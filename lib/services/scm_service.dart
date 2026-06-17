// lib/services/scm_service.dart
//
// Dart FFI bindings + high-level service for SCM (Smart-meter Channel Message)
// decoding via libscm_decoder.so.
//
// Usage pattern:
//   1. SdrService.handOffDevice()  → dup the USB fd, close spectrum lib
//   2. scmService.start(devQuery)  → open dongle + start decode thread
//   3. Listen to scmService.packets for decoded SCM packets
//   4. scmService.stop()
//   5. sdrService.reopenForSpectrum() → hand device back to spectrum

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ── Native type aliases ────────────────────────────────────────────────────

// void cb(uint32_t id, uint8_t type, uint8_t phy, uint8_t enc,
//         uint32_t consumption, uint16_t crc, int64_t ts_ms)
typedef _ScmCbNative = Void Function(
    Uint32, Uint8, Uint8, Uint8, Uint32, Uint16, Int64);

typedef _ScmOpenN = Int32 Function(Int32 fd, Pointer<Utf8> path);
typedef _ScmOpenD = int   Function(int  fd, Pointer<Utf8> path);

typedef _ScmStartN = Int32 Function(
    Pointer<NativeFunction<_ScmCbNative>>);
typedef _ScmStartD = int   Function(
    Pointer<NativeFunction<_ScmCbNative>>);

typedef _ScmStopN = Void Function();
typedef _ScmStopD = void  Function();

// ── Library + bindings ─────────────────────────────────────────────────────

DynamicLibrary? _tryOpenLib() {
  try {
    return Platform.isAndroid
        ? DynamicLibrary.open('libscm_decoder.so')
        : DynamicLibrary.process();
  } catch (e) {
    debugPrint('scm_service: failed to load libscm_decoder.so — $e');
    return null;
  }
}

final _lib = _tryOpenLib();

final _nativeOpen  = _lib?.lookupFunction<_ScmOpenN,  _ScmOpenD> ('scm_open');
final _nativeStart = _lib?.lookupFunction<_ScmStartN, _ScmStartD>('scm_start');
final _nativeStop  = _lib?.lookupFunction<_ScmStopN,  _ScmStopD> ('scm_stop');

/// True if libscm_decoder.so is present and all symbols resolved.
bool get scmAvailable =>
    _nativeOpen != null && _nativeStart != null && _nativeStop != null;

// ── SCM packet model ───────────────────────────────────────────────────────

class ScmPacket {
  final int id;           // 26-bit meter ID (display as decimal)
  final int type;         // 2=Gas, 12=Electric, 13=Water
  final int tamperPhy;    // physical tamper flag
  final int tamperEnc;    // encryption tamper flag
  final int consumption;  // 24-bit cumulative reading
  final int crc;
  final DateTime timestamp;

  const ScmPacket({
    required this.id,
    required this.type,
    required this.tamperPhy,
    required this.tamperEnc,
    required this.consumption,
    required this.crc,
    required this.timestamp,
  });

  String get typeLabel => switch (type) {
        2  => 'Gas',
        12 => 'Electric',
        13 => 'Water',
        _  => 'Type $type',
      };

  String get consumptionFormatted => switch (type) {
        12 => '${consumption.toStringAsFixed(0)} kWh',
        2  => '${consumption.toStringAsFixed(0)} CCF',
        13 => '${consumption.toStringAsFixed(0)} gal',
        _  => consumption.toString(),
      };
}

// ── ScmService ─────────────────────────────────────────────────────────────

class ScmService {
  ScmService._();
  static final ScmService instance = ScmService._();

  final _controller = StreamController<ScmPacket>.broadcast();

  /// Stream of decoded SCM packets.
  Stream<ScmPacket> get packets => _controller.stream;

  NativeCallable<_ScmCbNative>? _nativeCallback;
  bool _running = false;

  /// Whether the native library is present and all symbols resolved.
  bool get isAvailable => scmAvailable;

  bool get isRunning => _running;

  /// Start decoding.
  ///
  /// [devQuery] — "fd:N:/dev/bus/usb/…" from [SdrService.handOffDevice].
  ///
  /// Returns 0 on success, nonzero on failure.
  int start(String devQuery) {
    if (_running) return 0;
    if (!isAvailable) {
      debugPrint('ScmService: libscm_decoder.so not available — rebuild required');
      return -99;
    }

    // Parse "fd:N:path" → fd (int) + path (string)
    final parts = devQuery.split(':');
    if (parts.length < 3 || parts[0] != 'fd') {
      debugPrint('ScmService: invalid devQuery: $devQuery');
      return -2;
    }
    final fd   = int.tryParse(parts[1]) ?? -1;
    final path = parts.sublist(2).join(':');

    if (fd < 0) {
      debugPrint('ScmService: bad fd in devQuery: $devQuery');
      return -3;
    }

    final pathPtr = path.toNativeUtf8(allocator: malloc);
    int rc;
    try {
      rc = _nativeOpen!(fd, pathPtr);
    } finally {
      malloc.free(pathPtr);
    }

    if (rc != 0) {
      debugPrint('ScmService: scm_open failed (rc=$rc)');
      return rc;
    }

    _nativeCallback = NativeCallable<_ScmCbNative>.listener(_onPacket);

    rc = _nativeStart!(_nativeCallback!.nativeFunction);
    if (rc != 0) {
      debugPrint('ScmService: scm_start failed (rc=$rc)');
      _nativeCallback?.close();
      _nativeCallback = null;
      _nativeStop?.call();
      return rc;
    }

    _running = true;
    return 0;
  }

  /// Stop decoding (blocks briefly until the decode thread exits).
  void stop() {
    if (!_running) return;
    _running = false;
    _nativeStop?.call();
    _nativeCallback?.close();
    _nativeCallback = null;
  }

  void _onPacket(
      int id, int type, int phy, int enc, int consumption, int crc, int tsMs) {
    if (_controller.isClosed) return;
    _controller.add(ScmPacket(
      id:          id,
      type:        type,
      tamperPhy:   phy,
      tamperEnc:   enc,
      consumption: consumption,
      crc:         crc,
      timestamp:   DateTime.fromMillisecondsSinceEpoch(tsMs),
    ));
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
