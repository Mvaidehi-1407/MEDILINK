import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String? apiBaseUrl;
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
    apiBaseUrl = _preferences?.getString('medilink_api_url');
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
