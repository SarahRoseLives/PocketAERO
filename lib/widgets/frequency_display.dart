import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../models/app_theme.dart';
import '../models/waterfall_settings.dart';
import '../services/sdr_backend.dart';
import '../services/sdr_service.dart' show SdrService;

class FrequencyDisplay extends StatelessWidget {
  const FrequencyDisplay({super.key});

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();
    final freq = radio.frequencyHz;

    final displayText = _formatFrequency(freq);

    return Card(
      color: AppTheme.surfaceElevated,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('FREQUENCY', style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.grey[600],
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => showFrequencyKeypad(context, radio),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        displayText,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 52,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryDark,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    _StepButton(icon: Icons.arrow_drop_up, onTap: () => radio.stepFrequency(1000)),
                    _StepButton(icon: Icons.arrow_drop_down, onTap: () => radio.stepFrequency(-1000)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            _FrequencyStepRow(radio: radio),
          ],
        ),
      ),
    );
  }

  String _formatFrequency(double hz) {
    if (hz >= 1_000_000_000) {
      final ghz = hz / 1_000_000_000;
      return '${ghz.toStringAsFixed(6)} GHz';
    } else if (hz >= 1_000_000) {
      final mhz = hz / 1_000_000;
      return '${mhz.toStringAsFixed(6)} MHz';
    } else {
      final khz = hz / 1_000;
      return '${khz.toStringAsFixed(3)} kHz';
    }
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _StepButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 32, color: AppTheme.primary),
      ),
    );
  }
}

class _FrequencyStepRow extends StatelessWidget {
  final RadioProvider radio;
  const _FrequencyStepRow({required this.radio});

  @override
  Widget build(BuildContext context) {
    const steps = [
      (label: '1 Hz', step: 1.0),
      (label: '100 Hz', step: 100.0),
      (label: '1 kHz', step: 1000.0),
      (label: '10 kHz', step: 10000.0),
      (label: '100 kHz', step: 100000.0),
      (label: '1 MHz', step: 1000000.0),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: steps.map((s) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ActionChip(
            label: Text(s.label, style: const TextStyle(fontSize: 12)),
            onPressed: () => radio.stepFrequency(s.step),
            backgroundColor: AppTheme.surfaceElevated,
            side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.4)),
          ),
        )).toList(),
      ),
    );
  }
}

// ── Frequency keypad ────────────────────────────────────────────────────────

Future<void> showFrequencyKeypad(BuildContext context, RadioProvider radio) async {
  final result = await showDialog<double>(
    context: context,
    builder: (context) => FrequencyKeypadDialog(initialFreqHz: radio.frequencyHz),
  );
  if (result != null) {
    radio.setFrequency(result);
  }
}

class FrequencyKeypadDialog extends StatefulWidget {
  final double initialFreqHz;
  const FrequencyKeypadDialog({super.key, required this.initialFreqHz});

  @override
  State<FrequencyKeypadDialog> createState() => FrequencyKeypadDialogState();
}

class FrequencyKeypadDialogState extends State<FrequencyKeypadDialog> {
  late String _input;
  late String _suffix;

  @override
  void initState() {
    super.initState();
    final hz = widget.initialFreqHz;
    if (hz >= 1e6) {
      _suffix = 'MHz';
      _input = (hz / 1e6).toStringAsFixed(4);
    } else {
      _suffix = 'kHz';
      _input = (hz / 1e3).toStringAsFixed(3);
    }
  }

  double get _parsedHz =>
      (double.tryParse(_input) ?? 0) * (_suffix == 'MHz' ? 1e6 : 1e3);

  void _appendChar(String ch) {
    setState(() {
      if (ch == '.' && _input.contains('.')) return;
      if (_input.length >= 10) return;
      if (_input == '0' && ch != '.') {
        _input = ch;
      } else {
        _input += ch;
      }
    });
  }

