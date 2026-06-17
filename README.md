# PocketAERO

Inmarsat AERO satellite decoder for Android tablets and phones.

Decode live Inmarsat AERO signals using an RTL-SDR dongle via USB OTG.

## Download
- https://sarahsforge.dev/products/pocketaero

## Features

- **10500 bps ACARS text** — flight IDs, positions, weather reports, CPDLC messages
- **8400 bps C-channel** — call progress tracking, AMBE voice decoding with AAudio output
- **1200 / 600 bps P-channel** — system tables, logon/logoff events, T/C-channel assignments, voice-follow
- **MSK and OQPSK demodulation** — ported JAERO DSP pipeline
- **Full waterfall spectrum** — 4096-bin FFT with drag-to-tune, zoom, and color schemes (viridis / turbo / grayscale)
- **Constellation plot** — live IQ scatter plot from the active demodulator
- **WAV IQ recording** — save raw or decimated IQ for offline analysis
- **Dark / light theme** — OLED-friendly dark mode
- **USB wake lock** — screen stays on during monitoring
- **Version check** — automatic update notification on startup
- **Bias tee** — software toggle for powered LNAs/filters

## Screenshots

![Screenshot](screenshot.gif)

## Requirements

- Android 8.0+ (API 26+)
- RTL-SDR dongle (RTL2832U) via USB OTG
- ARM64 (aarch64) tablet or phone

## Build

```bash
cd PocketAERO
flutter pub get
flutter build apk --release
```

## Hardware Setup

1. Plug RTL-SDR dongle into tablet via USB OTG adapter
2. Connect antenna tuned for L-band (1525–1559 MHz)
3. Launch PocketAERO
4. Tap CONNECT, grant USB permission
5. Select baud rate (600/1200 for P-channel, 10500 for ACARS, 8400 for voice)
6. Tap DECODE ON


## Credits

PocketAERO builds on the work of:

- **[JAERO](https://github.com/jontio/JAERO)** by Jonathan Olds — the original AERO demodulator and AeroL frame decoder
- **[inmarsat-sniffer](https://github.com/alphafox02/inmarsat-sniffer)** — thin C wrapper providing the jaero_dsp port used in this project
- **[librtlsdr](https://github.com/steve-m/librtlsdr)** — RTL-SDR driver library
- **[mbelib](https://github.com/szechyjs/mbelib)** — AMBE vocoder for voice decoding
- **[libaeroambe](https://github.com/jontio/libaeroambe)** — AERO-specific AMBE deinterleave tables (rW/rX)

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE)
