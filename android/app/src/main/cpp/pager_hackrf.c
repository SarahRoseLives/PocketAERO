/*
 * pager_hackrf.c — HackRF IQ → FM demod → SRC → multimon-ng pager decoder
 *
 * Feed signed int8 IQ samples (as uint8_t, interleaved I/Q pairs) from
 * HackRF through the pager decode pipeline.
 *
 * Exported API (called from Dart via FFI):
 *
 *   int32_t pager_hackrf_init (pager_cb_t callback,
 *                               uint32_t input_sample_rate)
 *   void    pager_hackrf_feed (const uint8_t *iq, int n_bytes)
 *   void    pager_hackrf_deinit (void)
 *   void    pager_hackrf_free  (void *ptr)
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <android/log.h>

#include "multimon-ng/multimon.h"

#define LOG_TAG "RFStudio_Pager_HRF"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#define HACKRF_AUDIO_RATE  22050u
#define HACKRF_SRC_MAX     8192
#define HACKRF_NUM_DEMODS  5

/* Callback type — same signature as pager_cb_t in rfstudio_sdr.c */
typedef void (*pager_cb_t)(int32_t  protocol_id,
                            uint32_t address,
                            int32_t  function,
                            char    *message,
                            int64_t  timestamp_ms);

/* Active line dispatcher defined in rfstudio_sdr.c */
typedef void (*_pager_dispatch_fn_t)(const char *line);
extern _pager_dispatch_fn_t g_pager_active_dispatch;

/* ── Module state ─────────────────────────────────────────────────────────── */

static const struct demod_param *g_hackrf_demods[HACKRF_NUM_DEMODS] = {
    &demod_poc5,
    &demod_poc12,
    &demod_poc24,
    &demod_flex,
    &demod_flex_next,
};

static struct demod_state g_hackrf_dem[HACKRF_NUM_DEMODS];
static pager_cb_t         g_hackrf_callback = NULL;
static uint32_t           g_hackrf_in_rate  = 1000000;

static float  g_hackrf_prev_i    = 0.0f;
static float  g_hackrf_prev_q    = 0.0f;
static double g_hackrf_src_phase = 0.0;

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static int64_t _hackrf_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void _hackrf_dispatch_line(const char *line)
{
    if (!g_hackrf_callback) return;

    int proto = -1;
    if      (strncmp(line, "POCSAG512:",  10) == 0) proto = 0;
    else if (strncmp(line, "POCSAG1200:", 11) == 0) proto = 1;
    else if (strncmp(line, "POCSAG2400:", 11) == 0) proto = 2;
    else if (strncmp(line, "FLEX:",        5) == 0) proto = 3;
    else if (strncmp(line, "FLEX_NEXT:",  10) == 0) proto = 4;
    else return;

    const char *addr_p = strstr(line, "Address:");
    uint32_t address = 0;
    if (addr_p) address = (uint32_t)strtoul(addr_p + 8, NULL, 10);

    const char *func_p = strstr(line, "Function:");
    int32_t function = -1;
    if (func_p) function = (int32_t)strtol(func_p + 9, NULL, 10);

    const char *msg_start = NULL;
    const char *markers[] = { "Alpha:   ", "Numeric: ", "Skyper:  ", NULL };
    for (int i = 0; markers[i]; i++) {
        const char *p = strstr(line, markers[i]);
        if (p) { msg_start = p + strlen(markers[i]); break; }
    }
    if (!msg_start && proto >= 3) {
        const char *colon = strchr(line, ':');
        if (colon) msg_start = colon + 2;
    }

    char *message = msg_start ? strdup(msg_start) : strdup("");
    if (message) {
        size_t len = strlen(message);
        while (len > 0 && (message[len-1] == '\n' || message[len-1] == '\r' ||
                            message[len-1] == ' '))
            message[--len] = '\0';
    }
    g_hackrf_callback(proto, address, function, message, _hackrf_now_ms());
}

/* ── Public API ─────────────────────────────────────────────────────────── */

int32_t pager_hackrf_init(pager_cb_t callback, uint32_t input_sample_rate)
{
    g_hackrf_callback  = callback;
    g_hackrf_in_rate   = (input_sample_rate > 0) ? input_sample_rate : 1000000;
    g_hackrf_prev_i    = g_hackrf_prev_q = 0.0f;
    g_hackrf_src_phase = 0.0;

    for (int i = 0; i < HACKRF_NUM_DEMODS; i++) {
        memset(&g_hackrf_dem[i], 0, sizeof(g_hackrf_dem[i]));
        g_hackrf_dem[i].dem_par = g_hackrf_demods[i];
        g_hackrf_demods[i]->init(&g_hackrf_dem[i]);
    }

    g_pager_active_dispatch = _hackrf_dispatch_line;
    LOGI("HackRF pager init: rate=%u → %u", g_hackrf_in_rate, HACKRF_AUDIO_RATE);
    return 0;
}

void pager_hackrf_feed(const uint8_t *iq, int n_bytes)
{
    if (!g_hackrf_callback || n_bytes < 2) return;

    int n_pairs = n_bytes / 2;

    /* FM quadrature discriminator — HackRF signed int8 packed as uint8 */
    float *fm = (float *)malloc((size_t)n_pairs * sizeof(float));
    if (!fm) return;

    for (int i = 0; i < n_pairs; i++) {
        float ci = ((int8_t)iq[i * 2])     / 128.0f;
        float cq = ((int8_t)iq[i * 2 + 1]) / 128.0f;
        float cross = ci * g_hackrf_prev_q - cq * g_hackrf_prev_i;
        float dot   = ci * g_hackrf_prev_i + cq * g_hackrf_prev_q;
        fm[i]           = atan2f(cross, dot);
        g_hackrf_prev_i = ci;
        g_hackrf_prev_q = cq;
    }

    /* Linear-interpolation SRC: input_sample_rate → HACKRF_AUDIO_RATE */
    const double ratio = (double)HACKRF_AUDIO_RATE / g_hackrf_in_rate;
    int out_max = (int)((double)n_pairs * ratio) + 32;
    if (out_max > HACKRF_SRC_MAX) out_max = HACKRF_SRC_MAX;

    float *audio = (float *)malloc((size_t)out_max * sizeof(float));
    if (!audio) { free(fm); return; }

    int n_out = 0;
    while (n_out < out_max) {
        int idx = (int)g_hackrf_src_phase;
        if (idx + 1 >= n_pairs) break;
        float frac = (float)(g_hackrf_src_phase - idx);
        audio[n_out++] = fm[idx] + frac * (fm[idx + 1] - fm[idx]);
        g_hackrf_src_phase += 1.0 / ratio;
    }
    int consumed = (int)g_hackrf_src_phase;
    if (consumed > n_pairs) consumed = n_pairs;
    g_hackrf_src_phase -= consumed;

    free(fm);

    if (n_out > 0) {
        buffer_t mbuf = { .sbuffer = NULL, .fbuffer = audio };
        for (int i = 0; i < HACKRF_NUM_DEMODS; i++)
            g_hackrf_demods[i]->demod(&g_hackrf_dem[i], mbuf, n_out);
    }
    free(audio);
}

void pager_hackrf_deinit(void)
{
    for (int i = 0; i < HACKRF_NUM_DEMODS; i++)
        g_hackrf_demods[i]->deinit(&g_hackrf_dem[i]);
    g_hackrf_callback       = NULL;
    g_pager_active_dispatch = NULL;
    LOGI("HackRF pager deinit");
}

void pager_hackrf_free(void *ptr)
{
    free(ptr);
}
