import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/components.dart';
import '../ui/fallback.dart';
import '../ui/format.dart';
import '../widgets/common.dart';
import 'doctor_care.dart';
import 'doctor_portal.dart';
import 'profile_pages.dart' show AboutPage, ProfileAvatar;

final doctorAccountProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) async => Map<String, dynamic>.from(await ref.read(apiClientProvider).get('/doctor/account') as Map),
);

/// Logout: revoke the refresh token, then clear the session. Clearing it unmounts DoctorShell,
/// which disposes every open chat WebSocket.
Future<void> doctorLogout(BuildContext context, WidgetRef ref) async {
  final session = ref.read(sessionProvider.notifier);
  final refresh = session.refreshToken;
  if (refresh != null) {
    try {
      await ref.read(apiClientProvider).post('/auth/logout', body: {'refreshToken': refresh});
    } catch (_) {
      // Offline: tokens are still cleared locally below.
    }
  }
  await session.clear();
  if (context.mounted) context.go('/welcome');
}

/// A settings-style row in the patient Profile pattern (pastel icon circle, label, chevron).
class SettingsRow extends StatelessWidget {
  const SettingsRow({super.key, required this.icon, required this.label, required this.onTap, this.subtitle, this.tint = AppColors.tintBlue});
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final (Color, Color) tint;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: () {
      HapticFeedback.selectionClick();
      onTap();
    },
    minVerticalPadding: AppSpacing.sm,
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
    leading: IconBadge(icon: icon, tint: tint, size: 36),
    title: Text(label, style: AppText.bodyStrong),
    subtitle: subtitle == null ? null : Text(subtitle!, style: AppText.bodySm),
    trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.inkSecondary),
  );
}

Widget rowGroup(List<Widget> rows) => SectionCard(
  padding: EdgeInsets.zero,
  child: Column(children: [
    for (var i = 0; i < rows.length; i++) ...[if (i > 0) const Divider(height: 1, indent: 64), rows[i]],
  ]),
);

// =============================================================================================
// Profile tab
// =============================================================================================

