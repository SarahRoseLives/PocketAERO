// lib/services/dect_service.dart
//
// Dart FFI bindings + high-level service for DECT decoding via libdect_ffi.so.
//
// RTL-SDR path:
//   1. SdrService.handOffDevice()  → dup the USB fd, close spectrum lib
//   2. dectService.startRtl(devQuery, band) → open dongle + start decode thread
//   3. Poll dectService.getStatus() / getParts() on a timer
//   4. dectService.stop()
//   5. sdrService.reopenForSpectrum()
//
// HackRF path:
//   1. dectService.startPush(band) → engine-only start, no RTL-SDR opened
//   2. Subscribe to HackrfService.iqStream → call dectService.pushIqU8(chunk)
//   3. Check dectService.consumeRetune() → update HackrfService frequency
//   4. dectService.stop()

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ── Native struct definitions ──────────────────────────────────────────────

// Must match DectStatus in dect_ffi.cpp exactly.
final class DectStatusNative extends Struct {
  @Int32()  external int running;        // 0=stopped, 1=scanning, 2=narrowband
  @Int32()  external int band;           // 0=US, 1=EU
  @Int32()  external int tunedChannel;   // -1=scanning, 0–9=locked
  @Uint64() external int tunedFreqHz;
  @Int32()  external int voicePresent;
  @Int32()  external int partCount;
  @Uint64() external int packetsSeen;
}

// Must match DectPart in dect_ffi.cpp exactly.
final class DectPartNative extends Struct {
  @Int32()  external int rxId;
  @Int32()  external int type;           // 0=RFP (base), 1=PP (handset)
  @Int32()  external int voicePresent;
  @Int32()  external int qtSynced;
  @Int32()  external int slot;
  @Uint64() external int packetsOk;
  @Uint64() external int packetsBadCrc;
  @Uint64() external int voiceFramesOk;
  @Uint64() external int voiceXcrcFail;
  @Uint64() external int voiceSkipped;
  @Array(16)
  external Array<Char> partId;
}

// ── Native function type aliases ───────────────────────────────────────────

typedef _DectStartN = Int32 Function(Int32 fd, Pointer<Utf8> path, Int32 band);
typedef _DectStartD = int   Function(int  fd, Pointer<Utf8> path, int  band);

typedef _DectStartPushN = Int32 Function(Int32 band);
typedef _DectStartPushD = int   Function(int  band);

typedef _DectPushIqN = Void Function(Pointer<Int8> data, Int32 len);
typedef _DectPushIqD = void  Function(Pointer<Int8> data, int  len);

typedef _DectConsumeRetuneN = Int32 Function(
    Pointer<Uint64> freqHz, Pointer<Uint32> sampleRate);
typedef _DectConsumeRetuneD = int   Function(
    Pointer<Uint64> freqHz, Pointer<Uint32> sampleRate);

typedef _DectStopN = Void Function();
typedef _DectStopD = void  Function();

typedef _DectGetStatusN = Void Function(Pointer<DectStatusNative> out);
typedef _DectGetStatusD = void  Function(Pointer<DectStatusNative> out);

typedef _DectGetPartsN = Int32 Function(
    Pointer<DectPartNative> out, Int32 maxCount);
typedef _DectGetPartsD = int   Function(
    Pointer<DectPartNative> out, int  maxCount);

// ── Library + bindings ─────────────────────────────────────────────────────

DynamicLibrary? _tryOpenLib() {
  try {
    return Platform.isAndroid
        ? DynamicLibrary.open('libdect_ffi.so')
        : DynamicLibrary.process();
  } catch (e) {
    debugPrint('dect_service: failed to load libdect_ffi.so — $e');
    return null;
  }
}

final _lib = _tryOpenLib();

final _nativeStart      = _lib?.lookupFunction<_DectStartN, _DectStartD>('dect_start');
final _nativeStartPush  = _lib?.lookupFunction<_DectStartPushN, _DectStartPushD>('dect_start_push');
final _nativePushIq     = _lib?.lookupFunction<_DectPushIqN, _DectPushIqD>('dect_push_iq_s8');
final _nativeRetune     = _lib?.lookupFunction<_DectConsumeRetuneN, _DectConsumeRetuneD>('dect_consume_retune');
final _nativeStop       = _lib?.lookupFunction<_DectStopN,  _DectStopD> ('dect_stop');
final _nativeGetStatus  = _lib?.lookupFunction<_DectGetStatusN, _DectGetStatusD>('dect_get_status');
final _nativeGetParts   = _lib?.lookupFunction<_DectGetPartsN, _DectGetPartsD>('dect_get_parts');

