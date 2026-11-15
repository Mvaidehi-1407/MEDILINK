import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/components.dart';
import '../ui/format.dart';
import '../widgets/common.dart';
import 'doctor_care.dart' show ChipFilter;
import 'doctor_chat.dart';
import 'doctor_portal.dart';
import 'messaging.dart' show conversationIdFor;

// Patient side of doctor messaging. The Home Messages card and the Connections row both open
// [PatientMessagesPage]; both read [patientConversationsProvider], so they show one unread count.

final patientConversationsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  final refresh = Timer(const Duration(seconds: 30), ref.invalidateSelf); // keeps the badge live
  ref.onDispose(refresh.cancel);
  return ref.read(apiClientProvider).list('/consultations/conversations');
});

final patientUnreadProvider = Provider.autoDispose<int>(
  (ref) => (ref.watch(patientConversationsProvider).value ?? const []).fold(0, (sum, c) => sum + ((c['unread'] as num?)?.toInt() ?? 0)),
);

final _doctorsProvider = FutureProvider.autoDispose((ref) => ref.read(apiClientProvider).list('/consultations/doctors'));
final _myRequestsProvider = FutureProvider.autoDispose((ref) => ref.read(apiClientProvider).list('/consultations'));
final _followUpsProvider = FutureProvider.autoDispose((ref) => ref.read(apiClientProvider).list('/consultations/follow-ups'));
final _summariesProvider = FutureProvider.autoDispose((ref) => ref.read(apiClientProvider).list('/consultations/summaries'));

void _refreshAll(WidgetRef ref) {
  ref.invalidate(patientConversationsProvider);
  ref.invalidate(_doctorsProvider);
  ref.invalidate(_myRequestsProvider);
  ref.invalidate(_followUpsProvider);
  ref.invalidate(_summariesProvider);
}

String? _specialty(Map d) => (d['specialization'] == 'Other' ? d['specializationOther'] : d['specialization'])?.toString();

String _drName(Map d) {
  final n = d['name']?.toString() ?? 'Doctor';
  return n.toLowerCase().startsWith('dr') ? n : 'Dr. $n';
}

String? _availability(Map d) {
  final days = (d['availabilityDays'] as List? ?? const []).join(', ');
  final parts = [days, d['availabilityHours'], d['availabilityClinic']].where((p) => p != null && p.toString().isNotEmpty).join(' · ');
  return parts.isEmpty ? null : parts;
}

enum _State { request, pending, accepted, declined, unavailable }

/// Card state from my newest request with this doctor (the backend lists newest first).
(_State, Map<String, dynamic>?) _stateFor(Map d, List<Map<String, dynamic>> requests) {
  final r = requests.where((r) => r['requesterId'] == d['userId']).firstOrNull;
  switch (r?['status']) {
    case 'GRANTED':
      return (_State.accepted, r);
    case 'REQUESTED':
      return (_State.pending, r);
    case 'REJECTED':
      final at = parseBackendTime(r!['declinedAt']);
      if (at != null && DateTime.now().difference(at) < const Duration(hours: 24)) return (_State.declined, r);
  }
  return (d['accepting'] == true ? _State.request : _State.unavailable, r);
}

Future<void> openDoctorChat(BuildContext context, WidgetRef ref, Map<String, dynamic> doctor, {bool active = true}) async {
  final me = ref.read(sessionProvider).userId;
  final peer = {...doctor, 'id': doctor['userId'], 'name': _drName(doctor)};
  await pushPage(context, DoctorChatPage(
    conversationId: conversationIdFor(me, doctor['userId'].toString()),
    patient: peer,
    readOnly: !active,
    onProfile: () => showDoctorSheet(context, ref, doctor),
  ));
  _refreshAll(ref);
}

// =============================================================================================
// Messages screen
// =============================================================================================

