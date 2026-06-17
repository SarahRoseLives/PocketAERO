// adsb_ffi.cpp
//
// ADS-B (Mode S / 1090 MHz) decoder FFI library for RFStudio.
// Self-contained — does NOT include dump1090.h.
// Uses only cpr.h and ais_charset.h from the dump1090/ subfolder.
//
// C exports:
//   adsb_start(fd, dev_path)        → 1=ok, 0=fail
//   adsb_stop()
//   adsb_get_aircraft(out, max)     → count written
//   adsb_is_running()               → 1/0
//   adsb_get_message_count()        → total messages decoded

extern "C" {
#include "dump1090/cpr.h"
#include "dump1090/ais_charset.h"
}
#include "librtlsdr/include/rtl-sdr.h"
#include "librtlsdr/include/rtl-sdr-android.h"

#include <android/log.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <pthread.h>
#include <string>
#include <unordered_map>
#include <vector>

#define TAG  "adsb_ffi"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Constants ─────────────────────────────────────────────────────────────────

#define ADSB_FREQ        1090000000ULL
#define ADSB_SAMPLE_RATE 2400000
#define LONG_MSG_BITS    112
#define SHORT_MSG_BITS   56

// Aircraft TTL: 60 seconds
#define AIRCRAFT_TTL_MS  60000ULL

// ── CRC-24 Mode S ─────────────────────────────────────────────────────────────
// Table-based implementation matching dump1090 exactly.
// modesChecksum(msg, bits) returns 0 for a valid message.

#define MODES_GENERATOR_POLY 0xFFF409U

static uint32_t crc_table[256];
static bool     crc_table_init = false;

static void init_crc_table() {
    if (crc_table_init) return;
    for (int i = 0; i < 256; i++) {
        uint32_t c = (uint32_t)i << 16;
        for (int j = 0; j < 8; j++) {
            c = (c & 0x800000) ? (c << 1) ^ MODES_GENERATOR_POLY : (c << 1);
        }
        crc_table[i] = c & 0xFFFFFF;
    }
    crc_table_init = true;
}

// Returns 0 for a valid message (covers all bits including the 3 CRC bytes).
static uint32_t modes_checksum(const uint8_t* msg, int bits) {
    uint32_t rem = 0;
    int n = bits / 8;
    for (int i = 0; i < n - 3; i++) {
        rem = (rem << 8) ^ crc_table[msg[i] ^ ((rem & 0xFF0000) >> 16)];
        rem &= 0xFFFFFF;
    }
    rem ^= ((uint32_t)msg[n-3] << 16) ^ ((uint32_t)msg[n-2] << 8) ^ msg[n-1];
    return rem;
}

// ── IQ → Magnitude lookup table ───────────────────────────────────────────────

static uint16_t mag_table[256 * 256];
static bool     mag_table_init = false;

static void init_mag_table() {
    if (mag_table_init) return;
    for (int i = 0; i < 256; i++) {
        for (int q = 0; q < 256; q++) {
            float fi = (i - 127.5f) / 127.5f;
            float fq = (q - 127.5f) / 127.5f;
            float m  = sqrtf(fi * fi + fq * fq) * 65535.0f / 1.414f;
            if (m > 65535.0f) m = 65535.0f;
            mag_table[i * 256 + q] = (uint16_t)m;
        }
    }
    mag_table_init = true;
}

// ── Aircraft data ─────────────────────────────────────────────────────────────

struct AdsbAircraft {
    uint32_t addr;
    char     callsign[9];
    double   lat;
    double   lon;
    int      altitude;
    float    speed;
    float    heading;
    int      vert_rate;
    unsigned squawk;
    int      on_ground;
    uint64_t seen_ms;
    long     messages;

    // CPR position state
    int      even_cprlat;
    int      even_cprlon;
    uint64_t even_seen_ms;
    int      odd_cprlat;
    int      odd_cprlon;
    uint64_t odd_seen_ms;
    int      pos_valid;
};

static std::unordered_map<uint32_t, AdsbAircraft> g_aircraft;
static std::mutex g_aircraft_mutex;
static std::atomic<long> g_msg_count{0};

