import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/rf_mode.dart';
import '../models/sdr_type.dart';
import '../models/sweep_settings.dart';
import '../models/waterfall_settings.dart';
import '../services/sdr_backend.dart';
import '../services/sdr_service.dart' show SdrState, SdrDeviceInfo, SdrService;

enum RadioState { idle, receiving, transmitting }

enum ConnectionStatus { disconnected, connecting, connected, error }

class RadioProvider extends ChangeNotifier {
  SdrBackend? _backend;

  RadioProvider();

  void attachBackend(SdrBackend backend) {
    _backend?.removeListener(_onSdrUpdate);
    _backend = backend;
    _backend?.addListener(_onSdrUpdate);
    // Auto-correct sample rate to a valid value for this SDR type
    _coerceSampleRate(backend.connectedType);
    notifyListeners();
  }

  void _coerceSampleRate(SdrType? type) {
    final validRates = type == SdrType.hackRf
        ? WaterfallSettings.sampleRatesHackRf
        : WaterfallSettings.sampleRatesRtl;
    if (!validRates.contains(_wfSettings.sampleRateHz)) {
      _wfSettings = _wfSettings.copyWith(sampleRateHz: validRates.first);
    }
  }

  RadioState _radioState = RadioState.idle;
  RfMode _selectedMode   = RfMode.builtInModes.first;
  double _frequencyHz    = 1545000000;
  double _rxVolume       = 0.75;
  double _txPower        = 0.5;
  double _squelch        = 0.2;
  double _txMeterLevel   = 0.0;
  bool   _muteRx         = false;
  WaterfallSettings _wfSettings = const WaterfallSettings();

  // ── Sweep state ───────────────────────────────────────────────────────────
  SweepSettings _sweepSettings  = const SweepSettings();
  bool          _isSweeping     = false;
  int           _currentHop     = 0;
  Float32List?  _stitchedSpectrum;
  Float32List?  _peakHoldSpectrum;

  final List<RfMode> _customModes = [];

  // ── Getters ───────────────────────────────────────────────────────────────

  RadioState get radioState        => _radioState;
  RfMode     get selectedMode      => _selectedMode;
  double     get frequencyHz       => _frequencyHz;
  double     get rxVolume          => _rxVolume;
  double     get txPower           => _txPower;
  double     get squelch           => _squelch;
  double     get txMeterLevel      => _txMeterLevel;
  bool       get muteRx            => _muteRx;
  bool       get isTransmitting    => _radioState == RadioState.transmitting;
  bool       get isReceiving       => _radioState == RadioState.receiving;

  List<RfMode> get allModes => [...RfMode.builtInModes, ..._customModes];
  WaterfallSettings get wfSettings => _wfSettings;

  // Sweep getters
  SweepSettings get sweepSettings    => _sweepSettings;
  bool          get isSweeping       => _isSweeping;
  int           get currentHop       => _currentHop;
  Float32List?  get stitchedSpectrum => _stitchedSpectrum;
  Float32List?  get peakHoldSpectrum => _peakHoldSpectrum;

  /// Maps SdrBackend state to legacy ConnectionStatus for UI compatibility.
  ConnectionStatus get connectionStatus => switch (_backend?.state ?? SdrState.disconnected) {
    SdrState.disconnected => ConnectionStatus.disconnected,
    SdrState.connecting   => ConnectionStatus.connecting,
    SdrState.running      => ConnectionStatus.connected,
    SdrState.error        => ConnectionStatus.error,
  };

  /// The type of SDR currently connected, or null if disconnected.
  SdrType? get connectedSdrType => _backend?.connectedType;

  /// Direct access to the underlying SDR backend.
  SdrBackend? get backend => _backend;

  /// Device query string for rtl433_ffi_start (RTL-SDR only).
  /// Returns empty string if not connected or wrong backend type.
  String get usbDevQuery =>
      (_backend is SdrService) ? (_backend as SdrService).usbDevQuery : '';

  /// Signal strength 0.0–1.0 (derived from dBFS: –120 dB = 0, –20 dB = 1).
  double get signalStrength {
    if (_backend?.state != SdrState.running) return 0.0;
    return ((_backend!.signalDb + 120.0) / 100.0).clamp(0.0, 1.0);
  }

