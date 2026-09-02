import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame, HealthStatusCard;
import 'messaging.dart';

/// Real assigned/linked-patient list for Doctor and Caregiver roles: every patient who has
/// GRANTED consent to this clinician/caregiver, resolved to real names via /users.
class PatientConnections extends ConsumerStatefulWidget {
  const PatientConnections({super.key});
  @override
  ConsumerState<PatientConnections> createState() => _PatientConnectionsState();
}

class _PatientConnectionsState extends ConsumerState<PatientConnections> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<List<Map<String, dynamic>>> _fetchConnectedPatients() async {
    final api = ref.read(apiClientProvider);
    final myId = ref.read(sessionProvider).userId;
    final consents = await api.list('/consents');
    final granted = consents.where((c) => c['status'] == 'GRANTED' && c['requesterId'] == myId).toList();
    final patients = <Map<String, dynamic>>[];
    for (final consent in granted) {
      try {
        final user = await api.get('/users/${consent['patientId']}') as Map?;
        if (user != null) {
          patients.add({...Map<String, dynamic>.from(user), 'consentId': consent['id']});
        }
      } catch (_) {
        // A single unreachable profile shouldn't blank the whole list.
      }
    }
    return patients;
  }

  void _load() {
    setState(() => _future = _fetchConnectedPatients());
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Patients',
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState();
        if (snapshot.hasError) {
          return ErrorState(message: snapshot.error.toString(), onRetry: _load);
        }
        final patients = snapshot.data!;
        if (patients.isEmpty) {
          return const EmptyState(
            title: 'No connected patients yet',
            detail: 'Patients appear here once they grant your consent request.',
            icon: Icons.groups_outlined,
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: patients.length,
          itemBuilder: (context, i) {
            final patient = patients[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                  title: Text(patient['name']?.toString() ?? 'Patient'),
                  subtitle: Text(patient['email']?.toString() ?? ''),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => PatientDetailPage(patientId: patient['id'].toString(), patientName: patient['name']?.toString() ?? 'Patient')),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class PatientDetailPage extends ConsumerStatefulWidget {
  const PatientDetailPage({super.key, required this.patientId, required this.patientName});
  final String patientId;
  final String patientName;
  @override
  ConsumerState<PatientDetailPage> createState() => _PatientDetailPageState();
}

class _PatientDetailPageState extends ConsumerState<PatientDetailPage> {
  Future<List<Map<String, dynamic>>>? _emergencies;
  Future<List<Map<String, dynamic>>>? _records;
  bool _generatingReport = false;
  String? _reportMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = ref.read(apiClientProvider);
    setState(() {
      _emergencies = api.emergencies(widget.patientId);
      _records = api.medicalRecords(patientId: widget.patientId);
    });
  }

  Future<void> _viewRecord(Map<String, dynamic> record) async {
    try {
      final bytes = await ref.read(apiClientProvider).downloadMedicalRecord(record['id'].toString());
      if (!mounted) return;
      final contentType = record['contentType']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(record['filename']?.toString() ?? 'Medical record'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (contentType.startsWith('image/'))
                    Image.memory(Uint8List.fromList(bytes))
                  else if (contentType == 'text/plain')
                    Text(String.fromCharCodes(bytes))
                  else
                    Text('${(bytes.length / 1024).toStringAsFixed(1)} KB $contentType file.'),
                  if (record['summaryStatus'] == 'AVAILABLE' && record['summary'] != null) ...[
                    const Divider(height: 24),
                    const Text('AI summary', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    if ((record['summary']['keyObservations'] as List?)?.isNotEmpty ?? false)
                      Text((record['summary']['keyObservations'] as List).join('\n')),
                    if ((record['summary']['simplifiedExplanation']?.toString() ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(record['summary']['simplifiedExplanation'].toString()),
                    ],
                  ] else if (record['summaryStatus'] == 'UNAVAILABLE') ...[
                    const Divider(height: 24),
                    const Text(
                      'No AI summary available for this file type.',
                      style: TextStyle(color: Colors.blueGrey, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        ),
      );
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open this record.')));
    }
  }

  Future<void> _generateReport() async {
    setState(() {
      _generatingReport = true;
      _reportMessage = null;
    });
    try {
      final report = await ref.read(apiClientProvider).post(
        '/reports/patient-summary/${widget.patientId}',
      ) as Map;
      if (mounted) {
        setState(() => _reportMessage = 'Report generated (${report['reportGenerator']}). Tap "View" to see it.');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _reportMessage = e.message);
    } catch (_) {
      if (mounted) setState(() => _reportMessage = 'Could not generate the report. Try again.');
    } finally {
      if (mounted) setState(() => _generatingReport = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: widget.patientName,
    actions: [
      IconButton(
        icon: const Icon(Icons.chat_bubble_outline),
        onPressed: () {
          final myId = ref.read(sessionProvider).userId;
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ConversationPage(
              conversationId: conversationIdFor(myId, widget.patientId),
              otherPartyId: widget.patientId,
              title: widget.patientName,
            ),
          ));
        },
      ),
    ],
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        HealthStatusCard(patientId: widget.patientId),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: PrimaryButton(
                label: 'Generate report',
                loading: _generatingReport,
                onPressed: _generateReport,
                icon: Icons.description_outlined,
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PatientReportsPage(patientId: widget.patientId, patientName: widget.patientName),
              )),
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('View'),
            ),
          ],
        ),
        if (_reportMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_reportMessage!, style: const TextStyle(color: MedilinkColors.blue)),
          ),
        const SizedBox(height: 20),
        Text('Emergency & escalation history', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _emergencies,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState();
            if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _load);
            final events = snapshot.data!;
            if (events.isEmpty) {
              return const EmptyState(title: 'No emergency history', detail: 'Past events for this patient appear here.', icon: Icons.history);
            }
            return Column(
              children: events.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SectionCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${e['trigger'] ?? 'Emergency'} · ${e['createdAt'] ?? ''}'),
                    subtitle: e['panicAttackType'] != null && e['panicAttackType'] != 'NONE_DETECTED'
                        ? Text('Panic pattern: ${e['panicAttackType']}')
                        : null,
                    trailing: Wrap(spacing: 6, children: [
                      StatusBadge(label: e['status'].toString()),
                      if (e['escalationStage'] != null)
                        EscalationStageBadge(status: e['status'].toString(), escalationStage: e['escalationStage'].toString()),
                    ]),
                  ),
                ),
              )).toList(),
            );
          },
        ),
        const SizedBox(height: 20),
        Text('Uploaded records', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _records,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState();
            if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _load);
            final records = snapshot.data!;
            if (records.isEmpty) {
              return const EmptyState(title: 'No records shared', detail: 'Patient-uploaded records with consented access appear here.', icon: Icons.folder_open_outlined);
            }
            return Column(
              children: records.map((r) => SectionCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(r['filename']?.toString() ?? 'Record'),
                  subtitle: Text(r['category']?.toString() ?? ''),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _viewRecord(r),
                ),
              )).toList(),
            );
          },
        ),
      ],
    ),
  );
}

class PatientReportsPage extends ConsumerStatefulWidget {
  const PatientReportsPage({super.key, required this.patientId, required this.patientName});
  final String patientId;
  final String patientName;
  @override
  ConsumerState<PatientReportsPage> createState() => _PatientReportsPageState();
}

class _PatientReportsPageState extends ConsumerState<PatientReportsPage> {
  Future<List<Map<String, dynamic>>>? _reports;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() => _reports = ref.read(apiClientProvider).list('/reports/patient/${widget.patientId}'));

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Reports · ${widget.patientName}',
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: _reports,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState();
        if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _load);
        final reports = snapshot.data!;
        if (reports.isEmpty) {
          return const EmptyState(
            title: 'No reports yet',
            detail: 'Generate a report from the patient page to see it here.',
            icon: Icons.description_outlined,
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: reports.length,
          itemBuilder: (context, i) {
            final r = reports[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SectionCard(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              r['reportType']?.toString() ?? 'Report',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                          StatusBadge(label: r['reportGenerator']?.toString() ?? ''),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(r['timestamp']?.toString() ?? '', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Text(r['reportText']?.toString() ?? ''),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
