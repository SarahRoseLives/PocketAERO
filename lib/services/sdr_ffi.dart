// lib/services/sdr_ffi.dart
//
// Dart FFI bindings for librf_studio_sdr.so
//
// C API:
//   int32_t rf_open  (int32_t fd, const char *path, int32_t fft_size)
//   void    rf_set_frequency   (uint32_t hz)
//   void    rf_set_sample_rate (uint32_t sps)
//   void    rf_set_gain        (int32_t tenths_db)   // -1 = auto
//   int32_t rf_start (void)
//   int64_t rf_poll_fft (float *out_db, int32_t n)
//   float   rf_get_signal_db (void)
//   void    rf_stop  (void)
//   void    rf_close (void)

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// ── Native type aliases ────────────────────────────────────────────────────

typedef _RfOpenN = Int32 Function(Int32 fd, Pointer<Utf8> path, Int32 fftSize);
typedef _RfOpenD = int   Function(int  fd, Pointer<Utf8> path, int  fftSize);

typedef _RfSetFreqN = Void     Function(Uint32 hz);
typedef _RfSetFreqD = void     Function(int hz);

typedef _RfSetSrN   = Void     Function(Uint32 sps);
typedef _RfSetSrD   = void     Function(int sps);

typedef _RfSetGainN    = Void     Function(Int32 tenths);
typedef _RfSetGainD    = void     Function(int tenths);
typedef _RfSetBiasTeeN = Void     Function(Int32 on);
typedef _RfSetBiasTeeD = void     Function(int on);

typedef _RfStartN   = Int32    Function();
typedef _RfStartD   = int      Function();

typedef _RfPollN    = Int64    Function(Pointer<Float> outDb, Int32 n);
typedef _RfPollD    = int      Function(Pointer<Float> outDb, int  n);

typedef _RfSigDbN   = Float    Function();
typedef _RfSigDbD   = double   Function();

typedef _RfStopN    = Void     Function();
typedef _RfStopD    = void     Function();

typedef _RfCloseN   = Void     Function();
typedef _RfCloseD   = void     Function();

typedef _RfDupFdN   = Int32    Function();
typedef _RfDupFdD   = int      Function();

typedef _RfStartWfmN  = Int32  Function(Int32 mode);
typedef _RfStartWfmD  = int    Function(int mode);

typedef _RfStopWfmN   = Void   Function();
typedef _RfStopWfmD   = void   Function();

typedef _RfIsWfmRunN  = Int32  Function();
typedef _RfIsWfmRunD  = int    Function();

// ── AERO ACARS decoder FFI types ───────────────────────────────────────────

typedef _RfStartAeroN  = Int32  Function();
typedef _RfStartAeroD  = int    Function();

typedef _RfStopAeroN   = Int32  Function();
typedef _RfStopAeroD   = int    Function();

typedef _RfPollAeroN   = Int32  Function(Pointer<Uint8> out, Int32 maxlen);
typedef _RfPollAeroD   = int    Function(Pointer<Uint8> out, int    maxlen);

typedef _RfAeroMseN    = Float  Function();
typedef _RfAeroMseD    = double Function();

typedef _RfAeroFreqN   = Float  Function();
typedef _RfAeroFreqD   = double Function();

typedef _RfAeroEbNoN   = Float  Function();
typedef _RfAeroEbNoD   = double Function();

typedef _RfAeroConstN  = Int32  Function(Pointer<Double> iq, Int32 max_points);
typedef _RfAeroConstD  = int    Function(Pointer<Double> iq, int max_points);

typedef _RfLoadWavN    = Int32  Function(Pointer<Utf8> path);
typedef _RfLoadWavD    = int    Function(Pointer<Utf8> path);

typedef _RfSetAeroFeedModeN = Void Function(Int32 mode);
typedef _RfSetAeroFeedModeD = void Function(int mode);

typedef _RfSetAeroOffsetN = Void Function(Double hz);
typedef _RfSetAeroOffsetD = void Function(double hz);

