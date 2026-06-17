// signal_gen.c — Signal generator: CW, FM, Sweep, C4FM P25 Phase 1 CC
//
// C4FM P25 modulator ported from github.com/rose/ccemu (dsp + p25 packages).
//
// FFI API (called from Dart via librf_studio_sdr.so):
//   void     rf_siggen_init(void)
//   void     rf_siggen_start_cw   (double freq_offset_hz, double sample_rate, double amplitude)
//   void     rf_siggen_start_fm   (double audio_hz, double deviation_hz,
//                                  double sample_rate, double amplitude)
//   void     rf_siggen_start_sweep(double start_hz, double stop_hz,
//                                  double rate_hz_per_sec, double sample_rate, double amplitude)
//   void     rf_siggen_configure_c4fm(uint32_t nac, uint32_t wacn, uint32_t sysid,
//                                     uint32_t rfss, uint32_t site,
//                                     uint32_t chan_id, uint32_t chan_num,
//                                     uint32_t base_freq_5hz, int32_t simulate)
//   void     rf_siggen_start_c4fm (void)
//   void     rf_siggen_stop       (void)
//   int32_t  rf_siggen_fill       (uint8_t *buf, int32_t n)
//   int32_t  rf_siggen_mode       (void)   // 0=idle 1=CW 2=FM 3=Sweep 4=C4FM

#include <stdint.h>
#include <string.h>
#include <math.h>

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

#define C4FM_SAMPLE_RATE  2400000.0
#define C4FM_SYMBOL_RATE  4800.0
#define C4FM_OSR          500
#define C4FM_RRC_ALPHA    0.2
#define C4FM_RRC_SPAN     4
#define C4FM_POLY_TAPS    (C4FM_RRC_SPAN * 2 + 1)      // 9
#define C4FM_RRC_NTAPS    (C4FM_RRC_SPAN * 2 * C4FM_OSR + 1) // 4001
#define C4FM_DEV_PER_UNIT 600.0

// Dibit → 4-level symbol (P25 Gray coding)
// 00→+1 (+600 Hz), 01→+3 (+1800 Hz), 10→-1 (−600 Hz), 11→-3 (−1800 Hz)
static const float c4fm_sym[4] = { 1.0f, 3.0f, -1.0f, -3.0f };

// P25 frame constants
#define P25_FRAME_SYNC       0x5575F5FF77FFULL   // 48-bit sync word
#define P25_DUID_TSBK        0x07
#define P25_DUID_TDU         0x03
#define P25_TSCC_SS          0x02               // TSCC status symbol dibit

// ─────────────────────────────────────────────────────────────────────────────
// RRC polyphase filter (computed once by rf_siggen_init)
// ─────────────────────────────────────────────────────────────────────────────

static float g_poly[C4FM_OSR][C4FM_POLY_TAPS]; // [500][9]

static double _rrc_sample(double t, double T, double alpha) {
    const double eps = 1e-9;
    if (fabs(t) < eps)
        return 1.0 - alpha + 4.0 * alpha / M_PI;
    double boundary = T / (4.0 * alpha);
    if (fabs(fabs(t) - boundary) < eps) {
        double s = sin(M_PI / (4.0 * alpha));
        double c = cos(M_PI / (4.0 * alpha));
        return (alpha / M_SQRT2) *
               ((1.0 + 2.0 / M_PI) * s + (1.0 - 2.0 / M_PI) * c);
    }
    double tN  = t / T;
    double num = sin(M_PI * tN * (1.0 - alpha)) +
                 4.0 * alpha * tN * cos(M_PI * tN * (1.0 + alpha));
    double den = M_PI * tN * (1.0 - (4.0 * alpha * tN) * (4.0 * alpha * tN));
    return num / den;
}

