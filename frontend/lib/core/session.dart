import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single source of the backend address for REST, WebSocket and the Server address screen.
const productionApiBaseUrl = 'https://medilink-backend-6a75.onrender.com/api';
const _emulatorApiBaseUrl = 'http://10.0.2.2:8000/api';
const _buildApiBaseUrl = String.fromEnvironment('MEDILINK_API_URL');

/// `--dart-define=MEDILINK_API_URL=...` wins; otherwise release builds use production and
/// debug builds the Android emulator's host loopback.
final String defaultApiBaseUrl = normalizeApiBaseUrl(
  _buildApiBaseUrl.isNotEmpty ? _buildApiBaseUrl : (kReleaseMode ? productionApiBaseUrl : _emulatorApiBaseUrl),
);

bool _isLocalHost(String host) =>
    host == 'localhost' || host == '10.0.2.2' || host.startsWith('127.') || host.startsWith('192.168.') ||
    host.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host) || host.endsWith('.local');

/// Emulator/loopback addresses never reach a server from a real phone running a release APK.
bool _isEmulatorOrLoopback(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host == '10.0.2.2' || host == 'localhost' || host.startsWith('127.');
}

/// Trims, drops trailing slashes, adds a scheme (http for LAN/emulator, https otherwise), forces
/// https on onrender.com (its http:// answers 301, which POSTs can't follow) and ensures `/api`.
String normalizeApiBaseUrl(String raw) {
  var url = raw.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  if (url.isEmpty) return url;
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = '${_isLocalHost(Uri.tryParse('http://$url')?.host ?? '') ? 'http' : 'https'}://$url';
  }
  if (url.startsWith('http://') && (Uri.tryParse(url)?.host ?? '').endsWith('.onrender.com')) {
    url = url.replaceFirst('http://', 'https://');
  }
  if (!url.endsWith('/api')) url = '$url/api';
  return url;
}

class AppSession {
  const AppSession({
    this.user,
    this.accessToken,
    this.refreshToken,
    this.onboarded = false,
    this.seniorMode = false,
  });
  final Map<String, dynamic>? user;
  final String? accessToken;
  final String? refreshToken;
  final bool onboarded;
  final bool seniorMode;
  bool get signedIn => user != null && accessToken != null;
  String get role => user?['role']?.toString() ?? '';
  String get userId => user?['id']?.toString() ?? '';
  AppSession copyWith({
    Map<String, dynamic>? user,
    String? accessToken,
    String? refreshToken,
    bool? onboarded,
    bool? seniorMode,
    bool clearUser = false,
  }) => AppSession(
    user: clearUser ? null : user ?? this.user,
    accessToken: clearUser ? null : accessToken ?? this.accessToken,
    refreshToken: clearUser ? null : refreshToken ?? this.refreshToken,
    onboarded: onboarded ?? this.onboarded,
    seniorMode: seniorMode ?? this.seniorMode,
  );
}

class SessionController extends Notifier<AppSession> {
  static const _storage = FlutterSecureStorage();
  SharedPreferences? _preferences;
  /// User override from the Server address screen; null means [defaultApiBaseUrl].
  String? apiBaseUrl;
  String get effectiveApiBaseUrl => apiBaseUrl ?? defaultApiBaseUrl;
  String? get accessToken => state.accessToken;
  String? get refreshToken => state.refreshToken;

  @override
  AppSession build() {
    _load();
    return const AppSession();
  }

  Future<void> _load() async {
    _preferences = await SharedPreferences.getInstance();
    final rawUser = await _storage.read(key: 'medilink_user');
    final access = await _storage.read(key: 'medilink_access');
    final refresh = await _storage.read(key: 'medilink_refresh');
    final storedUrl = _preferences?.getString('medilink_api_url');
    if (storedUrl != null && kReleaseMode && _isEmulatorOrLoopback(storedUrl)) {
      // A leftover dev address must not silently override production in a release APK.
      await _preferences?.remove('medilink_api_url');
      apiBaseUrl = null;
    } else {
      apiBaseUrl = storedUrl == null ? null : normalizeApiBaseUrl(storedUrl);
    }
    // Dev Mode/the vitals simulator no longer exist -- purge any leftover flag from an install
    // that had it enabled before, so it never lingers as dead persisted state.
    await _preferences?.remove('medilink_dev_mode');
    state = AppSession(
      user: rawUser == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(rawUser) as Map),
      accessToken: access,
      refreshToken: refresh,
      onboarded: _preferences?.getBool('medilink_onboarded') ?? false,
      seniorMode: _preferences?.getBool('medilink_senior_mode') ?? false,
    );
  }

  Future<void> saveAuth(Map<String, dynamic> payload) async {
    final user = Map<String, dynamic>.from(payload['user'] as Map);
    final tokens = Map<String, dynamic>.from(payload['tokens'] as Map);
    await _storage.write(key: 'medilink_user', value: jsonEncode(user));
    await _storage.write(
      key: 'medilink_access',
      value: tokens['accessToken'].toString(),
    );
    await _storage.write(
      key: 'medilink_refresh',
      value: tokens['refreshToken'].toString(),
    );
    state = state.copyWith(
      user: user,
      accessToken: tokens['accessToken'].toString(),
      refreshToken: tokens['refreshToken'].toString(),
    );
  }

  Future<void> updateTokens({required String accessToken, required String refreshToken}) async {
    await _storage.write(key: 'medilink_access', value: accessToken);
    await _storage.write(key: 'medilink_refresh', value: refreshToken);
    state = state.copyWith(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<void> completeOnboarding() async {
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!.setBool('medilink_onboarded', true);
    state = state.copyWith(onboarded: true);
  }

  Future<void> setSeniorMode(bool value) async {
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!.setBool('medilink_senior_mode', value);
    state = state.copyWith(seniorMode: value);
  }

  Future<void> clear() async {
    await _storage.delete(key: 'medilink_user');
    await _storage.delete(key: 'medilink_access');
    await _storage.delete(key: 'medilink_refresh');
    state = state.copyWith(clearUser: true);
  }
}

final sessionProvider = NotifierProvider<SessionController, AppSession>(
  SessionController.new,
);