class DoctorProfileTab extends ConsumerWidget {
  const DoctorProfileTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final profile = ref.watch(doctorProfileProvider).value ?? const {};
    final account = ref.watch(doctorAccountProvider).value ?? const {};
    final spec = profile['specialization'] == 'Other' ? profile['specializationOther'] : profile['specialization'];
    final line1 = [spec, profile['qualification'], if (profile['experienceYears'] != null) '${profile['experienceYears']} yrs experience'].whereType<Object>().join(' · ');
    Future<void> go(Widget page) async {
      await pushPage(context, page);
      ref.invalidate(doctorProfileProvider);
      ref.invalidate(doctorAccountProvider);
      ref.invalidate(doctorHomeProvider);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        titleSpacing: AppSpacing.gutter,
        actions: [
          IconButton(tooltip: 'App settings', onPressed: () => go(const DoctorSettingsPage()), icon: const Icon(Icons.settings_outlined)),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(doctorProfileProvider);
          ref.invalidate(doctorAccountProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
          children: [
            const Center(child: ProfileAvatar()),
            const SizedBox(height: AppSpacing.md),
            Text(account['name']?.toString() ?? session.user?['name']?.toString() ?? '', textAlign: TextAlign.center, style: AppText.title.copyWith(fontSize: 22)),
            const SizedBox(height: AppSpacing.xxs),
            Text(line1.isEmpty ? 'Add your specialization in Edit profile' : line1, textAlign: TextAlign.center, style: AppText.bodySm),
            Text(profile['hospitalName']?.toString() ?? 'Hospital / clinic not set', textAlign: TextAlign.center, style: AppText.bodySm.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.sm),
            Center(child: StatusPill(label: availabilityLabel(profile['accepting'] == false ? 'UNAVAILABLE' : profile['availability']), color: profile['accepting'] == false ? AppColors.warning : AppColors.success)),
            const SizedBox(height: AppSpacing.xl),
            rowGroup([
              SettingsRow(icon: Icons.edit_outlined, label: 'Edit profile', tint: AppColors.tintMint, onTap: () => go(const DoctorEditProfilePage())),
              SettingsRow(icon: Icons.assignment_turned_in_outlined, label: 'My consultations', onTap: () => go(const MyConsultationsPage())),
              SettingsRow(icon: Icons.event_available_outlined, label: 'Availability', tint: AppColors.tintAmber, onTap: () => go(const AvailabilityPage())),
            ]),
            const SizedBox(height: AppSpacing.md),
            rowGroup([
              SettingsRow(icon: Icons.settings_outlined, label: 'App settings', onTap: () => go(const DoctorSettingsPage())),
              SettingsRow(icon: Icons.notifications_none_rounded, label: 'Notifications', onTap: () => go(const DoctorNotificationsPage())),
              SettingsRow(icon: Icons.info_outline_rounded, label: 'About MediLink', onTap: () => go(const AboutPage())),
              SettingsRow(icon: Icons.help_outline_rounded, label: 'Help & support', tint: AppColors.tintMint, onTap: () => go(const DoctorHelpPage())),
            ]),
            const SizedBox(height: AppSpacing.md),
            SectionCard(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
              child: SwitchListTile(
                value: session.seniorMode,
                onChanged: (v) => ref.read(sessionProvider.notifier).setSeniorMode(v),
                title: Text('Senior Mode', style: AppText.bodyStrong),
                subtitle: Text('Larger text across the app', style: AppText.bodySm),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: () => doctorLogout(context, ref),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                shape: const StadiumBorder(),
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.borderStrong),
              ),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Logout'),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================================
// Edit profile
// =============================================================================================

class DoctorEditProfilePage extends ConsumerStatefulWidget {
  const DoctorEditProfilePage({super.key});
  @override
  ConsumerState<DoctorEditProfilePage> createState() => _DoctorEditProfilePageState();
}

class _DoctorEditProfilePageState extends ConsumerState<DoctorEditProfilePage> {
  final _form = GlobalKey<FormState>();
  DoctorFieldsController? _fields;
  TextEditingController? _name, _email, _phone;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _fields?.dispose();
    _name?.dispose();
    _email?.dispose();
    _phone?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await api.patch('/doctor/account', body: {'name': _name!.text.trim(), 'email': _email!.text.trim(), 'phone': _phone!.text.trim()});
      await api.patch('/doctor/profile', body: _fields!.toJson());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile saved')));
      Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(doctorProfileProvider);
    final account = ref.watch(doctorAccountProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile'), titleSpacing: 0),
      body: asyncBody(
        profile,
        onRetry: () => ref.invalidate(doctorProfileProvider),
        data: (p) => asyncBody(
          account,
          onRetry: () => ref.invalidate(doctorAccountProvider),
          data: (a) {
            _fields ??= DoctorFieldsController(p);
            _name ??= TextEditingController(text: a['name']?.toString() ?? '');
            _email ??= TextEditingController(text: a['email']?.toString() ?? '');
            _phone ??= TextEditingController(text: a['phone']?.toString() ?? '');
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: ProfileAvatar()),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline_rounded, size: 22)),
                      validator: (v) => (v == null || v.trim().length < 2) ? 'Full name is required' : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email address', helperText: 'Never shown to patients.', prefixIcon: Icon(Icons.mail_outline_rounded, size: 22)),
                      validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email address' : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Mobile number', helperText: 'Never shown to patients.', prefixIcon: Icon(Icons.phone_outlined, size: 22)),
                      validator: (v) => RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(v?.trim() ?? '') ? null : 'Use E.164 format, e.g. +919876543210',
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Text('Professional details', style: AppText.title),
                    const SizedBox(height: AppSpacing.md),
                    DoctorProfileFields(controller: _fields!),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Semantics(liveRegion: true, child: Text(_error!, style: AppText.bodySm.copyWith(color: AppColors.danger))),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    PrimaryButton(label: 'Save changes', loading: _saving, onPressed: _save),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================================
// Availability
// =============================================================================================

class AvailabilityPage extends ConsumerStatefulWidget {
  const AvailabilityPage({super.key});
  @override
  ConsumerState<AvailabilityPage> createState() => _AvailabilityPageState();
}

class _AvailabilityPageState extends ConsumerState<AvailabilityPage> {
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  bool _loaded = false, _on = true, _saving = false;
  Set<String> _selected = {};
  TimeOfDay _from = const TimeOfDay(hour: 9, minute: 0), _to = const TimeOfDay(hour: 17, minute: 0);
  final _clinic = TextEditingController();
  DateTime? _awayUntil;

  @override
  void dispose() {
    _clinic.dispose();
    super.dispose();
  }

  void _fill(Map<String, dynamic> p) {
    _loaded = true;
    _on = p['availability'] != 'UNAVAILABLE';
    _selected = {...(p['availabilityDays'] as List? ?? []).map((d) => d.toString())};
    final hours = p['availabilityHours']?.toString().split('-');
    TimeOfDay? t(String s) => s.contains(':') ? TimeOfDay(hour: int.parse(s.split(':')[0]), minute: int.parse(s.split(':')[1])) : null;
    if (hours != null && hours.length == 2) {
      _from = t(hours[0]) ?? _from;
      _to = t(hours[1]) ?? _to;
    }
    _clinic.text = p['availabilityClinic']?.toString() ?? '';
    final until = parseBackendTime(p['unavailableUntil']);
    _awayUntil = until != null && until.isAfter(DateTime.now()) ? until : null;
  }

  String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).patch('/doctor/profile', body: {
        'availability': _on ? 'AVAILABLE' : 'UNAVAILABLE',
        'availabilityDays': _days.where(_selected.contains).toList(),
        'availabilityHours': '${_hhmm(_from)}-${_hhmm(_to)}',
        'availabilityClinic': _clinic.text.trim().isEmpty ? null : _clinic.text.trim(),
        'unavailableUntil': _awayUntil?.toUtc().toIso8601String(),
      });
      ref.invalidate(doctorProfileProvider);
      ref.invalidate(doctorHomeProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Availability saved')));
      Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Availability'), titleSpacing: 0),
    body: asyncBody(
      ref.watch(doctorProfileProvider),
      onRetry: () => ref.invalidate(doctorProfileProvider),
      data: (p) {
        if (!_loaded) _fill(p);
        return ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
          children: [
            SectionCard(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
              child: SwitchListTile(
                value: _on,
                onChanged: (v) => setState(() => _on = v),
                title: Text('Taking new requests', style: AppText.bodyStrong),
                subtitle: Text("When off, patients still see you, marked unavailable. Your chats and alerts don't change.", style: AppText.bodySm),
              ),
            ),
            const SectionHeader('Days'),
            Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
              for (final d in _days)
                FilterChip(
                  label: Text(d),
                  selected: _selected.contains(d),
                  onSelected: (on) => setState(() => on ? _selected.add(d) : _selected.remove(d)),
                ),
            ]),
            const SectionHeader('Hours'),
            Row(children: [
              for (final (label, isFrom) in [('From', true), ('To', false)]) ...[
                if (!isFrom) const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: isFrom ? _from : _to);
                      if (t != null) setState(() => isFrom ? _from = t : _to = t);
                    },
                    child: Text('$label ${(isFrom ? _from : _to).format(context)}'),
                  ),
                ),
              ],
            ]),
            const SectionHeader('Clinic'),
            TextField(controller: _clinic, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Where you see patients (optional)', prefixIcon: Icon(Icons.local_hospital_outlined, size: 22))),
            const SectionHeader('Time away'),
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_awayUntil == null ? "You're not marked as away." : 'Away until ${formatTimestamp(_awayUntil!.toUtc().toIso8601String())}. No new requests until then.', style: AppText.body),
                const SizedBox(height: AppSpacing.xs),
                Row(children: [
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () async {
                      final d = await showDatePicker(context: context, initialDate: DateTime.now().add(const Duration(days: 1)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 180)));
                      if (d != null) setState(() => _awayUntil = DateTime(d.year, d.month, d.day, 23, 59));
                    },
                    child: Text(_awayUntil == null ? 'Set time away' : 'Change date'),
                  ),
                  if (_awayUntil != null) TextButton(style: TextButton.styleFrom(minimumSize: const Size(0, 48)), onPressed: () => setState(() => _awayUntil = null), child: const Text("I'm back")),
                ]),
              ]),
            ),
            const SizedBox(height: AppSpacing.xl),
            PrimaryButton(label: 'Save availability', loading: _saving, onPressed: _save),
          ],
        );
      },
    ),
  );
}

