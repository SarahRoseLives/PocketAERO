import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/sweep_settings.dart';

class PanoramicSpectrum extends StatefulWidget {
  final Float32List? spectrum;
  final Float32List? peakHold;
  final SweepSettings settings;
  final double minDb;
  final double maxDb;

  const PanoramicSpectrum({
    super.key,
    required this.spectrum,
    required this.peakHold,
    required this.settings,
    this.minDb = -90,
    this.maxDb = -10,
  });

  @override
  State<PanoramicSpectrum> createState() => _PanoramicSpectrumState();
}

class _PanoramicSpectrumState extends State<PanoramicSpectrum> {
  final _scrollController = ScrollController();
  final List<Float32List> _rows = [];
  ui.Image? _wfImage;
  bool _imageBuilding = false;
  static const _maxRows = 120;

  // Viridis-inspired colormap: black → purple → blue → teal → green → yellow
  static final Uint8List _lut = _buildLut();

  static Uint8List _buildLut() {
    const stops = [
      [0.00,   0,   0,   0],
      [0.20,  68,   1,  84],
      [0.40,  59,  82, 139],
      [0.60,  33, 145, 140],
      [0.80,  94, 201,  98],
      [1.00, 253, 231,  37],
    ];
    final lut = Uint8List(256 * 3);
    for (int i = 0; i < 256; i++) {
      final t   = i / 255.0;
      final seg = (t * (stops.length - 1)).floor().clamp(0, stops.length - 2);
      final f   = t * (stops.length - 1) - seg;
      final a   = stops[seg], b = stops[seg + 1];
      lut[i * 3]     = ((a[1] + (b[1] - a[1]) * f)).round().clamp(0, 255);
      lut[i * 3 + 1] = ((a[2] + (b[2] - a[2]) * f)).round().clamp(0, 255);
      lut[i * 3 + 2] = ((a[3] + (b[3] - a[3]) * f)).round().clamp(0, 255);
    }
    return lut;
  }

  @override
  void didUpdateWidget(PanoramicSpectrum old) {
    super.didUpdateWidget(old);
    if (widget.spectrum != null && widget.spectrum != old.spectrum) {
      _addRow(widget.spectrum!);
    }
  }

  void _addRow(Float32List row) {
    if (_rows.length >= _maxRows) _rows.removeAt(0);
    _rows.add(Float32List.fromList(row));
    if (!_imageBuilding) _buildWaterfallImage();
  }

