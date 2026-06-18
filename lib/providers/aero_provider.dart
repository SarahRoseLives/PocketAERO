import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/aero_service.dart';
import '../services/sdr_ffi.dart';
import '../services/sdr_service.dart';
import '../providers/radio_provider.dart';

class _SatEntry {
  final String name;
  final double lonDeg;
  const _SatEntry(this.name, this.lonDeg);
}

const _satellites = [
  _SatEntry('I-4 F3 Americas',  -98.0),
  _SatEntry('I-4 F2 EMEA',       64.0),
  _SatEntry('I-4 F1 APAC',      143.5),
  _SatEntry('Alphasat',           25.0),
];

String _identifySatellite(double lonDeg) {
  String best = 'Unknown';
  double bestDist = 999;
  for (final s in _satellites) {
    double d = (lonDeg - s.lonDeg).abs();
    if (d > 180) d = 360 - d;
    if (d < bestDist) { bestDist = d; best = s.name; }
  }
  return best;
}

final _satIdRe = RegExp(r'SatID=(\d+)');
final _satLonRe = RegExp(r'Long=([0-9.]+)([EW])');

class AircraftEntry {
  final String aesId;
  final Set<int> gesIds = {};
  final Set<String> messageTypes = {};
  int messageCount = 0;
  DateTime firstSeen;
  DateTime lastSeen;
  String lastSuType = '';

  AircraftEntry({required this.aesId})
      : firstSeen = DateTime.now(),
        lastSeen = DateTime.now();

  void update(AeroMessage msg) {
    lastSeen = DateTime.now();
    messageCount++;
    if (msg.gesId > 0) gesIds.add(msg.gesId);
    final t = msg.callType.isNotEmpty ? msg.callType : msg.suType;
    messageTypes.add(t);
    lastSuType = t;
  }
}

class AeroProvider extends ChangeNotifier {
  final AeroService _aeroService;

  bool _aeroActive = false;
  bool _biasTeeOn = false;
  bool _recording = false;
  bool _recordingRaw = false;
  double _ncoOffset = 0;
  double _symbolRate = 10500;
  bool _voiceFollow = false;
  double _prevPchanFreq = 0;
  double _prevPchanRate = 0;
  String _satelliteName = '';
  double _satelliteLon = 0;
  int _satelliteId = -1;

  final List<AeroMessage> _messages = [];
  final List<AeroMessage> _acarsMessages = [];
  StreamSubscription<AeroMessage>? _msgSub;
  int _totalAcars = 0;
  int _totalPchan = 0;
  int _totalCalls = 0;
  final Map<String, AircraftEntry> _aircraft = {};

  static const int _maxAcars = 500;
  static const int _maxPchan = 300;

  AeroProvider({required AeroService service}) : _aeroService = service {
    _msgSub = _aeroService.messages.listen(_onMessage);
  }

  int get totalAcars => _totalAcars;
  int get totalPchan => _totalPchan;
  int get totalCalls => _totalCalls;

  /// ACARS-only messages (never trimmed by PCHAN flood)
  List<AeroMessage> get acarsMessages => _acarsMessages;

  // ── Message handling ─────────────────────────────────────────────────

