// dect_ffi.cpp
//
// DECT decoder FFI library for RFStudio.
// Wraps the DeDECTive AndroidDectEngine for use with RTL-SDR via Dart FFI.
//
// Exposes a C API:
//   dect_start(fd, dev_path, band)  → 1 on success, 0 on failure
//   dect_stop()
//   dect_get_status(DectStatus*)
//   dect_get_parts(DectPart*, max_count) → count written

#include "audio_output.h"      // stub — no PulseAudio on Android
#include "dc_blocker.h"
#include "dect_channels.h"
#include "packet_decoder.h"
#include "packet_receiver.h"
#include "phase_diff.h"
#include "wideband_monitor.h"  // WidebandSnapshot / WidebandChannelView types

// RTL-SDR Android API (fd-based open)
#include "librtlsdr/include/rtl-sdr.h"
#include "librtlsdr/include/rtl-sdr-android.h"

#include <android/log.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>

#define TAG  "dect_ffi"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── AndroidDectEngine (copied from DeDECTive) ─────────────────────────────────

namespace dedective {
namespace {

using Clock = std::chrono::steady_clock;
constexpr auto FOLLOW_TIMEOUT               = std::chrono::seconds(2);
constexpr size_t NARROWBAND_WARMUP_SAMPLES  = SAMPLE_RATE / 5;
constexpr size_t SCAN_WARMUP_SAMPLES        = SAMPLE_RATE / 20;   // ~50 ms per channel
constexpr size_t SCAN_DWELL_SAMPLES         = SAMPLE_RATE * 3 / 10; // ~300 ms per channel
constexpr size_t AUDIO_RING_SIZE            = 32768;

struct DedectiveAndroidStatus {
    int running;
    int mode;
    int band;
    int tuned_channel;
    uint64_t tuned_freq_hz;
    int voice_present;
    int part_count;
    uint64_t packets_seen;
    uint32_t buffered_audio_samples;
};

struct DedectiveAndroidRetuneRequest {
    uint64_t freq_hz;
    uint32_t sample_rate;
};

struct DedectiveAndroidChannel {
    int channel_number;
    uint64_t freq_hz;
    float relative_power_db;
    float smoothed_power_db;
    int active;
    int voice_detected;
    int qt_synced;
    int active_parts;
    uint64_t packets_seen;
};

struct DedectiveAndroidPart {
    int rx_id;
    int type;
    int voice_present;
    int qt_synced;
    int slot;
    uint64_t packets_ok;
    uint64_t packets_bad_crc;
    uint64_t voice_frames_ok;
    uint64_t voice_xcrc_fail;
    uint64_t voice_skipped;
    char part_id[16];
};

class AndroidDectEngine {
public:
    AndroidDectEngine() {
        set_band_locked(DectBand::US);
        clear_audio_locked();
    }

    void set_band(DectBand band) {
        std::lock_guard<std::mutex> lock(mutex_);
        set_band_locked(band);
        if (running_) {
            request_scanning_locked();
        }
    }

    void start() {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = true;
        request_scanning_locked();
    }

    void stop() {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
        mode_ = Mode::Stopped;
        tuned_channel_ = -1;
        pending_retune_ = false;
        voice_was_present_ = false;
        clear_parts_locked();
        clear_audio_locked();
    }

    void push_iq_bytes(const int8_t* data, size_t len) {
        if (!data || len < 2) return;
        iq_scratch_.clear();
        iq_scratch_.reserve(len / 2);
        for (size_t i = 0; i + 1 < len; i += 2) {
            iq_scratch_.emplace_back(
                static_cast<float>(data[i])     / 128.0f,
                static_cast<float>(data[i + 1]) / 128.0f);
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ || iq_scratch_.empty()) return;

        if (mode_ == Mode::Scanning) {
            process_narrowband_locked(iq_scratch_.data(), iq_scratch_.size());
            if (narrowband_warmup_remaining_ == 0 && nb_.packets_seen > 0 &&
                voice_present_locked()) {
                start_narrowband_locked(scan_channel_);
                return;
            }
            const size_t n = iq_scratch_.size();
            if (scan_dwell_remaining_ > n) {
                scan_dwell_remaining_ -= n;
            } else {
                scan_channel_ = (scan_channel_ + 1) % static_cast<int>(NUM_DECT_CHANNELS);
                setup_scan_channel_locked();
            }
            return;
        }

        if (mode_ == Mode::Narrowband) {
            process_narrowband_locked(iq_scratch_.data(), iq_scratch_.size());
            maybe_resume_scanning_locked();
        }
    }

