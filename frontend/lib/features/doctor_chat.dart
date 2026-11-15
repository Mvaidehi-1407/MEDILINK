import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/realtime_service.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/app_icons.dart' show SkeletonList;
import '../ui/format.dart';
import '../widgets/common.dart';
import 'doctor_portal.dart';
import 'doctor_scan.dart';

// =============================================================================================
// Conversations list
// =============================================================================================

class DoctorChatsTab extends ConsumerStatefulWidget {
  const DoctorChatsTab({super.key});
  @override
  ConsumerState<DoctorChatsTab> createState() => _DoctorChatsTabState();
}

class _DoctorChatsTabState extends ConsumerState<DoctorChatsTab> {
  final _search = TextEditingController();
  String _filter = 'all';
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() => ref.read(apiClientProvider).list('/doctor/conversations');
  void _reload() => setState(() => _future = _load());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> c) {
    final p = Map<String, dynamic>.from(c['patient'] as Map);
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty && !p['name'].toString().toLowerCase().contains(q) && !pidOf(p['id']).toLowerCase().contains(q)) return false;
    final last = parseBackendTime(c['lastAt']);
    return switch (_filter) {
      'unread' => (c['unread'] as num? ?? 0) > 0,
      // Active = a message in the last 7 days.
      'active' => last != null && DateTime.now().difference(last.toLocal()).inDays < 7,
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Chats'), titleSpacing: AppSpacing.gutter),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xs),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Search patients', prefixIcon: Icon(Icons.search_rounded)),
          ),
        ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            children: [
              for (final (value, label) in const [('all', 'All'), ('unread', 'Unread'), ('active', 'Active')])
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.xs),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _filter == value,
                    onSelected: (_) => setState(() => _filter = value),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(AppSpacing.gutter), child: SkeletonList(rows: 4));
                if (snap.hasError) return ErrorState(message: snap.error.toString(), onRetry: _reload);
                final rows = snap.data!.where(_matches).toList();
                if (rows.isEmpty) {
                  return ListView(children: [
                    const SizedBox(height: AppSpacing.xxxl),
                    EmptyState(
                      title: snap.data!.isEmpty ? 'No conversations yet' : 'No chats match',
                      detail: snap.data!.isEmpty ? 'Accept a consultation request to start chatting with that patient.' : 'Try another filter or search.',
                      icon: Icons.chat_bubble_outline_rounded,
                    ),
                  ]);
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) {
                    final c = rows[i];
                    final p = Map<String, dynamic>.from(c['patient'] as Map);
                    final unread = (c['unread'] as num? ?? 0).toInt();
                    return SectionCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        minVerticalPadding: AppSpacing.sm,
                        onTap: () async {
                          await pushPage(context, DoctorChatPage(conversationId: c['conversationId'].toString(), patient: p));
                          _reload();
                          ref.invalidate(doctorHomeProvider);
                        },
                        leading: PatientAvatar(patient: p, size: 48),
                        title: Row(
                          children: [
                            Flexible(child: Text(p['name']?.toString() ?? 'Patient', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            if (c['emergency'] == true) ...[
                              const SizedBox(width: AppSpacing.xxs),
                              Semantics(label: 'Active emergency', child: const Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 18)),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${pidOf(p['id'])} · ${c['lastMessage'] ?? 'No messages yet'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodySm.copyWith(fontWeight: unread > 0 ? FontWeight.w700 : null, color: unread > 0 ? AppColors.ink : null),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(c['lastAt'] == null ? '' : relativeTime(c['lastAt']), style: AppText.caption),
                            if (unread > 0) ...[
                              const SizedBox(height: AppSpacing.xxs),
                              Semantics(
                                label: '$unread unread',
                                child: Container(
                                  constraints: const BoxConstraints(minWidth: 22),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(AppRadius.pill)),
                                  child: Text('$unread', textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppColors.onDark, fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}

// =============================================================================================
// Conversation
// =============================================================================================

String _newClientId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class DoctorChatPage extends ConsumerStatefulWidget {
  const DoctorChatPage({super.key, required this.conversationId, required this.patient, this.readOnly = false, this.onProfile});
  final String conversationId;

  /// The other participant: a patient card for doctors, or a doctor's public profile (with `id` =
  /// their user id) for patients. One chat screen serves both sides.
  final Map<String, dynamic> patient;

  /// Ended consultation: the patient keeps the history, read-only.
  final bool readOnly;
  final VoidCallback? onProfile;
  @override
  ConsumerState<DoctorChatPage> createState() => _DoctorChatPageState();
}

class _DoctorChatPageState extends ConsumerState<DoctorChatPage> {
  static const _pageSize = 30;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _messages = [];

  /// Offline queue: unsent messages, persisted per conversation so they survive a restart.
  List<Map<String, dynamic>> _outbox = [];
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasOlder = true;
  bool _ended = false;
  bool _flushing = false;
  bool _offline = false;
  String? _error;
  DateTime? _typingUntil;
  DateTime _lastTypingSent = DateTime(2000);
  Timer? _typingTimer;
  RealtimeConnection? _socket;
  StreamSubscription? _sub;

  String get _myId => ref.read(sessionProvider).userId;
  String get _patientId => widget.patient['id'].toString();
  String get _outboxKey => 'doctor_outbox_${widget.conversationId}';
  bool get _isPatient => ref.read(sessionProvider).role == 'PATIENT';

  @override
  void initState() {
    super.initState();
    _ended = widget.readOnly;
    _scroll.addListener(() {
      if (_scroll.position.pixels <= 80) _loadOlder();
    });
    _restoreOutbox();
    _load();
    _socket = RealtimeService(ref.read(sessionProvider.notifier), ref.read(apiClientProvider)).conversationChannel(widget.conversationId);
    _sub = _socket!.events.listen(_onEvent);
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['event']) {
      case 'auth.ok':
        // Reconnected: send anything queued, then catch up.
        _flushOutbox();
        _error != null ? _load() : _refreshLatest();
      case 'chat.message':
        final m = Map<String, dynamic>.from(e['data'] as Map);
        if (_messages.any((x) => x['id'] == m['id'])) return;
        setState(() {
          _messages = [..._messages, m];
          _typingUntil = null;
        });
        if (m['receiverId'] == _myId) _markRead();
        _toBottom();
      case 'chat.read_all' || 'chat.read':
        _refreshLatest();
      case 'chat.typing':
        if ((e['data'] as Map?)?['userId'] == _myId) return;
        setState(() => _typingUntil = DateTime.now().add(const Duration(seconds: 4)));
        _typingTimer?.cancel();
        _typingTimer = Timer(const Duration(seconds: 4), () => mounted ? setState(() => _typingUntil = null) : null);
      case 'chat.ended':
        setState(() => _ended = true);
    }
  }

  Future<void> _restoreOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxKey);
    if (raw == null || !mounted) return;
    setState(() => _outbox = (jsonDecode(raw) as List).map((m) => Map<String, dynamic>.from(m as Map)).toList());
    _flushOutbox();
  }

  Future<void> _saveOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    _outbox.isEmpty ? await prefs.remove(_outboxKey) : await prefs.setString(_outboxKey, jsonEncode(_outbox));
  }

  Future<List<Map<String, dynamic>>> _fetch({String? before}) => ref
      .read(apiClientProvider)
      .list('/messages/${widget.conversationId}', query: {'limit': '$_pageSize', 'before': ?before});

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _fetch();
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _hasOlder = rows.length == _pageSize;
        _loading = false;
      });
      _markRead();
      _saveCache();
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(jump: true));
    } on ApiException catch (e) {
      if (!mounted) return;
      // No connection: show the last cached page and the queue instead of a blank error.
      final cached = e.statusCode == null ? await _readCache() : const <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e.statusCode == 403) {
          _ended = true;
        } else if (e.statusCode == null && (cached.isNotEmpty || _outbox.isNotEmpty)) {
          _messages = cached;
          _offline = true;
        } else {
          _error = e.message;
        }
      });
    }
  }

  String get _cacheKey => 'doctor_chat_cache_${widget.conversationId}';

  Future<void> _saveCache() async {
    final prefs = await SharedPreferences.getInstance();
    final recent = _messages.length > _pageSize ? _messages.sublist(_messages.length - _pageSize) : _messages;
    await prefs.setString(_cacheKey, jsonEncode(recent, toEncodable: (o) => o.toString()));
  }

  Future<List<Map<String, dynamic>>> _readCache() async {
    final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
    return raw == null ? [] : (jsonDecode(raw) as List).map((m) => Map<String, dynamic>.from(m as Map)).toList();
  }

  /// Re-reads the newest page (tick updates, messages missed while offline) and merges it.
  Future<void> _refreshLatest() async {
    try {
      final rows = await _fetch();
      if (!mounted) return;
      final byId = {for (final m in _messages) m['id']: m};
      for (final m in rows) {
        byId[m['id']] = m;
      }
      setState(() {
        _offline = false;
        _messages = byId.values.toList()..sort((a, b) => a['timestamp'].toString().compareTo(b['timestamp'].toString()));
      });
      _saveCache();
    } on ApiException catch (e) {
      if (e.statusCode == 403 && mounted) setState(() => _ended = true);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasOlder || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final before = _messages.first['timestamp'].toString();
      final rows = await _fetch(before: before);
      if (!mounted) return;
      final oldExtent = _scroll.position.maxScrollExtent;
      setState(() {
        _messages = [...rows, ..._messages];
        _hasOlder = rows.length == _pageSize;
      });
      // Keep the reader's place after older messages are inserted above.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.pixels + _scroll.position.maxScrollExtent - oldExtent);
      });
    } catch (_) {
      // Older history stays available on the next scroll.
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _markRead() async {
    try {
      await ref.read(apiClientProvider).post('/messages/${widget.conversationId}/read');
    } catch (_) {}
  }

  void _toBottom({bool jump = false}) {
    if (!_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    jump || AppMotion.reduced(context) ? _scroll.jumpTo(end) : _scroll.animateTo(end, duration: AppMotion.medium, curve: AppMotion.standard);
  }

  void _onTyping(String _) {
    if (DateTime.now().difference(_lastTypingSent).inSeconds < 3) return;
    _lastTypingSent = DateTime.now();
    _socket?.send({'type': 'typing'});
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _ended) return;
    _text.clear();
    setState(() => _outbox = [..._outbox, {'clientId': _newClientId(), 'message': text, 'queuedAt': DateTime.now().toUtc().toIso8601String()}]);
    await _saveOutbox();
    _toBottom();
    _flushOutbox();
  }

  Future<void> _flushOutbox() async {
    if (_flushing || _outbox.isEmpty) return;
    _flushing = true;
    try {
      while (_outbox.isNotEmpty && mounted) {
        final item = _outbox.first;
        final sent = Map<String, dynamic>.from(await ref.read(apiClientProvider).post('/messages', body: {
          'conversationId': widget.conversationId,
          'receiverId': _patientId,
          'message': item['message'],
          'clientId': item['clientId'],
        }) as Map);
        if (!mounted) return;
        setState(() {
          _outbox = _outbox.skip(1).toList();
          if (!_messages.any((m) => m['id'] == sent['id'])) _messages = [..._messages, sent];
        });
        await _saveOutbox();
      }
    } on ApiException catch (e) {
      // Network failure: keep queued; retried on reconnect/resume. Ended chat: stop.
      if (e.statusCode == null && mounted) setState(() => _offline = true);
      if (e.statusCode == 403 && mounted) setState(() => _ended = true);
      if (e.statusCode != null && e.statusCode != 403 && e.statusCode != 429 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      _flushing = false;
    }
  }

  /// Patients share one Vault report or their QR summary, each after a confirmation tap; the
  /// doctor receives only that item, never the Vault.
  Future<void> _patientAttach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.folder_shared_outlined), title: const Text('Report from my Vault'), subtitle: const Text('PDF or photo'), onTap: () => Navigator.pop(c, 'vault')),
          ListTile(leading: const Icon(Icons.qr_code_2_rounded), title: const Text('My health summary'), subtitle: const Text('The summary your QR code shows'), onTap: () => Navigator.pop(c, 'qr')),
          const SizedBox(height: AppSpacing.sm),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    final api = ref.read(apiClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    final name = widget.patient['name']?.toString() ?? 'your doctor';
    Future<bool> confirm(String what) async =>
        await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Share $what?'),
            content: Text('$name will see only this item, not the rest of your Vault.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Share')),
            ],
          ),
        ) ??
        false;
    try {
      if (choice == 'qr') {
        if (!await confirm('your health summary')) return;
        final sent = Map<String, dynamic>.from(await api.post('/messages', body: {
          'conversationId': widget.conversationId,
          'receiverId': _patientId,
          'message': 'Shared my health summary',
          'kind': 'qr_summary',
          'clientId': _newClientId(),
        }) as Map);
        if (mounted && !_messages.any((m) => m['id'] == sent['id'])) setState(() => _messages = [..._messages, sent]);
        _toBottom();
        return;
      }
      final records = (await api.list('/medical-records'))
          .where((r) => const {'application/pdf', 'image/jpeg', 'image/png'}.contains(r['contentType']))
          .toList();
      if (!mounted) return;
      if (records.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('No PDF or photo reports in your Vault yet.')));
        return;
      }
      final record = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (c) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * .6),
            child: ListView(shrinkWrap: true, children: [
              for (final r in records)
                ListTile(
                  leading: Icon(r['contentType'] == 'application/pdf' ? Icons.picture_as_pdf_outlined : Icons.image_outlined, color: AppColors.primary),
                  title: Text(r['filename'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${r['category'] ?? 'Report'} · ${formatTimestamp(r['createdAt']).split(',').first}'),
                  onTap: () => Navigator.pop(c, r),
                ),
            ]),
          ),
        ),
      );
      if (record == null || !mounted || !await confirm('"${record['filename']}"')) return;
      messenger.showSnackBar(SnackBar(content: Text('Sending ${record['filename']}…')));
      final bytes = await api.getBytes('/medical-records/${record['id']}');
      final sent = await api.uploadChatAttachment(
          conversationId: widget.conversationId, clientId: _newClientId(), filename: record['filename'].toString(), bytes: bytes);
      messenger.hideCurrentSnackBar();
      if (mounted && !_messages.any((m) => m['id'] == sent['id'])) setState(() => _messages = [..._messages, sent]);
      _toBottom();
    } on ApiException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      if (e.statusCode == 403 && mounted) setState(() => _ended = true);
    }
  }

  Future<void> _attach() async {
    if (_isPatient) return _patientAttach();
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'], withData: true);
    final file = picked?.files.single;
    if (file == null || file.bytes == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Sending ${file.name}…')));
    try {
      final sent = await ref.read(apiClientProvider).uploadChatAttachment(
            conversationId: widget.conversationId, clientId: _newClientId(), filename: file.name, bytes: file.bytes!);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      if (!_messages.any((m) => m['id'] == sent['id'])) setState(() => _messages = [..._messages, sent]);
      _toBottom();
    } on ApiException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      if (e.statusCode == 403 && mounted) setState(() => _ended = true);
    }
  }

  Future<void> _openAttachment(Map<String, dynamic> a) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await ref.read(apiClientProvider).getBytes('/messages/attachments/${a['id']}');
      if (!mounted) return;
      if (a['contentType'].toString().startsWith('image/')) {
        pushPage(context, Scaffold(
          appBar: AppBar(title: Text(a['filename'].toString()), titleSpacing: 0),
          body: InteractiveViewer(child: Center(child: Image.memory(Uint8List.fromList(bytes)))),
        ));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/${a['filename']}';
      await File(path).writeAsBytes(bytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: a['filename'].toString()));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text("This file couldn't be opened. Try again.")));
    }
  }

  void _openQrSummary() {
    final card = _messages.lastWhere((m) => m['kind'] == 'qr_summary', orElse: () => {});
    if (card.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No QR summary shared in this chat yet.')));
      return;
    }
    pushPage(context, PatientSummaryPage(patientId: _patientId));
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _sub?.cancel();
    _socket?.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typing = _typingUntil != null && _typingUntil!.isAfter(DateTime.now());
    final p = widget.patient;
    final patientView = _isPatient;
    final subtitle = patientView
        ? (p['specialization'] == 'Other' ? p['specializationOther'] : p['specialization'])?.toString() ?? 'Doctor'
        : pidOf(p['id']);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            PatientAvatar(patient: p, size: 40),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p['name']?.toString() ?? 'Patient', style: AppText.titleSm, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(typing ? 'typing…' : subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: typing ? AppColors.primary : null)),
                ],
              ),
            ),
          ],
        ),
        actions: patientView
            ? [if (widget.onProfile != null) IconButton(tooltip: 'Doctor profile', onPressed: widget.onProfile, icon: const Icon(Icons.info_outline_rounded))]
            : [
                IconButton(tooltip: 'QR summary', onPressed: _openQrSummary, icon: const Icon(Icons.qr_code_2_rounded)),
                IconButton(tooltip: 'Patient summary', onPressed: () => pushPage(context, PatientSummaryPage(patientId: _patientId)), icon: const Icon(Icons.assignment_outlined)),
                const SizedBox(width: AppSpacing.xxs),
              ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (patientView && !_ended)
              Container(
                width: double.infinity,
                color: AppColors.primaryTint,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                child: Text('For emergencies, use the SOS button. Doctors may not reply right away.', style: AppText.bodySm.copyWith(color: AppColors.ink)),
              ),
            Expanded(child: _body()),
            if (_ended)
              Container(
                width: double.infinity,
                color: AppColors.warningTint,
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(patientView ? 'This consultation has ended. Your chat history stays here, read-only.' : 'This consultation has ended. You can no longer send messages.',
                    textAlign: TextAlign.center, style: AppText.bodySm.copyWith(color: AppColors.ink)),
              )
            else
              _Composer(controller: _text, onSend: _send, onAttach: _attach, onChanged: _onTyping),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Padding(padding: EdgeInsets.all(AppSpacing.gutter), child: SkeletonList(rows: 4));
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    if (_messages.isEmpty && _outbox.isEmpty) {
      return EmptyState(
        title: _ended ? 'Chat closed' : 'No messages yet',
        detail: _ended ? 'This consultation has ended.' : 'Say hello to start the consultation.',
        icon: Icons.chat_bubble_outline_rounded,
      );
    }
    final items = <Widget>[];
    String? lastDay;
    void day(Object? ts) {
      final t = parseBackendTime(ts);
      if (t == null) return;
      final key = '${t.year}-${t.month}-${t.day}';
      if (key == lastDay) return;
      lastDay = key;
      items.add(_DateSeparator(label: formatTimestamp(ts).split(',').first));
    }

    if (_loadingOlder) items.add(const Padding(padding: EdgeInsets.all(AppSpacing.sm), child: Center(child: CircularProgressIndicator(strokeWidth: 2))));
    for (final m in _messages) {
      day(m['timestamp']);
      items.add(_Bubble(
        message: m,
        mine: m['senderId'] == _myId,
        peerLabel: _isPatient ? 'Doctor' : 'Patient',
        onOpenAttachment: _openAttachment,
        onOpenQr: _isPatient ? () {} : () => pushPage(context, PatientSummaryPage(patientId: _patientId)),
      ));
    }
    for (final q in _outbox) {
      items.add(_Bubble(message: {...q, 'senderId': _myId, 'timestamp': q['queuedAt']}, mine: true, queued: true, onOpenAttachment: (_) {}, onOpenQr: () {}));
    }
    final list = ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm), children: items);
    if (!_offline) return list;
    return Column(children: [
      Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          color: AppColors.warningTint,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          child: Text("You're offline. Messages will send when you're back online.", style: AppText.bodySm.copyWith(color: AppColors.ink)),
        ),
      ),
      Expanded(child: list),
    ]);
  }
}