  void _onMessage(AeroMessage msg) {
    if (msg.suType == 'ACARS') {
      _totalAcars++;
      _acarsMessages.add(msg);
      if (_acarsMessages.length > _maxAcars) {
        _acarsMessages.removeRange(0, 100);
      }
      debugPrint('ACARS_IN: aes=${msg.aesId} len=${msg.length} total=$_totalAcars buf=${_acarsMessages.length}');
    } else if (msg.suType == 'PCHAN' || msg.suType == 'VASSIGN') {
      _totalPchan++;
      if (msg.callType == 'SAT_ID') {
        final idM = _satIdRe.firstMatch(msg.hexBytes);
        final lonM = _satLonRe.firstMatch(msg.hexBytes);
        if (lonM != null) {
          double lon = double.tryParse(lonM.group(1)!) ?? 0;
          if (lonM.group(2) == 'W') lon = -lon;
          _satelliteLon = lon;
          _satelliteId = int.tryParse(idM?.group(1) ?? '') ?? -1;
          _satelliteName = _identifySatellite(lon);
          debugPrint('SAT_AUTO_ID: id=$_satelliteId lon=$lon → $_satelliteName');
        }
      }
    } else if (msg.suType == 'CALL') {
      _totalCalls++;
    }

    _messages.add(msg);
    if (_messages.length > 500) {
      _messages.removeRange(0, 200);
    }

    if (msg.aesId.isNotEmpty && msg.aesId != '000000') {
      _aircraft.putIfAbsent(msg.aesId, () => AircraftEntry(aesId: msg.aesId));
      _aircraft[msg.aesId]!.update(msg);
    }

    notifyListeners();
  }

  // ── Getters ──────────────────────────────────────────────────────────

  bool get aeroActive => _aeroActive;
  bool get biasTeeOn => _biasTeeOn;
  bool get recording => _recording;
  bool get recordingRaw => _recordingRaw;
  double get ncoOffset => _ncoOffset;
  double get symbolRate => _symbolRate;
  bool get voiceFollow => _voiceFollow;
  double get prevPchanFreq => _prevPchanFreq;
  AeroService get service => _aeroService;
  List<AeroMessage> get messages => _messages;
  String get satelliteName => _satelliteName;
  double get satelliteLon => _satelliteLon;
  int get satelliteId => _satelliteId;
  Map<String, AircraftEntry> get aircraft => _aircraft;

  // ── AERO toggle ──────────────────────────────────────────────────────

  void toggleAero(BuildContext context) {
    _aeroActive = !_aeroActive;
    if (_aeroActive) {
      _aeroService.start();
      SdrFfi.instance.setAeroOffset(_ncoOffset);
      SdrFfi.instance.setAeroSymbolRate(_symbolRate);
      SdrFfi.instance.setAeroOffsetCommit(_ncoOffset);
      _snack(context, 'AERO decoder started');
    } else {
      _aeroService.stop();
      _ncoOffset = 0;
      _prevPchanFreq = 0; _prevPchanRate = 0;
      _snack(context, 'AERO decoder stopped');
    }
    notifyListeners();
    context.read<RadioProvider>().notifyListeners();
  }

  void stopAero(BuildContext context) {
    if (!_aeroActive) return;
    _aeroActive = false;
    _aeroService.stop();
    _ncoOffset = 0;
    _prevPchanFreq = 0; _prevPchanRate = 0;
    _snack(context, 'AERO decoder stopped');
    notifyListeners();
    context.read<RadioProvider>().notifyListeners();
  }

  // ── Bias tee ─────────────────────────────────────────────────────────

  void toggleBiasTee(BuildContext context) {
    _biasTeeOn = !_biasTeeOn;
    SdrFfi.instance.setBiasTee(_biasTeeOn);
    _snack(context, 'Bias Tee ${_biasTeeOn ? "ON" : "OFF"}');
    notifyListeners();
  }

  // ── Symbol rate ──────────────────────────────────────────────────────

  void setSymbolRate(double rate, BuildContext context) {
    _symbolRate = rate;
    SdrFfi.instance.setAeroSymbolRate(_symbolRate);
    SdrFfi.instance.setAeroOffset(_ncoOffset);
    SdrFfi.instance.setAeroOffsetCommit(_ncoOffset);
    _snack(context, 'Symbol rate: ${rate.toInt()} baud');
    notifyListeners();
    context.read<RadioProvider>().notifyListeners();
  }

  // ── NCO offset ───────────────────────────────────────────────────────

  void adjustNco(double delta, BuildContext context) {
    _setNco(_ncoOffset + delta);
    _snack(context, 'NCO offset: ${_ncoOffset.toInt()} Hz');
  }