    bool consume_retune_request(DedectiveAndroidRetuneRequest& out) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!pending_retune_) return false;
        out = pending_request_;
        pending_retune_ = false;
        return true;
    }

    void get_status(DedectiveAndroidStatus& out) {
        std::lock_guard<std::mutex> lock(mutex_);
        out.running = running_ ? 1 : 0;
        out.mode = static_cast<int>(mode_);
        out.band = band_ == DectBand::US ? 0 : 1;
        if (mode_ == Mode::Scanning) {
            out.tuned_channel = scan_channel_;
            out.tuned_freq_hz = (*channels_)[static_cast<size_t>(scan_channel_)].freq_hz;
        } else {
            out.tuned_channel = tuned_channel_;
            out.tuned_freq_hz = tuned_channel_ >= 0
                ? (*channels_)[tuned_channel_].freq_hz
                : dect_center_freq(band_);
        }
        out.part_count = nb_.part_count;
        out.packets_seen = nb_.packets_seen;
        out.voice_present = voice_present_locked() ? 1 : 0;
        out.buffered_audio_samples = static_cast<uint32_t>(buffered_audio_locked());
    }

    int get_parts(DedectiveAndroidPart* out, int max_count) {
        if (!out || max_count <= 0) return 0;
        std::lock_guard<std::mutex> lock(mutex_);
        const int count = std::min(max_count, nb_.part_count);
        for (int i = 0; i < count; ++i) {
            const auto& in = nb_.parts[static_cast<size_t>(i)];
            out[i].rx_id            = in.rx_id;
            out[i].type             = in.type == PartType::RFP ? 0 : 1;
            out[i].voice_present    = in.voice_present ? 1 : 0;
            out[i].qt_synced        = in.qt_synced ? 1 : 0;
            out[i].slot             = in.slot;
            out[i].packets_ok       = in.packets_ok;
            out[i].packets_bad_crc  = in.packets_bad_crc;
            out[i].voice_frames_ok  = in.voice_frames_ok;
            out[i].voice_xcrc_fail  = in.voice_xcrc_fail;
            out[i].voice_skipped    = in.voice_skipped;
            std::snprintf(out[i].part_id, sizeof(out[i].part_id), "%s",
                          in.part_id_valid ? in.part_id_hex().c_str() : "??????????");
        }
        return count;
    }

    int read_audio(int16_t* out, int max_samples) {
        if (!out || max_samples <= 0) return 0;
        std::lock_guard<std::mutex> lk(mutex_);
        int count = 0;
        while (count < max_samples && audio_read_pos_ != audio_write_pos_) {
            out[count++] = audio_ring_[audio_read_pos_];
            audio_read_pos_ = (audio_read_pos_ + 1) % AUDIO_RING_SIZE;
        }
        return count;
    }

private:
    enum class Mode { Stopped = 0, Scanning = 1, Narrowband = 2 };

    struct NarrowbandState {
        PhaseDiff phase_diff;
        DCBlocker dc_blocker;
        std::unique_ptr<PacketReceiver> receiver;
        std::unique_ptr<PacketDecoder>  decoder;
        std::array<PartInfo, MAX_PARTS> parts{};
        int      part_count = 0;
        uint64_t packets_seen = 0;
        int      mix_first_rx_id = -1;
        int16_t  mix_frame[80]{};

        NarrowbandState() : dc_blocker() {}
    };

    void set_band_locked(DectBand band) {
        band_     = band;
        channels_ = &dect_channels(band_);
        last_snapshot_ = WidebandSnapshot{};
        for (size_t i = 0; i < NUM_DECT_CHANNELS; ++i) {
            auto& ch = last_snapshot_.channels[i];
            ch.channel_number    = (*channels_)[i].number;
            ch.freq_hz           = (*channels_)[i].freq_hz;
            ch.smoothed_power_db = -120.0f;
            ch.relative_power_db = 0.0f;
            ch.active            = false;
            ch.voice_detected    = false;
            ch.qt_synced         = false;
            ch.active_parts      = 0;
            ch.packets_seen      = 0;
        }
    }

