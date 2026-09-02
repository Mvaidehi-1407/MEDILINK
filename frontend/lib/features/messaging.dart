import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/realtime_service.dart';
import '../core/session.dart';
import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame;

/// Both participants must compute the same conversationId regardless of who opens the chat
/// first, or messages fragment into two separate threads. Canonical (sorted) pair ordering.
String conversationIdFor(String userA, String userB) {
  final ids = [userA, userB]..sort();
  return '${ids[0]}:${ids[1]}';
}

/// Real message thread: history via GET /api/messages/{conversationId}, send via POST
/// /api/messages, live delivery via the /ws/conversations/{id} WebSocket channel (Phase 12).
class ConversationPage extends ConsumerStatefulWidget {
  const ConversationPage({super.key, required this.conversationId, required this.otherPartyId, required this.title});
  final String conversationId;
  final String otherPartyId;
  final String title;
  @override
  ConsumerState<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends ConsumerState<ConversationPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String? _error;
  bool _sending = false;
  RealtimeConnection? _connection;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _load();
    _connection = RealtimeService(ref.read(sessionProvider.notifier), ref.read(apiClientProvider)).conversationChannel(widget.conversationId);
    _subscription = _connection!.events.listen((event) {
      if (!mounted) return;
      if (event['event'] == 'chat.message') {
        final message = Map<String, dynamic>.from(event['data'] as Map);
        setState(() => _messages = [..._messages, message]);
        _scrollToBottom();
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final messages = await ref.read(apiClientProvider).list('/messages/${widget.conversationId}');
      setState(() {
        _messages = messages;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final response = await ref.read(apiClientProvider).post('/messages', body: {
        'conversationId': widget.conversationId,
        'receiverId': widget.otherPartyId,
        'message': text,
      });
      if (response is! Map) throw const FormatException('Unexpected response');
      if (mounted) {
        setState(() {
          _messages = [..._messages, Map<String, dynamic>.from(response)];
          _controller.clear();
        });
        _scrollToBottom();
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not send message. Try again.')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _connection?.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(sessionProvider).userId;
    return PageFrame(
      title: widget.title,
      child: Column(
        children: [
          Expanded(
            child: _loading
                ? const LoadingState()
                : _error != null
                    ? ErrorState(message: _error!, onRetry: _load)
                    : _messages.isEmpty
                        ? const EmptyState(title: 'No messages yet', detail: 'Send the first message below.', icon: Icons.chat_bubble_outline)
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: _messages.length,
                            itemBuilder: (context, i) {
                              final message = _messages[i];
                              final mine = message['senderId'] == myId;
                              return Align(
                                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                                  decoration: BoxDecoration(
                                    color: mine ? MedilinkColors.blue : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    message['message']?.toString() ?? '',
                                    style: TextStyle(color: mine ? Colors.white : Colors.black87),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(hintText: 'Type a message', border: OutlineInputBorder()),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
