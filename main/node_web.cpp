/*
 * node_web.cpp — Wi-Fi (Station / Soft AP / off), captive portal, mDNS and
 * the configuration web server of the LoRaWAN node — ESP-IDF version
 * (esp_wifi + esp_http_server; same pages and same HTTP API as the Arduino
 * firmware 1.1, so the page and the Android app work unchanged).
 *
 * Pages (all with HTTP Basic login, except favicon, /saiu and /info):
 *   GET  /              configuration + status (page in flash, filled by JS)
 *   GET  /config.json   saved configuration (passwords never leave the node)
 *   GET  /status        live status of the node / LoRaWAN session
 *   POST /save          save the form (urlencoded)
 *   POST /action        a=send | restart | fcnt (v=<n>)    -> JSON
 *   POST /reboot        reboot page
 *   POST /factory       factory defaults + reboot
 *   GET  /logs, /logs_data, /logs_download   live log
 *   GET  /diag, /diag_run?t=ping|trace|dns&h=<host>   network diagnostics
 *   GET  /logout, /saiu  logout (same trick as the gateway)
 *   GET  /info          who answers on this IP, without login (Android app)
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_mac.h"
#include "esp_chip_info.h"
#include "esp_efuse.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_tls_crypto.h"
#include "mdns.h"

#include "node_build.h"
#include "node_web.h"
#include "node_config.h"
#include "node_state.h"
#include "node_log.h"
#include "node_dns.h"
#include "node_diag.h"
#include "node_page.h"

#define WEB_LOGOUT_USER     "_logout_"
#define WEB_LOGOUT_PASS     "_logout_"
#define AP_IDLE_OFF_MS      60000UL     /* fallback AP off 60 s after STA is up */
#define STA_RETRY_MS        60000UL     /* STA retry while in fallback AP       */

/* Soft AP addressing — defaults if node_build.h (ABP/OTAA) does not set them */
#ifndef DEF_AP_IP
#define DEF_AP_IP           192, 168, 101, 101
#endif
#ifndef DEF_AP_GATEWAY
#define DEF_AP_GATEWAY      DEF_AP_IP
#endif
#ifndef DEF_AP_MASK
#define DEF_AP_MASK         255, 255, 255, 0
#endif


static httpd_handle_t s_server;
static esp_netif_t   *s_sta, *s_ap;
static NodeConfig     wcfg;             /* web (httpd task) copy of the config */
static NodeConfig     bootCfg;          /* as booted: Wi-Fi + reboot-only fields */
static volatile bool  forcedAp;
static volatile bool  apOn, staUp, staWanted, autoReconnect;
static bool           mdnsOn, wifiStarted;
static char           apName[33], host[33], apIpStr[16], staIpStr[16];
static uint32_t       staStartMs, apIdleSinceMs, staRetryMs;
static uint32_t       cfgVerSeen;
static volatile bool  forceApReq;
static bool           taskRunning;

static uint32_t millis(void) { return (uint32_t)(esp_timer_get_time() / 1000); }

static bool isOtaa(void) { return NODE_ACTIVATION_OTAA; }

/* ===================================================================== */
/*                                 helpers                               */
/* ===================================================================== */

/* Small JSON writer on a fixed buffer. */
typedef struct { char *b; size_t size, n; } JBuf;

static void jraw(JBuf *j, const char *s)
{
    size_t l = strlen(s);
    if (j->n + l >= j->size) l = j->size - j->n - 1;
    memcpy(j->b + j->n, s, l);
    j->n += l;
    j->b[j->n] = '\0';
}

static void jfmt(JBuf *j, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int l = vsnprintf(j->b + j->n, j->size - j->n, fmt, ap);
    va_end(ap);
    if (l > 0) j->n += ((size_t)l < j->size - j->n) ? (size_t)l : j->size - j->n - 1;
}

static void jstrn(JBuf *j, const char *s, size_t len)
{
    char e[8];
    jraw(j, "\"");
    for (size_t i = 0; i < len; i++) {
        unsigned char c = s[i];
        if (c == '"' || c == '\\') { e[0] = '\\'; e[1] = c; e[2] = 0; jraw(j, e); }
        else if (c < 0x20)         { snprintf(e, sizeof(e), "\\u%04x", c); jraw(j, e); }
        else                       { e[0] = c; e[1] = 0; jraw(j, e); }
    }
    jraw(j, "\"");
}

static void jkey(JBuf *j, const char *k)
{
    if (j->n > 1 && j->b[j->n - 1] != '{' && j->b[j->n - 1] != '[') jraw(j, ",");
    jraw(j, "\""); jraw(j, k); jraw(j, "\":");
}

static void jstr(JBuf *j, const char *k, const char *v) { jkey(j, k); jstrn(j, v, strlen(v)); }
static void jint(JBuf *j, const char *k, long v)        { jkey(j, k); jfmt(j, "%ld", v); }
static void jbool(JBuf *j, const char *k, bool v)       { jkey(j, k); jraw(j, v ? "true" : "false"); }
static void jonoff(JBuf *j, const char *k, bool v)      { jstr(j, k, v ? "on" : "off"); }
static void jhex(JBuf *j, const char *k, const uint8_t *b, size_t n, char sep = 0)
{
    char h[3 * RST_CMD_MAX + 4];
    bytesToHex(b, n, h, sep);
    jstr(j, k, h);
}

const char *nodeChipModel(void)
{
#if CONFIG_IDF_TARGET_ESP32
    esp_chip_info_t ci;
    esp_chip_info(&ci);
    bool v3 = ci.revision >= 300 || ci.revision == 3;
    switch (esp_efuse_get_pkg_ver()) {
    case 0:  return v3 ? "ESP32-D0WDQ6-V3" : "ESP32-D0WDQ6";
    case 1:  return v3 ? "ESP32-D0WD-V3" : "ESP32-D0WD";
    case 2:  return "ESP32-D2WD";
    case 3:  return "ESP32-D0WDR2-V3";
    case 4:  return "ESP32-U4WDH";
    case 5:  return v3 ? "ESP32-PICO-V3" : "ESP32-PICO-D4";
    case 6:  return "ESP32-PICO-V3-02";
    default: return "ESP32";
    }
#elif CONFIG_IDF_TARGET_ESP32S3
    return "ESP32-S3";
#else
    return CONFIG_IDF_TARGET;
#endif
}

/* "Basic base64(user:pass)" */
static void basicAuth(const char *user, const char *pass, char *out, size_t size)
{
    char up[72];
    size_t olen = 0;
    int n = snprintf(up, sizeof(up), "%s:%s", user, pass);
    strlcpy(out, "Basic ", size);
    if (esp_crypto_base64_encode((unsigned char *)out + 6, size - 7, &olen,
                                 (const unsigned char *)up, n) != 0)
        olen = 0;
    out[6 + olen] = '\0';
}

/* The header is "Basic base64(user:pass)": base64 is not encryption, so it
 * is never logged; the comparison takes the same time wherever the strings
 * differ, and both copies are wiped from the stack. */
static void wipe(char *p, size_t n)
{
    for (volatile char *v = p; v < p + n; v++) *v = 0;
}

static bool authAs(httpd_req_t *req, const char *user, const char *pass)
{
    char expect[112], got[160];
    size_t len = httpd_req_get_hdr_value_len(req, "Authorization");
    if (len == 0 || len >= sizeof(got)) return false;
    if (httpd_req_get_hdr_value_str(req, "Authorization", got, sizeof(got)) != ESP_OK) return false;
    basicAuth(user, pass, expect, sizeof(expect));
    size_t lg = strlen(got), le = strlen(expect);
    unsigned char diff = (lg != le);
    for (size_t i = 0; i < lg && i < le; i++)
        diff |= (unsigned char)got[i] ^ (unsigned char)expect[i];
    wipe(got, sizeof(got));
    wipe(expect, sizeof(expect));
    return diff == 0;
}

static void send401(httpd_req_t *req)
{
    httpd_resp_set_status(req, "401 Unauthorized");
    httpd_resp_set_hdr(req, "WWW-Authenticate", "Basic realm=\"\"");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    httpd_resp_sendstr(req, "Login necessário.");
}

