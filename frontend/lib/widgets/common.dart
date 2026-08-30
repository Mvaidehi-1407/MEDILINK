import 'package:flutter/material.dart';

class MedilinkColors {
  static const blue = Color(0xFF075985);
  static const teal = Color(0xFF0F9D94);
  static const green = Color(0xFF16803C);
  static const amber = Color(0xFFB45309);
  static const red = Color(0xFFBA1A1A);
  static const canvas = Color(0xFFF7FAFC);
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

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: const Color(0xFFFFF3CD),
    padding: const EdgeInsets.all(10),
    child: const Row(
      children: [
        Icon(Icons.cloud_off, size: 18),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Offline. Actions will be available when your connection returns.',
          ),
        ),
      ],
    ),
  );
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
