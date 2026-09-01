import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';

class MedilinkColors {
  static const blue = Color(0xFF075985);
  static const teal = Color(0xFF0F9D94);
  static const green = Color(0xFF16803C);
  static const amber = Color(0xFFB45309);
  static const red = Color(0xFFBA1A1A);
  static const purple = Color(0xFF6B21A8);
  static const canvas = Color(0xFFF7FAFC);
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: .4)),
        ),
        child: Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11),
        ),
      ),
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
    height: 52,
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: loading ? null : onPressed,
      icon: loading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon),
      label: Text(label),
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label.replaceAll('_', ' '),
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = 'Loading your care data...'});
  final String label;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(label),
      ],
    ),
  );
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 44,
            color: MedilinkColors.red,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
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
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 46, color: MedilinkColors.blue),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(detail, textAlign: TextAlign.center),
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
      _ConnectionState.deviceOffline => ('Offline. Actions will be available when your connection returns.', Icons.cloud_off),
      _ConnectionState.backendUnreachable => ("Can't reach MediLink servers. Retrying...", Icons.dns_outlined),
      _ConnectionState.reconnecting => ('Reconnecting...', Icons.sync),
      _ConnectionState.online => ('', Icons.cloud_done),
    };
    return Container(
    width: double.infinity,
    color: const Color(0xFFFFF3CD),
    padding: const EdgeInsets.all(10),
    child: Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
          ),
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
  Widget build(BuildContext context) => Card(
    elevation: 0,
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}