/* web copy of the configuration up to date (changed by console/loop) */
static void syncCfg(void)
{
    if (nodeCfgVersion() != cfgVerSeen) {
        cfgVerSeen = nodeCfgVersion();
        nodeCfgShared(&wcfg);
    }
}

static bool auth(httpd_req_t *req)
{
    syncCfg();
    if (authAs(req, wcfg.webUser, wcfg.webPass))
        return true;
    send401(req);
    return false;
}

static void noStore(httpd_req_t *req) { httpd_resp_set_hdr(req, "Cache-Control", "no-store"); }

/* HTML escaping into a buffer */
static void htmlEsc(const char *s, char *out, size_t size)
{
    size_t j = 0;
    for (; *s && j + 7 < size; s++) {
        const char *r = NULL;
        switch (*s) {
        case '&': r = "&amp;"; break;
        case '<': r = "&lt;"; break;
        case '>': r = "&gt;"; break;
        case '"': r = "&quot;"; break;
        case '\'': r = "&#39;"; break;
        }
        if (r) { size_t l = strlen(r); memcpy(out + j, r, l); j += l; }
        else out[j++] = *s;
    }
    out[j] = '\0';
}

/* Small page after "Salvar", "Reiniciar"... (same look as the main page). */
static void sendSimple(httpd_req_t *req, const char *headExtra, const char *body)
{
    char title[200];
    htmlEsc(wcfg.name, title, sizeof(title));
    noStore(req);
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_send_chunk(req, SIMPLE_HEAD, HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, "<title>", HTTPD_RESP_USE_STRLEN);
    if (title[0]) httpd_resp_send_chunk(req, title, HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, "</title>", HTTPD_RESP_USE_STRLEN);
    if (headExtra && headExtra[0]) httpd_resp_send_chunk(req, headExtra, HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, "</head><body><div>", HTTPD_RESP_USE_STRLEN);
    if (body && body[0]) httpd_resp_send_chunk(req, body, HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, SIMPLE_END, HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, NULL, 0);
}

/* ------------------------- urlencoded form ------------------------- */
#define FORM_MAX_ARGS 96

typedef struct {
    int   n;
    char *k[FORM_MAX_ARGS];
    char *v[FORM_MAX_ARGS];
} Form;

static int hexv(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void urlDecode(char *s)
{
    char *w = s;
    for (; *s; s++) {
        if (*s == '+') *w++ = ' ';
        else if (*s == '%' && hexv(s[1]) >= 0 && hexv(s[2]) >= 0) {
            *w++ = (char)(hexv(s[1]) << 4 | hexv(s[2]));
            s += 2;
        } else *w++ = *s;
    }
    *w = '\0';
}

/* splits "a=1&b=2" in place */
static void formParse(char *body, Form *f)
{
    f->n = 0;
    char *p = body;
    while (p && *p && f->n < FORM_MAX_ARGS) {
        char *amp = strchr(p, '&');
        if (amp) *amp = '\0';
        char *eq = strchr(p, '=');
        if (eq) { *eq = '\0'; f->v[f->n] = eq + 1; }
        else f->v[f->n] = p + strlen(p);
        f->k[f->n] = p;
        urlDecode(f->k[f->n]);
        urlDecode(f->v[f->n]);
        f->n++;
        p = amp ? amp + 1 : NULL;
    }
}

static const char *formArg(const Form *f, const char *k)
{
    for (int i = 0; i < f->n; i++)
        if (!strcmp(f->k[i], k)) return f->v[i];
    return NULL;
}

/* body not received in time (the ESP-IDF default answer is in English) */
static void send408(httpd_req_t *req)
{
    httpd_resp_set_status(req, "408 Request Timeout");
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    httpd_resp_sendstr(req, "Tempo esgotado ao receber os dados. Tente de novo.");
}

/* reads the whole body (max size-1 bytes); false on error */
static bool readBody(httpd_req_t *req, char *buf, size_t size)
{
    size_t total = 0, want = req->content_len;
    if (want >= size) want = size - 1;
    while (total < want) {
        int r = httpd_req_recv(req, buf + total, want - total);
        if (r == HTTPD_SOCK_ERR_TIMEOUT) continue;
        if (r <= 0) return false;
        total += r;
    }
    buf[total] = '\0';
    return true;
}

/* copy trimmed */
static void trimCopy(const char *s, char *out, size_t size)
{
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
    size_t l = strlen(s);
    while (l && (s[l - 1] == ' ' || s[l - 1] == '\t' || s[l - 1] == '\r' || s[l - 1] == '\n')) l--;
    if (l >= size) l = size - 1;
    memcpy(out, s, l);
    out[l] = '\0';
}

/* ===================================================================== */
/*                                 Wi-Fi                                 */
/* ===================================================================== */
static void mdnsStart(void)
{
    if (mdns_init() != ESP_OK) return;
    mdns_hostname_set(host);
    mdns_instance_name_set(bootCfg.name);
    /* TXT read by the Android app to tell nodes and gateways apart */
    mdns_txt_item_t txt[] = {
        { "type", "node" },
        { "mode", isOtaa() ? "otaa" : "abp" },
        { "info", "/info" },
    };
    mdns_service_add(NULL, "_http", "_tcp", 80, txt, 3);
    mdnsOn = true;
}

static void onWifiEvent(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        staUp = false;
        if (staWanted && autoReconnect) esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *)data;
        snprintf(staIpStr, sizeof(staIpStr), IPSTR, IP2STR(&e->ip_info.ip));
        staUp = true;
    } else if (base == IP_EVENT && id == IP_EVENT_STA_LOST_IP) {
        staUp = false;
    }
}

static void wifiInit(void)
{
    esp_netif_init();
    esp_event_loop_create_default();
    s_sta = esp_netif_create_default_wifi_sta();
    s_ap  = esp_netif_create_default_wifi_ap();
    wifi_init_config_t wc = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wc));
    esp_wifi_set_storage(WIFI_STORAGE_RAM);          /* WiFi.persistent(false) */
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, onWifiEvent, NULL);
    esp_event_handler_register(IP_EVENT, ESP_EVENT_ANY_ID, onWifiEvent, NULL);
    esp_netif_set_hostname(s_sta, host);
}

static void wifiMode(wifi_mode_t m)
{
    esp_wifi_set_mode(m);
    if (!wifiStarted) {
        esp_wifi_start();
        wifiStarted = true;
    }
}

static void startAp(bool withSta)
{
    wifi_config_t ap;
    memset(&ap, 0, sizeof(ap));
    strlcpy((char *)ap.ap.ssid, apName, sizeof(ap.ap.ssid));
    ap.ap.ssid_len = strlen(apName);
    strlcpy((char *)ap.ap.password, bootCfg.apPass, sizeof(ap.ap.password));
    ap.ap.channel = bootCfg.apChannel;
    ap.ap.max_connection = 4;
    ap.ap.authmode = strlen(bootCfg.apPass) >= 8 ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    wifiMode(withSta ? WIFI_MODE_APSTA : WIFI_MODE_AP);
    esp_wifi_set_config(WIFI_IF_AP, &ap);

    esp_netif_ip_info_t ip;
    memset(&ip, 0, sizeof(ip));
    esp_netif_set_ip4_addr(&ip.ip, DEF_AP_IP);
    esp_netif_set_ip4_addr(&ip.gw, DEF_AP_GATEWAY);
    esp_netif_set_ip4_addr(&ip.netmask, DEF_AP_MASK);
    esp_netif_dhcps_stop(s_ap);
    if (esp_netif_set_ip_info(s_ap, &ip) != ESP_OK)
        printf("[WEB] Falha ao aplicar IP fixo do Soft AP — usando o padrão.\r\n");
    esp_netif_dhcps_start(s_ap);
    esp_netif_get_ip_info(s_ap, &ip);
    snprintf(apIpStr, sizeof(apIpStr), IPSTR, IP2STR(&ip.ip));

    nodeDnsStart(ip.ip.addr);
    apOn = true;
    apIdleSinceMs = 0;
    printf("[WEB] Soft AP \"%s\" ativo — http://%s/\r\n", apName, apIpStr);
    nodeLogSecret("[WEB] Senha do Soft AP: (oculta no log da web; veja no console serial)\r\n",
                  "[WEB] Senha do Soft AP: %s\r\n", bootCfg.apPass);
}

