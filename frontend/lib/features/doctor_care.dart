import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../theme/tokens.dart';
import '../ui/app_icons.dart' show SkeletonList;
import '../ui/components.dart';
import '../ui/format.dart';
import '../widgets/common.dart';
import 'doctor_chat.dart';
import 'doctor_portal.dart';
import 'doctor_scan.dart';

// =============================================================================================
// Shared helpers
// =============================================================================================

/// One FutureBuilder body with the shared shimmer / error / empty states.
Widget futureList<T>({
  required Future<T> future,
  required VoidCallback onRetry,
  required bool Function(T) isEmpty,
  required Widget empty,
  required Widget Function(T) data,
}) => FutureBuilder<T>(
  future: future,
  builder: (context, snap) {
    if (snap.connectionState != ConnectionState.done) {
      return const Padding(padding: EdgeInsets.all(AppSpacing.gutter), child: SkeletonList(rows: 4));
    }
    final err = snap.error;
    if (err is ApiException && err.statusCode == 403) return patientUnavailable(context, err.message);
    if (err != null) return ErrorState(message: err.toString(), onRetry: onRetry);
    final value = snap.data as T;
    if (isEmpty(value)) return ListView(children: [const SizedBox(height: AppSpacing.xxxl), empty]);
    return data(value);
  },
);

/// Risk tier label + colour. AI output only; never used for sensor values.
(String, Color) riskStyle(Object? level) => switch (level) {
  'HIGH_RISK' => ('High risk', AppColors.danger),
  'WARNING' => ('Warning', AppColors.warning),
  'NORMAL' => ('Normal', AppColors.success),
  'NO_RECENT_DATA' => ('No recent data', AppColors.inkSecondary),
  'CRITICAL' => ('Critical', AppColors.danger),
  'RESOLVED' => ('Resolved', AppColors.inkSecondary),
  _ => (humanizeEnum(level), AppColors.inkSecondary),
};

class ChipFilter extends StatelessWidget {
  const ChipFilter({super.key, required this.options, required this.value, required this.onChanged});
  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        for (final (v, label) in options)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: ChoiceChip(label: Text(label), selected: value == v, onSelected: (_) => onChanged(v)),
          ),
      ],
    ),
  );
}

// =============================================================================================
// Monitoring (read-only)
// =============================================================================================

class DoctorMonitoringPage extends ConsumerStatefulWidget {
  const DoctorMonitoringPage({super.key});
  @override
  ConsumerState<DoctorMonitoringPage> createState() => _DoctorMonitoringPageState();
}

class _DoctorMonitoringPageState extends ConsumerState<DoctorMonitoringPage> {
  String _filter = 'ALL';
  late Future<List<Map<String, dynamic>>> _future = _load();
  Future<List<Map<String, dynamic>>> _load() => ref.read(apiClientProvider).list('/doctor/monitoring');
  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Patient monitoring'), titleSpacing: 0),
    body: Column(
      children: [
        ChipFilter(
          value: _filter,
          onChanged: (v) => setState(() => _filter = v),
          options: const [('ALL', 'All'), ('NORMAL', 'Normal'), ('WARNING', 'Warning'), ('HIGH_RISK', 'High risk'), ('NO_RECENT_DATA', 'No recent data')],
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: futureList<List<Map<String, dynamic>>>(
              future: _future,
              onRetry: _reload,
              isEmpty: (rows) => rows.where((r) => _filter == 'ALL' || r['bucket'] == _filter).isEmpty,
              empty: const EmptyState(
                title: 'No patients here',
                detail: 'Connected patients with readings in this group appear here.',
                icon: Icons.monitor_heart_outlined,
              ),
              data: (rows) {
                final shown = rows.where((r) => _filter == 'ALL' || r['bucket'] == _filter).toList();
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) => _MonitorCard(row: shown[i]),
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class _MonitorCard extends StatelessWidget {
  const _MonitorCard({required this.row});
  final Map<String, dynamic> row;
  @override
  Widget build(BuildContext context) {
    final p = Map<String, dynamic>.from(row['patient'] as Map);
    final latest = row['latest'] as Map?;
    final (label, color) = riskStyle(row['bucket']);
    return SectionCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: AppRadius.cardAll,
        onTap: () => pushPage(context, MonitoringDetailPage(patient: p)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                PatientAvatar(patient: p, size: 44, online: row['device'] == 'CONNECTED'),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p['name']?.toString() ?? 'Patient', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(pidOf(p['id']), style: AppText.caption),
                  ]),
                ),
                StatusPill(label: label, color: color),
              ]),
              const SizedBox(height: AppSpacing.sm),
              Row(children: [
                Expanded(child: _Metric(label: 'Heart rate', value: '${latest?['heartRate'] ?? '--'}', unit: 'BPM')),
                Expanded(child: _Metric(label: 'SpO₂', value: '${latest?['spo2'] ?? '--'}', unit: '%')),
              ]),
              const SizedBox(height: AppSpacing.xs),
              Text(
                [
                  latest == null ? 'No readings yet' : 'Updated ${relativeTime(latest['timestamp'])}',
                  switch (row['device']) { 'CONNECTED' => 'Wearable streaming', 'OFFLINE' => 'Wearable offline', _ => 'No wearable' },
                ].join(' · '),
                style: AppText.bodySm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.unit});
  final String label, value, unit;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label $value $unit',
    excludeSemantics: true,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.caption),
      Text.rich(TextSpan(children: [
        TextSpan(text: value, style: AppText.title.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        TextSpan(text: ' $unit', style: AppText.bodySm),
      ])),
    ]),
  );
}

