/*
 * || Project:          IoT Energy Meter with C/C++/FreeRTOS, Java/Spring,
 * ||                   TypeScript/Angular and Dart/Flutter.
 * || About:            End-to-end LoRaWAN network for monitoring electrical quantities.
 * || Version:          0.0.1 (NODE_FW_VERSION, from the Git tag) — ESP-IDF, web configuration page
 * || Hardware:         ESP32 + RFM95W
 * || LoRaWAN Stack:    MCCI LMiC 6.0.1 (components/lmic, HAL for ESP-IDF)
 * || Network Server:   ChirpStack — AU915, sub-band 1 (ch 8–15 + 65)
 * || Activation:       OTAA
 * || Author:           Adail dos Santos Silva
 * || E-mail:           adail101@hotmail.com
 * || WhatsApp:         +55 89 9 9412-9256
 * ||
 * || NOTES:
 * ||   • Built with ESP-IDF only: scripts/build.sh esp32 flash /dev/ttyUSB0
 * ||   • Every parameter is set from the WEB PAGE of the node
 * ||     (http://<ip>/ or http://lorawan-node-otaa.local/, login admin/lorawan101)
 * ||     and kept in the NVS.
 * ||     node_build.h holds only the factory defaults.
 * ||
 * || SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "lmic/lmic.h"
#include "lmic_esp32.h"

#include "node_build.h"     /* ABP/OTAA + factory defaults             */
#include "node_config.h"    /* cfg: configuration kept in the NVS      */
#include "node_state.h"     /* status/commands shared with the web     */
#include "node_log.h"       /* printf -> console + RAM log for /logs   */
#include "node_web.h"       /* Wi-Fi + web server (core 0)             */

#if !NODE_ACTIVATION_OTAA
#error "This is the OTAA firmware: set NODE_ACTIVATION_OTAA 1 in node_build.h"
#endif

#ifdef CONFIG_ESP_CONSOLE_UART_NUM
#define CONSOLE_UART ((uart_port_t)CONFIG_ESP_CONSOLE_UART_NUM)
#else
#define CONSOLE_UART UART_NUM_0
#endif

/* Region of this LMiC build (components/lmic/project_config) — shown on the page. */
#if defined(CFG_au915)
const char *NODE_REGION = "AU915";
#elif defined(CFG_us915)
const char *NODE_REGION = "US915";
#elif defined(CFG_eu868)
const char *NODE_REGION = "EU868";
#elif defined(CFG_as923)
const char *NODE_REGION = "AS923";
#elif defined(CFG_kr920)
const char *NODE_REGION = "KR920";
#elif defined(CFG_in866)
const char *NODE_REGION = "IN866";
#else
const char *NODE_REGION = "?";
#endif

static uint32_t millis(void) { return (uint32_t)(esp_timer_get_time() / 1000); }

/* ------------------------------------------------------------------ */
/* Pin map — from the configuration (page → Hardware)                 */
/* ------------------------------------------------------------------ */
static lmic_esp32_pins_t pins;

/* ------------------------------------------------------------------ */
/* LoRaWAN credentials — OTAA (ChirpStack AU915, sub-band 1)          */
/* DevEUI, JoinEUI (AppEUI) and AppKey come from cfg (page → Ativação */
/* OTAA), typed MSB first exactly as ChirpStack shows them.           */
/*                                                                    */
/* Byte order: the LMiC copies os_getDevEui()/os_getArtEui() as they  */
/* are into the Join Request, and LoRaWAN carries EUIs LSB first.     */
/*   cfg.euiReverse = 0 → bytes as typed (original behaviour); the    */
/*                        network server sees the EUI reversed.       */
/*   cfg.euiReverse = 1 → reversed (MCCI standard); the server sees   */
/*                        exactly the EUI typed on the page.          */
/* The AppKey is always MSB (it is a key, not a number).              */
/* ------------------------------------------------------------------ */
static void copyEui(u1_t *buf, const uint8_t *eui)
{
    for (int i = 0; i < 8; i++)
        buf[i] = cfg.euiReverse ? eui[7 - i] : eui[i];
}

extern "C" void os_getArtEui(u1_t *buf) { copyEui(buf, cfg.joinEui); }
extern "C" void os_getDevEui(u1_t *buf) { copyEui(buf, cfg.devEui); }
extern "C" void os_getDevKey(u1_t *buf) { memcpy(buf, cfg.appKey, 16); }

/* LMiC job handle for the periodic uplink. */
static osjob_t txjob;

/* false if os_init_ex() failed (wrong pins): the page keeps working. */
static bool lmicOk;

/* Radio watchdog counters (see radioWatchdog; shown by the console "status"). */
static uint32_t radioRecoveries;      /* since boot */
static char     radioLastWhy[64];
static uint32_t radioLastMs;

static void do_send(osjob_t *j);
static void handleCommands(void);
static void consolePoll(void);
static void bootButtonPoll(void);

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */
static void printKey(const uint8_t *key, size_t len)
{
    for (size_t i = 0; i < len; ++i)
        printf(i ? "-%02X" : "%02X", key[i]);
    printf("\r\n");
}

/* Session key (NwkSKey/AppSKey): always printed in full, on the serial
 * console AND in the web log (/logs, .log download), so every log shows the
 * keys currently in use (they change on every JOIN / ABP reactivation).
 * sep = "-" or "". */
static void printSecretKey(const char *label, const uint8_t *key, size_t len, const char *sep)
{
    char hex[16 * 3 + 1];
    size_t n = 0;
    for (size_t i = 0; i < len && n + 4 < sizeof(hex); ++i)
        n += snprintf(hex + n, sizeof(hex) - n, (i && *sep) ? "-%02X" : "%02X", key[i]);
    printf("%s%s\r\n", label, hex);
}

/* Print the session keys obtained after a successful JOIN. */
static void printSessionKeys(void)
{
    u4_t      netid   = 0;
    devaddr_t devaddr = 0;
    u1_t      nwkKey[16];
    u1_t      artKey[16];

    LMIC_getSessionKeys(&netid, &devaddr, nwkKey, artKey);
    /* Display order (all logs, page and app): DevAddr, NwkSKey, AppSKey. */
    printf("  DevAddr : 0x%08lX\r\n", (unsigned long)devaddr);
    printSecretKey("  NwkSKey : ", nwkKey, sizeof(nwkKey), "-");
    printSecretKey("  AppSKey : ", artKey, sizeof(artKey), "-");
    printf("  NetID   : %lu\r\n", (unsigned long)netid);
}

