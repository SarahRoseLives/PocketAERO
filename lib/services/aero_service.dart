// lib/services/aero_service.dart
//
// High-level AERO ACARS decoder service.
//
// Uses the native AERO decoder built into librf_studio_sdr.so.
// Polls decoded messages on a timer and emits them as a Stream.
// Also exposes MSE and lock frequency for UI status display.

import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'sdr_ffi.dart';

class AeroMessage {
  final bool crcOk;
  final String suType;       /* "ACARS" or "CALL" */
  final String hexBytes;     /* decoded text / call info */
  final String aesId;
  final int gesId;
  final int length;
  final String callType;     /* distress, flight_safety, etc. (CALL only) */
  final int callRxFreq;      /* rx MHz * 1e6 (CALL only) */
  final int callTxFreq;      /* tx MHz * 1e6 (CALL only) */
  final int callChannel;     /* channel ID (CALL only) */
  final DateTime timestamp;

  const AeroMessage({
    required this.crcOk,
    required this.suType,
    required this.hexBytes,
    required this.aesId,
    required this.gesId,
    required this.length,
    required this.callType,
    required this.callRxFreq,
    required this.callTxFreq,
    required this.callChannel,
    required this.timestamp,
  });

  static final _callRe = RegExp(
    r'^CALL CH=(\d+)\s+AES=([0-9A-Fa-f]{6})\s+GES=(\d+)\s+TYPE=(\S+)\s+RX=([0-9.]+)\s+TX=([0-9.]+)');
  static final _acarsRe = RegExp(
    r'^AES=([0-9A-Fa-f]{6})\s+GES=(\d+)\s+LEN=(\d+)');
  /* P-channel voice assignment: "P T_ASSIGN AES=XXXXXX GES=XX RX=XXXX.XXXX TX=XXXX.XXXX" */
  static final _vassignRe = RegExp(
    r'^P (?:T_ASSIGN|C_ASSIGN\S*)\s+AES=([0-9A-Fa-f]{6})\s+GES=(\d+)\s+RX=([0-9.]+)\s+TX=([0-9.]+)');

  /// True if an AeroMessage is a voice channel assignment from P-channel.
  bool get isVoiceAssign => suType == 'VASSIGN';

  /// Parse from native format:
  ///   ACARS:   "AES=XXXXXX GES=XX LEN=XXX\ntext\n...\n\n"
  ///   CALL:    "CALL CH=XX AES=XXXXXX GES=XX TYPE=distress RX=XXXXX TX=XXXXX\n"
  ///   VASSIGN: "P T_ASSIGN AES=XXXXXX GES=XX RX=XXXX.XXXX TX=XXXX.XXXX\n"
  factory AeroMessage.parse(String line) {
    // Try voice assignment first
    final vm = _vassignRe.firstMatch(line);
    if (vm != null) {
      return AeroMessage(
        crcOk: true, suType: 'VASSIGN',
        hexBytes: line,
        aesId: vm.group(1)!.toUpperCase(),
        gesId: int.tryParse(vm.group(2)!) ?? 0,
        length: 0,
        callType: line.startsWith('P T_ASSIGN') ? 'T_ASSIGN' : 'C_ASSIGN',
        callRxFreq: ((double.tryParse(vm.group(3)!) ?? 0) * 1e6).round(),
        callTxFreq: ((double.tryParse(vm.group(4)!) ?? 0) * 1e6).round(),
        callChannel: 0,
        timestamp: DateTime.now(),
      );
    }

    // Try CALL first
    final cm = _callRe.firstMatch(line);
    if (cm != null) {
      return AeroMessage(
        crcOk: true, suType: 'CALL',
        hexBytes: line,
        aesId: cm.group(2)!.toUpperCase(),
        gesId: int.tryParse(cm.group(3)!) ?? 0,
        length: 0,
        callType: cm.group(4)!,
        callRxFreq: ((double.tryParse(cm.group(5)!) ?? 0) * 1e6).round(),
        callTxFreq: ((double.tryParse(cm.group(6)!) ?? 0) * 1e6).round(),
        callChannel: int.tryParse(cm.group(1)!) ?? 0,
        timestamp: DateTime.now(),
      );
    }

    // Try ACARS
    final am = _acarsRe.firstMatch(line);
    String aesId = ''; int gesId = 0, len = 0;
    if (am != null) {
      aesId = am.group(1)!.toUpperCase();
      gesId = int.tryParse(am.group(2)!) ?? 0;
      len   = int.tryParse(am.group(3)!) ?? 0;
    }
    return AeroMessage(
      crcOk: true, suType: 'ACARS',
      hexBytes: line,
      aesId: aesId, gesId: gesId, length: len,
      callType: '', callRxFreq: 0, callTxFreq: 0, callChannel: 0,
      timestamp: DateTime.now(),
    );
  }

