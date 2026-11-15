import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The MediLink mark (direction B, "Tile"): a white heartbeat on a teal rounded tile, drawn in Dart.
/// Geometry lives in a 100×100 box and scales to [size]. Launcher and splash PNGs are rendered
/// from this same painter (redesigned_app_screenshots/_capture_tooling/gen_brand_assets_test.dart).
class MedilinkMark extends StatelessWidget {
  const MedilinkMark({super.key, this.size = 48, this.color = AppColors.primary, this.onColor = AppColors.onDark});
  final double size;

  /// Tile colour. Pass [Colors.transparent] to draw the pulse alone.
  final Color color;

  /// Pulse colour.
  final Color onColor;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'MediLink',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(color, onColor)),
    ),
  );
}

/// Mark plus the "MediLink" wordmark (Bricolage Grotesque).
class MedilinkLockup extends StatelessWidget {
  const MedilinkLockup({
    super.key,
    this.fontSize = 28,
    this.vertical = false,
    this.color = AppColors.primary,
    this.textColor = AppColors.ink,
  });
  final double fontSize;
  final bool vertical;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final word = Text(
      'MediLink',
      textScaler: TextScaler.noScaling,
      style: TextStyle(
        fontFamily: AppText.display,
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        height: 1,
        letterSpacing: -0.02 * fontSize,
        color: textColor,
      ),
    );
    final mark = MedilinkMark(size: fontSize * (vertical ? 2.6 : 1.3), color: color);
    return Semantics(
      label: 'MediLink',
      container: true,
      excludeSemantics: true,
      child: vertical
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                SizedBox(height: fontSize * .5),
                word,
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                SizedBox(width: fontSize * .4),
                word,
              ],
            ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color, this.onColor);
  final Color color;
  final Color onColor;

  // Heartbeat in normalised x (0..1 across its span) and y offset in box units.
  // QRS spike plus a small T-wave so it never reads as a "+" at small sizes.
  // Baseline sits 4 units low so the asymmetric trace (−24 / +15) reads optically centred.
  static const _beat = [
    (0.0, 0.0),
    (0.27, 0.0),
    (0.33, 5.0),
    (0.41, -24.0),
    (0.50, 15.0),
    (0.56, 0.0),
    (0.63, 0.0),
    (0.69, -7.0),
    (0.75, 0.0),
    (1.0, 0.0),
  ];
  static const _baseline = 54.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100, size.height / 100);
    if (color.a > 0) {
      canvas.drawRRect(RRect.fromLTRBR(6, 6, 94, 94, const Radius.circular(27)), Paint()..color = color);
    }
    final pulse = Path();
    for (final (i, (t, dy)) in _beat.indexed) {
      final x = 18 + 64 * t;
      final y = _baseline + dy * .95;
      i == 0 ? pulse.moveTo(x, y) : pulse.lineTo(x, y);
    }
    canvas.drawPath(
      pulse,
      Paint()
        ..color = onColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color || old.onColor != onColor;
}
