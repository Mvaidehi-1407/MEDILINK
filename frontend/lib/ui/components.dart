import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'brand.dart';

/// Tinted circle with a centred icon. Sizes: S 36, M 44, L 56, XL 72.
class IconBadge extends StatelessWidget {
  const IconBadge({super.key, required this.icon, this.tint = AppColors.tintMint, this.size = 44});
  final IconData icon;
  final (Color, Color) tint;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: tint.$1, shape: BoxShape.circle),
    child: Icon(icon, color: tint.$2, size: size * .5),
  );
}

/// Small rounded status label. Colour pairs come from tokens.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm - 2, vertical: AppSpacing.xxs + 1),
    decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(AppRadius.pill)),
    child: Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w700),
    ),
  );
}

/// Morphing page indicator driven by a [PageController]'s live offset.
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.controller, required this.count, required this.current});
  final PageController controller;
  final int count;

  /// Used before the controller has a position.
  final int current;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final page = controller.hasClients && controller.position.haveDimensions
          ? controller.page ?? current.toDouble()
          : current.toDouble();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (var i = 0; i < count; i++) _dot((1 - (page - i).abs()).clamp(0.0, 1.0))],
      );
    },
  );

  /// [t] = 1 for the current page, 0 for others, in between while swiping.
  static Widget _dot(double t) => Container(
    margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs - 1),
    width: 8 + 18 * t,
    height: 8,
    decoration: BoxDecoration(
      color: Color.lerp(AppColors.borderStrong, AppColors.primary, t),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
  );
}

/// Scales its child down slightly while pressed. Purely visual; taps pass through.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child});
  final Widget child;
  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  void _set(bool v) => setState(() => _down = v);
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _set(true),
    onPointerUp: (_) => _set(false),
    onPointerCancel: (_) => _set(false),
    child: AnimatedScale(
      scale: _down ? .97 : 1,
      duration: AppMotion.of(context, AppMotion.fast),
      curve: AppMotion.standard,
      child: widget.child,
    ),
  );
}

/// Fades and lifts its child in once, after [delay]. Respects reduce-motion.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.child, this.delay = Duration.zero, this.offset = 16, this.scaleFrom = 1});
  final Widget child;
  final Duration delay;
  final double offset;
  final double scaleFrom;
  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: AppMotion.expressive);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: AppMotion.emphasized);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMotion.reduced(context)) {
      _c.value = 1;
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    child: widget.child,
    builder: (_, child) => Opacity(
      opacity: _t.value,
      child: Transform.translate(
        offset: Offset(0, widget.offset * (1 - _t.value)),
        child: Transform.scale(scale: widget.scaleFrom + (1 - widget.scaleFrom) * _t.value, child: child),
      ),
    ),
  );
}

/// Startup brand moment: centred mark and wordmark, one short fade + gentle scale, no loop.
class SplashBrand extends StatelessWidget {
  const SplashBrand({super.key, required this.tagline});
  final String tagline;
  @override
  Widget build(BuildContext context) => Reveal(
    offset: 0,
    scaleFrom: .94,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const MedilinkLockup(fontSize: 30, vertical: true),
        const SizedBox(height: AppSpacing.sm),
        Text(tagline, textAlign: TextAlign.center, style: AppText.body),
      ],
    ),
  );
}

/// Soft background shapes used behind brand moments (splash, welcome).
class BrandBackdrop extends StatelessWidget {
  const BrandBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // Kept in the upper half, clear of the status bar and the bottom actions.
      Positioned(top: 40, right: -110, child: _blob(240, AppColors.primaryTint.withValues(alpha: .6))),
      Positioned(top: 300, left: -150, child: _blob(240, AppColors.accentTint.withValues(alpha: .55))),
      Positioned.fill(child: child),
    ],
  );

  static Widget _blob(double s, Color c) => IgnorePointer(
    child: Container(
      width: s,
      height: s,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    ),
  );
}

/// Home grid tile: tinted icon badge, title, optional subtitle, chevron. Fills its grid cell.
class FeatureTile extends StatelessWidget {
  const FeatureTile({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.tint = AppColors.tintBlue,
  }) : assert(icon != null || leading != null);
  final IconData? icon;

  /// Replaces the icon badge, e.g. a reference [AssetBadge].
  final Widget? leading;
  final String title;
  final String? subtitle;
  final (Color, Color) tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(borderRadius: AppRadius.cardAll, boxShadow: AppElevation.card),
    child: Material(
      color: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.cardAll,
        side: BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading ?? IconBadge(icon: icon!, tint: tint, size: 52),
              const SizedBox(height: AppSpacing.sm + 2),
              Text(title, style: AppText.title.copyWith(fontSize: 19)),
              const Spacer(),
              const SizedBox(height: AppSpacing.xxs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: Text(subtitle ?? '', style: AppText.bodySm)),
                  const SizedBox(width: AppSpacing.xs),
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.borderStrong),
                    ),
                    child: const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkSecondary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Two equal-width columns; tiles in a row share the taller tile's height.
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < children.length; i += 2) ...[
        if (i > 0) const SizedBox(height: AppSpacing.sm),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: children[i]),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox()),
            ],
          ),
        ),
      ],
    ],
  );
}

/// Big BPM number plus SpO2 / BP / Temp row. Shows "--" for any missing value (real data only).
class VitalsHero extends StatelessWidget {
  const VitalsHero({super.key, this.heartRate, this.spo2, this.systolic, this.diastolic, this.temperature});
  final Object? heartRate, spo2, systolic, diastolic, temperature;

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption),
          const SizedBox(height: 2),
          Text(value, style: AppText.bodyStrong.copyWith(fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
    const divider = SizedBox(height: 32, child: VerticalDivider(width: AppSpacing.lg));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('${heartRate ?? '--'}', style: appNumeral),
            const SizedBox(width: AppSpacing.xs),
            Text('BPM', style: AppText.title.copyWith(color: AppColors.inkSecondary)),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            stat('SpO2', '${spo2 ?? '--'}%'),
            divider,
            stat('BP', '${systolic ?? '--'}/${diastolic ?? '--'}'),
            divider,
            stat('Temp', '${temperature ?? '--'} °C'),
          ],
        ),
      ],
    );
  }
}

enum SafetyTone { ok, danger, secondary }

/// Full-width, 56 dp, high-contrast action for emergency screens. No motion.
class SafetyButton extends StatelessWidget {
  const SafetyButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tone = SafetyTone.ok,
    this.loading = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final SafetyTone tone;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      SafetyTone.ok => (AppColors.primary, AppColors.onDark),
      SafetyTone.danger => (AppColors.danger, AppColors.onDark),
      SafetyTone.secondary => (AppColors.surface, AppColors.ink),
    };
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          minimumSize: const Size.fromHeight(56),
          shape: const StadiumBorder(),
          side: tone == SafetyTone.secondary ? const BorderSide(color: AppColors.borderStrong) : null,
          textStyle: AppText.label.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        icon: loading
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.inkMuted),
              )
            : Icon(icon, size: 22),
        label: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}

/// The one themed error view: feature icon in a centred badge, short headline, one line.
/// Display only: it has no actions of its own.
class ProblemView extends StatelessWidget {
  const ProblemView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.tint = AppColors.tintBlue,
  });
  final IconData icon;
  final String title;
  final String message;
  final (Color, Color) tint;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBadge(icon: icon, tint: tint, size: 64),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xxs + 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(message, textAlign: TextAlign.center, style: AppText.body),
          ),
        ],
      ),
    ),
  );
}
