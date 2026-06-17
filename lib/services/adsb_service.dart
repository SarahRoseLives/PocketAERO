// lib/services/adsb_service.dart
//
// Dart FFI bindings for libadsb_ffi.so (ADS-B / Mode S 1090 MHz decoder).
//
// Usage:
//   1. AdsbService.instance.start(fd, devPath) → starts RTL-SDR capture
//   2. Listen to AdsbService.instance.aircraftStream for live updates
//   3. AdsbService.instance.stop() → stops capture, call _resumeSpectrum()

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ── Native struct (must match AdsbAircraftExport in adsb_ffi.cpp exactly) ─────

final class AdsbAircraftNative extends Struct {
  @Uint32()
  external int addr;

  @Array(9)
  external Array<Uint8> callsign;

  @Double()
  external double lat;

  @Double()
  external double lon;

  @Int32()
  external int altitude;

  @Float()
  external double speed;

  @Float()
  external double heading;

  @Int32()
  external int vertRate;

  @Uint32()
  external int squawk;

  @Int32()
  external int onGround;

  @Int32()
  external int posValid;

  @Int64()
  external int messages;
}

// ── FFI type aliases ──────────────────────────────────────────────────────────

typedef _AdsbStartC    = Int32 Function(Int32 fd, Pointer<Utf8> devPath);
typedef _AdsbStartDart = int   Function(int  fd, Pointer<Utf8> devPath);

typedef _AdsbStopC    = Void Function();
typedef _AdsbStopDart = void  Function();

typedef _AdsbGetAircraftC    = Int32 Function(Pointer<AdsbAircraftNative> out, Int32 maxCount);
typedef _AdsbGetAircraftDart = int   Function(Pointer<AdsbAircraftNative> out, int  maxCount);

typedef _AdsbIsRunningC    = Int32 Function();
typedef _AdsbIsRunningDart = int   Function();

typedef _AdsbGetMessageCountC    = Int64 Function();
typedef _AdsbGetMessageCountDart = int   Function();

// ── Dart data model ───────────────────────────────────────────────────────────

class AdsbAircraft {
  final int    addr;
  final String callsign;
  final double lat;
  final double lon;
  final int    altitude;
  final double speed;
  final double heading;
  final int    vertRate;
  final int    squawk;
  final bool   onGround;
  final bool   posValid;
  final int    messages;

  const AdsbAircraft({
    required this.addr,
    required this.callsign,
    required this.lat,
    required this.lon,
    required this.altitude,
    required this.speed,
    required this.heading,
    required this.vertRate,
    required this.squawk,
    required this.onGround,
    required this.posValid,
    required this.messages,
  });

  String get icaoHex    => addr.toRadixString(16).toUpperCase().padLeft(6, '0');
  String get altStr     => altitude == -2147483648 ? '---' : '${altitude}ft';
  String get spdStr     => speed < 0 ? '---' : '${speed.round()}kt';
  String get hdgStr     => heading < 0 ? '---' : '${heading.round()}°';
  String get squawkStr  => squawk == 0 ? '----' : squawk.toRadixString(8).padLeft(4, '0');
  String get displayCs  => callsign.isEmpty ? icaoHex : callsign;
}

// ── Library loader ────────────────────────────────────────────────────────────

DynamicLibrary? _tryOpenLib() {
  try {
    return Platform.isAndroid
        ? DynamicLibrary.open('libadsb_ffi.so')
        : DynamicLibrary.process();
  } catch (e) {
    debugPrint('adsb_service: failed to load libadsb_ffi.so — $e');
    return null;
  }
}

final _lib = _tryOpenLib();

final _nativeStart    = _lib?.lookupFunction<_AdsbStartC,    _AdsbStartDart>   ('adsb_start');
final _nativeStop     = _lib?.lookupFunction<_AdsbStopC,     _AdsbStopDart>    ('adsb_stop');
final _nativeGetAc    = _lib?.lookupFunction<_AdsbGetAircraftC, _AdsbGetAircraftDart>('adsb_get_aircraft');
final _nativeIsRun    = _lib?.lookupFunction<_AdsbIsRunningC, _AdsbIsRunningDart>('adsb_is_running');
final _nativeMsgCount = _lib?.lookupFunction<_AdsbGetMessageCountC, _AdsbGetMessageCountDart>('adsb_get_message_count');

bool get adsbAvailable =>
    _nativeStart != null &&
    _nativeStop  != null &&
    _nativeGetAc != null &&
    _nativeIsRun != null;

// ── AdsbService ───────────────────────────────────────────────────────────────

class AdsbService {
  AdsbService._();
  static final AdsbService instance = AdsbService._();

  Timer? _pollTimer;
  final _controller = StreamController<List<AdsbAircraft>>.broadcast();

  Stream<List<AdsbAircraft>> get aircraftStream => _controller.stream;
  bool get isAvailable => adsbAvailable;
  bool get isRunning   => _nativeIsRun?.call() != 0;
  int  get messageCount => _nativeMsgCount?.call() ?? 0;

  /// Start ADS-B capture using the RTL-SDR fd + device path.
  /// [devQuery] format: "fd:N:/dev/bus/usb/..."
  bool start(String devQuery) {
    if (!isAvailable) {
      debugPrint('AdsbService: libadsb_ffi.so not available');
      return false;
    }

    final parts = devQuery.split(':');
    if (parts.length < 3 || parts[0] != 'fd') {
      debugPrint('AdsbService: invalid devQuery: $devQuery');
      return false;
    }
    final fd   = int.tryParse(parts[1]) ?? -1;
    final path = parts.sublist(2).join(':');
    if (fd < 0) return false;

    final pathPtr = path.toNativeUtf8(allocator: malloc);
    int rc;
    try {
      rc = _nativeStart!(fd, pathPtr);
    } finally {
      malloc.free(pathPtr);
    }

    if (rc == 0) {
      debugPrint('AdsbService: adsb_start failed');
      return false;
    }

    _startPollTimer();
    return true;
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _nativeStop?.call();
  }

  void _startPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!isRunning) {
        _pollTimer?.cancel();
        return;
      }
      _controller.add(_fetchAircraft());
    });
  }

  List<AdsbAircraft> _fetchAircraft() {
    if (_nativeGetAc == null) return [];
    const maxAircraft = 256;
    final ptr = calloc<AdsbAircraftNative>(maxAircraft);
    try {
      final count = _nativeGetAc!(ptr, maxAircraft);
      final result = <AdsbAircraft>[];
      for (int i = 0; i < count; i++) {
        final n = ptr[i];
        final csBytes = <int>[];
        for (int j = 0; j < 8; j++) {
          final b = n.callsign[j];
          if (b == 0) break;
          csBytes.add(b);
        }
        final cs = String.fromCharCodes(csBytes).trim();
        result.add(AdsbAircraft(
          addr:     n.addr,
          callsign: cs,
          lat:      n.lat,
          lon:      n.lon,
          altitude: n.altitude,
          speed:    n.speed.toDouble(),
          heading:  n.heading.toDouble(),
          vertRate: n.vertRate,
          squawk:   n.squawk,
          onGround: n.onGround != 0,
          posValid: n.posValid != 0,
          messages: n.messages,
        ));
      }
      // Sort by message count descending (most active first)
      result.sort((a, b) => b.messages.compareTo(a.messages));
      return result;
    } finally {
      calloc.free(ptr);
    }
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