    void request_scanning_locked() {
        const int resume_from = tuned_channel_ >= 0
            ? (tuned_channel_ + 1) % static_cast<int>(NUM_DECT_CHANNELS)
            : 0;
        mode_             = Mode::Scanning;
        tuned_channel_    = -1;
        voice_was_present_= false;
        voice_lost_at_    = Clock::time_point{};
        clear_parts_locked();
        clear_audio_locked();
        set_band_locked(band_);
        scan_channel_ = resume_from;
        setup_scan_channel_locked();
    }

    void setup_scan_channel_locked() {
        nb_ = NarrowbandState();
        nb_.decoder = std::make_unique<PacketDecoder>(
            [this](const PartInfo parts[], int count) {
                nb_.part_count = std::min(count, MAX_PARTS);
                for (int i = 0; i < nb_.part_count; ++i)
                    nb_.parts[static_cast<size_t>(i)] = parts[i];
            });
        nb_.receiver = std::make_unique<PacketReceiver>(
            [this](const ReceivedPacket& pkt) {
                ++nb_.packets_seen;
                nb_.decoder->process_packet(pkt);
            },
            [this](int rx_id) {
                nb_.decoder->notify_lost(rx_id);
            });
        scan_dwell_remaining_      = SCAN_DWELL_SAMPLES;
        narrowband_warmup_remaining_ = SCAN_WARMUP_SAMPLES;
        for (auto& ch : last_snapshot_.channels) ch.active = false;
        last_snapshot_.channels[static_cast<size_t>(scan_channel_)].active = true;
        pending_request_ = {(*channels_)[static_cast<size_t>(scan_channel_)].freq_hz,
                            SAMPLE_RATE};
        pending_retune_ = true;
    }

    void start_narrowband_locked(int channel_index) {
        nb_ = NarrowbandState();
        nb_.decoder = std::make_unique<PacketDecoder>(
            [this](const PartInfo parts[], int count) {
                nb_.part_count = std::min(count, MAX_PARTS);
                for (int i = 0; i < nb_.part_count; ++i)
                    nb_.parts[static_cast<size_t>(i)] = parts[i];
            },
            [this](int rx_id, const int16_t* pcm, size_t count) {
                // Mix dual-stream audio into ring buffer (no audio output here)
                if (count != 80) {
                    push_audio_locked(pcm, count);
                    return;
                }
                if (nb_.mix_first_rx_id < 0) {
                    std::memcpy(nb_.mix_frame, pcm, 80 * sizeof(int16_t));
                    nb_.mix_first_rx_id = rx_id;
                    return;
                }
                if (rx_id != nb_.mix_first_rx_id) {
                    for (int i = 0; i < 80; ++i) {
                        const int mixed = static_cast<int>(nb_.mix_frame[i]) +
                                          static_cast<int>(pcm[i]);
                        nb_.mix_frame[i] = static_cast<int16_t>(
                            std::clamp(mixed, -32768, 32767));
                    }
                    push_audio_locked(nb_.mix_frame, 80);
                    nb_.mix_first_rx_id = -1;
                    return;
                }
                push_audio_locked(nb_.mix_frame, 80);
                std::memcpy(nb_.mix_frame, pcm, 80 * sizeof(int16_t));
            });
        nb_.receiver = std::make_unique<PacketReceiver>(
            [this](const ReceivedPacket& pkt) {
                ++nb_.packets_seen;
                last_nb_activity_ = Clock::now();
                nb_.decoder->process_packet(pkt);
            },
            [this](int rx_id) {
                nb_.decoder->notify_lost(rx_id);
            });
        mode_             = Mode::Narrowband;
        tuned_channel_    = channel_index;
        voice_was_present_= false;
        voice_lost_at_    = Clock::now();
        last_nb_activity_ = Clock::now();
        narrowband_warmup_remaining_ = NARROWBAND_WARMUP_SAMPLES;
        clear_audio_locked();
        pending_request_ = {(*channels_)[static_cast<size_t>(channel_index)].freq_hz,
                            SAMPLE_RATE};
        pending_retune_ = true;
    }

    void process_narrowband_locked(const std::complex<float>* samples, size_t n) {
        if (!nb_.receiver) return;
        size_t start = 0;
        if (narrowband_warmup_remaining_ > 0) {
            const size_t discard = std::min(n, narrowband_warmup_remaining_);
            narrowband_warmup_remaining_ -= discard;
            start = discard;
        }
        for (size_t i = start; i < n; ++i) {
            const auto filtered = nb_.dc_blocker.process(samples[i]);
            const float phase = nb_.phase_diff.process(filtered);
            nb_.receiver->process_sample(phase);
        }
    }

