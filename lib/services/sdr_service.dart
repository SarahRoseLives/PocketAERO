// lib/services/sdr_service.dart
//
// High-level RTL-SDR service.
//
// Manages:
//  • USB device discovery via Kotlin MethodChannel
//  • Opening / closing the device
//  • Forwarding configuration changes to SdrFfi
//  • Exposing spectrumStream + signalDb for the UI

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/sdr_type.dart';
import 'sdr_backend.dart';
import 'sdr_ffi.dart';

enum SdrState { disconnected, connecting, running, error }

// USB VID:PID → SdrType mapping
const _vidPidMap = <(int, int), SdrType>{
  (0x0bda, 0x2832): SdrType.rtlSdr, // RTL2832U
  (0x0bda, 0x2838): SdrType.rtlSdr, // RTL2838
  (0x0bda, 0x2837): SdrType.rtlSdr,
  (0x1d50, 0x6089): SdrType.hackRf, // HackRF One
  (0x1d50, 0x604b): SdrType.hackRf, // HackRF Jawbreaker
  (0x04b4, 0x00f3): SdrType.plutoSdr,
};

SdrType _detectType(SdrDeviceInfo dev) {
  return _vidPidMap[(dev.vid, dev.pid)] ??
      (dev.name.toLowerCase().contains('hackrf')
          ? SdrType.hackRf
          : dev.name.toLowerCase().contains('pluto')
              ? SdrType.plutoSdr
              : SdrType.rtlSdr);
}

class SdrDeviceInfo {
  final String name;
  final int vid;
  final int pid;
  const SdrDeviceInfo({required this.name, required this.vid, required this.pid});
}

class SdrService extends SdrBackend {
  static const _usbChannel = MethodChannel('dev.sarahsforge.paero/usb');

  final _ffi = SdrFfi.instance;
  SdrFfi get ffi => _ffi;

  SdrState _state   = SdrState.disconnected;
  String?  _error;
  SdrType? _connectedType;
  List<SdrDeviceInfo> _devices = [];
  double   _signalDb = -120.0;

  // Stored after connect so 433 service can open the same fd.
  int    _usbFd         = -1;
  int    _usbFdDup      = -1; /* dup'd fd reserved for reopenForSpectrum */
  String _usbPath       = '';
  bool   _deviceHandedOff = false; /* true between handOffDevice and reopen */

  // Forwarded from FFI
  @override
  Stream<Float32List> get spectrumStream => _ffi.spectrumStream;

  /// Alias used by the sweep loop.
  @override
  Stream<Float32List> get fftStream => spectrumStream;

  @override
  SdrState get state           => _state;
  @override
  String?  get error           => _error;
  @override
  SdrType? get connectedType   => _connectedType;
  @override
  bool get isRunning           => _state == SdrState.running;

  void resetState() { _state = SdrState.disconnected; _error = null; }
  @override
  List<SdrDeviceInfo> get devices => List.unmodifiable(_devices);
  @override
  double get signalDb   => _signalDb;

  Timer? _sigTimer;

  // ── Device discovery ───────────────────────────────────────────────────────

  @override
  Future<void> scanDevices() async {
    try {
      final raw = await _usbChannel.invokeListMethod<Map>('listDevices') ?? [];
      _devices = raw.map((m) => SdrDeviceInfo(
        name: m['name'] as String,
        vid:  m['vid']  as int,
        pid:  m['pid']  as int,
      )).toList();
    } on PlatformException catch (e) {
      debugPrint('SdrService.scanDevices: ${e.message}');
      _devices = [];
    }
    notifyListeners();
  }

  // ── Connect / disconnect ──────────────────────────────────────────────────