static uint64_t now_ms() {
    using namespace std::chrono;
    return (uint64_t)duration_cast<milliseconds>(
        steady_clock::now().time_since_epoch()).count();
}

static AdsbAircraft& get_or_create(uint32_t addr) {
    auto it = g_aircraft.find(addr);
    if (it == g_aircraft.end()) {
        AdsbAircraft a{};
        a.addr      = addr;
        a.altitude  = INT32_MIN;
        a.speed     = -1.0f;
        a.heading   = -1.0f;
        a.vert_rate = INT32_MIN;
        a.callsign[0] = '\0';
        it = g_aircraft.emplace(addr, a).first;
    }
    return it->second;
}

static void purge_stale(uint64_t now) {
    for (auto it = g_aircraft.begin(); it != g_aircraft.end(); ) {
        if (now - it->second.seen_ms > AIRCRAFT_TTL_MS) {
            it = g_aircraft.erase(it);
        } else {
            ++it;
        }
    }
}

// ── Message parser ────────────────────────────────────────────────────────────

static void parse_df17(const uint8_t* msg, int len, uint64_t ts) {
    if (len < 14) return;

    uint32_t addr = ((uint32_t)msg[1] << 16) | ((uint32_t)msg[2] << 8) | msg[3];
    int tc = (msg[4] >> 3) & 0x1F;

    std::lock_guard<std::mutex> lk(g_aircraft_mutex);
    AdsbAircraft& ac = get_or_create(addr);
    ac.seen_ms = ts;
    ac.messages++;

    // TC 1-4: Aircraft Identification (callsign)
    if (tc >= 1 && tc <= 4) {
        // 8 chars × 6 bits = 48 bits starting at byte 5 (bits 40-87)
        const uint8_t* d = msg + 4; // payload starts at byte 4
        // Each character is 6 bits, packed into bytes 1-6 of payload (msg[5..10])
        uint64_t bits = 0;
        for (int i = 1; i <= 6; i++) {
            bits = (bits << 8) | d[i];
        }
        // Extract 8 characters, most-significant first
        for (int i = 7; i >= 0; i--) {
            uint8_t idx = bits & 0x3F;
            bits >>= 6;
            char c = ais_charset[idx];
            ac.callsign[i] = (c == ' ') ? '\0' : c;
        }
        ac.callsign[8] = '\0';
        // Trim trailing spaces/nulls
        int end = 7;
        while (end >= 0 && (ac.callsign[end] == ' ' || ac.callsign[end] == '\0')) {
            ac.callsign[end--] = '\0';
        }
    }

    // TC 9-18: Airborne position
    if (tc >= 9 && tc <= 18) {
        const uint8_t* d = msg + 4; // payload
        // Altitude: bits 13-24 of payload (zero-indexed from bit 0 of d[0])
        // d[0] bits: [TC(5)][SS(2)][NICsb(1)] | d[1] bits: [alt(8)] | d[2] bits: [alt(4)][...]
        int alt_raw  = ((d[1] << 4) | (d[2] >> 4)) & 0x1FFF;
        int q_bit    = (alt_raw >> 4) & 1;
        if (q_bit) {
            int n = ((alt_raw & 0x1F80) >> 1) | (alt_raw & 0x3F);
            ac.altitude = n * 25 - 1000;
        }

        int fflag    = (d[2] >> 2) & 1; // odd=1, even=0
        int cprlat   = ((d[2] & 0x3) << 15) | (d[3] << 7) | (d[4] >> 1);
        int cprlon   = ((d[4] & 0x1) << 16) | (d[5] << 8) | d[6];

        if (fflag == 0) {
            ac.even_cprlat  = cprlat;
            ac.even_cprlon  = cprlon;
            ac.even_seen_ms = ts;
        } else {
            ac.odd_cprlat  = cprlat;
            ac.odd_cprlon  = cprlon;
            ac.odd_seen_ms = ts;
        }

        // Decode if we have both frames within 10 seconds
        if (ac.even_seen_ms != 0 && ac.odd_seen_ms != 0) {
            uint64_t age = (ac.even_seen_ms > ac.odd_seen_ms)
                           ? ac.even_seen_ms - ac.odd_seen_ms
                           : ac.odd_seen_ms - ac.even_seen_ms;
            if (age < 10000ULL) {
                // Use the most recent frame's fflag to determine which is newer
                int use_odd = (ac.odd_seen_ms >= ac.even_seen_ms) ? 1 : 0;
                double lat, lon;
                int rc = decodeCPRairborne(
                    ac.even_cprlat, ac.even_cprlon,
                    ac.odd_cprlat,  ac.odd_cprlon,
                    use_odd, &lat, &lon);
                if (rc == 0) {
                    ac.lat       = lat;
                    ac.lon       = lon;
                    ac.pos_valid = 1;
                }
            }
        }

        // Surface/ground check: SS bits
        int ss = (d[0] >> 1) & 3;
        ac.on_ground = (ss == 0) ? 0 : 0; // SS=0 means no status; keep 0
    }

    // TC 5-8: Surface position
    if (tc >= 5 && tc <= 8) {
        ac.on_ground = 1;
    }

    // TC 19: Airborne velocity
    if (tc == 19) {
        const uint8_t* d = msg + 4;
        int sub = d[0] & 0x07;
        if (sub == 1 || sub == 2) {
            // EW / NS components
            int dir_ew  = (d[1] >> 2) & 1;
            int vel_ew  = ((d[1] & 0x3) << 8) | d[2];
            int dir_ns  = (d[3] >> 7) & 1;
            int vel_ns  = ((d[3] & 0x7F) << 3) | (d[4] >> 5);

            if (vel_ew > 0 && vel_ns > 0) {
                double vx = (double)(vel_ew - 1) * (dir_ew ? -1 : 1);
                double vy = (double)(vel_ns - 1) * (dir_ns ? -1 : 1);
                ac.speed   = (float)sqrtf((float)(vx*vx + vy*vy));
                double hdg = atan2(vx, vy) * 180.0 / M_PI;
                if (hdg < 0) hdg += 360.0;
                ac.heading = (float)hdg;
            }

            // Vertical rate
            int vr_sign = (d[4] >> 3) & 1;
            int vr_val  = ((d[4] & 0x07) << 6) | (d[5] >> 2);
            if (vr_val > 0) {
                ac.vert_rate = (vr_val - 1) * 64 * (vr_sign ? -1 : 1);
            }
        }
    }

    // TC 28: Emergency / Squawk
    if (tc == 28) {
        const uint8_t* d = msg + 4;
        int sub = d[0] & 7;
        if (sub == 1) {
            // Emergency squawk in bits 33-45
            int sq13 = ((d[4] & 0x1F) << 8) | d[5];
            // Convert Gillham / Gray code to octal squawk
            // Simplified: just extract 13-bit squawk
            // Bit pattern: C1 A1 C2 A2 C4 A4 0 B1 D1 B2 D2 B4 D4
            int c1 = (sq13 >> 12) & 1;
            int a1 = (sq13 >> 11) & 1;
            int c2 = (sq13 >> 10) & 1;
            int a2 = (sq13 >> 9)  & 1;
            int c4 = (sq13 >> 8)  & 1;
            int a4 = (sq13 >> 7)  & 1;
            int b1 = (sq13 >> 5)  & 1;
            int b2 = (sq13 >> 3)  & 1;
            int b4 = (sq13 >> 1)  & 1;
            int a_digit = a1*1 + a2*2 + a4*4;
            int b_digit = b1*1 + b2*2 + b4*4;
            int c_digit = c1*1 + c2*2 + c4*4;
            ac.squawk = (unsigned)(a_digit * 100 + b_digit * 10 + c_digit);
        }
    }
}