class MonitoringDetailPage extends ConsumerStatefulWidget {
  const MonitoringDetailPage({super.key, required this.patient});
  final Map<String, dynamic> patient;
  @override
  ConsumerState<MonitoringDetailPage> createState() => _MonitoringDetailPageState();
}

class _MonitoringDetailPageState extends ConsumerState<MonitoringDetailPage> {
  int _hours = 24;
  late Future<Map<String, dynamic>> _future = _load();
  Future<Map<String, dynamic>> _load() async => Map<String, dynamic>.from(
    await ref.read(apiClientProvider).get('/doctor/patients/${widget.patient['id']}/vitals', query: {'hours': '$_hours'}) as Map,
  );
  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.patient['name']?.toString() ?? 'Monitoring'), titleSpacing: 0),
    body: RefreshIndicator(
      onRefresh: () async => _reload(),
      child: futureList<Map<String, dynamic>>(
        future: _future,
        onRetry: _reload,
        isEmpty: (v) => (v['readings'] as List).isEmpty,
        empty: const EmptyState(title: 'No readings yet', detail: "Readings appear here once the patient's wearable sends data.", icon: Icons.monitor_heart_outlined),
        data: (v) {
          final readings = (v['readings'] as List).cast<Map>();
          final device = Map<String, dynamic>.from(v['device'] as Map);
          final ai = v['ai'] as Map?;
          List<double?> series(String k) => [for (final r in readings) (r[k] as num?)?.toDouble()];
          return ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
            children: [
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [ButtonSegment(value: 24, label: Text('24H')), ButtonSegment(value: 168, label: Text('7D')), ButtonSegment(value: 720, label: Text('30D'))],
                selected: {_hours},
                onSelectionChanged: (s) {
                  _hours = s.first;
                  _reload();
                },
              ),
              const SectionHeader('Sensor readings'),
              _ChartCard(title: 'Heart rate', unit: 'BPM', values: series('heartRate'), tint: AppColors.tintRed),
              const SizedBox(height: AppSpacing.sm),
              _ChartCard(title: 'SpO₂', unit: '%', values: series('spo2'), tint: AppColors.tintBlue),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${readings.length} readings · latest ${formatTimestamp(readings.last['timestamp'])}${readings.any((r) => r['source'] == 'DEMO') ? ' · includes demo data' : ''}',
                style: AppText.bodySm,
              ),
              const SectionHeader('Device'),
              SectionCard(
                child: Row(children: [
                  IconBadge(icon: Icons.watch_outlined, tint: device['status'] == 'CONNECTED' ? AppColors.tintMint : AppColors.tintBlue, size: 40),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(device['name']?.toString() ?? 'Wearable', style: AppText.bodyStrong),
                      Text(device['lastSeen'] == null ? 'Never seen' : 'Last data ${relativeTime(device['lastSeen'])}', style: AppText.bodySm),
                    ]),
                  ),
                  StatusPill(
                    label: switch (device['status']) { 'CONNECTED' => 'Streaming', 'OFFLINE' => 'Offline', _ => 'No device' },
                    color: device['status'] == 'CONNECTED' ? AppColors.success : AppColors.inkSecondary,
                  ),
                ]),
              ),
              const SectionHeader('AI risk assessment'),
              if (ai == null)
                SectionCard(child: Text('No AI assessment stored for this period.', style: AppText.body))
              else
                _AiCard(ai: Map<String, dynamic>.from(ai)),
            ],
          );
        },
      ),
    ),
  );
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.unit, required this.values, required this.tint});
  final String title, unit;
  final List<double?> values;
  final (Color, Color) tint;
  @override
  Widget build(BuildContext context) {
    final real = values.whereType<double>().toList();
    final summary = real.isEmpty
        ? 'No $title values'
        : '$title trend: lowest ${real.reduce((a, b) => a < b ? a : b).round()}, highest ${real.reduce((a, b) => a > b ? a : b).round()}, latest ${real.last.round()} $unit';
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(title, style: AppText.bodyStrong),
            const Spacer(),
            Text(real.isEmpty ? '--' : '${real.last.round()} $unit', style: AppText.bodyStrong.copyWith(color: tint.$2)),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            label: summary,
            excludeSemantics: true,
            child: SizedBox(height: 120, width: double.infinity, child: CustomPaint(painter: TrendPainter(values, tint.$2))),
          ),
        ],
      ),
    );
  }
}

