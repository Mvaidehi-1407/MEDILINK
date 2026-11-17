import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/api_client.dart';
import '../theme/tokens.dart';
import '../ui/app_icons.dart' show SkeletonList;
import '../ui/components.dart';
import '../ui/fallback.dart';
import '../ui/format.dart';
import '../widgets/common.dart';
import 'doctor_care.dart';
import 'doctor_chat.dart';
import 'doctor_portal.dart';

// =============================================================================================
// QR scanner
// =============================================================================================

class DoctorScannerPage extends ConsumerStatefulWidget {
  const DoctorScannerPage({super.key});
  @override
  ConsumerState<DoctorScannerPage> createState() => _DoctorScannerPageState();
}

class _DoctorScannerPageState extends ConsumerState<DoctorScannerPage> {
  final _camera = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _busy = false;
  bool _torch = false;
  int? _errorStatus; // 0 = offline

  Future<void> _onDetect(BarcodeCapture capture) async {
    final raw = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (_busy || raw == null) return;
    setState(() {
      _busy = true;
      _errorStatus = null;
    });
    try {
      final res = Map<String, dynamic>.from(await ref.read(apiClientProvider).post('/doctor/qr/redeem', body: {'token': raw}) as Map);
      if (!mounted) return;
      await _camera.stop();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PatientSummaryPage(patientId: res['patientId'].toString())));
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorStatus = e.statusCode ?? 0);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scan patient QR'),
      titleSpacing: 0,
      actions: [
        IconButton(
          tooltip: _torch ? 'Turn flashlight off' : 'Turn flashlight on',
          onPressed: () async {
            await _camera.toggleTorch();
            if (mounted) setState(() => _torch = !_torch);
          },
          icon: Icon(_torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded),
        ),
        const SizedBox(width: AppSpacing.xs),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _camera,
                  onDetect: _onDetect,
                  errorBuilder: (_, _) => const FallbackView(
                    kind: FallbackKind.permission,
                    title: 'Camera access needed',
                    message: 'Allow camera access to scan a patient QR code, or search by Patient ID below.',
                  ),
                ),
                IgnorePointer(
                  child: SizedBox.square(dimension: 240, child: CustomPaint(painter: _FrameCorners())),
                ),
                if (_busy) const CircularProgressIndicator(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_errorStatus != null)
                  Semantics(
                    liveRegion: true,
                    child: FallbackView(
                      compact: true,
                      kind: switch (_errorStatus) { 0 => FallbackKind.offline, 403 => FallbackKind.permission, 410 || 422 || 404 => FallbackKind.notFound, _ => FallbackKind.error },
                      title: switch (_errorStatus) { 0 => null, 403 => 'No consent', 410 || 422 || 404 => 'QR code expired or invalid', _ => "Couldn't check this QR code" },
                      message: switch (_errorStatus) {
                        0 => null,
                        403 => "This patient hasn't given you access. Ask them to share their MediLink QR code from their app.",
                        410 || 422 || 404 => 'Ask the patient to open MediLink and show a new QR code.',
                        _ => 'Please try scanning again.',
                      },
                      actionLabel: 'Scan again',
                      onAction: () => setState(() => _errorStatus = null),
                    ),
                  )
                else
                  Text("Point the camera at the QR code on the patient's MediLink app.", textAlign: TextAlign.center, style: AppText.body),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
                  onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                    builder: (c) => DoctorPatientsTab(
                      title: 'Search by Patient ID',
                      onPick: (p) => Navigator.of(c).pushReplacement(MaterialPageRoute(builder: (_) => PatientSummaryPage(patientId: p['id'].toString()))),
                    ),
                  )),
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Search by Patient ID'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _FrameCorners extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const len = 34.0;
    final p = Paint()
      ..color = AppColors.primaryTint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    for (final (x, y, sx, sy) in [(0.0, 0.0, 1.0, 1.0), (w, 0.0, -1.0, 1.0), (0.0, h, 1.0, -1.0), (w, h, -1.0, -1.0)]) {
      canvas.drawPath(Path()..moveTo(x, y + sy * len)..lineTo(x, y)..lineTo(x + sx * len, y), p);
    }
  }

  @override
  bool shouldRepaint(_FrameCorners oldDelegate) => false;
}

// =============================================================================================
// Patient summary (connected or QR-only). Read-only; no AI call here.
// =============================================================================================

/// Patient profile. Connected patients get tabs (Overview | Health | History) and actions;
/// QR-only access (or [summaryOnly]) shows the read-only summary and nothing else.
class PatientSummaryPage extends ConsumerStatefulWidget {
  const PatientSummaryPage({super.key, required this.patientId, this.summaryOnly = false});
  final String patientId;
  final bool summaryOnly;
  @override
  ConsumerState<PatientSummaryPage> createState() => _PatientSummaryPageState();
}