static void stopAp(void)
{
    nodeDnsStop();
    esp_wifi_set_mode(WIFI_MODE_STA);
    apOn = false;
    printf("[WEB] Station conectada: Soft AP de emergência desligado.\r\n");
}

static uint8_t apClients(void)
{
    wifi_sta_list_t l;
    if (!apOn || esp_wifi_ap_get_sta_list(&l) != ESP_OK) return 0;
    return (uint8_t)l.num;
}

static void staBegin(void)
{
    if (bootCfg.ipStatic) {
        esp_netif_ip_info_t ip;
        esp_netif_dns_info_t d;
        memset(&ip, 0, sizeof(ip));
        esp_netif_dhcpc_stop(s_sta);
        ip.ip.addr      = esp_ip4addr_aton(bootCfg.ip);
        ip.netmask.addr = esp_ip4addr_aton(bootCfg.mask[0] ? bootCfg.mask : "255.255.255.0");
        ip.gw.addr      = esp_ip4addr_aton(bootCfg.gw);
        esp_netif_set_ip_info(s_sta, &ip);
        memset(&d, 0, sizeof(d));
        d.ip.type = ESP_IPADDR_TYPE_V4;
        d.ip.u_addr.ip4.addr = (bootCfg.dns1[0] && validIPv4(bootCfg.dns1)) ? esp_ip4addr_aton(bootCfg.dns1) : ip.gw.addr;
        esp_netif_set_dns_info(s_sta, ESP_NETIF_DNS_MAIN, &d);
        d.ip.u_addr.ip4.addr = (bootCfg.dns2[0] && validIPv4(bootCfg.dns2)) ? esp_ip4addr_aton(bootCfg.dns2)
                                                                            : esp_ip4addr_aton("8.8.8.8");
        esp_netif_set_dns_info(s_sta, ESP_NETIF_DNS_BACKUP, &d);
    }
    wifi_config_t sc;
    memset(&sc, 0, sizeof(sc));
    strlcpy((char *)sc.sta.ssid, bootCfg.ssid, sizeof(sc.sta.ssid));
    strlcpy((char *)sc.sta.password, bootCfg.pass, sizeof(sc.sta.password));
    esp_wifi_set_config(WIFI_IF_STA, &sc);
    staWanted = true;
    esp_wifi_connect();
    staStartMs = staRetryMs = millis();
}

static void wifiStart(void)
{
    if (forcedAp || bootCfg.wifiMode == NODE_WIFI_AP) {
        startAp(false);
        return;
    }
    wifiMode(WIFI_MODE_STA);
    autoReconnect = true;
    if (!bootCfg.ssid[0]) {                 /* nothing configured yet */
        printf("[WEB] Nenhuma rede Wi-Fi configurada.\r\n");
        startAp(false);
        return;
    }
    printf("[WEB] Conectando na rede \"%s\"...\r\n", bootCfg.ssid);
    staBegin();
}

/* Called every 100 ms by the supervisor task. */
static void wifiSupervise(void)
{
    uint32_t now = millis();
    bool sta = staUp;

    if (sta && !mdnsOn) {
        wifi_ap_record_t ap;
        int rssi = esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
        mdnsStart();
        printf("[WEB] Wi-Fi conectado: http://%s/  ou  http://%s.local/  (RSSI %d dBm)\r\n",
               staIpStr, host, rssi);
    }

    if (forcedAp || bootCfg.wifiMode != NODE_WIFI_STA || !bootCfg.ssid[0])
        return;

    if (!apOn && !sta && now - staStartMs > bootCfg.staTimeout * 1000UL) {
        printf("[WEB] Sem conexão Wi-Fi há %u s — abrindo Soft AP de emergência.\r\n", bootCfg.staTimeout);
        autoReconnect = false;              /* STA scans would disturb the AP */
        esp_wifi_disconnect();
        startAp(true);
        staRetryMs = now;
    }
    if (apOn && !sta && apClients() == 0 && now - staRetryMs > STA_RETRY_MS) {
        staRetryMs = now;                   /* retry only when nobody uses the AP */
        esp_wifi_disconnect();
        esp_wifi_connect();
    }
    if (apOn && sta) {
        if (apClients() > 0) apIdleSinceMs = 0;
        else if (!apIdleSinceMs) apIdleSinceMs = now ? now : 1;
        else if (now - apIdleSinceMs > AP_IDLE_OFF_MS) { stopAp(); autoReconnect = true; }
    }
}

/* ===================================================================== */
/*                               handlers                                */
/* ===================================================================== */
static esp_err_t handleRoot(httpd_req_t *req)
{
    if (!auth(req)) return ESP_OK;
    noStore(req);
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, PAGE_MAIN, sizeof(PAGE_MAIN) - 1);
}

static esp_err_t handleFavicon(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Cache-Control", "max-age=86400");
    httpd_resp_set_type(req, "image/svg+xml");
    return httpd_resp_send(req, FAVICON_SVG, sizeof(FAVICON_SVG) - 1);
}

static esp_err_t sendJson(httpd_req_t *req, const char *buf)
{
    noStore(req);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, buf);
}

/* GET /info — identification for the Android app, WITHOUT login. */
static esp_err_t handleInfo(httpd_req_t *req)
{
    static char buf[512];
    JBuf j = { buf, sizeof(buf), 0 };
    uint8_t mac[6];

    syncCfg();
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    buf[0] = 0;
    jraw(&j, "{");
    jstr(&j, "type", "node");
    jstr(&j, "mode", isOtaa() ? "otaa" : "abp");
    jstr(&j, "fw", NODE_FW_NAME);
    jstr(&j, "version", NODE_FW_VERSION);
    jstr(&j, "region", NODE_REGION);
    jstr(&j, "name", wcfg.name);
    jstr(&j, "host", host);
    jhex(&j, "mac", mac, 6, ':');
    jstr(&j, "chip", nodeChipModel());
    jstr(&j, "board", CONFIG_NODE_BOARD_ID);              /* esp32 | esp32s3_n16r8 | esp32s3_n32r16v */
    jstr(&j, "board_name", CONFIG_NODE_BOARD_NAME);
    jstr(&j, "wifi", apOn && staUp ? "apsta" : apOn ? "ap" : "sta");
    jbool(&j, "mdns", mdnsOn);
    jint(&j, "api", 1);
    jraw(&j, "}");
    return sendJson(req, buf);
}

