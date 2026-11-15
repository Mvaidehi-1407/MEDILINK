import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/tokens.dart';
import 'components.dart';

/// The five non-content states every screen can land in. One look, one voice, app-wide.
enum FallbackKind { error, offline, permission, notFound, comingSoon }

class _Copy {
  const _Copy(this.icon, this.tint, this.title, this.message, this.action);
  final IconData icon;
  final (Color, Color) tint;
  final String title;
  final String message;
  final String? action;
}

const _copy = {
  FallbackKind.error: _Copy(
    Icons.error_outline_rounded,
    AppColors.tintRed,
    'Something went wrong',
    'This part of the app ran into a problem. Please try again in a moment.',
    'Try again',
  ),
  FallbackKind.offline: _Copy(
    Icons.cloud_off_rounded,
    AppColors.tintAmber,
    "Can't reach MediLink",
    'Check your internet connection. If it keeps happening, check the server address in App settings.',
    'Try again',
  ),
  FallbackKind.permission: _Copy(
    Icons.lock_outline_rounded,
    AppColors.tintViolet,
    'Permission needed',
    "MediLink needs this permission to continue. You can turn it on in your phone's settings.",
    'Open settings',
  ),
  FallbackKind.notFound: _Copy(
    Icons.explore_off_outlined,
    AppColors.tintBlue,
    'Page not found',
    "This page doesn't exist or has moved.",
    'Go back',
  ),
  FallbackKind.comingSoon: _Copy(
    Icons.hourglass_empty_rounded,
    AppColors.tintMint,
    'Coming soon',
    "This isn't available yet. It will appear here as soon as it's ready.",
    null,
  ),
};

/// Picks offline vs. generic error from an error message, without ever showing raw exception text.
FallbackKind fallbackKindFor(String? message) {
  final m = (message ?? '').toLowerCase();
  const offlineHints = ['unable to reach', "can't reach", 'could not reach', 'connection', 'network', 'timed out', 'timeout', 'socket', 'offline'];
  return offlineHints.any(m.contains) ? FallbackKind.offline : FallbackKind.error;
}

/// True when [message] reads like a developer exception rather than a sentence for people.
bool looksRaw(String? message) {
  final m = message ?? '';
  if (m.trim().isEmpty) return true;
  const raw = ['Exception', 'Error:', 'TypeError', 'is not a subtype', 'Null check', 'NoSuchMethod', 'RangeError', 'FormatException', 'dart:', '#0 '];
  return raw.any(m.contains) || m.length > 220;
}

/// Embeddable fallback (inside a page body, card or tab). [onAction] defaults per kind:
/// permission opens app settings; notFound pops the route.
class FallbackView extends StatelessWidget {
  const FallbackView({
    super.key,
    required this.kind,
    this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });
  final FallbackKind kind;
  final String? title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Smaller badge and no outer padding, for use inside cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = _copy[kind]!;
    final VoidCallback? action = onAction ??
        switch (kind) {
          FallbackKind.permission => () => openAppSettings(),
          FallbackKind.notFound => () => Navigator.of(context).maybePop(),
          _ => null,
        };
    final label = actionLabel ?? c.action;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconBadge(icon: c.icon, tint: c.tint, size: compact ? 52 : 72),
        SizedBox(height: compact ? AppSpacing.sm : AppSpacing.lg),
        Text(
          title ?? c.title,
          textAlign: TextAlign.center,
          style: (compact ? AppText.titleSm : AppText.title).copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.xs),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(message ?? c.message, textAlign: TextAlign.center, style: AppText.body),
        ),
        if (action != null && label != null) ...[
          SizedBox(height: compact ? AppSpacing.sm : AppSpacing.xl),
          compact
              ? TextButton(onPressed: action, child: Text(label))
              : FilledButton(
                  onPressed: action,
                  style: FilledButton.styleFrom(minimumSize: const Size(200, 52)),
                  child: Text(label),
                ),
        ],
      ],
    );
    if (compact) return Center(child: body);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: body,
      ),
    );
  }
}

/// Full page version, with its own app bar. Used for routes that can't be found, permission
/// walls and features that aren't available yet.
class FallbackScreen extends StatelessWidget {
  const FallbackScreen({
    super.key,
    required this.kind,
    this.appBarTitle = '',
    this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });
  final FallbackKind kind;
  final String appBarTitle;
  final String? title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Pushes a full-page fallback, e.g. `FallbackScreen.open(context, FallbackKind.comingSoon, appBarTitle: 'Share')`.
  static Future<void> open(BuildContext context, FallbackKind kind, {String appBarTitle = '', String? title, String? message}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FallbackScreen(kind: kind, appBarTitle: appBarTitle, title: title, message: message),
      ));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(appBarTitle)),
    body: SafeArea(
      child: FallbackView(kind: kind, title: title, message: message, actionLabel: actionLabel, onAction: onAction),
    ),
  );
}

/// Replaces Flutter's red/grey crash box (ErrorWidget) app-wide. It can be built anywhere in the
/// tree, even outside MaterialApp, so it brings its own Directionality and Material and scales down
/// to whatever space the broken widget had.
Widget fallbackErrorWidget(FlutterErrorDetails details) => Directionality(
  textDirection: TextDirection.ltr,
  child: Material(
    color: AppColors.surface,
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const IconBadge(icon: Icons.error_outline_rounded, tint: AppColors.tintRed, size: 52),
              const SizedBox(height: AppSpacing.sm),
              Text(_copy[FallbackKind.error]!.title, style: AppText.titleSm),
              const SizedBox(height: AppSpacing.xxs),
              Text('Go back and try again.', style: AppText.bodySm),
            ],
          ),
        ),
      ),
    ),
  ),
);