  Future<void> _buildWaterfallImage() async {
    if (_rows.isEmpty) return;
    _imageBuilding = true;
    final rows   = List<Float32List>.from(_rows);
    final nBins  = rows.first.length;
    final nRows  = rows.length;
    final minDb  = widget.minDb;
    final dbSpan = widget.maxDb - minDb;
    final pixels = Uint8List(nRows * nBins * 4);

    for (int r = 0; r < nRows; r++) {
      final row  = rows[nRows - 1 - r];
      final base = r * nBins;
      for (int c = 0; c < nBins; c++) {
        final t  = ((row[c] - minDb) / dbSpan).clamp(0.0, 1.0);
        final ci = (t * 255).round();
        final p  = (base + c) * 4;
        pixels[p]     = _lut[ci * 3];
        pixels[p + 1] = _lut[ci * 3 + 1];
        pixels[p + 2] = _lut[ci * 3 + 2];
        pixels[p + 3] = 255;
      }
    }

    ui.decodeImageFromPixels(pixels, nBins, nRows, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) { _imageBuilding = false; return; }
      setState(() {
        _wfImage?.dispose();
        _wfImage = img;
        _imageBuilding = false;
      });
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _wfImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final numHops    = widget.settings.numHops;
    final minWidth   = (numHops * 80).toDouble();

    return LayoutBuilder(builder: (context, constraints) {
      final displayWidth = math.max(constraints.maxWidth, minWidth);
      final displayHeight = constraints.maxHeight;
      // Spectrum panel: top half; Waterfall panel: bottom half
      final specH = (displayHeight * 0.42).floorToDouble();
      final wfH   = displayHeight - specH;

      return SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: displayWidth,
          height: displayHeight,
          child: Column(
            children: [
              // ── Spectrum panel ───────────────────────────────────────────
              SizedBox(
                width: displayWidth,
                height: specH,
                child: CustomPaint(
                  painter: _SpectrumPainter(
                    spectrum: widget.spectrum,
                    peakHold: widget.peakHold,
                    settings: widget.settings,
                    minDb:    widget.minDb,
                    maxDb:    widget.maxDb,
                  ),
                ),
              ),
              // ── Waterfall panel ──────────────────────────────────────────
              SizedBox(
                width: displayWidth,
                height: wfH,
                child: CustomPaint(
                  painter: _WaterfallPainter(
                    wfImage:  _wfImage,
                    settings: widget.settings,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

// ── Spectrum panel painter ────────────────────────────────────────────────────

class _SpectrumPainter extends CustomPainter {
  final Float32List? spectrum;
  final Float32List? peakHold;
  final SweepSettings settings;
  final double minDb;
  final double maxDb;

  static const _axisH = 18.0;

  _SpectrumPainter({
    required this.spectrum,
    required this.peakHold,
    required this.settings,
    required this.minDb,
    required this.maxDb,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final drawH = size.height - _axisH;

    // Background
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF0F0F14));

    // Frequency grid (6 vertical lines)
    const vDivs = 6;
    final startHz = settings.startHz, stopHz = settings.stopHz;
    final span = stopHz - startHz;
    for (int i = 0; i <= vDivs; i++) {
      final x = size.width * i / vDivs;
      canvas.drawLine(Offset(x, 0), Offset(x, drawH),
          Paint()..color = const Color(0x26323240)..strokeWidth = 0.5);
      final fMhz = (startHz + span * i / vDivs) / 1e6;
      final tp = TextPainter(
        text: TextSpan(text: fMhz.toStringAsFixed(3),
            style: const TextStyle(color: Color(0xFFA0A0A0), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 2, drawH + 4));
    }

    // dB grid (5 horizontal lines)
    const hDivs = 5;
    final dbRange = maxDb - minDb;
    for (int i = 0; i <= hDivs; i++) {
      final db = maxDb - dbRange * i / hDivs;
      final y  = drawH * i / hDivs;
      canvas.drawLine(Offset(0, y), Offset(size.width, y),
          Paint()..color = const Color(0x26323240)..strokeWidth = 0.5);
      final tp = TextPainter(
        text: TextSpan(text: '${db.toInt()}',
            style: const TextStyle(color: Color(0xFF828282), fontSize: 8)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y + 1));
    }

    if (spectrum != null) {
      _drawLine(canvas, Size(size.width, drawH), spectrum!,
          fill: true,
          fillColor: const Color(0xB4145050),
          lineColor: const Color(0xFF00D2C8),
          lineWidth: 1.2);
    }
    if (peakHold != null) {
      _drawLine(canvas, Size(size.width, drawH), peakHold!,
          lineColor: Colors.red.shade400,
          lineWidth: 0.8);
    }
    if (spectrum == null) {
      final tp = TextPainter(
        text: const TextSpan(text: 'Press RUN to start sweep',
            style: TextStyle(color: Color(0xFF444466), fontSize: 16)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(
          size.width / 2 - tp.width / 2, size.height / 2 - tp.height / 2));
    }
  }

  void _drawLine(Canvas canvas, Size size, Float32List data, {
    bool fill = false,
    Color fillColor = Colors.transparent,
    required Color lineColor,
    double lineWidth = 1.0,
  }) {
    if (data.isEmpty) return;
    final dbRange = maxDb - minDb;
    final pts     = <Offset>[];

    for (int i = 0; i < data.length; i++) {
      final x  = size.width * i / data.length;
      final db = data[i].clamp(minDb, maxDb);
      final y  = size.height * (1 - (db - minDb) / dbRange);
      pts.add(Offset(x, y));
    }

    if (fill && pts.isNotEmpty) {
      final fillPath = Path()
        ..moveTo(pts.first.dx, size.height)
        ..lineTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) { fillPath.lineTo(p.dx, p.dy); }
      fillPath
        ..lineTo(pts.last.dx, size.height)
        ..close();
      canvas.drawPath(fillPath, Paint()..color = fillColor);
    }

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) { path.lineTo(p.dx, p.dy); }
    canvas.drawPath(path, Paint()
      ..color = lineColor
      ..strokeWidth = lineWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) =>
      old.spectrum != spectrum || old.peakHold != peakHold ||
      old.minDb != minDb      || old.maxDb != maxDb;
}

// ── Waterfall panel painter ───────────────────────────────────────────────────

class _WaterfallPainter extends CustomPainter {
  final ui.Image? wfImage;
  final SweepSettings settings;

  _WaterfallPainter({required this.wfImage, required this.settings});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF05050F));

    if (wfImage != null) {
      canvas.drawImageRect(
        wfImage!,
        Rect.fromLTWH(0, 0, wfImage!.width.toDouble(), wfImage!.height.toDouble()),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint(),
      );
    }

    // Frequency label overlay (matches reference)
    final startHz = settings.startHz, stopHz = settings.stopHz;
    final span    = stopHz - startHz;
    const vDivs   = 6;
    for (int i = 0; i <= vDivs; i++) {
      final x     = size.width * i / vDivs;
      final fMhz  = (startHz + span * i / vDivs) / 1e6;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
          Paint()..color = const Color(0x50505060)..strokeWidth = 0.5);
      final tp = TextPainter(
        text: TextSpan(text: fMhz.toStringAsFixed(3),
            style: const TextStyle(color: Color(0xDCC8C8C8), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 2, size.height - 14));
    }
  }

  @override
  bool shouldRepaint(_WaterfallPainter old) => old.wfImage != wfImage;
}
