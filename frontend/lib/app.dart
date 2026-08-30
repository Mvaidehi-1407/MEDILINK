import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/session.dart';
import 'features/auth_flow.dart';
import 'features/dashboard.dart';
import 'widgets/common.dart';

class MedilinkApp extends ConsumerWidget {
  const MedilinkApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seniorMode = ref.watch(sessionProvider).seniorMode;
    return MaterialApp.router(
      title: 'MEDILINK',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: MedilinkColors.blue,
          brightness: Brightness.light,
          primary: MedilinkColors.blue,
          secondary: MedilinkColors.teal,
          error: MedilinkColors.red,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: MedilinkColors.canvas,
        cardTheme: const CardThemeData(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          color: Colors.white,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        textTheme: ThemeData.light().textTheme.apply(
          fontSizeFactor: seniorMode ? 1.18 : 1,
        ),
      ),
      routerConfig: appRouter,
    );
  }
}

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const StartupGate()),
    GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingPage()),
    GoRoute(path: '/welcome', builder: (_, __) => const WelcomePage()),
    GoRoute(path: '/login', builder: (_, __) => const AuthPage(login: true)),
    GoRoute(path: '/signup', builder: (_, __) => const AuthPage(login: false)),
    GoRoute(path: '/permissions', builder: (_, __) => const PermissionsPage()),
    GoRoute(path: '/app', builder: (_, __) => const AuthGate()),
  ],
);

class StartupGate extends ConsumerWidget {
  const StartupGate({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    Future.microtask(
      () => context.go(
        session.signedIn
            ? '/app'
            : session.onboarded
            ? '/welcome'
            : '/onboarding',
      ),
    );
    return const Scaffold(
      body: Center(
        child: LoadingState(
          label: 'MEDILINK\nMonitor. Detect. Connect. Respond.',
        ),
      ),
    );
  }
}

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sessionProvider).signedIn) {
      Future.microtask(() => context.go('/login'));
      return const Scaffold(
        body: LoadingState(label: 'Securing your MEDILINK session...'),
      );
    }
    return const RoleShell();
  }
}