typedef _RfSetAeroBoxcarN = Void Function(Int32 mode);
typedef _RfSetAeroBoxcarD = void Function(int mode);

typedef _RfSetAeroSymRateN = Void Function(Double rate);
typedef _RfSetAeroSymRateD = void Function(double rate);

typedef _RfStartAeroRecN = Int32 Function(Pointer<Utf8> path);
typedef _RfStartAeroRecD = int Function(Pointer<Utf8> path);

typedef _RfStopAeroRecN  = Int32 Function();
typedef _RfStopAeroRecD  = int Function();

typedef _RfStartAeroRecRawN = Int32 Function(Pointer<Utf8> path);
typedef _RfStartAeroRecRawD = int Function(Pointer<Utf8> path);

typedef _RfStopAeroRecRawN  = Int32 Function();
typedef _RfStopAeroRecRawD  = int Function();

typedef _RfGetSampleRateN = Uint32 Function();
typedef _RfGetSampleRateD = int    Function();

// ── Signal generator FFI types ────────────────────────────────────────────

typedef _RfSiggenInitN        = Void Function();
typedef _RfSiggenInitD        = void Function();

typedef _RfSiggenStartCwN     = Void   Function(Double freqOffHz, Double sr, Double amp);
typedef _RfSiggenStartCwD     = void   Function(double freqOffHz, double sr, double amp);

typedef _RfSiggenStartFmN     = Void   Function(Double audioHz, Double devHz, Double sr, Double amp);
typedef _RfSiggenStartFmD     = void   Function(double audioHz, double devHz, double sr, double amp);

typedef _RfSiggenStartSweepN  = Void   Function(Double startHz, Double stopHz,
                                                  Double rateHzPerSec, Double sr, Double amp);
typedef _RfSiggenStartSweepD  = void   Function(double startHz, double stopHz,
                                                  double rateHzPerSec, double sr, double amp);

typedef _RfSiggenCfgC4fmN     = Void   Function(Uint32 nac, Uint32 wacn, Uint32 sysid,
                                                  Uint32 rfss, Uint32 site,
                                                  Uint32 chanId, Uint32 chanNum,
                                                  Uint32 baseFreq5hz, Int32 simulate);
typedef _RfSiggenCfgC4fmD     = void   Function(int nac, int wacn, int sysid,
                                                  int rfss, int site,
                                                  int chanId, int chanNum,
                                                  int baseFreq5hz, int simulate);

typedef _RfSiggenStartC4fmN   = Void   Function();
typedef _RfSiggenStartC4fmD   = void   Function();

typedef _RfSiggenStopN        = Void   Function();
typedef _RfSiggenStopD        = void   Function();

typedef _RfSiggenFillN        = Int32  Function(Pointer<Uint8> buf, Int32 n);
typedef _RfSiggenFillD        = int    Function(Pointer<Uint8> buf, int n);

typedef _RfSiggenModeN        = Int32  Function();
typedef _RfSiggenModeD        = int    Function();

// ── SdrFfi ─────────────────────────────────────────────────────────────────

/// Low-level FFI bindings. Use [SdrFfi.instance] to obtain the singleton.
class SdrFfi {
  SdrFfi._();
  static final SdrFfi instance = SdrFfi._();

  static final DynamicLibrary _lib = Platform.isAndroid
      ? DynamicLibrary.open('librf_studio_sdr.so')
      : DynamicLibrary.process();