/// Simple line + soft fill trend (approximate: no chart library in the app).
class TrendPainter extends CustomPainter {
  TrendPainter(this.values, this.color);
  final List<double?> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = <Offset>[];
    final real = values.whereType<double>().toList();
    if (real.isEmpty) return;
    var lo = real.reduce((a, b) => a < b ? a : b), hi = real.reduce((a, b) => a > b ? a : b);
    if (hi - lo < 4) {
      lo -= 2;
      hi += 2;
    }
    const labelW = 30.0;
    final w = size.width - labelW, h = size.height - 8;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) continue;
      final x = labelW + (values.length == 1 ? w / 2 : w * i / (values.length - 1));
      pts.add(Offset(x, 4 + h - (v - lo) / (hi - lo) * h));
    }
    final grid = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    for (final y in [4.0, 4 + h / 2, 4 + h]) {
      canvas.drawLine(Offset(labelW, y), Offset(size.width, y), grid);
    }
    for (final (v, y) in [(hi, 4.0), (lo, 4 + h)]) {
      final tp = TextPainter(text: TextSpan(text: '${v.round()}', style: AppText.caption), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }
    final line = Path()..addPolygon(pts, false);
    canvas.drawPath(
      Path.from(line)
        ..lineTo(pts.last.dx, 4 + h)
        ..lineTo(pts.first.dx, 4 + h)
        ..close(),
      Paint()..color = color.withValues(alpha: .10),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(pts.last, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(TrendPainter old) => old.values != values;
}

class _AiCard extends StatelessWidget {
  const _AiCard({required this.ai});
  final Map<String, dynamic> ai;
  @override
  Widget build(BuildContext context) {
    final (label, color) = riskStyle(ai['riskLevel']);
    final contributing = (ai['contributing'] as List? ?? []).cast<Map>();
    final signals = (ai['signals'] as List? ?? []).map((s) => humanizeEnum(s)).join(', ');
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const IconBadge(icon: Icons.insights_outlined, tint: AppColors.tintViolet, size: 40),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text('Assessed ${formatTimestamp(ai['timestamp'])}', style: AppText.bodySm)),
            StatusPill(label: label, color: color),
          ]),
          if (signals.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('Signals: $signals', style: AppText.body),
          ],
          if (contributing.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('Based on these readings', style: AppText.caption),
            for (final r in contributing)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
                child: Text('${formatTimestamp(r['timestamp'])} · HR ${r['heartRate'] ?? '--'} · SpO₂ ${r['spo2'] ?? '--'}%', style: AppText.bodySm),
              ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(color: AppColors.warningTint, borderRadius: BorderRadius.circular(AppRadius.sm)),
            child: Text('Informational only. Not a diagnosis.', style: AppText.bodySm.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================================
// Emergency alerts (read-only)
// =============================================================================================

class DoctorAlertsPage extends ConsumerStatefulWidget {
  const DoctorAlertsPage({super.key});
  @override
  ConsumerState<DoctorAlertsPage> createState() => _DoctorAlertsPageState();
}

class _DoctorAlertsPageState extends ConsumerState<DoctorAlertsPage> {
  String _filter = 'ALL';
  late Future<List<Map<String, dynamic>>> _future = _load();
  Future<List<Map<String, dynamic>>> _load() => ref.read(apiClientProvider).list('/doctor/alerts');
  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Emergency alerts'), titleSpacing: 0),
    body: Column(children: [
      ChipFilter(
        value: _filter,
        onChanged: (v) => setState(() => _filter = v),
        // Only the levels stored emergencies can carry.
        options: const [('ALL', 'All'), ('CRITICAL', 'Critical'), ('HIGH_RISK', 'High risk'), ('RESOLVED', 'Resolved')],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.xs),
        child: Text("Alerts show while MediLink is open. You won't get them when the app is closed.", style: AppText.caption),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async => _reload(),
          child: futureList<List<Map<String, dynamic>>>(
            future: _future,
            onRetry: _reload,
            isEmpty: (rows) => rows.where((r) => _filter == 'ALL' || r['level'] == _filter).isEmpty,
            empty: const EmptyState(title: 'No emergency alerts', detail: 'Emergencies from your connected patients appear here.', icon: Icons.verified_user_outlined),
            data: (rows) {
              final shown = rows.where((r) => _filter == 'ALL' || r['level'] == _filter).toList();
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
                itemCount: shown.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                itemBuilder: (_, i) => AlertCard(alert: shown[i], onReturn: _reload),
              );
            },
          ),
        ),
      ),
    ]),
  );
}