class PatientMessagesPage extends ConsumerWidget {
  const PatientMessagesPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(patientUnreadProvider);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Messages'),
          titleSpacing: 0,
          bottom: TabBar(tabs: [
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('My Chats'),
                if (unread > 0) ...[const SizedBox(width: AppSpacing.xs), Badge(label: Text('$unread'))],
              ]),
            ),
            const Tab(text: 'Find Doctors'),
          ]),
        ),
        body: const TabBarView(children: [_MyChats(), _FindDoctors()]),
      ),
    );
  }
}

class _MyChats extends ConsumerWidget {
  const _MyChats();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followUps = ref.watch(_followUpsProvider).value ?? const [];
    final summaries = ref.watch(_summariesProvider).value ?? const [];
    return asyncBody(
      ref.watch(patientConversationsProvider),
      onRetry: () => _refreshAll(ref),
      data: (chats) {
        final names = {for (final c in chats) (c['doctor'] as Map)['userId']: _drName(c['doctor'] as Map)};
        return RefreshIndicator(
          onRefresh: () async => _refreshAll(ref),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, AppSpacing.xl),
            children: [
              for (final f in followUps)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: SectionCard(
                    child: Row(children: [
                      const Icon(Icons.event_available_outlined, color: AppColors.primary),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Follow-up: ${f['title']}', style: AppText.bodyStrong),
                          Text('${f['doctorName']} · due ${formatTimestamp(f['dueAt']).split(',').first}', style: AppText.bodySm),
                        ]),
                      ),
                    ]),
                  ),
                ),
              if (chats.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xl),
                  child: Column(children: [
                    const EmptyState(title: 'No chats yet', detail: 'Find a doctor to start talking.', icon: Icons.chat_bubble_outline_rounded),
                    FilledButton(onPressed: () => DefaultTabController.of(context).animateTo(1), child: const Text('Find a doctor')),
                  ]),
                ),
              for (final c in chats) _ChatRow(chat: c),
              if (summaries.isNotEmpty) ...[
                const SectionHeader('Visit summaries'),
                for (final s in summaries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: SectionCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s['reason']?.toString() ?? 'Consultation', style: AppText.bodyStrong),
                        Text('${names[s['doctorId']] ?? 'Your doctor'} · ${formatTimestamp(s['date']).split(',').first}', style: AppText.bodySm),
                        if ((s['advice'] ?? '').toString().isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(s['advice'].toString(), style: AppText.body),
                        ],
                      ]),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ChatRow extends ConsumerWidget {
  const _ChatRow({required this.chat});
  final Map<String, dynamic> chat;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = Map<String, dynamic>.from(chat['doctor'] as Map);
    final unread = (chat['unread'] as num?)?.toInt() ?? 0;
    final active = chat['active'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SectionCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          leading: PatientAvatar(patient: d, size: 48),
          title: Text(_drName(d), style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            active ? (chat['lastMessage']?.toString() ?? _specialty(d) ?? 'Say hello') : 'Consultation ended · read-only',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodySm.copyWith(fontWeight: unread > 0 ? FontWeight.w700 : null),
          ),
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (chat['lastAt'] != null) Text(relativeTime(chat['lastAt']), style: AppText.caption),
            if (unread > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Badge(label: Text('$unread'))),
          ]),
          onTap: () => openDoctorChat(context, ref, d, active: active),
        ),
      ),
    );
  }
}

// =============================================================================================
// Find Doctors
// =============================================================================================

class _FindDoctors extends ConsumerStatefulWidget {
  const _FindDoctors();
  @override
  ConsumerState<_FindDoctors> createState() => _FindDoctorsState();
}

class _FindDoctorsState extends ConsumerState<_FindDoctors> {
  static const _page = 20;
  String _q = '';
  String _spec = 'All';
  int _shown = _page;

