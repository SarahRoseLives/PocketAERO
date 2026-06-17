#pragma once
#include <cstdint>
#include <array>
#include <string>

namespace dedective {

// DECT symbol rate (GFSK, 1.152 Mbps)
inline constexpr uint32_t DECT_SYMBOL_RATE   = 1'152'000;

// We sample at exactly 4× the symbol rate so every 4 IQ samples = 1 bit.
// No fractional resampler needed.
inline constexpr uint32_t SAMPLE_RATE        = 4 * DECT_SYMBOL_RATE; // 4,608,000 Hz

// DECT channel spacing (1.728 MHz per channel)
inline constexpr double   DECT_CHAN_SPACING  = 1'728'000.0;

// Both US and EU bands have exactly 10 channels.
inline constexpr size_t   NUM_DECT_CHANNELS  = 10;

struct DectChannel {
    int         number;
    uint64_t    freq_hz;
    const char *label;
};

// US DECT 6.0 — FCC Part 15, Subpart D
// Ten channels, 1.728 MHz spacing, 1921.536–1937.088 MHz
inline constexpr std::array<DectChannel, NUM_DECT_CHANNELS> US_DECT_CHANNELS = {{
    { 0,  1'921'536'000ULL, "US-0  1921.536 MHz" },
    { 1,  1'923'264'000ULL, "US-1  1923.264 MHz" },
    { 2,  1'924'992'000ULL, "US-2  1924.992 MHz" },
    { 3,  1'926'720'000ULL, "US-3  1926.720 MHz" },
    { 4,  1'928'448'000ULL, "US-4  1928.448 MHz" },
    { 5,  1'930'176'000ULL, "US-5  1930.176 MHz" },
    { 6,  1'931'904'000ULL, "US-6  1931.904 MHz" },
    { 7,  1'933'632'000ULL, "US-7  1933.632 MHz" },
    { 8,  1'935'360'000ULL, "US-8  1935.360 MHz" },
    { 9,  1'937'088'000ULL, "US-9  1937.088 MHz" },
}};

// EU DECT — ETSI EN 300 175
// Ten channels, 1.728 MHz spacing, 1881.792–1897.344 MHz
// f = 1897.344 − n × 1.728 MHz  (n = 0..9)
inline constexpr std::array<DectChannel, NUM_DECT_CHANNELS> EU_DECT_CHANNELS = {{
    { 0,  1'897'344'000ULL, "EU-0  1897.344 MHz" },
    { 1,  1'895'616'000ULL, "EU-1  1895.616 MHz" },
    { 2,  1'893'888'000ULL, "EU-2  1893.888 MHz" },
    { 3,  1'892'160'000ULL, "EU-3  1892.160 MHz" },
    { 4,  1'890'432'000ULL, "EU-4  1890.432 MHz" },
    { 5,  1'888'704'000ULL, "EU-5  1888.704 MHz" },
    { 6,  1'886'976'000ULL, "EU-6  1886.976 MHz" },
    { 7,  1'885'248'000ULL, "EU-7  1885.248 MHz" },
    { 8,  1'883'520'000ULL, "EU-8  1883.520 MHz" },
    { 9,  1'881'792'000ULL, "EU-9  1881.792 MHz" },
}};

enum class DectBand { US, EU };

inline constexpr const char* dect_band_names[] = { "US Band (1920 MHz)", "EU Band (1880 MHz)" };

inline const std::array<DectChannel, NUM_DECT_CHANNELS>& dect_channels(DectBand band) {
    return band == DectBand::US ? US_DECT_CHANNELS : EU_DECT_CHANNELS;
}

inline uint64_t dect_center_freq(DectBand band) {
    const auto& ch = dect_channels(band);
    return (ch.front().freq_hz + ch.back().freq_hz) / 2;
}

} // namespace dedective