/// One alert. Coral/red while active.
class AlertCard extends StatelessWidget {
  const AlertCard({super.key, required this.alert, this.onReturn});
  final Map<String, dynamic> alert;
  final VoidCallback? onReturn;
  @override
  Widget build(BuildContext context) {
    final patient = Map<String, dynamic>.from(alert['patient'] as Map? ?? {});
    final active = alert['active'] != false;
    final (label, color) = riskStyle(alert['level'] ?? (active ? 'CRITICAL' : 'RESOLVED'));
    final reading = alert['reading'] as Map?;
    return Material(
      color: active ? AppColors.dangerTint : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.cardAll,
        side: BorderSide(color: active ? AppColors.danger.withValues(alpha: .3) : AppColors.border),
      ),
      child: InkWell(
        customBorder: const RoundedRectangleBorder(borderRadius: AppRadius.cardAll),
        onTap: () async {
          await pushPage(context, AlertDetailPage(alertId: alert['id'].toString()));
          onReturn?.call();
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              IconBadge(icon: Icons.warning_amber_rounded, tint: active ? AppColors.tintRed : AppColors.tintBlue, size: 44),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(patient['name']?.toString() ?? 'Patient', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('${pidOf(patient['id'])} · ${formatTimestamp(alert['createdAt'])}', style: AppText.bodySm),
                    if (reading != null) Text('HR ${reading['heartRate'] ?? '--'} · SpO₂ ${reading['spo2'] ?? '--'}%', style: AppText.bodySm),
                    if (alert['acknowledged'] == true) Text('Acknowledged', style: AppText.caption.copyWith(color: AppColors.success)),
                  ],
                ),
              ),
              StatusPill(label: label, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class AlertDetailPage extends ConsumerStatefulWidget {
  const AlertDetailPage({super.key, required this.alertId});
  final String alertId;
  @override
  ConsumerState<AlertDetailPage> createState() => _AlertDetailPageState();
}

class _AlertDetailPageState extends ConsumerState<AlertDetailPage> {
  late Future<Map<String, dynamic>> _future = _load();
  bool _acking = false;
  Future<Map<String, dynamic>> _load() async => Map<String, dynamic>.from(await ref.read(apiClientProvider).get('/doctor/alerts/${widget.alertId}') as Map);
  void _reload() => setState(() => _future = _load());

  Future<void> _ack() async {
    setState(() => _acking = true);
    try {
      final r = await ref.read(apiClientProvider).post('/doctor/alerts/${widget.alertId}/acknowledge') as Map;
      // Hide this alert's banner everywhere right away; the server copy keeps it hidden.
      ref.read(acknowledgedAlertsProvider.notifier).add(widget.alertId, r['status']);
      ref.invalidate(doctorHomeProvider);
      _reload();
    } on ApiException catch (e) {
      // Banner stays; short error.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.statusCode == null ? "Couldn't acknowledge. Check your connection and try again." : "Couldn't acknowledge: ${e.message}"),
        ));
      }
    } finally {
      if (mounted) setState(() => _acking = false);
    }
  }

  Future<void> _call(String phone) async {
    if (!await launchUrl(Uri(scheme: 'tel', path: phone)) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open the phone app.")));
    }
  }