  void setNcoOffset(double hz) {
    _setNco(hz);
  }

  void commitNcoOffset() {
    SdrFfi.instance.setAeroOffsetCommit(_ncoOffset);
  }

  void _setNco(double hz) {
    _ncoOffset = hz.clamp(-200000, 200000);
    SdrFfi.instance.setAeroOffset(_ncoOffset);
    notifyListeners();
  }

  // ── Voice follow ─────────────────────────────────────────────────────

  void setVoiceFollow(bool v) {
    _voiceFollow = v;
    notifyListeners();
  }

  void handleVoiceAssign(AeroMessage msg, RadioProvider radio) {
    if (!_voiceFollow || msg.callType != 'C_ASSIGN') return;
    _prevPchanFreq = radio.frequencyHz;
    _prevPchanRate = _symbolRate;
    _aeroService.onVoiceAssign(msg, radio.frequencyHz.round(), _symbolRate);
    _symbolRate = 8400.0;
    SdrFfi.instance.setAeroSymbolRate(8400.0);
    radio.setFrequency(msg.callRxFreq.toDouble());
    notifyListeners();
  }

  void handleVoiceRevert(RadioProvider radio) {
    if (_prevPchanFreq > 0) {
      radio.setFrequency(_prevPchanFreq);
      _prevPchanFreq = 0;
    }
    if (_prevPchanRate > 0) {
      _symbolRate = _prevPchanRate;
      SdrFfi.instance.setAeroSymbolRate(_prevPchanRate);
      _prevPchanRate = 0;
    }
    _aeroService.revertVoiceFollow();
    notifyListeners();
  }

  // ── Recording ────────────────────────────────────────────────────────

  void toggleRecording(BuildContext context) {
    _recording = !_recording;
    if (_recording) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '/storage/emulated/0/Download/aero_iq_$ts.wav';
      final pathPtr = path.toNativeUtf8();
      final r = SdrFfi.instance.startAeroRecording(pathPtr);
      malloc.free(pathPtr);
      if (r == 0) {
        _snack(context, 'Recording IQ to Downloads...');
      } else {
        _recording = false;
        _snackErr(context, 'Recording failed (permissions?)');
      }
    } else {
      SdrFfi.instance.stopAeroRecording();
      _snack(context, 'Recording saved to Downloads');
    }
    notifyListeners();
  }

  void toggleRecordingRaw(BuildContext context, RadioProvider radio) {
    _recordingRaw = !_recordingRaw;
    if (_recordingRaw) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final mhz = (radio.frequencyHz / 1e6).toStringAsFixed(3);
      final path = '/storage/emulated/0/Download/aero_raw_${mhz}MHz_$ts.wav';
      final pathPtr = path.toNativeUtf8();
      final r = SdrFfi.instance.startAeroRecordingRaw(pathPtr);
      malloc.free(pathPtr);
      if (r == 0) {
        _snack(context, 'Recording RAW at $mhz MHz...');
      } else {
        _recordingRaw = false;
        _snackErr(context, 'RAW recording failed');
      }
    } else {
      SdrFfi.instance.stopAeroRecordingRaw();
      _snack(context, 'RAW recording saved to Downloads');
    }
    notifyListeners();
  }

  Future<void> loadWavFile(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.first.path;
      if (path == null) { _snackErr(context, 'No path'); return; }
      _snack(context, 'Loading: $path');
      _aeroService.stop();
      _aeroService.start();
      _aeroActive = true;
      notifyListeners();
      final pathPtr = path.toNativeUtf8();
      SdrFfi.instance.loadWavAero(pathPtr);
      malloc.free(pathPtr);
      _snack(context, 'WAV decode complete');
    } catch (e) {
      _snackErr(context, 'Error: $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  void _snack(BuildContext context, String msg) {
    if (!kDebugMode || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _snackErr(BuildContext context, String msg) {
    if (!kDebugMode || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg),
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 2)));
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    super.dispose();
  }
}