/* Publish the session keys derived by this JOIN for the page / app
 * (status snapshot). Called from the LMiC loop only. */
static void publishSessionKeys(void)
{
    u4_t      netid   = 0;
    devaddr_t devaddr = 0;
    u1_t      nwkKey[16];
    u1_t      artKey[16];

    LMIC_getSessionKeys(&netid, &devaddr, nwkKey, artKey);
    nodeStatusLock();
    {
        NodeStatus *s = nodeStatusRaw();
        memcpy(s->nwkSKey, nwkKey, 16);
        memcpy(s->appSKey, artKey, 16);
        s->keysValid = true;
        s->sessionMs = millis();
    }
    nodeStatusUnlock();
}

/* Print the OTAA identity used for the JOIN. */
static void printJoinIds(void)
{
    u1_t b[8];
    printf("  DevEUI  (page): "); printKey(cfg.devEui, 8);
    printf("  JoinEUI (page): "); printKey(cfg.joinEui, 8);
    os_getDevEui(b);
    printf("  DevEUI as the server receives it: ");
    for (int i = 7; i >= 0; i--) printf("%02X", b[i]);
    printf(cfg.euiReverse ? "  (byte order: LSB / MCCI)\r\n" : "  (byte order: as typed)\r\n");
}

/* Record the last LMiC event for the web status panel. */
static void stEvent(const char *name)
{
    nodeStatusLock();
    NodeStatus *s = nodeStatusRaw();
    strlcpy(s->lastEvent, name, sizeof(s->lastEvent));
    s->lastEventMs = millis();
    s->txPending   = lmicOk && (LMIC.opmode & OP_TXRXPEND) != 0;
    nodeStatusUnlock();
}

/* Schedule the next uplink cfg.txInterval seconds from now. */
static void scheduleNext(void)
{
    os_setTimedCallback(&txjob, os_getTime() + sec2osticks(cfg.txInterval), do_send);
    nodeStatusLock();
    nodeStatusRaw()->nextTxMs = millis() + cfg.txInterval * 1000UL;
    nodeStatusUnlock();
}

/* ------------------------------------------------------------------ */
/* Remote reset command — downlink on cfg.rstPort with exactly        */
/* cfg.rstCmd (factory: AD A1 DE AD BE EF 0D 0A on FPort 101).        */
/* ------------------------------------------------------------------ */
static bool isResetCommand(const uint8_t *data, uint8_t len)
{
    if (len != cfg.rstLen) return false;
    return memcmp(data, cfg.rstCmd, cfg.rstLen) == 0;
}

static void flushConsole(void)
{
    fflush(stdout);
    uart_wait_tx_done(CONSOLE_UART, pdMS_TO_TICKS(500));
}

static void handleDownlink(void)
{
    if (LMIC.dataLen == 0) return;

    uint8_t  fport = LMIC.frame[LMIC.dataBeg - 1];
    uint8_t  len   = LMIC.dataLen;
    uint8_t *data  = &LMIC.frame[LMIC.dataBeg];

    nodeStatusLock();
    NodeStatus *s = nodeStatusRaw();
    s->dnCount++;
    s->lastDnMs   = millis();
    s->lastDnPort = fport;
    s->lastDnLen  = len;
    memcpy(s->lastDn, data, len < sizeof(s->lastDn) ? len : sizeof(s->lastDn));
    s->rssi       = LMIC.rssi - RSSI_OFF;
    s->snr        = LMIC.snr / 4;
    nodeStatusUnlock();

    /* payload, port, frequency, RSSI and SNR are in the [RX] line (logDownlink) */

    if (cfg.rstEnable && fport == cfg.rstPort) {
        printf("  [RESET PORT] Command received on FPort %u — validating...\r\n", cfg.rstPort);
        if (isResetCommand(data, len)) {
            printf("  [RESET] Valid reset command — rebooting in %u ms...\r\n", cfg.rstDelay);
            flushConsole();
            vTaskDelay(pdMS_TO_TICKS(cfg.rstDelay));
            esp_restart();
        } else {
            printf("  [RESET] Invalid payload — command ignored.\r\n  Expected: ");
            for (uint8_t i = 0; i < cfg.rstLen; ++i) printf(i < cfg.rstLen - 1 ? "%02X " : "%02X", cfg.rstCmd[i]);
            printf("\r\n  Received: ");
            for (uint8_t i = 0; i < len; ++i) printf(i < len - 1 ? "%02X " : "%02X", data[i]);
            printf("\r\n");
        }
    }
}

/* ================================================================== */
/* Node log — same lines, in the same order, as the Radioenge node    */
/* (LoRaMac-node) firmware:                                           */
/*                                                                    */
/* Uplink                                                             */
/*   EV_TXSTART                                                       */
/*   LMiC DevAddr / NwkSKey / AppSKey   ┐                             */
/*   Frame raw: … (as it goes on air)   │ session diagnostics         */
/*   FCnt/up: <FCnt of this frame>      │ (verbose 1)                 */
/*   FCnt/down: <last downlink FCnt>    │                             */
/*     MIC: …                           ┘                             */
/*   Packet queued.                                                   */
/*   EV_TXCOMPLETE (includes waiting for RX windows)                  */
/*   [TX] FCnt · tipo · DR · MHz · dBm · canal · porta · bytes · ACK  */
/*                                                                    */
/* Downlink (after the [TX] of the uplink that opened the window)     */
/*   [RX] RX1/RX2 · DR · MHz · porta · bytes HEX · RSSI · SNR · FCnt  */
/*   RX:<hex>:<rssi>:<snr>              (same as the Radioenge AT fw)  */
/*   Frame raw (RX): … (as it came, ┐                                 */
/*   FCnt/down (quadro): …          │ session diagnostics (verbose 1)  */
/*     MIC: …                       ┘                                 */
/*                                                                    */
/* The uplink line is printed on EV_TXCOMPLETE with the parameters    */
/* captured on EV_TXSTART. The downlink frequency / DR / RSSI / SNR   */
/* and the encrypted frame come from lmic_node_rx_hook(), called by   */
/* the LMiC radio driver on every LoRa RxDone (the LMiC does NOT pass */
/* EV_RXSTART to onEvent, and decrypts the payload in place).         */
/* ================================================================== */

/* "917,8 MHz" — 100 kHz resolution (AU915: 915,2 + n·0,2 / 915,9 + n·1,6
 * up, 923,3 + n·0,6 down). */