// =============================================================================================
// My consultations
// =============================================================================================

class MyConsultationsPage extends ConsumerStatefulWidget {
  const MyConsultationsPage({super.key});
  @override
  ConsumerState<MyConsultationsPage> createState() => _MyConsultationsPageState();
}

class _MyConsultationsPageState extends ConsumerState<MyConsultationsPage> {
  late Future<List<Map<String, dynamic>>> _future = ref.read(apiClientProvider).list('/doctor/requests', query: {'tab': 'accepted'});
  void _reload() => setState(() => _future = ref.read(apiClientProvider).list('/doctor/requests', query: {'tab': 'accepted'}));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My consultations'), titleSpacing: 0),
    body: RefreshIndicator(
      onRefresh: () async => _reload(),
      child: futureList<List<Map<String, dynamic>>>(
        future: _future,
        onRetry: _reload,
        isEmpty: (r) => r.isEmpty,
        empty: const EmptyState(title: 'No consultations yet', detail: 'Consultations you accept are listed here with their dates.', icon: Icons.assignment_turned_in_outlined),
        data: (rows) => ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
          itemBuilder: (_, i) {
            final r = rows[i];
            final p = Map<String, dynamic>.from(r['patient'] as Map);
            final ended = r['status'] == 'REVOKED';
            return SectionCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                minVerticalPadding: AppSpacing.sm,
                leading: PatientAvatar(patient: p, size: 44),
                title: Text(p['name']?.toString() ?? 'Patient', style: AppText.bodyStrong),
                subtitle: Text(
                  [
                    r['reason']?.toString() ?? '',
                    'Requested ${formatTimestamp(r['createdAt']).split(',').first}',
                    if (r['respondedAt'] != null) 'Accepted ${formatTimestamp(r['respondedAt']).split(',').first}',
                    if (r['endedAt'] != null) 'Ended ${formatTimestamp(r['endedAt']).split(',').first}',
                  ].join('\n'),
                  style: AppText.bodySm,
                ),
                isThreeLine: true,
                trailing: StatusPill(label: ended ? 'Ended' : 'Active', color: ended ? AppColors.inkSecondary : AppColors.success),
              ),
            );
          },
        ),
      ),
    ),
  );
}