// Parse DF (Downlink Format) messages — CRC already verified by caller
static void parse_message(const uint8_t* msg, int bits, uint64_t ts) {
    int df = (msg[0] >> 3) & 0x1F;

    // DF17 = Extended Squitter (ADS-B)
    if (df == 17 && bits == LONG_MSG_BITS) {
        parse_df17(msg, bits / 8, ts);
        g_msg_count.fetch_add(1, std::memory_order_relaxed);
    }
    // DF11 = Mode S All-Call Reply (just track ICAO)
    else if (df == 11 && bits == SHORT_MSG_BITS) {
        uint32_t addr = ((uint32_t)msg[1] << 16) |
                        ((uint32_t)msg[2] << 8) | msg[3];
        std::lock_guard<std::mutex> lk(g_aircraft_mutex);
        AdsbAircraft& ac = get_or_create(addr);
        ac.seen_ms = ts;
        ac.messages++;
        g_msg_count.fetch_add(1, std::memory_order_relaxed);
    }
}

// ── Demodulator — copied from dump1090/demod_2400.c ──────────────────────────
//
// At 2.4 MSPS there are exactly 6 samples per 5 symbols (bits).
// Phase offset is in units of 1/5 sample (83.3 ns).
// Each symbol advance moves the phase by 6/5 units.
//
// Correlation functions: correlate a 1-0 Manchester-encoded bit starting at m[0],
// assuming the symbol starts at sub-sample phase 0..4 within m[0].
// Returns >0 for a 1 bit, <0 for a 0 bit.