  @override
  Future<void> connect(SdrDeviceInfo device, {int fftSize = 2048}) async {
    if (_state != SdrState.disconnected) return;
    _setState(SdrState.connecting);

    try {
      final Map result = await _usbChannel.invokeMethod('openDevice', {'name': device.name});
      final int    fd   = result['fd']   as int;
      final String path = result['path'] as String;
      _usbFd   = fd;
      _usbPath = path;

      final openResult = _ffi.open(fd, path, fftSize: fftSize);
      debugPrint('SdrService.connect: rf_open result=$openResult');
      if (openResult != 0) throw Exception('rf_open failed ($openResult)');

      final startResult = _ffi.start();
      debugPrint('SdrService.connect: rf_start result=$startResult state=${_state}');
      if (startResult != 0) throw Exception('rf_start failed ($startResult)');

      _connectedType = _detectType(device);
      _startSignalPoller();
      _setState(SdrState.running);
      debugPrint('SdrService.connect: state set to running, isRunning=${_state == SdrState.running}');
    } on PlatformException catch (e) {
      _setError(e.message ?? 'USB error');
      rethrow;
    } catch (e) {
      _setError(e.toString());
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _stopSignalPoller();
    _ffi.close();
    try { await _usbChannel.invokeMethod('closeDevice'); } catch (_) {}
    _signalDb        = -120.0;
    _connectedType   = null;
    _usbFd           = -1;
    _usbFdDup        = -1;
    _deviceHandedOff = false;
    _usbPath         = '';
    _setState(SdrState.disconnected);
  }

  // ── Tuning / configuration ────────────────────────────────────────────────

  @override
  void setFrequency(int hz) {
    if (isRunning) _ffi.setFrequency(hz);
  }

  @override
  void setSampleRate(int sps) {
    if (isRunning) _ffi.setSampleRate(sps);
  }

  /// [tenthsDb] = gain in tenths of a dB (e.g. 300 = 30.0 dB), or -1 for auto.
  @override
  void setGain(int tenthsDb) {
    if (isRunning) _ffi.setGain(tenthsDb);
  }

  /// Enable/disable the RTL-SDR bias tee (5V on antenna port).
  /// Not persisted — defaults off for safety on each app start.
  void setBiasTee(bool on) {
    _ffi.setBiasTee(on);
  }



  /// Device query string for rtl433_ffi_start, e.g. "fd:5:/dev/bus/usb/001/002".
  /// Returns empty string if no device is connected.
  String get usbDevQuery => _usbFd >= 0 ? 'fd:$_usbFd:$_usbPath' : '';

  /// Hand off the USB device to a secondary decoder (433 MHz, SCM, etc.).
  ///
  /// Duplicates the USB fd TWICE before closing librtlsdr:
  ///   • First dup  → returned in the devQuery string for the decoder library.
  ///   • Second dup → stored in [_usbFdDup] for [reopenForSpectrum].
  ///
  /// Returns null if no device is connected.
  String? handOffDevice() {
    if (_usbFd < 0) return null;
    _stopSignalPoller();
    _ffi.stop();
    final dupForDecoder = _ffi.dupUsbFd();
    final dupForReopen  = _ffi.dupUsbFd();
    _ffi.close();
    if (dupForDecoder < 0 || dupForReopen < 0) return null;
    _usbFdDup       = dupForReopen;
    _deviceHandedOff = true;
    return 'fd:$dupForDecoder:$_usbPath';
  }

  /// Re-open the device on the spectrum side and restart the FFT thread.
  /// No-op if [handOffDevice] was never called or reopen already succeeded.
  void reopenForSpectrum() {
    if (!_deviceHandedOff) return; // nothing was handed off
    final fd = _usbFdDup >= 0 ? _usbFdDup : _usbFd;
    if (fd < 0) return;
    _usbFdDup        = -1;
    _deviceHandedOff = false;
    final r = _ffi.open(fd, _usbPath, fftSize: 2048);
    if (r == 0) {
      _usbFd = fd;
      _ffi.start();
      _startSignalPoller();
      _setState(SdrState.running);
    }
  }

  /// True if [handOffDevice] was called and the FFT pipeline needs restarting.
  bool get needsSpectrumReopen => _deviceHandedOff;

  // ── WFM demodulation ─────────────────────────────────────────────────────

  static const _wfmAudioChannel = MethodChannel('dev.sarahsforge.paero/wfm_audio');

  bool _wfmRunning = false;
  bool get isWfmRunning => _wfmRunning;
  int _demodMode = 0; // 0=WFM, 1=NFM
  int get demodMode => _demodMode;

  /// Start WFM (mode=0) or NFM (mode=1) demodulation + audio playback.
  Future<void> startDemod(int mode) async {
    if (_wfmRunning) await stopDemod();
    _demodMode = mode;
    _ffi.startWfm(mode: mode);
    await _wfmAudioChannel.invokeMethod('startAudio');
    _wfmRunning = true;
    notifyListeners();
  }

  Future<void> startWfm() => startDemod(0);

  /// Stop demodulation and audio.
  Future<void> stopDemod() async {
    if (!_wfmRunning) return;
    _ffi.stopWfm();
    await _wfmAudioChannel.invokeMethod('stopAudio');
    _wfmRunning = false;
    _ffi.start();
    notifyListeners();
  }

  Future<void> stopWfm() => stopDemod();

  // ── Signal level poller ───────────────────────────────────────────────────

  void _startSignalPoller() {
    _sigTimer?.cancel();
    _sigTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!isRunning) return;
      final db = _ffi.getSignalDb();
      if ((db - _signalDb).abs() > 0.5) {
        _signalDb = db;
        notifyListeners();
      }
    });
  }

  void _stopSignalPoller() {
    _sigTimer?.cancel();
    _sigTimer = null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setState(SdrState s) {
    _state = s;
    _error = null;
    notifyListeners();
  }

  void _setError(String msg) {
    _state  = SdrState.error;
    _error  = msg;
    notifyListeners();
  }

  @override
  void dispose() {
    _ffi.dispose();
    _stopSignalPoller();
    super.dispose();
  }
}
