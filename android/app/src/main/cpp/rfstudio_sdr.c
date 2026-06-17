/*
 * rfstudio_sdr.c  —  RTL-SDR + FFT native library for RFStudio
 *
 * Exported API (called from Dart via FFI):
 *
 *   int32_t  rf_open  (int32_t fd, const char *path, int32_t fft_size)
 *       Open device by USB file-descriptor obtained from Kotlin UsbManager.
 *       fft_size must be a power of 2 (e.g. 2048).
 *       Returns 0 on success, negative on error.
 *
 *   void     rf_set_frequency   (uint32_t hz)
 *   void     rf_set_sample_rate (uint32_t sps)
 *   void     rf_set_gain        (int32_t tenths_db)   // -1 = auto
 *   void     rf_set_bias_tee    (int32_t on)          // 1=on, 0=off
 *       Tune / reconfigure; safe to call while running.
 *
 *   int32_t  rf_start (void)
 *       Start background IQ-read + FFT thread.
 *       Returns 0 on success, -1 if already running or device not open.
 *
 *   int64_t  rf_poll_fft (float *out_db, int32_t n)
 *       Copy the latest FFT frame (n magnitudes in dBFS, DC-centred) into
 *       the caller-supplied buffer.  Returns a monotonically increasing
 *       frame counter; if the value is unchanged since the last call, no
 *       new data is available.  Safe to call from the Dart main isolate
 *       (uses a mutex internally).
 *
 *   float    rf_get_signal_db (void)
 *       Latest peak signal level (dBFS).  Returns 0.0f if not running.
 *
 *   void     rf_stop  (void)
 *       Stop the decode thread and block until it exits.
 *
 *   void     rf_close (void)
 *       Stop (if running) and close the device.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#include <stdarg.h>
#include <unistd.h>
#include <android/log.h>
#include <jni.h>

#include "librtlsdr/include/rtl-sdr.h"
#include "librtlsdr/include/rtl-sdr-android.h"
#include "multimon-ng/multimon.h"
#include "jaero_demod.h"

/* ── mbelib AMBE vocoder (for AERO C-channel voice) ── */
#include "mbelib.h"
static int g_ambe_init = 0;
static mbe_parms g_ambe_cur, g_ambe_prev, g_ambe_prev_enhanced;

/* ── AAudio output (Android low-latency audio) ── */
#include <aaudio/AAudio.h>
static AAudioStream *g_audio_out = NULL;

#define LOG_TAG "RFStudio_SDR"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Global that jaero_demod.cpp references */
double oqpsk_lockingbw = 0;  /* default 10500; overridden per-path */

/* ── Tuneable defaults ────────────────────────────────────────────────────── */
#define DEFAULT_SAMPLE_RATE  1024000u
#define DEFAULT_CENTER_FREQ  100000000u   /* 100 MHz — FM band */
#define MIN_DB              -120.0f
#define FFT_AVG_N            8            /* power-average this many frames per output */

/* ── Cooley-Tukey radix-2 FFT (in-place, DIF) ───────────────────────────── */

static void _fft(float *re, float *im, int n)
{
    /* Bit-reversal permutation */
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t;
            t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }

    /* Butterfly stages */
    for (int len = 2; len <= n; len <<= 1) {
        float ang = -2.0f * (float)M_PI / (float)len;
        float w_re = cosf(ang), w_im = sinf(ang);
        for (int i = 0; i < n; i += len) {
            float cur_re = 1.0f, cur_im = 0.0f;
            for (int j = 0; j < len / 2; j++) {
                int a = i + j, b = i + j + len / 2;
                float u_re = re[a], u_im = im[a];
                float v_re = re[b] * cur_re - im[b] * cur_im;
                float v_im = re[b] * cur_im + im[b] * cur_re;
                re[a] = u_re + v_re;  im[a] = u_im + v_im;
                re[b] = u_re - v_re;  im[b] = u_im - v_im;
                float tmp = cur_re * w_re - cur_im * w_im;
                cur_im    = cur_re * w_im + cur_im * w_re;
                cur_re    = tmp;
            }
        }
    }
}

/* Hann window coefficient */
static inline float _hann(int i, int n)
{
    return 0.5f * (1.0f - cosf(2.0f * (float)M_PI * (float)i / (float)(n - 1)));
}

/* Accumulate linear power spectrum (magnitude², DC-centred, normalised) into
   power_acc.  Call with a pre-zeroed buffer; call FFT_AVG_N times then convert. */
static void _accumulate_power(const uint8_t *iq, int n,
                               float *re_buf, float *im_buf,
                               float *power_acc)
{
    const float scale = 1.0f / 127.5f;
    const float norm  = 2.0f / (float)n;

    for (int i = 0; i < n; i++) {
        float w   = _hann(i, n);
        re_buf[i] = ((float)iq[2 * i]     - 127.5f) * scale * w;
        im_buf[i] = ((float)iq[2 * i + 1] - 127.5f) * scale * w;
    }

    _fft(re_buf, im_buf, n);

    /* Accumulate power (magnitude²), FFT-shifted so DC is at centre */
    for (int i = 0; i < n; i++) {
        float re = re_buf[i] * norm;
        float im = im_buf[i] * norm;
        power_acc[(i + n / 2) % n] += re * re + im * im;
    }
}

/* ── Library state ────────────────────────────────────────────────────────── */

static rtlsdr_dev_t  *g_dev        = NULL;
static int            g_usb_fd     = -1; /* original Android USB fd for dup() */
static volatile int   g_running    = 0;
static pthread_t      g_thread;

static int            g_fft_size   = 2048;
static float         *g_fft_out    = NULL;   /* latest frame, g_fft_size floats */
static pthread_mutex_t g_fft_mtx   = PTHREAD_MUTEX_INITIALIZER;
static volatile int64_t g_fft_cnt  = 0;      /* frame counter */
static volatile float  g_signal_db = MIN_DB;

/* ── AERO decoder via jaero_demod (inmarsat-sniffer port of JAERO) ────────── */
static jaero_oqpsk_cont_demod_t *g_aero_demod = NULL;
static jaero_pmsk_demod_t        *g_aero_pmsk  = NULL;
static double      g_aero_symbol_rate = 10500.0;  /* 10500=ACARS, 8400=voice, 600/1200=MSK */
static int          g_aero_running = 0;
static int          g_aero_feed_iq_mode = 1; /* 0=feedAudio (Hilbert), 1=feedIQ (JAERO's Hilbert) — default feedIQ */
static int          g_aero_boxcar_mode = 1; /* 0=halfband cascade (broken), 1=simple boxcar averaging — default boxcar */
static int          g_aero_recording = 0;
static FILE        *g_aero_rec_file = NULL;
static long         g_aero_rec_samples = 0;
static int          g_aero_rec_rate = 0;

static int          g_aero_recording_raw = 0;
static FILE        *g_aero_rec_raw_file = NULL;
static long         g_aero_rec_raw_bytes = 0;
static int          g_aero_rate = 1024000;   /* cached: actual RTL sample rate */
static int          g_aero_decim = 21;       /* cached: decimation factor (halfband) */
static int          g_aero_boxcar_n = 16;    /* boxcar decimation samples (vs g_aero_decim) */
static char         g_aero_msg_buf[65536];
static int          g_aero_msg_len = 0;
static pthread_mutex_t g_aero_msg_mtx = PTHREAD_MUTEX_INITIALIZER;

/* 4-stage halfband 2:1 decimation (SDRReceiver hbcoeff23) + 81-tap Hilbert USB.
 * Matches SDRReceiver's vfo.cpp process() + ssbDemod() chain exactly.
 * Halfband decimates IQ to 48 ksps, then Hilbert USB produces int16 audio. */
#define HB_STAGES 4   /* 1024000 / 16 = 64000 Hz output */
#define HB_TAPS 23

/* SDRReceiver-exact 81-tap Hilbert USB demod */
#define HILB_TAPS 81
#define HILB_DELAY ((HILB_TAPS - 1) / 2)  /* = 40 */

/* Halfband coefficients (23-tap, from SDRReceiver) */
static const float _hb_coeff[HB_TAPS] = {
    -0.00014988f, 0.0f, 0.00147486f, 0.0f,
    -0.00744169f, 0.0f, 0.02616352f, 0.0f,
    -0.07759370f, 0.0f, 0.30754684f, 0.5f,
    0.30754684f, 0.0f, -0.07759370f, 0.0f,
    0.02616352f, 0.0f, -0.00744169f, 0.0f,
    0.00147486f, 0.0f, -0.00014988f
};

static float _hb_ring_i[HB_STAGES][HB_TAPS];
static float _hb_ring_q[HB_STAGES][HB_TAPS];
static int   _hb_ridx[HB_STAGES];
static int   _hb_skip[HB_STAGES];
static float _hb_out_i[HB_STAGES]; /* last computed FIR output — survives skip cycles */
static float _hb_out_q[HB_STAGES];
static int   _hb_init = 0;

/* NCO phase accumulator (complex phasor for fast rotation) */
static double _nco_c = 1.0;   /* cos(phase) */
static double _nco_s = 0.0;   /* sin(phase) */
static double _nco_ci = 1.0;  /* cos(inc), precomputed */
static double _nco_si = 0.0;  /* sin(inc), precomputed */

/* 81-tap Hilbert FIR state (SDRReceiver-compatible) */
static float _hilb_pts[41];             /* [half+i] coefficients for i=1,3,..,half */
static float _hilb_buff[2 * HILB_TAPS]; /* double-length ring buffer for I */
static float _hilb_delay[HILB_DELAY + 1]; /* delay line for Q */
static int   _hilb_ptr = 0;
static int   _hilb_didx = 0;

static void _aero_init_hb(void)
{
    memset(_hb_ring_i, 0, sizeof(_hb_ring_i));
    memset(_hb_ring_q, 0, sizeof(_hb_ring_q));
    memset(_hb_ridx, 0, sizeof(_hb_ridx));
    memset(_hb_skip, 0, sizeof(_hb_skip));
    memset(_hb_out_i, 0, sizeof(_hb_out_i));
    memset(_hb_out_q, 0, sizeof(_hb_out_q));
    _nco_c = 1.0; _nco_s = 0.0;
    _nco_ci = 1.0; _nco_si = 0.0;  /* set later in rf_start_aero */

    /* Build SDRReceiver-identical 81-tap Hilbert coefficients.
     * Ideal kernel: h[n] = 0 for even n, 2/(π*n) for odd n.
     * Energy-normalized, reversed.  Same as FIRHilbert constructor. */
    float tmp[HILB_TAPS];
    double sumsq = 0.0;
    for (int n = 0; n < HILB_TAPS; n++) {
        int k = n - HILB_DELAY;           /* n = 0→80, k = -40→+40 */
        if (k == 0 || (k & 1) == 0)
            tmp[n] = 0.0f;
        else
            tmp[n] = 2.0f / ((float)M_PI * (float)k);
        sumsq += (double)tmp[n] * (double)tmp[n];
    }
    float gain = (float)sqrt(sumsq);
    for (int n = 0; n < HILB_TAPS; n++)
        tmp[n] /= gain;

    /* Store reversed coefficients at [half+i] for i=1,3,5,...
     * Matches FIRHilbert's points[half+i] array. */
    for (int i = 1; i <= HILB_DELAY; i += 2)
        _hilb_pts[i] = tmp[HILB_TAPS - 1 - (HILB_DELAY + i)];

    memset(_hilb_buff, 0, sizeof(_hilb_buff));
    memset(_hilb_delay, 0, sizeof(_hilb_delay));
    _hilb_ptr = 0;
    _hilb_didx = 0;
    _hb_init = 1;
    LOGI("AERO: NCO+4×halfband+81tapHilbert USB (SDRReceiver coeffs)");
}

static void _aero_acars_cb(const uint8_t *data, int len, int channel_id,
                            uint32_t aes_id, uint8_t ges_id,
                            uint8_t qno, uint8_t refno, int downlink,
                            void *user)
{
    (void)user; (void)channel_id; (void)aes_id; (void)ges_id;
    (void)qno; (void)refno; (void)downlink;
    pthread_mutex_lock(&g_aero_msg_mtx);
    int room = (int)sizeof(g_aero_msg_buf) - g_aero_msg_len - 1;
    if (room < 4) { pthread_mutex_unlock(&g_aero_msg_mtx); return; }

    /* Format: "AES=XXXXXX GES=XX LEN=XXX\ntext\ntext...\n\n" */
    {
        int hdr = snprintf(g_aero_msg_buf + g_aero_msg_len, (size_t)room,
                           "AES=%06X GES=%u LEN=%d\n", aes_id, ges_id, len);
        if (hdr > 0 && hdr < room) { g_aero_msg_len += hdr; room -= hdr; }
    }

    for (int i = 0; i < len && room >= 2; i++) {
        char c = (char)(data[i] & 0x7F);
        if (c == '\r') c = '\n';  /* normalize line endings */
        if ((c >= 0x20 && c < 0x7F) || c == '\n') {
            g_aero_msg_buf[g_aero_msg_len++] = c;
            room--;
        }
    }
    g_aero_msg_buf[g_aero_msg_len++] = '\n';  /* end of SU */
    g_aero_msg_buf[g_aero_msg_len++] = '\n';  /* blank line between SUs */
    LOGI("ACARS: AES=%06X GES=%u len=%d", aes_id, ges_id, len);
    pthread_mutex_unlock(&g_aero_msg_mtx);
}