  String? get sdrError => _backend?.error;

  List<SdrDeviceInfo> get sdrDevices => _backend?.devices ?? [];

  // ── SdrService listener ───────────────────────────────────────────────────

  void _onSdrUpdate() {
    RadioState newState = _radioState;
    if (_backend?.state == SdrState.running) {
      newState = RadioState.receiving;
      // Coerce sample rate to match connected SDR when it first goes running
      _coerceSampleRate(_backend?.connectedType);
    } else if (_backend?.state == SdrState.disconnected) {
      newState = RadioState.idle;
    }
    if (newState != _radioState) {
      _radioState = newState;
      notifyListeners();
    }
  }

  // ── USB / Connection ──────────────────────────────────────────────────────

  Future<void> scanDevices() => _backend?.scanDevices() ?? Future.value();

  Future<void> connectToDevice(SdrDeviceInfo device) =>
      _backend?.connect(device, fftSize: _wfSettings.fftSize.bins) ?? Future.value();

  Future<void> toggleConnection() async {
    final state = _backend?.state ?? SdrState.disconnected;
    switch (state) {
      case SdrState.disconnected:
      case SdrState.error:
        await _backend?.scanDevices();
        final devices = _backend?.devices ?? [];
        if (devices.isNotEmpty) {
          await _backend?.connect(devices.first, fftSize: _wfSettings.fftSize.bins);
        }
      case SdrState.running:
        await _backend?.disconnect();
      case SdrState.connecting:
        break;
    }
  }

  // ── Frequency ─────────────────────────────────────────────────────────────

  void setFrequency(double hz) {
    _frequencyHz = hz.clamp(100_000, 6_000_000_000);
    debugPrint('SET_FREQ: ${_frequencyHz.toInt()} Hz (${(_frequencyHz / 1e6).toStringAsFixed(4)} MHz)');
    _backend?.setFrequency(_frequencyHz.toInt());
    notifyListeners();
  }

  void stepFrequency(double stepHz) => setFrequency(_frequencyHz + stepHz);

  // ── Mode ──────────────────────────────────────────────────────────────────

  void selectMode(RfMode mode) {
    _selectedMode = mode;
    notifyListeners();
  }

  void addCustomMode(RfMode mode) {
    _customModes.add(mode);
    notifyListeners();
  }