class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xxs),
        decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.pill), border: Border.all(color: AppColors.border)),
        child: Text(label, style: AppText.caption),
      ),
    ),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.onOpenAttachment, required this.onOpenQr, this.queued = false, this.peerLabel = 'Patient'});
  final Map<String, dynamic> message;
  final String peerLabel;
  final bool mine;
  final bool queued;
  final ValueChanged<Map<String, dynamic>> onOpenAttachment;
  final VoidCallback onOpenQr;

  String _clock(Object? ts) {
    final t = parseBackendTime(ts);
    if (t == null) return '';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    if (message['kind'] == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
            decoration: BoxDecoration(color: AppColors.primaryTint, borderRadius: BorderRadius.circular(AppRadius.sm)),
            child: Text(message['message']?.toString() ?? '', textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppColors.primaryPressed)),
          ),
        ),
      );
    }
    final fg = mine ? AppColors.onDark : AppColors.ink;
    final attachment = message['attachment'] as Map?;
    final status = message['readStatus']?.toString();
    final (IconData tick, String tickLabel) = queued
        ? (Icons.schedule_rounded, 'Waiting to send')
        : switch (status) {
            'READ' => (Icons.done_all_rounded, 'Read'),
            'DELIVERED' => (Icons.done_all_rounded, 'Delivered'),
            _ => (Icons.done_rounded, 'Sent'),
          };
    Widget content;
    if (message['kind'] == 'qr_summary') {
      content = InkWell(
        onTap: onOpenQr,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.qr_code_2_rounded, color: fg),
          const SizedBox(width: AppSpacing.xs),
          Flexible(child: Text(mine ? 'Health summary shared' : 'Patient QR summary · View', style: AppText.bodyStrong.copyWith(color: fg))),
        ]),
      );
    } else if (attachment != null) {
      final isImage = attachment['contentType'].toString().startsWith('image/');
      final kb = ((attachment['size'] as num? ?? 0) / 1024).ceil();
      content = InkWell(
        onTap: () => onOpenAttachment(Map<String, dynamic>.from(attachment)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined, color: fg),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(attachment['filename'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: fg)),
              Text('$kb KB · Tap to open', style: AppText.caption.copyWith(color: mine ? AppColors.onDark.withValues(alpha: .85) : null)),
            ]),
          ),
        ]),
      );
    } else {
      content = Text(message['message']?.toString() ?? '', style: AppText.body.copyWith(color: fg));
    }
    return Semantics(
      label: '${mine ? 'You' : peerLabel},${_clock(message['timestamp'])}${mine ? ', $tickLabel' : ''}',
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(AppSpacing.sm + 2, AppSpacing.xs + 2, AppSpacing.sm + 2, AppSpacing.xs),
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .78),
          decoration: BoxDecoration(
            color: mine ? (queued ? AppColors.primary.withValues(alpha: .7) : AppColors.primary) : AppColors.surface,
            border: mine ? null : Border.all(color: AppColors.border),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(AppRadius.card),
              topRight: const Radius.circular(AppRadius.card),
              bottomLeft: Radius.circular(mine ? AppRadius.card : 4),
              bottomRight: Radius.circular(mine ? 4 : AppRadius.card),
            ),
            boxShadow: mine ? null : AppElevation.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(alignment: Alignment.centerLeft, widthFactor: 1, child: content),
              const SizedBox(height: 2),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_clock(message['timestamp']), style: AppText.caption.copyWith(fontSize: 11, color: mine ? AppColors.onDark.withValues(alpha: .85) : null)),
                if (mine) ...[
                  const SizedBox(width: 4),
                  Icon(tick, size: 14, color: status == 'READ' && !queued ? AppColors.primaryTint : AppColors.onDark.withValues(alpha: .85)),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend, required this.onAttach, required this.onChanged});
  final TextEditingController controller;
  final VoidCallback onSend, onAttach;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(tooltip: 'Attach a document or photo', onPressed: onAttach, icon: const Icon(Icons.attach_file_rounded)),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              maxLength: 4000,
              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
              textCapitalization: TextCapitalization.sentences,
              onChanged: onChanged,
              decoration: const InputDecoration(hintText: 'Type a message', isDense: true),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          IconButton.filled(
            tooltip: 'Send',
            style: IconButton.styleFrom(minimumSize: const Size(48, 48), backgroundColor: AppColors.primary),
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    ),
  );
}
