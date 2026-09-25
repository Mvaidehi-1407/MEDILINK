import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/api_client.dart';
import '../core/fcm_service.dart';
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
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _identifier = TextEditingController();
  final _care1Name = TextEditingController();
  final _care1Phone = TextEditingController();
  final _care2Name = TextEditingController();
  final _care2Phone = TextEditingController();
  final _care3Name = TextEditingController();
  final _care3Phone = TextEditingController();
  String _role = 'PATIENT';
  bool _loading = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _identifier.dispose();
    _care1Name.dispose();
    _care1Phone.dispose();
    _care2Name.dispose();
    _care2Phone.dispose();
    _care3Name.dispose();
    _care3Phone.dispose();
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
              _phoneField(
                _phone,
                'Phone number (+countrycode...)',
                helperText: 'Used to log in and shared with doctors/caregivers you connect with.',
              ),
              const SizedBox(height: 16),
            ],
            if (widget.login)
              _field(_identifier, 'Email or phone number', Icons.person_outline)
            else
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
              if (_role == 'PATIENT') ...[
                const SizedBox(height: 24),
                Text(
                  'Emergency caretakers',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Add 3 people to contact, in order, if we can\'t reach you during an emergency.',
                ),
                const SizedBox(height: 12),
                _caretakerFields(1, _care1Name, _care1Phone),
                const SizedBox(height: 12),
                _caretakerFields(2, _care2Name, _care2Phone),
                const SizedBox(height: 12),
                _caretakerFields(3, _care3Name, _care3Phone),
              ],
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
  Widget _phoneField(TextEditingController c, String label, {String? helperText}) =>
      TextFormField(
        controller: c,
        keyboardType: TextInputType.phone,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.phone_outlined),
          helperText: helperText,
        ),
        validator: (v) {
          if (v == null || v.trim().isEmpty) return 'Phone number is required';
          if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(v.trim())) {
            return 'Use E.164 format, e.g. +919876543210';
          }
          return null;
        },
      );
  Widget _caretakerFields(int index, TextEditingController name, TextEditingController phone) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Caretaker $index', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(Icons.person_outline)),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Caretaker name is required' : null,
          ),
          const SizedBox(height: 8),
          _phoneField(phone, 'Phone number'),
        ],
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
          ? await api.login(_identifier.text.trim(), _password.text)
          : await api.register(
              name: _name.text.trim(),
              email: _email.text.trim(),
              password: _password.text,
              role: _role,
              phone: _phone.text.trim(),
              caretakers: _role == 'PATIENT'
                  ? [
                      {'name': _care1Name.text.trim(), 'phone': _care1Phone.text.trim()},
                      {'name': _care2Name.text.trim(), 'phone': _care2Phone.text.trim()},
                      {'name': _care3Name.text.trim(), 'phone': _care3Phone.text.trim()},
                    ]
                  : null,
            );
      await ref.read(sessionProvider.notifier).saveAuth(payload);
      unawaited(FcmService(ref.read(apiClientProvider)).initializeAndRegister());
      // amends/51-52: previously only a brand-new signup ever saw this screen, so a returning
      // login after a fresh install (permissions reset by the OS on uninstall) never got asked
      // for location at all -- it only ever got requested reactively, mid-emergency, too late to
      // matter for a no-response timeout. PermissionsPage itself skips straight through when
      // everything's already granted, so this costs an already-set-up user nothing.
      if (mounted) context.go('/permissions');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});
  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  // amends/51-52: previously this screen was signup-only and had no way to tell whether
  // permissions were already granted -- a returning user after a fresh reinstall (permissions
  // reset by the OS) never saw it at all, so location was never requested proactively, only
  // reactively mid-emergency. Auto-skipping when everything's already granted keeps this free
  // for an already-set-up user while still reliably prompting a fresh install.
  bool _checkedInitialSkip = false;

  // amends/58: previously only Bluetooth-scan, location, and notifications were requested here --
  // BLUETOOTH_CONNECT (needed for the actual BLE data connection, not just scanning), phone
  // (CALL_PHONE, for the automatic emergency call), and SMS (SEND_SMS, for the automatic
  // emergency text) were only ever requested reactively, the first time a real relayed call/SMS
  // attempt fired -- exactly the "fails later at an unpredictable point" scenario a live
  // emergency must never hit. All 6 are now requested upfront, before Home is reachable.
  static const _requiredPermissions = [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
    Permission.phone,
    Permission.sms,
    Permission.notification,
  ];
  final Map<Permission, bool> _grantedState = {};

  bool get _allGranted =>
      _grantedState.length == _requiredPermissions.length && _grantedState.values.every((g) => g);

  void _onTileStatus(List<Permission> permissions, bool granted) {
    setState(() {
      for (final p in permissions) {
        _grantedState[p] = granted;
      }
    });
  }

  Future<void> _maybeAutoSkip() async {
    final granted = await Future.wait(_requiredPermissions.map((p) => p.isGranted));
    if (mounted && granted.every((g) => g)) {
      context.go('/app');
    } else if (mounted) {
      setState(() => _checkedInitialSkip = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _maybeAutoSkip();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedInitialSkip) {
      return const Scaffold(body: LoadingState(label: 'Checking permissions...'));
    }
    return Scaffold(
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
              'MEDILINK needs every permission below before it can monitor you safely -- '
              'each one is used only for real emergency response, never anything else.',
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView(
                children: [
                  PermissionTile(
                    icon: Icons.bluetooth_outlined,
                    title: 'Bluetooth',
                    explanation: 'Needed to connect to your wearable device.',
                    permissions: const [Permission.bluetoothScan, Permission.bluetoothConnect],
                    onStatusChanged: (g) => _onTileStatus(const [Permission.bluetoothScan, Permission.bluetoothConnect], g),
                  ),
                  PermissionTile(
                    icon: Icons.location_on_outlined,
                    title: 'Location',
                    explanation:
                        'Used during a real emergency, to tell your caretakers and the nearest hospital where you are.',
                    permissions: const [Permission.location],
                    onStatusChanged: (g) => _onTileStatus(const [Permission.location], g),
                  ),
                  PermissionTile(
                    icon: Icons.call_outlined,
                    title: 'Phone calls',
                    explanation: 'Needed so your phone can automatically call your caretakers in a confirmed emergency.',
                    permissions: const [Permission.phone],
                    onStatusChanged: (g) => _onTileStatus(const [Permission.phone], g),
                  ),
                  PermissionTile(
                    icon: Icons.sms_outlined,
                    title: 'SMS',
                    explanation: 'Needed so your phone can automatically text your caretakers in a confirmed emergency.',
                    permissions: const [Permission.sms],
                    onStatusChanged: (g) => _onTileStatus(const [Permission.sms], g),
                  ),
                  PermissionTile(
                    icon: Icons.notifications_outlined,
                    title: 'Notifications',
                    explanation: 'Alerts you and your care team the moment something needs attention.',
                    permissions: const [Permission.notification],
                    onStatusChanged: (g) => _onTileStatus(const [Permission.notification], g),
                  ),
                ],
              ),
            ),
            // amends/58: previously this always continued regardless of what was granted --
            // a denied permission failed silently later, at the exact moment of a real
            // emergency. Now disabled until every permission above is actually granted.
            PrimaryButton(
              label: _allGranted ? 'Continue to MEDILINK' : 'Grant all permissions to continue',
              onPressed: _allGranted ? () => context.go('/app') : null,
              icon: Icons.arrow_forward,
            ),
          ],
        ),
      ),
    );
  }
}