  late final _rfOpen  = _lib.lookupFunction<_RfOpenN,    _RfOpenD>   ('rf_open');
  late final _rfSetF      = _lib.lookupFunction<_RfSetFreqN,    _RfSetFreqD>   ('rf_set_frequency');
  late final _rfSetSr     = _lib.lookupFunction<_RfSetSrN,      _RfSetSrD>     ('rf_set_sample_rate');
  late final _rfSetG      = _lib.lookupFunction<_RfSetGainN,    _RfSetGainD>   ('rf_set_gain');
  late final _rfSetBiasT  = _lib.lookupFunction<_RfSetBiasTeeN, _RfSetBiasTeeD>('rf_set_bias_tee');
  late final _rfStart = _lib.lookupFunction<_RfStartN,   _RfStartD>  ('rf_start');
  late final _rfPoll  = _lib.lookupFunction<_RfPollN,    _RfPollD>   ('rf_poll_fft');
  late final _rfSigDb = _lib.lookupFunction<_RfSigDbN,   _RfSigDbD>  ('rf_get_signal_db');
  late final _rfStop  = _lib.lookupFunction<_RfStopN,    _RfStopD>   ('rf_stop');
  late final _rfClose = _lib.lookupFunction<_RfCloseN,   _RfCloseD>  ('rf_close');
  late final _rfDupFd     = _lib.lookupFunction<_RfDupFdN,     _RfDupFdD>    ('rf_dup_usb_fd');
  late final _rfStartWfm  = _lib.lookupFunction<_RfStartWfmN,  _RfStartWfmD> ('rf_start_wfm');
  late final _rfStopWfm   = _lib.lookupFunction<_RfStopWfmN,   _RfStopWfmD>  ('rf_stop_wfm');
  late final _rfIsWfmRun  = _lib.lookupFunction<_RfIsWfmRunN,  _RfIsWfmRunD> ('rf_is_wfm_running');

  // AERO ACARS decoder
  late final _rfStartAero = _lib.lookupFunction<_RfStartAeroN, _RfStartAeroD>('rf_start_aero');
  late final _rfStopAero  = _lib.lookupFunction<_RfStopAeroN,  _RfStopAeroD> ('rf_stop_aero');
  late final _rfPollAero  = _lib.lookupFunction<_RfPollAeroN,  _RfPollAeroD> ('rf_poll_aero');
  late final _rfAeroMse   = _lib.lookupFunction<_RfAeroMseN,   _RfAeroMseD>  ('rf_get_aero_mse');
  late final _rfAeroFreq  = _lib.lookupFunction<_RfAeroFreqN,  _RfAeroFreqD> ('rf_get_aero_freq');
  late final _rfAeroEbNo  = _lib.lookupFunction<_RfAeroEbNoN,  _RfAeroEbNoD> ('rf_get_aero_ebno');
  late final _rfAeroConst = _lib.lookupFunction<_RfAeroConstN, _RfAeroConstD>('rf_get_aero_constellation');
  late final _rfLoadWav   = _lib.lookupFunction<_RfLoadWavN,   _RfLoadWavD>  ('rf_load_wav_aero');
  late final _rfSetAeroOffset = _lib.lookupFunction<_RfSetAeroOffsetN, _RfSetAeroOffsetD>('rf_set_aero_offset');
  late final _rfSetAeroBoxcar = _lib.lookupFunction<_RfSetAeroBoxcarN, _RfSetAeroBoxcarD>('rf_set_aero_boxcar_mode');
  late final _rfSetAeroSymRate = _lib.lookupFunction<_RfSetAeroSymRateN, _RfSetAeroSymRateD>('rf_set_aero_symbol_rate');
  late final _rfSetAeroFeedMode = _lib.lookupFunction<_RfSetAeroFeedModeN, _RfSetAeroFeedModeD>('rf_set_aero_feed_mode');
  late final _rfStartAeroRec = _lib.lookupFunction<_RfStartAeroRecN, _RfStartAeroRecD>('rf_start_aero_recording');
  late final _rfStopAeroRec  = _lib.lookupFunction<_RfStopAeroRecN,  _RfStopAeroRecD> ('rf_stop_aero_recording');
  late final _rfStartAeroRecRaw = _lib.lookupFunction<_RfStartAeroRecRawN, _RfStartAeroRecRawD>('rf_start_aero_recording_raw');
  late final _rfStopAeroRecRaw  = _lib.lookupFunction<_RfStopAeroRecRawN,  _RfStopAeroRecRawD> ('rf_stop_aero_recording_raw');
  late final _rfGetSampleRate    = _lib.lookupFunction<_RfGetSampleRateN,   _RfGetSampleRateD>  ('rf_get_sample_rate');

