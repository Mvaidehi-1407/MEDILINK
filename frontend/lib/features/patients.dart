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
        setState(() => _reportMessage = 'Report generated (${report['reportGenerator']}). Open Reports to view it.');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _reportMessage = e.message);
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
        PrimaryButton(
          label: 'Generate report',
          loading: _generatingReport,
          onPressed: _generateReport,
          icon: Icons.description_outlined,
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
                ),
              )).toList(),
            );
          },
        ),
      ],
    ),
  );
}