/// True if libdect_ffi.so is present and all symbols resolved.
bool get dectAvailable =>
    _nativeStart != null &&
    _nativeStop  != null &&
    _nativeGetStatus != null &&
    _nativeGetParts  != null;

// ── Dart data models ───────────────────────────────────────────────────────

class DectStatus {
  final int     running;        // 0=stopped, 1=scanning, 2=narrowband
  final int     band;           // 0=US, 1=EU
  final int     tunedChannel;   // -1=scanning, 0–9=locked channel
  final int     tunedFreqHz;
  final bool    voicePresent;
  final int     partCount;
  final int     packetsSeen;

  const DectStatus({
    required this.running,
    required this.band,
    required this.tunedChannel,
    required this.tunedFreqHz,
    required this.voicePresent,
    required this.partCount,
    required this.packetsSeen,
  });

  factory DectStatus.empty() => const DectStatus(
    running: 0, band: 0, tunedChannel: -1,
    tunedFreqHz: 0, voicePresent: false,
    partCount: 0, packetsSeen: 0,
  );

  String get modeLabel => switch (running) {
    1 => 'Scanning',
    2 => 'Narrowband Lock',
    _ => 'Stopped',
  };

  String get freqMhz {
    if (tunedFreqHz == 0) return '—';
    final mhz = tunedFreqHz / 1e6;
    return '${mhz.toStringAsFixed(3)} MHz';
  }

  String get bandLabel => band == 1 ? 'EU (1880 MHz)' : 'US (1920 MHz)';
}

class DectPart {
  final int    rxId;
  final int    type;           // 0=RFP (base), 1=PP (handset)
  final bool   voicePresent;
  final bool   qtSynced;
  final int    slot;
  final int    packetsOk;
  final int    packetsBadCrc;
  final int    voiceFramesOk;
  final int    voiceXcrcFail;
  final int    voiceSkipped;
  final String partId;

  const DectPart({
    required this.rxId,
    required this.type,
    required this.voicePresent,
    required this.qtSynced,
    required this.slot,
    required this.packetsOk,
    required this.packetsBadCrc,
    required this.voiceFramesOk,
    required this.voiceXcrcFail,
    required this.voiceSkipped,
    required this.partId,
  });

  String get typeLabel => type == 0 ? 'RFP (Base)' : 'PP (Handset)';
  bool   get isRfp     => type == 0;
}

// ── Retune request from engine ─────────────────────────────────────────────

class DectRetuneRequest {
  final int freqHz;
  final int sampleRate;
  const DectRetuneRequest(this.freqHz, this.sampleRate);
}

// ── Audio playback (via Android AudioTrack method channel) ─────────────────

const _audioChannel = MethodChannel('dev.sarahsforge.paero/dect_audio');

// ── DectService ────────────────────────────────────────────────────────────

class DectService {
  DectService._();
  static final DectService instance = DectService._();

  bool _running = false;

  bool get isAvailable => dectAvailable;
  bool get isRunning   => _running;

  /// Start decoding via RTL-SDR (hands off the device).
  ///
  /// [devQuery] — "fd:N:/dev/bus/usb/…" from [SdrService.handOffDevice].
  /// [band]     — 0=US, 1=EU.
  bool startRtl(String devQuery, int band) {
    if (_running) return true;
    if (!isAvailable) {
      debugPrint('DectService: libdect_ffi.so not available');
      return false;
    }

    final parts = devQuery.split(':');
    if (parts.length < 3 || parts[0] != 'fd') {
      debugPrint('DectService: invalid devQuery: $devQuery');
      return false;
    }
    final fd   = int.tryParse(parts[1]) ?? -1;
    final path = parts.sublist(2).join(':');
    if (fd < 0) return false;

    final pathPtr = path.toNativeUtf8(allocator: malloc);
    int rc;
    try {
      rc = _nativeStart!(fd, pathPtr, band);
    } finally {
      malloc.free(pathPtr);
    }

    if (rc == 0) {
      debugPrint('DectService: dect_start failed');
      return false;
    }
    _running = true;
    return true;
  }

