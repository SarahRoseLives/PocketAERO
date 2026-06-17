#pragma once
// Minimal stub for audio_output.h — no PulseAudio on this build target.
// The wideband_monitor.h header references AudioOutput*, but the structs we
// use (WidebandSnapshot, WidebandChannelView) do not require a full definition.
#include <atomic>
#include <cstdint>
#include <cstddef>

namespace dedective {

class AudioOutput {
public:
    AudioOutput() = default;
    ~AudioOutput() = default;

    bool start() { return false; }
    void stop() {}
    void write_samples(const int16_t* /*samples*/, size_t /*count*/) {}
    void set_muted(bool /*m*/) {}
    bool is_muted()   const { return true; }
    void set_volume(float /*v*/) {}
    float volume()    const { return 0.0f; }
    bool is_running() const { return false; }
};

} // namespace dedective