class _PatientSummaryPageState extends ConsumerState<PatientSummaryPage> {
  late Future<Map<String, dynamic>> _future = _load();

  Future<Map<String, dynamic>> _load() async =>
      Map<String, dynamic>.from(await ref.read(apiClientProvider).get('/doctor/patients/${widget.patientId}/summary') as Map);
  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _future,
    builder: (context, snap) {
      Widget page(Widget body, {PreferredSizeWidget? bottom}) => Scaffold(
        appBar: AppBar(title: Text(widget.summaryOnly ? 'QR summary' : 'Patient profile'), titleSpacing: 0, bottom: bottom),
        body: body,
      );
      if (snap.connectionState != ConnectionState.done) {
        return page(const Padding(padding: EdgeInsets.all(AppSpacing.gutter), child: SkeletonList(rows: 4)));
      }
      final err = snap.error;
      if (err is ApiException && err.statusCode == 403) {
        return page(patientUnavailable(context, "This patient hasn't given you access. Ask them to show their MediLink QR code or accept your consultation."));
      }
      if (err != null) {
        final kind = err is ApiException && err.statusCode == null ? FallbackKind.offline : FallbackKind.error;
        return page(FallbackView(
          kind: kind,
          message: kind == FallbackKind.offline ? null : "This patient's summary couldn't be loaded right now.",
          actionLabel: 'Try again',
          onAction: _reload,
        ));
      }
      final s = snap.data!;
      final p = Map<String, dynamic>.from(s['patient'] as Map);
      if (s['connected'] != true || widget.summaryOnly) {
        return page(_scroll([_header(s, p), _qrLinks(s, p), ..._qrSummary(s), ..._overview(s, withCaretakers: false), ..._health(s, withReports: false)]));
      }
      return DefaultTabController(
        length: 3,
        child: page(
          TabBarView(children: [
            _scroll([_header(s, p), _actions(s, p), ..._overview(s, withCaretakers: true)]),
            _scroll([..._qrSummary(s), ..._health(s, withReports: true)]),
            _History(patient: p, consultations: (s['consultations'] as List? ?? []).cast<Map>()),
          ]),
          bottom: const TabBar(tabs: [Tab(text: 'Overview'), Tab(text: 'Health'), Tab(text: 'History')]),
        ),
      );
    },
  );

  Widget _scroll(List<Widget> children) => RefreshIndicator(
    onRefresh: () async => _reload(),
    child: ListView(padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, AppSpacing.xl), children: children),
  );

  Widget _header(Map<String, dynamic> s, Map<String, dynamic> p) => SectionCard(
    child: Row(children: [
      PatientAvatar(patient: p, size: 64),
      const SizedBox(width: AppSpacing.md),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p['name']?.toString() ?? 'Patient', style: AppText.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          Text([p['medilinkId'] ?? pidOf(p['id']), if (p['age'] != null) 'Age ${p['age']}'].join(' · '), style: AppText.bodySm),
          if ((p['phone'] ?? '').toString().isNotEmpty) Text(p['phone'].toString(), style: AppText.bodySm),
          const SizedBox(height: AppSpacing.xxs),
          s['connected'] == true
              ? const StatusPill(label: 'Connected', color: AppColors.success)
              : StatusPill(label: 'QR access until ${formatTimestamp(s['qrExpiresAt'])}', color: AppColors.warning),
        ]),
      ),
    ]),
  );

  /// QR screen links: full patient page and message. Both need an accepted consultation; a QR-only
  /// doctor sees why instead of a dead button.
  Widget _qrLinks(Map<String, dynamic> s, Map<String, dynamic> p) {
    final connected = s['connected'] == true;
    final shape = OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder());
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: shape,
              onPressed: connected ? () => pushPage(context, PatientSummaryPage(patientId: p['id'].toString())) : null,
              icon: const Icon(Icons.person_outline_rounded, size: 18),
              label: const Text('Full profile'),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
              onPressed: connected ? () => pushPage(context, DoctorChatPage(conversationId: s['conversationId'].toString(), patient: p)) : null,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
              label: const Text('Message'),
            ),
          ),
        ]),
        if (!connected)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text('The full page and messaging open once this patient sends you a consultation request and you accept it.', style: AppText.bodySm),
          ),
      ]),
    );
  }

  /// Risk level, newest AI report summary and recent emergencies (stored records only).
  List<Widget> _qrSummary(Map<String, dynamic> s) {
    final risk = s['risk'] as Map?;
    final report = s['reportSummary'] as Map?;
    final emergencies = (s['recentEmergencies'] as List? ?? []).cast<Map>();
    final findings = (report?['keyFindings'] as List? ?? const []);
    return [
      const SectionHeader('Risk level'),
      SectionCard(
        child: risk == null
            ? Text('No risk assessment recorded yet.', style: AppText.body)
            : Row(children: [
                StatusPill(label: riskStyle(risk['riskLevel']).$1, color: riskStyle(risk['riskLevel']).$2),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text('From the reading on ${formatTimestamp(risk['timestamp'])}', style: AppText.bodySm)),
              ]),
      ),
      const SectionHeader('Latest report summary'),
      SectionCard(
        child: report == null
            ? Text('No AI report summary yet.', style: AppText.body)
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(report['filename']?.toString() ?? 'Report', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text([report['documentType'], report['date'] ?? formatTimestamp(report['createdAt']).split(',').first].whereType<Object>().join(' · '), style: AppText.bodySm),
                for (final f in findings) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $f', style: AppText.body)),
                const SizedBox(height: AppSpacing.xs),
                Text(report['disclaimer']?.toString() ?? '', style: AppText.caption),
              ]),
      ),
      const SectionHeader('Recent emergencies'),
      SectionCard(
        padding: emergencies.isEmpty ? const EdgeInsets.all(AppSpacing.md) : EdgeInsets.zero,
        child: emergencies.isEmpty
            ? Text('No emergencies recorded.', style: AppText.body)
            : Column(children: [
                for (final e in emergencies)
                  ListTile(
                    leading: Icon(e['status'] == 'RESOLVED' || e['status'] == 'CANCELLED' ? Icons.check_circle_outline_rounded : Icons.warning_amber_rounded,
                        color: e['status'] == 'RESOLVED' || e['status'] == 'CANCELLED' ? AppColors.success : AppColors.danger),
                    title: Text(e['status'].toString().replaceAll('_', ' ').toLowerCase().replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase()), style: AppText.bodyStrong),
                    subtitle: Text(formatTimestamp(e['createdAt']), style: AppText.bodySm),
                  ),
              ]),
      ),
    ];
  }

  Widget _actions(Map<String, dynamic> s, Map<String, dynamic> p) {
    Widget action(IconData icon, String label, VoidCallback onTap, {bool primary = false}) => primary
        ? FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()), onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label))
        : OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()), onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label));
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: LayoutBuilder(builder: (context, c) {
        final half = (c.maxWidth - AppSpacing.xs) / 2;
        return Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
          SizedBox(width: half, child: action(Icons.chat_bubble_outline_rounded, 'Open chat', () => pushPage(context, DoctorChatPage(conversationId: s['conversationId'].toString(), patient: p)), primary: true)),
          SizedBox(width: half, child: action(Icons.monitor_heart_outlined, 'Monitoring', () => pushPage(context, MonitoringDetailPage(patient: p)))),
          SizedBox(width: half, child: action(Icons.qr_code_2_rounded, 'QR summary', () => pushPage(context, PatientSummaryPage(patientId: p['id'].toString(), summaryOnly: true)))),
          SizedBox(width: half, child: action(Icons.note_add_outlined, 'Add note', () => pushPage(context, NoteEditorPage(patient: p)))),
        ]);
      }),
    );
  }

  List<Widget> _overview(Map<String, dynamic> s, {required bool withCaretakers}) {
    final latest = s['latest'] as Map?;
    final device = Map<String, dynamic>.from(s['device'] as Map? ?? {});
    final caretakers = (s['caretakers'] as List?)?.cast<Map>();
    String recorded(Object? v) => v == null || (v is List && v.isEmpty) ? 'Not recorded' : (v is List ? v.join(', ') : v.toString());
    return [
      const SectionHeader('Latest vitals'),
      SectionCard(
        child: latest == null
            ? Text('No readings recorded yet.', style: AppText.body)
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: _Vital(label: 'Heart rate', value: '${latest['heartRate'] ?? '--'}', unit: 'BPM', tint: AppColors.tintRed, icon: Icons.favorite_outline_rounded)),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: _Vital(label: 'SpO₂', value: '${latest['spo2'] ?? '--'}', unit: '%', tint: AppColors.tintBlue, icon: Icons.water_drop_outlined)),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Text('Recorded ${formatTimestamp(latest['timestamp'])}${latest['source'] == 'DEMO' ? ' · Demo data' : ''}', style: AppText.bodySm),
              ]),
      ),
      const SizedBox(height: AppSpacing.sm),
      SectionCard(
        child: Row(children: [
          IconBadge(icon: Icons.watch_outlined, tint: device['status'] == 'CONNECTED' ? AppColors.tintMint : AppColors.tintBlue, size: 40),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(device['name']?.toString() ?? 'Wearable', style: AppText.bodyStrong)),
          StatusPill(
            label: switch (device['status']) { 'CONNECTED' => 'Streaming', 'OFFLINE' => 'Offline', _ => 'No device' },
            color: device['status'] == 'CONNECTED' ? AppColors.success : AppColors.inkSecondary,
          ),
        ]),
      ),
      const SectionHeader('Medical background'),
      SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Medical history', style: AppText.caption),
          Text(recorded(s['history']), style: AppText.bodyStrong),
          const SizedBox(height: AppSpacing.sm),
          Text('Allergies', style: AppText.caption),
          Text(recorded(s['allergies']), style: AppText.bodyStrong),
        ]),
      ),
      if (withCaretakers && caretakers != null) ...[
        const SectionHeader('Caretakers'),
        SectionCard(
          padding: caretakers.isEmpty ? const EdgeInsets.all(AppSpacing.md) : EdgeInsets.zero,
          child: caretakers.isEmpty
              ? Text('No caretakers on file.', style: AppText.body)
              : Column(children: [
                  for (final c in caretakers)
                    ListTile(title: Text(c['name']?.toString() ?? '', style: AppText.bodyStrong), subtitle: Text(c['phone']?.toString() ?? '', style: AppText.bodySm)),
                ]),
        ),
      ],
    ];
  }

  List<Widget> _health(Map<String, dynamic> s, {required bool withReports}) {
    final abnormal = (s['abnormal'] as List? ?? []).cast<Map>();
    final reports = (s['reports'] as List? ?? []).cast<Map>();
    return [
      const SectionHeader('Recent abnormal readings'),
      if (abnormal.isEmpty)
        SectionCard(child: Text('No abnormal readings recorded.', style: AppText.body))
      else
        SectionCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (final r in abnormal)
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
                title: Text('HR ${r['heartRate'] ?? '--'} · SpO₂ ${r['spo2'] ?? '--'}%', style: AppText.bodyStrong),
                subtitle: Text(formatTimestamp(r['timestamp']), style: AppText.bodySm),
                trailing: StatusPill(label: riskStyle(r['riskLevel']).$1, color: riskStyle(r['riskLevel']).$2),
              ),
          ]),
        ),
      if (withReports) ...[
        const SectionHeader('Shared reports'),
        SectionCard(
          padding: reports.isEmpty ? const EdgeInsets.all(AppSpacing.md) : EdgeInsets.zero,
          child: reports.isEmpty
              ? Text('No reports shared in chat yet.', style: AppText.body)
              : Column(children: [
                  for (final r in reports)
                    ListTile(
                      leading: Icon(r['contentType'].toString().startsWith('image/') ? Icons.image_outlined : Icons.picture_as_pdf_outlined, color: AppColors.primary),
                      title: Text(r['filename'].toString(), style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('Shared ${formatTimestamp(r['createdAt'])} · open it from the chat', style: AppText.bodySm),
                    ),
                ]),
        ),
      ],
    ];
  }
}

