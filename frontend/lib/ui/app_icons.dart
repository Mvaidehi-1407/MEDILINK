import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Icons cropped from the approved reference screenshots (`assets/icons`). Badges are full-colour
/// circles used as-is; `nav*` files are alpha masks tinted by [MedilinkNavBar].
/// Source: screenshots only (no original icon files were supplied), so these are approximations.
abstract final class AppIcons {
  static const _d = 'assets/icons';
  static const badgeHealth = '$_d/badge_health.png';
  static const badgeEmergency = '$_d/badge_emergency.png';
  static const badgeVault = '$_d/badge_vault.png';
  static const badgeHospitals = '$_d/badge_hospitals.png';
  static const badgeQr = '$_d/badge_qr.png';
  static const badgeMessages = '$_d/badge_messages.png';
  static const badgeHeart = '$_d/badge_heart.png';
  static const insightBars = '$_d/ic_insight_bars.png';
  static const illusStethoscope = '$_d/illus_stethoscope_shield.png';
  static const navHome = '$_d/nav_home.png';
  static const navHealth = '$_d/nav_health.png';
  static const navSiren = '$_d/nav_siren.png';
  static const navConnections = '$_d/nav_connections.png';
  static const navProfile = '$_d/nav_profile.png';
}

/// A full-colour circular reference badge (decorative: the label beside it carries the meaning).
class AssetBadge extends StatelessWidget {
  const AssetBadge(this.asset, {super.key, this.size = 52});
  final String asset;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Image.asset(asset, width: size, height: size, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
  );
}

/// One bottom-nav destination: a reference mask from [asset], or a Material [icon] for roles the
/// references don't cover.
class NavItem {
  const NavItem(this.label, {this.asset, this.icon}) : assert(asset != null || icon != null);
  final String label;
  final String? asset;
  final IconData? icon;
}

/// Bottom navigation per the Home reference: icon + label, the active one inside a soft pill.
/// Same contract as NavigationBar (selectedIndex / onDestinationSelected), light haptic on change.
class MedilinkNavBar extends StatelessWidget {
  const MedilinkNavBar({super.key, required this.items, required this.selectedIndex, required this.onDestinationSelected});
  final List<NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return Material(
      color: AppColors.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavButton(
                    item: items[i],
                    selected: i == selectedIndex,
                    duration: reduced ? Duration.zero : AppMotion.medium,
                    onTap: () {
                      if (i != selectedIndex) HapticFeedback.selectionClick();
                      onDestinationSelected(i);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.selected, required this.duration, required this.onTap});
  final NavItem item;
  final bool selected;
  final Duration duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.ink : AppColors.inkSecondary;
    final glyph = item.asset != null
        ? ImageIcon(AssetImage(item.asset!), size: 24, color: color)
        : Icon(item.icon, size: 24, color: color);
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.standard,
          constraints: const BoxConstraints(minHeight: 60),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentTint : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              glyph,
              const SizedBox(height: 4),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: AppText.caption.copyWith(
                  fontSize: 12.5,
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading placeholder: grey blocks with one 400 ms highlight pass, then a short rest.
/// Static (no sweep) when the OS asks to reduce motion.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;
  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  // 400 ms sweep + 800 ms rest per cycle.
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) {
      final t = Curves.easeInOut.transform((_c.value / (1 / 3)).clamp(0.0, 1.0));
      return ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment(-1.6 + 3.2 * t, 0),
          end: Alignment(-0.6 + 3.2 * t, 0),
          colors: const [AppColors.border, AppColors.surfaceMuted, AppColors.border],
        ).createShader(rect),
        child: child,
      );
    },
  );
}

/// A rounded grey block for skeletons.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 14, this.radius = AppRadius.sm, this.circle = false});
  final double? width;
  final double height;
  final double radius;
  final bool circle;
  @override
  Widget build(BuildContext context) => Container(
    width: circle ? height : width,
    height: height,
    decoration: BoxDecoration(
      color: AppColors.border,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
    ),
  );
}

/// Three skeleton list rows (avatar + two lines), used while a list is loading.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 3});
  final int rows;
  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: AppRadius.cardAll,
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const SkeletonBox(height: 44, circle: true),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(widthFactor: .6, child: const SkeletonBox(height: 14)),
                        const SizedBox(height: AppSpacing.xs),
                        FractionallySizedBox(widthFactor: .85, child: const SkeletonBox(height: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
