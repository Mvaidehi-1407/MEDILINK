import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/api_client.dart';
import '../core/fcm_service.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/brand.dart';
import '../ui/components.dart';
import '../ui/onboarding.dart';
import '../widgets/common.dart';
import 'doctor_portal.dart' show DoctorFieldsController, DoctorProfileFields;
import 'profile_pages.dart' show ServerSettingsPage;

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
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const MedilinkLockup(fontSize: 18),
                Positioned(
                  right: AppSpacing.xs,
                  child: TextButton(
                    onPressed: _finish,
                    style: TextButton.styleFrom(foregroundColor: AppColors.inkSecondary),
                    child: const Text('Skip'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _cards.length,
              onPageChanged: (v) => setState(() => _page = v),
              itemBuilder: (context, index) {
                final item = _cards[index];
                return OnboardingCard(
                  index: index,
                  title: item.$1,
                  body: item.$2,
                  controller: _controller,
                );
              },
            ),
          ),
          PageDots(controller: _controller, count: _cards.length, current: _page),
          const SizedBox(height: AppSpacing.xl),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.md),
            child: Row(
              children: [
                if (_page > 0)
                  Expanded(
                    flex: 2,
                    child: PressScale(
                      child: OutlinedButton(
                        onPressed: () => _controller.previousPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        ),
                        child: const Text('Back'),
                      ),
                    ),
                  ),
                if (_page > 0) const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 3,
                  child: PressScale(
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
                ),
              ],
            ),
          ),
        ],
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
    body: BrandBackdrop(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xl, AppSpacing.gutter, AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              const Center(child: MedilinkLockup(fontSize: 34, vertical: true)),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Monitor. Detect. Connect. Respond.',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(fontSize: 16),
              ),
              const Spacer(flex: 4),
              PrimaryButton(
                label: 'Sign in',
                onPressed: () => context.go('/login'),
                icon: Icons.login_rounded,
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                onPressed: () => context.go('/signup'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: Colors.transparent,
                  side: const BorderSide(color: AppColors.border),
                ),
                child: const Text('Create account'),
              ),
            ],
          ),
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
  final _doctor = DoctorFieldsController();
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
    _doctor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.login ? 'Sign in' : 'Create account',
        style: AppText.titleSm.copyWith(color: AppColors.inkSecondary),
      ),
    ),
    body: SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(alignment: Alignment.centerLeft, child: MedilinkMark(size: 48)),
              const SizedBox(height: AppSpacing.md),
              Text(widget.login ? 'Welcome back' : 'Join MEDILINK', style: AppText.headline),
              const SizedBox(height: AppSpacing.xl),
              if (!widget.login) ...[
                _field(_name, 'Full name', Icons.person_outline_rounded),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'Your role',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  borderRadius: AppRadius.inputAll,
                  dropdownColor: AppColors.surface,
                  style: AppText.body.copyWith(color: AppColors.ink),
                  icon: const Icon(Icons.expand_more_rounded),
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
                const SizedBox(height: AppSpacing.md),
                _phoneField(
                  _phone,
                  'Phone number (+countrycode...)',
                  helperText: 'Used to log in and shared with doctors/caregivers you connect with.',
                ),
                const SizedBox(height: AppSpacing.xl),
              ],
              if (widget.login)
                _field(_identifier, 'Email or phone number', Icons.person_outline_rounded)
              else
                _field(_email, 'Email address', Icons.mail_outline_rounded),
              const SizedBox(height: AppSpacing.md),
              _field(_password, 'Password', Icons.lock_outline_rounded, obscure: true),
              if (!widget.login) ...[
                const SizedBox(height: AppSpacing.md),
                _field(
                  _confirm,
                  'Confirm password',
                  Icons.lock_outline_rounded,
                  obscure: true,
                ),
                if (_role == 'PATIENT') ...[
                  const SizedBox(height: AppSpacing.xxl),
                  Text('Emergency caretakers', style: AppText.title),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    'Add 3 people to contact, in order, if we can\'t reach you during an emergency.',
                    style: AppText.bodySm,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _caretakerFields(1, _care1Name, _care1Phone),
                  const SizedBox(height: AppSpacing.sm),
                  _caretakerFields(2, _care2Name, _care2Phone),
                  const SizedBox(height: AppSpacing.sm),
                  _caretakerFields(3, _care3Name, _care3Phone),
                ],
                if (_role == 'DOCTOR') ...[
                  const SizedBox(height: AppSpacing.xxl),
                  Text('Professional details', style: AppText.title),
                  const SizedBox(height: AppSpacing.xxs),
                  Text('Patients see these on your profile. You can change them later.', style: AppText.bodySm),
                  const SizedBox(height: AppSpacing.md),
                  DoctorProfileFields(controller: _doctor),
                ],
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.lg),
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: AppColors.dangerTint,
                        borderRadius: AppRadius.inputAll,
                        border: Border.all(color: AppColors.danger.withValues(alpha: .25)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
                          const SizedBox(width: AppSpacing.xs + 2),
                          Expanded(
                            child: Text(
                              _error!,
                              style: AppText.bodySm.copyWith(color: AppColors.dangerPressed, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.xl),
              PrimaryButton(
                label: widget.login ? 'Login' : 'Create account',
                loading: _loading,
                onPressed: _submit,
                icon: widget.login ? Icons.login_rounded : Icons.arrow_forward,
              ),
              const SizedBox(height: AppSpacing.xs),
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
              // A physical phone can't use the emulator's default server address.
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const ServerSettingsPage()),
                  ),
                  icon: const Icon(Icons.dns_outlined, size: 18),
                  label: const Text('Server settings'),
                ),
              ),
            ],
          ),
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
    decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon, size: 22)),
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
          prefixIcon: const Icon(Icons.phone_outlined, size: 22),
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
      SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: AppColors.primaryTint, shape: BoxShape.circle),
                  child: Text(
                    '$index',
                    style: AppText.caption.copyWith(color: AppColors.primaryPressed, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm - 2),
                Text('Caretaker $index', style: AppText.bodyStrong),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(Icons.person_outline_rounded, size: 22)),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Caretaker name is required' : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            _phoneField(phone, 'Phone number'),
          ],
        ),
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
              doctor: _role == 'DOCTOR' ? _doctor.toJson() : null,
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
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.md),
                children: [
                  Text('Set up safe monitoring', style: AppText.headline),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'MEDILINK needs every permission below before it can monitor you safely -- '
                    'each one is used only for real emergency response, never anything else.',
                    style: AppText.body,
                  ),
                  const SizedBox(height: AppSpacing.xl),
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
            Container(
              padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, AppSpacing.md),
              decoration: const BoxDecoration(
                color: AppColors.canvas,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: PrimaryButton(
                label: _allGranted ? 'Continue to MEDILINK' : 'Grant all permissions to continue',
                onPressed: _allGranted ? () => context.go('/app') : null,
                icon: Icons.arrow_forward,
              ),
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
    final tint = {
          Icons.bluetooth_outlined: AppColors.tintBlue,
          Icons.location_on_outlined: AppColors.tintRed,
          Icons.call_outlined: AppColors.tintMint,
          Icons.sms_outlined: AppColors.tintAmber,
          Icons.notifications_outlined: AppColors.tintViolet,
        }[widget.icon] ??
        AppColors.tintMint;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SectionCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(icon: widget.icon, tint: tint),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Expanded(child: Text(widget.title, style: AppText.titleSm)),
                        if (granted)
                          const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 24),
                      ],
                    ),
                  ),
                  Text(widget.explanation, style: AppText.bodySm),
                  // Clear explanation + a real way to retry (the same button, re-tappable) when
                  // denied, rather than the permission silently failing later mid-emergency.
                  if (deniedAfterAsking) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 1),
                          child: Icon(Icons.info_outline_rounded, size: 18, color: AppColors.warning),
                        ),
                        const SizedBox(width: AppSpacing.xs - 2),
                        Expanded(
                          child: Text(
                            permanentlyDenied
                                ? 'Denied permanently -- enable it in Settings, then come back here.'
                                : 'You said no -- tap Allow to try again.',
                            style: AppText.bodySm.copyWith(color: AppColors.warning, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (!granted) ...[
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: permanentlyDenied ? openAppSettings : _request,
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.primaryTint,
                        foregroundColor: AppColors.primaryPressed,
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                      ),
                      child: Text(permanentlyDenied ? 'Open Settings' : 'Allow'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
