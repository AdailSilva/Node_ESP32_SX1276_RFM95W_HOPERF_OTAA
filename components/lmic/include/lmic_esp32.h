/*
 * lmic_esp32.h — LMiC (MCCI) HAL for ESP-IDF (no Arduino).
 *
 * The pins come from the node configuration (web page → Hardware) and are
 * handed to os_init_ex(&pins). DIO lines use GPIO interrupts (rising edge):
 * the ISR stores the timestamp and wakes the LoRaWAN task, so the RX windows
 * stay precise even if the task sleeps between runs of os_runloop_once().
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef LMIC_ESP32_H
#define LMIC_ESP32_H

#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#ifdef __cplusplus
extern "C" {
#endif

#define LMIC_ESP32_UNUSED_PIN   (-1)

typedef struct {
    int8_t   sclk, miso, mosi;      /* SPI bus                              */
    int8_t   nss;                   /* chip select (driven by the HAL)      */
    int8_t   rst;                   /* -1 = not connected                   */
    int8_t   dio[3];                /* DIO0 required, DIO1/DIO2 optional    */
    uint32_t spi_freq;              /* Hz, 0 = LMIC_SPI_FREQ (1 MHz)        */
} lmic_esp32_pins_t;

/* Task woken by the DIO interrupts (the task that runs os_runloop_once()). */
void lmic_esp32_set_notify_task(TaskHandle_t task);

/* Called by the HAL when the LMiC asserts (lmic_hal_failed). The default
 * handler only prints the file/line; the LoRaWAN task then stops forever,
 * while the web page keeps working so the pins can be fixed. */
typedef void (*lmic_esp32_fail_cb_t)(const char *file, uint16_t line);
void lmic_esp32_set_fail_cb(lmic_esp32_fail_cb_t cb);

/* Radio watchdog support (ESP32 port):
 *  - lmic_esp32_missed_irqs(): DIO interrupts whose edge was lost and that
 *    the HAL delivered from the line level (see processPendingIRQs);
 *  - lmic_esp32_reset_irq_level(): forget the disableIRQs() nesting, used
 *    after leaving an LMiC assert with longjmp(). */
uint32_t lmic_esp32_missed_irqs(void);
void lmic_esp32_reset_irq_level(void);

#ifdef __cplusplus
}
#endif

#endif