static void _aero_cassign_cb(int channel_id, uint8_t type,
                              uint32_t aes_id, uint8_t ges_id,
                              double rx_mhz, double tx_mhz,
                              void *user)
{
    (void)user;
    const char *type_names[] = {NULL, "distress", "flight_safety",
                                 "other_safety", "non_safety",
                                 NULL, NULL, NULL};
    const char *tn = (type <= 4) ? type_names[type] : "unknown";

    LOGI("CASSIGN: CH=%d AES=%06X GES=%u TYPE=%s RX=%.4fMHz TX=%.4fMHz",
         channel_id, aes_id, ges_id, tn, rx_mhz, tx_mhz);

    pthread_mutex_lock(&g_aero_msg_mtx);
    int room = (int)sizeof(g_aero_msg_buf) - g_aero_msg_len - 1;
    int n = snprintf(g_aero_msg_buf + g_aero_msg_len, (size_t)room,
                     "CALL CH=%d AES=%06X GES=%u TYPE=%s RX=%.4f TX=%.4f\n",
                     channel_id, aes_id, ges_id, tn, rx_mhz, tx_mhz);
    if (n > 0 && n < room) { g_aero_msg_len += n; }
    pthread_mutex_unlock(&g_aero_msg_mtx);
}

static void _aero_soft_bits_cb(const unsigned char *bits, int num_bits,
                                int channel_id, void *user)
{
    (void)user; (void)bits; (void)channel_id;
    static uint64_t total_bits = 0;
    total_bits += (uint64_t)num_bits;
    if (total_bits % (10500 * 8) < (uint64_t)num_bits)
        LOGI("VOICE: bits=%llu ch=%d", (unsigned long long)total_bits, channel_id);
}

/* Decoded frame callback — parses both C-channel (10-byte) and P-channel (12-byte) SUs.
 * P-channel SU layout: [0]=msg_type, [1-3]=AES, [4]=GES, [5-9]=payload, [10-11]=CRC. */
static void _aero_decoded_cb(const uint8_t *data, int len, void *user)
{
    (void)user;
    static int call_count = 0;
    call_count++;
    if (call_count <= 5 || call_count % 200 == 0)
        LOGI("DECODE_CB: call=%d len=%d", call_count, len);
    if (!data || len < 10) return;

    /* Detect P-channel: 12-byte SUs (with CRC appended) */
    if (len >= 12 && (len % 12) == 0) {
        int unit_size = 12;
        for (int i = 0; i + unit_size <= len; i += unit_size) {
            uint8_t msg = data[i];
            if (msg == 0x01) continue; /* Fill-in SU */
            uint32_t aes = ((uint32_t)data[i+1] << 16) | ((uint32_t)data[i+2] << 8) | (uint32_t)data[i+3];
            uint8_t  ges = data[i+4];
            uint8_t  p0  = data[i+5];
            uint8_t  p1  = data[i+6];
            uint8_t  p2  = data[i+7];
            uint8_t  p3  = data[i+8];
            uint8_t  p4  = data[i+9];
            /* CRC at p[i+10..11] — skip logging it */
            const char *type_name = NULL;
            switch (msg) {
                case 0x01: type_name = "FILL"; break;
                case 0x05: type_name = "SAT_BRD"; break;
                case 0x07: type_name = "SAT_BEAM"; break;
                case 0x0A: type_name = "SAT_IDX"; break;
                case 0x0C: type_name = "SAT_ID"; break;
                case 0x10: type_name = "LOGON_REQ"; break;
                case 0x11: type_name = "LOGON_CFM"; break;
                case 0x12: type_name = "LOGOFF"; break;
                case 0x13: type_name = "LOGON_REJ"; break;
                case 0x14: type_name = "LOGON_INT"; break;
                case 0x15: type_name = "LOGON_ACK"; break;
                case 0x16: type_name = "LOGON_PROMPT"; break;
                case 0x17: type_name = "REASSIGN"; break;
                case 0x21: type_name = "CALL_ANNC"; break;
                case 0x28: type_name = "EIRP_TBL"; break;
                case 0x30: type_name = "CALLPROG"; break;
                case 0x31: type_name = "C_ASSIGN_D"; break;
                case 0x32: type_name = "C_ASSIGN_F"; break;
                case 0x33: type_name = "C_ASSIGN_S"; break;
                case 0x34: type_name = "C_ASSIGN_N"; break;
                case 0x40: type_name = "P_R_CTRL"; break;
                case 0x41: type_name = "T_CTRL"; break;
                case 0x51: type_name = "T_ASSIGN"; break;
                case 0x61: type_name = "RQA"; break;
                case 0x62: type_name = "ACK"; break;
                case 0x71: type_name = "ISU_DATA"; break;
                case 0x74: type_name = "ISU_LSDU3"; break;
                case 0x76: type_name = "ISU_LSDU4"; break;
            }
            if (!type_name) type_name = "UNK";

            /* Extract voice channel frequency for C_ASSIGN only (T_ASSIGN uses
             * a different encoding — frequency comes from system table). */
            double rx_mhz = 0.0, tx_mhz = 0.0;
            int is_assign = (msg >= 0x31 && msg <= 0x34);

            /* ── SAT_ID (0x0C): satellite identification ──────────────────── */
            if (msg == 0x0C) {
                int satid = ((data[i+2] << 4) & 0x30) | ((data[i+3] >> 4) & 0x0F);
                int seqno = (data[i+2] >> 2) & 0x3F;
                double lon = (double)p0 * 1.5;
                int ch1 = ((p1 & 0x7F) << 8) | p2;
                int ch2 = ((p3 & 0x7F) << 8) | p4;
                double f1 = (double)ch1 * 0.0025 + 1510.0;
                double f2 = (double)ch2 * 0.0025 + 1510.0;
                const char *spot1 = (p1 & 0x80) ? " (Spot)" : "";
                const char *spot2 = (p3 & 0x80) ? " (Spot)" : "";
                LOGI("PCHAN: %s SatID=%d Seq=%d Long=%.1f%s Psmc1=%.4f%s Psmc2=%.4f%s",
                     type_name, satid, seqno, lon > 180.0 ? 360.0-lon : lon,
                     lon > 180.0 ? "W" : "E", f1, spot1, f2, spot2);
                pthread_mutex_lock(&g_aero_msg_mtx);
                int room = (int)sizeof(g_aero_msg_buf) - g_aero_msg_len - 1;
                int n = snprintf(g_aero_msg_buf + g_aero_msg_len, (size_t)room,
                         "P %s SatID=%d Seq=%d Long=%.1f%s Psmc1=%.4f%s Psmc2=%.4f%s\n",
                         type_name, satid, seqno, lon > 180.0 ? 360.0-lon : lon,
                         lon > 180.0 ? "W" : "E", f1, spot1, f2, spot2);
                if (n > 0 && n < room) { g_aero_msg_len += n; }
                pthread_mutex_unlock(&g_aero_msg_mtx);
                continue;
            }

            /* ── SAT_BRD (0x05): Psmc/Rsmc channel broadcast ──────────────── */
            if (msg == 0x05) {
                int seqno = (data[i+2] >> 2) & 0x3F;
                int lsu   = data[i+2] & 0x03;
                int ch1 = (p0 << 8) | p1;
                int ch2 = (p2 << 8) | p3;
                int ch3 = (p4 << 8) | data[i+10]; /* uses CRC byte */
                double f1 = (double)ch1 * 0.0025 + 1510.0;
                double f2 = (double)ch2 * 0.0025 + 1510.0;
                double f3 = (double)ch3 * 0.0025 + 1510.0;
                if (lsu <= 1) { f2 += 101.5; f3 += 101.5; }
                else { f1 += 101.5; f2 += 101.5; f3 += 101.5; }
                const char *label;
                if (lsu <= 1) label = "Psmc/Rsmc0/Rsmc1";
                else if (lsu == 2) label = "Rsmc2/Rsmc3/Rsmc4";
                else label = "Rsmc5/Rsmc6/Rsmc7";
                LOGI("PCHAN: %s GES=%u Seq=%d LSU=%d %s %.4f/%.4f/%.4f",
                     type_name, ges, seqno, lsu, label, f1, f2, f3);
                pthread_mutex_lock(&g_aero_msg_mtx);
                int room = (int)sizeof(g_aero_msg_buf) - g_aero_msg_len - 1;
                int n = snprintf(g_aero_msg_buf + g_aero_msg_len, (size_t)room,
                         "P %s GES=%u Seq=%d LSU=%d %s %.4f/%.4f/%.4f\n",
                         type_name, ges, seqno, lsu, label, f1, f2, f3);
                if (n > 0 && n < room) { g_aero_msg_len += n; }
                pthread_mutex_unlock(&g_aero_msg_mtx);
                continue;
            }
            if (is_assign) {
                int ch_rx = ((p1 & 0x7F) << 8) | p2;
                int ch_tx = ((p3 & 0x7F) << 8) | p4;
                rx_mhz = (double)ch_rx * 0.0025 + 1510.0;
                tx_mhz = (double)ch_tx * 0.0025 + 1611.5;
                LOGI("PCHAN: %s AES=%06X GES=%u RX=%.4f TX=%.4f %02X%02X%02X%02X%02X",
                     type_name, aes, ges, rx_mhz, tx_mhz, p0, p1, p2, p3, p4);
            } else if (msg == 0x51) {
                LOGI("PCHAN: %s AES=%06X GES=%u %02X%02X%02X%02X%02X",
                     type_name, aes, ges, p0, p1, p2, p3, p4);
            } else {
                LOGI("PCHAN: %s AES=%06X GES=%u %02X%02X%02X%02X%02X",
                     type_name, aes, ges, p0, p1, p2, p3, p4);
            }
            pthread_mutex_lock(&g_aero_msg_mtx);
            int room = (int)sizeof(g_aero_msg_buf) - g_aero_msg_len - 1;
            int n;
            if (is_assign) {
                n = snprintf(g_aero_msg_buf + g_aero_msg_len, (size_t)room,
                             "P %s AES=%06X GES=%u RX=%.4f TX=%.4f\n",
                             type_name, aes, ges, rx_mhz, tx_mhz);
            } else {
                n = snprintf(g_aero_msg_buf + g_aero_msg_len, (size_t)room,
                             "P %s AES=%06X GES=%u %02X%02X%02X%02X%02X\n",
                             type_name, aes, ges, p0, p1, p2, p3, p4);
            }
            if (n > 0 && n < room) { g_aero_msg_len += n; }
            pthread_mutex_unlock(&g_aero_msg_mtx);
        }
        return;
    }

    /* C-channel: 10-byte SUs */
    int unit_size = 10;
    for (int i = 0; i + unit_size <= len; i += unit_size) {
        uint8_t msg = data[i];
        if (msg != 0x30) continue; /* only Call_progress */
        uint32_t aes = ((uint32_t)data[i+1] << 16) | ((uint32_t)data[i+2] << 8) | (uint32_t)data[i+3];
        uint8_t  ges = data[i+4];
        uint8_t  p0  = data[i+5];
        uint8_t  p1  = data[i+6];
        uint8_t  p2  = data[i+7];
        uint8_t  p3  = data[i+8];
        uint8_t  p4  = data[i+9];
        LOGI("CALLPROG: AES=%06X GES=%u pl=%02X%02X%02X%02X%02X",
             aes, ges, p0, p1, p2, p3, p4);
        pthread_mutex_lock(&g_aero_msg_mtx);
        int room = (int)sizeof(g_aero_msg_buf) - g_aero_msg_len - 1;
        int n = snprintf(g_aero_msg_buf + g_aero_msg_len, (size_t)room,
                         "CALLPROG AES=%06X GES=%u %02X%02X%02X%02X%02X\n",
                         aes, ges, p0, p1, p2, p3, p4);
        if (n > 0 && n < room) { g_aero_msg_len += n; }
        pthread_mutex_unlock(&g_aero_msg_mtx);
    }
}

/* ── AERO demodulator dispatch helper ────────────────────────────────────── */

/* Feed IQ to whichever demodulator is active (MSK for ≤1200 bps, OQPSK for >1200) */
static inline void _aero_feed_demod_iq(const double *iq, int n) {
    if (g_aero_pmsk)
        jaero_pmsk_feed_iq(g_aero_pmsk, iq, n);
    else if (g_aero_demod)
        jaero_oqpsk_cont_feed_iq(g_aero_demod, iq, n);
}

static inline void _aero_feed_demod_audio(const int16_t *audio, int n) {
    if (g_aero_pmsk)
        jaero_pmsk_feed_audio(g_aero_pmsk, audio, n);
    else if (g_aero_demod)
        jaero_oqpsk_cont_feed_audio(g_aero_demod, audio, n);
}

