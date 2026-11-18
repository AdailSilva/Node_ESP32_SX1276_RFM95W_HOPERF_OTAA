/*
 * lmic_project_config.h — region and radio of this LMiC build
 * (was ~/Arduino/libraries/MCCI_LoRaWAN_LMIC_library/project_config/).
 * Only one CFG_<region>.
 */
#define CFG_au915 1
// #define CFG_us915 1
// #define CFG_eu868 1
// #define CFG_as923 1
// #define CFG_kr920 1
// #define CFG_in866 1
#define CFG_sx1276_radio 1      /* RFM95W */

/* DIO0/DIO1 by GPIO interrupt (hal_esp32.c): precise RX windows even when
 * the LoRaWAN task sleeps between jobs. */
#define LMIC_USE_INTERRUPTS