/* GET /config.json */
static esp_err_t handleConfigJson(httpd_req_t *req)
{
    static char buf[4096];      /* + pin rules of the board (node_board.h) */
    JBuf j = { buf, sizeof(buf), 0 };
    const NodeConfig &c = wcfg;
    char t[40];
    uint8_t mac[6];

    if (!auth(req)) return ESP_OK;
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    buf[0] = 0;
    jraw(&j, "{");
    jstr(&j, "_mode", isOtaa() ? "otaa" : "abp");
    jstr(&j, "_fw", NODE_FW_NAME " " NODE_FW_VERSION);
    jstr(&j, "_lmic", NODE_LMIC_VERSION);
    jstr(&j, "_region", NODE_REGION);
    jhex(&j, "_mac", mac, 6, ':');
    jstr(&j, "_chip", nodeChipModel());
    jstr(&j, "_board", CONFIG_NODE_BOARD_ID);
    jstr(&j, "_board_name", CONFIG_NODE_BOARD_NAME);
    jkey(&j, "_pins_rsv"); jraw(&j, NODE_PINS_RSV_JSON);   /* GPIO -> reason (node_board.h) */
    jkey(&j, "_pins_in");  jraw(&j, NODE_PINS_IN_JSON);    /* input-only GPIOs */
    jint(&j, "_pin_max", NODE_PIN_MAX);
    jstr(&j, "_pins_hint", NODE_PINS_HINT);

    jstr(&j, "name", c.name);
    jstr(&j, "wifi_mode", c.wifiMode == NODE_WIFI_AP ? "ap" : c.wifiMode == NODE_WIFI_OFF ? "off" : "sta");
    jstr(&j, "wifi_ssid", c.ssid);
    jbool(&j, "wifi_pswd_set", c.pass[0] != 0);
    jstr(&j, "ip_mode", c.ipStatic ? "static" : "dhcp");
    jstr(&j, "ip_addr", c.ip);
    jstr(&j, "ip_mask", c.mask);
    jstr(&j, "ip_gw", c.gw);
    jstr(&j, "ip_dns1", c.dns1);
    jstr(&j, "ip_dns2", c.dns2);
    jstr(&j, "ap_ssid", c.apSsid);
    jbool(&j, "ap_pswd_set", c.apPass[0] != 0);
    jint(&j, "ap_ch", c.apChannel);
    jint(&j, "sta_to", c.staTimeout);
    jint(&j, "boot_pin", c.bootPin);
    jstr(&j, "web_user", c.webUser);

    jhex(&j, "dev_eui", c.devEui, 8);
    jhex(&j, "join_eui", c.joinEui, 8);
    jhex(&j, "app_key", c.appKey, 16);
    jonoff(&j, "eui_rev", c.euiReverse);
    snprintf(t, sizeof(t), "%08lX", (unsigned long)c.devAddr);  jstr(&j, "dev_addr", t);
    jhex(&j, "nwk_skey", c.nwkSKey, 16);
    jhex(&j, "app_skey", c.appSKey, 16);
    snprintf(t, sizeof(t), "%06lX", (unsigned long)c.netId);    jstr(&j, "net_id", t);
    jint(&j, "rx1_delay", c.rx1Delay);

    jint(&j, "sub_band", c.subBand);
    jonoff(&j, "ch500", c.ch500);
    jstr(&j, "ch_list", c.chList);
    jonoff(&j, "adr", c.adr);
    jint(&j, "dr", c.dr);
    jint(&j, "tx_pow", c.txPow);
    jonoff(&j, "link_chk", c.linkCheck);
    jint(&j, "clk_err", c.clockErr);
    jint(&j, "rx2_dr", c.rx2Dr);
    if (c.rx2Freq) jint(&j, "rx2_freq", c.rx2Freq); else jstr(&j, "rx2_freq", "");

    jint(&j, "tx_int", c.txInterval);
    jint(&j, "fport", c.fport);
    jonoff(&j, "confirmed", c.confirmed);
    jstr(&j, "pl_fmt", c.payloadHex ? "hex" : "text");
    if (c.payloadHex) {
        char h[PAYLOAD_MAX * 3 + 1];
        bytesToHex(c.payload, c.payloadLen, h, ' ');
        jstr(&j, "payload", h);
    } else {
        jkey(&j, "payload");
        jstrn(&j, (const char *)c.payload, c.payloadLen);
    }

    jonoff(&j, "rst_en", c.rstEnable);
    jint(&j, "rst_port", c.rstPort);
    jhex(&j, "rst_cmd", c.rstCmd, c.rstLen, ' ');
    jint(&j, "rst_delay", c.rstDelay);

    jint(&j, "pin_sclk", c.pinSclk);
    jint(&j, "pin_miso", c.pinMiso);
    jint(&j, "pin_mosi", c.pinMosi);
    jint(&j, "pin_nss", c.pinNss);
    jint(&j, "pin_rst", c.pinRst);
    jint(&j, "pin_dio0", c.pinDio0);
    jint(&j, "pin_dio1", c.pinDio1);
    jint(&j, "pin_dio2", c.pinDio2);
    jint(&j, "spi_freq", c.spiFreq);
    jint(&j, "baud", c.baud);
    jonoff(&j, "verbose", c.verbose);
    jraw(&j, "}");
    return sendJson(req, buf);
}

/* Fields that only take effect after a reboot (compared with the boot copy). */
static int rebootPending(char *list, size_t size)
{
    const NodeConfig &a = bootCfg, &b = wcfg;
    int n = 0;
    list[0] = 0;
#define DIFF(cond, label) if (cond) { if (n++) strlcat(list, ", ", size); strlcat(list, label, size); }
    DIFF(a.wifiMode != b.wifiMode || strcmp(a.ssid, b.ssid) || strcmp(a.pass, b.pass) ||
         a.ipStatic != b.ipStatic || strcmp(a.ip, b.ip) || strcmp(a.mask, b.mask) ||
         strcmp(a.gw, b.gw) || strcmp(a.dns1, b.dns1) || strcmp(a.dns2, b.dns2) ||
         strcmp(a.apSsid, b.apSsid) || strcmp(a.apPass, b.apPass) || a.apChannel != b.apChannel ||
         a.staTimeout != b.staTimeout || strcmp(a.name, b.name), "Wi-Fi");
    DIFF(a.bootPin != b.bootPin || a.pinSclk != b.pinSclk || a.pinMiso != b.pinMiso ||
         a.pinMosi != b.pinMosi || a.pinNss != b.pinNss || a.pinRst != b.pinRst ||
         a.pinDio0 != b.pinDio0 || a.pinDio1 != b.pinDio1 || a.pinDio2 != b.pinDio2 ||
         a.spiFreq != b.spiFreq, "pinos");
    DIFF(a.baud != b.baud, "velocidade da serial");
#undef DIFF
    return n;
}

/* GET /status */
static esp_err_t handleStatus(httpd_req_t *req)
{
    static char buf[1700];
    JBuf j = { buf, sizeof(buf), 0 };
    NodeStatus s;
    uint32_t now = millis();
    char t[80];

    if (!auth(req)) return ESP_OK;
    nodeStatusGet(&s);
    buf[0] = 0;
    jraw(&j, "{\"node\":{");
    jint(&j, "up", now / 1000);
    jint(&j, "heap", esp_get_free_heap_size());
    jint(&j, "heap_min", esp_get_minimum_free_heap_size());
    bool sta = staUp;
    jstr(&j, "wifi", apOn && sta ? "apsta" : apOn ? "ap" : sta ? "sta" : (!wifiStarted ? "off" : "connecting"));
    wifi_ap_record_t ap;
    if (sta && esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
        jint(&j, "rssi", ap.rssi);
        jstr(&j, "ip", staIpStr);
        jstr(&j, "ssid", (const char *)ap.ssid);
    } else {
        jkey(&j, "rssi"); jraw(&j, "null");
    }
    if (apOn) { jstr(&j, "ap_ip", apIpStr); jstr(&j, "ap_ssid", apName); jint(&j, "ap_clients", apClients()); }
    jstr(&j, "host", host);
    jbool(&j, "forced_ap", forcedAp);
    rebootPending(t, sizeof(t));
    jstr(&j, "reboot", t);
    jraw(&j, "},\"lw\":{");
    jstr(&j, "mode", isOtaa() ? "otaa" : "abp");
    jbool(&j, "joined", s.joined);
    jint(&j, "join_tries", s.joinTries);
    snprintf(t, sizeof(t), "%08lX", (unsigned long)s.devAddr); jstr(&j, "devaddr", t);
    snprintf(t, sizeof(t), "%06lX", (unsigned long)s.netId);   jstr(&j, "netid", t);
    jint(&j, "fcnt_up", s.fcntUp);
    jint(&j, "fcnt_dn", s.fcntDn);
    jint(&j, "boot_fcnt", s.bootFcnt);
    /* Session keys in use (MSB, as ChirpStack shows them).
     * src "join" = OTAA, derived at the last JOIN (new on every JOIN);
     * src "abp"  = typed on the page. Empty strings while there is no
     * session (OTAA before the JOIN is accepted). */
    jkey(&j, "skeys"); jraw(&j, "{");
    jstr(&j, "src", isOtaa() ? "join" : "abp");
    jbool(&j, "valid", s.keysValid);
    /* Display order everywhere: DevAddr, NwkSKey, AppSKey. */
    if (s.keysValid) {
        snprintf(t, sizeof(t), "%08lX", (unsigned long)s.devAddr); jstr(&j, "devaddr", t);
        jhex(&j, "nwk", s.nwkSKey, 16);
        jhex(&j, "app", s.appSKey, 16);
    } else {
        jstr(&j, "devaddr", "");
        jstr(&j, "nwk", "");
        jstr(&j, "app", "");
    }
    jint(&j, "age", s.keysValid && s.sessionMs ? (long)((now - s.sessionMs) / 1000) : -1);
    jraw(&j, "}");
    jint(&j, "up", s.upCount);
    jint(&j, "ack", s.ackCount);
    jint(&j, "dn", s.dnCount);
    jint(&j, "last_tx", s.lastTxMs ? (long)((now - s.lastTxMs) / 1000) : -1);
    jint(&j, "next_tx", s.nextTxMs ? (long)((int32_t)(s.nextTxMs - now) / 1000) : -1);
    jbool(&j, "pending", s.txPending);
    jint(&j, "dr", s.dr);
    jint(&j, "txpow", s.txPow);
    jint(&j, "freq", s.freq);
    jint(&j, "interval", wcfg.txInterval);
    if (s.lastDnMs) {
        jkey(&j, "last_dn"); jraw(&j, "{");
        jint(&j, "port", s.lastDnPort);
        jint(&j, "len", s.lastDnLen);
        char h[sizeof(s.lastDn) * 3 + 1];
        bytesToHex(s.lastDn, s.lastDnLen < sizeof(s.lastDn) ? s.lastDnLen : sizeof(s.lastDn), h, ' ');
        jstr(&j, "hex", h);
        jint(&j, "age", (now - s.lastDnMs) / 1000);
        jint(&j, "rssi", s.rssi);
        jint(&j, "snr", s.snr);
        jraw(&j, "}");
    }
    jstr(&j, "ev", s.lastEvent);
    jint(&j, "ev_age", s.lastEventMs ? (long)((now - s.lastEventMs) / 1000) : -1);
    jraw(&j, "}}");
    return sendJson(req, buf);
}

