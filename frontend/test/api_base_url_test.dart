import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medilink/core/api_client.dart';
import 'package:medilink/core/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('normalizeApiBaseUrl', () {
    expect(normalizeApiBaseUrl(' medilink-backend-6a75.onrender.com/ '), productionApiBaseUrl);
    expect(normalizeApiBaseUrl('http://medilink-backend-6a75.onrender.com/api/'), productionApiBaseUrl);
    expect(normalizeApiBaseUrl('192.168.1.20:8000'), 'http://192.168.1.20:8000/api');
    expect(normalizeApiBaseUrl('http://10.0.2.2:8000/api'), 'http://10.0.2.2:8000/api');
    expect(normalizeApiBaseUrl(''), '');
  });

  test('POST strips trailing slash and re-sends 307 with same method and body', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final session = container.read(sessionProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    session.apiBaseUrl = productionApiBaseUrl;

    final seen = <String>[];
    final client = MockClient((request) async {
      seen.add('${request.method} ${request.url.path} ${request.body}');
      if (request.url.path == '/api/auth/login') {
        return http.Response('', 307, headers: {'location': '/api/auth/login2'});
      }
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final api = ApiClient(session, client: client);

    final result = await api.post('/auth/login/', body: {'identifier': 'a', 'password': 'b'});
    expect(result, {'ok': true});
    expect(seen, [
      'POST /api/auth/login {"identifier":"a","password":"b"}',
      'POST /api/auth/login2 {"identifier":"a","password":"b"}',
    ]);
  });
}
