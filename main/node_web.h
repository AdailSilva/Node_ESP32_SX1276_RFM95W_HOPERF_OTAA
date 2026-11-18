/*
 * node_web.h — Wi-Fi + configuration web server of the LoRaWAN node (ESP-IDF).
 *
 * The web server (esp_http_server) and the Wi-Fi supervisor run on core 0,
 * so serving a page never delays the LoRaWAN task (core 1): the RX1/RX2
 * windows of the LMiC are timing critical.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef NODE_WEB_H
#define NODE_WEB_H

#include <stdbool.h>

/* Region name of the LMiC build (defined in node_main.cpp from CFG_xxx). */
extern const char *NODE_REGION;

/* Start Wi-Fi and the web server (forceAp = open the Soft AP right away). */
void nodeWebBegin(bool forceAp);

/* Open the Soft AP now (BOOT button held 3 s, or "wifi_ap" on the serial
 * console). Starts Wi-Fi/web even when the Wi-Fi was configured off. */
void nodeWebForceAp(void);

/* One line for the boot banner: how to reach the page. */
void nodeWebPrintAccess(void);

/* "ESP32-D0WD-V3", "ESP32-S3"... (same text as ESP.getChipModel()). */
const char *nodeChipModel(void);

#endif
