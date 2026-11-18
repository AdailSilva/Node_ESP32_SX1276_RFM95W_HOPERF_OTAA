/*
 * node_board.h — board (ESP32 module) of this build: name, factory pin map of
 * the RFM95W and the GPIOs the web page / app must refuse.
 *
 * The board is chosen at build time (scripts/build.sh <board>, which loads
 * boards/<board>.defaults and sets CONFIG_NODE_BOARD_*):
 *
 *   BOARD             Module (DevKit)            IDF_TARGET  Flash / PSRAM
 *   esp32             ESP32-WROOM-32U            esp32       4 MB quad / none
 *   esp32s3_n16r8     ESP32-S3-WROOM-1U-N16R8    esp32s3     16 MB quad 3.3 V / 8 MB octal
 *   esp32s3_n32r16v   ESP32-S3-WROOM-2-N32R16V   esp32s3     32 MB octal 1.8 V / 16 MB octal
 *
 * The pins below are only the FACTORY values (first boot or "Restaurar padrão
 * de fábrica"). After that they live in the NVS and are changed on the web
 * page (Hardware) or in the app, without recompiling.
 *
 * This file is identical in the ABP and the OTAA project.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef NODE_BOARD_H
#define NODE_BOARD_H

#include "sdkconfig.h"

#if CONFIG_NODE_BOARD_ESP32_WROOM_32U
/* ------------------------------------------------------------------ */
/* ESP32-WROOM-32U DevKit (38 pins) + RFM95W                          */
/* SPI on the usual VSPI pins 18/19/23/5 (SPI2_HOST via GPIO matrix). */
/* GPIO34-39 are input only: fine for DIO0/DIO1, never for outputs.   */
/* ------------------------------------------------------------------ */
#define DEF_PIN_SCLK            18
#define DEF_PIN_MISO            19
#define DEF_PIN_MOSI            23
#define DEF_PIN_NSS             5
#define DEF_PIN_RESET           14
#define DEF_PIN_DIO0            34
#define DEF_PIN_DIO1            35
#define DEF_PIN_DIO2            -1     /* not connected (39 = reference) */

/* GPIOs refused by the page/app for the radio, with the reason (JSON object) */
#define NODE_PINS_RSV_JSON \
    "{\"0\":\"strapping (botão BOOT)\",\"1\":\"TX0 do console\",\"3\":\"RX0 do console\"," \
    "\"6\":\"memória flash\",\"7\":\"memória flash\",\"8\":\"memória flash\"," \
    "\"9\":\"memória flash\",\"10\":\"memória flash\",\"11\":\"memória flash\"," \
    "\"12\":\"strapping (MTDI: em nível alto no boot a flash vira 1,8 V)\"," \
    "\"20\":\"não existe no ESP32\",\"24\":\"não existe no ESP32\"," \
    "\"28\":\"não existe no ESP32\",\"29\":\"não existe no ESP32\"," \
    "\"30\":\"não existe no ESP32\",\"31\":\"não existe no ESP32\"}"
/* input-only GPIOs (valid for MISO / DIOx, refused for SCLK, MOSI, NSS, RESET) */
#define NODE_PINS_IN_JSON       "[34,35,36,37,38,39]"
#define NODE_PIN_MAX            39
#define NODE_PINS_HINT          "GPIO 34–39 do ESP32 são só entrada: servem para DIO, nunca para SCLK, MOSI, NSS ou RESET. " \
                                "Não use 0/12 (strapping), 1/3 (console) nem 6–11 (flash)."

#elif CONFIG_NODE_BOARD_ESP32S3_WROOM_1U_N16R8 || CONFIG_NODE_BOARD_ESP32S3_WROOM_2_N32R16V
/* ------------------------------------------------------------------ */
/* ESP32-S3 DevKitC-1 (WROOM-1U-N16R8 or WROOM-2-N32R16V) + RFM95W    */
/* SPI on the native FSPI pins (SPI2_HOST, IOMUX 10-13). Every S3     */
/* GPIO can be an output; the same pins work on both modules.         */
/* ------------------------------------------------------------------ */
#define DEF_PIN_SCLK            12
#define DEF_PIN_MISO            13
#define DEF_PIN_MOSI            11
#define DEF_PIN_NSS             10
#define DEF_PIN_RESET           9
#define DEF_PIN_DIO0            4
#define DEF_PIN_DIO1            5
#define DEF_PIN_DIO2            -1     /* not connected (6 = reference) */

#if CONFIG_NODE_BOARD_ESP32S3_WROOM_2_N32R16V
#define NODE_PINS_S3_OCTAL \
    "\"33\":\"flash/PSRAM octal\",\"34\":\"flash/PSRAM octal\",\"35\":\"flash/PSRAM octal\"," \
    "\"36\":\"flash/PSRAM octal\",\"37\":\"flash/PSRAM octal\"," \
    "\"47\":\"domínio de 1,8 V no N32R16V\",\"48\":\"domínio de 1,8 V no N32R16V\""
#define NODE_PINS_HINT          "Não use 0/3/45/46 (strapping), 19/20 (USB), 26–37 (flash/PSRAM octal), " \
                                "43/44 (console) nem 47/48 (1,8 V no N32R16V)."
#else
#define NODE_PINS_S3_OCTAL \
    "\"33\":\"PSRAM octal\",\"34\":\"PSRAM octal\",\"35\":\"PSRAM octal\"," \
    "\"36\":\"PSRAM octal\",\"37\":\"PSRAM octal\""
#define NODE_PINS_HINT          "Não use 0/3/45/46 (strapping), 19/20 (USB), 26–37 (flash/PSRAM octal) " \
                                "nem 43/44 (console). No N16R8, 47/48 são de 3,3 V e podem ser usados."
#endif

#define NODE_PINS_RSV_JSON \
    "{\"0\":\"strapping (botão BOOT)\",\"3\":\"strapping\"," \
    "\"19\":\"USB nativo (D−)\",\"20\":\"USB nativo (D+)\"," \
    "\"22\":\"não existe no ESP32-S3\",\"23\":\"não existe no ESP32-S3\"," \
    "\"24\":\"não existe no ESP32-S3\",\"25\":\"não existe no ESP32-S3\"," \
    "\"26\":\"memória flash\",\"27\":\"memória flash\",\"28\":\"memória flash\"," \
    "\"29\":\"memória flash\",\"30\":\"memória flash\",\"31\":\"memória flash\",\"32\":\"memória flash\"," \
    NODE_PINS_S3_OCTAL "," \
    "\"43\":\"TX0 do console\",\"44\":\"RX0 do console\"," \
    "\"45\":\"strapping (tensão da flash)\",\"46\":\"strapping\"}"
#define NODE_PINS_IN_JSON       "[]"
#define NODE_PIN_MAX            48

#else
#error "No board selected: build with scripts/build.sh <esp32|esp32s3_n16r8|esp32s3_n32r16v>"
#endif

#endif
