import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../widgets/common.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _controller = PageController();
  int _page = 0;
  static const _cards = [
    (
      'Your Health. Always Connected.',
      'MEDILINK links your wearable, phone, and care team.',
      Icons.monitor_heart_outlined,
    ),
    (
      'Detect Before It Escalates.',
      'Health data is assessed using configured thresholds.',
      Icons.analytics_outlined,
    ),
    (
      'When It Matters, Respond Faster.',
      'Potential emergencies connect location and care teams.',
      Icons.emergency_outlined,
    ),
    (
      'One Platform. Connected Care.',
      'Patient, caregiver, doctor, and hospital teams work together.',
      Icons.hub_outlined,
    ),
  ];
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _finish, child: const Text('Skip')),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _cards.length,
                onPageChanged: (v) => setState(() => _page = v),
                itemBuilder: (context, index) {
                  final item = _cards[index];
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        height: 220,
                        width: 220,
                        decoration: BoxDecoration(
                          color: MedilinkColors.blue.withValues(alpha: .08),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          item.$3,
                          size: 100,
                          color: MedilinkColors.teal,
                        ),
                      ),
                      const SizedBox(height: 42),
                      Text(
                        item.$1,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 16),
                      Text(item.$2, textAlign: TextAlign.center),
                    ],
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _cards.length,
                (i) => Container(
                  margin: const EdgeInsets.all(4),
                  height: 8,
                  width: i == _page ? 24 : 8,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? MedilinkColors.blue
                        : Colors.blueGrey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                if (_page > 0)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _controller.previousPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      ),
                      child: const Text('Back'),
                    ),
                  ),
                if (_page > 0) const SizedBox(width: 12),
                Expanded(
                  child: PrimaryButton(
                    label: _page == _cards.length - 1 ? 'Get started' : 'Next',
                    onPressed: _page == _cards.length - 1
                        ? _finish
                        : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                    icon: Icons.arrow_forward,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> _finish() async {
    await ref.read(sessionProvider.notifier).completeOnboarding();
    if (mounted) context.go('/welcome');
  }
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(),
            const Icon(
              Icons.health_and_safety_outlined,
              color: MedilinkColors.blue,
              size: 58,
            ),
            const SizedBox(height: 24),
            Text(
              'MEDILINK',
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: MedilinkColors.blue,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Monitor. Detect. Connect. Respond.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            PrimaryButton(
              label: 'Sign in',
              onPressed: () => context.go('/login'),
              icon: Icons.login,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.go('/signup'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: const Text('Create account'),
            ),
          ],
        ),
      ),
    ),
  );
}

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key, required this.login});
  final bool login;
  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String _role = 'PATIENT';
  bool _loading = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.login ? 'Sign in' : 'Create account')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.login ? 'Welcome back' : 'Join MEDILINK',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 24),
            if (!widget.login) ...[
              _field(_name, 'Full name', Icons.person_outline),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Your role'),
                items: const [
                  DropdownMenuItem(value: 'PATIENT', child: Text('Patient')),
                  DropdownMenuItem(
                    value: 'CAREGIVER',
                    child: Text('Caregiver'),
                  ),
                  DropdownMenuItem(value: 'DOCTOR', child: Text('Doctor')),
                  DropdownMenuItem(value: 'HOSPITAL', child: Text('Hospital')),
                ],
                onChanged: (v) => setState(() => _role = v!),
              ),
              const SizedBox(height: 16),
            ],
            _field(_email, 'Email address', Icons.email_outlined),
            const SizedBox(height: 16),
            _field(_password, 'Password', Icons.lock_outline, obscure: true),
            if (!widget.login) ...[
              const SizedBox(height: 16),
              _field(
                _confirm,
                'Confirm password',
                Icons.lock_outline,
                obscure: true,
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: MedilinkColors.red),
                ),
              ),
            const SizedBox(height: 28),
            PrimaryButton(
              label: widget.login ? 'Login' : 'Create account',
              loading: _loading,
              onPressed: _submit,
              icon: widget.login ? Icons.login : Icons.arrow_forward,
            ),
            Center(
              child: TextButton(
                onPressed: () =>
                    context.go(widget.login ? '/signup' : '/login'),
                child: Text(
                  widget.login
                      ? 'Need an account? Sign up'
                      : 'Already have an account? Sign in',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _field(
    TextEditingController c,
    String label,
    IconData icon, {
    bool obscure = false,
  }) => TextFormField(
    controller: c,
    obscureText: obscure,
    decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
    validator: (v) {
      if (v == null || v.trim().isEmpty) return '$label is required';
      if (label == 'Email address' && !v.contains('@'))
        return 'Enter a valid email address';
      if (label == 'Password' && v.length < 8)
        return 'Password must have at least 8 characters';
      if (label == 'Confirm password' && v != _password.text)
        return 'Passwords do not match';
      return null;
    },
  );
  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final payload = widget.login
          ? await api.login(_email.text.trim(), _password.text)
          : await api.register(
              name: _name.text.trim(),
              email: _email.text.trim(),
              password: _password.text,
              role: _role,
            );
      await ref.read(sessionProvider.notifier).saveAuth(payload);
      if (mounted) context.go(widget.login ? '/app' : '/permissions');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

class PermissionsPage extends StatelessWidget {
  const PermissionsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Permissions')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Set up safe monitoring',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          const Text(
            'MEDILINK uses Bluetooth, location, and notifications only for connected care.',
          ),
          const SizedBox(height: 24),
          const Expanded(
            child: Column(
              children: [
                PermissionTile(
                  icon: Icons.bluetooth_outlined,
                  title: 'Bluetooth',
                  permission: Permission.bluetoothScan,
                ),
                PermissionTile(
                  icon: Icons.location_on_outlined,
                  title: 'Location',
                  permission: Permission.location,
                ),
                PermissionTile(
                  icon: Icons.notifications_outlined,
                  title: 'Notifications',
                  permission: Permission.notification,
                ),
              ],
            ),
          ),
          PrimaryButton(
            label: 'Continue to MEDILINK',
            onPressed: () => context.go('/app'),
            icon: Icons.arrow_forward,
          ),
        ],
      ),
    ),
  );
}

class PermissionTile extends StatelessWidget {
  const PermissionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.permission,
  });
  final IconData icon;
  final String title;
  final Permission permission;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SectionCard(
      child: ListTile(
        leading: Icon(icon, color: MedilinkColors.blue),
        title: Text(title),
        trailing: TextButton(
          onPressed: () => permission.request(),
          child: const Text('Allow'),
        ),
      ),
    ),
  );
}
