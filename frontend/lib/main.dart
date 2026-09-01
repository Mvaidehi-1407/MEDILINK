import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/crash_reporting.dart';

void main() {
  // WidgetsFlutterBinding.ensureInitialized() and runApp() must run in the same zone -- calling
  // ensureInitialized() in the root zone and runApp() inside runZonedGuarded's child zone
  // triggers a "Zone mismatch" that corrupts zone-scoped framework state (this was the actual
  // cause of a downstream text_style/fontSize rendering assertion on first frame). Everything
  // that touches bindings/rendering must live inside the same guarded zone.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await CrashReporting.initialize();
      runApp(const ProviderScope(child: MedilinkApp()));
    },
    (error, stack) => CrashReporting.recordError(error, stack, reason: 'Uncaught zone error'),
  );
}