  Future<void> _openChat(Map<String, dynamic> patient) async {
    try {
      final convs = await ref.read(apiClientProvider).list('/doctor/conversations');
      final c = convs.firstWhere((c) => (c['patient'] as Map)['id'] == patient['id']);
      if (mounted) pushPage(context, DoctorChatPage(conversationId: c['conversationId'].toString(), patient: patient));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No active chat with this patient.')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Alert details'), titleSpacing: 0),
    body: futureList<Map<String, dynamic>>(
      future: _future,
      onRetry: _reload,
      isEmpty: (_) => false,
      empty: const SizedBox(),
      data: (a) {
        final p = Map<String, dynamic>.from(a['patient'] as Map);
        final reading = a['reading'] as Map?;
        final reason = Map<String, dynamic>.from(a['reason'] as Map? ?? {});
        final caretakers = (a['caretakers'] as List? ?? []).cast<Map>();
        final hospital = Map<String, dynamic>.from(a['hospital'] as Map? ?? {});
        final nearby = (hospital['nearby'] as List? ?? []).cast<Map>();
        final timeline = (a['timeline'] as List? ?? []).cast<Map>();
        final (label, color) = riskStyle(a['level']);
        final loc = a['location'] as Map?;
        return ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
          children: [
            SectionCard(
              child: Row(children: [
                PatientAvatar(patient: p, size: 56),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p['name']?.toString() ?? 'Patient', style: AppText.titleSm),
                    Text('${pidOf(p['id'])} · ${formatTimestamp(a['createdAt'])}', style: AppText.bodySm),
                  ]),
                ),
                StatusPill(label: label, color: color),
              ]),
            ),
            const SizedBox(height: AppSpacing.md),
            if (a['acknowledgedAt'] == null)
              PrimaryButton(label: 'Acknowledge alert', icon: Icons.check_rounded, loading: _acking, onPressed: _ack)
            else
              Text('You acknowledged this ${formatTimestamp(a['acknowledgedAt'])}. The patient\'s emergency response is unchanged.', style: AppText.bodySm),
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                onPressed: () => pushPage(context, PatientSummaryPage(patientId: p['id'].toString())),
                icon: const Icon(Icons.person_outline_rounded, size: 18),
                label: const Text('View patient'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                onPressed: () => _openChat(p),
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: const Text('Open chat'),
              ),
            ]),
            const SectionHeader('Reason'),
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(humanizeEnum(reason['trigger'] ?? 'Not recorded'), style: AppText.bodyStrong),
                if (reason['patientResponse'] != null) Text('Patient response: ${humanizeEnum(reason['patientResponse'])}', style: AppText.bodySm),
                if (reason['panicPattern'] == true) Text('Panic pattern detected', style: AppText.bodySm),
                if (reading != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text('HR ${reading['heartRate'] ?? '--'} BPM · SpO₂ ${reading['spo2'] ?? '--'}% · ${formatTimestamp(reading['timestamp'])}', style: AppText.body),
                ],
              ]),
            ),
            const SectionHeader('Location'),
            SectionCard(
              child: Text(
                a['address']?.toString() ?? (loc != null ? '${loc['latitude'] ?? loc['lat'] ?? ''}, ${loc['longitude'] ?? loc['lng'] ?? ''}' : 'Location not shared for this alert.'),
                style: AppText.body,
              ),
            ),
            const SectionHeader('Caretakers'),
            if (caretakers.isEmpty)
              SectionCard(child: Text('No caretakers on file.', style: AppText.body))
            else
              SectionCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (final c in caretakers)
                    ListTile(
                      title: Text(c['name']?.toString() ?? 'Caretaker', style: AppText.bodyStrong),
                      subtitle: Text(c['relation']?.toString() ?? c['phone']?.toString() ?? '', style: AppText.bodySm),
                      trailing: c['phone'] == null
                          ? null
                          : IconButton(tooltip: 'Call ${c['name']}', onPressed: () => _call(c['phone'].toString()), icon: const Icon(Icons.call_outlined, color: AppColors.primary)),
                    ),
                ]),
              ),
            const SectionHeader('Hospital and ambulance'),
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Hospital call: ${hospital['callStatus'] == null ? 'not placed' : humanizeEnum(hospital['callStatus'])}', style: AppText.bodyStrong),
                for (final h in nearby)
                  Text('${h['name']} · ${(((h['distanceMeters'] as num?) ?? 0) / 1000).toStringAsFixed(1)} km', style: AppText.bodySm),
                const SizedBox(height: AppSpacing.xs),
                Text(a['ambulance'] == 'REQUESTED' ? 'Ambulance: requested' : 'Ambulance status: not available', style: AppText.bodySm),
              ]),
            ),
            if (timeline.isNotEmpty) ...[
              const SectionHeader('History'),
              SectionCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final t in timeline)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('${formatTimestamp(t['timestamp'])} · ${humanizeEnum(t['event'])}', style: AppText.bodySm),
                    ),
                ]),
              ),
            ],
          ],
        );
      },
    ),
  );
}

// =============================================================================================
// Consultation notes
// =============================================================================================

class PatientNotesList extends ConsumerStatefulWidget {
  const PatientNotesList({super.key, required this.patient});
  final Map<String, dynamic> patient;
  @override
  ConsumerState<PatientNotesList> createState() => _PatientNotesListState();
}

class _PatientNotesListState extends ConsumerState<PatientNotesList> {
  late Future<List<Map<String, dynamic>>> _future = _load();
  Future<List<Map<String, dynamic>>> _load() => ref.read(apiClientProvider).list('/doctor/patients/${widget.patient['id']}/notes');
  void _reload() => setState(() => _future = _load());

  Future<void> _edit([Map<String, dynamic>? note]) async {
    final saved = await pushPage<bool>(context, NoteEditorPage(patient: widget.patient, note: note));
    if (saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, 0),
        child: PrimaryButton(label: 'Add consultation note', icon: Icons.note_add_outlined, onPressed: () => _edit()),
      ),
      Expanded(
        child: futureList<List<Map<String, dynamic>>>(
          future: _future,
          onRetry: _reload,
          isEmpty: (rows) => rows.isEmpty,
          empty: const EmptyState(title: 'No notes yet', detail: 'Notes you write are private unless you share them with the patient.', icon: Icons.sticky_note_2_outlined),
          data: (rows) => ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (_, i) {
              final n = rows[i];
              final edits = (n['history'] as List? ?? []).length;
              return SectionCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  minVerticalPadding: AppSpacing.sm,
                  onTap: () => _edit(n),
                  title: Text(n['reason']?.toString() ?? 'Consultation', style: AppText.bodyStrong),
                  subtitle: Text(
                    [formatTimestamp(n['date']).split(',').first, if (n['followUpDate'] != null) 'Follow-up ${formatTimestamp(n['followUpDate']).split(',').first}', if (edits > 0) 'Edited $edits×'].join(' · '),
                    style: AppText.bodySm,
                  ),
                  trailing: StatusPill(label: n['patientFacing'] == true ? 'Shared' : 'Private', color: n['patientFacing'] == true ? AppColors.primary : AppColors.inkSecondary),
                ),
              );
            },
          ),
        ),
      ),
    ],
  );
}

