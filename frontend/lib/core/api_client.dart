import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

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

  // Refresh tokens are single-use server-side (rotation/replay protection), so two concurrent
  // callers racing to refresh the same token would otherwise see one 200 and one 401 -- and
  // without this guard, that losing 401 would wipe out the *winning* call's freshly-stored
  // session (see _request's 401 handler below), logging the user out right after a successful
  // login/refresh. Coalescing every concurrent call onto a single in-flight request means they
  // all see the same (successful) outcome instead of racing the one-time-use token against
  // each other.
  Future<bool>? _refreshInFlight;

  Future<bool> _refreshTokens() {
    return _refreshInFlight ??= _doRefresh().whenComplete(() => _refreshInFlight = null);
  }

  Future<bool> _doRefresh() async {
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

  /// Public entry point for callers outside the normal request/401 flow (e.g. the WebSocket
  /// connection, which authenticates once at connect time and has no way to react to a 401
  /// itself) to proactively ensure a fresh access token before they need one.
  Future<bool> refreshTokens() => _refreshTokens();

  Future<Map<String, dynamic>> login(String identifier, String password) async =>
      Map<String, dynamic>.from(
        await post('/auth/login', body: {'identifier': identifier, 'password': password})
            as Map,
      );

  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required String role,
    required String phone,
    List<Map<String, String>>? caretakers,
  }) async => Map<String, dynamic>.from(
    await post(
      '/auth/register',
      body: {
        'name': name,
        'email': email,
        'password': password,
        'role': role,
        'phone': phone,
        if (caretakers != null) 'caretakers': caretakers,
      },
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
  Future<List<Map<String, dynamic>>> activeEmergencies() =>
      list('/emergencies/active');
  Future<Map<String, dynamic>> emergencyAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]) async => Map<String, dynamic>.from(
    await post('/emergencies/$id/$action', body: body ?? const {}) as Map,
  );

  /// Unauthenticated backend status (call provider / mode), used only to render an honest
  /// "sandbox — verified numbers only" style notice rather than hardcoding it in the UI.
  Future<Map<String, dynamic>> systemStatus() async {
    final root = (_session.apiBaseUrl ?? _defaultBaseUrl).replaceFirst(RegExp(r'/api$'), '');
    final response = await _client.get(Uri.parse('$root/healthz')).timeout(const Duration(seconds: 10));
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  // ---- Phase 20: emergency contacts, panic/escalation actions ----------------------------
  Future<List<Map<String, dynamic>>> emergencyContacts() => list('/contacts');
  Future<Map<String, dynamic>> addEmergencyContact({
    required String name,
    required String phone,
    String? relation,
    bool isPrimary = false,
  }) async => Map<String, dynamic>.from(
    await post('/contacts', body: {
      'name': name,
      'phone': phone,
      if (relation != null && relation.isNotEmpty) 'relation': relation,
      'isPrimary': isPrimary,
    }) as Map,
  );
  Future<Map<String, dynamic>> updateEmergencyContact(String id, Map<String, dynamic> updates) async =>
      Map<String, dynamic>.from(await patch('/contacts/$id', body: updates) as Map);
  Future<void> deleteEmergencyContact(String id) => delete('/contacts/$id');
  Future<Map<String, dynamic>> acknowledgeContactAlert(String emergencyId) async =>
      Map<String, dynamic>.from(await post('/emergencies/$emergencyId/acknowledge-contact') as Map);
  Future<Map<String, dynamic>> getEmergency(String id) async =>
      Map<String, dynamic>.from(await get('/emergencies/$id') as Map);

  /// Closes an emergency for good (hospital accounts only, per the backend's role check).
  /// An emergency left open blocks every future emergency for that patient, since the backend
  /// won't open a second one while one is still active -- so resolving is what frees the patient
  /// to be alerted again, not just a tidy-up action.
  Future<Map<String, dynamic>> resolveEmergency(String emergencyId, {String? notes}) async =>
      Map<String, dynamic>.from(await post('/emergencies/$emergencyId/resolve', body: {
        if (notes != null && notes.isNotEmpty) 'resolutionNotes': notes,
      }) as Map);
  Future<Map<String, dynamic>> createManualSos(String patientId) async =>
      Map<String, dynamic>.from(await post('/emergencies', body: {
        'patientId': patientId,
        'trigger': 'MANUAL_SOS',
      }) as Map);

  // ---- Medical records: real upload/list/download/delete against GridFS -------------------
  Future<List<Map<String, dynamic>>> medicalRecords({String? patientId}) =>
      list('/medical-records', query: patientId != null ? {'patientId': patientId} : null);

  Future<Map<String, dynamic>> uploadMedicalRecord({
    required String patientId,
    required String category,
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) async {
    final token = _session.accessToken;
    final request = http.MultipartRequest('POST', _uri('/medical-records/upload'))
      ..fields['patientId'] = patientId
      ..fields['category'] = category
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: MediaType.parse(contentType)));
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    final streamed = await _client.send(request).timeout(const Duration(seconds: 60));
    final text = await streamed.stream.bytesToString();
    final data = text.isEmpty ? null : jsonDecode(text);
    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return Map<String, dynamic>.from(data as Map);
    }
    final detail = data is Map && data['detail'] != null ? data['detail'].toString() : 'Upload failed (${streamed.statusCode})';
    throw ApiException(detail, statusCode: streamed.statusCode);
  }

  Future<List<int>> downloadMedicalRecord(String recordId) async {
    final token = _session.accessToken;
    final headers = <String, String>{if (token != null) 'Authorization': 'Bearer $token'};
    final response = await _client.get(_uri('/medical-records/$recordId'), headers: headers).timeout(const Duration(seconds: 60));
    if (response.statusCode >= 200 && response.statusCode < 300) return response.bodyBytes;
    throw ApiException('Download failed (${response.statusCode})', statusCode: response.statusCode);
  }

  Future<void> deleteMedicalRecord(String recordId) => delete('/medical-records/$recordId');
}

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(ref.read(sessionProvider.notifier)),
);