  @override
  Widget build(BuildContext context) {
    final requests = ref.watch(_myRequestsProvider).value ?? const [];
    return asyncBody(
      ref.watch(_doctorsProvider),
      onRetry: () => _refreshAll(ref),
      data: (doctors) {
        if (doctors.isEmpty) {
          return const EmptyState(title: 'No doctors yet', detail: 'No doctors have joined yet. Check back soon.', icon: Icons.medical_services_outlined);
        }
        final specs = {for (final d in doctors) ?_specialty(d)}.toList()..sort();
        final q = _q.toLowerCase();
        final matches = doctors.where((d) {
          if (_spec != 'All' && _specialty(d) != _spec) return false;
          return q.isEmpty || [d['name'], d['hospitalName'], _specialty(d)].any((v) => (v ?? '').toString().toLowerCase().contains(q));
        }).toList();
        return RefreshIndicator(
          onRefresh: () async => _refreshAll(ref),
          child: ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, 0),
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search name, hospital or specialty'),
                  onChanged: (v) => setState(() {
                    _q = v.trim();
                    _shown = _page;
                  }),
                ),
              ),
              if (specs.length > 1)
                ChipFilter(
                  options: [('All', 'All'), for (final s in specs) (s, s)],
                  value: _spec,
                  onChanged: (v) => setState(() {
                    _spec = v;
                    _shown = _page;
                  }),
                ),
              if (matches.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.xl),
                  child: EmptyState(title: 'No matching doctors', detail: 'Try another name, hospital or specialty.', icon: Icons.search_off_rounded),
                ),
              for (final d in matches.take(_shown))
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, 0),
                  child: _DoctorCard(doctor: d, requests: requests),
                ),
              if (matches.length > _shown)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: OutlinedButton(onPressed: () => setState(() => _shown += _page), child: const Text('Show more doctors')),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DoctorCard extends ConsumerWidget {
  const _DoctorCard({required this.doctor, required this.requests});
  final Map<String, dynamic> doctor;
  final List<Map<String, dynamic>> requests;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = doctor;
    final (state, _) = _stateFor(d, requests);
    final exp = d['experienceYears'];
    final hospital = d['hospitalName']?.toString() ?? '';
    final avail = _availability(d);
    return SectionCard(
      child: InkWell(
        onTap: () => showDoctorSheet(context, ref, d),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PatientAvatar(patient: d, size: 56),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_drName(d), style: AppText.titleSm, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (_specialty(d) != null) ...[const SizedBox(height: 4), StatusPill(label: _specialty(d)!, color: AppColors.primary)],
                if ((d['qualification'] ?? '').toString().isNotEmpty || exp != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text([if ((d['qualification'] ?? '').toString().isNotEmpty) d['qualification'], if (exp != null) '$exp yrs experience'].join(' · '), style: AppText.bodySm),
                  ),
                if (hospital.isNotEmpty) Text(hospital, style: AppText.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (avail != null) Text(avail, style: AppText.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(width: double.infinity, child: _StateButton(doctor: d, requests: requests, state: state)),
        ]),
      ),
    );
  }
}

class _StateButton extends ConsumerWidget {
  const _StateButton({required this.doctor, required this.requests, required this.state});
  final Map<String, dynamic> doctor;
  final List<Map<String, dynamic>> requests;
  final _State state;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const size = Size(0, 48);
    return switch (state) {
      _State.request => FilledButton(style: FilledButton.styleFrom(minimumSize: size), onPressed: () => requestChat(context, ref, doctor), child: const Text('Request chat')),
      _State.accepted => FilledButton.icon(style: FilledButton.styleFrom(minimumSize: size), onPressed: () => openDoctorChat(context, ref, doctor), icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18), label: const Text('Open chat')),
      _State.pending => const OutlinedButton(style: ButtonStyle(minimumSize: WidgetStatePropertyAll(size)), onPressed: null, child: Text('Request pending')),
      _State.declined => const OutlinedButton(style: ButtonStyle(minimumSize: WidgetStatePropertyAll(size)), onPressed: null, child: Text('Declined · you can ask again after 24 hours')),
      _State.unavailable => const OutlinedButton(style: ButtonStyle(minimumSize: WidgetStatePropertyAll(size)), onPressed: null, child: Text('Not taking requests right now')),
    };
  }
}

// =============================================================================================
// Doctor profile sheet, request flow, end connection
// =============================================================================================

