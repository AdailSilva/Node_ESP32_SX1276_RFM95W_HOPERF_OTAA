/*
 * hal_esp32.c — LMiC HAL for ESP-IDF (port of the MCCI Arduino HAL hal.cpp).
 *
 *  - SPI: spi_master, NSS driven by hand (like the Arduino HAL), mode 0
 *  - time: esp_timer (64-bit microseconds) >> US_PER_OSTICK_EXPONENT
 *  - DIO0/1/2: GPIO interrupt on the rising edge stores the time of the
 *    edge; the LMiC processes it in lmic_hal_processPendingIRQs() (task)
 *  - lmic_hal_disableIRQs()/enableIRQs(): nesting counter only. The ISRs
 *    touch nothing but interrupt_time[], so the LMiC itself never runs in
 *    interrupt context and the SPI can be used inside its critical parts.
 *
 * Works with MCCI LMiC 3.3.0 (functions hal_*) and 6.0.1 (lmic_hal_*):
 * CMake defines LMIC_ESP32_HAL_V6 for the newer one.
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>
#include "lmic/lmic.h"
#include "lmic/hal.h"
#include "lmic_esp32.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_attr.h"
#include "rom/ets_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#if LMIC_ESP32_HAL_V6
#define HAL(name) lmic_hal_##name
#else
#define HAL(name) hal_##name
#endif

/* SPI controller of the radio. SPIx_HOST are enum values (not macros), so the
 * old "#if defined(SPI3_HOST)" was always false and SPI2_HOST was used on every
 * board; kept as is:
 *   ESP32    SPI2_HOST = HSPI, pins 18/19/23/5 through the GPIO matrix (tested)
 *   ESP32-S3 SPI2_HOST = FSPI, pins 12/13/11/10 = its native IOMUX pins
 * Override with -D LMIC_SPI_HOST=SPI3_HOST if needed. */
#ifndef LMIC_SPI_HOST
#define LMIC_SPI_HOST SPI2_HOST
#endif

static const char *TAG = "lmic_hal";

static const lmic_esp32_pins_t *s_pins;
static spi_device_handle_t s_spi;
static bool s_bus_ok;
static TaskHandle_t s_task;
static lmic_esp32_fail_cb_t s_fail_cb;
static volatile ostime_t s_irq_time[3];
static uint8_t s_irq_level;

/* DMA capable, word aligned: the radio FIFO is at most 255 bytes */
static DMA_ATTR uint8_t s_tx[260];
static DMA_ATTR uint8_t s_rx[260];

void lmic_esp32_set_notify_task(TaskHandle_t task) { s_task = task; }
void lmic_esp32_set_fail_cb(lmic_esp32_fail_cb_t cb) { s_fail_cb = cb; }

/* --------------------------------- time --------------------------------- */
u4_t HAL(ticks)(void)
{
    return (u4_t)((uint64_t)esp_timer_get_time() >> US_PER_OSTICK_EXPONENT);
}

static s4_t delta_time(u4_t time)
{
    return (s4_t)(time - HAL(ticks)());
}

u4_t HAL(waitUntil)(u4_t time)
{
    s4_t delta = delta_time(time);
    if (delta < 0)
        return (u4_t)-delta;
    /* long waits: let the other tasks run; the last ~9 ms are busy-waited */
    while (delta > ms2osticks(9)) {
        vTaskDelay(pdMS_TO_TICKS(8) ? pdMS_TO_TICKS(8) : 1);
        delta = delta_time(time);
    }
    while (delta_time(time) > 0)
        ;
    return 0;
}

u1_t HAL(checkTimer)(u4_t time)
{
    return delta_time(time) <= 0;
}

void HAL(sleep)(void) {}

/* ------------------------------ interrupts ------------------------------ */
static void IRAM_ATTR dio_isr(void *arg)
{
    int i = (int)(intptr_t)arg;
    if (s_irq_time[i] == 0) {
        ostime_t now = (ostime_t)((uint64_t)esp_timer_get_time() >> US_PER_OSTICK_EXPONENT);
        s_irq_time[i] = now ? now : 1;
    }
    if (s_task) {
        BaseType_t woken = pdFALSE;
        vTaskNotifyGiveFromISR(s_task, &woken);
        if (woken)
            portYIELD_FROM_ISR();
    }
}

void HAL(disableIRQs)(void) { s_irq_level++; }

void HAL(enableIRQs)(void)
{
    if (s_irq_level)
        s_irq_level--;
}

uint8_t HAL(getIrqLevel)(void) { return s_irq_level; }

void HAL(pollPendingIRQs_helper)(void) {}   /* LMIC_USE_INTERRUPTS: nothing to poll */

