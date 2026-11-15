import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../theme/tokens.dart';
import '../ui/app_icons.dart';
import '../ui/components.dart';
import '../ui/fallback.dart';

/// Legacy names kept for existing call sites; values now come from the design tokens.
class MedilinkColors {
  static const blue = AppColors.accent;
  static const teal = AppColors.primary;
  static const green = AppColors.success;
  static const amber = AppColors.warning;
  static const red = AppColors.danger;
  static const purple = Color(0xFF6A4FD3);
  static const canvas = AppColors.canvas;
}

/// Reused across Patient/Caregiver/Hospital dashboards (Phase 14/20.13): shows where a
/// supervision-mode/escalation episode currently stands, with distinct accessible colors per
/// stage so severity is legible at a glance without relying on color alone (label text always
/// present too).
class EscalationStageBadge extends StatelessWidget {
  const EscalationStageBadge({super.key, required this.status, this.escalationStage});
  final String status;
  final String? escalationStage;

  (String, Color) _presentation() {
    if (status == 'SUPERVISION') return ('SUPERVISION MODE', MedilinkColors.teal);
    switch (escalationStage) {
      case 'HOSPITAL_ESCALATED':
        return ('HOSPITAL ESCALATED', MedilinkColors.red);
      case 'CONTACT_NOTIFIED':
        return ('CONTACT NOTIFIED', MedilinkColors.amber);
      case 'PATIENT_ALERTED':
        return ('PATIENT ALERTED', MedilinkColors.purple);
      case 'AMBULANCE_REQUESTED':
        return ('AMBULANCE REQUESTED', MedilinkColors.red);
      default:
        return (status.replaceAll('_', ' '), MedilinkColors.blue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = _presentation();
    return Semantics(
      label: 'Escalation stage $label',
      child: StatusPill(label: label, color: color),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: loading ? null : onPressed,
      // Icon trails the label (arrow/login read as "go"); spinner replaces it while loading.
      iconAlignment: IconAlignment.end,
      icon: loading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.inkMuted),
            )
          : Icon(icon, size: 20),
      label: Text(label, textAlign: TextAlign.center),
    ),
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final normalized = label.toUpperCase();
    final color =
        normalized.contains('HIGH') ||
            normalized.contains('ACTIVE') ||
            normalized.contains('EMERGENCY')
        ? MedilinkColors.red
        : normalized.contains('WARNING') || normalized.contains('PENDING')
        ? MedilinkColors.amber
        : MedilinkColors.green;
    return Semantics(
      label: 'Status $label',
      child: StatusPill(label: label.replaceAll('_', ' '), color: color),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = 'Loading your care data...'});
  final String label;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SkeletonList(),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            liveRegion: true,
            child: Text(label, textAlign: TextAlign.center, style: AppText.body),
          ),
        ],
      ),
    ),
  );
}

/// Error body for lists and pages. Uses the app-wide [FallbackView]; raw exception text is never
/// shown, while server messages written for people are kept.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final kind = fallbackKindFor(message);
    return FallbackView(
      kind: kind,
      message: kind == FallbackKind.offline || looksRaw(message) ? null : message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.detail,
    this.icon = Icons.inbox_outlined,
  });
  final String title;
  final String detail;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBadge(icon: icon, tint: AppColors.tintBlue, size: 64),
          const SizedBox(height: AppSpacing.md),
          Text(title, textAlign: TextAlign.center, style: AppText.titleSm),
          const SizedBox(height: AppSpacing.xxs + 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(detail, textAlign: TextAlign.center, style: AppText.body),
          ),
        ],
      ),
    ),
  );
}

enum _ConnectionState { online, deviceOffline, backendUnreachable, reconnecting }

/// Real device connectivity (Phase 13) via connectivity_plus, PLUS a real backend reachability
/// ping -- these are different failure states (phone has no signal at all vs. phone is online
/// but MediLink's backend can't be reached) and must be told apart rather than collapsed into
/// one generic "offline" label. Reactive: no manual refresh needed.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key});
  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  _ConnectionState _state = _ConnectionState.online;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _backendPingTimer;

  @override
  void initState() {
    super.initState();
    _subscription = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    Connectivity().checkConnectivity().then(_onConnectivityChanged);
    _backendPingTimer = Timer.periodic(const Duration(seconds: 20), (_) => _pingBackendIfDeviceOnline());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _backendPingTimer?.cancel();
    super.dispose();
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    final deviceOnline = results.any((r) => r != ConnectivityResult.none);
    if (!deviceOnline) {
      if (mounted) setState(() => _state = _ConnectionState.deviceOffline);
      return;
    }
    if (mounted && _state == _ConnectionState.deviceOffline) {
      setState(() => _state = _ConnectionState.reconnecting);
    }
    await _pingBackendIfDeviceOnline();
  }

  Future<void> _pingBackendIfDeviceOnline() async {
    final results = await Connectivity().checkConnectivity();
    final deviceOnline = results.any((r) => r != ConnectivityResult.none);
    if (!deviceOnline) {
      if (mounted) setState(() => _state = _ConnectionState.deviceOffline);
      return;
    }
    try {
      await ref.read(apiClientProvider).systemStatus();
      if (mounted) setState(() => _state = _ConnectionState.online);
    } catch (_) {
      if (mounted) setState(() => _state = _ConnectionState.backendUnreachable);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _ConnectionState.online) return const SizedBox.shrink();
    final (message, icon) = switch (_state) {
      _ConnectionState.deviceOffline => ('Offline. Actions will be available when your connection returns.', Icons.cloud_off_rounded),
      _ConnectionState.backendUnreachable => ("Can't reach MediLink servers. Retrying...", Icons.dns_outlined),
      _ConnectionState.reconnecting => ('Reconnecting...', Icons.sync_rounded),
      _ConnectionState.online => ('', Icons.cloud_done_outlined),
    };
    return Container(
      width: double.infinity,
      color: AppColors.warningTint,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: AppSpacing.sm - 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm - 2),
          Expanded(
            child: Text(message, style: AppText.bodySm.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(borderRadius: AppRadius.cardAll, boxShadow: AppElevation.card),
    child: Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    ),
  );
}