    void maybe_resume_scanning_locked() {
        if (mode_ != Mode::Narrowband) return;
        if (Clock::now() - last_nb_activity_ > FOLLOW_TIMEOUT) {
            request_scanning_locked();
            return;
        }
        const bool voice_now = voice_present_locked();
        if (voice_now) {
            voice_was_present_ = true;
            return;
        }
        if (voice_was_present_) {
            voice_was_present_ = false;
            voice_lost_at_     = Clock::now();
            return;
        }
        if (nb_.packets_seen == 0 || voice_lost_at_ == Clock::time_point{}) return;
        if (Clock::now() - voice_lost_at_ > FOLLOW_TIMEOUT) {
            request_scanning_locked();
        }
    }

    bool voice_present_locked() const {
        for (int i = 0; i < nb_.part_count; ++i) {
            if (nb_.parts[static_cast<size_t>(i)].voice_present) return true;
        }
        return false;
    }

    void clear_parts_locked() {
        nb_.part_count = 0;
        nb_.packets_seen = 0;
        nb_.mix_first_rx_id = -1;
        nb_.receiver.reset();
        nb_.decoder.reset();
        narrowband_warmup_remaining_ = 0;
    }

    void clear_audio_locked() {
        audio_ring_.fill(0);
        audio_read_pos_  = 0;
        audio_write_pos_ = 0;
    }

    size_t buffered_audio_locked() const {
        if (audio_write_pos_ >= audio_read_pos_)
            return audio_write_pos_ - audio_read_pos_;
        return AUDIO_RING_SIZE - (audio_read_pos_ - audio_write_pos_);
    }

    void push_audio_locked(const int16_t* pcm, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            const size_t next = (audio_write_pos_ + 1) % AUDIO_RING_SIZE;
            if (next == audio_read_pos_)
                audio_read_pos_ = (audio_read_pos_ + 1) % AUDIO_RING_SIZE;
            audio_ring_[audio_write_pos_] = pcm[i];
            audio_write_pos_ = next;
        }
    }

    mutable std::mutex mutex_;
    WidebandSnapshot last_snapshot_{};
    NarrowbandState  nb_;
    DectBand         band_     = DectBand::US;
    const std::array<DectChannel, NUM_DECT_CHANNELS>* channels_ =
        &US_DECT_CHANNELS;
    Mode     mode_             = Mode::Stopped;
    bool     running_          = false;
    int      tuned_channel_    = -1;
    bool     voice_was_present_= false;
    bool     pending_retune_   = false;
    DedectiveAndroidRetuneRequest pending_request_{};
    Clock::time_point voice_lost_at_{};
    Clock::time_point last_nb_activity_{};
    int    scan_channel_              = 0;
    size_t scan_dwell_remaining_      = 0;
    size_t narrowband_warmup_remaining_ = 0;
    std::array<int16_t, AUDIO_RING_SIZE> audio_ring_{};
    size_t audio_read_pos_  = 0;
    size_t audio_write_pos_ = 0;
    std::vector<std::complex<float>> iq_scratch_;
};

AndroidDectEngine& global_engine() {
    static AndroidDectEngine engine;
    return engine;
}

} // namespace
} // namespace dedective

// ── RTL-SDR capture thread ────────────────────────────────────────────────────

static rtlsdr_dev_t*    g_dev       = nullptr;
static pthread_t        g_thread    = 0;
static std::atomic<int> g_running   {0};
static constexpr int    READ_LEN    = 65536;
// RTL-SDR IQ bytes are uint8 0–255; centre at 128.
// DECT engine expects int8_t -128…127.
static uint8_t          g_iq_buf[READ_LEN];
static int8_t           g_iq_signed[READ_LEN];