  // Signal generator
  late final _rfSgInit       = _lib.lookupFunction<_RfSiggenInitN,       _RfSiggenInitD>      ('rf_siggen_init');
  late final _rfSgStartCw    = _lib.lookupFunction<_RfSiggenStartCwN,    _RfSiggenStartCwD>   ('rf_siggen_start_cw');
  late final _rfSgStartFm    = _lib.lookupFunction<_RfSiggenStartFmN,    _RfSiggenStartFmD>   ('rf_siggen_start_fm');
  late final _rfSgStartSweep = _lib.lookupFunction<_RfSiggenStartSweepN, _RfSiggenStartSweepD>('rf_siggen_start_sweep');
  late final _rfSgCfgC4fm    = _lib.lookupFunction<_RfSiggenCfgC4fmN,    _RfSiggenCfgC4fmD>  ('rf_siggen_configure_c4fm');
  late final _rfSgStartC4fm  = _lib.lookupFunction<_RfSiggenStartC4fmN,  _RfSiggenStartC4fmD>('rf_siggen_start_c4fm');
  late final _rfSgStop       = _lib.lookupFunction<_RfSiggenStopN,       _RfSiggenStopD>      ('rf_siggen_stop');
  late final _rfSgFill       = _lib.lookupFunction<_RfSiggenFillN,       _RfSiggenFillD>      ('rf_siggen_fill');
  late final _rfSgMode       = _lib.lookupFunction<_RfSiggenModeN,       _RfSiggenModeD>      ('rf_siggen_mode');

  // Persistent native buffer for FFT polling
  Pointer<Float>? _fftBuf;
  int _fftSize = 0;

  final _spectrumCtrl = StreamController<Float32List>.broadcast();

  /// Live spectrum frames (Float32List of [fftSize] dBFS values, DC-centred).
  Stream<Float32List> get spectrumStream => _spectrumCtrl.stream;

  Timer? _pollTimer;
  int    _lastFrame = -1;

  /// Open RTL-SDR device.
  /// [fd] = file descriptor from Kotlin UsbManager.openDevice()
  /// [path] = USB device path (e.g. /dev/bus/usb/001/002)
  /// [fftSize] = power-of-2 FFT size (default 2048)
  int open(int fd, String path, {int fftSize = 2048}) {
    _fftSize = fftSize;
    _fftBuf?.realloc(_fftSize);
    _fftBuf ??= calloc<Float>(_fftSize);

    final pathPtr = path.toNativeUtf8();
    final result  = _rfOpen(fd, pathPtr, fftSize);
    calloc.free(pathPtr);
    return result;
  }

  void setFrequency(int hz)      => _rfSetF(hz);
  void setSampleRate(int sps)    => _rfSetSr(sps);
  int  getSampleRate()           => _rfGetSampleRate();
  void setBiasTee(bool on)       => _rfSetBiasT(on ? 1 : 0);
  /// [tenthsDb] < 0 for auto gain
  void setGain(int tenthsDb)     => _rfSetG(tenthsDb);

  /// Start reading + FFT. Begins emitting on [spectrumStream].
  int start() {
    final r = _rfStart();
    if (r == 0) _startPoller();
    return r;
  }

  double getSignalDb() => _rfSigDb();

  void stop() {
    _stopPoller();
    _rfStop();
    _lastFrame = -1;
  }

  void close() {
    _stopPoller();
    _rfClose();
    _fftBuf?.let((b) { calloc.free(b); _fftBuf = null; });
    _lastFrame = -1;
  }

  /// Duplicate the Android USB fd before closing the device.
  int dupUsbFd() => _rfDupFd();