  /// Start DECT engine in HackRF push mode (no RTL-SDR opened).
  /// Caller feeds IQ chunks via [pushIqU8].
  bool startPush(int band) {
    if (_running) return true;
    if (_nativeStartPush == null) {
      debugPrint('DectService: dect_start_push not available');
      return false;
    }
    final rc = _nativeStartPush!(band);
    if (rc == 0) {
      debugPrint('DectService: dect_start_push failed');
      return false;
    }
    _running = true;
    return true;
  }

  /// Push a chunk of IQ bytes from HackRF.
  /// HackRF delivers signed int8 packed as uint8 (Java byte → Dart Uint8List).
  /// Reinterpret as signed before passing to the C engine.
  void pushIqU8(Uint8List chunk) {
    if (!_running || _nativePushIq == null || chunk.isEmpty) return;
    final ptr = malloc<Int8>(chunk.length);
    try {
      for (int i = 0; i < chunk.length; i++) {
        // Reinterpret uint8 as int8: values >127 are negative
        final v = chunk[i];
        ptr[i] = v > 127 ? v - 256 : v;
      }
      _nativePushIq!(ptr, chunk.length);
    } finally {
      malloc.free(ptr);
    }
  }

  /// Check if the engine wants a retune (HackRF path).
  /// Returns null if no retune pending.
  DectRetuneRequest? consumeRetune() {
    if (_nativeRetune == null) return null;
    final freqPtr = calloc<Uint64>();
    final ratePtr = calloc<Uint32>();
    try {
      final pending = _nativeRetune!(freqPtr, ratePtr);
      if (pending == 0) return null;
      return DectRetuneRequest(freqPtr.value, ratePtr.value);
    } finally {
      calloc.free(freqPtr);
      calloc.free(ratePtr);
    }
  }

  /// Stop decoding (RTL-SDR or push mode).
  void stop() {
    if (!_running) return;
    _running = false;
    _nativeStop?.call();
  }

  /// Returns current engine status.
  DectStatus getStatus() {
    if (!isAvailable) return DectStatus.empty();
    final ptr = calloc<DectStatusNative>();
    try {
      _nativeGetStatus!(ptr);
      final s = ptr.ref;
      return DectStatus(
        running:      s.running,
        band:         s.band,
        tunedChannel: s.tunedChannel,
        tunedFreqHz:  s.tunedFreqHz,
        voicePresent: s.voicePresent != 0,
        partCount:    s.partCount,
        packetsSeen:  s.packetsSeen,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  /// Returns list of active DECT parts (up to 8).
  List<DectPart> getParts() {
    if (!isAvailable) return [];
    const maxParts = 8;
    final ptr = calloc<DectPartNative>(maxParts);
    try {
      final count = _nativeGetParts!(ptr, maxParts);
      return List.generate(count, (i) {
        final n = (ptr + i).ref;
        final buf = StringBuffer();
        for (int j = 0; j < 16; j++) {
          final c = n.partId[j];
          if (c == 0) break;
          buf.writeCharCode(c);
        }
        return DectPart(
          rxId:          n.rxId,
          type:          n.type,
          voicePresent:  n.voicePresent != 0,
          qtSynced:      n.qtSynced != 0,
          slot:          n.slot,
          packetsOk:     n.packetsOk,
          packetsBadCrc: n.packetsBadCrc,
          voiceFramesOk: n.voiceFramesOk,
          voiceXcrcFail: n.voiceXcrcFail,
          voiceSkipped:  n.voiceSkipped,
          partId:        buf.toString(),
        );
      });
    } finally {
      calloc.free(ptr);
    }
  }
  /// Start Android AudioTrack player draining the PCM ring buffer (8 kHz mono).
  Future<void> startAudio() async {
    try {
      await _audioChannel.invokeMethod('startAudio');
    } catch (e) {
      debugPrint('DectService.startAudio: $e');
    }
  }

  /// Stop AudioTrack playback.
  Future<void> stopAudio() async {
    try {
      await _audioChannel.invokeMethod('stopAudio');
    } catch (e) {
      debugPrint('DectService.stopAudio: $e');
    }
  }

}
