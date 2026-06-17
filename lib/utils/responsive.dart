import 'package:flutter/widgets.dart';

/// Device width breakpoints (dp)
class Breakpoints {
  static const double phoneMax  = 599.0;   // <= this = phone portrait / small
  static const double tabletMin = 600.0;   // >= this = tablet / landscape

  /// True when screen is wide enough for side-by-side (tablet landscape).
  /// Uses shortestSide so landscape phones don't get tablet layout.
  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.shortestSide >= tabletMin;
}

/// Responsive scaling for font sizes, chip sizes, and spacers.
///
/// At reference width 360dp (standard phone), scale = 1.0.
/// At 840dp+ (tablet landscape), scale maxes at 1.5.
class ResponsiveScale {
  final double _scale;

  ResponsiveScale(BuildContext context)
      : _scale = _compute(context);

  static double _compute(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final s = 1.0 + (w - 360.0) / 480.0 * 0.5;
    return s.clamp(1.0, 1.5);
  }

  double fontSize(double base)   => (base * _scale).roundToDouble();
  double spacing(double base)   => (base * _scale).roundToDouble();
  double iconSize(double base)  => (base * _scale).roundToDouble();
  double minChipHeight()        => stretchTapTarget ? 40.0 : 28.0;

  /// On phones, compact chips are fine. On tablets, enforce 40dp tall.
  bool get stretchTapTarget => _scale >= 1.3;
}