static void printMHz(uint32_t hz)
{
    printf("%lu,%lu MHz", (unsigned long)(hz / 1000000UL), (unsigned long)((hz / 100000UL) % 10UL));
}

static void printRaw(const char *label, const uint8_t *f, uint8_t n)
{
    printf("%s", label);
    for (uint8_t i = 0; i < n; i++) printf("%02X ", f[i]);
    printf("\r\n");
}

static void printMic(const uint8_t *f, uint8_t n)
{
    if (n >= 4) printf("  MIC: %02X-%02X-%02X-%02X\r\n", f[n - 4], f[n - 3], f[n - 2], f[n - 1]);
}

/* EUI as it travels (LSB first) printed the way ChirpStack shows it */
static void printEuiLe(const char *label, const uint8_t *p)
{
    printf("%s", label);
    for (int i = 7; i >= 0; i--) printf("%02X", p[i]);
    printf("\r\n");
}

/* AU915 (and US915) data rate from the radio parameters of a frame:
 * 125 kHz SF12..SF7 = DR0..DR5, 500 kHz SF12..SF7 = DR8..DR13. */
static uint8_t drFromRps(rps_t rps)
{
    int sf = (int)getSf(rps);                 /* SF7 = 1 … SF12 = 6 */
    if (sf < (int)SF7 || sf > (int)SF12) return 0;
    return (getBw(rps) == BW500) ? (uint8_t)(8 + (int)SF12 - sf) : (uint8_t)((int)SF12 - sf);
}

/* --- last frame received by the radio (filled by the hook) --------- */
static uint8_t           rxRaw[256];
static volatile uint8_t  rxRawLen  = 0;
static volatile uint32_t rxRawFreq = 0;
static volatile uint8_t  rxRawDr   = 0;
static volatile int8_t   rxRawRssi = 0;
static volatile int8_t   rxRawSnr  = 0;
static volatile bool     rxRawOk   = false;

extern "C" void lmic_node_rx_hook(const u1_t *frame, u1_t len, u4_t freq, rps_t rps, s1_t rssi, s1_t snr)
{
    memcpy(rxRaw, frame, len);
    rxRawLen  = len;
    rxRawFreq = freq;
    rxRawDr   = drFromRps(rps);
    rxRawRssi = rssi;
    rxRawSnr  = snr;
    rxRawOk   = true;
}

/* --- the uplink on air (captured on EV_TXSTART) --------------------- */
static struct {
    bool     valid, join, conf, data;
    uint32_t freq, fcnt;
    uint8_t  dr, chnl, port, len, retry;
    int8_t   pw;
} upl;

static void captureUplink(void)
{
    upl.valid = true;
    upl.join  = (LMIC.opmode & OP_JOINING) != 0;
    upl.freq  = LMIC.freq;
    upl.dr    = LMIC.dndr;                    /* TX datarate (LMiC: "carry TX datarate") */
    upl.chnl  = LMIC.txChnl;
    upl.pw    = (LMIC.txpow > LMIC.adrTxPow) ? LMIC.adrTxPow : LMIC.txpow;   /* what goes to the radio */
    upl.fcnt  = LMIC.seqnoUp - 1;             /* the frame carries seqnoUp - 1 */
    upl.conf  = LMIC.pendTxConf != 0;
    upl.data  = (LMIC.opmode & OP_TXDATA) != 0;
    upl.port  = LMIC.pendTxPort;
    upl.len   = LMIC.pendTxLen;
    upl.retry = LMIC.txCnt;
    rxRawOk   = false;                        /* new uplink: no downlink yet */
}

/* EV_TXSTART — header and session diagnostics (verbose 1). */
static void logTxStart(void)
{
    const uint8_t *f = LMIC.frame;
    uint8_t n = (uint8_t)(LMIC.dataBeg + LMIC.dataLen);

    if (upl.join) {
        /* Join-request: MHDR | JoinEUI | DevEUI | DevNonce | MIC (no session yet) */
        printf("\r\nEV_TXSTART (Join-request)\r\n");
        if (!cfg.verbose) return;
        n = LMIC.dataLen;                     /* LEN_JR = 23 */
        if (n >= 19) {
            printEuiLe("LMiC JoinEUI: ", f + 1);
            printEuiLe("LMiC DevEUI : ", f + 9);
            printf("LMiC DevNonce: %u\r\n\r\n", (unsigned)(f[17] | (f[18] << 8)));
        }
        printRaw("Frame raw: ", f, n);
        printMic(f, n);
        return;
    }

    printf("\r\nEV_TXSTART\r\n");
    if (!cfg.verbose) { printf("Packet queued.\r\n"); return; }
    /* Display order (all logs, page and app): DevAddr, NwkSKey, AppSKey. */
    /* OTAA: the keys derived by the JOIN live in the LMiC secure element;
     * LMIC.nwkKey/artKey are NOT updated by the JOIN, so read the session in
     * use through LMIC_getSessionKeys() (always the current keys). */
    u4_t      sNetid   = 0;
    devaddr_t sDevaddr = 0;
    u1_t      sNwk[16];
    u1_t      sApp[16];
    LMIC_getSessionKeys(&sNetid, &sDevaddr, sNwk, sApp);
    printf("LMiC DevAddr: 0x%08lX\r\n", (unsigned long)sDevaddr);
    printSecretKey("LMiC NwkSKey: ", sNwk, 16, "");
    printSecretKey("LMiC AppSKey: ", sApp, 16, "");
    printf("\r\n");
    printRaw("Frame raw: ", f, n);
    /* FCnt/up = FCnt of this frame; FCnt/down = last downlink received
     * (the LMiC keeps the NEXT expected value in seqnoDn). */
    printf("FCnt/up: %lu\r\n", (unsigned long)upl.fcnt);
    if (LMIC.seqnoDn != 0)
        printf("FCnt/down: %lu\r\n", (unsigned long)(LMIC.seqnoDn - 1));
    else
        printf("FCnt/down: - (nenhum downlink nesta sessão)\r\n");
    printMic(f, n);
    printf("Packet queued.\r\n");
}