static inline double _aero_get_mse(void) {
    if (g_aero_pmsk)  return jaero_pmsk_get_mse(g_aero_pmsk);
    if (g_aero_demod) return jaero_oqpsk_cont_get_mse(g_aero_demod);
    return 1.0;
}

static inline double _aero_get_ebno(void) {
    if (g_aero_pmsk)  return jaero_pmsk_get_ebno(g_aero_pmsk);
    if (g_aero_demod) return jaero_oqpsk_cont_get_ebno(g_aero_demod);
    return 0;
}

static inline int _aero_is_locked(void) {
    if (g_aero_pmsk)  return jaero_pmsk_is_locked(g_aero_pmsk);
    if (g_aero_demod) return jaero_oqpsk_cont_is_locked(g_aero_demod);
    return 0;
}

/* Feed raw 8-bit IQ through 4-stage halfband decimation pipeline (SDRReceiver hbcoeff23).
 * Each stage: insert into ring buffer, every other sample compute
 * FIR dot product (23-tap halfband, 12 nonzero) → 2:1 decimation. */
static void _aero_feed_iq(const uint8_t *iq, int n_iq_pairs)
{
    if ((!g_aero_demod && !g_aero_pmsk) || !g_aero_running) return;

    static double iq_buf[65536];
    static int iq_cnt = 0;
    static int64_t total_fed = 0;
    static double rms_sum = 0.0;
    static int rms_cnt = 0;
    const double scale = 1.0 / 128.0;

    for (int i = 0; i < n_iq_pairs; i++) {
        float xi = (float)(((double)(iq[i*2]   - 128)) * scale);
        float xq = (float)(((double)(iq[i*2+1] - 128)) * scale);

        if (_hb_init && !g_aero_boxcar_mode) {
            /* NCO mix at full rate — phasor rotation (no trig in hot loop) */
            if (_nco_si != 0.0) {
                double nr = (double)xi * _nco_c - (double)xq * _nco_s;
                double ni = (double)xi * _nco_s + (double)xq * _nco_c;
                xi = (float)nr; xq = (float)ni;

                /* Update phasor: c_next = c*ci - s*si, s_next = c*si + s*ci */
                double tc = _nco_c * _nco_ci - _nco_s * _nco_si;
                double ts = _nco_c * _nco_si + _nco_s * _nco_ci;
                _nco_c = tc; _nco_s = ts;
            }

            /* Insert into stage 0 ring buffer */
            _hb_ring_i[0][_hb_ridx[0]] = xi;
            _hb_ring_q[0][_hb_ridx[0]] = xq;
            _hb_ridx[0] = (_hb_ridx[0] + 1) % HB_TAPS;

            /* Stage 0: halfband output toggle */
            if (!_hb_skip[0]) {
                double out_i = 0.0, out_q = 0.0;
                int p = _hb_ridx[0];
                for (int j = 0; j < HB_TAPS; j++) {
                    out_i += (double)_hb_coeff[j] * (double)_hb_ring_i[0][p];
                    out_q += (double)_hb_coeff[j] * (double)_hb_ring_q[0][p];
                    if (++p >= HB_TAPS) p = 0;
                }
                xi = (float)out_i; xq = (float)out_q;
            }
            _hb_skip[0] = !_hb_skip[0];

            /* Stages 1-3: identical halfband + decimate.
             * Each stage inserts xi/xq into its ring, computes FIR every other
             * insertion, and saves its own output.  The saved output (not the
             * input xi) is forwarded to the next stage so skip cycles don't
             * leak a lower stage's value into a higher stage's ring. */
            for (int s = 1; s < HB_STAGES && !_hb_skip[s-1]; s++) {
                _hb_ring_i[s][_hb_ridx[s]] = xi;
                _hb_ring_q[s][_hb_ridx[s]] = xq;
                _hb_ridx[s] = (_hb_ridx[s] + 1) % HB_TAPS;

                if (!_hb_skip[s]) {
                    double out_i = 0.0, out_q = 0.0;
                    int p = _hb_ridx[s];
                    for (int j = 0; j < HB_TAPS; j++) {
                        out_i += (double)_hb_coeff[j] * (double)_hb_ring_i[s][p];
                        out_q += (double)_hb_coeff[j] * (double)_hb_ring_q[s][p];
                        if (++p >= HB_TAPS) p = 0;
                    }
                    _hb_out_i[s] = (float)out_i;
                    _hb_out_q[s] = (float)out_q;
                }
                _hb_skip[s] = !_hb_skip[s];

                /* Forward the SAVED output of this stage (not the input xi).
                 * On a skip cycle this correctly restores the last FIR output. */
                xi = _hb_out_i[s];
                xq = _hb_out_q[s];
            }

            /* After HB stages: AERO demod — feedIQ or feedAudio */
            if (!_hb_skip[HB_STAGES-1]) {
                float hi = xi, hq = xq;

                /* WAV recording: capture post-halfband IQ (NCO-shifted, USB overlay bandwidth) */
                if (g_aero_recording && g_aero_rec_file) {
                    int16_t si = (int16_t)(hi * 32767.0f);
                    int16_t sq = (int16_t)(hq * 32767.0f);
                    if (hi > 1.0f) si = 32767; else if (hi < -1.0f) si = -32768;
                    if (hq > 1.0f) sq = 32767; else if (hq < -1.0f) sq = -32768;
                    fwrite(&si, 2, 1, g_aero_rec_file);
                    fwrite(&sq, 2, 1, g_aero_rec_file);
                    g_aero_rec_samples++;
                }

                if (g_aero_feed_iq_mode) {
                    /* feedIQ: bypass our Hilbert USB, feed complex IQ directly.
                     * JAERO's internal 125-tap Hilbert handles USB demod,
                     * identical path to WAV decode (MSE 0.011 on ARM64). */
                    static double iq_buf[512];
                    static int iq_cnt = 0;

                    iq_buf[iq_cnt*2]   = (double)hi;
                    iq_buf[iq_cnt*2+1] = (double)hq;
                    iq_cnt++;

                    rms_sum += (double)hi*(double)hi + (double)hq*(double)hq;
                    rms_cnt++;

                    if (iq_cnt >= 256) {
                        _aero_feed_demod_iq(iq_buf, iq_cnt);
                        total_fed += iq_cnt;
                        double mse = _aero_get_mse();
                        double ebno = _aero_get_ebno();
                        int locked = _aero_is_locked();

                        static double rms_val = 0;
                        static int rms_n = 0;
                        rms_val += rms_sum; rms_n += rms_cnt;
                        rms_sum = 0; rms_cnt = 0;

                        if (total_fed % (256 * 8) == 0) {
                            LOGI("FEEDIQ: total=%lldK mse=%.3f ebno=%.1f locked=%d rms=%.3f",
                                 (long long)total_fed/1024, mse, ebno, locked,
                                 rms_n > 0 ? sqrt(rms_val / rms_n) : 0.0);
                            rms_val = rms_n = 0;
                        }
                        iq_cnt = 0;
                    }
                } else {
                /* Hilbert transform of I (FIRHilbert::FIRUpdateAndProcess) */
                _hilb_buff[_hilb_ptr] = hi;
                _hilb_buff[_hilb_ptr + HILB_TAPS] = hi;
                int start = _hilb_ptr + 1;
                if (start >= HILB_TAPS) start = 0;
                float *b = &_hilb_buff[start];
                float acc = 0.0f;
                for (int i = 1; i <= HILB_DELAY; i += 2)
                    acc += _hilb_pts[i] * (b[HILB_DELAY + i] - b[HILB_DELAY - i]);
                _hilb_ptr++;
                if (_hilb_ptr >= HILB_TAPS) _hilb_ptr = 0;

                /* Delay Q (delayT.update_dont_touch) */
                _hilb_delay[_hilb_didx] = hq;
                _hilb_didx = (_hilb_didx + 1) % (HILB_DELAY + 1);
                float delayed_q = _hilb_delay[_hilb_didx];

                /* USB = delay(Q) + hilbert(I) — SDRReceiver formula */
                float usb = delayed_q + acc;
                int16_t audio = (int16_t)(usb * 5.0f * 32768.0f);
                if (audio > 32767) audio = 32767;
                else if (audio < -32768) audio = -32768;

                /* Accumulate audio for bulk feed */
                static int16_t audio_buf[4096];
                static int audio_cnt = 0;
                audio_buf[audio_cnt++] = audio;
                rms_sum += (double)usb * (double)usb;
                rms_cnt++;

                if (audio_cnt >= 256) {
                    _aero_feed_demod_audio(audio_buf, audio_cnt);
                    total_fed += audio_cnt;
                    double mse = _aero_get_mse();
                    double ebno = _aero_get_ebno();
                    int locked = _aero_is_locked();

                    /* Also accumulate RMS of the output IQ for diagnostic */
                    static double rms_val = 0;
                    static int rms_n = 0;
                    rms_val += rms_sum; rms_n += rms_cnt;
                    rms_sum = 0; rms_cnt = 0;

                    if (total_fed % (256 * 32) == 0) {
                        LOGI("FEED: total=%lldK mse=%.3f ebno=%.1f locked=%d rms=%.3f",
                             (long long)total_fed/1024, mse, ebno, locked,
                             rms_n > 0 ? sqrt(rms_val / rms_n) : 0.0);
                        rms_val = rms_n = 0;
                    }
                    audio_cnt = 0;
                }
                } /* end feedAudio block */
            }
        } else if (_hb_init && g_aero_boxcar_mode) {
            /* NCO mix at full rate (same as halfband path) */
            if (_nco_si != 0.0) {
                double nr = (double)xi * _nco_c - (double)xq * _nco_s;
                double ni = (double)xi * _nco_s + (double)xq * _nco_c;
                xi = (float)nr; xq = (float)ni;
                double tc = _nco_c * _nco_ci - _nco_s * _nco_si;
                double ts = _nco_c * _nco_si + _nco_s * _nco_ci;
                _nco_c = tc; _nco_s = ts;
            }

            /* Boxcar averaging decimation: accumulate 16 samples, output 1.
             * No halfband — zero phase distortion, zero filter bugs. */
            static double bc_i = 0.0, bc_q = 0.0;
            static int bc_n = 0;
            bc_i += (double)xi; bc_q += (double)xq;
            if (++bc_n >= g_aero_boxcar_n) {
                float hi = (float)(bc_i / (double)g_aero_boxcar_n);
                float hq = (float)(bc_q / (double)g_aero_boxcar_n);
                bc_i = 0.0; bc_q = 0.0; bc_n = 0;

                /* WAV recording of boxcar-decimated IQ */
                if (g_aero_recording && g_aero_rec_file) {
                    int16_t si = (int16_t)(hi * 32767.0f);
                    int16_t sq = (int16_t)(hq * 32767.0f);
                    if (hi > 1.0f) si = 32767; else if (hi < -1.0f) si = -32768;
                    if (hq > 1.0f) sq = 32767; else if (hq < -1.0f) sq = -32768;
                    fwrite(&si, 2, 1, g_aero_rec_file);
                    fwrite(&sq, 2, 1, g_aero_rec_file);
                    g_aero_rec_samples++;
                }

                /* Feed to JAERO — always use feedIQ in boxcar mode */
                {
                    static double iq_fb[512]; static int iq_fc = 0;
                    iq_fb[iq_fc*2] = (double)hi; iq_fb[iq_fc*2+1] = (double)hq;
                    iq_fc++;
                    rms_sum += (double)hi*(double)hi + (double)hq*(double)hq;
                    rms_cnt++;
                    if (iq_fc >= 256) {
                        _aero_feed_demod_iq(iq_fb, iq_fc);
                        total_fed += iq_fc;
                        if (total_fed % (256 * 8) == 0) {
                            double mse = _aero_get_mse();
                            double ebno = _aero_get_ebno();
                            int locked = _aero_is_locked();
                            static double rms_v = 0; static int rms_n = 0;
                            rms_v += rms_sum; rms_n += rms_cnt;
                            rms_sum = 0; rms_cnt = 0;
                            LOGI("BCIQ: total=%lldK mse=%.3f ebno=%.1f locked=%d rms=%.3f",
                                 (long long)total_fed/1024, mse, ebno, locked,
                                 rms_n > 0 ? sqrt(rms_v / rms_n) : 0.0);
                            rms_v = rms_n = 0;
                        }
                        iq_fc = 0;
        }
    }
}
        } else {
            /* No halfband, no NCO — raw boxcar fallback */
            static int64_t acc_i = 0, acc_q = 0;
            static int acc_n = 0;
            acc_i += (int16_t)(iq[i*2]   - 128);
            acc_q += (int16_t)(iq[i*2+1] - 128);
            if (++acc_n >= g_aero_boxcar_n) {
                iq_buf[iq_cnt*2]   = ((double)acc_i / g_aero_boxcar_n) / 128.0;
                iq_buf[iq_cnt*2+1] = ((double)acc_q / g_aero_boxcar_n) / 128.0;
                iq_cnt++; acc_i = acc_q = 0; acc_n = 0;
                if (iq_cnt >= 256) {
                    _aero_feed_demod_iq(iq_buf, iq_cnt);
                    total_fed += iq_cnt;
                    double mse = _aero_get_mse();
                    double ebno = _aero_get_ebno();
                    int locked = _aero_is_locked();
                    if (total_fed % (256 * 16) == 0)
                        LOGI("FEED: total=%lldK mse=%.3f ebno=%.1f locked=%d",
                             (long long)total_fed/1024, mse, ebno, locked);
                    iq_cnt = 0;
                }
            }
        }
    }
}

