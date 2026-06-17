import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:ffi/ffi.dart';
import '../services/sdr_ffi.dart';

/// Constellation scatter plot showing IQ points from the active demodulator.
/// Polls the native constellation API every ~200ms and paints the latest
/// points as a scatter plot with a dark background and grid lines.
class ConstellationView extends StatefulWidget {
  final SdrFfi ffi;
  final bool active;

  const ConstellationView({super.key, required this.ffi, required this.active});

  @override State<ConstellationView> createState() => _ConstellationViewState();
}

class _ConstellationViewState extends State<ConstellationView>
    with SingleTickerProviderStateMixin {
  static const _maxPoints = 512;
  static const _pollMs = 200;

  final Float64List _iq = Float64List(_maxPoints * 2);
  int _nPoints = 0;

  @override void initState() {
    super.initState();
    _poll();
  }

  @override void didUpdateWidget(ConstellationView old) {
    super.didUpdateWidget(old);
    if (!old.active && widget.active) {
      // Restart poll on next frame — setState during build is unsafe
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _poll();
      });
    }
  }

  void _poll() {
    if (!widget.active || !mounted) return;
    try {
      final ptr = calloc<Double>(_maxPoints * 2);
      final n = widget.ffi.getAeroConstellation(ptr, _maxPoints);
      if (n > 0) {
        final limit = (n * 2).clamp(0, _maxPoints * 2);
        for (var i = 0; i < limit; i++) {
          _iq[i] = ptr[i];
        }
        _nPoints = n;
        setState(() {});
      }
      calloc.free(ptr);
    } catch (e) {
      print('CONST err: $e');
    }
    Future.delayed(const Duration(milliseconds: _pollMs), () {
      if (mounted) _poll();
    });
  }

  @override Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CustomPaint(
        size: ui.Size.infinite,
        painter: _ConstellationPainter(_iq, _nPoints),
      ),
    );
  }
}

class _ConstellationPainter extends CustomPainter {
  final Float64List iq;
  final int nPoints;

  _ConstellationPainter(this.iq, this.nPoints);

  @override void paint(Canvas canvas, ui.Size size) {
    // Semi-transparent dark background
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xBB0A0E1A));

    final cx = size.width / 2;
    final cy = size.height / 2;
    final scale = (size.shortestSide / 2) * 0.45;

    // Grid
    final gridPaint = Paint()..color = Colors.white12..strokeWidth = 0.5;
    canvas.drawLine(ui.Offset(0, cy), ui.Offset(size.width, cy), gridPaint);
    canvas.drawLine(ui.Offset(cx, 0), ui.Offset(cx, size.height), gridPaint);

    // Points
    if (nPoints > 0) {
      final dotPaint = Paint()
        ..color = const Color(0xFF00FF88)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 4.0;
      double minVal = 99, maxVal = -99;
      for (var i = 0; i < nPoints; i++) {
        final x = cx + iq[i * 2] * scale;
        final y = cy - iq[i * 2 + 1] * scale;
        canvas.drawCircle(ui.Offset(x, y), 1.5, dotPaint);
      }
    } else {
      final tp = TextPainter(
        text: TextSpan(text: 'No data', style: TextStyle(color: Colors.white38, fontSize: 10)),
        textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
    }
  }

  @override bool shouldRepaint(_ConstellationPainter old) =>
      old.nPoints != nPoints;
}