/* Lost edge fallback: the radio keeps a DIO line HIGH until the LMiC clears
 * the IRQ flags. If a line is HIGH on DIO_STUCK_POLLS consecutive polls (~1 ms
 * apart) during a TX/RX and no edge was recorded, the edge was lost (noise, ISR
 * latency): the interrupt is delivered anyway, so the TX/RX ends normally instead of leaving
 * the LMiC waiting forever (OP_TXRXPEND). At most once per DIO_STUCK_GAP_MS. */
#define DIO_STUCK_POLLS   3
#define DIO_STUCK_GAP_MS  100
static uint8_t s_hi_polls[3];
static int64_t s_last_forced_us[3];
static uint32_t s_missed_irqs;

void HAL(processPendingIRQs)(void)
{
    for (int i = 0; i < 3; i++) {
        if (!s_pins || s_pins->dio[i] < 0)
            continue;
        ostime_t t = s_irq_time[i];
        if (t) {
            s_irq_time[i] = 0;
            s_hi_polls[i] = 0;
            radio_irq_handler_v2((u1_t)i, t);
            continue;
        }
        /* only while a TX/RX is in progress: otherwise nobody waits for it */
        if (!(LMIC.opmode & OP_TXRXPEND) || gpio_get_level((gpio_num_t)s_pins->dio[i]) == 0) {
            s_hi_polls[i] = 0;
            continue;
        }
        if (++s_hi_polls[i] < DIO_STUCK_POLLS)
            continue;
        s_hi_polls[i] = 0;
        int64_t now = esp_timer_get_time();
        if (now - s_last_forced_us[i] < (int64_t)DIO_STUCK_GAP_MS * 1000)
            continue;
        s_last_forced_us[i] = now;
        s_missed_irqs++;
        t = (ostime_t)((uint64_t)now >> US_PER_OSTICK_EXPONENT);
        radio_irq_handler_v2((u1_t)i, t ? t : 1);
    }
}

uint32_t lmic_esp32_missed_irqs(void) { return s_missed_irqs; }

void lmic_esp32_reset_irq_level(void) { s_irq_level = 0; }

/* --------------------------------- pins --------------------------------- */
void HAL(pin_rxtx)(u1_t val) { (void)val; }   /* RFM95W: no RX/TX switch pin */

void HAL(pin_rst)(u1_t val)
{
    if (!s_pins || s_pins->rst < 0)
        return;
    gpio_num_t p = (gpio_num_t)s_pins->rst;
    if (val == 0 || val == 1) {                 /* drive */
        gpio_set_level(p, val);
        gpio_set_direction(p, GPIO_MODE_OUTPUT);
    } else {                                    /* float */
        gpio_set_direction(p, GPIO_MODE_INPUT);
    }
}

/* ---------------------------------- SPI --------------------------------- */
static void spi_trx(u1_t cmd, u1_t *buf, size_t len, bool is_read)
{
    if (!s_spi || len > sizeof(s_tx) - 1)
        return;
    s_tx[0] = cmd;
    if (is_read)
        memset(s_tx + 1, 0, len);
    else if (len)
        memcpy(s_tx + 1, buf, len);

    spi_transaction_t t;
    memset(&t, 0, sizeof(t));
    t.length = (len + 1) * 8;
    t.tx_buffer = s_tx;
    t.rx_buffer = is_read ? s_rx : NULL;

    gpio_set_level((gpio_num_t)s_pins->nss, 0);
    esp_err_t err = spi_device_polling_transmit(s_spi, &t);
    gpio_set_level((gpio_num_t)s_pins->nss, 1);
    if (err != ESP_OK)
        ESP_LOGE(TAG, "SPI: %s", esp_err_to_name(err));
    else if (is_read)
        memcpy(buf, s_rx + 1, len);
}

void HAL(spi_write)(u1_t cmd, const u1_t *buf, size_t len)
{
    spi_trx(cmd, (u1_t *)buf, len, false);
}

void HAL(spi_read)(u1_t cmd, u1_t *buf, size_t len)
{
    spi_trx(cmd, buf, len, true);
}

#if LMIC_ESP32_HAL_V6
bit_t HAL(radio_spi_is_busy)(void) { return 0; }
#if (defined(CFG_sx1261_radio) || defined(CFG_sx1262_radio))
#error "This HAL supports the SX1276/RFM95W only"
#endif
#endif