/* ------------------------------ POST /save ------------------------------ */
static char  errs[1024];
static Form  form;

static void err(const char *m)
{
    if (errs[0]) strlcat(errs, "\n", sizeof(errs));
    strlcat(errs, m, sizeof(errs));
}

static bool hasArg(const char *name) { return formArg(&form, name) != NULL; }
static const char *arg(const char *name) { const char *v = formArg(&form, name); return v ? v : ""; }

static bool argStr(const char *name, char *dst, size_t size, const char *label, bool allowEmpty = true)
{
    if (!hasArg(name)) return false;
    char v[260];
    trimCopy(arg(name), v, sizeof(v));
    char m[96];
    if (!allowEmpty && !v[0]) { snprintf(m, sizeof(m), "%s: obrigatório.", label); err(m); return false; }
    if (strlen(v) >= size) { snprintf(m, sizeof(m), "%s: texto longo demais.", label); err(m); return false; }
    strlcpy(dst, v, size);
    return true;
}

static bool argLong(const char *name, long lo, long hi, long *out, const char *label)
{
    if (!hasArg(name)) return false;
    char v[32];
    trimCopy(arg(name), v, sizeof(v));
    if (!v[0]) return false;
    char *e;
    long x = strtol(v, &e, 10);
    if (*e || x < lo || x > hi) {
        char m[96];
        snprintf(m, sizeof(m), "%s: use um número entre %ld e %ld.", label, lo, hi);
        err(m);
        return false;
    }
    *out = x;
    return true;
}

static bool argOnOff(const char *name, uint8_t *dst)
{
    if (!hasArg(name)) return false;
    *dst = !strcmp(arg(name), "on") ? 1 : 0;
    return true;
}

static void argHex(const char *name, uint8_t *dst, size_t len, const char *label)
{
    if (!hasArg(name)) return;
    char v[80];
    trimCopy(arg(name), v, sizeof(v));
    if (!v[0]) return;                             /* empty keeps the value */
    if (!hexToBytes(v, dst, len)) {
        char m[96];
        snprintf(m, sizeof(m), "%s: use exatamente %u bytes em hexadecimal (%u caracteres).", label, (unsigned)len, (unsigned)len * 2);
        err(m);
    }
}

static void argPin(const char *name, int8_t *dst, const char *label, bool optional)
{
    long v;
    if (argLong(name, optional ? -1 : 0, 48, &v, label)) *dst = (int8_t)v;
}

