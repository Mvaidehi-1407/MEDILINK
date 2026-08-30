import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'session.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(this._session, {http.Client? client})
    : _client = client ?? http.Client();

  static const _defaultBaseUrl = String.fromEnvironment(
    'MEDILINK_API_URL',
    defaultValue: 'http://10.0.2.2:8000/api',
  );
  final SessionController _session;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${_session.apiBaseUrl ?? _defaultBaseUrl}$path')
          .replace(queryParameters: query);

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _request('GET', path, query: query);
  Future<dynamic> post(String path, {Object? body}) =>
      _request('POST', path, body: body);
  Future<dynamic> patch(String path, {Object? body}) =>
      _request('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _request('DELETE', path);

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool allowRefresh = true,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final token = _session.accessToken;
    if (token != null) headers['Authorization'] = 'Bearer $token';
    try {
      final request = http.Request(method, _uri(path, query))
        ..headers.addAll(headers)
        ..body = body == null ? '' : jsonEncode(body);
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
      final text = await response.stream.bytesToString();
      final data = text.isEmpty ? null : jsonDecode(text);
      if (response.statusCode >= 200 && response.statusCode < 300) return data;
      if (response.statusCode == 401 && allowRefresh && path != '/auth/login' && path != '/auth/refresh') {
        final refreshed = await _refreshTokens();
        if (refreshed) return await _request(method, path, body: body, query: query, allowRefresh: false);
      }
      if (response.statusCode == 401) await _session.clear();
      final detail = data is Map && data['detail'] != null
          ? data['detail'].toString()
          : 'Request failed (${response.statusCode})';
      throw ApiException(detail, statusCode: response.statusCode);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(
        'Unable to reach MEDILINK. Check your connection and try again.',
      );
    }
  }

  Future<bool> _refreshTokens() async {
    final refresh = _session.refreshToken;
    if (refresh == null) return false;
    try {
      final data = await _request('POST', '/auth/refresh', body: {'refreshToken': refresh}, allowRefresh: false) as Map;
      await _session.updateTokens(accessToken: data['accessToken'].toString(), refreshToken: data['refreshToken'].toString());
      return true;
    } on ApiException {
      return false;
    }
  }

  Future<Map<String, dynamic>> login(String email, String password) async =>
      Map<String, dynamic>.from(
        await post('/auth/login', body: {'email': email, 'password': password})
            as Map,
      );

  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required String role,
  }) async => Map<String, dynamic>.from(
    await post(
      '/auth/register',
      body: {'name': name, 'email': email, 'password': password, 'role': role},
    ) as Map,
  );

  Future<List<Map<String, dynamic>>> list(
    String path, {
    Map<String, String>? query,
  }) async {
    final data = await get(path, query: query);
    return (data as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<Map<String, dynamic>> currentReading(String patientId) async =>
      Map<String, dynamic>.from(await get('/health/current/$patientId') as Map);
  Future<List<Map<String, dynamic>>> healthHistory(String patientId) =>
      list('/health/history/$patientId');
  Future<Map<String, dynamic>> submitReading(
    Map<String, dynamic> reading,
  ) async => Map<String, dynamic>.from(
    await post('/health/readings', body: reading) as Map,
  );
  Future<List<Map<String, dynamic>>> nearbyHospitals(
    double latitude,
    double longitude,
  ) => list(
    '/hospitals/nearby',
    query: {
      'latitude': '$latitude',
      'longitude': '$longitude',
      'radius': '10000',
    },
  );
  Future<List<Map<String, dynamic>>> emergencies(String patientId) =>
      list('/emergencies/patient/$patientId');
  Future<Map<String, dynamic>> emergencyAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]) async => Map<String, dynamic>.from(
    await post('/emergencies/$id/$action', body: body ?? const {}) as Map,
  );
}

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(ref.read(sessionProvider.notifier)),
);
