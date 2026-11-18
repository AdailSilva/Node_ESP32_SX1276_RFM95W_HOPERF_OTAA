/*
 * node_log.c — log shown on the web page /logs (same as the gateway weblog.c).
 * Web log (see node_log.h): stdout is redirected to a small VFS device
 * "/dev/nodelog" whose write() forwards the data to the original console and
 * appends it to a ring buffer.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_vfs.h"
#include "esp_vfs_ops.h"
#include "sdkconfig.h"
#if !CONFIG_LIBC_PICOLIBC
#include <sys/reent.h>
#endif

#include "node_log.h"

static char *s_buf;
static volatile uint32_t s_total;          /* bytes written since boot */
static SemaphoreHandle_t s_mx;
static int s_console_fd = -1;
static bool s_redirected;                  /* stdout goes through tee_write() */

static void ring_put(const char *d, size_t n)
{
    if (!s_buf || n == 0)
        return;
    if (xSemaphoreTake(s_mx, pdMS_TO_TICKS(5)) != pdTRUE)
        return;                             /* never block the logger */
    if (n > NODE_LOG_SIZE) {                  /* keep only the tail */
        d += n - NODE_LOG_SIZE;
        s_total += n - NODE_LOG_SIZE;
        n = NODE_LOG_SIZE;
    }
    size_t pos = s_total % NODE_LOG_SIZE;
    size_t first = NODE_LOG_SIZE - pos;
    if (first > n)
        first = n;
    memcpy(s_buf + pos, d, first);
    memcpy(s_buf, d + first, n - first);
    s_total += n;
    xSemaphoreGive(s_mx);
}

static ssize_t tee_write(void *ctx, int fd, const void *data, size_t size)
{
    if (s_console_fd >= 0)
        write(s_console_fd, data, size);   /* serial console, unchanged */
    ring_put(data, size);
    return size;
}

static int tee_open(void *ctx, const char *path, int flags, int mode) { return 0; }
static int tee_close(void *ctx, int fd) { return 0; }
static int tee_fstat(void *ctx, int fd, struct stat *st)
{
    memset(st, 0, sizeof(*st));
    st->st_mode = S_IFCHR;                  /* character device -> line buffered */
    return 0;
}

static const esp_vfs_fs_ops_t s_ops = {
    .write_p = tee_write,
    .open_p  = tee_open,
    .close_p = tee_close,
    .fstat_p = tee_fstat,
};

void nodeLogInit(void)
{
    FILE *f;

    if (s_buf)
        return;
    s_mx = xSemaphoreCreateMutex();
    s_buf = malloc(NODE_LOG_SIZE);
    if (!s_mx || !s_buf)
        return;

    fflush(stdout);
    s_console_fd = fileno(stdout);
    if (esp_vfs_register_fs("/dev/nodelog", &s_ops, ESP_VFS_FLAG_CONTEXT_PTR | ESP_VFS_FLAG_STATIC, NULL) != ESP_OK)
        return;
    f = fopen("/dev/nodelog", "w");
    if (!f)
        return;
    setvbuf(f, NULL, _IOLBF, 256);
#if CONFIG_LIBC_PICOLIBC
    stdout = f;
#else
    _GLOBAL_REENT->_stdout = f;
    __getreent()->_stdout = f;
#endif
    s_redirected = true;
}

void nodeLogSecret(const char *webText, const char *fmt, ...)
{
    char line[256];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n > 0) {
        if ((size_t)n >= sizeof(line))
            n = sizeof(line) - 1;
        fflush(stdout);                     /* keep the order of the lines */
        if (s_redirected && s_console_fd >= 0)
            write(s_console_fd, line, n);   /* serial console only */
        else
            fwrite(line, 1, n, stdout);     /* stdout is still the console */
    }
    for (volatile char *v = line; v < line + sizeof(line); v++)
        *v = 0;                             /* no copy of the secret left on the stack */
    if (webText)
        ring_put(webText, strlen(webText));
}

size_t nodeLogRead(uint32_t from, char *dst, size_t max, uint32_t *start, uint32_t *next)
{
    uint32_t total, first_avail;
    size_t n = 0;

    if (!s_buf) {
        *start = *next = 0;
        return 0;
    }
    xSemaphoreTake(s_mx, portMAX_DELAY);
    total = s_total;
    first_avail = (total > NODE_LOG_SIZE) ? total - NODE_LOG_SIZE : 0;
    if (from < first_avail || from > total)
        from = first_avail;
    n = total - from;
    if (n > max)
        n = max;
    for (size_t i = 0; i < n; i++)
        dst[i] = s_buf[(from + i) % NODE_LOG_SIZE];
    xSemaphoreGive(s_mx);
    *start = first_avail;
    *next = from + n;
    return n;
}