/* AMBE voice frame callback — receives 12-byte frames (96 bits) at 50 fps.
 * Frames are deinterleaved and fed to mbelib AMBE4800 decoder → 160 int16 PCM. */
static void _aero_voice_cb(const uint8_t *ambe_frame, int frame_bytes, void *user)
{
    (void)user;
    static int vfc = 0;
    vfc++;
    if (!ambe_frame || frame_bytes != 12) return;

    /* One-time AMBE state init */
    if (!g_ambe_init) {
        mbe_initMbeParms(&g_ambe_cur, &g_ambe_prev, &g_ambe_prev_enhanced);
        g_ambe_init = 1;
        LOGI("AMBE: vocoder init OK");
    }

    /* Unpack 12 bytes → 96 bits (LSB-first per byte, matches JAERO) */
    unsigned char ambe_bits[96];
    for (int i = 0; i < 12; i++) {
        uint8_t b = ambe_frame[i];
        for (int j = 0; j < 8; j++)
            ambe_bits[i * 8 + j] = (b >> j) & 1;
    }

    /* Deinterleave: 96 bits → 6 codewords × 24 bits.
     * Tables from libaeroambe/aeroambe.h — exact JAERO AeroAMBE mapping.
     * rW = which codeword (0-5), rX = bit position within codeword (0-23). */
    static const unsigned char rW[96] = {
        0,0,1,1,2,3,4,5, 0,0,1,1,2,3,4,5, 0,0,1,1,2,3,4,5, 0,0,1,2,2,3,4,5,
        0,0,1,2,2,3,4,5, 0,0,1,2,2,3,4,5, 0,0,1,2,3,3,4,5, 0,0,1,2,3,3,4,5,
        0,0,1,2,3,3,4,5, 0,0,1,2,3,4,4,5, 0,0,1,2,3,4,5,5, 0,0,1,2,3,4,5,5
    };
    static const unsigned char rX[96] = {
        23,11,14,2,5,8,9,11, 22,10,13,1,4,7,8,10, 21,9,12,0,3,6,7,9, 20,8,11,14,2,5,6,8,
        19,7,10,13,1,4,5,7, 18,6,9,12,0,3,4,6, 17,5,8,11,14,2,3,5, 16,4,7,10,13,1,2,4,
        15,3,6,9,12,0,1,3, 14,2,5,8,11,12,0,2, 13,1,4,7,10,11,13,1, 12,0,3,6,9,10,12,0
    };
    char ambe_fr[6][24];
    memset(ambe_fr, 0, sizeof(ambe_fr));
    for (int i = 0; i < 96; i++)
        ambe_fr[rW[i]][(int)rX[i]] = (char)ambe_bits[i];

    /* ECC + decode → 160 int16 PCM samples */
    char ambe_d[72];
    int errs = 0, errs2 = 0;
    char err_str[64];
    short pcm[160];
    memset(pcm, 0, sizeof(pcm));

    mbe_processAmbe4800x3600Frame(pcm, &errs, &errs2, err_str,
                                   ambe_fr, ambe_d,
                                   &g_ambe_cur, &g_ambe_prev,
                                   &g_ambe_prev_enhanced, 1);

    if (vfc <= 3 || vfc % 125 == 0)
        LOGI("AMBE: frame=%d errs=%d/%d pcm0=%d",
             vfc, errs, errs2, (int)pcm[0]);

    /* Lazy-init AAudio output stream (8 kHz, mono, int16) */
    if (!g_audio_out) {
        AAudioStreamBuilder *bld;
        if (AAudio_createStreamBuilder(&bld) == AAUDIO_OK) {
            AAudioStreamBuilder_setFormat(bld, AAUDIO_FORMAT_PCM_I16);
            AAudioStreamBuilder_setChannelCount(bld, 1);
            AAudioStreamBuilder_setSampleRate(bld, 8000);
            AAudioStreamBuilder_setDirection(bld, AAUDIO_DIRECTION_OUTPUT);
            AAudioStreamBuilder_setSharingMode(bld, AAUDIO_SHARING_MODE_SHARED);
            AAudioStreamBuilder_setBufferCapacityInFrames(bld, 8000 * 2);  /* 2 sec buffer for bursty C-channel */
            aaudio_result_t r = AAudioStreamBuilder_openStream(bld, &g_audio_out);
            AAudioStreamBuilder_delete(bld);
            if (r == AAUDIO_OK && g_audio_out) {
                AAudioStream_requestStart(g_audio_out);
                LOGI("AMBE: audio output opened (8kHz mono)");
            }
        }
    }

    /* Write decoded PCM to audio output */
    if (g_audio_out) {
        aaudio_result_t wr = AAudioStream_write(g_audio_out, pcm, 160, 0LL);
        if (wr < 0 && vfc % 50 == 0)
            LOGI("AMBE: audio write err %d", wr);
    }
}

/* ── AERO ring buffer: decouple RTL callback from AERO feed processing ────
 * The RTL async callback must return quickly to avoid USB buffer overflows.
 * Copy raw IQ to a ring buffer here and signal a dedicated AERO thread that
 * does the heavy boxcar decimation, NCO rotation, and JAERO demod feed. */
#define AERO_RB_SIZE  (256 * 1024)  /* 256 KB — ~16 RTL callback chunks */
static uint8_t        *g_aero_rb     = NULL;
static volatile int    g_aero_rb_wr  = 0;
static volatile int    g_aero_rb_rd  = 0;
static int             g_aero_rb_mask = 0;
static pthread_mutex_t g_aero_rb_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_aero_rb_cond = PTHREAD_COND_INITIALIZER;
static pthread_t       g_aero_thread;
static volatile int    g_aero_thread_running = 0;

static int aero_rb_avail(void)
{
    int wr = g_aero_rb_wr, rd = g_aero_rb_rd;
    return (wr >= rd) ? (wr - rd) : (AERO_RB_SIZE + wr - rd);
}

static int aero_rb_space(void)
{
    return AERO_RB_SIZE - aero_rb_avail() - 1;
}

static void *aero_thread_fn(void *arg)
{
    (void)arg;
    /* Allocate local buffer for processing — same size as what _aero_feed_iq
     * expects (n_iq_pairs int8 pairs). */
    uint8_t *local = (uint8_t *)malloc(131072);  /* 128K IQ pairs = 256K bytes */
    if (!local) { LOGE("AERO thread: malloc failed"); return NULL; }

    while (g_aero_thread_running) {
        pthread_mutex_lock(&g_aero_rb_mtx);
        while (g_aero_thread_running && aero_rb_avail() == 0)
            pthread_cond_wait(&g_aero_rb_cond, &g_aero_rb_mtx);
        if (!g_aero_thread_running) {
            pthread_mutex_unlock(&g_aero_rb_mtx);
            break;
        }
        int avail = aero_rb_avail();
        int to_copy = avail;
        if (to_copy > 131072) to_copy = 131072;

        /* Copy from ring buffer (may wrap) */
        int rd = g_aero_rb_rd;
        int first = AERO_RB_SIZE - rd;
        if (to_copy <= first) {
            memcpy(local, g_aero_rb + rd, (size_t)to_copy);
        } else {
            memcpy(local, g_aero_rb + rd, (size_t)first);
            memcpy(local + first, g_aero_rb, (size_t)(to_copy - first));
        }
        g_aero_rb_rd = (rd + to_copy) & g_aero_rb_mask;
        pthread_mutex_unlock(&g_aero_rb_mtx);

        /* Process locally — _aero_feed_iq expects n_iq_pairs, not bytes.
         * Feed in pairs (interleaved I/Q uint8_t). */
        _aero_feed_iq(local, to_copy / 2);
    }
    free(local);
    return NULL;
}

/* ── Async callback for rtlsdr_read_async ─────────────────────────────────── */

struct AeroFFTCtx {
    int      fft_size;
    float   *re, *im, *acc, *tmp;
    int      frame_count;       /* FFT frames accumulated this averaging round */
    uint8_t *partial;           /* leftover IQ bytes from previous callback */
    int      partial_len;       /* bytes valid in partial[] */
};

static void _aero_async_cb(unsigned char *buf, uint32_t len_bytes, void *ctx)
{
    if (!g_running) return;
    if (len_bytes == 0 || (len_bytes & 1)) return;

    struct AeroFFTCtx *c = (struct AeroFFTCtx *)ctx;
    int n_iq   = (int)len_bytes / 2;
    int fft_n  = c->fft_size;
    int fft_bytes = fft_n * 2;
    int consumed = 0;

    /* --- AERO feed: copy to ring buffer, signal dedicated thread */
    if ((g_aero_demod || g_aero_pmsk) && g_aero_running) {
        pthread_mutex_lock(&g_aero_rb_mtx);
        int space = aero_rb_space();
        int to_copy = ((int)len_bytes < space) ? (int)len_bytes : space;
        if (to_copy > 0) {
            int wr = g_aero_rb_wr;
            int first = AERO_RB_SIZE - wr;
            if (to_copy <= first) {
                memcpy(g_aero_rb + wr, buf, (size_t)to_copy);
            } else {
                memcpy(g_aero_rb + wr, buf, (size_t)first);
                memcpy(g_aero_rb, buf + first, (size_t)(to_copy - first));
            }
            g_aero_rb_wr = (wr + to_copy) & g_aero_rb_mask;
            pthread_cond_signal(&g_aero_rb_cond);
        } else {
            /* Ring full — drop data rather than block the RTL callback */
            static int drops = 0;
            if (++drops % 100 == 1)
                LOGE("AERO rb: dropped chunk (ring full, %d drops)", drops);
        }
        pthread_mutex_unlock(&g_aero_rb_mtx);
    }

    /* --- Raw IQ recording: capture unprocessed 8-bit RTL IQ, convert to 16-bit signed WAV */
    if (g_aero_recording_raw && g_aero_rec_raw_file) {
        for (uint32_t i = 0; i < len_bytes; i += 2) {
            int16_t si = (int16_t)((int)(buf[i])   - 128) * 256;
            int16_t sq = (int16_t)((int)(buf[i+1]) - 128) * 256;
            fwrite(&si, 2, 1, g_aero_rec_raw_file);
            fwrite(&sq, 2, 1, g_aero_rec_raw_file);
        }
        g_aero_rec_raw_bytes += len_bytes;  /* still track original 8-bit bytes for header sizing */
    }

    /* --- FFT accumulation: build complete fft_n-IQ-pair frames from the stream */
    /* 1) Complete any partial frame left over from the previous callback */
    if (c->partial_len > 0) {
        int needed = fft_bytes - c->partial_len;
        int to_copy = ((int)len_bytes < needed) ? (int)len_bytes : needed;
        memcpy(c->partial + c->partial_len, buf, (size_t)to_copy);
        c->partial_len += to_copy;
        consumed += to_copy;
        if (c->partial_len == fft_bytes) {
            _accumulate_power(c->partial, fft_n, c->re, c->im, c->acc);
            c->frame_count++;
            c->partial_len = 0;
        }
    }

    /* 2) Process full, aligned frames */
    while (consumed + fft_bytes <= (int)len_bytes) {
        _accumulate_power(buf + consumed, fft_n, c->re, c->im, c->acc);
        c->frame_count++;
        consumed += fft_bytes;
    }

    /* 3) Stash leftover for next callback */
    if (consumed < (int)len_bytes) {
        int leftover = (int)len_bytes - consumed;
        memcpy(c->partial, buf + consumed, (size_t)leftover);
        c->partial_len = leftover;
    }

    /* --- Publish FFT frame when we have enough spectra averaged */
    if (c->frame_count >= FFT_AVG_N) {
        int fc = c->frame_count;          /* may be > FFT_AVG_N; use all */
        float inv = 1.0f / (float)fc;

        for (int i = 0; i < fft_n; i++) {
            float p  = c->acc[i] * inv;
            c->tmp[i] = (p > 1e-30f) ? 10.0f * log10f(p) : MIN_DB;
        }

        /* Supress DC spike */
        int dc = fft_n / 2;
        c->tmp[dc] = (c->tmp[dc - 2] + c->tmp[dc - 1] + c->tmp[dc + 1] + c->tmp[dc + 2]) * 0.25f;

        /* Signal level: peak over centre 25% */
        float peak = MIN_DB;
        int lo = fft_n * 3 / 8, hi = fft_n * 5 / 8;
        for (int i = lo; i < hi; i++)
            if (c->tmp[i] > peak) peak = c->tmp[i];
        g_signal_db = peak;

        pthread_mutex_lock(&g_fft_mtx);
        memcpy(g_fft_out, c->tmp, (size_t)fft_n * sizeof(float));
        g_fft_cnt++;
        pthread_mutex_unlock(&g_fft_mtx);

        /* Reset for next round */
        c->frame_count = 0;
        memset(c->acc, 0, (size_t)fft_n * sizeof(float));
    }
}

