/*
 * scm_lib.c  –  SCM decoder library for Android
 *
 * Same Manchester-filter / preamble-search / BCH pipeline as scm_decoder.c,
 * but IQ samples come directly from librtlsdr (via rtl_tcp_andro's
 * rtlsdr_open2 which accepts a file-descriptor from Android's UsbManager)
 * instead of a TCP socket.
 *
 * Exported API (called from Dart via FFI):
 *
 *   int32_t  scm_open (int32_t fd, const char *device_path)
 *     Open the RTL-SDR dongle whose USB file descriptor was obtained by Kotlin.
 *     Returns 0 on success, negative on error.
 *
 *   int32_t  scm_start(scm_cb_t callback)
 *     Start the decode loop on a background pthread.
 *     callback is invoked (from that thread) for every valid SCM packet.
 *     Returns 0 on success, -1 if already running / not opened.
 *
 *   void     scm_stop (void)
 *     Signal the decode loop to stop and block until it exits.
 *     Safe to call from any thread.
 *
 * The callback signature:
 *   void cb(uint32_t id, uint8_t type, uint8_t phy, uint8_t enc,
 *           uint32_t consumption, uint16_t crc, int64_t timestamp_ms)
 *
 * Dart's NativeCallable.listener() wraps a Dart closure into a C function
 * pointer that is safe to call from any native thread.
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <pthread.h>

#include "librtlsdr/include/rtl-sdr.h"
#include "librtlsdr/include/rtl-sdr-android.h"   /* rtlsdr_open2 */

/* ── Signal processing constants (symbollength = 72) ─────────────────────── */
#define CHIP_LEN      72
#define SYM_LEN       (CHIP_LEN * 2)
#define DATA_RATE     32768
#define SAMPLE_RATE   (DATA_RATE * CHIP_LEN)   /* 2,359,296 sps */
#define CENTER_FREQ   912600155U

#define PREAMBLE_SYMS 21
#define PACKET_SYMS   96

#define PREAMBLE_LEN  (PREAMBLE_SYMS * SYM_LEN)  /* 3,024 */
#define PACKET_LEN    (PACKET_SYMS   * SYM_LEN)  /* 13,824 */
#define BLOCK_SIZE    4096
#define BLOCK_SIZE2   (BLOCK_SIZE * 2)
#define BUFFER_LEN    (PACKET_LEN + BLOCK_SIZE)
#define SIGNAL_LEN    (BLOCK_SIZE + SYM_LEN)

/* rtlsdr_read_sync buffer: must be a multiple of 512 and >= BLOCK_SIZE2.
   We use exactly BLOCK_SIZE2 = 8192 bytes (= 4096 IQ pairs).           */
#define RTL_READ_LEN  BLOCK_SIZE2

static const uint8_t PREAMBLE[PREAMBLE_SYMS] = {
    1,1,1,1,1, 0,0,1,0,1, 0,1,0,0,1, 1,0,0,0,0, 0
};

/* ── Lookup tables ────────────────────────────────────────────────────────── */

static float    mag_lut[256];
static uint16_t crc_tbl[256];

static void tables_init(void)
{
    for (int i = 0; i < 256; i++) {
        float v = (127.5f - (float)i) / 127.5f;
        mag_lut[i] = v * v;
    }
    for (int i = 0; i < 256; i++) {
        uint16_t c = (uint16_t)(i << 8);
        for (int b = 0; b < 8; b++)
            c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x6F63)
                             : (uint16_t)(c << 1);
        crc_tbl[i] = c;
    }
}

/* ── Manchester matched filter ───────────────────────────────────────────── */

static void manchester_filter(const float *sig, uint8_t *out)
{
    static double csum[SIGNAL_LEN + 1];
    double s = 0.0;
    csum[0] = 0.0;
    for (int i = 0; i < SIGNAL_LEN; i++) { s += sig[i]; csum[i+1] = s; }
    for (int i = 0; i < BLOCK_SIZE; i++) {
        double lo = csum[i + CHIP_LEN] - csum[i];
        double hi = csum[i + SYM_LEN]  - csum[i + CHIP_LEN];
        out[i] = (lo >= hi) ? 1 : 0;
    }
}

/* ── SCM field extraction + CRC verify ───────────────────────────────────── */

typedef struct { uint32_t id; uint8_t type, phy, enc; uint32_t cons; uint16_t crc; } SCM;

static int decode_scm(const uint8_t *bits, SCM *scm)
{
    uint8_t bytes[12];
    memset(bytes, 0, sizeof(bytes));
    for (int i = 0; i < PACKET_SYMS; i++)
        bytes[i >> 3] |= (uint8_t)(bits[i] << (7 - (i & 7)));

    uint16_t c = 0;
    for (int i = 2; i < 12; i++) c = (uint16_t)((c<<8) ^ crc_tbl[(c>>8)^bytes[i]]);
    if (c != 0) return 0;

    uint32_t id_hi = ((uint32_t)bits[21] << 1) | bits[22];
    uint32_t id_lo = 0;
    for (int i = 56; i < 80; i++) id_lo = (id_lo << 1) | bits[i];
    scm->id = (id_hi << 24) | id_lo;
    if (scm->id == 0) return 0;

    scm->phy  = (uint8_t)((bits[24] << 1) | bits[25]);
    scm->type = (uint8_t)((bits[26]<<3)|(bits[27]<<2)|(bits[28]<<1)|bits[29]);
    scm->enc  = (uint8_t)((bits[30] << 1) | bits[31]);
    scm->cons = 0;
    for (int i = 32; i < 56; i++) scm->cons = (scm->cons << 1) | bits[i];
    scm->crc  = 0;
    for (int i = 80; i < 96; i++) scm->crc  = (uint16_t)((scm->crc<<1)|bits[i]);
    return 1;
}

