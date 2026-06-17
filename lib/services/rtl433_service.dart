// lib/services/rtl433_service.dart
//
// Dart FFI bindings + high-level service for rtl_433 decoding (librtl433_ffi.so).
//
// Usage pattern:
//   1. SdrFfi.instance.stop() + close()  → release the device
//   2. rtl433Service.start(devQuery, freqHz, gainStr)
//   3. Listen to rtl433Service.messages for decoded packets
//   4. rtl433Service.stop()
//   5. sdrService.reopenForSpectrum()    → hand device back to spectrum

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ── Native type aliases ────────────────────────────────────────────────────

typedef _DataCbNative = Void Function(Pointer<Utf8> json, Pointer<Void> ctx);

typedef _StartN = Int32 Function(
  Pointer<Utf8>                              devQuery,
  Uint32                                     freqHz,
  Uint32                                     sampleRate,
  Pointer<Utf8>                              gainStr,
  Int32                                      biasT,
  Pointer<NativeFunction<_DataCbNative>>     cb,
  Pointer<Void>                              ctx,
);
typedef _StartD = int Function(
  Pointer<Utf8>                              devQuery,
  int                                        freqHz,
  int                                        sampleRate,
  Pointer<Utf8>                              gainStr,
  int                                        biasT,
  Pointer<NativeFunction<_DataCbNative>>     cb,
  Pointer<Void>                              ctx,
);

typedef _StopN   = Void  Function();
typedef _StopD   = void  Function();

typedef _StatusN = Int32 Function();
typedef _StatusD = int   Function();

// ── Library + bindings ─────────────────────────────────────────────────────

DynamicLibrary? _tryOpenLib() {
  try {
    return Platform.isAndroid
        ? DynamicLibrary.open('librtl433_ffi.so')
        : DynamicLibrary.process();
  } catch (e) {
    debugPrint('rtl433_service: failed to load librtl433_ffi.so — $e');
    return null;
  }
}

final _lib = _tryOpenLib();

final _nativeStart = _lib?.lookupFunction<_StartN, _StartD>('rtl433_ffi_start');
final _nativeStop  = _lib?.lookupFunction<_StopN,  _StopD> ('rtl433_ffi_stop');
final _nativeStatus = _lib?.lookupFunction<_StatusN, _StatusD>('rtl433_ffi_status');

/// True if librtl433_ffi.so is present and all symbols resolved.
bool get rtl433Available => _nativeStart != null;

// ── Decoded packet model ───────────────────────────────────────────────────

class Rtl433Packet {
  final DateTime timestamp;
  final Map<String, dynamic> data;

  const Rtl433Packet({required this.timestamp, required this.data});

  String get model => data['model'] as String? ?? 'Unknown';

  /// Returns the "category" of this packet for background colour tinting.
  PacketCategory get category {
    final m = model.toLowerCase();
    if (m.contains('weather') || m.contains('thermo') || m.contains('temp') ||
        m.contains('acurite') || m.contains('lacrosse') || m.contains('alecto') ||
        m.contains('auriol') || m.contains('bresser') || m.contains('ambient')) {
      return PacketCategory.weather;
    }
    if (m.contains('tpms') || m.contains('tire') || m.contains('tyre')) {
      return PacketCategory.tpms;
    }
    if (m.contains('door') || m.contains('pir') || m.contains('motion') ||
        m.contains('contact') || m.contains('alarm')) {
      return PacketCategory.security;
    }
    if (m.contains('power') || m.contains('energy') || m.contains('meter') ||
        m.contains('kwh') || m.contains('watt')) {
      return PacketCategory.energy;
    }
    return PacketCategory.other;
  }
}

enum PacketCategory { weather, tpms, security, energy, other }

// ── Rtl433Service ──────────────────────────────────────────────────────────

class Rtl433Service {
  Rtl433Service._();
  static final Rtl433Service instance = Rtl433Service._();

  final _controller = StreamController<Rtl433Packet>.broadcast();

  /// Stream of decoded RF packets.
  Stream<Rtl433Packet> get messages => _controller.stream;

  NativeCallable<_DataCbNative>? _nativeCallback;
  bool _running = false;

  /// Start decoding.
  ///
  /// [devQuery]   — "fd:N:/dev/bus/usb/…" from [SdrService.usbDevQuery]
  /// [freqHz]     — centre frequency (default 433 920 000)
  /// [sampleRate] — IQ sample rate (250 000 recommended for rtl_433)
  /// [gainStr]    — gain string like "40" or null for AGC
  ///
  /// Returns 0 on success, nonzero on failure.
  int start({
    required String devQuery,
    int freqHz       = 433920000,
    int sampleRate   = 250000,
    String? gainStr,
    bool biasT       = false,
  }) {
    if (_running) return 0;
    if (_nativeStart == null) {
      debugPrint('Rtl433Service: librtl433_ffi.so not available — rebuild required');
      return -99;
    }

    _nativeCallback = NativeCallable<_DataCbNative>.listener(_onPacket);

    final devPtr  = devQuery.toNativeUtf8(allocator: malloc);
    // Pass empty string for auto-gain; rtl_433 treats empty as AGC.
    final gainPtr = (gainStr != null && gainStr.isNotEmpty)
        ? gainStr.toNativeUtf8(allocator: malloc)
        : ''.toNativeUtf8(allocator: malloc);

    int rc;
    try {
      rc = _nativeStart!(
        devPtr,
        freqHz,
        sampleRate,
        gainPtr,
        biasT ? 1 : 0,
        _nativeCallback!.nativeFunction,
        nullptr,
      );
    } finally {
      malloc.free(devPtr);
      malloc.free(gainPtr);
    }

    if (rc != 0) {
      debugPrint('Rtl433Service: rtl433_ffi_start failed (rc=$rc)');
      _nativeCallback?.close();
      _nativeCallback = null;
      return rc;
    }

    _running = true;
    return 0;
  }

  /// Stop decoding (blocks briefly until rtl_433 threads exit).
  void stop() {
    if (!_running) return;
    _running = false;
    _nativeStop?.call();
    _nativeCallback?.close();
    _nativeCallback = null;
  }

  /// 0 = stopped, 1 = running, -1 = error.
  int get nativeStatus => _nativeStatus?.call() ?? 0;

  bool get isRunning => _running;

  /// Whether the native library is present and usable.
  bool get isAvailable => rtl433Available;

  void _onPacket(Pointer<Utf8> json, Pointer<Void> ctx) {
    if (_controller.isClosed) return;
    try {
      final decoded = jsonDecode(json.toDartString());
      if (decoded is Map<String, dynamic>) {
        _controller.add(Rtl433Packet(
          timestamp: DateTime.now(),
          data: decoded,
        ));
      }
    } catch (e) {
      debugPrint('Rtl433Service: JSON parse error: $e');
    }
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
