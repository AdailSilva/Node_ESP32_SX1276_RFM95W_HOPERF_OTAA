/*
 * node_dns.c — captive-portal DNS of the Soft AP (was DNSServer in Arduino):
 * every "A" query is answered with the Soft AP address, so phones and PCs
 * that open any site land on the configuration page.
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "esp_log.h"
#include "node_dns.h"

static const char *TAG = "node_dns";
static volatile bool s_run;
static volatile bool s_alive;
static uint32_t s_ip;                       /* network order */

static void dns_task(void *arg)
{
    uint8_t buf[512];
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in a = { 0 };

    a.sin_family = AF_INET;
    a.sin_port = htons(53);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (sock < 0 || bind(sock, (struct sockaddr *)&a, sizeof(a)) < 0) {
        ESP_LOGE(TAG, "socket/bind 53 failed");
        if (sock >= 0) close(sock);
        s_alive = false;
        vTaskDelete(NULL);
        return;
    }
    struct timeval tv = { .tv_sec = 0, .tv_usec = 300000 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    while (s_run) {
        struct sockaddr_in from;
        socklen_t fl = sizeof(from);
        int n = recvfrom(sock, buf, sizeof(buf) - 16, 0, (struct sockaddr *)&from, &fl);
        if (n < 12)
            continue;
        if (buf[2] & 0x80)                  /* already a response */
            continue;
        if (((buf[4] << 8) | buf[5]) < 1)   /* no question */
            continue;
        /* walk the first question name */
        int p = 12;
        while (p < n && buf[p] != 0) {
            if ((buf[p] & 0xC0) == 0xC0) { p++; break; }
            p += buf[p] + 1;
        }
        p++;                                /* terminating zero */
        if (p + 4 > n)
            continue;
        uint16_t qtype = (buf[p] << 8) | buf[p + 1];
        p += 4;                             /* type + class */

        buf[2] = 0x84 | (buf[2] & 0x01);    /* response, authoritative, keep RD */
        buf[3] = 0x80;                      /* RA, NOERROR */
        buf[4] = 0; buf[5] = 1;             /* 1 question */
        buf[8] = buf[9] = buf[10] = buf[11] = 0;
        if (qtype == 1 || qtype == 255) {   /* A / ANY -> our address */
            buf[6] = 0; buf[7] = 1;
            uint8_t ans[16] = { 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4 };
            memcpy(ans + 12, &s_ip, 4);
            memcpy(buf + p, ans, 16);
            p += 16;
        } else {                            /* AAAA etc: no answer */
            buf[6] = buf[7] = 0;
        }
        sendto(sock, buf, p, 0, (struct sockaddr *)&from, fl);
    }
    close(sock);
    s_alive = false;
    vTaskDelete(NULL);
}

bool nodeDnsStart(uint32_t ip_network_order)
{
    for (int i = 0; i < 10 && s_alive && !s_run; i++)   /* old task still closing */
        vTaskDelay(pdMS_TO_TICKS(100));
    s_ip = ip_network_order;
    if (s_alive) {
        s_run = true;
        return true;
    }
    s_run = true;
    s_alive = true;
    if (xTaskCreatePinnedToCore(dns_task, "node_dns", 3072, NULL, 2, NULL, 0) != pdPASS) {
        s_alive = false;
        return false;
    }
    return true;
}

void nodeDnsStop(void)
{
    s_run = false;
}