static esp_err_t handleSave(httpd_req_t *req)
{
    static char body[4096];
    static NodeConfig n;
    long v;
    char tmp[72];

    if (!auth(req)) return ESP_OK;
    if (!readBody(req, body, sizeof(body))) { send408(req); return ESP_FAIL; }
    formParse(body, &form);
    n = wcfg;
    errs[0] = 0;

    /* device / Wi-Fi */
    argStr("name", n.name, sizeof(n.name), "Nome do nó", false);
    if (hasArg("wifi_mode")) {
        const char *m = arg("wifi_mode");
        n.wifiMode = !strcmp(m, "ap") ? NODE_WIFI_AP : !strcmp(m, "off") ? NODE_WIFI_OFF : NODE_WIFI_STA;
    }
    argStr("wifi_ssid", n.ssid, sizeof(n.ssid), "Nome da rede (SSID)");
    if (hasArg("wifi_pswd") && arg("wifi_pswd")[0]) {
        if (strlen(arg("wifi_pswd")) < 8) err("Senha do Wi-Fi: mínimo de 8 caracteres.");
        else argStr("wifi_pswd", n.pass, sizeof(n.pass), "Senha do Wi-Fi");
    }
    if (hasArg("ip_mode")) n.ipStatic = !strcmp(arg("ip_mode"), "static");
    argStr("ip_addr", n.ip, sizeof(n.ip), "Endereço IP");
    argStr("ip_mask", n.mask, sizeof(n.mask), "Máscara");
    argStr("ip_gw", n.gw, sizeof(n.gw), "Gateway");
    argStr("ip_dns1", n.dns1, sizeof(n.dns1), "DNS primário");
    argStr("ip_dns2", n.dns2, sizeof(n.dns2), "DNS secundário");
    if (n.ipStatic) {
        if (!validIPv4(n.ip))   err("Endereço IP: use o formato 192.168.18.101.");
        if (!validIPv4(n.mask)) err("Máscara: use o formato 255.255.255.0.");
        if (!validIPv4(n.gw))   err("Gateway: use o formato 192.168.18.1.");
        if (n.dns1[0] && !validIPv4(n.dns1)) err("DNS primário: formato inválido.");
        if (n.dns2[0] && !validIPv4(n.dns2)) err("DNS secundário: formato inválido.");
    }
    argStr("ap_ssid", n.apSsid, sizeof(n.apSsid), "Nome do Soft AP");
    if (hasArg("ap_pswd") && arg("ap_pswd")[0]) {
        if (strlen(arg("ap_pswd")) < 8) err("Senha do Soft AP: mínimo de 8 caracteres.");
        else argStr("ap_pswd", n.apPass, sizeof(n.apPass), "Senha do Soft AP");
    }
    if (argLong("ap_ch", 1, 13, &v, "Canal do Soft AP")) n.apChannel = v;
    if (argLong("sta_to", 5, 3600, &v, "Tempo até o Soft AP")) n.staTimeout = v;
    if (argLong("boot_pin", -1, 48, &v, "Botão do Soft AP")) n.bootPin = v;

    /* web login */
    if (argStr("web_user", tmp, sizeof(n.webUser), "Usuário da página", false)) {
        if (strchr(tmp, ':') || !strcmp(tmp, WEB_LOGOUT_USER)) err("Usuário da página: sem dois-pontos.");
        else strlcpy(n.webUser, tmp, sizeof(n.webUser));
    }
    if (hasArg("web_pswd") && arg("web_pswd")[0]) {
        const char *p = arg("web_pswd");
        if (strlen(p) < 6 || strlen(p) >= sizeof(n.webPass) || strchr(p, ':'))
            err("Nova senha da página: 6 a 31 caracteres, sem dois-pontos.");
        else strlcpy(n.webPass, p, sizeof(n.webPass));
    }

    /* activation */
    argHex("dev_eui", n.devEui, 8, "DevEUI");
    argHex("join_eui", n.joinEui, 8, "JoinEUI / AppEUI");
    argHex("app_key", n.appKey, 16, "AppKey");
    argOnOff("eui_rev", &n.euiReverse);
    if (hasArg("dev_addr") && arg("dev_addr")[0]) {
        uint8_t a[4];
        if (hexToBytes(arg("dev_addr"), a, 4))
            n.devAddr = (uint32_t)a[0] << 24 | (uint32_t)a[1] << 16 | (uint32_t)a[2] << 8 | a[3];
        else err("DevAddr: use 8 caracteres hexadecimais.");
    }
    argHex("nwk_skey", n.nwkSKey, 16, "NwkSKey");
    argHex("app_skey", n.appSKey, 16, "AppSKey");
    if (hasArg("net_id") && arg("net_id")[0]) {
        uint8_t a[3];
        if (hexToBytes(arg("net_id"), a, 3))
            n.netId = (uint32_t)a[0] << 16 | (uint32_t)a[1] << 8 | a[2];
        else err("NetID: use 6 caracteres hexadecimais (000000 ChirpStack, 000013 TTN).");
    }
    if (argLong("rx1_delay", 1, 15, &v, "Atraso RX1")) n.rx1Delay = v;

    /* radio */
    if (argLong("sub_band", 0, 7, &v, "Sub-banda")) n.subBand = v;
    argOnOff("ch500", &n.ch500);
    if (argStr("ch_list", tmp, sizeof(n.chList), "Canais personalizados")) {
        uint8_t m[9];
        if (tmp[0] && parseChannelList(tmp, m) <= 0) err("Canais personalizados: use números de 0 a 71, ex.: 8-15,65.");
        else strlcpy(n.chList, tmp, sizeof(n.chList));
    }
    argOnOff("adr", &n.adr);
    if (argLong("dr", 0, 6, &v, "Data rate")) n.dr = v;
    if (argLong("tx_pow", 2, 20, &v, "Potência")) n.txPow = v;
    argOnOff("link_chk", &n.linkCheck);
    if (argLong("clk_err", 0, 10, &v, "Erro de relógio")) n.clockErr = v;
    if (argLong("rx2_dr", 8, 13, &v, "Data rate RX2")) n.rx2Dr = v;
    if (hasArg("rx2_freq")) {
        if (!arg("rx2_freq")[0]) n.rx2Freq = 0;
        else if (argLong("rx2_freq", 100000000L, 999999999L, &v, "Frequência RX2 (Hz)")) n.rx2Freq = v;
    }

    /* uplink */
    if (argLong("tx_int", 5, 86400, &v, "Intervalo")) n.txInterval = v;
    if (argLong("fport", 1, 223, &v, "FPort do uplink")) n.fport = v;
    argOnOff("confirmed", &n.confirmed);
    if (hasArg("pl_fmt") && hasArg("payload")) {
        bool hex = !strcmp(arg("pl_fmt"), "hex");
        const char *p = arg("payload");
        if (hex) {
            uint8_t b[PAYLOAD_MAX];
            int l = hexToBytesVar(p, b, PAYLOAD_MAX);
            if (l < 1) err("Payload: hexadecimal inválido (1 a 222 bytes).");
            else { n.payloadHex = 1; n.payloadLen = l; memcpy(n.payload, b, l); }
        } else {
            size_t l = strlen(p);
            if (l < 1 || l > PAYLOAD_MAX) err("Payload: 1 a 222 bytes.");
            else { n.payloadHex = 0; n.payloadLen = l; memcpy(n.payload, p, l); }
        }
    }

    /* remote reset */
    argOnOff("rst_en", &n.rstEnable);
    if (argLong("rst_port", 1, 223, &v, "FPort do reset")) n.rstPort = v;
    if (hasArg("rst_cmd") && arg("rst_cmd")[0]) {
        uint8_t b[RST_CMD_MAX];
        int l = hexToBytesVar(arg("rst_cmd"), b, RST_CMD_MAX);
        if (l < 1) err("Comando de reset: 1 a 16 bytes em hexadecimal.");
        else { n.rstLen = l; memcpy(n.rstCmd, b, l); }
    }
    if (argLong("rst_delay", 0, 60000, &v, "Espera antes do reset")) n.rstDelay = v;

    /* hardware */
    argPin("pin_sclk", &n.pinSclk, "SCLK", false);
    argPin("pin_miso", &n.pinMiso, "MISO", false);
    argPin("pin_mosi", &n.pinMosi, "MOSI", false);
    argPin("pin_nss",  &n.pinNss,  "NSS", false);
    argPin("pin_rst",  &n.pinRst,  "RESET", true);
    argPin("pin_dio0", &n.pinDio0, "DIO0", false);
    argPin("pin_dio1", &n.pinDio1, "DIO1", true);
    argPin("pin_dio2", &n.pinDio2, "DIO2", true);
    if (argLong("spi_freq", 0, 10000000L, &v, "Clock SPI")) n.spiFreq = v;
    if (argLong("baud", 9600, 921600, &v, "Velocidade da serial")) n.baud = v;
    argOnOff("verbose", &n.verbose);

    static char page[2048];
    if (errs[0]) {
        char e[1200];
        htmlEsc(errs, e, sizeof(e));
        snprintf(page, sizeof(page),
                 "<h2>Nada foi salvo</h2><p>Corrija e tente de novo:</p><p style='text-align:left;white-space:pre-line;color:#c0362c'>%s"
                 "</p><form action='/' method='get'><button class='p' type='submit'>Voltar</button></form>", e);
        sendSimple(req, NULL, page);
        return ESP_OK;
    }

    nodeConfigSanitize(&n);
    bool loginChanged = strcmp(n.webUser, wcfg.webUser) || strcmp(n.webPass, wcfg.webPass);
    if (!nodeConfigSave(&n)) {
        sendSimple(req, NULL, "<h2>Falha ao gravar</h2><p>A NVS não aceitou a gravação. Tente de novo.</p>"
                              "<form action='/' method='get'><button class='p'>Voltar</button></form>");
        return ESP_OK;
    }
    wcfg = n;
    nodeCfgPost(&n);                     /* the LoRaWAN loop applies its part */
    cfgVerSeen = nodeCfgVersion();
    printf("[WEB] Configuração salva pela página.\r\n");

    char pend[96];
    strlcpy(page, "<h2>Configuração salva</h2><p>", sizeof(page));
    strlcat(page, isOtaa() ? "LoRaWAN, rádio, uplink e reset remoto já foram aplicados (mudança de chaves ou canais refaz o JOIN)."
                           : "LoRaWAN, rádio, uplink e reset remoto já foram aplicados.", sizeof(page));
    if (rebootPending(pend, sizeof(pend))) {
        strlcat(page, "</p><p><b>Precisa reiniciar para valer: ", sizeof(page));
        strlcat(page, pend, sizeof(page));
        strlcat(page, ".</b>", sizeof(page));
    }
    if (loginChanged) strlcat(page, "</p><p>O usuário/senha da página mudaram: o navegador vai pedir o novo login.", sizeof(page));
    strlcat(page, "</p><form action='/reboot' method='post'><button class='p' type='submit'>Reiniciar agora</button></form>"
                  "<form action='/' method='get'><button type='submit'>Voltar</button></form>", sizeof(page));
    sendSimple(req, NULL, page);
    return ESP_OK;
}