/* [TX] line — on EV_TXCOMPLETE / EV_JOIN_TXCOMPLETE / EV_JOINED. */
static void logUplink(void)
{
    if (!upl.valid) return;
    if (upl.join) {
        printf("[TX] JoinRequest · DR%u · ", (unsigned)upl.dr);
        printMHz(upl.freq);
        printf(" · %d dBm · canal %u\r\n", (int)upl.pw, (unsigned)upl.chnl);
        return;
    }
    printf("[TX] FCnt %lu · %s · DR%u · ", (unsigned long)upl.fcnt,
           upl.conf ? "confirmado" : "não confirmado", (unsigned)upl.dr);
    printMHz(upl.freq);
    printf(" · %d dBm · canal %u", (int)upl.pw, (unsigned)upl.chnl);
    if (upl.data)
        printf(" · porta %u · %u bytes", (unsigned)upl.port, (unsigned)upl.len);
    else
        printf(" · sem payload (só comandos MAC)");
    if (upl.retry) printf(" · retransmissão %u", (unsigned)upl.retry);
    if (upl.conf) printf((LMIC.txrxFlags & TXRX_ACK) ? " · ACK" : " · sem ACK");
    printf("\r\n");
}

static const char *rxWindowName(void)
{
    if (LMIC.txrxFlags & TXRX_DNW1) return "RX1";
    if (LMIC.txrxFlags & TXRX_DNW2) return "RX2";
    return "RX";
}

/* [RX] + RX: + Frame raw (RX) — data downlink, on EV_TXCOMPLETE. */
static void logDownlink(void)
{
    if ((LMIC.txrxFlags & (TXRX_DNW1 | TXRX_DNW2)) == 0) return;   /* nothing received */

    uint8_t  port = (LMIC.txrxFlags & TXRX_PORT) ? LMIC.frame[LMIC.dataBeg - 1] : 0;
    uint8_t  len  = LMIC.dataLen;
    const uint8_t *d = &LMIC.frame[LMIC.dataBeg];        /* decrypted payload */
    uint8_t  shown = len > 32 ? 32 : len;
    int      rssi  = rxRawOk ? rxRawRssi : (int)(LMIC.rssi - RSSI_OFF);
    int      snr   = rxRawOk ? rxRawSnr  : (int)(LMIC.snr / 4);

    printf("[RX] %s · DR%u · ", rxWindowName(), (unsigned)(rxRawOk ? rxRawDr : 0));
    printMHz(rxRawOk ? rxRawFreq : 0);
    printf(" · porta %u · %u bytes", (unsigned)port, (unsigned)len);
    if (len) {
        printf(" ");
        for (uint8_t i = 0; i < shown; ++i) printf("%02X", d[i]);
        if (len > 32) printf("…");
    }
    printf(" · RSSI %d dBm · SNR %d dB · FCntDown %lu\r\n", rssi, snr,
           (unsigned long)(LMIC.seqnoDn - 1));

    /* Same as the Radioenge firmware (original AT format): RX:<hex>:<RSSI>:<SNR> */
    printf("RX:");
    for (uint8_t i = 0; i < len; ++i) printf("%02x", d[i]);
    printf(":%d:%d\r\n", rssi, snr);

    if (cfg.verbose && rxRawOk && rxRawLen) {
        printf("\r\n");                       /* separates the received frame */
        printRaw("Frame raw (RX): ", rxRaw, rxRawLen);
        if (rxRawLen >= 8)
            printf("FCnt/down (quadro): %u\r\n", (unsigned)(rxRaw[6] | (rxRaw[7] << 8)));
        printMic(rxRaw, rxRawLen);
    }
}

/* [RX] JoinAccept + Frame raw (RX, Join-accept cifrado) — on EV_JOINED. */
static void logJoinAccept(void)
{
    printf("[RX] JoinAccept · %s · DR%u · ", rxWindowName(), (unsigned)(rxRawOk ? rxRawDr : 0));
    printMHz(rxRawOk ? rxRawFreq : 0);
    printf(" · RSSI %d dBm · SNR %d dB\r\n",
           rxRawOk ? rxRawRssi : (int)(LMIC.rssi - RSSI_OFF), rxRawOk ? rxRawSnr : (int)(LMIC.snr / 4));
    if (cfg.verbose && rxRawOk && rxRawLen) {
        printf("\r\n");
        printRaw("Frame raw (RX, Join-accept cifrado): ", rxRaw, rxRawLen);
    }
}

