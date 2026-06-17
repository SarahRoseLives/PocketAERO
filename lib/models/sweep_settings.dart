import 'package:flutter/foundation.dart';

enum SpectrumMode { single, sweep }

@immutable
class SweepSettings {
  final SpectrumMode mode;
  final double startHz;
  final double stopHz;
  final double rbwHz;
  final int framesPerHop;
  final int gainTenths; // 0 = auto

  const SweepSettings({
    this.mode         = SpectrumMode.single,
    this.startHz      = 88_000_000,
    this.stopHz       = 108_000_000,
    this.rbwHz        = 2_400_000,
    this.framesPerHop = 4,
    this.gainTenths   = 0,
  });

  /// Centers of each hop across [startHz, stopHz].
  /// Hops overlap by 25 % (step = 0.75 × rbwHz) so the rolled-off edges of
  /// adjacent hops are blended away by the Hann-window stitching in RadioProvider.
  List<double> get hopCenters {
    final step = rbwHz * 0.75;
    final centers = <double>[];
    double c = startHz + rbwHz / 2;
    while (true) {
      centers.add(c);
      if (c + rbwHz / 2 >= stopHz) break;
      c += step;
    }
    if (centers.isEmpty) centers.add((startHz + stopHz) / 2);
    return centers;
  }

  int get numHops => hopCenters.length;

  SweepSettings copyWith({
    SpectrumMode? mode,
    double? startHz,
    double? stopHz,
    double? rbwHz,
    int? framesPerHop,
    int? gainTenths,
  }) => SweepSettings(
    mode:         mode         ?? this.mode,
    startHz:      startHz      ?? this.startHz,
    stopHz:       stopHz       ?? this.stopHz,
    rbwHz:        rbwHz        ?? this.rbwHz,
    framesPerHop: framesPerHop ?? this.framesPerHop,
    gainTenths:   gainTenths   ?? this.gainTenths,
  );
}
