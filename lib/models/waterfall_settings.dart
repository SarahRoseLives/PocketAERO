// lib/models/waterfall_settings.dart

enum WaterfallColorScheme { viridis, turbo, classic, grayscale }

enum FftSize {
  s512(512, '512'),
  s1024(1024, '1k'),
  s2048(2048, '2k'),
  s4096(4096, '4k');

  final int bins;
  final String label;
  const FftSize(this.bins, this.label);
}

class WaterfallSettings {
  final FftSize fftSize;
  final int sampleRateHz;
  /// Tuner gain in tenths of dB; -1 = auto
  final int gainTenths;
  /// Minimum dBFS for colour mapping (bottom of scale)
  final double minDb;
  /// Maximum dBFS for colour mapping (top of scale)
  final double maxDb;
  final int waterfallRows;
  final WaterfallColorScheme colorScheme;

  const WaterfallSettings({
    this.fftSize       = FftSize.s4096,
    this.sampleRateHz  = 2048000,
    this.gainTenths    = -1,
    this.minDb         = -44.0,
    this.maxDb         = -22.0,
    this.waterfallRows = 250,
    this.colorScheme   = WaterfallColorScheme.viridis,
  });

  bool get autoGain => gainTenths < 0;
  double get gainDb => gainTenths < 0 ? 0.0 : gainTenths / 10.0;

  WaterfallSettings copyWith({
    FftSize? fftSize,
    int? sampleRateHz,
    int? gainTenths,
    double? minDb,
    double? maxDb,
    int? waterfallRows,
    WaterfallColorScheme? colorScheme,
  }) => WaterfallSettings(
    fftSize:       fftSize       ?? this.fftSize,
    sampleRateHz:  sampleRateHz  ?? this.sampleRateHz,
    gainTenths:    gainTenths    ?? this.gainTenths,
    minDb:         minDb         ?? this.minDb,
    maxDb:         maxDb         ?? this.maxDb,
    waterfallRows: waterfallRows ?? this.waterfallRows,
    colorScheme:   colorScheme   ?? this.colorScheme,
  );

  static const List<int> sampleRatesRtl = [
    250000, 1000000, 1024000, 1800000, 1920000, 2048000, 2400000, 3200000,
  ];

  static const List<int> sampleRatesHackRf = [
    2000000, 4000000, 6000000, 8000000, 10000000, 12000000, 16000000, 20000000,
  ];

  // Legacy alias (RTL rates as default)
  static const List<int> sampleRates = sampleRatesRtl;

  static String formatSampleRate(int hz) {
    if (hz >= 1000000) return '${(hz / 1000000.0).toStringAsFixed(hz % 1000000 == 0 ? 0 : 3)} MHz';
    return '${(hz / 1000.0).toStringAsFixed(0)} kHz';
  }
}