static inline int slice_phase0(uint16_t *m) { return  5*m[0] - 3*m[1] - 2*m[2]; }
static inline int slice_phase1(uint16_t *m) { return  4*m[0] -   m[1] - 3*m[2]; }
static inline int slice_phase2(uint16_t *m) { return  3*m[0] +   m[1] - 4*m[2]; }
static inline int slice_phase3(uint16_t *m) { return  2*m[0] + 3*m[1] - 5*m[2]; }
static inline int slice_phase4(uint16_t *m) { return    m[0] + 5*m[1] - 5*m[2] - m[3]; }

// Decode one byte of 8 Manchester-encoded bits at the current phase.
// Advances *pPtr and updates *phase exactly as dump1090 does.
static inline uint8_t decode_byte(uint16_t **pPtr, int *phase) {
    uint8_t b = 0;
    switch (*phase) {
    case 0:
        b = (slice_phase0(*pPtr)    > 0 ? 0x80 : 0) |
            (slice_phase2(*pPtr+2)  > 0 ? 0x40 : 0) |
            (slice_phase4(*pPtr+4)  > 0 ? 0x20 : 0) |
            (slice_phase1(*pPtr+7)  > 0 ? 0x10 : 0) |
            (slice_phase3(*pPtr+9)  > 0 ? 0x08 : 0) |
            (slice_phase0(*pPtr+12) > 0 ? 0x04 : 0) |
            (slice_phase2(*pPtr+14) > 0 ? 0x02 : 0) |
            (slice_phase4(*pPtr+16) > 0 ? 0x01 : 0);
        *phase = 1; *pPtr += 19; break;
    case 1:
        b = (slice_phase1(*pPtr)    > 0 ? 0x80 : 0) |
            (slice_phase3(*pPtr+2)  > 0 ? 0x40 : 0) |
            (slice_phase0(*pPtr+5)  > 0 ? 0x20 : 0) |
            (slice_phase2(*pPtr+7)  > 0 ? 0x10 : 0) |
            (slice_phase4(*pPtr+9)  > 0 ? 0x08 : 0) |
            (slice_phase1(*pPtr+12) > 0 ? 0x04 : 0) |
            (slice_phase3(*pPtr+14) > 0 ? 0x02 : 0) |
            (slice_phase0(*pPtr+17) > 0 ? 0x01 : 0);
        *phase = 2; *pPtr += 19; break;
    case 2:
        b = (slice_phase2(*pPtr)    > 0 ? 0x80 : 0) |
            (slice_phase4(*pPtr+2)  > 0 ? 0x40 : 0) |
            (slice_phase1(*pPtr+5)  > 0 ? 0x20 : 0) |
            (slice_phase3(*pPtr+7)  > 0 ? 0x10 : 0) |
            (slice_phase0(*pPtr+10) > 0 ? 0x08 : 0) |
            (slice_phase2(*pPtr+12) > 0 ? 0x04 : 0) |
            (slice_phase4(*pPtr+14) > 0 ? 0x02 : 0) |
            (slice_phase1(*pPtr+17) > 0 ? 0x01 : 0);
        *phase = 3; *pPtr += 19; break;
    case 3:
        b = (slice_phase3(*pPtr)    > 0 ? 0x80 : 0) |
            (slice_phase0(*pPtr+3)  > 0 ? 0x40 : 0) |
            (slice_phase2(*pPtr+5)  > 0 ? 0x20 : 0) |
            (slice_phase4(*pPtr+7)  > 0 ? 0x10 : 0) |
            (slice_phase1(*pPtr+10) > 0 ? 0x08 : 0) |
            (slice_phase3(*pPtr+12) > 0 ? 0x04 : 0) |
            (slice_phase0(*pPtr+15) > 0 ? 0x02 : 0) |
            (slice_phase2(*pPtr+17) > 0 ? 0x01 : 0);
        *phase = 4; *pPtr += 19; break;
    default: /* case 4 */
        b = (slice_phase4(*pPtr)    > 0 ? 0x80 : 0) |
            (slice_phase1(*pPtr+3)  > 0 ? 0x40 : 0) |
            (slice_phase3(*pPtr+5)  > 0 ? 0x20 : 0) |
            (slice_phase0(*pPtr+8)  > 0 ? 0x10 : 0) |
            (slice_phase2(*pPtr+10) > 0 ? 0x08 : 0) |
            (slice_phase4(*pPtr+12) > 0 ? 0x04 : 0) |
            (slice_phase1(*pPtr+15) > 0 ? 0x02 : 0) |
            (slice_phase3(*pPtr+17) > 0 ? 0x01 : 0);
        *phase = 0; *pPtr += 20; break;  // phase 4 advances 20, not 19
    }
    return b;
}

