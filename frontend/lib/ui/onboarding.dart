import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'components.dart';

/// One onboarding card: illustration, Bricolage headline, body. Staggered reveal on first show,
/// light parallax driven by the page controller's live offset (read-only).
class OnboardingCard extends StatelessWidget {
  const OnboardingCard({
    super.key,
    required this.index,
    required this.title,
    required this.body,
    required this.controller,
  });
  final int index;
  final String title;
  final String body;
  final PageController controller;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return LayoutBuilder(
      builder: (context, box) {
        final art = math.min(290.0, math.min(box.maxWidth - 2 * AppSpacing.gutter, box.maxHeight * .56));
        return AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final page = controller.hasClients && controller.position.haveDimensions
                ? controller.page ?? index.toDouble()
                : index.toDouble();
            final d = reduced ? 0.0 : (page - index).clamp(-1.0, 1.0);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Illustration lags the swipe slightly (parallax); text follows the page.
                Transform.translate(
                  offset: Offset(d * box.maxWidth * .28, 0),
                  child: Reveal(
                    scaleFrom: .92,
                    offset: 0,
                    child: OnboardingIllustration(index: index, size: art),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                Opacity(opacity: 1 - d.abs() * .6, child: child),
              ],
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: Column(
              children: [
                Reveal(
                  delay: const Duration(milliseconds: 120),
                  child: Text(title, textAlign: TextAlign.center, style: AppText.displayLg),
                ),
                const SizedBox(height: AppSpacing.sm),
                Reveal(
                  delay: const Duration(milliseconds: 220),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(body, textAlign: TextAlign.center, style: AppText.body.copyWith(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The four onboarding illustrations, drawn in Dart on a shared 240×240 grid with one stroke weight.
class OnboardingIllustration extends StatelessWidget {
  const OnboardingIllustration({super.key, required this.index, this.size = 240});
  final int index;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _IllustrationPainter(index)),
    ),
  );
}

class _IllustrationPainter extends CustomPainter {
  _IllustrationPainter(this.index);
  final int index;

  static const _w = 4.0; // shared line weight on the 240 grid
  static const _c = Offset(120, 120);

  Paint _line(Color c, [double w = _w]) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  Paint _fill(Color c) => Paint()..color = c;

  Path _pulse(double x0, double x1, double y, double amp) {
    const beat = [
      (0.0, 0.0),
      (0.3, 0.0),
      (0.36, 4.0),
      (0.45, -20.0),
      (0.55, 13.0),
      (0.62, 0.0),
      (0.7, 0.0),
      (0.77, -6.0),
      (0.84, 0.0),
      (1.0, 0.0),
    ];
    final p = Path();
    for (final (i, (t, dy)) in beat.indexed) {
      final pt = Offset(x0 + (x1 - x0) * t, y + dy * amp);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    return p;
  }

  void _person(Canvas c, Offset o, Color col) {
    c.drawCircle(o.translate(0, -6), 6, _line(col, 3.2));
    c.drawArc(
      Rect.fromCenter(center: o.translate(0, 14), width: 22, height: 18),
      math.pi,
      math.pi,
      false,
      _line(col, 3.2),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 240);
    // Shared backdrop: soft disc on the central axis.
    canvas.drawCircle(_c, 104, _fill(AppColors.primaryTint.withValues(alpha: .55)));
    canvas.drawCircle(_c, 78, _fill(AppColors.surface.withValues(alpha: .55)));
    const ink = AppColors.primary;
    switch (index) {
      case 0: // Wearable streaming vitals.
        final band = RRect.fromRectAndRadius(
          Rect.fromCenter(center: _c, width: 44, height: 168),
          const Radius.circular(18),
        );
        canvas.drawRRect(band, _fill(AppColors.primaryTint));
        canvas.drawRRect(band, _line(ink));
        final face = RRect.fromRectAndRadius(
          Rect.fromCenter(center: _c, width: 92, height: 100),
          const Radius.circular(26),
        );
        canvas.drawRRect(face, _fill(AppColors.surface));
        canvas.drawRRect(face, _line(ink));
        canvas.drawPath(_pulse(92, 148, 122, 1), _line(ink));
        for (final r in [72.0, 88.0]) {
          final rect = Rect.fromCircle(center: _c, radius: r);
          canvas.drawArc(rect, -.42, .84, false, _line(AppColors.accent.withValues(alpha: r == 72 ? 1 : .5)));
          canvas.drawArc(rect, math.pi - .42, .84, false, _line(AppColors.accent.withValues(alpha: r == 72 ? 1 : .5)));
        }
      case 1: // Trend approaching a threshold, caught early.
        final card = RRect.fromRectAndRadius(
          Rect.fromCenter(center: _c, width: 168, height: 124),
          const Radius.circular(20),
        );
        canvas.drawRRect(card, _fill(AppColors.surface));
        canvas.drawRRect(card, _line(ink));
        final dash = _line(AppColors.danger.withValues(alpha: .7), 3);
        for (var x = 52.0; x < 186; x += 14) {
          canvas.drawLine(Offset(x, 96), Offset(math.min(x + 7, 186), 96), dash);
        }
        final trend = Path()
          ..moveTo(54, 156)
          ..lineTo(80, 146)
          ..lineTo(100, 152)
          ..lineTo(124, 128)
          ..lineTo(144, 134)
          ..lineTo(166, 110);
        canvas.drawPath(trend, _line(ink));
        canvas.drawCircle(const Offset(166, 110), 15, _fill(AppColors.warning.withValues(alpha: .16)));
        canvas.drawCircle(const Offset(166, 110), 7, _fill(AppColors.surface));
        canvas.drawCircle(const Offset(166, 110), 7, _line(AppColors.warning, 3.5));
      case 2: // Location shared with responders.
        for (final (w, a) in [(150.0, .35), (104.0, .7)]) {
          canvas.drawOval(
            Rect.fromCenter(center: const Offset(120, 168), width: w, height: w * .3),
            _line(ink.withValues(alpha: a), 3),
          );
        }
        final pin = Path()
          ..moveTo(120, 168)
          ..cubicTo(98, 140, 78, 120, 78, 96)
          ..arcToPoint(const Offset(162, 96), radius: const Radius.circular(42))
          ..cubicTo(162, 120, 142, 140, 120, 168)
          ..close();
        canvas.drawPath(pin, _fill(ink));
        canvas.drawCircle(const Offset(120, 96), 22, _fill(AppColors.surface));
        // Small cross: help on the way.
        canvas.drawLine(const Offset(120, 86), const Offset(120, 106), _line(AppColors.danger, 5));
        canvas.drawLine(const Offset(110, 96), const Offset(130, 96), _line(AppColors.danger, 5));
      default: // Care team around the patient.
        final nodes = [
          (const Offset(120, 44), AppColors.tintBlue),
          (const Offset(196, 120), AppColors.tintViolet),
          (const Offset(120, 196), AppColors.tintAmber),
          (const Offset(44, 120), AppColors.tintRed),
        ];
        for (final (o, _) in nodes) {
          canvas.drawLine(_c, o, _line(ink.withValues(alpha: .35), 3));
        }
        canvas.drawCircle(_c, 34, _fill(AppColors.surface));
        canvas.drawCircle(_c, 34, _line(ink));
        canvas.drawPath(_pulse(100, 140, 122, .8), _line(ink, 3.5));
        for (final (i, (o, (bg, fg))) in nodes.indexed) {
          canvas.drawCircle(o, 24, _fill(bg));
          canvas.drawCircle(o, 24, _line(fg, 3));
          if (i == 2) {
            // Hospital: cross.
            canvas.drawLine(o.translate(0, -9), o.translate(0, 9), _line(fg, 4));
            canvas.drawLine(o.translate(-9, 0), o.translate(9, 0), _line(fg, 4));
          } else {
            _person(canvas, o, fg);
          }
        }
    }
  }

  @override
  bool shouldRepaint(_IllustrationPainter old) => old.index != index;
}
