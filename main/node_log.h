/*
 * node_log.h — everything printed (printf and ESP_LOGx) goes to the serial
 * console AND to a RAM ring buffer, shown live on the web page /logs.
 * stdout is redirected to a VFS device "/dev/nodelog" that tees the data
 * (same code as the gateway weblog.c).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef NODE_LOG_H
#define NODE_LOG_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NODE_LOG_SIZE   (16 * 1024)

void nodeLogInit(void);         /* first thing in app_main() */

/* Copy log bytes from absolute offset 'from'. *start = oldest offset still
 * in RAM, *next = offset to ask next time. Returns bytes copied. */
size_t nodeLogRead(uint32_t from, char *out, size_t size, uint32_t *start, uint32_t *next);

/* printf() for secrets (Wi-Fi password, NwkSKey, AppSKey): the formatted text
 * goes to the serial console only; webText (may be NULL) is stored in the RAM
 * log in its place. The log can be read on /logs and downloaded as a .log
 * file that is easy to share, so secrets never go there. */
void nodeLogSecret(const char *webText, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

#ifdef __cplusplus
}
#endif

#endif
