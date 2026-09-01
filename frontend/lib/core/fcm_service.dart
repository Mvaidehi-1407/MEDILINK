import 'dart:developer' as developer;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Background messages arrive on a separate isolate, so this must be a top-level function.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  developer.log('Background FCM message: ${message.messageId}', name: 'FcmService');
}

/// Real Firebase Cloud Messaging wiring: registers the real device token with the backend on
/// login, re-registers on onTokenRefresh, and surfaces foreground/background messages.
/// Gracefully does nothing if no Firebase project is configured (no google-services.json) --
/// Firebase.initializeApp() throws in that case and is caught here rather than crashing the app.
class FcmService {
  FcmService(this._api);
  final ApiClient _api;
  bool _initialized = false;

  Future<void> initializeAndRegister() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _initialized = true;
    } catch (e) {
      developer.log('Firebase not configured for this build; push notifications disabled: $e', name: 'FcmService');
      return;
    }

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      developer.log('Push notification permission denied by user.', name: 'FcmService');
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    final token = await messaging.getToken();
    if (token != null) await _registerToken(token);

    messaging.onTokenRefresh.listen(_registerToken);

    FirebaseMessaging.onMessage.listen((message) {
      developer.log('Foreground FCM message: ${message.notification?.title}', name: 'FcmService');
    });
  }

  Future<void> _registerToken(String token) async {
    try {
      await _api.post('/notifications/fcm-token', body: {
        'token': token,
        'platform': defaultTargetPlatform.name,
      });
    } catch (e) {
      developer.log('Failed to register FCM token with backend: $e', name: 'FcmService');
    }
  }

  bool get isInitialized => _initialized;
}