// =============================================================================================
// App settings
// =============================================================================================

class DoctorSettingsPage extends ConsumerWidget {
  const DoctorSettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('App settings'), titleSpacing: 0),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
      children: [
        rowGroup([
          SettingsRow(icon: Icons.lock_outline_rounded, label: 'Change password', tint: AppColors.tintViolet, onTap: () => pushPage(context, const ChangePasswordPage())),
          SettingsRow(icon: Icons.notifications_active_outlined, label: 'Notification preferences', onTap: () => pushPage(context, const NotificationPrefsPage())),
          SettingsRow(icon: Icons.shield_outlined, label: 'Privacy and security', tint: AppColors.tintMint, onTap: () => pushPage(context, const _PrivacyPage())),
          SettingsRow(icon: Icons.tune_rounded, label: 'Permissions', subtitle: 'Camera for QR scanning, notifications', onTap: () => openAppSettings()),
          SettingsRow(icon: Icons.badge_outlined, label: 'Account information', onTap: () => pushPage(context, const _AccountInfoPage())),
        ]),
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          onPressed: () => doctorLogout(context, ref),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), shape: const StadiumBorder(), foregroundColor: AppColors.ink, side: const BorderSide(color: AppColors.borderStrong)),
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Logout'),
        ),
      ],
    ),
  );
}