  /// Start WFM (mode=0) or NFM (mode=1) demodulation + audio ring buffer.
  int startWfm({int mode = 0}) => _rfStartWfm(mode);

  /// Stop WFM demodulation.
  void stopWfm() => _rfStopWfm();

  bool get isWfmRunning => _rfIsWfmRun() != 0;

  // ── Signal generator wrappers ─────────────────────────────────────────────

  void siggenInit() => _rfSgInit();

  void siggenStartCw({required double freqOffsetHz,
                       double sampleRate = 2400000, double amplitude = 100}) =>
      _rfSgStartCw(freqOffsetHz, sampleRate, amplitude);

  void siggenStartFm({required double audioHz, required double deviationHz,
                       double sampleRate = 2400000, double amplitude = 100}) =>
      _rfSgStartFm(audioHz, deviationHz, sampleRate, amplitude);

  void siggenStartSweep({required double startHz, required double stopHz,
                          required double rateHzPerSec,
                          double sampleRate = 2400000, double amplitude = 100}) =>
      _rfSgStartSweep(startHz, stopHz, rateHzPerSec, sampleRate, amplitude);

  void siggenConfigureC4fm({required int nac, required int wacn, required int sysid,
                             required int rfss, required int site,
                             required int chanId, required int chanNum,
                             required int baseFreq5hz, bool simulate = false}) =>
      _rfSgCfgC4fm(nac, wacn, sysid, rfss, site, chanId, chanNum,
                   baseFreq5hz, simulate ? 1 : 0);

  void siggenStartC4fm() => _rfSgStartC4fm();

  void siggenStop() => _rfSgStop();

  int siggenMode() => _rfSgMode();

  // ── AERO ACARS ─────────────────────────────────────────────────────────

  int startAero()          => _rfStartAero();
  int stopAero()           => _rfStopAero();
  int pollAero(Pointer<Uint8> out, int maxlen) => _rfPollAero(out, maxlen);
  double getAeroMse()      => _rfAeroMse();
  double getAeroFreq()     => _rfAeroFreq();
  double getAeroEbNo()     => _rfAeroEbNo();
  int getAeroConstellation(Pointer<Double> iq, int maxPoints) =>
      _rfAeroConst(iq, maxPoints);
  int loadWavAero(Pointer<Utf8> path) => _rfLoadWav(path);
  void setAeroFeedIqMode(bool on) => _rfSetAeroFeedMode(on ? 1 : 0);
  void setAeroOffset(double hz) => _rfSetAeroOffset(hz);
  void setAeroBoxcarMode(bool on) => _rfSetAeroBoxcar(on ? 1 : 0);
  void setAeroSymbolRate(double rate) => _rfSetAeroSymRate(rate);
  int startAeroRecording(Pointer<Utf8> path) => _rfStartAeroRec(path);
  int stopAeroRecording()  => _rfStopAeroRec();
  int startAeroRecordingRaw(Pointer<Utf8> path) => _rfStartAeroRecRaw(path);
  int stopAeroRecordingRaw()  => _rfStopAeroRecRaw();

  /// Fills [n] bytes of IQ data into [buf] (caller-allocated).
  int siggenFill(Pointer<Uint8> buf, int n) => _rfSgFill(buf, n);

  void dispose() {
    close();
    _spectrumCtrl.close();
  }

  // ── Polling timer ─────────────────────────────────────────────────────────

  void _startPoller() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => _poll());
  }

  void _stopPoller() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _poll() {
    final buf = _fftBuf;
    if (buf == null || _spectrumCtrl.isClosed) return;
    final frame = _rfPoll(buf, _fftSize);
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    // Copy native float array → Dart Float32List
    final out = Float32List(_fftSize);
    for (int i = 0; i < _fftSize; i++) { out[i] = buf[i]; }
    _spectrumCtrl.add(out);
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) block) => block(this);
}

extension _ReallocPointer on Pointer<Float> {
  // No-op helper used for clarity; actual realloc would need dart:ffi malloc
  void realloc(int n) {}
}