/* --------------------------- POST /action ---------------------------- */
static esp_err_t handleAction(httpd_req_t *req)
{
    static char body[256];
    const char *msg = NULL;

    if (!auth(req)) return ESP_OK;
    if (!readBody(req, body, sizeof(body))) { send408(req); return ESP_FAIL; }
    formParse(body, &form);
    const char *a = arg("a");
    noStore(req);
    httpd_resp_set_type(req, "application/json");

    if (!strcmp(a, "send")) {
        nodeCmdPost(NODE_CMD_SEND_NOW);
        msg = "Uplink solicitado.";
    } else if (!strcmp(a, "restart")) {
        nodeCmdPost(NODE_CMD_RESTART);
        msg = isOtaa() ? "Refazendo o JOIN." : "Sessão ABP reprovisionada.";
    } else if (!strcmp(a, "fcnt") && !isOtaa()) {
        const char *v = arg("v");
        char *e;
        unsigned long x = strtoul(v, &e, 10);
        if (!v[0] || *e) {
            httpd_resp_set_status(req, "400 Bad Request");
            return httpd_resp_sendstr(req, "{\"ok\":false,\"error\":\"FCnt inválido\"}");
        }
        nodeCmdPost(NODE_CMD_SET_FCNT, x);
        msg = "FCnt alterado.";
    } else {
        httpd_resp_set_status(req, "400 Bad Request");
        return httpd_resp_sendstr(req, "{\"ok\":false,\"error\":\"ação desconhecida\"}");
    }
    char r[96];
    snprintf(r, sizeof(r), "{\"ok\":true,\"msg\":\"%s\"}", msg);
    return httpd_resp_sendstr(req, r);
}

static void rebootSoon(void)
{
    vTaskDelay(pdMS_TO_TICKS(400));      /* let the response leave */
    nodeCmdPost(NODE_CMD_REBOOT);
}

static esp_err_t handleReboot(httpd_req_t *req)
{
    if (!auth(req)) return ESP_OK;
    printf("[WEB] Reinício pedido pela página.\r\n");
    sendSimple(req, "<meta http-equiv='refresh' content='15; URL=/'>",
               "<h2>Reiniciando…</h2><p>A página volta sozinha em 15 segundos. Se o nó mudou de "
               "modo (Soft AP ↔ Station) ou de IP, acesse pelo novo endereço.</p>");
    rebootSoon();
    return ESP_OK;
}

static esp_err_t handleFactory(httpd_req_t *req)
{
    if (!auth(req)) return ESP_OK;
    printf("[WEB] Restaurando padrão de fábrica.\r\n");
    nodeConfigErase();
    sendSimple(req, "<meta http-equiv='refresh' content='20; URL=/'>",
               "<h2>Padrão de fábrica restaurado</h2><p>O nó está reiniciando com os valores do "
               "<code>node_build.h</code>. Login da página: <b>" DEF_WEB_USER " / " DEF_WEB_PASS "</b>. "
               "O contador de frames (FCnt) foi mantido.</p>");
    rebootSoon();
    return ESP_OK;
}

/* ----------------------------- classes ------------------------------ */
static esp_err_t handleClassesPage(httpd_req_t *req)
{
    if (!auth(req)) return ESP_OK;
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, PAGE_CLASSES, sizeof(PAGE_CLASSES) - 1);
}

/* ------------------------------ logs -------------------------------- */
static esp_err_t handleLogsPage(httpd_req_t *req)
{
    if (!auth(req)) return ESP_OK;
    noStore(req);
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, PAGE_LOGS, sizeof(PAGE_LOGS) - 1);
}

static esp_err_t handleLogsData(httpd_req_t *req)
{
    static char buf[4096];
    static char hNext[16], hStart[16];
    char q[48], val[16];
    uint32_t start, next, from = 0;

    if (!auth(req)) return ESP_OK;
    if (httpd_req_get_url_query_str(req, q, sizeof(q)) == ESP_OK &&
        httpd_query_key_value(q, "from", val, sizeof(val)) == ESP_OK)
        from = strtoul(val, NULL, 10);
    size_t n = nodeLogRead(from, buf, sizeof(buf), &start, &next);
    snprintf(hNext, sizeof(hNext), "%lu", (unsigned long)next);
    snprintf(hStart, sizeof(hStart), "%lu", (unsigned long)start);
    noStore(req);
    httpd_resp_set_hdr(req, "X-Log-Next", hNext);
    httpd_resp_set_hdr(req, "X-Log-Start", hStart);
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    return httpd_resp_send(req, buf, n);
}

static esp_err_t handleLogsDownload(httpd_req_t *req)
{
    static char in[1024], out[1024];
    static char disp[112];
    uint32_t start, next, from;
    int esc = 0;                    /* 0 = text, 1 = got ESC, 2 = inside ESC[ ... */

    if (!auth(req)) return ESP_OK;
    snprintf(disp, sizeof(disp), "attachment; filename=\"%s_uptime%lus.log\"", host, (unsigned long)(millis() / 1000));
    httpd_resp_set_hdr(req, "Content-Disposition", disp);
    noStore(req);
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    nodeLogRead(0, in, 0, &start, &next);
    from = start;
    for (;;) {
        size_t n = nodeLogRead(from, in, sizeof(in), &start, &next), o = 0;
        if (!n) break;
        from = next;
        for (size_t i = 0; i < n; i++) {
            char ch = in[i];
            if (esc == 1) { esc = (ch == '[') ? 2 : 0; continue; }
            if (esc == 2) { if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) esc = 0; continue; }
            if (ch == 0x1b) { esc = 1; continue; }
            if (ch == '\r') continue;
            out[o++] = ch;
        }
        if (o && httpd_resp_send_chunk(req, out, o) != ESP_OK) return ESP_FAIL;
    }
    return httpd_resp_send_chunk(req, NULL, 0);
}

/* --------------------------- diagnostics ---------------------------- */
/* Network diagnostics (menu "Diagnósticos"), same as the gateway.
 * GET /diag     -> page (flash) + default host DIAG_DEFAULT_HOST and suggestions
 * GET /diag_run?t=ping|trace|dns&h=<host> -> result streamed line by line.
 * The HTTP server handles one request at a time, so only one test runs at once;
 * the raw ICMP socket exists only during the test (see node_diag.c). The
 * server runs on core 0, so a test never delays the LoRaWAN task (core 1). */
static void diagAddOpt(char *b, size_t size, const char *v)
{
    char key[DIAG_HOST_MAX + 20];
    size_t n = strlen(b);

    if (v == NULL || !diag_host_ok(v))
        return;
    snprintf(key, sizeof(key), "value='%s'", v);
    if (strstr(b, key) == NULL && n + strlen(key) + 10 < size)
        snprintf(b + n, size - n, "<option %s>", key);
}

static esp_err_t handleDiagPage(httpd_req_t *req)
{
    char opts[320] = "", router[16] = "";
    esp_netif_ip_info_t ipi;

    if (!auth(req)) return ESP_OK;
    if (s_sta && staUp && esp_netif_get_ip_info(s_sta, &ipi) == ESP_OK && ipi.gw.addr != 0)
        esp_ip4addr_ntoa(&ipi.gw, router, sizeof(router));

    diagAddOpt(opts, sizeof(opts), DIAG_DEFAULT_HOST);          /* ChirpStack (default) */
    diagAddOpt(opts, sizeof(opts), router[0] ? router : NULL);  /* Wi-Fi router */
    diagAddOpt(opts, sizeof(opts), "8.8.8.8");
    diagAddOpt(opts, sizeof(opts), "openwrt.org");

    noStore(req);
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_send_chunk(req, PAGE_DIAG_A, sizeof(PAGE_DIAG_A) - 1);
    httpd_resp_send_chunk(req, "value='" DIAG_DEFAULT_HOST "'><datalist id='sg'>", HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, opts, HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, "</datalist>", HTTPD_RESP_USE_STRLEN);
    httpd_resp_send_chunk(req, PAGE_DIAG_B, sizeof(PAGE_DIAG_B) - 1);
    return httpd_resp_send_chunk(req, NULL, 0);
}

static int diagOut(void *ctx, const char *line)
{
    return httpd_resp_send_chunk((httpd_req_t *)ctx, line, HTTPD_RESP_USE_STRLEN) != ESP_OK;
}