  void _backspace() {
    setState(() {
      if (_input.length <= 1) {
        _input = '0';
      } else {
        _input = _input.substring(0, _input.length - 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const buttonKeys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0'];
    return Dialog(
      child: SizedBox(
        width: (MediaQuery.of(context).size.width * 0.85).clamp(280.0, 480.0),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Display ──────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$_input $_suffix',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 28,
                    decoration: TextDecoration.underline,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(height: 16),
              // ── Numpad grid ───────────────────────────────────────────────
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.0,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final label in buttonKeys)
                    FilledButton.tonal(
                      onPressed: () => _appendChar(label),
                      child: Text(label, style: const TextStyle(fontSize: 20)),
                    ),
                  FilledButton.tonal(
                    onPressed: _backspace,
                    child: const Icon(Icons.backspace_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // ── MHz / kHz toggle ─────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final s in ['MHz', 'kHz'])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(s),
                        selected: _suffix == s,
                        onSelected: (_) => setState(() => _suffix = s),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // ── Actions ───────────────────────────────────────────────────
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('CANCEL'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _parsedHz),
                    child: const Text('TUNE'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact VU-style meter bar
class SignalMeter extends StatelessWidget {
  final double value;
  final Color color;
  final String label;
  final int segments;

  const SignalMeter({
    super.key,
    required this.value,
    required this.color,
    required this.label,
    this.segments = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.grey[600], letterSpacing: 1.2, fontWeight: FontWeight.w600,
        )),
        const SizedBox(height: 4),
        SizedBox(
          height: 18,
          child: CustomPaint(
            painter: _MeterPainter(value: value, color: color, segments: segments),
            child: Container(),
          ),
        ),
      ],
    );
  }
}

class _MeterPainter extends CustomPainter {
  final double value;
  final Color color;
  final int segments;

  const _MeterPainter({required this.value, required this.color, required this.segments});

  @override
  void paint(Canvas canvas, Size size) {
    final activeCount = (value * segments).round();
    final segW = (size.width - (segments - 1) * 2) / segments;

    for (int i = 0; i < segments; i++) {
      final x = i * (segW + 2);
      final isActive = i < activeCount;
      final segColor = isActive
          ? (i > segments * 0.85 ? Colors.red : (i > segments * 0.7 ? Colors.orange : color))
          : color.withValues(alpha: 0.15);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, segW, size.height),
          const Radius.circular(2),
        ),
        Paint()..color = segColor,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.value != value || old.color != color;
}

/// High-performance spectrum + waterfall display.
///
/// Performance approach:
///  - Spectrum: filled [Path] (downsampled to display width) — 1 drawPath call
///  - Waterfall: async-built [ui.Image] via pixel buffer — 1 drawImageRect call
///  - Repaint driven by [ValueNotifier], no full widget-tree setState in hot path
///  - Pre-computed colormap LUT (256 RGBA entries per scheme)
class WaterfallDisplay extends StatefulWidget {
  final double? zoomBandwidthHz;

  const WaterfallDisplay({
    super.key,
    this.zoomBandwidthHz,
  });

  @override
  State<WaterfallDisplay> createState() => _WaterfallDisplayState();
}

class _WaterfallDisplayState extends State<WaterfallDisplay> {
  double _dragStartFreqHz = 0;
  double _dragStartX = 0;
  double _dragOffsetHz = 0;
  bool _isDraggingRedLine = false;
  static const _redLineGrabRadius = 30.0;

  // Ring buffer of FFT rows
  late List<Float32List> _rows;
  StreamSubscription<Float32List>? _sub;
  bool _hasRealData = false;

  // Latest spectrum row for the line display
  Float32List? _spectrum;

  // Rendered waterfall image
  ui.Image? _wfImage;
  bool _imageBuilding = false;
  int _lastImageBuildMs = 0;
  static const _imageIntervalMs = 40; // max ~25fps image builds

  // ValueNotifiers drive repaints without full widget rebuild
  final _specNotifier = ValueNotifier<int>(0);
  final _wfNotifier   = ValueNotifier<int>(0);

  // Cached mock data (generated once)
  static final _mockSpectrum = _buildMockSpectrum();
  static final List<Float32List> _mockRows = _buildMockRows();

  static Float32List _buildMockSpectrum() {
    final rng = math.Random(42);
    const n = 512;
    final d = Float32List(n);
    for (int i = 0; i < n; i++) {
      double v = -90 + rng.nextDouble() * 8;
      if (i > 205 && i < 225) v += 28 * (1 - (i - 215).abs() / 10.0);
      if (i > 300 && i < 316) v += 18 * (1 - (i - 308).abs() / 8.0);
      d[i] = v;
    }
    return d;
  }

  static List<Float32List> _buildMockRows() {
    final rng = math.Random(7);
    return List.generate(60, (r) {
      final row = Float32List(_mockSpectrum.length);
      for (int i = 0; i < row.length; i++) {
        row[i] = _mockSpectrum[i] + (rng.nextDouble() - 0.5) * 6;
      }
      return row;
    });
  }

  DateTime _lastTuneTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const _tuneIntervalMs = 100; // max 10 Hz tuning during drag

  int get _liveSampleRate {
    final radio = context.read<RadioProvider>();
    if (radio.backend is SdrService) {
      final live = (radio.backend as SdrService).ffi.getSampleRate();
      if (live > 0) return live;
    }
    return radio.wfSettings.sampleRateHz;
  }

  void _onDragStart(DragStartDetails details, BoxConstraints constraints) {
    _dragStartX = details.localPosition.dx;
    _dragStartFreqHz = context.read<RadioProvider>().frequencyHz;
    _isDraggingRedLine =
        (details.localPosition.dx - constraints.maxWidth / 2).abs() < _redLineGrabRadius;
  }

  void _onDragUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    final sr = _liveSampleRate.toDouble();
    final spanHz = widget.zoomBandwidthHz ?? sr;
    final hzPerPixel = spanHz / constraints.maxWidth;

    if (_isDraggingRedLine) {
      _dragOffsetHz = (constraints.maxWidth / 2 - details.localPosition.dx) * hzPerPixel;
      _specNotifier.value++;
    } else {
      final dx = details.localPosition.dx - _dragStartX;
      final radio = context.read<RadioProvider>();
      radio.setFrequency(_dragStartFreqHz - dx * hzPerPixel);
    }
  }

  @override
  void initState() {
    super.initState();
    _resetRows(150);
    // If returning from a decoder screen, reopen spectrum immediately so we
    // don't show mock data while waiting for the AppShell nav handler.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final backend = context.read<RadioProvider>().backend;
      if (backend is SdrService && backend.needsSpectrumReopen) {
        backend.reopenForSpectrum();
      }
    });
  }

  void _resetRows(int maxRows) {
    _rows = [];
    for (var r in _mockRows) {
      if (_rows.length < maxRows) _rows.add(r);
    }
  }

  SdrBackend? _trackedBackend;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final backend = context.read<RadioProvider>().backend;
    if (backend != _trackedBackend) {
      _sub?.cancel();
      _trackedBackend = backend;
      if (backend != null) {
        _sub = backend.spectrumStream.listen(_onFrame);
      }
    }
  }

  void _onFrame(Float32List frame) {
    if (!mounted) return;
    final maxRows = context.read<RadioProvider>().wfSettings.waterfallRows;

    _hasRealData = true;
    _spectrum = frame;
    // Clear mock rows (512 bins) when real FFT (2048 bins) first arrives
    if (_rows.isNotEmpty && _rows.first.length != frame.length) {
      _rows.clear();
    }
    _rows.insert(0, frame);
    if (_rows.length > maxRows) _rows.removeLast();

    // Trigger spectrum repaint immediately
    _specNotifier.value++;

    // Throttle waterfall image builds
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_imageBuilding && (now - _lastImageBuildMs) >= _imageIntervalMs) {
      _scheduleImageBuild(frame.length, maxRows);
    }
  }

  void _scheduleImageBuild(int bins, int maxRows) {
    _imageBuilding = true;
    _lastImageBuildMs = DateTime.now().millisecondsSinceEpoch;

    final settings  = context.read<RadioProvider>().wfSettings;
    List<Float32List> rowsSnap = List<Float32List>.from(_rows);
    final minDb     = settings.minDb;
    final maxDb     = settings.maxDb;
    final scheme    = settings.colorScheme;
    final imgW      = (MediaQuery.of(context).size.width * 0.95).ceil().clamp(256, 2048);
    final imgH      = rowsSnap.length.clamp(1, maxRows);

    // If zoomed, crop rows to only the centre portion
    final zoomHz = widget.zoomBandwidthHz;
    if (zoomHz != null && rowsSnap.isNotEmpty) {
      final sr = _liveSampleRate.toDouble();
      final ratio = (zoomHz / sr).clamp(0.01, 1.0);
      /* Some rows may have different lengths (mock 512 vs real 2048).
       * Use the minimum length so the crop doesn't index out of bounds. */
      int rLen = rowsSnap.first.length;
      for (final r in rowsSnap) {
        if (r.length < rLen) rLen = r.length;
      }
      final cropLo = ((1.0 - ratio) / 2.0 * rLen).round().clamp(0, rLen - 1);
      final cropHi = ((1.0 + ratio) / 2.0 * rLen).round().clamp(1, rLen);
      rowsSnap = rowsSnap.map((r) {
        if (r.length == rLen) {
          return Float32List.fromList(r.sublist(cropLo, cropHi));
        }
        /* Different-length row — resample to match cropped size */
        final cropped = Float32List(cropHi - cropLo);
        final scale = r.length / rLen;
        for (int j = 0; j < cropped.length; j++) {
          cropped[j] = r[((cropLo + j) * scale).round().clamp(0, r.length - 1)];
        }
        return cropped;
      }).toList();
    }

    _buildWaterfallImage(rowsSnap, imgW, imgH, minDb, maxDb, scheme)
        .then((img) {
      if (!mounted) return;
      _wfImage?.dispose();
      _wfImage = img;
      _imageBuilding = false;
      _wfNotifier.value++;
    });
  }

  static Future<ui.Image> _buildWaterfallImage(
    List<Float32List> rows, int w, int h,
    double minDb, double maxDb,
    WaterfallColorScheme scheme,
  ) async {
    final lut = _buildLut(scheme);
    final pixels = Uint8List(w * h * 4);
    final range  = (maxDb - minDb).clamp(1.0, 200.0);

    for (int r = 0; r < h && r < rows.length; r++) {
      final row  = rows[r];
      final rLen = row.length;
      final base = r * w * 4;
      for (int x = 0; x < w; x++) {
        final binIdx = (x * rLen / w).toInt().clamp(0, rLen - 1);
        final v  = ((row[binIdx] - minDb) / range).clamp(0.0, 1.0);
        final ci = (v * 255).toInt();
        final c  = lut[ci];
        final pi = base + x * 4;
        pixels[pi]     = (c >> 16) & 0xFF; // R
        pixels[pi + 1] = (c >> 8)  & 0xFF; // G
        pixels[pi + 2] =  c        & 0xFF; // B
        pixels[pi + 3] = 255;              // A
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        pixels, w, h, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// Pre-compute 256-entry RGB colormap (packed as 0xRRGGBB).
  static List<int> _buildLut(WaterfallColorScheme scheme) {
    return List.generate(256, (i) {
      final t = i / 255.0;
      switch (scheme) {
        case WaterfallColorScheme.viridis:
          return _viridis(t);
        case WaterfallColorScheme.turbo:
          return _turbo(t);
        case WaterfallColorScheme.grayscale:
          final v = (t * 255).round();
          return (v << 16) | (v << 8) | v;
      }
    });
  }

  static int _viridis(double t) {
    // Approximation of matplotlib viridis
    final r = (0.267 + 1.619 * t - 2.190 * t * t + 0.851 * t * t * t).clamp(0.0, 1.0);
    final g = (0.004 + 1.363 * t - 0.554 * t * t - 0.340 * t * t * t).clamp(0.0, 1.0);
    final b = (0.329 + 1.496 * t - 3.166 * t * t + 1.823 * t * t * t).clamp(0.0, 1.0);
    return (_f(r) << 16) | (_f(g) << 8) | _f(b);
  }

  static int _turbo(double t) {
    // Approximation of Google turbo colormap
    final r = (0.139 + 4.189 * t - 8.540 * t * t + 5.106 * t * t * t).clamp(0.0, 1.0);
    final g = (0.097 + 3.671 * t - 3.956 * t * t + 0.218 * t * t * t).clamp(0.0, 1.0);
    final b = (0.453 + 3.107 * t - 8.010 * t * t + 5.293 * t * t * t).clamp(0.0, 1.0);
    return (_f(r) << 16) | (_f(g) << 8) | _f(b);
  }

  static int _f(double v) => (v * 255).round().clamp(0, 255);

  @override
  void dispose() {
    _sub?.cancel();
    _wfImage?.dispose();
    _specNotifier.dispose();
    _wfNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radio    = context.watch<RadioProvider>();
    final isLive   = _hasRealData;
    final wfRows   = radio.wfSettings.waterfallRows;

    // Build mock waterfall when no real data yet
    if (!isLive && _wfImage == null && !_imageBuilding) {
      _scheduleImageBuild(_mockSpectrum.length, wfRows);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Row(
              children: [
                Text('SPECTRUM / WATERFALL',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Colors.grey[600],
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    )),
                const Spacer(),
                Text(isLive ? 'LIVE' : '',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: isLive ? Colors.green[700] : Colors.grey[400],
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    )),
              ],
            ),
            const SizedBox(height: 8),

            // ── Display ─────────────────────────────────────────────────────
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  onPanStart: (d) => _onDragStart(d, constraints),
                  onPanUpdate: (d) => _onDragUpdate(d, constraints),
                  onPanEnd: (_) {
                    if (_isDraggingRedLine && _dragOffsetHz != 0) {
                      final radio = context.read<RadioProvider>();
                      final targetFreq = _dragStartFreqHz - _dragOffsetHz;
                      debugPrint('DRAG_END: startFreq=${_dragStartFreqHz.toStringAsFixed(0)} '
                          'offsetHz=${_dragOffsetHz.toStringAsFixed(0)} '
                          'targetFreq=${targetFreq.toStringAsFixed(0)}');
                      radio.setFrequency(targetFreq);
                    }
                    _dragOffsetHz = 0;
                    _isDraggingRedLine = false;
                    _specNotifier.value++;
                  },
                  onTapUp: (d) {
                    final w = constraints.maxWidth;
                    final radio = context.read<RadioProvider>();
                    if (d.localPosition.dx < w * 0.3) {
                      radio.setFrequency(radio.frequencyHz - 1000);
                    } else if (d.localPosition.dx > w * 0.7) {
                      radio.setFrequency(radio.frequencyHz + 1000);
                    }
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: RepaintBoundary(
                      child: _WaterfallCanvas(
                        spectrumGetter:  () => _spectrum ?? _mockSpectrum,
                        wfImageNotifier: _wfNotifier,
                        specNotifier:   _specNotifier,
                        wfImageGetter:  () => _wfImage,
                        settings:       radio.wfSettings,
                        centerFreqHz:   radio.frequencyHz.round(),
                        zoomBandwidthHz: widget.zoomBandwidthHz,
                        ncoOffsetGetter: () => _dragOffsetHz,
                        liveSampleRate:  _liveSampleRate,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Canvas widget ───────────────────────────────────────────────────────────

class _WaterfallCanvas extends StatelessWidget {
  final Float32List Function() spectrumGetter;
  final ValueNotifier<int> wfImageNotifier;
  final ValueNotifier<int> specNotifier;
  final ui.Image? Function() wfImageGetter;
  final WaterfallSettings settings;
  final int centerFreqHz;
  final double? zoomBandwidthHz;
  final double Function() ncoOffsetGetter;
  final int liveSampleRate;

  const _WaterfallCanvas({
    required this.spectrumGetter,
    required this.wfImageNotifier,
    required this.specNotifier,
    required this.wfImageGetter,
    required this.settings,
    required this.centerFreqHz,
    this.zoomBandwidthHz,
    required this.ncoOffsetGetter,
    required this.liveSampleRate,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return Stack(children: [
        // Waterfall (low frequency repaints — image changes)
        ValueListenableBuilder<int>(
          valueListenable: wfImageNotifier,
          builder: (context, _, child) => CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _WfImagePainter(image: wfImageGetter()),
            isComplex: true,
          ),
        ),
        // Spectrum overlay — calls spectrumGetter() for fresh data every tick
        ValueListenableBuilder<int>(
          valueListenable: specNotifier,
          builder: (context, _, child) => CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _SpectrumLinePainter(
              spectrum: spectrumGetter(),
              settings: settings,
              centerFreqHz: centerFreqHz,
              zoomBandwidthHz: zoomBandwidthHz,
              ncoOffsetHz: ncoOffsetGetter(),
              liveSampleRate: liveSampleRate,
            ),
            willChange: true,
          ),
        ),
      ]);
    });
  }
}

// ── Waterfall image painter (1 draw call) ──────────────────────────────────

class _WfImagePainter extends CustomPainter {
  final ui.Image? image;
  const _WfImagePainter({this.image});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0A0E1A));
    final img = image;
    if (img == null) return;
    final specH = size.height * 0.38;
    final wfRect = Rect.fromLTWH(0, specH + 4, size.width, size.height - specH - 4);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      wfRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_WfImagePainter old) => old.image != image;
}

// ── Spectrum line painter (filled Path, downsampled) ───────────────────────

class _SpectrumLinePainter extends CustomPainter {
  final Float32List? spectrum;
  final WaterfallSettings settings;
  final int centerFreqHz;
  final double? zoomBandwidthHz;
  final double ncoOffsetHz;
  final int liveSampleRate;

  const _SpectrumLinePainter({
    required this.spectrum,
    required this.settings,
    required this.centerFreqHz,
    this.zoomBandwidthHz,
    this.ncoOffsetHz = 0,
    required this.liveSampleRate,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (spectrum == null || spectrum!.isEmpty) return;

    const freqAxisH = 16.0;  // height reserved for frequency labels
    const specTopY  = 0.0;
    final specH = size.height * 0.38 - freqAxisH;
    final minDb = settings.minDb;
    final maxDb = settings.maxDb;
    final range = (maxDb - minDb).clamp(1.0, 200.0);

    // ── dB grid lines ────────────────────────────────────────────────────────
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 0.5;
    final gridDbStep = range > 60 ? 20.0 : 10.0;
    for (double db = (minDb / gridDbStep).ceil() * gridDbStep;
         db <= maxDb;
         db += gridDbStep) {
      final y = specH * (1.0 - (db - minDb) / range);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      _drawLabel(canvas, '${db.toInt()}', Offset(4, y - 9),
          const TextStyle(color: Colors.white24, fontSize: 8));
    }

    // ── Spectrum fill (max-pooling per display column) ────────────────────────
    final zoomHz = zoomBandwidthHz;
    final sr     = liveSampleRate.toDouble();
    final spanHz = zoomHz ?? sr;
    final data   = spectrum!;
    final int N  = data.length;

    // When zoomed, only render the center portion of the spectrum
    int binLo = 0, binHi = N;
    if (zoomHz != null) {
      final double zoomRatio = spanHz / sr;
      binLo = ((1.0 - zoomRatio) / 2.0 * N).round().clamp(0, N - 1);
      binHi = ((1.0 + zoomRatio) / 2.0 * N).round().clamp(1, N);
    }
    final int zoomBins = binHi - binLo;

    final displayW = size.width.toInt().clamp(64, 4096);
    final path = Path();
    path.moveTo(0, specH);

    for (int x = 0; x <= displayW; x++) {
      final double frac = x / displayW;
      double idx = binLo + frac * zoomBins;
      int lo = idx.toInt().clamp(0, N - 2);
      int hi = lo + 1;
      double t  = idx - lo;
      double peak = data[lo] * (1.0 - t) + data[hi] * t;
      final v = ((peak - minDb) / range).clamp(0.0, 1.0);
      path.lineTo(x * size.width / displayW, specH * (1.0 - v));
    }

    path.lineTo(size.width, specH);
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 0),
          Offset(0, specH),
          [const Color(0xFF00E5FF), const Color(0xFF004D66)],
        )
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Baseline separator
    canvas.drawLine(
      Offset(0, specH),
      Offset(size.width, specH),
      Paint()..color = Colors.white24..strokeWidth = 1,
    );

    // dB scale labels
    _drawLabel(canvas, '${maxDb.toInt()} dB', Offset(size.width - 44, 2),
        const TextStyle(color: Colors.white38, fontSize: 8));
    _drawLabel(canvas, '${minDb.toInt()} dB', Offset(size.width - 44, specH - 10),
        const TextStyle(color: Colors.white38, fontSize: 8));

    // ── Frequency axis ────────────────────────────────────────────────────────
    final axisY = specH + 1;
    final freqStart = centerFreqHz - spanHz / 2;
    final freqEnd   = centerFreqHz + spanHz / 2;

    canvas.drawLine(
      Offset(0, axisY),
      Offset(size.width, axisY),
      Paint()..color = Colors.white12..strokeWidth = 0.5,
    );

    // Frequency labels
    final spanMhz = spanHz / 1e6;
    final stepMhz = spanMhz <= 0.5 ? 0.1
                  : spanMhz <= 1.0 ? 0.25
                  : spanMhz <= 2.0 ? 0.5
                  : spanMhz <= 4.0 ? 1.0
                  : 2.0;
    final stepHz = stepMhz * 1e6;
    final firstTick = (freqStart / stepHz).ceil() * stepHz;
    for (double f = firstTick; f <= freqEnd; f += stepHz) {
      final xPos = (f - freqStart) / spanHz * size.width;
      canvas.drawLine(Offset(xPos, axisY), Offset(xPos, axisY + 3),
          Paint()..color = Colors.white38..strokeWidth = 0.5);
      final label = _formatFreqLabel(f);
      _drawLabel(canvas, label, Offset(xPos - 14, axisY + 3),
          const TextStyle(color: Colors.white54, fontSize: 8));
    }

    // ── Centre marker ──────────────────────────────────────────────────────────
    final pixelsPerHz = size.width / spanHz;
    final cx = size.width / 2 - ncoOffsetHz * pixelsPerHz;
    final lineColor = zoomHz != null
        ? const Color(0xFFFF0000)
        : const Color(0xFFFF6B00);
    canvas.drawLine(Offset(cx, 0), Offset(cx, axisY),
        Paint()..color = lineColor..strokeWidth = 2.5..style = PaintingStyle.stroke);
  }

  static void _drawLabel(Canvas canvas, String text, Offset pos, TextStyle style) {
    final span = TextSpan(text: text, style: style);
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, pos);
  }

  static String _formatFreqLabel(double hz) {
    if (hz.abs() >= 1e9) return '${(hz / 1e9).toStringAsFixed(1)}G';
    if (hz.abs() >= 1e6) {
      final mhz = hz / 1e6;
      return mhz == mhz.roundToDouble() ? '${mhz.toInt()}M' : '${mhz.toStringAsFixed(1)}M';
    }
    if (hz.abs() >= 1e3) return '${(hz / 1e3).toStringAsFixed(0)}k';
    return '${hz.toInt()}';
  }

  @override
  bool shouldRepaint(_SpectrumLinePainter old) =>
      old.spectrum != spectrum ||
      old.settings != settings ||
      old.centerFreqHz != centerFreqHz ||
      old.zoomBandwidthHz != zoomBandwidthHz ||
      old.ncoOffsetHz != ncoOffsetHz ||
      old.liveSampleRate != liveSampleRate;
}

// (Spectrum controls are in SpectrumControls widget in radio_controls.dart)