class _History extends StatelessWidget {
  const _History({required this.patient, required this.consultations});
  final Map<String, dynamic> patient;
  final List<Map> consultations;

  static String _state(Object? s) => switch (s) { 'GRANTED' => 'active', 'REVOKED' => 'ended', 'REJECTED' => 'declined', _ => 'pending' };

  @override
  Widget build(BuildContext context) => Column(children: [
    if (consultations.isNotEmpty)
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, 0),
        child: Text(
          'Consultations: ${consultations.map((c) => '${formatTimestamp(c['createdAt']).split(',').first} (${_state(c['status'])})').join(', ')}',
          style: AppText.bodySm,
        ),
      ),
    Expanded(child: PatientNotesList(patient: patient)),
  ]);
}

class _Vital extends StatelessWidget {
  const _Vital({required this.label, required this.value, required this.unit, required this.tint, required this.icon});
  final String label, value, unit;
  final (Color, Color) tint;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label $value $unit',
    excludeSemantics: true,
    child: Row(children: [
      IconBadge(icon: icon, tint: tint, size: 40),
      const SizedBox(width: AppSpacing.xs),
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppText.caption),
          Text.rich(TextSpan(children: [
            TextSpan(text: value, style: AppText.title.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            TextSpan(text: ' $unit', style: AppText.bodySm),
          ])),
        ]),
      ),
    ]),
  );
}