Future<void> showDoctorSheet(BuildContext context, WidgetRef ref, Map<String, dynamic> doctor) async {
  final requests = await ref.read(_myRequestsProvider.future).catchError((_) => <Map<String, dynamic>>[]);
  if (!context.mounted) return;
  final d = doctor;
  final (state, request) = _stateFor(d, requests);
  Widget row(IconData icon, String? text) => text == null || text.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: AppColors.inkSecondary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(text, style: AppText.body)),
          ]),
        );
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            PatientAvatar(patient: d, size: 64),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_drName(d), style: AppText.title),
                if (_specialty(d) != null) Text(_specialty(d)!, style: AppText.bodySm),
              ]),
            ),
          ]),
          const SizedBox(height: AppSpacing.md),
          row(Icons.school_outlined, d['qualification']?.toString()),
          row(Icons.work_history_outlined, d['experienceYears'] == null ? null : '${d['experienceYears']} years of experience'),
          row(Icons.local_hospital_outlined, d['hospitalName']?.toString()),
          row(Icons.schedule_outlined, _availability(d)),
          const SizedBox(height: AppSpacing.sm),
          if (state == _State.accepted) ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () {
                Navigator.pop(sheet);
                openDoctorChat(context, ref, d);
              },
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('Start chat'),
            ),
            const SizedBox(height: AppSpacing.xs),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () {
                Navigator.pop(sheet);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tap the paperclip in the chat to share a report.')));
                openDoctorChat(context, ref, d);
              },
              icon: const Icon(Icons.attach_file_rounded),
              label: const Text('Share reports'),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppColors.danger),
              onPressed: () {
                Navigator.pop(sheet);
                _endConnection(context, ref, d, request!);
              },
              child: const Text('End connection'),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: _StateButton(doctor: d, requests: requests, state: state),
            ),
        ]),
      ),
    ),
  );
}

Future<void> requestChat(BuildContext context, WidgetRef ref, Map<String, dynamic> doctor) async {
  final agreed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Before you connect', style: AppText.title),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Your doctor will see your medical summary, health readings and emergency alerts while connected. You can end this anytime.',
            style: AppText.body,
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: () => Navigator.pop(c, true), child: const Text('I agree, continue')),
          TextButton(style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        ]),
      ),
    ),
  );
  if (agreed != true || !context.mounted) return;
  final sent = await pushPage<bool>(context, _RequestForm(doctor: doctor));
  if (sent == true) _refreshAll(ref);
}

class _RequestForm extends ConsumerStatefulWidget {
  const _RequestForm({required this.doctor});
  final Map<String, dynamic> doctor;
  @override
  ConsumerState<_RequestForm> createState() => _RequestFormState();
}

class _RequestFormState extends ConsumerState<_RequestForm> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final _message = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).post('/consultations', body: {
        'doctorId': widget.doctor['userId'],
        'reason': _reason.text.trim(),
        if (_message.text.trim().isNotEmpty) 'firstMessage': _message.text.trim(),
      });
      messenger.showSnackBar(SnackBar(content: Text('Request sent to ${_drName(widget.doctor)}.')));
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Request ${_drName(widget.doctor)}'), titleSpacing: 0),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          TextFormField(
            controller: _reason,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Reason for consultation', hintText: 'For example: chest pain for 2 days'),
            validator: (v) => (v ?? '').trim().length < 3 ? 'Tell the doctor briefly why you want to talk.' : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            controller: _message,
            maxLength: 2000,
            minLines: 3,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'First message (optional)', alignLabelWithHint: true),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Sending…' : 'Send request'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _endConnection(BuildContext context, WidgetRef ref, Map<String, dynamic> doctor, Map<String, dynamic> request) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('End connection with ${_drName(doctor)}?'),
      content: const Text('They stop seeing your health data right away. You keep your chat history, read-only.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep connection')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: AppColors.danger), onPressed: () => Navigator.pop(c, true), child: const Text('End connection')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(apiClientProvider).post('/consultations/${request['id']}/end');
    messenger.showSnackBar(const SnackBar(content: Text('Connection ended.')));
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
  _refreshAll(ref);
}