static void* capture_thread(void* /*arg*/) {
    LOGI("capture thread started");

    while (g_running.load()) {
        // Handle pending retune request from the engine.
        dedective::DedectiveAndroidRetuneRequest req{};
        if (dedective::global_engine().consume_retune_request(req)) {
            LOGI("retune → %llu Hz  sr=%u", (unsigned long long)req.freq_hz,
                 req.sample_rate);
            rtlsdr_set_center_freq(g_dev, static_cast<uint32_t>(req.freq_hz));
            rtlsdr_set_sample_rate(g_dev, req.sample_rate);
            rtlsdr_reset_buffer(g_dev);
        }

        // Read a block of IQ samples.
        int n_read = 0;
        int rc = rtlsdr_read_sync(g_dev, g_iq_buf, READ_LEN, &n_read);
        if (rc != 0 || n_read <= 0) {
            if (g_running.load())
                LOGE("rtlsdr_read_sync failed (rc=%d n_read=%d)", rc, n_read);
            break;
        }

        // Convert uint8 → int8 by subtracting 128.
        for (int i = 0; i < n_read; ++i)
            g_iq_signed[i] = static_cast<int8_t>(
                static_cast<int>(g_iq_buf[i]) - 128);

        dedective::global_engine().push_iq_bytes(g_iq_signed,
                                                  static_cast<size_t>(n_read));
    }

    LOGI("capture thread exiting");
    return nullptr;
}

// ── C FFI exports ─────────────────────────────────────────────────────────────