/* ------------------------------------------------------------------ */
/* LMiC event handler                                                 */
/* ------------------------------------------------------------------ */
extern "C" void onEvent(ev_t ev)
{
    switch (ev) {
    case EV_JOINING:
        printf("EV_JOINING\r\n");
        printJoinIds();
        stEvent("EV_JOINING");
        break;

    case EV_JOIN_TXCOMPLETE:
        /* No JoinAccept received in the join windows — LMiC will retry. */
        printf("EV_JOIN_TXCOMPLETE: no JoinAccept\r\n");
        logUplink();                        /* [TX] JoinRequest */
        stEvent("EV_JOIN_TXCOMPLETE");
        break;

    case EV_JOIN_FAILED:     printf("EV_JOIN_FAILED\r\n");   stEvent("EV_JOIN_FAILED"); break;
    case EV_REJOIN_FAILED:   printf("EV_REJOIN_FAILED\r\n"); stEvent("EV_REJOIN_FAILED"); break;

    case EV_JOINED:
        printf("EV_JOINED\r\n");
        logUplink();                        /* [TX] JoinRequest */
        logJoinAccept();                    /* [RX] JoinAccept  */
        printSessionKeys();
        /* The JOIN re-enables link check and forces the join DR (DR2 in
         * AU915): re-apply what the page says (with ADR on it is only the
         * starting point). */
        LMIC_setLinkCheckMode(cfg.linkCheck);
        LMIC_setDrTxpow((dr_t)cfg.dr, cfg.txPow);
        nodeStatusLock();
        {
            NodeStatus *s = nodeStatusRaw();
            s->dr      = cfg.dr;
            s->txPow   = cfg.txPow;
            s->joined  = true;
            s->devAddr = LMIC.devaddr;
            s->netId   = LMIC.netid;
            s->fcntUp  = LMIC.seqnoUp;
            s->fcntDn  = LMIC.seqnoDn;
        }
        nodeStatusUnlock();
        publishSessionKeys();               /* new keys for this JOIN */
        stEvent("EV_JOINED");
        break;

    case EV_TXSTART:
        captureUplink();
        logTxStart();
        nodeStatusLock();
        {
            NodeStatus *s = nodeStatusRaw();
            s->freq  = LMIC.freq;
            s->dr    = LMIC.datarate;
            s->txPow = LMIC.txpow;
            s->nextTxMs = 0;
            if (LMIC.opmode & OP_JOINING) s->joinTries++;
        }
        nodeStatusUnlock();
        stEvent("EV_TXSTART");
        break;

    case EV_RXSTART:
        /* Never delivered by the MCCI LMiC (filtered in reportEventNoUpdate,
         * timing-critical); the downlink data comes from lmic_node_rx_hook(). */
        break;

    case EV_TXCOMPLETE:
        printf("EV_TXCOMPLETE (includes waiting for RX windows)\r\n");
        logUplink();                        /* [TX] (ACK / sem ACK at the end) */
        logDownlink();                      /* [RX], RX:, Frame raw (RX)     */
        nodeStatusLock();
        {
            NodeStatus *s = nodeStatusRaw();
            s->upCount++;
            if (LMIC.txrxFlags & TXRX_ACK) s->ackCount++;
            s->lastTxMs = millis();
            s->fcntUp   = LMIC.seqnoUp;
            s->fcntDn   = LMIC.seqnoDn;
        }
        nodeStatusUnlock();
        handleDownlink();
        scheduleNext();
        stEvent("EV_TXCOMPLETE");
        break;

    case EV_TXCANCELED:  printf("EV_TXCANCELED\r\n");  stEvent("EV_TXCANCELED"); break;
    case EV_LINK_DEAD:   printf("EV_LINK_DEAD\r\n");   stEvent("EV_LINK_DEAD"); break;
    case EV_LINK_ALIVE:  printf("EV_LINK_ALIVE\r\n");  stEvent("EV_LINK_ALIVE"); break;
    case EV_RESET:       printf("EV_RESET\r\n");       stEvent("EV_RESET"); break;
    case EV_RXCOMPLETE:  printf("EV_RXCOMPLETE\r\n");  stEvent("EV_RXCOMPLETE"); break;
    case EV_SCAN_TIMEOUT:   printf("EV_SCAN_TIMEOUT\r\n");   break;
    case EV_BEACON_FOUND:   printf("EV_BEACON_FOUND\r\n");   break;
    case EV_BEACON_MISSED:  printf("EV_BEACON_MISSED\r\n");  break;
    case EV_BEACON_TRACKED: printf("EV_BEACON_TRACKED\r\n"); break;
    case EV_LOST_TSYNC:     printf("EV_LOST_TSYNC\r\n");     break;
    default:
        printf("Unknown event: %u\r\n", (unsigned)ev);
        break;
    }
}

/* ------------------------------------------------------------------ */
/* Uplink                                                             */
/* ------------------------------------------------------------------ */
static void do_send(osjob_t *j)
{
    (void)j;
    if (LMIC.opmode & OP_TXRXPEND) {
        printf("OP_TXRXPEND — previous job still running, skipping.\r\n");
        return;
    }
    /* TODO: read real sensor data into cfg.payload before calling setTxData2. */
    LMIC_setTxData2(cfg.fport, cfg.payload, cfg.payloadLen, cfg.confirmed);
    /* "Packet queued." is printed with the EV_TXSTART block (same place as
     * in the Radioenge firmware), so the order never changes. */
    stEvent("Packet queued");
}

/* Radio parameters that can change at any time (no session reset). */
static void applyRadioLive(void)
{
    LMIC_setAdrMode(cfg.adr);
    LMIC_setLinkCheckMode(cfg.linkCheck);
    LMIC_setDrTxpow((dr_t)cfg.dr, cfg.txPow);
    LMIC_setClockError(MAX_CLOCK_ERROR * cfg.clockErr / 100);
}

/* (Re)start the LoRaWAN stack with the current cfg.
 * The first do_send() also triggers the OTAA JOIN. */
static void lmicStart(void)
{
    os_clearCallback(&txjob);
    LMIC_reset();

#if CFG_LMIC_US_like
    /* AU915 sub-band / 500 kHz channel / custom list from the page. */
    uint8_t mask[9];
    int n = nodeChannelMask(&cfg, mask);
    for (u1_t b  = 0; b  <  8; ++b)  LMIC_disableSubBand(b);
    for (u1_t ch = 0; ch < 72; ++ch) LMIC_disableChannel(ch);
    for (u1_t ch = 0; ch < 72; ++ch)
        if (mask[ch >> 3] & (1 << (ch & 7))) LMIC_enableChannel(ch);
    printf("  Channels: %d enabled (%s)\r\n", n, cfg.chList[0] ? cfg.chList : "sub-band from config");
#endif

    applyRadioLive();

    /* RX2 window — AU915/ChirpStack default 923.3 MHz, DR8 (SF12/BW500).
     * The JOIN Accept sets it in OTAA; defined here as a safeguard. */
    LMIC.dn2Dr = cfg.rx2Dr;
    if (cfg.rx2Freq) LMIC.dn2Freq = cfg.rx2Freq;

    nodeStatusLock();
    {
        NodeStatus *s = nodeStatusRaw();
        s->joined  = false;
        s->devAddr = 0;
        s->netId   = 0;
        /* old session is gone: the next JOIN derives new keys */
        s->keysValid = false;
        memset(s->nwkSKey, 0, 16);
        memset(s->appSKey, 0, 16);
        s->sessionMs = 0;
        s->fcntUp  = LMIC.seqnoUp;
        s->fcntDn  = LMIC.seqnoDn;
        s->dr      = cfg.dr;
        s->txPow   = cfg.txPow;
    }
    nodeStatusUnlock();

    do_send(&txjob);                        /* first uplink — also starts the JOIN */
}

/* ------------------------------------------------------------------ */
/* Commands from the web page / new configuration — executed only     */
/* when no TX/RX is in progress (the LMiC is not reentrant).          */
/* ------------------------------------------------------------------ */
static uint32_t deferredCmd;

static bool activationChanged(const NodeConfig &a, const NodeConfig &b)
{
    return memcmp(a.devEui, b.devEui, 8) || memcmp(a.joinEui, b.joinEui, 8) ||
           memcmp(a.appKey, b.appKey, 16) || a.euiReverse != b.euiReverse ||
           a.subBand != b.subBand || a.ch500 != b.ch500 || strcmp(a.chList, b.chList) ||
           a.rx2Dr != b.rx2Dr || a.rx2Freq != b.rx2Freq;
}

static bool radioChanged(const NodeConfig &a, const NodeConfig &b)
{
    return a.adr != b.adr || a.dr != b.dr || a.txPow != b.txPow ||
           a.linkCheck != b.linkCheck || a.clockErr != b.clockErr;
}