  void removeCustomMode(String id) {
    _customModes.removeWhere((m) => m.id == id);
    if (_selectedMode.id == id) _selectedMode = RfMode.builtInModes.first;
    notifyListeners();
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  void setRxVolume(double v) { _rxVolume = v.clamp(0.0, 1.0); notifyListeners(); }
  void setTxPower(double v)  { _txPower  = v.clamp(0.0, 1.0); notifyListeners(); }
  void setSquelch(double v)  { _squelch  = v.clamp(0.0, 1.0); notifyListeners(); }
  void toggleMuteRx()        { _muteRx   = !_muteRx;          notifyListeners(); }

  void startTransmit() {
    if (!_selectedMode.supportsTransmit) return;
    _radioState   = RadioState.transmitting;
    _txMeterLevel = _txPower;
    notifyListeners();
  }

  void stopTransmit() {
    _radioState   = RadioState.idle;
    _txMeterLevel = 0.0;
    notifyListeners();
  }

  // ── Waterfall settings ────────────────────────────────────────────────────

  void updateWaterfallSettings(WaterfallSettings s) {
    final prev = _wfSettings;
    _wfSettings = s;
    if (_backend?.isRunning ?? false) {
      if (s.sampleRateHz != prev.sampleRateHz) _backend?.setSampleRate(s.sampleRateHz);
      if (s.gainTenths   != prev.gainTenths)   _backend?.setGain(s.gainTenths);
    }
    notifyListeners();
  }

  // ── Sweep control ─────────────────────────────────────────────────────────

  void updateSweepSettings(SweepSettings s) {
    _sweepSettings = s;
    notifyListeners();
  }

  Future<void> startSweep() async {
    if (_isSweeping) return;
    _isSweeping = true;
    _currentHop = 0;
    notifyListeners();
    _runSweepLoop();
  }

  void stopSweep() {
    _isSweeping = false;
    _currentHop = 0;
    notifyListeners();
  }

  void clearPeakHold() {
    _peakHoldSpectrum = null;
    notifyListeners();
  }

  Future<void> _runSweepLoop() async {
    if (_backend == null) {
      _isSweeping = false;
      notifyListeners();
      return;
    }
    // Apply sample rate matching RBW and gain for the sweep.
    // For HackRF, skip setSampleRate here — changing SR mid-stream interrupts
    // the USB transfer job. HackRF uses whatever rate was set at connect time.
    final initSettings = _sweepSettings;
    if (connectedSdrType != SdrType.hackRf) {
      _backend?.setSampleRate(initSettings.rbwHz.toInt());
    }
    _backend?.setGain(initSettings.gainTenths == 0 ? -1 : initSettings.gainTenths);

    while (_isSweeping) {
      final settings  = _sweepSettings;
      final hops      = settings.hopCenters;
      final fftSize   = _wfSettings.fftSize.bins;
      final binHz     = settings.rbwHz / fftSize;

      // Output spans startHz..stopHz at binHz resolution (independent of
      // hop count / overlap factor).
      final totalBins = ((settings.stopHz - settings.startHz) / binHz).ceil() + 1;

      // Hann window: weight = 1 at center, ≈0 at edges — naturally suppresses
      // the rolled-off edge bins of each RTL-SDR hop.
      final hann = List<double>.generate(
        fftSize,
        (i) => 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (fftSize - 1))),
      );

      final outAccum  = Float64List(totalBins);
      final outWeight = Float64List(totalBins);

      for (int h = 0; h < hops.length && _isSweeping; h++) {
        _currentHop = h + 1;
        notifyListeners();

        _backend?.setFrequency(hops[h].toInt());
        await Future.delayed(const Duration(milliseconds: 80));
        if (!_isSweeping) break;

        final fftStream = _backend?.fftStream;
        if (fftStream == null) break;

        final acc       = Float32List(fftSize);
        int count       = 0;
        final completer = Completer<void>();
        late StreamSubscription<Float32List> sub;
        sub = fftStream.listen((frame) {
          if (frame.length != fftSize) return;
          for (int i = 0; i < fftSize; i++) { acc[i] += frame[i]; }
          count++;
          if (count >= settings.framesPerHop) {
            sub.cancel();
            if (!completer.isCompleted) completer.complete();
          }
        });

        await completer.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            sub.cancel();
            if (!completer.isCompleted) completer.complete();
          },
        );

        // Weighted overlap-add: map each FFT bin to its output bin, accumulate
        // Hann-weighted dB value and total weight.
        final hopLeftHz     = hops[h] - settings.rbwHz / 2;
        final hopOffsetBins = ((hopLeftHz - settings.startHz) / binHz).round();
        for (int i = 0; i < fftSize; i++) {
          final outIdx = hopOffsetBins + i;
          if (outIdx < 0 || outIdx >= totalBins) continue;
          final w   = hann[i];
          final val = count > 0 ? acc[i] / count : -90.0;
          outAccum[outIdx]  += w * val;
          outWeight[outIdx] += w;
        }
      }

      if (!_isSweeping) break;

      // Normalise: divide accumulated weighted dB by total weight.
      final sweepBuf = Float32List(totalBins);
      for (int j = 0; j < totalBins; j++) {
        sweepBuf[j] = outWeight[j] > 0
            ? (outAccum[j] / outWeight[j]).toDouble()
            : -90.0;
      }

      _stitchedSpectrum = sweepBuf;

      final peak = _peakHoldSpectrum;
      if (peak == null || peak.length != totalBins) {
        _peakHoldSpectrum = Float32List.fromList(sweepBuf);
      } else {
        for (int i = 0; i < totalBins; i++) {
          if (sweepBuf[i] > peak[i]) peak[i] = sweepBuf[i];
        }
      }

      notifyListeners();
    }

    _isSweeping = false;
    notifyListeners();
  }

  // ── Mock (for testing without hardware) ───────────────────────────────────

  void simulateSignal(double strength) {
    if (_backend?.state == SdrState.running) return; // real data takes precedence
    if (_radioState == RadioState.transmitting) return;
    _radioState = strength > 0 ? RadioState.receiving : RadioState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _backend?.removeListener(_onSdrUpdate);
    super.dispose();
  }
}

