import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'session.dart';

class RealtimeService {
  RealtimeService(this._session);
  final SessionController _session;

  Stream<Map<String, dynamic>> patientEvents(String patientId) => _events('/ws/patient/$patientId');
  Stream<Map<String, dynamic>> hospitalEvents() => _events('/ws/hospitals');
  Stream<Map<String, dynamic>> conversationEvents(String conversationId) => _events('/ws/conversations/$conversationId');

  Stream<Map<String, dynamic>> _events(String path) {
    final token = _session.accessToken;
    if (token == null) return const Stream.empty();
    final apiBase = _session.apiBaseUrl ?? 'http://10.0.2.2:8000/api';
    final root = apiBase.replaceFirst(RegExp(r'/api$'), '').replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
    final channel = WebSocketChannel.connect(Uri.parse('$root$path?token=$token'));
    return channel.stream.where((event) => event is String).map((event) => Map<String, dynamic>.from(jsonDecode(event as String) as Map));
  }
}