/* ── Background read / async-FFT thread ───────────────────────────────────── */

static void *_rf_thread(void *arg)
{
    (void)arg;
    int n = g_fft_size;

    struct AeroFFTCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.fft_size = n;
    ctx.re  = (float *)malloc((size_t)n * sizeof(float));
    ctx.im  = (float *)malloc((size_t)n * sizeof(float));
    ctx.acc = (float *)calloc((size_t)n, sizeof(float));
    ctx.tmp = (float *)malloc((size_t)n * sizeof(float));
    ctx.partial = (uint8_t *)malloc((size_t)(n * 2));

    if (!ctx.re || !ctx.im || !ctx.acc || !ctx.tmp || !ctx.partial) {
        free(ctx.re); free(ctx.im); free(ctx.acc); free(ctx.tmp); free(ctx.partial);
        g_running = 0;
        return NULL;
    }

    LOGI("rf_thread: starting rtlsdr_read_async (fft=%d avg=%d)", n, FFT_AVG_N);
    rtlsdr_read_async(g_dev, _aero_async_cb, &ctx, 0, 0);
    LOGI("rf_thread: rtlsdr_read_async returned");

    free(ctx.re); free(ctx.im); free(ctx.acc); free(ctx.tmp); free(ctx.partial);
    g_running = 0;
    return NULL;
}

/* ── Public API ──────────────────────────────────────────────────────────── */

int32_t rf_open(int32_t fd, const char *path, int32_t fft_size)
{
    if (g_dev) { rtlsdr_close(g_dev); g_dev = NULL; }
    g_usb_fd = (int)fd;
    free(g_fft_out); g_fft_out = NULL;

    /* fft_size must be a power of 2 and divisible by 1024 (RTL-SDR read constraint) */
    if (fft_size < 512) fft_size = 512;
    /* Round up to next multiple of 512 and nearest power of 2 */
    int sz = 512;
    while (sz < fft_size) sz <<= 1;
    g_fft_size = sz;

    g_fft_out = (float *)calloc((size_t)g_fft_size, sizeof(float));
    if (!g_fft_out) return -2;

    if (rtlsdr_open2(&g_dev, (int)fd, path) != 0) { LOGE("rf_open FAIL: rtlsdr_open2"); return -1; }
    LOGI("rf_open OK: g_dev=%p fft=%d", g_dev, g_fft_size);

    rtlsdr_set_sample_rate(g_dev, DEFAULT_SAMPLE_RATE);
    rtlsdr_set_center_freq(g_dev, DEFAULT_CENTER_FREQ);
    rtlsdr_set_tuner_gain_mode(g_dev, 0);   /* auto tuner gain */
    rtlsdr_set_agc_mode(g_dev, 1);
    rtlsdr_reset_buffer(g_dev);

    g_signal_db = MIN_DB;
    g_fft_cnt   = 0;

    return 0;
}

void rf_set_frequency(uint32_t hz)
{
    if (g_dev) {
        int r = rtlsdr_set_center_freq(g_dev, hz);
        LOGI("set_freq: %u Hz (rtlsdr=%d, async_running=%d)", hz, r, g_running);
        if (!g_running) rtlsdr_reset_buffer(g_dev);
    }
}

void rf_set_sample_rate(uint32_t sps)
{
    if (g_dev) {
        rtlsdr_set_sample_rate(g_dev, sps);
        if (!g_running) rtlsdr_reset_buffer(g_dev);
        g_aero_rate = (int)sps;
    }
}

void rf_set_gain(int32_t tenths_db)
{
    if (!g_dev) return;
    if (tenths_db < 0) {
        rtlsdr_set_tuner_gain_mode(g_dev, 0);   /* auto */
    } else {
        rtlsdr_set_tuner_gain_mode(g_dev, 1);
        rtlsdr_set_tuner_gain(g_dev, (int)tenths_db);
    }
}

void rf_set_bias_tee(int32_t on)
{
    if (!g_dev) return;
    int r = rtlsdr_set_bias_tee(g_dev, on ? 1 : 0);
    LOGI("bias_tee %s (r=%d)", on ? "ON" : "OFF", r);
}

int32_t rf_start(void)
{
    LOGI("rf_start: g_dev=%p g_running=%d", g_dev, g_running);
    if (!g_dev || g_running) {
        LOGE("rf_start FAIL: g_dev=%p g_running=%d", g_dev, g_running);
        return -1;
    }
    g_running = 1;
    if (pthread_create(&g_thread, NULL, _rf_thread, NULL) != 0) {
        g_running = 0;
        LOGE("rf_start FAIL: pthread_create failed");
        return -1;
    }
    LOGI("rf_start OK");
    return 0;
}

int64_t rf_poll_fft(float *out_db, int32_t n)
{
    if (!g_fft_out || n <= 0) return g_fft_cnt;
    int copy = (n < g_fft_size) ? n : g_fft_size;
    pthread_mutex_lock(&g_fft_mtx);
    memcpy(out_db, g_fft_out, (size_t)copy * sizeof(float));
    int64_t cnt = g_fft_cnt;
    pthread_mutex_unlock(&g_fft_mtx);
    return cnt;
}

float rf_get_signal_db(void)
{
    return g_signal_db;
}

void rf_stop(void)
{
    if (!g_running) return;
    g_running = 0;
    if (g_dev) rtlsdr_cancel_async(g_dev);
    pthread_join(g_thread, NULL);
}

void rf_close(void)
{
    rf_stop();
    if (g_dev) { rtlsdr_close(g_dev); g_dev = NULL; }
    free(g_fft_out); g_fft_out = NULL;
    if (g_aero_rb) { free(g_aero_rb); g_aero_rb = NULL; }
}

/*
 * rf_dup_usb_fd — duplicate the Android USB file descriptor.
 *
 * Call this BEFORE rf_close() to obtain a fresh fd that remains valid
 * after libusb closes its internal copy.  The caller (e.g. rtl_433) owns
 * the returned fd and must not close it explicitly (libusb inside
 * librtl433_ffi.so will dup it again for its own use).
 *
 * Returns the new fd on success, -1 if no device has been opened yet.
 */