static void setConsoleBaud(uint32_t baud)
{
    static uint32_t current = 115200;
    if (baud == current) return;
    printf("[LOG] Console serial: %lu bps (página → Hardware → Velocidade da serial).\r\n", (unsigned long)baud);
    flushConsole();
    uart_set_baudrate(CONSOLE_UART, baud);
    current = baud;
}

static void handleCommands(void)
{
    uint32_t arg = 0;
    uint32_t cmd = nodeCmdTake(&arg) | deferredCmd;
    (void)arg;                              /* NODE_CMD_SET_FCNT is ABP only */
    deferredCmd = 0;
    if (!cmd) return;

    if (cmd & NODE_CMD_REBOOT) {
        printf("Rebooting (requested by the web page)...\r\n");
        flushConsole();
        vTaskDelay(pdMS_TO_TICKS(100));
        esp_restart();
    }

    if (!lmicOk) {                          /* only the reboot works */
        NodeConfig n;
        if (nodeCfgTake(&n)) cfg = n;
        return;
    }

    if (LMIC.opmode & OP_TXRXPEND) {        /* try again after this TX/RX */
        deferredCmd = cmd;
        return;
    }

    if (cmd & NODE_CMD_APPLY) {
        NodeConfig n;
        if (nodeCfgTake(&n)) {
            NodeConfig old = cfg;
            cfg = n;
            printf("[CFG] New configuration from the web page.\r\n");
            if (activationChanged(old, n)) {
                printf("[CFG] Keys/channels changed — new JOIN.\r\n");
                lmicStart();
                cmd &= ~(NODE_CMD_RESTART | NODE_CMD_SEND_NOW);
            } else {
                if (radioChanged(old, n)) {
                    applyRadioLive();
                    printf("[CFG] Radio parameters applied.\r\n");
                }
                if (old.txInterval != n.txInterval) {
                    NodeStatus s;
                    nodeStatusGet(&s);
                    if (s.nextTxMs) scheduleNext();
                    printf("[CFG] Uplink interval: %lu s\r\n", (unsigned long)cfg.txInterval);
                }
            }
        }
    }

    if (cmd & NODE_CMD_RESTART) {
        printf("[CMD] New JOIN requested by the web page.\r\n");
        lmicStart();
    } else if (cmd & NODE_CMD_SEND_NOW) {
        printf("[CMD] Uplink requested by the web page.\r\n");
        os_clearCallback(&txjob);
        do_send(&txjob);
    }
}

/* ------------------------------------------------------------------ */
/* Serial console (idf.py monitor / any terminal, Enter = new line)   */
/* ------------------------------------------------------------------ */
static void consoleHelp(void)
{
    printf("Comandos: help | status | keys | wifi_ap | web_auth --reset | send | rejoin | cfg_reset | reboot\r\n");
}

static void consoleExec(char *line)
{
    while (*line == ' ') line++;
    if (!*line) return;
    printf("> %s\r\n", line);

    if (!strcmp(line, "help")) {
        consoleHelp();
    } else if (!strcmp(line, "status")) {
        NodeStatus s;
        nodeStatusGet(&s);
        printf("OTAA %s DevAddr %08lX  FCnt up %lu  dn %lu  uplinks %lu  downlinks %lu  heap %lu\r\n",
               s.joined ? "joined" : "NOT joined", (unsigned long)s.devAddr,
               (unsigned long)s.fcntUp, (unsigned long)s.fcntDn, (unsigned long)s.upCount,
               (unsigned long)s.dnCount, (unsigned long)esp_get_free_heap_size());
        if (radioRecoveries)
            printf("Radio: %lu recovery(ies) since boot, last %lu s ago (%s); lost IRQs delivered by level: %lu\r\n",
                   (unsigned long)radioRecoveries, (unsigned long)((millis() - radioLastMs) / 1000), radioLastWhy,
                   (unsigned long)lmic_esp32_missed_irqs());
        else
            printf("Radio: OK, no recovery since boot; lost IRQs delivered by level: %lu\r\n",
                   (unsigned long)lmic_esp32_missed_irqs());
        nodeWebPrintAccess();
    } else if (!strcmp(line, "keys")) {
        NodeStatus s;
        nodeStatusGet(&s);
        if (!s.keysValid) {
            printf("Sem sessão: as chaves são derivadas quando o JOIN é aceito.\r\n");
        } else {
            printf("Chaves da sessão OTAA (derivadas no último JOIN, há %lu s):\r\n",
                   (unsigned long)((millis() - s.sessionMs) / 1000));
            printf("  DevAddr : %08lX\r\n", (unsigned long)s.devAddr);
            printSecretKey("  NwkSKey : ", s.nwkSKey, 16, "-");
            printSecretKey("  AppSKey : ", s.appSKey, 16, "-");
        }
    } else if (!strcmp(line, "wifi_ap")) {
        nodeWebForceAp();
    } else if (!strcmp(line, "web_auth --reset")) {
        strlcpy(cfg.webUser, DEF_WEB_USER, sizeof(cfg.webUser));
        strlcpy(cfg.webPass, DEF_WEB_PASS, sizeof(cfg.webPass));
        nodeConfigSave(&cfg);
        nodeCfgSetShared(&cfg);
        printf("Login da página: " DEF_WEB_USER " / " DEF_WEB_PASS " (já vale).\r\n");
    } else if (!strcmp(line, "rejoin")) {
        nodeCmdPost(NODE_CMD_RESTART);
    } else if (!strcmp(line, "send")) {
        nodeCmdPost(NODE_CMD_SEND_NOW);
    } else if (!strcmp(line, "cfg_reset")) {
        printf("Configuração apagada — reiniciando com o padrão de fábrica.\r\n");
        nodeConfigErase();
        nodeCmdPost(NODE_CMD_REBOOT);
    } else if (!strcmp(line, "reboot")) {
        nodeCmdPost(NODE_CMD_REBOOT);
    } else {
        printf("Comando desconhecido.\r\n");
        consoleHelp();
    }
}

static void consolePoll(void)
{
    static char buf[48];
    static uint8_t n;
    uint8_t c;
    while (uart_read_bytes(CONSOLE_UART, &c, 1, 0) == 1) {
        if (c == '\r' || c == '\n') {
            buf[n] = 0;
            if (n) consoleExec(buf);
            n = 0;
        } else if (n < sizeof(buf) - 1) {
            buf[n++] = (char)c;
        }
    }
}