  @override
  String toString() =>
      '${crcOk ? "✓" : "✗"} $suType $hexBytes';
}

class AeroService {
  final SdrFfi _ffi;
  Timer? _pollTimer;
  bool _running = false;

  final _messageCtrl = StreamController<AeroMessage>.broadcast();
  final _statusCtrl  = StreamController<AeroStatus>.broadcast();

  Stream<AeroMessage> get messages => _messageCtrl.stream;
  Stream<AeroStatus> get status    => _statusCtrl.stream;

  bool get isRunning => _running;

  /* Voice-follow state */
  bool    _voiceFollowing = false;
  int     _prevFreqHz     = 0;
  double  _prevSymbolRate = 10500;
  int     _voiceRxHz      = 0;
  int     _silenceMs      = 0;
  Timer?  _silenceTimer;

  /// Called by HomeScreen when voice-follow is enabled and a VASSIGN arrives.
  /// Returns [voiceRxHz, prevFreqHz, prevSymbolRate] or null.
  Map<String, dynamic>? onVoiceAssign(AeroMessage msg, int currentFreqHz, double currentRate) {
    if (!msg.isVoiceAssign || msg.callRxFreq == 0) return null;
    final rxHz = msg.callRxFreq;
    // Don't re-trigger if already on this voice channel
    if (_voiceFollowing && _voiceRxHz == rxHz) return null;
    _voiceFollowing  = true;
    _prevFreqHz      = currentFreqHz;
    _prevSymbolRate  = currentRate;
    _voiceRxHz       = rxHz;
    _silenceMs       = 0;
    _silenceTimer?.cancel();
    return {
      'voiceFreq': rxHz,
      'prevFreq':  _prevFreqHz,
      'prevRate':  _prevSymbolRate,
    };
  }

  /// Reset voice-follow (e.g. back to P-channel).
  Map<String, dynamic>? revertVoiceFollow() {
    if (!_voiceFollowing) return null;
    _voiceFollowing = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    final prevFreq = _prevFreqHz;
    final prevRate = _prevSymbolRate;
    _prevFreqHz = 0;
    _voiceRxHz = 0;
    return {'freqHz': prevFreq, 'symbolRate': prevRate};
  }

  bool get isVoiceFollowing => _voiceFollowing;

  AeroService(this._ffi);

  void start() {
    if (_running) return;
    final r = _ffi.startAero();
    if (r != 0) return;
    _running = true;
    _startPoller();
  }

  void stop() {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _ffi.stopAero();
  }

  void _startPoller() {
    _pollTimer?.cancel();
    final outPtr = malloc<Uint8>(4096);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_running) return;
      try {
        final n = _ffi.pollAero(outPtr, 4096);
        bool hadVoiceMsg = false;
        if (n > 0) {
          final text = outPtr.cast<Utf8>().toDartString(length: n);
          for (final line in text.split('\n')) {
            if (line.trim().isNotEmpty) {
              final msg = AeroMessage.parse(line);
              _messageCtrl.add(msg);
              if (msg.isVoiceAssign) hadVoiceMsg = true;
            }
          }
        }
        /* Voice-follow silence timeout: if following a voice channel
         * and no VASSIGN messages for 5 seconds, revert to P-channel. */
        if (_voiceFollowing) {
          if (hadVoiceMsg) {
            _silenceMs = 0;
          } else {
            _silenceMs += 200;
            if (_silenceMs >= 5000) {
              _messageCtrl.add(AeroMessage(
                crcOk: true, suType: 'REVERT',
                hexBytes: '', aesId: '', gesId: 0, length: 0,
                callType: '', callRxFreq: 0, callTxFreq: 0, callChannel: 0,
                timestamp: DateTime.now(),
              ));
              _silenceMs = 0;
            }
          }
        }
        _statusCtrl.add(AeroStatus(
          mse: _ffi.getAeroMse(),
          freqHz: _ffi.getAeroFreq(),
          ebNo: _ffi.getAeroEbNo(),
        ));
      } catch (_) {}
    });
  }

  void dispose() {
    stop();
    _messageCtrl.close();
    _statusCtrl.close();
  }
}

class AeroStatus {
  final double mse;
  final double freqHz;
  final double ebNo;
  const AeroStatus({required this.mse, required this.freqHz, required this.ebNo});

  bool get isLocked => mse < 0.5;
}