class PermissionTile extends StatefulWidget {
  const PermissionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.explanation,
    required this.permissions,
    this.onStatusChanged,
  });
  final IconData icon;
  final String title;
  final String explanation;
  // amends/58: a group of permissions requested and reported together (e.g. Bluetooth scan +
  // connect are one logical "Bluetooth" row to the user, even though Android treats them as two
  // separate runtime permissions).
  final List<Permission> permissions;
  final ValueChanged<bool>? onStatusChanged;
  @override
  State<PermissionTile> createState() => _PermissionTileState();
}

class _PermissionTileState extends State<PermissionTile> {
  Map<Permission, PermissionStatus> _statuses = {};
  bool get _checked => _statuses.length == widget.permissions.length;
  bool get _allGranted => _checked && _statuses.values.every((s) => s.isGranted);

  Future<void> _refresh(Map<Permission, PermissionStatus> statuses) async {
    if (!mounted) return;
    setState(() => _statuses = statuses);
    widget.onStatusChanged?.call(_allGranted);
  }

  @override
  void initState() {
    super.initState();
    Future.wait(widget.permissions.map((p) async => MapEntry(p, await p.status)))
        .then((entries) => _refresh(Map.fromEntries(entries)));
  }

  Future<void> _request() async {
    _refresh(await widget.permissions.request());
  }

  @override
  Widget build(BuildContext context) {
    final granted = _allGranted;
    // Only true after an actual request came back denied -- never shown before the first tap,
    // so a permission nobody has asked about yet doesn't read as "you already said no".
    final deniedAfterAsking = _checked && !granted;
    final permanentlyDenied = _statuses.values.any((s) => s.isPermanentlyDenied);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SectionCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(widget.icon, color: MedilinkColors.blue),
                title: Text(widget.title),
                trailing: granted
                    ? const Icon(Icons.check_circle, color: MedilinkColors.teal)
                    : TextButton(
                        onPressed: permanentlyDenied ? openAppSettings : _request,
                        child: Text(permanentlyDenied ? 'Open Settings' : 'Allow'),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                child: Text(
                  // Clear explanation + a real way to retry (the same button, re-tappable) when
                  // denied, rather than the permission silently failing later mid-emergency.
                  deniedAfterAsking
                      ? (permanentlyDenied
                            ? '${widget.explanation} Denied permanently -- enable it in Settings, then come back here.'
                            : '${widget.explanation} You said no -- tap Allow to try again.')
                      : widget.explanation,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: deniedAfterAsking ? MedilinkColors.amber : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