/* BOOT button held 3 s -> Soft AP (GPIO 0 must NOT be held at power-on). */
static void bootButtonPoll(void)
{
    static uint32_t downSince;
    static bool fired;
    if (cfg.bootPin < 0) return;
    if (gpio_get_level((gpio_num_t)cfg.bootPin) == 0) {
        if (!downSince) downSince = millis() | 1;
        else if (!fired && millis() - downSince > 3000) { fired = true; nodeWebForceAp(); }
    } else {
        downSince = 0;
        fired = false;
    }
}

/* ------------------------------------------------------------------ */
/* Radio watchdog — the radio recovers by itself, the session stays   */
/*                                                                    */
/* The SX127x can be reset by a brown-out or a glitch on RESET, stop  */
/* answering on the SPI, or lose a DIO interrupt. Before, the node    */
/* then stopped transmitting (OP_TXRXPEND forever, or an LMiC assert  */
/* that parked the LoRaWAN task) until somebody rebooted it.          */
/*   - lost DIO edge: the HAL delivers it from the line level (ms);   */
/*   - radio idle: once per second the LMiC task checks that it       */
/*     answers (version) and sleeps, as the LMiC left it; if not      */
/*     (twice in a row) it gets a hardware reset and is ready again   */
/*     before the next uplink;                                        */
/*   - TX/RX that never ends (TXRX_STUCK_MS) or an LMiC assert: radio */
/*     reset, the pending operation is dropped and the next uplink    */
/*     is scheduled.                                                  */
/* DevAddr, keys, FCnt, channels and ADR state are kept in all cases  */
/* (the FCnt of a dropped frame is not reused). A radio that does not */
/* answer at all is retried forever (1 s, 2 s ... 60 s): a wiring or  */
/* power problem to correct; the page, console and reboot keep        */
/* working meanwhile.                                                 */
/* ------------------------------------------------------------------ */
#define RADIO_CHECK_MS       1000    /* one check per second (radio idle) */
#define RADIO_FAILS_MAX      2       /* failed checks in a row before acting */
#define TXRX_STUCK_MS        60000   /* TX + RX1 + RX2 always end well before */
#define RADIO_RETRY_MAX_MS   60000   /* radio not answering: retry up to every 60 s */
#define RADIO_WARN_PER_H     3       /* recoveries per hour that point to hardware */

static jmp_buf  lmicJmp;              /* back to lorawanTask after an LMiC assert */
static volatile bool lmicJmpReady;
static char     lmicFailWhere[64];

/* Only a reboot request is served while the radio is down; the other
 * commands wait for it (they would start a TX). */
static void radioDownPoll(void)
{
    uint32_t arg = 0;
    uint32_t c = nodeCmdTake(&arg);
    if (c & NODE_CMD_REBOOT) {
        printf("Rebooting (requested by the web page)...\r\n");
        flushConsole();
        vTaskDelay(pdMS_TO_TICKS(100));
        esp_restart();
    }
    if (c)
        nodeCmdPost(c, arg);
    consolePoll();
    bootButtonPoll();
}

/* Drop what the LMiC was doing (it will never finish), keep the session. */
static void lmicDropPending(void)
{
    if ((LMIC.opmode & OP_JOINING) || LMIC.devaddr == 0) {
        printf("[RADIO] JOIN in progress: starting it again\r\n");
        lmicStart();                        /* no session yet: nothing to keep */
        return;
    }
    os_clearCallback(&LMIC.osjob);
    LMIC.pendTxLen = 0;
    LMIC.opmode &= ~(OP_TXDATA | OP_POLL | OP_TXRXPEND);
    os_radio(RADIO_RST);
    printf("[RADIO] pending frame dropped; FCnt up %lu kept, next uplink in %lu s\r\n",
           (unsigned long)LMIC.seqnoUp, (unsigned long)cfg.txInterval);
    scheduleNext();
}

static void radioRecover(const char *why, bool dropPending)
{
    static uint32_t winStart;
    static unsigned inWin;
    uint32_t wait = 1000;

    printf("[RADIO] %s: resetting the radio (LoRaWAN session kept)\r\n", why);
    while (!radio_reinit()) {
        printf("[RADIO] radio not answering on the SPI (power, RESET or SPI wires) — retry in %lu s\r\n",
               (unsigned long)(wait / 1000));
        stEvent("Radio not answering");
        for (uint32_t t0 = millis(); millis() - t0 < wait; ) {
            radioDownPoll();
            vTaskDelay(pdMS_TO_TICKS(10));
        }
        wait = (wait * 2 > RADIO_RETRY_MAX_MS) ? RADIO_RETRY_MAX_MS : wait * 2;
    }
    if (dropPending)
        lmicDropPending();

    radioRecoveries++;
    radioLastMs = millis();
    strlcpy(radioLastWhy, why, sizeof(radioLastWhy));
    printf("[RADIO] radio ready again (recovery #%lu since boot)\r\n", (unsigned long)radioRecoveries);
    stEvent("Radio recovered");

    if (!inWin || millis() - winStart >= 3600000UL) {
        winStart = millis();
        inWin = 0;
    }
    if (++inWin > RADIO_WARN_PER_H)
        printf("[RADIO] %u recoveries in the last hour: the node keeps working, but this is a hardware "
               "problem to correct (3.3 V supply and decoupling of the radio, RESET/DIO/SPI wires, antenna)\r\n", inWin);
}

static void radioWatchdog(void)
{
    static uint32_t lastCheck, pendSince;
    static uint8_t fails;
    uint32_t now = millis();

    if (!lmicOk || now - lastCheck < RADIO_CHECK_MS)
        return;
    lastCheck = now;

    if (LMIC.opmode & OP_TXRXPEND) {        /* TX/RX in progress: never touch the radio */
        fails = 0;
        if (!pendSince) {
            pendSince = now | 1;
        } else if (now - pendSince >= TXRX_STUCK_MS) {
            pendSince = 0;
            radioRecover("TX/RX did not end in 60 s (radio interrupt lost)", true);
        }
        return;
    }
    pendSince = 0;
    if (os_queryTimeCriticalJobs(ms2osticks(100)))
        return;                             /* a TX/RX is about to start */

    int r = radio_check_idle();
    if (r == RADIO_CHECK_OK) {
        fails = 0;
        return;
    }
    const char *why = (r == RADIO_CHECK_VERSION) ? "radio not answering on the SPI"
                                                 : "radio left SLEEP (it was reset)";
    if (++fails < RADIO_FAILS_MAX) {
        printf("[RADIO] check failed (%u/%u): %s\r\n", fails, RADIO_FAILS_MAX, why);
        return;
    }
    fails = 0;
    radioRecover(why, false);
}

