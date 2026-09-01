import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'session.dart';

/// A self-healing WebSocket connection to one MEDILINK realtime channel. Reconnects
/// automatically with exponential backoff on any drop (network blip, server restart, forced
/// disconnect) and also reconnects immediately when the app returns to the foreground, since a
/// backgrounded app's socket is not assumed to still be open.
class RealtimeConnection with WidgetsBindingObserver {
  RealtimeConnection(this._session, this._path) {
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  final SessionController _session;
  final String _path;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  int _backoffSeconds = 1;
  bool _disposed = false;
  bool _connected = false;

  Stream<Map<String, dynamic>> get events => _controller.stream;
  bool get isConnected => _connected;

  void _connect() {
    if (_disposed) return;
    final token = _session.accessToken;
    if (token == null) return;
    final apiBase = _session.apiBaseUrl ?? 'http://10.0.2.2:8000/api';
    final root = apiBase
        .replaceFirst(RegExp(r'/api$'), '')
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');
    try {
      final channel = WebSocketChannel.connect(Uri.parse('$root$_path'));
      _channel = channel;
      // Auth token travels as the first WS message, never in the URL, so it never lands in
      // proxy/server access logs.
      channel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
      _subscription = channel.stream.listen(
        (event) {
          _connected = true;
          _backoffSeconds = 1;
          if (event is! String) return;
          try {
            final data = Map<String, dynamic>.from(jsonDecode(event) as Map);
            if (data['event'] == 'auth.ok') return;
            _controller.add(data);
          } catch (_) {}
        },
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _connected = false;
    if (_disposed || _reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(Duration(seconds: _backoffSeconds), () {
      _backoffSeconds = (_backoffSeconds * 2).clamp(1, 30);
      _connect();
    });
  }

  /// Used by tests / manual "force disconnect" verification and by the lifecycle hook below.
  void forceReconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
    _backoffSeconds = 1;
    _connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_connected) {
      forceReconnect();
    }
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    WidgetsBinding.instance.removeObserver(this);
    _controller.close();
  }
}

class RealtimeService {
  RealtimeService(this._session);
  final SessionController _session;

  RealtimeConnection patientChannel(String patientId) => RealtimeConnection(_session, '/ws/patient/$patientId');
  RealtimeConnection hospitalChannel() => RealtimeConnection(_session, '/ws/hospitals');
  RealtimeConnection conversationChannel(String conversationId) => RealtimeConnection(_session, '/ws/conversations/$conversationId');
}