class NoteEditorPage extends ConsumerStatefulWidget {
  const NoteEditorPage({super.key, required this.patient, this.note});
  final Map<String, dynamic> patient;
  final Map<String, dynamic>? note;
  @override
  ConsumerState<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends ConsumerState<NoteEditorPage> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c = {
    for (final k in ['reason', 'observations', 'assessment', 'advice', 'additional']) k: TextEditingController(text: widget.note?[k]?.toString() ?? ''),
  };
  late DateTime _date = parseBackendTime(widget.note?['date']) ?? DateTime.now();
  late DateTime? _followUp = parseBackendTime(widget.note?['followUpDate']);
  late bool _shared = widget.note?['patientFacing'] == true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime initial, {bool future = false}) => showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: future ? DateTime.now() : DateTime(2020),
    lastDate: DateTime.now().add(const Duration(days: 365)),
  );

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final body = {
      'patientId': widget.patient['id'],
      'date': _date.toUtc().toIso8601String(),
      for (final e in _c.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
      'followUpDate': _followUp == null ? null : DateTime(_followUp!.year, _followUp!.month, _followUp!.day, 9).toUtc().toIso8601String(),
      'patientFacing': _shared,
    };
    try {
      final api = ref.read(apiClientProvider);
      widget.note == null ? await api.post('/doctor/notes', body: body) : await api.patch('/doctor/notes/${widget.note!['id']}', body: body);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String key, String label, {int lines = 3, bool required = false}) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.md),
    child: TextFormField(
      controller: _c[key],
      minLines: 1,
      maxLines: lines,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
      validator: required ? (v) => (v == null || v.trim().length < 2) ? '$label is required' : null : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final history = (widget.note?['history'] as List? ?? []).cast<Map>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.note == null ? 'New note' : 'Edit note'), titleSpacing: 0),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
          children: [
            Text('For ${widget.patient['name']}', style: AppText.bodySm),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.event_outlined),
              label: Text('Date: ${formatTimestamp(_date.toUtc().toIso8601String()).split(',').first}'),
              onPressed: () async {
                final d = await _pick(_date);
                if (d != null) setState(() => _date = d);
              },
            ),
            const SizedBox(height: AppSpacing.md),
            _field('reason', 'Reason for consultation', lines: 2, required: true),
            _field('observations', 'Observations'),
            _field('assessment', 'Assessment'),
            _field('advice', 'Advice'),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.event_repeat_outlined),
              label: Text(_followUp == null ? 'Add follow-up date' : 'Follow-up: ${formatTimestamp(DateTime(_followUp!.year, _followUp!.month, _followUp!.day, 9).toUtc().toIso8601String()).split(',').first}'),
              onPressed: () async {
                final d = await _pick(_followUp ?? DateTime.now().add(const Duration(days: 7)), future: true);
                if (d != null) setState(() => _followUp = d);
              },
            ),
            const SizedBox(height: AppSpacing.md),
            _field('additional', 'Additional notes'),
            SectionCard(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
              child: SwitchListTile(
                value: _shared,
                onChanged: (v) => setState(() => _shared = v),
                title: Text('Share summary with patient', style: AppText.bodyStrong),
                subtitle: Text('The patient sees the date, reason, advice and follow-up date. Observations and assessment stay private.', style: AppText.bodySm),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Semantics(liveRegion: true, child: Text(_error!, style: AppText.bodySm.copyWith(color: AppColors.danger))),
            ],
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(label: 'Save note', loading: _saving, onPressed: _save),
            if (history.isNotEmpty) ...[
              const SectionHeader('Edit history'),
              for (final h in history.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: SectionCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Before ${formatTimestamp(h['editedAt'])}', style: AppText.caption),
                      Text(h['reason']?.toString() ?? '', style: AppText.bodyStrong),
                      if (h['assessment'] != null) Text(h['assessment'].toString(), style: AppText.bodySm),
                    ]),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================================
// Follow-ups
// =============================================================================================

class DoctorFollowUpsPage extends ConsumerStatefulWidget {
  const DoctorFollowUpsPage({super.key});
  @override
  ConsumerState<DoctorFollowUpsPage> createState() => _DoctorFollowUpsPageState();
}

class _DoctorFollowUpsPageState extends ConsumerState<DoctorFollowUpsPage> {
  String _tab = 'UPCOMING';
  late Future<List<Map<String, dynamic>>> _future = _load();
  Future<List<Map<String, dynamic>>> _load() => ref.read(apiClientProvider).list('/doctor/follow-ups');
  void _reload() {
    setState(() => _future = _load());
    ref.invalidate(doctorHomeProvider);
  }

  Future<void> _schedule() async {
    final patient = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
      builder: (c) => DoctorPatientsTab(title: 'Choose a patient', onPick: (p) => Navigator.pop(c, p)),
    ));
    if (patient == null || !mounted) return;
    if (await _sheet(patient: patient) == true) _reload();
  }

  Future<bool?> _sheet({Map<String, dynamic>? patient, Map<String, dynamic>? followUp}) => showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FollowUpSheet(patient: patient ?? Map<String, dynamic>.from(followUp!['patient'] as Map), followUp: followUp),
  );

  Future<void> _act(Future<dynamic> Function() call, String done) async {
    try {
      await call();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      _reload();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiClientProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Follow-ups'), titleSpacing: 0),
      floatingActionButton: FloatingActionButton.extended(onPressed: _schedule, icon: const Icon(Icons.add_rounded), label: const Text('Schedule')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.sm),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'UPCOMING', label: Text('Upcoming')),
                ButtonSegment(value: 'COMPLETED', label: Text('Completed')),
                ButtonSegment(value: 'MISSED', label: Text('Missed')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: futureList<List<Map<String, dynamic>>>(
              future: _future,
              onRetry: _reload,
              isEmpty: (rows) => rows.where((r) => r['state'] == _tab).isEmpty,
              empty: EmptyState(
                title: switch (_tab) { 'UPCOMING' => 'Nothing scheduled', 'COMPLETED' => 'No completed follow-ups', _ => 'No missed follow-ups' },
                detail: _tab == 'UPCOMING' ? 'Schedule a follow-up to remember when to check in with a patient.' : 'Follow-ups move here automatically.',
                icon: Icons.event_available_outlined,
              ),
              data: (rows) {
                final shown = rows.where((r) => r['state'] == _tab).toList();
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, 96),
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) {
                    final f = shown[i];
                    final p = Map<String, dynamic>.from(f['patient'] as Map? ?? {});
                    final open = f['state'] != 'COMPLETED';
                    return SectionCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          PatientAvatar(patient: p, size: 40),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(f['title']?.toString() ?? '', style: AppText.bodyStrong),
                              Text('${p['name'] ?? ''} · due ${formatTimestamp(f['dueAt'])}',
                                  style: AppText.bodySm.copyWith(color: f['state'] == 'MISSED' ? AppColors.danger : null)),
                            ]),
                          ),
                        ]),
                        if ((f['notes'] ?? '').toString().isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(f['notes'].toString(), style: AppText.bodySm),
                        ],
                        if (open)
                          Wrap(spacing: AppSpacing.xxs, children: [
                            TextButton(
                              onPressed: () async {
                                if (await _sheet(followUp: f) == true) _reload();
                              },
                              child: const Text('Edit date'),
                            ),
                            TextButton(onPressed: () => _act(() => api.post('/doctor/follow-ups/${f['id']}/remind'), 'Reminder sent in the app.'), child: const Text('Send reminder')),
                            TextButton(onPressed: () => _act(() => api.patch('/doctor/follow-ups/${f['id']}', body: {'status': 'DONE'}), 'Marked as completed.'), child: const Text('Mark completed')),
                          ]),
                      ]),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class _FollowUpSheet extends ConsumerStatefulWidget {
  const _FollowUpSheet({required this.patient, this.followUp});
  final Map<String, dynamic> patient;
  final Map<String, dynamic>? followUp;
  @override
  ConsumerState<_FollowUpSheet> createState() => _FollowUpSheetState();
}