static std::atomic<uint64_t> g_bytes_rx{0};
static std::atomic<uint64_t> g_preambles{0};
static std::atomic<uint64_t> g_crc_pass{0};
static std::atomic<uint64_t> g_crc_fail{0};

// Preamble detection: 5 phase variants copied from dump1090/demod_2400.c.
// Returns true if a valid preamble pattern is found; fills high/base_signal/base_noise.
static bool check_preamble(const uint16_t *p,
                            uint16_t *high,
                            uint32_t *base_signal, uint32_t *base_noise) {
    // Quick pre-filter (from dump1090): rising edge at 0->1, falling at 12->13
    if (!(p[0] < p[1] && p[12] > p[13])) return false;

    if (p[1] > p[2] && p[2] < p[3] && p[3] > p[4] &&
        p[8] < p[9] && p[9] > p[10] && p[10] < p[11]) {
        // phase 3: peaks at 1, 3, 9, 11-12
        *high        = (p[1] + p[3] + p[9] + p[11] + p[12]) / 4;
        *base_signal =  p[1] + p[3] + p[9];
        *base_noise  =  p[5] + p[6] + p[7];
    } else if (p[1] > p[2] && p[2] < p[3] && p[3] > p[4] &&
               p[8] < p[9] && p[9] > p[10] && p[11] < p[12]) {
        // phase 4: peaks at 1, 3, 9, 12
        *high        = (p[1] + p[3] + p[9] + p[12]) / 4;
        *base_signal =  p[1] + p[3] + p[9] + p[12];
        *base_noise  =  p[5] + p[6] + p[7] + p[8];
    } else if (p[1] > p[2] && p[2] < p[3] && p[4] > p[5] &&
               p[8] < p[9] && p[10] > p[11] && p[11] < p[12]) {
        // phase 5: peaks at 1, 3-4, 9-10, 12
        *high        = (p[1] + p[3] + p[4] + p[9] + p[10] + p[12]) / 4;
        *base_signal =  p[1] + p[12];
        *base_noise  =  p[6] + p[7];
    } else if (p[1] > p[2] && p[3] < p[4] && p[4] > p[5] &&
               p[9] < p[10] && p[10] > p[11] && p[11] < p[12]) {
        // phase 6: peaks at 1, 4, 10, 12
        *high        = (p[1] + p[4] + p[10] + p[12]) / 4;
        *base_signal =  p[1] + p[4] + p[10] + p[12];
        *base_noise  =  p[5] + p[6] + p[7] + p[8];
    } else if (p[2] > p[3] && p[3] < p[4] && p[4] > p[5] &&
               p[9] < p[10] && p[10] > p[11] && p[11] < p[12]) {
        // phase 7: peaks at 1-2, 4, 10, 12
        *high        = (p[1] + p[2] + p[4] + p[10] + p[12]) / 4;
        *base_signal =  p[4] + p[10] + p[12];
        *base_noise  =  p[6] + p[7] + p[8];
    } else {
        return false;
    }
    return true;
}

