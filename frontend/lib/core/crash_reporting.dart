import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Real Crashlytics wiring (Phase 19). Gracefully does nothing if no Firebase project is
/// configured (no google-services.json) -- Firebase.initializeApp() throws in that case and is
/// caught here rather than crashing the app on startup. Call `initialize()` once before
/// `runApp`, then run the app inside `runZonedGuarded` so zone errors are captured too.
class CrashReporting {
  static bool _available = false;
  static bool get available => _available;

  static Future<void> initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
      _available = true;
    } catch (e) {
      developer.log('Firebase not configured for this build; Crashlytics disabled: $e', name: 'CrashReporting');
      _available = false;
    }
  }

  /// Manual trigger used by the "Force test crash" debug action so a real crash reaching
  /// Crashlytics can be verified once a Firebase project is configured.
  static void forceTestCrash() {
    if (_available) {
      FirebaseCrashlytics.instance.crash();
    } else {
      throw StateError('Forced test crash (Crashlytics not configured for this build)');
    }
  }

  static void recordError(Object error, StackTrace stack, {String? reason}) {
    if (_available) {
      FirebaseCrashlytics.instance.recordError(error, stack, reason: reason);
    }
  }
}