/* LMiC assert (lmic_hal_failed). At start-up (wrong pins) the LoRaWAN part
 * stops and everything else (web page, console, BOOT button, reboot) keeps
 * working. Once running, it goes back to lorawanTask (longjmp), which
 * resets the radio and carries on with the same session. Never returns. */
static void lmicFailed(const char *file, uint16_t line)
{
    if (lmicOk && lmicJmpReady) {
        const char *base = strrchr(file, '/');
        snprintf(lmicFailWhere, sizeof(lmicFailWhere), "LMiC assert %s:%u", base ? base + 1 : file, (unsigned)line);
        longjmp(lmicJmp, 1);
    }
    printf("LMiC FAILURE %s:%u — check the pins on the web page (Hardware).\r\n", file, (unsigned)line);
    lmicOk = false;
    stEvent("LMiC init FAILED");
    for (;;) {
        handleCommands();
        consolePoll();
        bootButtonPoll();
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

/* ------------------------------------------------------------------ */
/* LoRaWAN task (core 1) — the "setup()" and "loop()" of the sketch   */
/* ------------------------------------------------------------------ */
static void lorawanTask(void *)
{
    pins.sclk     = cfg.pinSclk;
    pins.miso     = cfg.pinMiso;
    pins.mosi     = cfg.pinMosi;
    pins.nss      = cfg.pinNss;
    pins.rst      = cfg.pinRst;
    pins.dio[0]   = cfg.pinDio0;
    pins.dio[1]   = cfg.pinDio1;
    pins.dio[2]   = cfg.pinDio2;
    pins.spi_freq = cfg.spiFreq;
    printf("Pins: SCLK %d MISO %d MOSI %d NSS %d RST %d DIO0 %d DIO1 %d DIO2 %d\r\n",
           cfg.pinSclk, cfg.pinMiso, cfg.pinMosi, cfg.pinNss, cfg.pinRst,
           cfg.pinDio0, cfg.pinDio1, cfg.pinDio2);

    lmic_esp32_set_notify_task(xTaskGetCurrentTaskHandle());
    lmic_esp32_set_fail_cb(lmicFailed);

    if (!os_init_ex(&pins)) {
        printf("LMiC init FAILED — check the pins on the web page (Hardware).\r\n");
        stEvent("LMiC init FAILED");
    } else {
        lmicOk = true;
        if (setjmp(lmicJmp) == 0) {
            lmicJmpReady = true;
            lmicStart();
        } else {
            /* back from an LMiC assert (see lmicFailed) */
            lmic_esp32_reset_irq_level();
            radioRecover(lmicFailWhere, true);
        }
    }

    for (;;) {
        /* a few passes: each os_runloop_once() runs at most one job */
        if (lmicOk)
            for (int i = 0; i < 4; i++) os_runloop_once();
        handleCommands();
        consolePoll();
        bootButtonPoll();
        radioWatchdog();                    /* radio reset / dead / lost IRQ -> recover */
        if (lmicOk) {
            /* keep "transmitting now" fresh for the status panel */
            bool pend = (LMIC.opmode & OP_TXRXPEND) != 0;
            nodeStatusLock();
            nodeStatusRaw()->txPending = pend;
            nodeStatusUnlock();
        }
        /* sleep 1 ms or until a DIO interrupt (RX/TX done); a job due in
         * less than 2 ms (RX window) only yields, without sleeping */
        if (lmicOk && os_queryTimeCriticalJobs(ms2osticks(2)))
            taskYIELD();
        else
            ulTaskNotifyTake(pdTRUE, 1);
    }
}

/* ------------------------------------------------------------------ */
/* app_main                                                           */
/* ------------------------------------------------------------------ */
extern "C" void app_main(void)
{
    /* console: UART driver with a TX buffer, so printing never blocks the
     * LoRaWAN task, and an RX buffer for the console commands */
    uart_driver_install(CONSOLE_UART, 512, 4096, 0, NULL, 0);
    uart_vfs_dev_use_driver(CONSOLE_UART);
    nodeLogInit();                          /* printf -> console + /logs */

    esp_err_t e = nvs_flash_init();
    if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    /* Configuration from the NVS (factory defaults on the first boot). */
    bool saved = nodeConfigLoad(&cfg);
    nodeCfgSetShared(&cfg);

    printf("\r\nStarting — " NODE_FW_NAME " " NODE_FW_VERSION " (" NODE_LMIC_VERSION ", ESP-IDF %s)\r\n",
           esp_get_idf_version());
    printf("Board: " CONFIG_NODE_BOARD_NAME " (" CONFIG_NODE_BOARD_ID ", " CONFIG_IDF_TARGET ")\r\n");
    printf("Node \"%s\" · region %s · config %s\r\n", cfg.name, NODE_REGION,
           saved ? "loaded from NVS" : "factory defaults (node_build.h)");

    /* BOOT / config button (3 s press, checked by the LoRaWAN task). */
    if (cfg.bootPin >= 0 && cfg.bootPin != cfg.pinNss && cfg.bootPin != cfg.pinRst &&
        cfg.bootPin != cfg.pinDio0 && cfg.bootPin != cfg.pinDio1 && cfg.bootPin != cfg.pinDio2 &&
        cfg.bootPin != cfg.pinSclk && cfg.bootPin != cfg.pinMiso && cfg.bootPin != cfg.pinMosi &&
        GPIO_IS_VALID_GPIO(cfg.bootPin)) {
        gpio_reset_pin((gpio_num_t)cfg.bootPin);
        gpio_set_direction((gpio_num_t)cfg.bootPin, GPIO_MODE_INPUT);
        gpio_set_pull_mode((gpio_num_t)cfg.bootPin, GPIO_PULLUP_ONLY);
    } else {
        cfg.bootPin = -1;
    }

    /* Wi-Fi + web page (core 0). */
    nodeWebBegin(false);
    nodeWebPrintAccess();
    consoleHelp();

    setConsoleBaud(cfg.baud);

    xTaskCreatePinnedToCore(lorawanTask, "lorawan", 6144, NULL, 5, NULL, 1);
}