static esp_err_t handleDiagRun(httpd_req_t *req)
{
    char q[112], t[8] = "", h[DIAG_HOST_MAX + 1] = "";
    bool ok = false;

    if (!auth(req)) return ESP_OK;
    if (httpd_req_get_url_query_str(req, q, sizeof(q)) == ESP_OK &&
        httpd_query_key_value(q, "t", t, sizeof(t)) == ESP_OK &&
        httpd_query_key_value(q, "h", h, sizeof(h)) == ESP_OK) {
        char *r = h, *w = h;                     /* %3A -> ':' (IPv6 literal) */
        for (; *r; r++, w++) {
            if (r[0] == '%' && r[1] == '3' && (r[2] == 'A' || r[2] == 'a')) { *w = ':'; r += 2; }
            else *w = *r;
        }
        *w = '\0';
        ok = diag_host_ok(h) && (!strcmp(t, "ping") || !strcmp(t, "trace") || !strcmp(t, "dns"));
    }

    noStore(req);
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    httpd_resp_set_hdr(req, "X-Content-Type-Options", "nosniff");
    if (!ok) {
        httpd_resp_set_status(req, "400 Bad Request");
        return httpd_resp_sendstr(req, "teste ou destino inválido\n");
    }

    printf("[WEB] Diagnóstico: %s %s\r\n", t, h);
    if (!strcmp(t, "ping"))
        diag_ping(h, DIAG_PING_MAX, diagOut, req);
    else if (!strcmp(t, "trace"))
        diag_traceroute(h, diagOut, req);
    else
        diag_nslookup(h, diagOut, req);
    return httpd_resp_send_chunk(req, NULL, 0);
}

/* ----------------------------- logout ------------------------------- */
static esp_err_t handleLogout(httpd_req_t *req)
{
    if (!authAs(req, WEB_LOGOUT_USER, WEB_LOGOUT_PASS)) {
        send401(req);
        return ESP_OK;
    }
    noStore(req);
    httpd_resp_set_type(req, "text/plain");
    return httpd_resp_sendstr(req, "ok");
}

static esp_err_t handleLoggedOut(httpd_req_t *req)
{
    syncCfg();
    sendSimple(req, NULL, "<h2>Você saiu</h2><p>Para voltar à configuração do nó, entre de novo com usuário e senha.</p>"
                          "<form action='/' method='get'><button class='p'>Entrar novamente</button></form>"
                          "<p style='font-size:13px'>Se o navegador entrar direto sem pedir a senha, feche todas as janelas dele.</p>");
    return ESP_OK;
}

/* Captive portal: any unknown host while the Soft AP is on goes to the page. */
static esp_err_t handleNotFound(httpd_req_t *req, httpd_err_code_t code)
{
    if (apOn) {
        char h[64] = "", local[48];
        httpd_req_get_hdr_value_str(req, "Host", h, sizeof(h));
        snprintf(local, sizeof(local), "%s.local", host);
        if (strcmp(h, apIpStr) && strcmp(h, local)) {
            static char loc[40];
            snprintf(loc, sizeof(loc), "http://%s/", apIpStr);
            httpd_resp_set_status(req, "302 Found");
            httpd_resp_set_hdr(req, "Location", loc);
            httpd_resp_send(req, "", 0);
            return ESP_OK;
        }
    }
    httpd_resp_set_status(req, "404 Not Found");
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    httpd_resp_sendstr(req, "Página não encontrada.");
    return ESP_OK;
}

/* ===================================================================== */
/*                                  tasks                                */
/* ===================================================================== */
static void reg(const char *uri, httpd_method_t m, esp_err_t (*h)(httpd_req_t *))
{
    httpd_uri_t u;
    memset(&u, 0, sizeof(u));
    u.uri = uri;
    u.method = m;
    u.handler = h;
    httpd_register_uri_handler(s_server, &u);
}

static void serverStart(void)
{
    httpd_config_t c = HTTPD_DEFAULT_CONFIG();
    c.max_uri_handlers = 20;
    c.stack_size = 8192;
    c.core_id = 0;                       /* core 1 belongs to the LoRaWAN task */
    c.lru_purge_enable = true;
    if (httpd_start(&s_server, &c) != ESP_OK) {
        printf("[WEB] Falha ao iniciar o servidor web.\r\n");
        return;
    }
    reg("/", HTTP_GET, handleRoot);
    reg("/config.json", HTTP_GET, handleConfigJson);
    reg("/status", HTTP_GET, handleStatus);
    reg("/save", HTTP_POST, handleSave);
    reg("/action", HTTP_POST, handleAction);
    reg("/reboot", HTTP_POST, handleReboot);
    reg("/factory", HTTP_POST, handleFactory);
    reg("/logs", HTTP_GET, handleLogsPage);
    reg("/logs_data", HTTP_GET, handleLogsData);
    reg("/logs_download", HTTP_GET, handleLogsDownload);
    reg("/diag", HTTP_GET, handleDiagPage);
    reg("/diag_run", HTTP_GET, handleDiagRun);
    reg("/classes", HTTP_GET, handleClassesPage);
    reg("/logout", HTTP_GET, handleLogout);
    reg("/saiu", HTTP_GET, handleLoggedOut);
    reg("/favicon.svg", HTTP_GET, handleFavicon);
    reg("/favicon.ico", HTTP_GET, handleFavicon);
    reg("/info", HTTP_GET, handleInfo);
    httpd_register_err_handler(s_server, HTTPD_404_NOT_FOUND, handleNotFound);
}

static void supervisorTask(void *)
{
    for (;;) {
        if (forceApReq) {
            forceApReq = false;
            if (!apOn) {
                forcedAp = true;
                autoReconnect = false;
                startAp(staUp);
            } else {
                printf("[WEB] Soft AP \"%s\" já está ativo — http://%s/\r\n", apName, apIpStr);
            }
        }
        wifiSupervise();
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

static void startAll(void)
{
    taskRunning = true;
    wifiInit();
    wifiStart();
    serverStart();
    xTaskCreatePinnedToCore(supervisorTask, "node_wifi", 4096, NULL, 2, NULL, 0);
}

void nodeWebForceAp(void)
{
    printf("[WEB] Abrindo o Soft AP de configuração...\r\n");
    if (!taskRunning) {
        nodeCfgShared(&wcfg);
        cfgVerSeen = nodeCfgVersion();
        forcedAp = true;
        startAll();
    } else {
        forceApReq = true;
    }
}

void nodeWebBegin(bool forceAp)
{
    nodeCfgShared(&wcfg);
    cfgVerSeen = nodeCfgVersion();
    bootCfg  = wcfg;
    forcedAp = forceAp;
    nodeApSsid(&wcfg, apName, sizeof(apName));
    nodeHostname(&wcfg, host, sizeof(host));
    {
        esp_netif_ip_info_t ip;
        esp_netif_set_ip4_addr(&ip.ip, DEF_AP_IP);
        snprintf(apIpStr, sizeof(apIpStr), IPSTR, IP2STR(&ip.ip));
    }

    if (wcfg.wifiMode == NODE_WIFI_OFF && !forceAp) {
        printf("[WEB] Wi-Fi desligado (Inicialização). Segure o botão do Soft AP por 3 s, "
               "ou digite wifi_ap no console, para abrir o Soft AP.\r\n");
        return;
    }
    startAll();
}

void nodeWebPrintAccess(void)
{
    if (wcfg.wifiMode == NODE_WIFI_OFF && !forcedAp) return;
    if (forcedAp || wcfg.wifiMode == NODE_WIFI_AP || !wcfg.ssid[0])
        nodeLogSecret("[WEB] Página: conecte no Wi-Fi do Soft AP (senha oculta no log da web; "
                      "veja no console serial) e abra a página\r\n",
                      "[WEB] Página: conecte no Wi-Fi \"%s\" (senha %s) e abra http://%s/\r\n",
                      apName, wcfg.apPass, apIpStr);
    else
        printf("[WEB] Página: http://%s.local/ (ou o IP que aparecer abaixo). Sem Wi-Fi em %u s abre o Soft AP \"%s\".\r\n",
               host, wcfg.staTimeout, apName);
    if (wcfg.bootPin >= 0)
        printf("[WEB] Segure o GPIO %d em nível baixo por 3 s para abrir o Soft AP a qualquer momento.\r\n", wcfg.bootPin);
}