/* ------------------------------ board info ------------------------------ */
s1_t HAL(getRssiCal)(void) { return 0; }
ostime_t HAL(setModuleActive)(bit_t val) { (void)val; return 0; }
bit_t HAL(queryUsingTcxo)(void) { return 0; }
#if LMIC_ESP32_HAL_V6
bit_t HAL(queryUsingDcdc)(void) { return 0; }
bit_t HAL(queryUsingDIO2AsRfSwitch)(void) { return 0; }
bit_t HAL(queryUsingDIO3AsTCXOSwitch)(void) { return 0; }
#endif

uint8_t HAL(getTxPowerPolicy)(u1_t inputPolicy, s1_t requestedPower, u4_t freq)
{
    (void)inputPolicy; (void)requestedPower; (void)freq;
    return LMICHAL_radio_tx_power_policy_paboost;   /* RFM95W: PA_BOOST only */
}

/* -------------------------------- failure ------------------------------- */
void HAL(failed)(const char *file, u2_t line)
{
    if (s_fail_cb)
        s_fail_cb(file, line);
    else
        ESP_LOGE(TAG, "LMiC FAILURE %s:%u", file, (unsigned)line);
    /* never returns: stop only this task (the web page keeps running) */
    for (;;)
        vTaskDelay(portMAX_DELAY);
}

#if LMIC_ESP32_HAL_V6
void HAL(set_failure_handler)(lmic_hal_failure_handler_t *h) { (void)h; }
#else
void HAL(set_failure_handler)(const hal_failure_handler_t *const h) { (void)h; }
#endif

/* ---------------------------------- init -------------------------------- */
static bool io_init(void)
{
    const lmic_esp32_pins_t *p = s_pins;
    if (p->nss < 0 || p->dio[0] < 0 || p->sclk < 0 || p->miso < 0 || p->mosi < 0) {
        ESP_LOGE(TAG, "NSS, DIO0, SCLK, MISO and MOSI are required");
        return false;
    }

    gpio_config_t out = {
        .pin_bit_mask = 1ULL << p->nss,
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_set_level((gpio_num_t)p->nss, 1);
    if (gpio_config(&out) != ESP_OK)
        return false;
    gpio_set_level((gpio_num_t)p->nss, 1);

    if (p->rst >= 0) {
        gpio_reset_pin((gpio_num_t)p->rst);
        gpio_set_direction((gpio_num_t)p->rst, GPIO_MODE_INPUT);
    }

    esp_err_t e = gpio_install_isr_service(0);
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "gpio_install_isr_service: %s", esp_err_to_name(e));
        return false;
    }
    for (int i = 0; i < 3; i++) {
        if (p->dio[i] < 0)
            continue;
        gpio_config_t in = {
            .pin_bit_mask = 1ULL << p->dio[i],
            .mode = GPIO_MODE_INPUT,
            .intr_type = GPIO_INTR_POSEDGE,
        };
        if (gpio_config(&in) != ESP_OK)
            return false;
        gpio_isr_handler_remove((gpio_num_t)p->dio[i]);
        if (gpio_isr_handler_add((gpio_num_t)p->dio[i], dio_isr, (void *)(intptr_t)i) != ESP_OK)
            return false;
    }

    if (!s_bus_ok) {
        spi_bus_config_t bus = {
            .mosi_io_num = p->mosi,
            .miso_io_num = p->miso,
            .sclk_io_num = p->sclk,
            .quadwp_io_num = -1,
            .quadhd_io_num = -1,
            .max_transfer_sz = sizeof(s_tx),
        };
        e = spi_bus_initialize(LMIC_SPI_HOST, &bus, SPI_DMA_CH_AUTO);
        if (e != ESP_OK) {
            ESP_LOGE(TAG, "spi_bus_initialize: %s", esp_err_to_name(e));
            return false;
        }
        s_bus_ok = true;
    }
    if (!s_spi) {
        spi_device_interface_config_t dev = {
            .mode = 0,
            .clock_speed_hz = p->spi_freq ? (int)p->spi_freq : (int)LMIC_SPI_FREQ,
            .spics_io_num = -1,                 /* NSS driven by hand */
            .queue_size = 1,
        };
        e = spi_bus_add_device(LMIC_SPI_HOST, &dev, &s_spi);
        if (e != ESP_OK) {
            ESP_LOGE(TAG, "spi_bus_add_device: %s", esp_err_to_name(e));
            return false;
        }
    }
    return true;
}

void HAL(init_ex)(const void *pContext)
{
    s_pins = (const lmic_esp32_pins_t *)pContext;
    if (!s_pins || !io_init())
        HAL(failed)(__FILE__, __LINE__);
}

void HAL(init)(void)
{
    HAL(failed)(__FILE__, __LINE__);   /* always use os_init_ex(&pins) */
}