static void _build_poly_filter(void) {
    double T = 1.0 / C4FM_SYMBOL_RATE;
    double centre = (C4FM_RRC_NTAPS - 1) / 2.0;
    double h[C4FM_RRC_NTAPS];

    for (int i = 0; i < C4FM_RRC_NTAPS; i++) {
        double t = (i - centre) / (double)C4FM_OSR / C4FM_SYMBOL_RATE;
        h[i] = _rrc_sample(t, T, C4FM_RRC_ALPHA);
    }

    // Normalise so centre tap == 1.0
    int centre_idx = C4FM_RRC_NTAPS / 2;
    if (h[centre_idx] != 0.0) {
        double scale = 1.0 / h[centre_idx];
        for (int i = 0; i < C4FM_RRC_NTAPS; i++) h[i] *= scale;
    }

    // Build polyphase bank: poly[p][j] = h[j * OSR + p]
    for (int p = 0; p < C4FM_OSR; p++) {
        for (int j = 0; j < C4FM_POLY_TAPS; j++) {
            int idx = j * C4FM_OSR + p;
            g_poly[p][j] = (idx < C4FM_RRC_NTAPS) ? (float)h[idx] : 0.0f;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// P25 BCH(64,16,23) encoder  (from ccemu/p25/bch.go)
// ─────────────────────────────────────────────────────────────────────────────

static const uint64_t _bch_matrix[16] = {
    0x8000cd930bdd3b2aULL,
    0x4000ab5a8e33a6beULL,
    0x2000983e4cc4e874ULL,
    0x10004c1f2662743aULL,
    0x0800eb9c98ec0136ULL,
    0x0400b85d47ab3bb0ULL,
    0x02005c2ea3d59dd8ULL,
    0x01002e1751eaceecULL,
    0x0080170ba8f56776ULL,
    0x0040c616dfa78890ULL,
    0x0020630b6fd3c448ULL,
    0x00103185b7e9e224ULL,
    0x000818c2dbf4f112ULL,
    0x0004c1f2662743a2ULL,
    0x0002ad6a38ce9afbULL,
    0x00019b2617ba7657ULL,
};

static uint64_t _encode_bch(uint16_t data) {
    uint64_t cw = 0;
    for (int i = 0; i < 16; i++)
        if (data & (0x8000u >> i))
            cw ^= _bch_matrix[i];
    return cw;
}

// ─────────────────────────────────────────────────────────────────────────────
// P25 CRC-CCITT  (from ccemu/p25/crc.go)
// ─────────────────────────────────────────────────────────────────────────────

static uint16_t _crc_ccitt(uint16_t high, uint64_t low) {
    const uint32_t poly = 0x1021u;
    uint32_t crc = 0;
    for (int i = 15; i >= 0; i--) {
        crc <<= 1;
        uint32_t bit = (high >> i) & 1u;
        if (((crc >> 16) ^ bit) & 1u) crc ^= poly;
    }
    for (int i = 63; i >= 0; i--) {
        crc <<= 1;
        uint32_t bit = (uint32_t)((low >> i) & 1ULL);
        if (((crc >> 16) ^ bit) & 1u) crc ^= poly;
    }
    return (uint16_t)((crc & 0xffffu) ^ 0xffffu);
}

// ─────────────────────────────────────────────────────────────────────────────
// P25 Trellis encoder + Data interleave  (from ccemu/p25/trellis.go)
// ─────────────────────────────────────────────────────────────────────────────

static const uint8_t _trellis[4][4][2] = {
    {{0,2},{3,0},{0,1},{3,3}},
    {{3,2},{0,0},{3,1},{0,3}},
    {{2,1},{1,3},{2,2},{1,0}},
    {{1,1},{2,3},{1,2},{2,0}},
};

// input: 48 dibits → output: 98 dibits (appends flush dibit)
static void _trellis_encode(const uint8_t *in48, uint8_t *out98) {
    int state = 0;
    int pos = 0;
    for (int k = 0; k <= 48; k++) { // k=48: flush dibit 0
        uint8_t d = (k < 48) ? in48[k] : 0;
        out98[pos++] = _trellis[state][d][0];
        out98[pos++] = _trellis[state][d][1];
        state = d;
    }
    // pos == 98
}

static void _data_interleave(const uint8_t *in98, uint8_t *out98) {
    int pos = 0;
    for (int j = 0; j < 97; j += 8) {
        out98[pos++] = in98[j];
        out98[pos++] = in98[j + 1];
    }
    for (int i = 2; i < 7; i += 2) {
        for (int j = 0; j < 89; j += 8) {
            out98[pos++] = in98[i + j];
            out98[pos++] = in98[i + j + 1];
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TSBK builder helpers
// ─────────────────────────────────────────────────────────────────────────────

static void _bytes_to_dibits(const uint8_t *data, int n, uint8_t *out) {
    for (int i = 0; i < n; i++) {
        out[i*4+0] = (data[i] >> 6) & 3;
        out[i*4+1] = (data[i] >> 4) & 3;
        out[i*4+2] = (data[i] >> 2) & 3;
        out[i*4+3] = (data[i]     ) & 3;
    }
}

// Converts n LS-bits of v to dibits (MSB first); n must be ≤ 64, multiple of 2
static void _u64_to_dibits(uint64_t v, int n, uint8_t *out) {
    uint8_t bytes[8];
    for (int i = 0; i < 8; i++) bytes[i] = (uint8_t)(v >> (56 - 8*i));
    uint8_t tmp[32];
    _bytes_to_dibits(bytes, 8, tmp);
    memcpy(out, tmp + (32 - n), (size_t)n);
}

// inserts P25 status symbols after every 35 data dibits
static int _insert_status(const uint8_t *in, int n, uint8_t ss, uint8_t *out) {
    int num_ss  = (n + 34) / 35;
    int remaining = num_ss;
    int pos = 0, counter = 1;
    for (int k = 0; k < n; k++) {
        out[pos++] = in[k];
        if (counter % 35 == 0 && remaining > 0) {
            out[pos++] = ss;
            remaining--;
        }
        counter++;
    }
    while (remaining > 0) {
        out[pos++] = 0;
        if (counter % 35 == 0) {
            out[pos++] = ss;
            remaining--;
        }
        counter++;
    }
    return pos;
}

// Assembles a TSBK PDU into out[12] (big-endian)
static void _build_tsbk(uint8_t out[12], int last_block,
                         uint8_t opcode, uint8_t mfid, uint64_t args) {
    uint16_t lb   = last_block ? 1u : 0u;
    uint16_t high = (uint16_t)((lb << 15) | ((uint16_t)opcode << 8) | mfid);
    uint16_t crc  = _crc_ccitt(high, args);
    out[0] = (uint8_t)(high >> 8);
    out[1] = (uint8_t)(high);
    for (int i = 0; i < 8; i++) out[2+i] = (uint8_t)(args >> (56 - 8*i));
    out[10] = (uint8_t)(crc >> 8);
    out[11] = (uint8_t)(crc);
}

// ─────────────────────────────────────────────────────────────────────────────
// P25 frame builder
// ─────────────────────────────────────────────────────────────────────────────

// Returns dibit count written to out (≤256)
static int _build_p25_frame(uint8_t *out, const uint8_t tsbk[12], uint16_t nac) {
    uint8_t frame[200];
    int pos = 0;

    // 24 dibits: frame sync
    _u64_to_dibits(P25_FRAME_SYNC, 24, frame + pos);
    pos += 24;

    // 32 dibits: NID (BCH encoded NAC|DUID)
    uint64_t nid = _encode_bch((uint16_t)((nac << 4) | P25_DUID_TSBK));
    _u64_to_dibits(nid, 32, frame + pos);
    pos += 32;

    // 48 dibits from TSBK bytes, then trellis encode + interleave → 98 dibits
    uint8_t dibits48[48];
    _bytes_to_dibits(tsbk, 12, dibits48);

    uint8_t enc98[98];
    _trellis_encode(dibits48, enc98);

    uint8_t ili98[98];
    _data_interleave(enc98, ili98);

    memcpy(frame + pos, ili98, 98);
    pos += 98;

    // Insert P25 status symbols
    return _insert_status(frame, pos, P25_TSCC_SS, out);
}

// ─────────────────────────────────────────────────────────────────────────────
// TSBK builders — minimal set for P25 CC
// ─────────────────────────────────────────────────────────────────────────────

static void _tsbk_iden_up(uint8_t out[12],
                           uint8_t iden, uint16_t bw_units, int16_t offset_units,
                           uint16_t chspac_units, uint32_t base_freq_5hz) {
    uint64_t base = base_freq_5hz & 0xFFFFFFFFULL;
    uint64_t ofld;
    if      (offset_units > 0) ofld = 0x100ULL | (uint64_t)(offset_units & 0xFF);
    else if (offset_units < 0) ofld = (uint64_t)((-offset_units) & 0xFF);
    else                        ofld = 0;
    uint64_t args = ((uint64_t)(iden & 0xF) << 60)       |
                    ((uint64_t)(bw_units & 0x1FF) << 51)  |
                    (ofld << 42)                           |
                    ((uint64_t)(chspac_units & 0x3FF) << 32) |
                    base;
    _build_tsbk(out, 1, 0x3D, 0x00, args);
}

static void _tsbk_net_status(uint8_t out[12],
                              uint32_t wacn, uint16_t sysid,
                              uint8_t chan_id, uint16_t chan_num, uint8_t ssc) {
    uint64_t ch   = ((uint64_t)(chan_id & 0xF) << 12) | (chan_num & 0xFFF);
    uint64_t args = ((uint64_t)(wacn & 0xFFFFF) << 36) |
                    ((uint64_t)(sysid & 0xFFF) << 24)   |
                    (ch << 8)                            |
                    ssc;
    _build_tsbk(out, 1, 0x3B, 0x00, args);
}

static void _tsbk_rfss_status(uint8_t out[12],
                               uint8_t lrar, uint16_t sysid,
                               uint8_t rfss, uint8_t site,
                               uint8_t chan_id, uint16_t chan_num, uint8_t ssc) {
    uint64_t ch   = ((uint64_t)(chan_id & 0xF) << 12) | (chan_num & 0xFFF);
    uint64_t args = ((uint64_t)lrar << 56)             |
                    ((uint64_t)(sysid & 0xFFF) << 40)  |
                    ((uint64_t)rfss << 32)              |
                    ((uint64_t)site << 24)              |
                    (ch << 8)                           |
                    ssc;
    _build_tsbk(out, 1, 0x3A, 0x00, args);
}

static void _tsbk_adj_sts(uint8_t out[12],
                           uint16_t adj_sysid, uint8_t rfss, uint8_t site,
                           uint8_t chan_id, uint16_t chan_num, uint8_t ssc) {
    uint64_t ch   = ((uint64_t)(chan_id & 0xF) << 12) | (chan_num & 0xFFF);
    uint64_t args = ((uint64_t)(adj_sysid & 0xFFF) << 40) |
                    ((uint64_t)rfss << 32)                 |
                    ((uint64_t)site << 24)                 |
                    (ch << 8)                              |
                    ssc;
    _build_tsbk(out, 1, 0x3C, 0x00, args);
}

static void _tsbk_grp_vch_grant(uint8_t out[12],
                                 uint8_t opts,
                                 uint8_t chan_id, uint16_t chan_num,
                                 uint16_t tg, uint32_t src) {
    uint64_t ch   = ((uint64_t)(chan_id & 0xF) << 12) | (chan_num & 0xFFF);
    uint64_t args = ((uint64_t)opts << 56) |
                    (ch << 40)             |
                    ((uint64_t)tg << 24)   |
                    (src & 0xFFFFFF);
    _build_tsbk(out, 1, 0x00, 0x00, args);
}

static void _tsbk_grp_vch_grant_updt(uint8_t out[12],
                                      uint8_t cid1, uint16_t cnum1, uint16_t tg1,
                                      uint8_t cid2, uint16_t cnum2, uint16_t tg2) {
    uint64_t ch1  = ((uint64_t)(cid1 & 0xF) << 12) | (cnum1 & 0xFFF);
    uint64_t ch2  = ((uint64_t)(cid2 & 0xF) << 12) | (cnum2 & 0xFFF);
    uint64_t args = (ch1 << 48) | ((uint64_t)tg1 << 32) | (ch2 << 16) | tg2;
    _build_tsbk(out, 1, 0x02, 0x00, args);
}

static void _tsbk_grp_aff_rsp(uint8_t out[12],
                                uint8_t gav, uint16_t ann_tg, uint16_t tg, uint32_t src) {
    uint64_t args = ((uint64_t)(gav & 3) << 56)  |
                    ((uint64_t)ann_tg << 40)       |
                    ((uint64_t)tg << 24)           |
                    (src & 0xFFFFFF);
    _build_tsbk(out, 1, 0x28, 0x00, args);
}

static void _tsbk_u_reg_rsp(uint8_t out[12],
                              int accepted, uint16_t sysid, uint32_t tgt, uint32_t src) {
    uint64_t rv   = accepted ? 1ULL : 0ULL;
    uint64_t args = (rv << 60)                       |
                    ((uint64_t)(sysid & 0xFFF) << 48) |
                    ((uint64_t)(tgt & 0xFFFFFF) << 24) |
                    (src & 0xFFFFFF);
    _build_tsbk(out, 1, 0x2C, 0x00, args);
}

// ─────────────────────────────────────────────────────────────────────────────
// C4FM control channel state machine
// ─────────────────────────────────────────────────────────────────────────────

#define CC_MAX_DIBITS 256

static uint8_t  g_cc_dibit_buf[CC_MAX_DIBITS];
static int      g_cc_n_dibits;
static int      g_cc_dibit_pos;
static int      g_cc_sample_in_dibit;  // 0..C4FM_OSR-1; 0 means "need new dibit"

static uint16_t g_cc_nac;
static uint32_t g_cc_wacn;
static uint16_t g_cc_sysid;
static uint8_t  g_cc_rfss;
static uint8_t  g_cc_site;
static uint8_t  g_cc_chan_id;
static uint16_t g_cc_chan_num;
static uint32_t g_cc_base_freq_5hz;
static int32_t  g_cc_simulate;

static int g_cc_sys_idx;          // cycles 0..3 through system TSBKs
static int g_cc_frame_count;      // total frames generated
static int g_cc_sim_tg_idx;       // current sim talkgroup index
static int g_cc_sim_call_frames;  // remaining grant-update frames for current call

static const uint16_t _sim_tgs[5]     = {1, 2, 3, 100, 200};
static const uint32_t _sim_units[6]   = {0x001001, 0x001002, 0x001003,
                                          0x001004, 0x001005, 0x001006};

static void _cc_load_next_frame(void) {
    uint8_t tsbk[12];

    // Simulated activity: grant updates in progress
    if (g_cc_simulate && g_cc_sim_call_frames > 0) {
        g_cc_sim_call_frames--;
        uint16_t tg = _sim_tgs[g_cc_sim_tg_idx % 5];
        _tsbk_grp_vch_grant_updt(tsbk, g_cc_chan_id, g_cc_chan_num, tg,
                                          g_cc_chan_id, g_cc_chan_num, tg);
        goto build;
    }

    // Simulated activity: start a new voice grant every 8 system frames
    if (g_cc_simulate && (g_cc_frame_count % 8 == 7)) {
        g_cc_sim_tg_idx++;
        uint16_t tg  = _sim_tgs[g_cc_sim_tg_idx % 5];
        uint32_t src = _sim_units[g_cc_sim_tg_idx % 6];
        _tsbk_grp_vch_grant(tsbk, 0x00, g_cc_chan_id, g_cc_chan_num, tg, src);
        g_cc_sim_call_frames = 3;
        goto build;
    }

    // System broadcast cycle: IDENUp → NetSts → RFSSts → AdjSts → repeat
    switch (g_cc_sys_idx % 4) {
        case 0:
            _tsbk_iden_up(tsbk, g_cc_chan_id, 100, 0, 100, g_cc_base_freq_5hz);
            break;
        case 1:
            _tsbk_net_status(tsbk, g_cc_wacn, g_cc_sysid,
                             g_cc_chan_id, g_cc_chan_num, 0x00);
            break;
        case 2:
            _tsbk_rfss_status(tsbk, 0, g_cc_sysid, g_cc_rfss, g_cc_site,
                              g_cc_chan_id, g_cc_chan_num, 0x00);
            break;
        default:
            _tsbk_adj_sts(tsbk, g_cc_sysid, g_cc_rfss,
                          (uint8_t)(g_cc_site + 1),
                          g_cc_chan_id, g_cc_chan_num, 0x00);
            break;
    }
    g_cc_sys_idx++;

build:
    g_cc_frame_count++;
    int n = _build_p25_frame(g_cc_dibit_buf, tsbk, g_cc_nac);
    g_cc_n_dibits = (n < CC_MAX_DIBITS) ? n : CC_MAX_DIBITS;
    g_cc_dibit_pos = 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// C4FM modulator state
// ─────────────────────────────────────────────────────────────────────────────

static float  g_history[C4FM_POLY_TAPS];
static int    g_hist_pos;
static double g_c4fm_phase;

// ─────────────────────────────────────────────────────────────────────────────
// Other generator states (CW / FM / Sweep)
// ─────────────────────────────────────────────────────────────────────────────

typedef enum { SG_IDLE=0, SG_CW=1, SG_FM=2, SG_SWEEP=3, SG_C4FM=4 } sg_mode_t;
static sg_mode_t g_sg_mode = SG_IDLE;

static double g_cw_phase;
static double g_cw_phase_inc;
static double g_cw_amplitude;

static double g_fm_carrier_phase;
static double g_fm_audio_phase;
static double g_fm_audio_phase_inc;
static double g_fm_deviation_inc;   // 2π × deviation / sample_rate
static double g_fm_amplitude;

static double g_sw_cur_freq;
static double g_sw_start_freq;
static double g_sw_stop_freq;
static double g_sw_freq_inc;        // Hz per sample
static double g_sw_sample_rate;
static double g_sw_phase;
static double g_sw_amplitude;

static int g_siggen_initialized = 0;

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

void rf_siggen_init(void) {
    if (g_siggen_initialized) return;
    _build_poly_filter();
    g_siggen_initialized = 1;
}

void rf_siggen_start_cw(double freq_offset_hz, double sample_rate, double amplitude) {
    rf_siggen_init();
    g_sg_mode       = SG_IDLE; // stop briefly
    g_cw_phase      = 0.0;
    g_cw_phase_inc  = 2.0 * M_PI * freq_offset_hz / sample_rate;
    g_cw_amplitude  = amplitude;
    g_sg_mode       = SG_CW;
}

void rf_siggen_start_fm(double audio_hz, double deviation_hz,
                         double sample_rate, double amplitude) {
    rf_siggen_init();
    g_sg_mode              = SG_IDLE;
    g_fm_carrier_phase     = 0.0;
    g_fm_audio_phase       = 0.0;
    g_fm_audio_phase_inc   = 2.0 * M_PI * audio_hz / sample_rate;
    g_fm_deviation_inc     = 2.0 * M_PI * deviation_hz / sample_rate;
    g_fm_amplitude         = amplitude;
    g_sg_mode              = SG_FM;
}

void rf_siggen_start_sweep(double start_hz, double stop_hz,
                            double rate_hz_per_sec, double sample_rate,
                            double amplitude) {
    rf_siggen_init();
    g_sg_mode       = SG_IDLE;
    g_sw_start_freq = start_hz;
    g_sw_stop_freq  = stop_hz;
    g_sw_cur_freq   = start_hz;
    g_sw_freq_inc   = rate_hz_per_sec / sample_rate;
    g_sw_sample_rate = sample_rate;
    g_sw_phase      = 0.0;
    g_sw_amplitude  = amplitude;
    g_sg_mode       = SG_SWEEP;
}

void rf_siggen_configure_c4fm(uint32_t nac, uint32_t wacn, uint32_t sysid,
                               uint32_t rfss, uint32_t site,
                               uint32_t chan_id, uint32_t chan_num,
                               uint32_t base_freq_5hz, int32_t simulate) {
    g_cc_nac          = (uint16_t)(nac & 0xFFF);
    g_cc_wacn         = wacn & 0xFFFFF;
    g_cc_sysid        = (uint16_t)(sysid & 0xFFF);
    g_cc_rfss         = (uint8_t)(rfss & 0xFF);
    g_cc_site         = (uint8_t)(site & 0xFF);
    g_cc_chan_id      = (uint8_t)(chan_id & 0xF);
    g_cc_chan_num     = (uint16_t)(chan_num & 0xFFF);
    g_cc_base_freq_5hz = base_freq_5hz;
    g_cc_simulate     = simulate;
}

void rf_siggen_start_c4fm(void) {
    rf_siggen_init();
    g_sg_mode             = SG_IDLE;
    // Reset modulator state
    memset(g_history,  0, sizeof(g_history));
    g_hist_pos            = 0;
    g_c4fm_phase          = 0.0;
    // Reset CC state
    g_cc_n_dibits         = 0;
    g_cc_dibit_pos        = 0;
    g_cc_sample_in_dibit  = 0;
    g_cc_sys_idx          = 0;
    g_cc_frame_count      = 0;
    g_cc_sim_tg_idx       = 0;
    g_cc_sim_call_frames  = 0;
    g_sg_mode             = SG_C4FM;
}

void rf_siggen_stop(void) {
    g_sg_mode = SG_IDLE;
}

int32_t rf_siggen_mode(void) {
    return (int32_t)g_sg_mode;
}

// Fills exactly n bytes (must be even) of IQ data into buf.
// Returns n on success, 0 if mode is idle.
int32_t rf_siggen_fill(uint8_t *buf, int32_t n) {
    if (g_sg_mode == SG_IDLE || n <= 0) return 0;

    int pos = 0;

    if (g_sg_mode == SG_CW) {
        int pairs = n / 2;
        double phase = g_cw_phase;
        double inc   = g_cw_phase_inc;
        double amp   = g_cw_amplitude;
        for (int i = 0; i < pairs; i++) {
            buf[pos++] = (uint8_t)(int8_t)(cos(phase) * amp);
            buf[pos++] = (uint8_t)(int8_t)(sin(phase) * amp);
            phase += inc;
            if (phase >  M_PI) phase -= 2.0 * M_PI;
            if (phase < -M_PI) phase += 2.0 * M_PI;
        }
        g_cw_phase = phase;

    } else if (g_sg_mode == SG_FM) {
        int pairs = n / 2;
        double cphase = g_fm_carrier_phase;
        double aphase = g_fm_audio_phase;
        double ainc   = g_fm_audio_phase_inc;
        double devinc = g_fm_deviation_inc;
        double amp    = g_fm_amplitude;
        for (int i = 0; i < pairs; i++) {
            cphase += cos(aphase) * devinc;
            buf[pos++] = (uint8_t)(int8_t)(cos(cphase) * amp);
            buf[pos++] = (uint8_t)(int8_t)(sin(cphase) * amp);
            aphase += ainc;
            if (aphase > 2.0 * M_PI) aphase -= 2.0 * M_PI;
        }
        g_fm_carrier_phase = cphase;
        g_fm_audio_phase   = aphase;

    } else if (g_sg_mode == SG_SWEEP) {
        int pairs = n / 2;
        double phase     = g_sw_phase;
        double cur_freq  = g_sw_cur_freq;
        double sr        = g_sw_sample_rate;
        double finc      = g_sw_freq_inc;
        double start     = g_sw_start_freq;
        double stop      = g_sw_stop_freq;
        double amp       = g_sw_amplitude;
        for (int i = 0; i < pairs; i++) {
            phase += 2.0 * M_PI * cur_freq / sr;
            buf[pos++] = (uint8_t)(int8_t)(cos(phase) * amp);
            buf[pos++] = (uint8_t)(int8_t)(sin(phase) * amp);
            cur_freq += finc;
            if (cur_freq > stop)  cur_freq = start;
            if (cur_freq < start) cur_freq = stop;
            if (phase >  M_PI) phase -= 2.0 * M_PI;
            if (phase < -M_PI) phase += 2.0 * M_PI;
        }
        g_sw_phase    = phase;
        g_sw_cur_freq = cur_freq;

    } else if (g_sg_mode == SG_C4FM) {
        const double phaseInc = 2.0 * M_PI * C4FM_DEV_PER_UNIT / C4FM_SAMPLE_RATE;

        while (pos + 1 < n) {
            // Load a new dibit when the previous one's samples are exhausted
            if (g_cc_sample_in_dibit == 0) {
                if (g_cc_dibit_pos >= g_cc_n_dibits)
                    _cc_load_next_frame();
                uint8_t d = g_cc_dibit_buf[g_cc_dibit_pos++];
                // Insert symbol into history ring
                g_history[g_hist_pos] = c4fm_sym[d & 3];
                g_hist_pos = (g_hist_pos + 1) % C4FM_POLY_TAPS;
            }

            // Compute polyphase filter output for sample g_cc_sample_in_dibit
            int p = g_cc_sample_in_dibit;
            const float *comp = g_poly[p];
            float acc = 0.0f;
            for (int j = 0; j < C4FM_POLY_TAPS; j++) {
                int idx = ((g_hist_pos - 1 - j) % C4FM_POLY_TAPS + C4FM_POLY_TAPS)
                          % C4FM_POLY_TAPS;
                acc += comp[j] * g_history[idx];
            }

            g_c4fm_phase += (double)acc * phaseInc;
            buf[pos++] = (uint8_t)(int8_t)(cos(g_c4fm_phase) * 100.0);
            buf[pos++] = (uint8_t)(int8_t)(sin(g_c4fm_phase) * 100.0);

            g_cc_sample_in_dibit++;
            if (g_cc_sample_in_dibit >= C4FM_OSR)
                g_cc_sample_in_dibit = 0;
        }
    }

    return pos;
}