extern "C" {

// Public structs (must match Dart FFI layout exactly).
struct DectStatus {
    int      running;          // 0=stopped, 1=scanning, 2=narrowband
    int      band;             // 0=US, 1=EU
    int      tuned_channel;    // -1=scanning, 0–9=locked
    uint64_t tuned_freq_hz;
    int      voice_present;
    int      part_count;
    uint64_t packets_seen;
};

struct DectPart {
    int      rx_id;
    int      type;             // 0=RFP (base), 1=PP (handset)
    int      voice_present;
    int      qt_synced;
    int      slot;
    uint64_t packets_ok;
    uint64_t packets_bad_crc;
    uint64_t voice_frames_ok;
    uint64_t voice_xcrc_fail;
    uint64_t voice_skipped;
    char     part_id[16];
};

/// Open RTL-SDR, set initial frequency & sample rate, start decode thread.
/// @param fd        Dup'd USB file descriptor from Android UsbManager.
/// @param dev_path  USB device path (e.g. "/dev/bus/usb/001/002").
/// @param band      0 = US DECT 6.0 (1920 MHz), 1 = EU DECT (1880 MHz).
/// @return 1 on success, 0 on failure.
int dect_start(int fd, const char* dev_path, int band) {
    if (g_running.load()) {
        LOGE("dect_start: already running");
        return 0;
    }
    if (!dev_path) {
        LOGE("dect_start: null dev_path");
        return 0;
    }

    // Open the RTL-SDR via the Android USB fd.
    if (g_dev) {
        rtlsdr_close(g_dev);
        g_dev = nullptr;
    }
    int rc = rtlsdr_open2(&g_dev, fd, dev_path);
    if (rc != 0) {
        LOGE("rtlsdr_open2 failed (rc=%d fd=%d path=%s)", rc, fd, dev_path);
        return 0;
    }

    // Configure the engine band before starting.
    dedective::global_engine().set_band(
        band == 1 ? dedective::DectBand::EU : dedective::DectBand::US);

    // Tune to the first channel of the selected band.
    using namespace dedective;
    const auto& chans = dect_channels(band == 1 ? DectBand::EU : DectBand::US);
    const uint64_t initial_freq = chans[0].freq_hz;

    rtlsdr_set_sample_rate(g_dev, SAMPLE_RATE);
    rtlsdr_set_center_freq(g_dev, static_cast<uint32_t>(initial_freq));
    rtlsdr_set_tuner_gain_mode(g_dev, 0);   // auto tuner gain
    rtlsdr_set_agc_mode(g_dev, 1);           // RTL2832 digital AGC
    rtlsdr_reset_buffer(g_dev);

    LOGI("RTL-SDR opened: fd=%d path=%s band=%s freq=%llu sr=%u",
         fd, dev_path,
         band == 1 ? "EU" : "US",
         (unsigned long long)initial_freq,
         SAMPLE_RATE);

    // Start the engine, then the capture thread.
    dedective::global_engine().start();
    g_running.store(1);

    if (pthread_create(&g_thread, nullptr, capture_thread, nullptr) != 0) {
        LOGE("pthread_create failed");
        g_running.store(0);
        dedective::global_engine().stop();
        rtlsdr_close(g_dev);
        g_dev = nullptr;
        return 0;
    }

    return 1;
}

/// Stop the decoder thread and close the RTL-SDR device.
void dect_stop(void) {
    if (!g_running.load()) return;

    g_running.store(0);
    dedective::global_engine().stop();

    // Interrupt any blocked rtlsdr_read_sync call.
    if (g_dev) rtlsdr_reset_buffer(g_dev);

    if (g_thread) {
        pthread_join(g_thread, nullptr);
        g_thread = 0;
    }

    if (g_dev) {
        rtlsdr_close(g_dev);
        g_dev = nullptr;
    }

    LOGI("dect_stop: done");
}

/// Fill *out with current status.
void dect_get_status(DectStatus* out) {
    if (!out) return;
    dedective::DedectiveAndroidStatus s{};
    dedective::global_engine().get_status(s);
    out->running       = s.running ? s.mode : 0;
    out->band          = s.band;
    out->tuned_channel = s.tuned_channel;
    out->tuned_freq_hz = s.tuned_freq_hz;
    out->voice_present = s.voice_present;
    out->part_count    = s.part_count;
    out->packets_seen  = s.packets_seen;
}

/// Fill out[0..max_count-1] with active part information.
/// @return Number of entries written.
int dect_get_parts(DectPart* out, int max_count) {
    if (!out || max_count <= 0) return 0;
    static_assert(sizeof(DectPart) == sizeof(dedective::DedectiveAndroidPart),
                  "DectPart / DedectiveAndroidPart size mismatch");
    return dedective::global_engine().get_parts(
        reinterpret_cast<dedective::DedectiveAndroidPart*>(out), max_count);
}

/// Start DECT engine in push mode (HackRF path — no RTL-SDR opened).
/// Caller feeds IQ via dect_push_iq_s8(). band: 0=US, 1=EU.
/// Returns 1 on success, 0 if already running.
int dect_start_push(int band) {
    if (g_running.load()) {
        LOGE("dect_start_push: already running");
        return 0;
    }
    dedective::global_engine().set_band(
        band == 1 ? dedective::DectBand::EU : dedective::DectBand::US);
    dedective::global_engine().start();
    g_running.store(1);
    // No capture thread — caller pushes IQ directly.
    LOGI("dect_start_push: push mode active band=%s", band == 1 ? "EU" : "US");
    return 1;
}

/// Push a chunk of signed IQ bytes (HackRF format: int8_t interleaved I/Q).
/// HackRF delivers uint8 (0–255 centered at 127); caller must subtract 127.
/// This function accepts already-shifted int8_t samples.
void dect_push_iq_s8(const int8_t* data, int len) {
    if (!data || len < 2 || !g_running.load()) return;
    dedective::global_engine().push_iq_bytes(data, static_cast<size_t>(len));
}

/// Check if the engine wants a frequency/rate change (for HackRF retuning).
/// Returns 1 if a request is pending (fills *freq_hz and *sample_rate), 0 otherwise.
int dect_consume_retune(uint64_t* freq_hz, uint32_t* sample_rate) {
    if (!freq_hz || !sample_rate) return 0;
    dedective::DedectiveAndroidRetuneRequest req{};
    if (!dedective::global_engine().consume_retune_request(req)) return 0;
    *freq_hz     = req.freq_hz;
    *sample_rate = req.sample_rate;
    return 1;
}

/// Read decoded G.721 PCM audio (8 kHz, 16-bit mono) from the engine's ring buffer.
/// @param out        Output buffer of int16_t samples.
/// @param max_samples Maximum samples to read.
/// @return Number of samples written (0 if buffer empty).
int dect_read_audio(int16_t* out, int max_samples) {
    return dedective::global_engine().read_audio(out, max_samples);
}

} // extern "C"

// ── JNI entry point for Kotlin AudioTrack player ──────────────────────────────
#include <jni.h>

extern "C"
JNIEXPORT jint JNICALL
Java_com_rfstudio_rfstudio_DectAudioPlayer_nativeReadAudio(
        JNIEnv* env, jclass, jshortArray outArray, jint maxSamples) {
    if (!outArray || maxSamples <= 0) return 0;
    jshort* shorts = env->GetShortArrayElements(outArray, nullptr);
    const int count = dedective::global_engine().read_audio(
        reinterpret_cast<int16_t*>(shorts), static_cast<int>(maxSamples));
    env->ReleaseShortArrayElements(outArray, shorts, 0);
    return count;
}