class _FollowUpSheetState extends ConsumerState<_FollowUpSheet> {
  late final _title = TextEditingController(text: widget.followUp?['title']?.toString() ?? 'Review progress');
  late final _notes = TextEditingController(text: widget.followUp?['notes']?.toString() ?? '');
  late DateTime _due = parseBackendTime(widget.followUp?['dueAt']) ?? DateTime.now().add(const Duration(days: 7));
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().length < 2) {
      setState(() => _error = 'Enter what to follow up on');
      return;
    }
    setState(() => _saving = true);
    final due = DateTime(_due.year, _due.month, _due.day, 9).toUtc().toIso8601String();
    try {
      final api = ref.read(apiClientProvider);
      widget.followUp == null
          ? await api.post('/doctor/follow-ups', body: {'patientId': widget.patient['id'], 'title': _title.text.trim(), 'dueAt': due, 'notes': _notes.text.trim()})
          : await api.patch('/doctor/follow-ups/${widget.followUp!['id']}', body: {'dueAt': due, 'notes': _notes.text.trim(), 'status': 'OPEN'});
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Follow-up with ${widget.patient['name']}', style: AppText.title),
          const SizedBox(height: AppSpacing.md),
          TextField(controller: _title, enabled: widget.followUp == null, decoration: InputDecoration(labelText: 'What to check', errorText: _error)),
          const SizedBox(height: AppSpacing.sm),
          TextField(controller: _notes, maxLines: 3, minLines: 1, decoration: const InputDecoration(labelText: 'Notes (optional)')),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.event_outlined),
            label: Text('Due ${formatTimestamp(DateTime(_due.year, _due.month, _due.day, 9).toUtc().toIso8601String())}'),
            onPressed: () async {
              final picked = await showDatePicker(context: context, initialDate: _due.isBefore(DateTime.now()) ? DateTime.now() : _due, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
              if (picked != null) setState(() => _due = picked);
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(label: widget.followUp == null ? 'Schedule follow-up' : 'Save date', loading: _saving, onPressed: _save),
        ],
      ),
    ),
  );
}

