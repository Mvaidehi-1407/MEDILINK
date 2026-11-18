import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'session.dart';

/// A self-healing WebSocket connection to one MEDILINK realtime channel. Reconnects
/// automatically with exponential backoff on any drop (network blip, server restart, forced
/// disconnect) and also reconnects immediately when the app returns to the foreground, since a
/// backgrounded app's socket is not assumed to still be open.
///
/// The access token is short-lived (30 min by default). Unlike REST calls, this connection only
/// authenticates once at connect time and has no way to react to a 401 mid-stream -- so every
/// (re)connect attempt first ensures a fresh token via the same refresh flow the REST client
/// uses, rather than silently failing to auth over and over with a stale one (which looks
/// identical to a network problem from the outside: connect, then an immediate server-side close).
class RealtimeConnection with WidgetsBindingObserver {
  RealtimeConnection(this._session, this._api, this._path) {
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  final SessionController _session;
  final ApiClient _api;
  final String _path;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _backoffSeconds = 1;
  bool _disposed = false;
  bool _connected = false;

  // No client-initiated traffic means an idle-looking socket, which mobile carrier/Wi-Fi NAT
  // tables and Android's battery management commonly kill in well under a minute -- the server
  // already answers a ping with a pong (see app/api/websockets.py), nothing was ever sending one.
  static const _pingInterval = Duration(seconds: 20);

  Stream<Map<String, dynamic>> get events => _controller.stream;
  bool get isConnected => _connected;

  /// Sends a client event (e.g. typing) on the open socket; dropped silently while offline.
  void send(Map<String, dynamic> message) {
    if (!_connected) return;
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {}
  }

  Future<void> _connect() async {
    if (_disposed) return;
    if (_session.refreshToken != null) {
      // Best-effort: if the current access token still has life left the backend just accepts
      // it as-is; if not, this replaces it before we try to authenticate the socket.
      await _api.refreshTokens();
    }
    if (_disposed) return;
    final token = _session.accessToken;
    if (token == null) return;
    // Same base as ApiClient (SessionController.effectiveApiBaseUrl), so REST and WS never diverge.
    final apiBase = _session.effectiveApiBaseUrl;
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
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(_pingInterval, (_) {
        try {
          channel.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      });
      _subscription = channel.stream.listen(
        (event) {
          _connected = true;
          _backoffSeconds = 1;
          if (event is! String) return;
          try {
            final data = Map<String, dynamic>.from(jsonDecode(event) as Map);
            if (data['event'] == 'pong') return;
            // auth.ok is forwarded (not swallowed) so listeners can re-check server state on
            // every fresh connect, not just react to whichever push happens to arrive next --
            // a push made while this socket was mid-reconnect is otherwise gone for good.
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
    _pingTimer?.cancel();
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
    _pingTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    WidgetsBinding.instance.removeObserver(this);
    _controller.close();
  }
}

class RealtimeService {
  RealtimeService(this._session, this._api);
  final SessionController _session;
  final ApiClient _api;

  RealtimeConnection patientChannel(String patientId) => RealtimeConnection(_session, _api, '/ws/patient/$patientId');
  RealtimeConnection hospitalChannel() => RealtimeConnection(_session, _api, '/ws/hospitals');
  RealtimeConnection conversationChannel(String conversationId) => RealtimeConnection(_session, _api, '/ws/conversations/$conversationId');
}
