import 'package:flutter/foundation.dart';
import '../models/sdr_type.dart';
import 'sdr_service.dart' show SdrState, SdrDeviceInfo;
/// Shared interface for all SDR hardware backends (RTL-SDR, HackRF, PlutoSDR).
abstract class SdrBackend extends ChangeNotifier {
  SdrState get state;
  SdrType? get connectedType;
  String?  get error;
  bool     get isRunning;
  List<SdrDeviceInfo> get devices;
  double   get signalDb;
  Stream<Float32List> get spectrumStream;
  Stream<Float32List> get fftStream;

  Future<void> scanDevices();
  Future<void> connect(SdrDeviceInfo device, {int fftSize = 2048});
  Future<void> disconnect();
  void setFrequency(int hz);
  void setSampleRate(int sps);
  /// [tenthsDb] = gain in tenths of a dB, or -1 for auto.
  void setGain(int tenthsDb);
}