// =============================================================================================
// Notifications (in-app)
// =============================================================================================

/// Returns a bottom-nav tab index when a notification belongs to a tab (requests, chats).
class DoctorNotificationsPage extends ConsumerStatefulWidget {
  const DoctorNotificationsPage({super.key});
  @override
  ConsumerState<DoctorNotificationsPage> createState() => _DoctorNotificationsPageState();
}

class _DoctorNotificationsPageState extends ConsumerState<DoctorNotificationsPage> {
  late Future<List<Map<String, dynamic>>> _future = _load();
  Future<List<Map<String, dynamic>>> _load() => ref.read(apiClientProvider).list('/doctor/notifications');
  void _reload() => setState(() => _future = _load());

  static (IconData, (Color, Color)) _icon(Object? type) => switch (type) {
    'ConsultationRequest' => (Icons.assignment_ind_outlined, AppColors.tintBlue),
    'NewMessage' => (Icons.chat_bubble_outline_rounded, AppColors.tintMint),
    'ReportShared' => (Icons.description_outlined, AppColors.tintViolet),
    'QrShared' => (Icons.qr_code_2_rounded, AppColors.tintMint),
    'Emergency' => (Icons.warning_amber_rounded, AppColors.tintRed),
    'MonitoringWarning' => (Icons.monitor_heart_outlined, AppColors.tintAmber),
    'FollowUpDue' => (Icons.event_available_outlined, AppColors.tintAmber),
    _ => (Icons.notifications_none_rounded, AppColors.tintBlue),
  };

  Future<void> _open(Map<String, dynamic> n) async {
    final data = Map<String, dynamic>.from(n['data'] as Map? ?? {});
    try {
      await ref.read(apiClientProvider).patch('/notifications/${n['id']}/read');
    } catch (_) {}
    if (!mounted) return;
    switch (data['type']) {
      case 'ConsultationRequest':
        Navigator.pop(context, 1);
      case 'NewMessage' || 'ReportShared':
        Navigator.pop(context, 2);
      case 'Emergency':
        await pushPage(context, data['emergencyId'] != null ? AlertDetailPage(alertId: data['emergencyId'].toString()) : const DoctorAlertsPage());
      case 'MonitoringWarning':
        await pushPage(context, MonitoringDetailPage(patient: {'id': data['patientId'], 'name': 'Patient monitoring'}));
      case 'FollowUpDue':
        await pushPage(context, const DoctorFollowUpsPage());
      case 'QrShared':
        if (data['patientId'] != null) await pushPage(context, PatientSummaryPage(patientId: data['patientId'].toString()));
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Notifications'),
      titleSpacing: 0,
      actions: [
        TextButton(
          onPressed: () async {
            await ref.read(apiClientProvider).post('/doctor/notifications/read-all');
            _reload();
          },
          child: const Text('Mark all read'),
        ),
        const SizedBox(width: AppSpacing.xs),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: () async => _reload(),
      child: futureList<List<Map<String, dynamic>>>(
        future: _future,
        onRetry: _reload,
        isEmpty: (rows) => rows.isEmpty,
        empty: const EmptyState(title: "You're all caught up", detail: 'Requests, messages, alerts and reminders show up here.', icon: Icons.notifications_none_rounded),
        data: (rows) => ListView.separated(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.xs),
          itemBuilder: (_, i) {
            final n = rows[i];
            final (icon, tint) = _icon((n['data'] as Map?)?['type']);
            final unread = n['read'] != true;
            return Semantics(
              label: unread ? 'Unread' : null,
              child: SectionCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  minVerticalPadding: AppSpacing.sm,
                  onTap: () => _open(n),
                  leading: IconBadge(icon: icon, tint: tint, size: 44),
                  title: Text(n['title']?.toString() ?? 'Update', style: AppText.bodyStrong.copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
                  subtitle: Text('${n['body'] ?? ''}\n${relativeTime(n['createdAt'])}', style: AppText.bodySm),
                  isThreeLine: true,
                  trailing: unread
                      ? Container(width: 10, height: 10, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle))
                      : null,
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}