static void demodulate(uint16_t* mag, size_t len, uint64_t ts) {
    // Need 19 (preamble) + up to 14 bytes × 20 samples + 17 slack = 317 samples
    if (len < 320) return;

    for (size_t j = 0; j < len - 320; j++) {
        uint16_t high;
        uint32_t base_signal, base_noise;

        if (!check_preamble(mag + j, &high, &base_signal, &base_noise)) continue;

        // ~3.5 dB SNR required (copied from dump1090)
        if (base_signal * 2 < 3 * base_noise) continue;

        // Quiet gap samples 5,6,7,8,14,15,16,17,18 must be below high
        uint16_t *p = mag + j;
        if (p[5] >= high || p[6] >= high || p[7] >= high || p[8] >= high ||
            p[14] >= high || p[15] >= high || p[16] >= high ||
            p[17] >= high || p[18] >= high) continue;

        g_preambles.fetch_add(1, std::memory_order_relaxed);

        // Try all 5 phases (try_phase 4..8) — copied from dump1090
        uint8_t best_msg[14] = {};
        bool    accepted = false;

        for (int try_phase = 4; try_phase <= 8 && !accepted; try_phase++) {
            uint16_t *pPtr  = &mag[j + 19] + (try_phase / 5); // j+19 or j+20
            int       phase = try_phase % 5;

            uint8_t msg[14] = {};

            // Decode first byte to get DF
            msg[0] = decode_byte(&pPtr, &phase);
            int df = msg[0] >> 3;

            // Accept DF 17 (long, 112 bits) or DF 11/0/4/5 (short, 56 bits)
            int nbytes;
            if (df == 17 || df == 18 || df == 16 || df == 20 || df == 21)
                nbytes = LONG_MSG_BITS / 8;   // 14
            else if (df == 11 || df == 0 || df == 4 || df == 5)
                nbytes = SHORT_MSG_BITS / 8;  // 7
            else
                continue;

            // Decode remaining bytes
            for (int i = 1; i < nbytes; i++)
                msg[i] = decode_byte(&pPtr, &phase);

            if (modes_checksum(msg, nbytes * 8) == 0) {
                memcpy(best_msg, msg, nbytes);
                g_crc_pass.fetch_add(1, std::memory_order_relaxed);
                parse_message(best_msg, nbytes * 8, ts);
                accepted = true;
            } else {
                g_crc_fail.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
}

// ── RTL-SDR capture ───────────────────────────────────────────────────────────

static rtlsdr_dev_t*    g_dev        = nullptr;
static pthread_t        g_thread;
static std::atomic<bool> g_running   {false};
static std::atomic<bool> g_stop_req  {false};

// Scratch buffer for magnitude (reused across callbacks)
static std::vector<uint16_t> g_mag_buf;

static void rtlsdr_cb(unsigned char* buf, uint32_t len, void* /*ctx*/) {
    if (g_stop_req.load(std::memory_order_relaxed)) return;
    if (len == 0 || (len & 1)) return;

    g_bytes_rx.fetch_add(len, std::memory_order_relaxed);

    uint32_t nsamples = len / 2;
    if (g_mag_buf.size() < nsamples) g_mag_buf.resize(nsamples);

    for (uint32_t j = 0; j < nsamples; j++) {
        g_mag_buf[j] = mag_table[buf[j*2] * 256 + buf[j*2+1]];
    }

    uint64_t ts = now_ms();
    demodulate(g_mag_buf.data(), nsamples, ts);

    // Log stats + purge stale aircraft every ~2s
    static uint64_t last_log = 0;
    if (ts - last_log > 2000) {
        LOGI("stats: bytes_rx=%llu preambles=%llu crc_pass=%llu crc_fail=%llu msgs=%ld",
             (unsigned long long)g_bytes_rx.load(),
             (unsigned long long)g_preambles.load(),
             (unsigned long long)g_crc_pass.load(),
             (unsigned long long)g_crc_fail.load(),
             (long)g_msg_count.load());
        last_log = ts;
        std::lock_guard<std::mutex> lk(g_aircraft_mutex);
        purge_stale(ts);
    }
}

static void* capture_thread(void* /*arg*/) {
    LOGI("capture_thread: starting async read");
    int r = rtlsdr_read_async(g_dev, rtlsdr_cb, nullptr, 0, 512 * 1024);
    LOGI("capture_thread: rtlsdr_read_async returned %d", r);
    g_running.store(false, std::memory_order_release);
    return nullptr;
}

// ── C exports ────────────────────────────────────────────────────────────────

extern "C" {

typedef struct {
    uint32_t addr;
    char     callsign[9];
    double   lat;
    double   lon;
    int      altitude;
    float    speed;
    float    heading;
    int      vert_rate;
    unsigned squawk;
    int      on_ground;
    int      pos_valid;
    long     messages;
} AdsbAircraftExport;

int adsb_start(int fd, const char* dev_path) {
    if (g_running.load()) {
        LOGE("adsb_start: already running");
        return 0;
    }

    init_mag_table();
    init_crc_table();
    g_aircraft.clear();
    g_msg_count.store(0);
    g_stop_req.store(false);
    g_bytes_rx.store(0);
    g_preambles.store(0);
    g_crc_pass.store(0);
    g_crc_fail.store(0);

    int r = rtlsdr_open2(&g_dev, fd, dev_path);
    if (r < 0 || g_dev == nullptr) {
        LOGE("adsb_start: rtlsdr_open_android failed (%d)", r);
        return 0;
    }

    rtlsdr_set_center_freq(g_dev, (uint32_t)ADSB_FREQ);
    rtlsdr_set_sample_rate(g_dev, (uint32_t)ADSB_SAMPLE_RATE);
    rtlsdr_set_agc_mode(g_dev, 1);
    rtlsdr_set_tuner_gain_mode(g_dev, 0); // auto gain
    rtlsdr_reset_buffer(g_dev);

    LOGI("adsb_start: freq=%llu rate=%d", (unsigned long long)ADSB_FREQ, ADSB_SAMPLE_RATE);

    g_running.store(true, std::memory_order_release);
    pthread_create(&g_thread, nullptr, capture_thread, nullptr);
    return 1;
}

void adsb_stop(void) {
    if (!g_running.load() && g_dev == nullptr) return;
    LOGI("adsb_stop: stopping");
    g_stop_req.store(true, std::memory_order_release);
    if (g_dev) {
        rtlsdr_cancel_async(g_dev);
    }
    if (g_running.load()) {
        pthread_join(g_thread, nullptr);
    }
    if (g_dev) {
        rtlsdr_close(g_dev);
        g_dev = nullptr;
    }
    g_running.store(false, std::memory_order_release);
    LOGI("adsb_stop: done");
}

int adsb_get_aircraft(AdsbAircraftExport* out, int max_count) {
    if (!out || max_count <= 0) return 0;
    std::lock_guard<std::mutex> lk(g_aircraft_mutex);
    int n = 0;
    for (auto& kv : g_aircraft) {
        if (n >= max_count) break;
        const AdsbAircraft& ac = kv.second;
        AdsbAircraftExport& ex = out[n++];
        ex.addr      = ac.addr;
        memcpy(ex.callsign, ac.callsign, 9);
        ex.lat       = ac.lat;
        ex.lon       = ac.lon;
        ex.altitude  = ac.altitude;
        ex.speed     = ac.speed;
        ex.heading   = ac.heading;
        ex.vert_rate = ac.vert_rate;
        ex.squawk    = ac.squawk;
        ex.on_ground = ac.on_ground;
        ex.pos_valid = ac.pos_valid;
        ex.messages  = ac.messages;
    }
    return n;
}

int adsb_is_running(void) {
    return g_running.load(std::memory_order_relaxed) ? 1 : 0;
}

long adsb_get_message_count(void) {
    return (long)g_msg_count.load(std::memory_order_relaxed);
}

} // extern "C"