class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});
  @override
  ConsumerState<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController(), _new = TextEditingController(), _confirm = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).post('/auth/change-password', body: {'currentPassword': _current.text, 'newPassword': _new.text});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password changed')));
      Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _pw(TextEditingController c, String label, String? Function(String?) v) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.md),
    child: TextFormField(controller: c, obscureText: true, decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.lock_outline_rounded, size: 22)), validator: v),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Change password'), titleSpacing: 0),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, AppSpacing.xl),
        children: [
          _pw(_current, 'Current password', (v) => (v == null || v.isEmpty) ? 'Enter your current password' : null),
          _pw(_new, 'New password', (v) => (v == null || v.length < 8) ? 'Use at least 8 characters' : null),
          _pw(_confirm, 'Confirm new password', (v) => v != _new.text ? 'Passwords do not match' : null),
          if (_error != null) Semantics(liveRegion: true, child: Text(_error!, style: AppText.bodySm.copyWith(color: AppColors.danger))),
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(label: 'Change password', loading: _saving, onPressed: _save),
        ],
      ),
    ),
  );
}

class NotificationPrefsPage extends ConsumerStatefulWidget {
  const NotificationPrefsPage({super.key});
  @override
  ConsumerState<NotificationPrefsPage> createState() => _NotificationPrefsPageState();
}

class _NotificationPrefsPageState extends ConsumerState<NotificationPrefsPage> {
  static const _types = [
    ('ConsultationRequest', 'Consultation requests'),
    ('NewMessage', 'New messages'),
    ('ReportShared', 'Shared reports'),
    ('MonitoringWarning', 'Monitoring warnings'),
    ('FollowUpDue', 'Follow-up reminders'),
  ];
  Map<String, bool>? _prefs;

  Future<void> _set(String type, bool on) async {
    setState(() => _prefs![type] = on);
    try {
      await ref.read(apiClientProvider).patch('/doctor/profile', body: {'notificationPrefs': _prefs});
      ref.invalidate(doctorProfileProvider);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _prefs![type] = !on);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notification preferences'), titleSpacing: 0),
    body: asyncBody(
      ref.watch(doctorProfileProvider),
      onRetry: () => ref.invalidate(doctorProfileProvider),
      data: (p) {
        _prefs ??= {for (final (t, _) in _types) t: (p['notificationPrefs'] as Map?)?[t] != false};
        return ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
          children: [
            Text('In-app notifications only. MediLink does not send push notifications to doctors.', style: AppText.bodySm),
            const SizedBox(height: AppSpacing.md),
            SectionCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                SwitchListTile(value: true, onChanged: null, title: Text('Emergency alerts', style: AppText.bodyStrong), subtitle: Text('Always on', style: AppText.bodySm)),
                for (final (t, label) in _types) SwitchListTile(value: _prefs![t]!, onChanged: (v) => _set(t, v), title: Text(label, style: AppText.bodyStrong)),
              ]),
            ),
          ],
        );
      },
    ),
  );
}

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();
  static const _points = [
    ('What you can see', 'A patient\'s summary, readings and emergency alerts only while they are connected with you, or for a short time after they show you their QR code.'),
    ('What you can\'t see', 'The patient\'s Vault. You only see reports they choose to send you in chat.'),
    ('Every view is logged', 'Each time you open a patient\'s data, MediLink records who, which patient, what and when. No medical details are stored in that log.'),
    ('Your notes', 'Consultation notes stay private unless you choose to share a summary with the patient.'),
    ('Your contact details', 'Patients never see your email, phone or registration number.'),
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy and security'), titleSpacing: 0),
    body: ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      itemCount: _points.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (_, i) => SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_points[i].$1, style: AppText.bodyStrong),
          const SizedBox(height: AppSpacing.xxs),
          Text(_points[i].$2, style: AppText.body),
        ]),
      ),
    ),
  );
}