/* ── Duplicate suppression ───────────────────────────────────────────────── */

#define MAX_SEEN 64
typedef struct { uint8_t k[10]; } Fp;
static Fp seen_prev[MAX_SEEN], seen_next[MAX_SEEN];
static int n_prev, n_next;

static int already_seen(const uint8_t *fp)
{
    for (int i = 0; i < n_prev; i++) if (!memcmp(seen_prev[i].k, fp, 10)) return 1;
    for (int i = 0; i < n_next; i++) if (!memcmp(seen_next[i].k, fp, 10)) return 1;
    return 0;
}
static void mark_seen(const uint8_t *fp)
{ if (n_next < MAX_SEEN) memcpy(seen_next[n_next++].k, fp, 10); }
static void rotate_seen(void)
{ memcpy(seen_prev, seen_next, (size_t)n_next*sizeof(Fp)); n_prev=n_next; n_next=0; }

/* ── Library state ────────────────────────────────────────────────────────── */

typedef void (*scm_cb_t)(uint32_t id, uint8_t type, uint8_t phy, uint8_t enc,
                          uint32_t consumption, uint16_t crc, int64_t ts_ms);

static rtlsdr_dev_t    *g_dev      = NULL;
static volatile int     g_running  = 0;
static pthread_t        g_thread;
static scm_cb_t         g_callback = NULL;

/* ── Decode thread ────────────────────────────────────────────────────────── */

static void *decode_loop(void *arg)
{
    (void)arg;

    static float   signal[SIGNAL_LEN];
    static uint8_t quantized[BUFFER_LEN];
    static uint8_t iq_block[RTL_READ_LEN];
    static uint8_t bits96[PACKET_SYMS];

    memset(signal,    0, sizeof(signal));
    memset(quantized, 0, sizeof(quantized));

    while (g_running) {
        int n_read = 0;
        int r = rtlsdr_read_sync(g_dev, iq_block, RTL_READ_LEN, &n_read);
        if (r < 0 || n_read != RTL_READ_LEN) break;

        /* Magnitude */
        memmove(signal, signal + BLOCK_SIZE, SYM_LEN * sizeof(float));
        for (int i = 0; i < BLOCK_SIZE; i++)
            signal[SYM_LEN + i] = mag_lut[iq_block[2*i]] + mag_lut[iq_block[2*i+1]];

        /* Quantized bits */
        memmove(quantized, quantized + BLOCK_SIZE, PACKET_LEN);
        manchester_filter(signal, quantized + PACKET_LEN);

        /* Preamble search */
        rotate_seen();
        for (int q = 0; q < BLOCK_SIZE; q++) {
            if (!quantized[q]) continue;
            int ok = 1;
            for (int p = 1; p < PREAMBLE_SYMS; p++) {
                if (quantized[q + (size_t)p * SYM_LEN] != PREAMBLE[p]) { ok = 0; break; }
            }
            if (!ok) continue;

            for (int p = 0; p < PACKET_SYMS; p++)
                bits96[p] = quantized[q + (size_t)p * SYM_LEN];

            SCM scm;
            if (!decode_scm(bits96, &scm)) continue;

            /* Fingerprint = bytes[2:12] of the packed frame */
            uint8_t fp[10];
            memset(fp, 0, sizeof(fp));
            for (int i = 16; i < PACKET_SYMS; i++)
                fp[(i-16)>>3] |= (uint8_t)(bits96[i] << (7-((i-16)&7)));

            if (already_seen(fp)) continue;
            mark_seen(fp);

            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            int64_t ms = (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;

            if (g_callback)
                g_callback(scm.id, scm.type, scm.phy, scm.enc,
                           scm.cons, scm.crc, ms);
        }
    }
    return NULL;
}

/* ── Public API ──────────────────────────────────────────────────────────── */

int32_t scm_open(int32_t fd, const char *device_path)
{
    tables_init();

    if (g_dev) { rtlsdr_close(g_dev); g_dev = NULL; }

    if (rtlsdr_open2(&g_dev, (int)fd, device_path) != 0) return -1;

    rtlsdr_set_sample_rate(g_dev, SAMPLE_RATE);
    rtlsdr_set_center_freq(g_dev, CENTER_FREQ);
    rtlsdr_set_tuner_gain_mode(g_dev, 0);   /* auto tuner gain */
    rtlsdr_set_agc_mode(g_dev, 1);          /* enable RTL2832 AGC */
    rtlsdr_reset_buffer(g_dev);

    return 0;
}

int32_t scm_start(scm_cb_t callback)
{
    if (!g_dev || g_running) return -1;
    g_callback = callback;
    g_running  = 1;
    n_prev = n_next = 0;
    if (pthread_create(&g_thread, NULL, decode_loop, NULL) != 0) {
        g_running = 0;
        return -1;
    }
    return 0;
}

void scm_stop(void)
{
    if (!g_running) return;
    g_running = 0;
    if (g_dev) rtlsdr_reset_buffer(g_dev);
    pthread_join(g_thread, NULL);
    if (g_dev) { rtlsdr_close(g_dev); g_dev = NULL; }
}