int32_t rf_dup_usb_fd(void)
{
    if (g_usb_fd < 0) return -1;
    return (int32_t)dup(g_usb_fd);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * PAGER DECODE MODE  (POCSAG 512/1200/2400, FLEX, FLEX_NEXT)
 *
 * rf_stop() must be called before rf_start_pager().  g_dev is reused.
 * ═══════════════════════════════════════════════════════════════════════════ */

/* ── multimon-ng required globals (defined once for the whole library) ────── */

int  json_mode = 0;
void addJsonTimestamp(cJSON *json_output) { (void)json_output; }

/* ── Callback type ──────────────────────────────────────────────────────────*/

typedef void (*pager_cb_t)(int32_t protocol_id,
                            uint32_t address,
                            int32_t  function,
                            char    *message,
                            int64_t  timestamp_ms);

/* ── Active line dispatcher (shared between RTL and HackRF pager paths) ──── *
 * Set to the currently-active path's dispatch function before starting.     *
 * pager_hackrf.c sets this via the extern declaration below.               */

typedef void (*_pager_dispatch_fn_t)(const char *line);
_pager_dispatch_fn_t g_pager_active_dispatch = NULL;

/* ── _verbprintf (called by multimon-ng decoders, one definition per .so) ── */

static char   _g_vp_line[2048];
static size_t _g_vp_len = 0;

void _verbprintf(int verb_level, const char *fmt, ...)
{
    if (verb_level != 0) return;
    va_list args;
    va_start(args, fmt);
    int w = vsnprintf(_g_vp_line + _g_vp_len,
                      sizeof(_g_vp_line) - _g_vp_len, fmt, args);
    va_end(args);
    if (w > 0) _g_vp_len += (size_t)w;

    char *nl;
    while ((nl = (char *)memchr(_g_vp_line, '\n', _g_vp_len)) != NULL) {
        *nl = '\0';
        if (g_pager_active_dispatch) g_pager_active_dispatch(_g_vp_line);
        size_t rest = _g_vp_len - (size_t)(nl + 1 - _g_vp_line);
        memmove(_g_vp_line, nl + 1, rest);
        _g_vp_len = rest;
    }
    if (_g_vp_len >= sizeof(_g_vp_line) - 1) _g_vp_len = 0;
}

/* ── RTL pager parameters ─────────────────────────────────────────────────── */

#define PAGER_SAMPLE_RATE  250000u
#define PAGER_AUDIO_RATE   22050u
#define PAGER_BUF_BYTES    (16384 * 2)
#define PAGER_FM_SAMPLES   (PAGER_BUF_BYTES / 2)
#define PAGER_SRC_MAX      4096
#define PAGER_NUM_DEMODS   5

static const struct demod_param *g_pager_demods[PAGER_NUM_DEMODS] = {
    &demod_poc5,
    &demod_poc12,
    &demod_poc24,
    &demod_flex,
    &demod_flex_next,
};

static struct demod_state  g_pager_dem[PAGER_NUM_DEMODS];
static volatile int        g_pager_running  = 0;
static pthread_t           g_pager_thread;
static pager_cb_t          g_pager_callback = NULL;

/* FM discriminator state */
static float  g_pager_prev_i   = 0.0f;
static float  g_pager_prev_q   = 0.0f;
static double g_pager_src_phase = 0.0;

static void _pager_fm_demod(const uint8_t *iq, int n, float *audio)
{
    for (int i = 0; i < n; i++) {
        float ci = (iq[i * 2]     - 127.5f) * (1.0f / 127.5f);
        float cq = (iq[i * 2 + 1] - 127.5f) * (1.0f / 127.5f);
        float cross = ci * g_pager_prev_q - cq * g_pager_prev_i;
        float dot   = ci * g_pager_prev_i + cq * g_pager_prev_q;
        audio[i]    = atan2f(cross, dot);
        g_pager_prev_i = ci;
        g_pager_prev_q = cq;
    }
}

static int _pager_src(const float *in, int n_in, float *out, int out_max)
{
    const double ratio = (double)PAGER_AUDIO_RATE / PAGER_SAMPLE_RATE;
    int n_out = 0;
    while (n_out < out_max) {
        int idx = (int)g_pager_src_phase;
        if (idx + 1 >= n_in) break;
        float frac = (float)(g_pager_src_phase - idx);
        out[n_out++] = in[idx] + frac * (in[idx + 1] - in[idx]);
        g_pager_src_phase += 1.0 / ratio;
    }
    int consumed = (int)g_pager_src_phase;
    if (consumed > n_in) consumed = n_in;
    g_pager_src_phase -= consumed;
    return n_out;
}

static int64_t _pager_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void _rtl_dispatch_line(const char *line)
{
    if (!g_pager_callback) return;

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
    g_pager_callback(proto, address, function, message, _pager_now_ms());
}

static void *_pager_thread_fn(void *arg)
{
    (void)arg;
    static uint8_t iq_buf[PAGER_BUF_BYTES];
    static float   fm_buf[PAGER_FM_SAMPLES];
    static float   audio_buf[PAGER_SRC_MAX];

    while (g_pager_running) {
        int n_read = 0;
        int r = rtlsdr_read_sync(g_dev, iq_buf, PAGER_BUF_BYTES, &n_read);
        if (r < 0 || n_read <= 0) {
            LOGE("pager rtlsdr_read_sync error %d", r);
            break;
        }
        int n_iq = n_read / 2;
        _pager_fm_demod(iq_buf, n_iq, fm_buf);
        int n_audio = _pager_src(fm_buf, n_iq, audio_buf, PAGER_SRC_MAX);
        if (n_audio <= 0) continue;
        buffer_t mbuf = { .sbuffer = NULL, .fbuffer = audio_buf };
        for (int i = 0; i < PAGER_NUM_DEMODS; i++)
            g_pager_demods[i]->demod(&g_pager_dem[i], mbuf, n_audio);
    }
    return NULL;
}

/* ── Public pager API ───────────────────────────────────────────────────── */

int32_t rf_start_pager(pager_cb_t callback)
{
    if (!g_dev || g_pager_running) return -1;

    rtlsdr_set_sample_rate(g_dev, PAGER_SAMPLE_RATE);
    rtlsdr_reset_buffer(g_dev);

    for (int i = 0; i < PAGER_NUM_DEMODS; i++) {
        memset(&g_pager_dem[i], 0, sizeof(g_pager_dem[i]));
        g_pager_dem[i].dem_par = g_pager_demods[i];
        g_pager_demods[i]->init(&g_pager_dem[i]);
    }

    g_pager_prev_i = g_pager_prev_q = 0.0f;
    g_pager_src_phase = 0.0;
    _g_vp_len = 0;

    g_pager_callback = callback;
    g_pager_active_dispatch = _rtl_dispatch_line;
    g_pager_running = 1;

    if (pthread_create(&g_pager_thread, NULL, _pager_thread_fn, NULL) != 0) {
        g_pager_running = 0;
        g_pager_active_dispatch = NULL;
        LOGE("rf_start_pager: pthread_create failed");
        return -1;
    }
    LOGI("Pager decode thread started (RTL, rate=%u)", PAGER_SAMPLE_RATE);
    return 0;
}

void rf_stop_pager(void)
{
    if (!g_pager_running) return;
    g_pager_running = 0;
    g_pager_active_dispatch = NULL;
    if (g_dev) rtlsdr_reset_buffer(g_dev);
    pthread_join(g_pager_thread, NULL);
    for (int i = 0; i < PAGER_NUM_DEMODS; i++)
        g_pager_demods[i]->deinit(&g_pager_dem[i]);
    g_pager_callback = NULL;
    LOGI("Pager decode thread stopped");
}

void rf_pager_free(void *ptr)
{
    free(ptr);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * WFM / NFM DEMODULATE MODE
 *
 * Uses whatever sample rate is currently set (no rate change on start).
 * WFM: 75µs de-emphasis, full FM deviation audio.
 * NFM: 25µs de-emphasis, higher-pass feel for voice comms.
 * ═══════════════════════════════════════════════════════════════════════════ */

#define WFM_AUDIO_RATE    48000u
#define WFM_BUF_BYTES     (16384 * 2)
#define WFM_FM_SAMPLES    (WFM_BUF_BYTES / 2)
#define WFM_AUDIO_MAX     8192
#define WFM_RING_SIZE     (WFM_AUDIO_RATE * 2)

typedef enum { DEMOD_WFM = 0, DEMOD_NFM = 1 } DemodMode;

static int16_t g_wfm_ring[WFM_RING_SIZE];
static size_t  g_wfm_rd   = 0;
static size_t  g_wfm_wr   = 0;
static pthread_mutex_t g_wfm_mtx = PTHREAD_MUTEX_INITIALIZER;

static volatile int g_wfm_running = 0;
static pthread_t    g_wfm_thread;
static DemodMode    g_demod_mode  = DEMOD_WFM;

/* FM discriminator state */
static float  g_wfm_prev_i    = 0.0f;
static float  g_wfm_prev_q    = 0.0f;
static double g_wfm_src_phase = 0.0;
static float  g_wfm_deemph   = 0.0f;

/* ── 4th-order Butterworth LP (two cascaded biquads, double precision) ────
 *
 * Running the IIR at the full input rate then keeping every Dth output
 * is the standard polyphase approach.  Double precision is required
 * because at very low normalised cutoff (e.g. NFM 12 kHz / 2.4 MHz =
 * 0.01) the biquad poles are close to the unit circle and float32 loses
 * too many significant bits.
 *
 * g_wfm_decim_idx persists across blocks so the decimation phase never
 * slips at block boundaries (the root cause of the earlier garbling).  */

static double g_iir_b0[2], g_iir_b1[2], g_iir_b2[2];
static double g_iir_a1[2], g_iir_a2[2];
static double g_iir_xi1[2], g_iir_xi2[2], g_iir_yi1[2], g_iir_yi2[2];
static double g_iir_xq1[2], g_iir_xq2[2], g_iir_yq1[2], g_iir_yq2[2];
static int    g_wfm_decim_idx = 0;  /* persistent position within decim cycle */

/* Design one biquad section of a Butterworth LP.
 * wc: normalised cutoff = f_cutoff / (fs/2).  Q: section quality factor. */
static void _design_biquad(double wc, double Q,
                             double *b0, double *b1, double *b2,
                             double *a1, double *a2)
{
    double wa  = tan(3.14159265358979 * wc * 0.5);
    double wa2 = wa * wa;
    double d   = 1.0 + wa / Q + wa2;
    *b0 = wa2 / d;
    *b1 = 2.0 * (*b0);
    *b2 = *b0;
    *a1 = 2.0 * (wa2 - 1.0) / d;
    *a2 = (1.0 - wa / Q + wa2) / d;
}

/* 4th-order Butterworth LP = two biquads with Q = 0.5412 and 1.3066. */
static void _design_butterworth4(double wc)
{
    _design_biquad(wc, 0.54120, &g_iir_b0[0], &g_iir_b1[0], &g_iir_b2[0],
                   &g_iir_a1[0], &g_iir_a2[0]);
    _design_biquad(wc, 1.30656, &g_iir_b0[1], &g_iir_b1[1], &g_iir_b2[1],
                   &g_iir_a1[1], &g_iir_a2[1]);
    memset(g_iir_xi1, 0, sizeof(g_iir_xi1));
    memset(g_iir_xi2, 0, sizeof(g_iir_xi2));
    memset(g_iir_yi1, 0, sizeof(g_iir_yi1));
    memset(g_iir_yi2, 0, sizeof(g_iir_yi2));
    memset(g_iir_xq1, 0, sizeof(g_iir_xq1));
    memset(g_iir_xq2, 0, sizeof(g_iir_xq2));
    memset(g_iir_yq1, 0, sizeof(g_iir_yq1));
    memset(g_iir_yq2, 0, sizeof(g_iir_yq2));
    g_wfm_decim_idx = 0;
}

/* Apply 4th-order IIR at full rate, keep every decim-th sample, FM-demod. */
static int _wfm_decimate_demod(const uint8_t *iq, int n_iq,
                                float *out, int decim)
{
    int n_out = 0;
    for (int i = 0; i < n_iq; i++) {
        double xi = (iq[i*2]   - 127.5) * (1.0/127.5);
        double xq = (iq[i*2+1] - 127.5) * (1.0/127.5);

        /* Cascade two biquad sections */
        for (int s = 0; s < 2; s++) {
            double yi = g_iir_b0[s]*xi + g_iir_b1[s]*g_iir_xi1[s] + g_iir_b2[s]*g_iir_xi2[s]
                      - g_iir_a1[s]*g_iir_yi1[s] - g_iir_a2[s]*g_iir_yi2[s];
            double yq = g_iir_b0[s]*xq + g_iir_b1[s]*g_iir_xq1[s] + g_iir_b2[s]*g_iir_xq2[s]
                      - g_iir_a1[s]*g_iir_yq1[s] - g_iir_a2[s]*g_iir_yq2[s];
            g_iir_xi2[s]=g_iir_xi1[s]; g_iir_xi1[s]=xi;
            g_iir_yi2[s]=g_iir_yi1[s]; g_iir_yi1[s]=yi;
            g_iir_xq2[s]=g_iir_xq1[s]; g_iir_xq1[s]=xq;
            g_iir_yq2[s]=g_iir_yq1[s]; g_iir_yq1[s]=yq;
            xi = yi; xq = yq;
        }

        /* Persistent decimation counter — never slips at block boundaries */
        if (++g_wfm_decim_idx >= decim) {
            g_wfm_decim_idx = 0;
            float ci = (float)xi, cq = (float)xq;
            float cross = ci * g_wfm_prev_q - cq * g_wfm_prev_i;
            float dot   = ci * g_wfm_prev_i + cq * g_wfm_prev_q;
            out[n_out++] = atan2f(cross, dot);
            g_wfm_prev_i = ci;
            g_wfm_prev_q = cq;
        }
    }
    return n_out;
}

/* Linear interpolation SRC from `in_rate` to WFM_AUDIO_RATE (48 kHz). */
static int _wfm_src(const float *in, int n_in, float *out, int out_max,
                    uint32_t in_rate)
{
    if (in_rate == 0) in_rate = DEFAULT_SAMPLE_RATE;
    const double ratio = (double)WFM_AUDIO_RATE / (double)in_rate;
    int n_out = 0;
    while (n_out < out_max) {
        int idx = (int)g_wfm_src_phase;
        if (idx + 1 >= n_in) break;
        float frac = (float)(g_wfm_src_phase - (double)idx);
        out[n_out++] = in[idx] + frac * (in[idx+1] - in[idx]);
        g_wfm_src_phase += 1.0 / ratio;
    }
    int consumed = (int)g_wfm_src_phase;
    if (consumed > n_in) consumed = n_in;
    g_wfm_src_phase -= (double)consumed;
    return n_out;
}

/* De-emphasis + push to ring.
 * WFM: 75µs (α = 1/(1 + 75e-6 * 48000) ≈ 0.2146)
 * NFM: 25µs (α = 1/(1 + 25e-6 * 48000) ≈ 0.4545) */
static void _wfm_push_audio(const float *samples, int n, float alpha, float gain)
{
    pthread_mutex_lock(&g_wfm_mtx);
    for (int i = 0; i < n; i++) {
        g_wfm_deemph += alpha * (samples[i] - g_wfm_deemph);
        float s = g_wfm_deemph * gain;
        if (s >  1.0f) s =  1.0f;
        if (s < -1.0f) s = -1.0f;
        size_t next = (g_wfm_wr + 1) % WFM_RING_SIZE;
        if (next != g_wfm_rd) {
            g_wfm_ring[g_wfm_wr] = (int16_t)(s * 32767.0f);
            g_wfm_wr = next;
        }
    }
    pthread_mutex_unlock(&g_wfm_mtx);
}

static void *_wfm_thread_fn(void *arg)
{
    (void)arg;
    uint8_t *iq_buf    = (uint8_t *)malloc(WFM_BUF_BYTES);
    float   *fm_buf    = (float   *)malloc(WFM_FM_SAMPLES * sizeof(float));
    float   *audio_buf = (float   *)malloc(WFM_AUDIO_MAX  * sizeof(float));
    float   *re_buf    = (float   *)malloc((size_t)g_fft_size * sizeof(float));
    float   *im_buf    = (float   *)malloc((size_t)g_fft_size * sizeof(float));
    float   *acc_buf   = (float   *)malloc((size_t)g_fft_size * sizeof(float));
    float   *tmp_buf   = (float   *)malloc((size_t)g_fft_size * sizeof(float));

    if (!iq_buf || !fm_buf || !audio_buf || !re_buf || !im_buf || !acc_buf || !tmp_buf) {
        LOGE("wfm: malloc failed");
        goto cleanup;
    }

    /* De-emphasis constants */
    const float wfm_alpha = 0.2146f;  /* 75µs @ 48kHz */
    const float nfm_alpha = 0.4545f;  /* 25µs @ 48kHz */

    int fft_acc_count = 0;
    memset(acc_buf, 0, (size_t)g_fft_size * sizeof(float));

    while (g_wfm_running) {
        int n_read = 0;
        int r = rtlsdr_read_sync(g_dev, iq_buf, WFM_BUF_BYTES, &n_read);
        if (r < 0 || n_read <= 0) {
            LOGE("wfm: rtlsdr_read_sync error %d", r);
            break;
        }
        int n_iq = n_read / 2;

        /* ── Channelizer: decimate IQ around DC then FM-demodulate ──────
         * WFM target post-decim ≈ 240 kHz (passes ±100 kHz around carrier)
         * NFM target post-decim ≈  48 kHz (passes  ±8 kHz around carrier)
         * The boxcar average acts as a lowpass that rejects adjacent channels
         * before the discriminator, giving clean audio at any input rate.  */
        uint32_t cur_rate = g_dev ? rtlsdr_get_sample_rate(g_dev) : DEFAULT_SAMPLE_RATE;
        if (cur_rate == 0) cur_rate = DEFAULT_SAMPLE_RATE;

        uint32_t target_if = (g_demod_mode == DEMOD_NFM) ? 48000u : 240000u;
        int decim = (int)(cur_rate / target_if);
        if (decim < 1) decim = 1;
        uint32_t decimated_rate = cur_rate / (uint32_t)decim;

        int n_fm = _wfm_decimate_demod(iq_buf, n_iq, fm_buf, decim);

        /* SRC: decimated_rate → 48 kHz audio */
        int out_max = (int)((double)n_fm * (double)WFM_AUDIO_RATE / (double)decimated_rate) + 4;
        if (out_max > WFM_AUDIO_MAX) out_max = WFM_AUDIO_MAX;
        int n_audio = _wfm_src(fm_buf, n_fm, audio_buf, out_max, decimated_rate);
        if (n_audio > 0) {
            float alpha = (g_demod_mode == DEMOD_NFM) ? nfm_alpha : wfm_alpha;
            float gain  = (g_demod_mode == DEMOD_NFM) ? 6.0f : 4.0f;
            _wfm_push_audio(audio_buf, n_audio, alpha, gain);
        }

        /* FFT for waterfall — raw IQ at full rate, unchanged */
        int offset = 0;
        while (offset + g_fft_size <= n_iq) {
            _accumulate_power(iq_buf + offset*2, g_fft_size, re_buf, im_buf, acc_buf);
            fft_acc_count++;
            offset += g_fft_size;
            if (fft_acc_count >= FFT_AVG_N) {
                float inv = 1.0f / (float)fft_acc_count;
                for (int i = 0; i < g_fft_size; i++) {
                    float p = acc_buf[i] * inv;
                    tmp_buf[i] = (p > 1e-30f) ? 10.0f * log10f(p) : MIN_DB;
                }
                int dc = g_fft_size / 2;
                if (dc > 1 && dc < g_fft_size - 2) {
                    float avg = (tmp_buf[dc-2] + tmp_buf[dc+2]) * 0.5f;
                    tmp_buf[dc-1] = avg;
                    tmp_buf[dc]   = avg;
                    tmp_buf[dc+1] = avg;
                }
                pthread_mutex_lock(&g_fft_mtx);
                memcpy(g_fft_out, tmp_buf, (size_t)g_fft_size * sizeof(float));
                g_fft_cnt++;
                pthread_mutex_unlock(&g_fft_mtx);
                memset(acc_buf, 0, (size_t)g_fft_size * sizeof(float));
                fft_acc_count = 0;
            }
        }
    }

cleanup:
    free(iq_buf); free(fm_buf); free(audio_buf);
    free(re_buf); free(im_buf); free(acc_buf); free(tmp_buf);
    LOGI("WFM/NFM thread exiting");
    return NULL;
}

/* mode: 0=WFM, 1=NFM */
int32_t rf_start_wfm(int32_t mode)
{
    if (!g_dev) return -1;
    if (g_wfm_running) return 0;

    /* Stop FFT thread if active — demod thread takes over both jobs */
    rf_stop();

    g_demod_mode    = (mode == 1) ? DEMOD_NFM : DEMOD_WFM;
    g_wfm_prev_i    = g_wfm_prev_q = 0.0f;
    g_wfm_src_phase = 0.0;
    g_wfm_deemph    = 0.0f;
    g_wfm_rd = g_wfm_wr = 0;
    g_fft_cnt = 0;

    /* Design 4th-order Butterworth anti-alias filter.
     * WFM: 100 kHz passband (covers full FM deviation + Carson bandwidth).
     * NFM: 12 kHz passband (standard 12.5 kHz NFM channel half-width).
     * wc = f_cutoff / (fs/2). */
    uint32_t rate = g_dev ? rtlsdr_get_sample_rate(g_dev) : DEFAULT_SAMPLE_RATE;
    if (rate == 0) rate = DEFAULT_SAMPLE_RATE;
    double target_bw = (mode == 1) ? 12000.0 : 100000.0;
    double wc = (2.0 * target_bw) / (double)rate;
    if (wc > 0.95) wc = 0.95;
    _design_butterworth4(wc);
    LOGI("demod mode=%d rate=%u wc=%.5f", mode, rate, wc);

    rtlsdr_set_agc_mode(g_dev, 1);
    rtlsdr_reset_buffer(g_dev);

    g_wfm_running = 1;
    if (pthread_create(&g_wfm_thread, NULL, _wfm_thread_fn, NULL) != 0) {
        g_wfm_running = 0;
        LOGE("rf_start_wfm: pthread_create failed");
        return -1;
    }
    LOGI("demod started mode=%d rate=%u", mode, g_dev ? rtlsdr_get_sample_rate(g_dev) : 0);
    return 0;
}

void rf_stop_wfm(void)
{
    if (!g_wfm_running) return;
    g_wfm_running = 0;
    if (g_dev) rtlsdr_reset_buffer(g_dev);
    pthread_join(g_wfm_thread, NULL);
    LOGI("WFM/NFM demod stopped");
}

int32_t rf_read_wfm_audio(int16_t *out, int32_t max_samples)
{
    int count = 0;
    pthread_mutex_lock(&g_wfm_mtx);
    while (count < max_samples && g_wfm_rd != g_wfm_wr) {
        out[count++] = g_wfm_ring[g_wfm_rd];
        g_wfm_rd = (g_wfm_rd + 1) % WFM_RING_SIZE;
    }
    pthread_mutex_unlock(&g_wfm_mtx);
    return count;
}

int32_t rf_is_wfm_running(void)
{
    return g_wfm_running ? 1 : 0;
}

/* ── AERO ACARS decoder public API ────────────────────────────────────────── */
int32_t rf_start_aero(void) {
    if (g_aero_running) return -1;

    /* Allocate ring buffer once (shared between AERO modes) */
    if (!g_aero_rb) {
        g_aero_rb = (uint8_t *)malloc(AERO_RB_SIZE);
        if (!g_aero_rb) return -1;
        g_aero_rb_mask = AERO_RB_SIZE - 1;
        g_aero_rb_wr = g_aero_rb_rd = 0;
    }

    /* Cache actual RTL sample rate and compute decimation */
    uint32_t rate = g_dev ? rtlsdr_get_sample_rate(g_dev) : DEFAULT_SAMPLE_RATE;
    if (rate == 0) rate = DEFAULT_SAMPLE_RATE;
    g_aero_rate  = (int)rate;

    /* Set boxcar decimation for target audio rate:
     *   MSK (≤1200 bps): target 48000 Hz, exact for IIR resonator
     *   OQPSK (>1200 bps): target 64000 Hz */
    if (g_aero_symbol_rate <= 1200.0) {
        /* MSK path needs exactly 48 kHz. Use RTL at 2.4M → 2400000/50 = 48000 */
        uint32_t msk_rate = 2400000;
        rtlsdr_set_sample_rate(g_dev, msk_rate);
        rate = msk_rate;
        g_aero_rate = (int)rate;
        g_aero_boxcar_n = 50;
        LOGI("MSK: set RTL to %u Hz, boxcar %d:1 → 48000 Hz",
             msk_rate, g_aero_boxcar_n);
    } else {
        g_aero_boxcar_n = 16;
        g_aero_rate = (int)rate;
    }
    /* Halfband decimation = 2^HB_STAGES (e.g. 4 stages → 16:1) */
    g_aero_decim = 1 << HB_STAGES;
    double audio_rate = (double)g_aero_rate / (double)g_aero_boxcar_n;

    /* 4-stage halfband 2:1 decimation (SDRReceiver hbcoeff23) + NCO at 8 kHz IF */
    _aero_init_hb();
    double inc = 2.0 * 3.14159265358979 * 0.0 / (double)g_aero_rate;
    _nco_ci = cos(inc);
    _nco_si = sin(inc);

    /* Wide AFC for live: catches RTL PPM offset */
    oqpsk_lockingbw = 0;  /* default per rate */
    if (g_aero_symbol_rate <= 1200.0) {
        /* P-channel MSK at 600 or 1200 bps */
        g_aero_pmsk = jaero_pmsk_create(audio_rate, g_aero_symbol_rate, 0,
                                         _aero_soft_bits_cb, NULL);
        if (!g_aero_pmsk) return -1;
        jaero_pmsk_set_acars_callback(g_aero_pmsk, _aero_acars_cb, NULL);
        jaero_pmsk_set_cassign_callback(g_aero_pmsk, _aero_cassign_cb, NULL);
        jaero_pmsk_set_decoded_callback(g_aero_pmsk, _aero_decoded_cb, NULL);
        LOGI("AERO P-channel MSK started (%.3fM / decim %d → %.0f Hz, %.0f baud)",
             rate/1e6, g_aero_boxcar_n, audio_rate, g_aero_symbol_rate);
    } else {
        /* OQPSK for 8400/10500 bps (C-channel / ACARS) */
        g_aero_demod = jaero_oqpsk_cont_create(audio_rate, g_aero_symbol_rate, 0,
                                                _aero_soft_bits_cb, NULL);
        if (!g_aero_demod) return -1;
        jaero_oqpsk_cont_set_acars_callback(g_aero_demod, _aero_acars_cb, NULL);
        jaero_oqpsk_cont_set_cassign_callback(g_aero_demod, _aero_cassign_cb, NULL);
        jaero_oqpsk_cont_set_decoded_callback(g_aero_demod, _aero_decoded_cb, NULL);
        jaero_oqpsk_cont_set_voice_callback(g_aero_demod, _aero_voice_cb, NULL);
    }
    /* Start the AERO feeder thread (processes ring buffer → decoder) */
    if (!g_aero_thread_running) {
        g_aero_thread_running = 1;
        if (pthread_create(&g_aero_thread, NULL, aero_thread_fn, NULL) != 0) {
            LOGE("AERO: pthread_create for feeder thread failed");
            g_aero_thread_running = 0;
            if (g_aero_demod) { jaero_oqpsk_cont_destroy(g_aero_demod); g_aero_demod = NULL; }
            if (g_aero_pmsk)  { jaero_pmsk_destroy(g_aero_pmsk);          g_aero_pmsk  = NULL; }
            return -1;
        }
    }
    g_aero_running = 1;
    g_aero_msg_len = 0;
    LOGI("AERO started (%.3fM → boxcar → %.0f Hz)", rate/1e6, audio_rate);
    return 0;
}

int32_t rf_stop_aero(void) {
    g_aero_running = 0;
    /* Stop the AERO feeder thread */
    if (g_aero_thread_running) {
        g_aero_thread_running = 0;
        pthread_cond_signal(&g_aero_rb_cond);
        pthread_join(g_aero_thread, NULL);
    }
    if (g_aero_demod) { jaero_oqpsk_cont_destroy(g_aero_demod); g_aero_demod = NULL; }
    if (g_aero_pmsk)  { jaero_pmsk_destroy(g_aero_pmsk);          g_aero_pmsk  = NULL; }
    g_aero_msg_len = 0;
    _hb_init = 0;
    memset(_hb_ring_i, 0, sizeof(_hb_ring_i));
    memset(_hb_ring_q, 0, sizeof(_hb_ring_q));
    memset(_hb_ridx, 0, sizeof(_hb_ridx));
    memset(_hb_skip, 0, sizeof(_hb_skip));
    memset(_hb_out_i, 0, sizeof(_hb_out_i));
    memset(_hb_out_q, 0, sizeof(_hb_out_q));
    LOGI("AERO decoder stopped");
    return 0;
}

int32_t rf_poll_aero(char *out, int32_t maxlen) {
    if (!g_aero_running) return -1;
    pthread_mutex_lock(&g_aero_msg_mtx);
    int len = g_aero_msg_len < maxlen ? g_aero_msg_len : maxlen;
    if (len > 0) {
        memcpy(out, g_aero_msg_buf, (size_t)len);
        memmove(g_aero_msg_buf, g_aero_msg_buf + len, (size_t)(g_aero_msg_len - len));
        g_aero_msg_len -= len;
    }
    pthread_mutex_unlock(&g_aero_msg_mtx);
    return (int32_t)len;
}

float rf_get_aero_mse(void) {
    if (!g_aero_running) return 0.0f;
    return (float)_aero_get_mse();
}

float rf_get_aero_freq(void) {
    return 8000.0f;  /* currently hardcoded NCO shift */
}

float rf_get_aero_ebno(void) {
    if (!g_aero_running) return 0.0f;
    return (float)_aero_get_ebno();
}

int rf_get_aero_constellation(double *iq, int max_points) {
    if (max_points <= 0 || !g_aero_running) return 0;
    int n = 0;
    if (g_aero_pmsk)
        n = jaero_pmsk_get_constellation(g_aero_pmsk, iq, max_points);
    else if (g_aero_demod)
        n = jaero_oqpsk_cont_get_constellation(g_aero_demod, iq, max_points);
    return n;
}

uint32_t rf_get_sample_rate(void) {
    return g_dev ? rtlsdr_get_sample_rate(g_dev) : DEFAULT_SAMPLE_RATE;
}

void rf_set_aero_feed_mode(int32_t mode) {
    g_aero_feed_iq_mode = (mode != 0) ? 1 : 0;
    LOGI("AERO feed mode: %s", g_aero_feed_iq_mode ? "feedIQ (JAERO's Hilbert)" : "feedAudio (our Hilbert)");
}

void rf_set_aero_symbol_rate(double rate) {
    if (rate < 600.0) rate = 600.0;
    g_aero_symbol_rate = rate;
    LOGI("AERO symbol rate: %.0f baud", rate);
    if (!g_aero_running) return;
    /* Pause feeding while we destroy/recreate demodulators to avoid
     * race with the async RTL callback thread. */
    g_aero_running = 0;
    usleep(20000);  /* 20ms — let async thread drain */
    if (g_aero_demod) { jaero_oqpsk_cont_destroy(g_aero_demod); g_aero_demod = NULL; }
    if (g_aero_pmsk)  { jaero_pmsk_destroy(g_aero_pmsk);          g_aero_pmsk  = NULL; }
    g_aero_msg_len = 0;

    /* Adjust RTL sample rate and boxcar decimation for target audio rate */
    uint32_t new_rate = DEFAULT_SAMPLE_RATE;
    if (rate <= 1200.0) {
        new_rate = 2400000;
        g_aero_boxcar_n = 50;  /* 2400000/50 = 48000 Hz for MSK */
    } else {
        g_aero_boxcar_n = 16;  /* 1024000/16 = 64000 Hz for OQPSK */
    }
    if (g_dev) {
        rtlsdr_set_sample_rate(g_dev, new_rate);
        g_aero_rate = (int)new_rate;
    }
    double audio_rate = (double)g_aero_rate / (double)g_aero_boxcar_n;
    if (rate <= 1200.0) {
        g_aero_pmsk = jaero_pmsk_create(audio_rate, rate, 0,
                                         _aero_soft_bits_cb, NULL);
        if (g_aero_pmsk) {
            jaero_pmsk_set_acars_callback(g_aero_pmsk, _aero_acars_cb, NULL);
            jaero_pmsk_set_cassign_callback(g_aero_pmsk, _aero_cassign_cb, NULL);
            jaero_pmsk_set_decoded_callback(g_aero_pmsk, _aero_decoded_cb, NULL);
        }
    } else {
        g_aero_demod = jaero_oqpsk_cont_create(audio_rate, rate, 0,
                                                _aero_soft_bits_cb, NULL);
        if (g_aero_demod) {
            jaero_oqpsk_cont_set_acars_callback(g_aero_demod, _aero_acars_cb, NULL);
            jaero_oqpsk_cont_set_cassign_callback(g_aero_demod, _aero_cassign_cb, NULL);
            jaero_oqpsk_cont_set_decoded_callback(g_aero_demod, _aero_decoded_cb, NULL);
            jaero_oqpsk_cont_set_voice_callback(g_aero_demod, _aero_voice_cb, NULL);
        }
    }
    g_aero_running = 1;
    LOGI("AERO re-created at %.0f baud", rate);
}

void rf_set_aero_boxcar_mode(int32_t mode) {
    g_aero_boxcar_mode = (mode != 0) ? 1 : 0;
    LOGI("AERO decimator: %s", g_aero_boxcar_mode ? "boxcar average" : "halfband cascade");
}

int32_t rf_start_aero_recording(const char *path) {
    if (!g_aero_running) { LOGE("rec: AERO not running"); return -1; }
    if (g_aero_recording)  { LOGE("rec: already recording"); return -1; }
    g_aero_rec_file = fopen(path, "wb");
    if (!g_aero_rec_file) { LOGE("rec: cannot open %s", path); return -1; }

    g_aero_rec_rate    = g_aero_rate / g_aero_boxcar_n;  /* e.g. 64000 Hz or 48000 Hz */
    g_aero_rec_samples = 0;

    /* WAV header with placeholder file/data sizes */
    uint8_t hdr[44]; memset(hdr, 0, 44);
    memcpy(hdr,     "RIFF", 4);
    memcpy(hdr + 8,  "WAVE", 4);
    memcpy(hdr + 12, "fmt ", 4);
    hdr[16] = 16;                         /* chunk size */
    hdr[20] = 1;                          /* PCM */
    hdr[22] = 2;                          /* 2 channels = I + Q */
    uint32_t sr = (uint32_t)g_aero_rec_rate;
    hdr[24] = sr & 0xFF; hdr[25] = (sr>>8)&0xFF; hdr[26] = (sr>>16)&0xFF; hdr[27] = (sr>>24)&0xFF;
    uint32_t br = sr * 4;                 /* byte rate = sr * ch * bps/8 */
    hdr[28] = br & 0xFF; hdr[29] = (br>>8)&0xFF; hdr[30] = (br>>16)&0xFF; hdr[31] = (br>>24)&0xFF;
    hdr[32] = 4;                          /* block align = 4 bytes per IQ pair */
    hdr[34] = 16;                         /* bits per sample */
    memcpy(hdr + 36, "data", 4);

    fwrite(hdr, 1, 44, g_aero_rec_file);
    fflush(g_aero_rec_file);
    g_aero_recording = 1;
    LOGI("AERO REC START: %s  rate=%.1fkHz", path, g_aero_rec_rate / 1000.0);
    return 0;
}

int32_t rf_stop_aero_recording(void) {
    if (!g_aero_recording || !g_aero_rec_file) return -1;

    uint32_t data_size = (uint32_t)(g_aero_rec_samples * 4);
    uint32_t file_size = data_size + 36;

    fseek(g_aero_rec_file, 4, SEEK_SET);
    fwrite(&file_size, 4, 1, g_aero_rec_file);
    fseek(g_aero_rec_file, 40, SEEK_SET);
    fwrite(&data_size, 4, 1, g_aero_rec_file);

    fclose(g_aero_rec_file);
    g_aero_rec_file = NULL;
    g_aero_recording = 0;

    LOGI("AERO REC STOP: %ld samples (%.1f sec)", g_aero_rec_samples,
         g_aero_rec_samples / (double)g_aero_rec_rate);
    return 0;
}

int32_t rf_start_aero_recording_raw(const char *path) {
    if (g_aero_recording_raw) { LOGE("raw: already recording"); return -1; }
    g_aero_rec_raw_file = fopen(path, "wb");
    if (!g_aero_rec_raw_file) { LOGE("raw: cannot open %s", path); return -1; }

    g_aero_rec_raw_bytes = 0;

    /* WAV header for raw RTL IQ: 16-bit signed PCM, 2 channels, 1.024 Msps */
    uint32_t sr = (uint32_t)g_aero_rate;
    uint32_t cf = g_dev ? rtlsdr_get_center_freq(g_dev) : 0;
    LOGI("AERO RAW REC START: %s  rate=%u  center=%u Hz", path, sr, cf);
    uint8_t hdr[44]; memset(hdr, 0, 44);
    memcpy(hdr,     "RIFF", 4);
    memcpy(hdr + 8,  "WAVE", 4);
    memcpy(hdr + 12, "fmt ", 4);
    hdr[16] = 16;                         /* chunk size */
    hdr[20] = 1;                          /* PCM */
    hdr[22] = 2;                          /* 2 channels = I + Q */
    hdr[24] = sr & 0xFF; hdr[25] = (sr>>8)&0xFF; hdr[26] = (sr>>16)&0xFF; hdr[27] = (sr>>24)&0xFF;
    uint32_t br = sr * 4;                 /* byte rate = sr * ch * (bps/8) */
    hdr[28] = br & 0xFF; hdr[29] = (br>>8)&0xFF; hdr[30] = (br>>16)&0xFF; hdr[31] = (br>>24)&0xFF;
    hdr[32] = 4;                          /* block align = 4 bytes per IQ pair */
    hdr[34] = 16;                         /* bits per sample = 16 signed */

    memcpy(hdr + 36, "data", 4);

    fwrite(hdr, 1, 44, g_aero_rec_raw_file);
    fflush(g_aero_rec_raw_file);
    g_aero_recording_raw = 1;
    return 0;
}

int32_t rf_stop_aero_recording_raw(void) {
    if (!g_aero_recording_raw || !g_aero_rec_raw_file) return -1;

    uint32_t data_size = (uint32_t)(g_aero_rec_raw_bytes * 2);  /* 8-bit pairs → 16-bit stereo = 4 bytes/pair */
    uint32_t file_size = data_size + 36;

    fseek(g_aero_rec_raw_file, 4, SEEK_SET);
    fwrite(&file_size, 4, 1, g_aero_rec_raw_file);
    fseek(g_aero_rec_raw_file, 40, SEEK_SET);
    fwrite(&data_size, 4, 1, g_aero_rec_raw_file);

    fclose(g_aero_rec_raw_file);
    g_aero_rec_raw_file = NULL;
    g_aero_recording_raw = 0;

    LOGI("AERO RAW REC STOP: %ld bytes (%.1f sec)", g_aero_rec_raw_bytes,
         g_aero_rec_raw_bytes / (double)(g_aero_rate * 2));
    return 0;
}

/* Set NCO mixing frequency offset (Hz) */
void rf_set_aero_offset(double hz) {
    double inc = 2.0 * 3.14159265358979 * hz / (double)g_aero_rate;
    _nco_ci = cos(inc);
    _nco_si = sin(inc);
    LOGI("AERO NCO offset: %.1f Hz", hz);
}

/* ── WAV file decode (test mode) ─────────────────────────────────────────── */
int32_t rf_load_wav_aero(const char *path) {
    if (!path) return -1;
    LOGI("Loading WAV: %s", path);

    FILE *f = fopen(path, "rb");
    if (!f) { LOGE("Cannot open WAV: %s", path); return -1; }

    /* Parse WAV header */
    char riff[4]; uint32_t sz; char wave[4];
    fread(riff, 1, 4, f); fread(&sz, 4, 1, f); fread(wave, 1, 4, f);
    if (memcmp(riff, "RIFF", 4) || memcmp(wave, "WAVE", 4)) {
        fclose(f); return -1;
    }

    int sr = 0, nc = 0, bps = 0;
    long data_pos = 0, data_sz = 0;
    while (!feof(f)) {
        char id[4]; uint32_t cs;
        if (fread(id, 1, 4, f) != 4) break;
        if (fread(&cs, 4, 1, f) != 1) break;
        if (memcmp(id, "fmt ", 4) == 0) {
            uint16_t fmt, ch; uint32_t srate, brate; uint16_t balign, bpss;
            fread(&fmt, 2, 1, f); fread(&ch, 2, 1, f);
            fread(&srate, 4, 1, f); fread(&brate, 4, 1, f);
            fread(&balign, 2, 1, f); fread(&bpss, 2, 1, f);
            sr = (int)srate; nc = (int)ch; bps = (int)bpss;
            if (cs > 16) fseek(f, cs - 16, SEEK_CUR);
        } else if (memcmp(id, "data", 4) == 0) {
            data_pos = ftell(f); data_sz = cs;
            break;
        } else fseek(f, cs, SEEK_CUR);
    }
    if (!data_sz) { fclose(f); return -1; }
    fseek(f, data_pos, SEEK_SET);

    long nsamples = data_sz / (nc * (bps / 8));
    LOGI("WAV: %dHz %dch %dbps %ld samples", sr, nc, bps, nsamples);

    /* Create fresh demodulator (destroy old one for clean state) */
    if (g_aero_demod) {
        jaero_oqpsk_cont_destroy(g_aero_demod);
        g_aero_demod = NULL;
    }
    oqpsk_lockingbw = 0;  /* default 10500 for WAV path */
    g_aero_demod = jaero_oqpsk_cont_create((double)sr, 10500.0, 0, _aero_soft_bits_cb, NULL);
    if (g_aero_demod) {
        jaero_oqpsk_cont_set_acars_callback(g_aero_demod, _aero_acars_cb, NULL);
        jaero_oqpsk_cont_set_cassign_callback(g_aero_demod, _aero_cassign_cb, NULL);
    }
    if (!g_aero_demod) { fclose(f); return -1; }
    g_aero_running = 1;
    g_aero_msg_len = 0;

    /* Read and feed IQ */
    int16_t *buf = (int16_t*)malloc(data_sz);
    fread(buf, 1, data_sz, f);
    fclose(f);

    double *iq = (double*)malloc(nsamples * 2 * sizeof(double));
    if (nc >= 2) {
        for (long i = 0; i < nsamples; i++) {
            iq[i*2]   = buf[i*2]   / 32768.0;
            iq[i*2+1] = buf[i*2+1] / 32768.0;
        }
    } else {
        for (long i = 0; i < nsamples; i++)
            iq[i] = buf[i] / 32768.0;
    }

    LOGI("Feeding %ld IQ pairs to AERO decoder...", nsamples);
    jaero_oqpsk_cont_feed_iq(g_aero_demod, iq, nsamples);
    LOGI("WAV decode complete. Messages: %d  MSE=%.3f Eb/No=%.1f",
         g_aero_msg_len,
         g_aero_demod ? jaero_oqpsk_cont_get_mse(g_aero_demod) : 0.0,
         g_aero_demod ? jaero_oqpsk_cont_get_ebno(g_aero_demod) : 0.0);
    /* Dump first 600 bytes for comparison */
    if (g_aero_msg_len > 0) {
        int dump_len = g_aero_msg_len < 200 ? g_aero_msg_len : 200;
        char hex[601];
        int hp = 0;
        for (int i = 0; i < dump_len && hp < 600; i++) {
            hp += snprintf(hex + hp, 4, "%02X", (unsigned char)g_aero_msg_buf[i]);
        }
        hex[hp] = 0;
        LOGI("MSG_HEX: %s", hex);
    }

    free(buf); free(iq);
    return 0;
}

/* ── JNI entry point for WfmAudioPlayer ──────────────────────────────────── */

JNIEXPORT jint JNICALL
Java_com_rfstudio_rfstudio_WfmAudioPlayer_nativeReadAudio(
        JNIEnv *env, jclass cls, jshortArray outArray, jint maxSamples)
{
    (void)cls;
    jshort *buf = (*env)->GetShortArrayElements(env, outArray, NULL);
    if (!buf) return 0;
    int count = rf_read_wfm_audio((int16_t *)buf, (int32_t)maxSamples);
    (*env)->ReleaseShortArrayElements(env, outArray, buf, 0);
    return (jint)count;
}