class _AccountInfoPage extends ConsumerWidget {
  const _AccountInfoPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Account information'), titleSpacing: 0),
    body: asyncBody(
      ref.watch(doctorAccountProvider),
      onRetry: () => ref.invalidate(doctorAccountProvider),
      data: (a) => ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          SectionCard(
            child: Column(children: [
              for (final (label, value) in [
                ('Name', a['name']),
                ('Email', a['email']),
                ('Mobile', a['phone']),
                ('Account type', 'Doctor'),
                ('MediLink ID', a['id']),
                ('Member since', a['createdAt'] == null ? null : formatTimestamp(a['createdAt']).split(',').first),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs + 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 2, child: Text(label, style: AppText.bodySm)),
                    Expanded(flex: 3, child: SelectableText(value?.toString() ?? 'Not set', style: AppText.bodyStrong)),
                  ]),
                ),
            ]),
          ),
        ],
      ),
    ),
  );
}

// =============================================================================================
// Help and support
// =============================================================================================

class DoctorHelpPage extends StatelessWidget {
  const DoctorHelpPage({super.key});
  static const _faq = [
    ('How do patients find me?', 'Every registered doctor appears in the patient app. Keep your profile complete so patients can choose you.'),
    ('When can I see a patient\'s data?', 'After you accept their consultation request, or for a short time after they show you their QR code.'),
    ('Will I get emergency alerts when the app is closed?', 'No. Alerts appear while MediLink is open. The patient\'s SOS still calls and texts their caretakers.'),
    ('Who sees my consultation notes?', 'Only you, unless you turn on "Share summary with patient" for a note.'),
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Help & support'), titleSpacing: 0),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
      children: [
        const SectionHeader('Frequently asked'),
        SectionCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (final (q, a) in _faq)
              ExpansionTile(
                title: Text(q, style: AppText.bodyStrong),
                childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                children: [Text(a, style: AppText.body)],
              ),
          ]),
        ),
        const SizedBox(height: AppSpacing.md),
        rowGroup([
          SettingsRow(
            icon: Icons.support_agent_outlined,
            label: 'Contact support',
            tint: AppColors.tintMint,
            onTap: () => FallbackScreen.open(context, FallbackKind.comingSoon, appBarTitle: 'Contact support', message: "Support contact details aren't set up yet. Use Report a problem and we'll see it."),
          ),
          SettingsRow(icon: Icons.bug_report_outlined, label: 'Report a problem', tint: AppColors.tintAmber, onTap: () => pushPage(context, const ReportProblemPage())),
          SettingsRow(icon: Icons.info_outline_rounded, label: 'About MediLink', onTap: () => pushPage(context, const AboutPage())),
          SettingsRow(icon: Icons.privacy_tip_outlined, label: 'Privacy policy', onTap: () => FallbackScreen.open(context, FallbackKind.comingSoon, appBarTitle: 'Privacy policy')),
          SettingsRow(icon: Icons.gavel_outlined, label: 'Terms of use', onTap: () => FallbackScreen.open(context, FallbackKind.comingSoon, appBarTitle: 'Terms of use')),
        ]),
      ],
    ),
  );
}

class ReportProblemPage extends ConsumerStatefulWidget {
  const ReportProblemPage({super.key});
  @override
  ConsumerState<ReportProblemPage> createState() => _ReportProblemPageState();
}

class _ReportProblemPageState extends ConsumerState<ReportProblemPage> {
  final _text = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_text.text.trim().length < 5) {
      setState(() => _error = 'Tell us a little more about what happened');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).post('/support/reports', body: {'message': _text.text.trim()});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thanks. Your report was sent.')));
      Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Report a problem'), titleSpacing: 0),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, AppSpacing.xl),
      children: [
        Text("Describe what went wrong and what you expected. Please don't include patient details.", style: AppText.body),
        const SizedBox(height: AppSpacing.md),
        TextField(controller: _text, minLines: 4, maxLines: 8, maxLength: 2000, decoration: InputDecoration(labelText: 'What happened?', alignLabelWithHint: true, errorText: _error)),
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(label: 'Send report', loading: _sending, onPressed: _send),
      ],
    ),
  );
}
