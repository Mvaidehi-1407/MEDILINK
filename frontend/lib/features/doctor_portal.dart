import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/app_icons.dart';
import '../ui/components.dart';
import '../ui/fallback.dart';
import '../ui/format.dart';
import '../widgets/common.dart';
import 'doctor_account.dart';
import 'doctor_care.dart';
import 'doctor_chat.dart';
import 'doctor_scan.dart';
import 'profile_pages.dart' show avatarImage;

// =============================================================================================
// Shared bits (also used by Create Account, doctor_chat.dart and doctor_scan.dart)
// =============================================================================================

const kSpecializations = [
  'General Physician', 'Cardiologist', 'Pulmonologist', 'Neurologist', 'Endocrinologist', 'Pediatrician',
  'Geriatrician', 'Orthopedic', 'Dermatologist', 'Psychiatrist', 'Gynecologist', 'Other',
];

/// Short, readable Patient ID shown on cards (last 6 characters of the account id).
String pidOf(Object? id) {
  final s = id?.toString() ?? '';
  return s.length <= 6 ? 'PID $s' : 'PID ${s.substring(s.length - 6).toUpperCase()}';
}

/// "Just now" / "5 min ago" / "3 h ago", else the shared local-time format.
String relativeTime(Object? ts) {
  final t = parseBackendTime(ts);
  if (t == null) return '';
  final d = DateTime.now().difference(t.toLocal());
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return formatTimestamp(ts);
}

Future<T?> pushPage<T>(BuildContext context, Widget page) {
  HapticFeedback.selectionClick();
  return Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));
}

class PatientAvatar extends StatelessWidget {
  const PatientAvatar({super.key, required this.patient, this.size = 48, this.online});
  final Map<String, dynamic>? patient;
  final double size;
  final bool? online;
  @override
  Widget build(BuildContext context) {
    final name = patient?['name']?.toString() ?? '';
    final image = avatarImage(patient?['avatarDataUrl']?.toString());
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            CircleAvatar(
              radius: size / 2,
              backgroundColor: AppColors.primaryTint,
              backgroundImage: image,
              child: image != null
                  ? null
                  : Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                      style: AppText.titleSm.copyWith(color: AppColors.primaryPressed, fontSize: size * .38)),
            ),
            if (online != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: size * .26,
                  height: size * .26,
                  decoration: BoxDecoration(
                    color: online! ? AppColors.success : AppColors.inkMuted,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Loading (shimmer) / error / data for an [AsyncValue], in the shared fallback style.
Widget asyncBody<T>(AsyncValue<T> value, {required VoidCallback onRetry, required Widget Function(T) data}) => value.when(
  skipLoadingOnRefresh: true,
  loading: () => const Padding(padding: EdgeInsets.all(AppSpacing.gutter), child: SkeletonList(rows: 4)),
  error: (e, _) => ErrorState(message: e.toString(), onRetry: onRetry),
  data: data,
);

/// Section heading with an optional "See all".
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.onSeeAll});
  final String title;
  final VoidCallback? onSeeAll;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.xs),
    child: Row(
      children: [
        Expanded(child: Semantics(header: true, child: Text(title, style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)))),
        if (onSeeAll != null)
          TextButton(onPressed: onSeeAll, child: const Text('See all')),
      ],
    ),
  );
}

// ---- Registration / Edit profile fields -------------------------------------------------------

class DoctorFieldsController {
  DoctorFieldsController([Map<String, dynamic>? initial]) {
    final s = initial?['specialization']?.toString();
    specialization.value = kSpecializations.contains(s) ? s : null;
    other.text = initial?['specializationOther']?.toString() ?? '';
    qualification.text = initial?['qualification']?.toString() ?? '';
    experience.text = initial?['experienceYears']?.toString() ?? '';
    hospital.text = initial?['hospitalName']?.toString() ?? '';
    registration.text = initial?['registrationNumber']?.toString() ?? '';
    languages.text = (initial?['languages'] as List?)?.join(', ') ?? '';
  }
  final specialization = ValueNotifier<String?>(null);
  final other = TextEditingController();
  final qualification = TextEditingController();
  final experience = TextEditingController();
  final hospital = TextEditingController();
  final registration = TextEditingController();
  final languages = TextEditingController();

  Map<String, dynamic> toJson() {
    final langs = languages.text.split(',').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return {
      'specialization': specialization.value,
      if (specialization.value == 'Other') 'specializationOther': other.text.trim(),
      'qualification': qualification.text.trim(),
      'experienceYears': int.tryParse(experience.text.trim()),
      'hospitalName': hospital.text.trim(),
      if (registration.text.trim().isNotEmpty) 'registrationNumber': registration.text.trim(),
      if (langs.isNotEmpty) 'languages': langs,
    };
  }

  void dispose() {
    specialization.dispose();
    for (final c in [other, qualification, experience, hospital, registration, languages]) {
      c.dispose();
    }
  }
}

/// Doctor-only fields in the same input style as the rest of Create Account. Must sit in a Form.
class DoctorProfileFields extends StatelessWidget {
  const DoctorProfileFields({super.key, required this.controller});
  final DoctorFieldsController controller;

  String? _required(String? v, String label) => (v == null || v.trim().isEmpty) ? '$label is required' : null;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: controller.specialization,
    builder: (context, spec, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: spec,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Specialization', prefixIcon: Icon(Icons.medical_services_outlined, size: 22)),
          borderRadius: AppRadius.inputAll,
          dropdownColor: AppColors.surface,
          style: AppText.body.copyWith(color: AppColors.ink),
          icon: const Icon(Icons.expand_more_rounded),
          items: [for (final s in kSpecializations) DropdownMenuItem(value: s, child: Text(s))],
          onChanged: (v) => controller.specialization.value = v,
          validator: (v) => v == null ? 'Specialization is required' : null,
        ),
        if (spec == 'Other') ...[
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: controller.other,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Your specialization', prefixIcon: Icon(Icons.edit_outlined, size: 22)),
            validator: (v) => _required(v, 'Specialization'),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: controller.qualification,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Qualification', hintText: 'e.g. MBBS, MD', prefixIcon: Icon(Icons.school_outlined, size: 22)),
          validator: (v) => _required(v, 'Qualification'),
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: controller.experience,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
          decoration: const InputDecoration(labelText: 'Years of experience', prefixIcon: Icon(Icons.workspace_premium_outlined, size: 22)),
          validator: (v) => _required(v, 'Years of experience'),
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: controller.hospital,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Hospital / Clinic name', prefixIcon: Icon(Icons.local_hospital_outlined, size: 22)),
          validator: (v) => _required(v, 'Hospital / Clinic name'),
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: controller.registration,
          decoration: const InputDecoration(
            labelText: 'Registration number (optional)',
            helperText: 'Never shown to patients.',
            prefixIcon: Icon(Icons.badge_outlined, size: 22),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: controller.languages,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Consultation languages (optional)',
            hintText: 'e.g. English, Hindi, Telugu',
            prefixIcon: Icon(Icons.translate_rounded, size: 22),
          ),
        ),
      ],
    ),
  );
}

// =============================================================================================
// Data
// =============================================================================================

final doctorHomeProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) async => Map<String, dynamic>.from(await ref.read(apiClientProvider).get('/doctor/home') as Map),
);

final doctorProfileProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) async => Map<String, dynamic>.from(await ref.read(apiClientProvider).get('/doctor/profile') as Map),
);

// =============================================================================================
// Shell
// =============================================================================================

class DoctorShell extends ConsumerStatefulWidget {
  const DoctorShell({super.key});
  @override
  ConsumerState<DoctorShell> createState() => _DoctorShellState();
}

class _DoctorShellState extends ConsumerState<DoctorShell> with WidgetsBindingObserver {
  int _index = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Stored records only (new requests, messages, alerts). 30 s keeps alerts fresh without push.
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => ref.invalidate(doctorHomeProvider));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(doctorHomeProvider);
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final views = [
      DoctorHomeTab(onTab: _go),
      const DoctorRequestsTab(),
      const DoctorChatsTab(),
      const DoctorPatientsTab(),
      const DoctorProfileTab(),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const OfflineBanner(),
            const CriticalAlertBanner(),
            Expanded(child: IndexedStack(index: _index, children: views)),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.0,
          child: MedilinkNavBar(
            selectedIndex: _index,
            onDestinationSelected: _go,
            items: const [
              NavItem('Home', asset: AppIcons.navHome),
              NavItem('Requests', icon: Icons.assignment_ind_outlined),
              NavItem('Chats', icon: Icons.chat_bubble_outline_rounded),
              NavItem('Patients', icon: Icons.groups_outlined),
              NavItem('Profile', asset: AppIcons.navProfile),
            ],
          ),
        ),
      ),
    );
  }
}

/// Active emergency alerts stay visible on every tab.
class CriticalAlertBanner extends ConsumerWidget {
  const CriticalAlertBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = (ref.watch(doctorHomeProvider).value?['alerts'] as List?) ?? const [];
    if (alerts.isEmpty) return const SizedBox.shrink();
    final first = Map<String, dynamic>.from(alerts.first as Map);
    final name = (first['patient'] as Map?)?['name'] ?? 'A patient';
    final more = alerts.length > 1 ? ' and ${alerts.length - 1} more' : '';
    return Semantics(
      liveRegion: true,
      child: Material(
        color: AppColors.danger,
        child: InkWell(
          onTap: () => pushPage(context, const DoctorAlertsPage()),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: AppSpacing.xs),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.onDark, size: 22),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text('Emergency: $name$more',
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong.copyWith(color: AppColors.onDark)),
                  ),
                  Text('View', style: AppText.label.copyWith(color: AppColors.onDark)),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.onDark),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================================
// Home
// =============================================================================================

class DoctorHomeTab extends ConsumerWidget {
  const DoctorHomeTab({super.key, required this.onTab});
  final ValueChanged<int> onTab;

  static String greeting(DateTime now) => now.hour < 12 ? 'Good morning' : now.hour < 17 ? 'Good afternoon' : 'Good evening';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(doctorHomeProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(doctorHomeProvider.future),
      child: asyncBody(
        home,
        onRetry: () => ref.invalidate(doctorHomeProvider),
        data: (h) => _HomeBody(home: h, onTab: onTab),
      ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({required this.home, required this.onTab});
  final Map<String, dynamic> home;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = Map<String, dynamic>.from(home['profile'] as Map? ?? {});
    final counts = Map<String, dynamic>.from(home['counts'] as Map? ?? {});
    final name = profile['name']?.toString() ?? ref.watch(sessionProvider).user?['name']?.toString() ?? '';
    final shownName = name.toLowerCase().startsWith('dr') ? name : 'Dr. $name';
    final requests = (home['recentRequests'] as List? ?? []).cast<Map>();
    final messages = (home['recentMessages'] as List? ?? []).cast<Map>();
    final alerts = (home['alerts'] as List? ?? []).cast<Map>();
    final unread = (home['unreadNotifications'] as num? ?? 0) > 0;
    int c(String k) => (counts[k] as num?)?.toInt() ?? 0;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.lg, AppSpacing.gutter, AppSpacing.xl),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("${DoctorHomeTab.greeting(DateTime.now())},", style: AppText.headline),
                  Text(shownName, style: AppText.headline, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: AppSpacing.xxs),
                  Text('Your patients, your priority.', style: AppText.body),
                ],
              ),
            ),
            _Bell(unread: unread, onTap: () async {
              final tab = await pushPage<int>(context, const DoctorNotificationsPage());
              if (tab != null) onTab(tab);
              ref.invalidate(doctorHomeProvider);
            }),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _DoctorCard(profile: profile, name: shownName),
        if (profile['profileComplete'] != true) ...[
          const SizedBox(height: AppSpacing.sm),
          _CompleteProfileCard(onTap: () async {
            await pushPage(context, const DoctorEditProfilePage());
            ref.invalidate(doctorHomeProvider);
          }),
        ],
        const SizedBox(height: AppSpacing.lg),
        TileGrid(children: [
          _CountCard(label: 'Consultation requests', count: c('requests'), icon: Icons.assignment_ind_outlined, tint: AppColors.tintBlue, onTap: () => onTab(1)),
          _CountCard(label: 'Active chats', count: c('activeChats'), icon: Icons.chat_bubble_outline_rounded, tint: AppColors.tintMint, onTap: () => onTab(2)),
          _CountCard(label: 'My patients', count: c('patients'), icon: Icons.groups_outlined, tint: AppColors.tintViolet, onTap: () => onTab(3)),
          _CountCard(label: 'Emergency alerts', count: c('alerts'), icon: Icons.warning_amber_rounded, tint: AppColors.tintRed, onTap: () => pushPage(context, const DoctorAlertsPage())),
          _CountCard(label: 'Patient monitoring', count: c('monitoring'), icon: Icons.monitor_heart_outlined, tint: AppColors.tintMint, onTap: () => pushPage(context, const DoctorMonitoringPage())),
          _CountCard(label: 'Follow-ups', count: c('followUps'), icon: Icons.event_available_outlined, tint: AppColors.tintAmber, onTap: () => pushPage(context, const DoctorFollowUpsPage())),
        ]),
        const SectionHeader('Quick actions'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _QuickAction(icon: Icons.qr_code_scanner_rounded, label: 'Scan patient QR', tint: AppColors.tintMint, onTap: () => pushPage(context, const DoctorScannerPage())),
            _QuickAction(icon: Icons.chat_bubble_outline_rounded, label: 'Open chats', tint: AppColors.tintBlue, onTap: () => onTab(2)),
            _QuickAction(icon: Icons.monitor_heart_outlined, label: 'Monitor patients', tint: AppColors.tintViolet, onTap: () => pushPage(context, const DoctorMonitoringPage())),
            _QuickAction(icon: Icons.warning_amber_rounded, label: 'View alerts', tint: AppColors.tintRed, onTap: () => pushPage(context, const DoctorAlertsPage())),
          ],
        ),
        if (alerts.isNotEmpty) ...[
          SectionHeader('Emergency alerts', onSeeAll: () => pushPage(context, const DoctorAlertsPage())),
          for (final a in alerts.take(3)) Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: AlertCard(alert: Map<String, dynamic>.from(a))),
        ],
        SectionHeader('Recent requests', onSeeAll: () => onTab(1)),
        if (requests.isEmpty)
          const _InlineEmpty('No pending requests. New consultation requests from patients appear here.')
        else
          for (final r in requests)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _MiniRow(
                patient: Map<String, dynamic>.from(r['patient'] as Map),
                line: r['reason']?.toString() ?? '',
                time: relativeTime(r['createdAt']),
                onTap: () => onTab(1),
              ),
            ),
        SectionHeader('Recent messages', onSeeAll: () => onTab(2)),
        if (messages.isEmpty)
          const _InlineEmpty('No messages yet. Messages from connected patients appear here.')
        else
          for (final m in messages)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _MiniRow(
                patient: Map<String, dynamic>.from(m['patient'] as Map? ?? {}),
                line: m['message']?.toString() ?? '',
                time: relativeTime(m['timestamp']),
                unread: m['readStatus'] != 'READ',
                onTap: () {
                  final p = Map<String, dynamic>.from(m['patient'] as Map? ?? {});
                  pushPage(context, DoctorChatPage(conversationId: m['conversationId'].toString(), patient: p));
                },
              ),
            ),
      ],
    );
  }
}

class _Bell extends StatelessWidget {
  const _Bell({required this.unread, required this.onTap});
  final bool unread;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: unread ? 'Notifications, unread' : 'Notifications',
    child: Material(
      color: AppColors.surface,
      shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.notifications_none_rounded, color: AppColors.ink),
              if (unread)
                Positioned(
                  top: 12,
                  right: 13,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: AppColors.danger, shape: BoxShape.circle, border: Border.all(color: AppColors.surface, width: 1.5)),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

String availabilityLabel(Object? a) => a == 'UNAVAILABLE' ? 'Not taking requests' : 'Available';

class _DoctorCard extends ConsumerWidget {
  const _DoctorCard({required this.profile, required this.name});
  final Map<String, dynamic> profile;
  final String name;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = profile['specialization'] == 'Other' ? profile['specializationOther'] : profile['specialization'];
    final available = profile['availability'] != 'UNAVAILABLE';
    return SectionCard(
      child: Row(
        children: [
          PatientAvatar(patient: {'name': name.replaceFirst('Dr. ', ''), 'avatarDataUrl': profile['avatarDataUrl']}, size: 56),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppText.titleSm, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(spec?.toString() ?? 'Specialization not set', style: AppText.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(profile['hospitalName']?.toString() ?? 'Hospital / clinic not set', style: AppText.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.xxs),
                StatusPill(label: availabilityLabel(profile['availability']), color: available ? AppColors.success : AppColors.warning),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompleteProfileCard extends StatelessWidget {
  const _CompleteProfileCard({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.warningTint,
    borderRadius: AppRadius.cardAll,
    child: InkWell(
      borderRadius: AppRadius.cardAll,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            const IconBadge(icon: Icons.person_outline_rounded, tint: AppColors.tintAmber, size: 44),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Complete your profile', style: AppText.bodyStrong),
                  Text('Add your specialization, qualification, experience and hospital so patients can find you.', style: AppText.bodySm),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.inkSecondary),
          ],
        ),
      ),
    ),
  );
}

class _CountCard extends StatelessWidget {
  const _CountCard({required this.label, required this.count, required this.icon, required this.tint, required this.onTap});
  final String label;
  final int count;
  final IconData icon;
  final (Color, Color) tint;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$label: $count',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: const BoxDecoration(borderRadius: AppRadius.cardAll, boxShadow: AppElevation.card),
      child: Material(
        color: AppColors.surface,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.cardAll, side: BorderSide(color: AppColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconBadge(icon: icon, tint: tint, size: 44),
                const SizedBox(height: AppSpacing.sm),
                Text('$count', style: AppText.headline.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                Text(label, style: AppText.bodySm.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.tint, required this.onTap});
  final IconData icon;
  final String label;
  final (Color, Color) tint;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: AppRadius.cardAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            children: [
              IconBadge(icon: icon, tint: tint, size: 52),
              const SizedBox(height: AppSpacing.xs),
              Text(label, textAlign: TextAlign.center, maxLines: 2, style: AppText.caption.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MiniRow extends StatelessWidget {
  const _MiniRow({required this.patient, required this.line, required this.time, required this.onTap, this.unread = false});
  final Map<String, dynamic> patient;
  final String line;
  final String time;
  final bool unread;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => SectionCard(
    padding: EdgeInsets.zero,
    child: ListTile(
      onTap: onTap,
      minVerticalPadding: AppSpacing.sm,
      leading: PatientAvatar(patient: patient, size: 44),
      title: Text(patient['name']?.toString() ?? 'Patient', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodySm.copyWith(fontWeight: unread ? FontWeight.w700 : null)),
      trailing: Text(time, style: AppText.caption),
    ),
  );
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => SectionCard(child: Text(text, style: AppText.bodySm));
}

// =============================================================================================
// Requests
// =============================================================================================

class DoctorRequestsTab extends ConsumerStatefulWidget {
  const DoctorRequestsTab({super.key});
  @override
  ConsumerState<DoctorRequestsTab> createState() => _DoctorRequestsTabState();
}

class _DoctorRequestsTabState extends ConsumerState<DoctorRequestsTab> {
  String _tab = 'pending';
  late Future<List<Map<String, dynamic>>> _future = _load();
  final _busy = <String>{};

  Future<List<Map<String, dynamic>>> _load() async {
    final api = ref.read(apiClientProvider);
    final rows = await api.list('/doctor/requests', query: {'tab': _tab});
    // Declined tab also lists requests that expired after 7 days without an answer.
    if (_tab == 'declined') rows.addAll(await api.list('/doctor/requests', query: {'tab': 'expired'}));
    return rows;
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _respond(Map<String, dynamic> r, bool accept) async {
    final name = (r['patient'] as Map?)?['name'] ?? 'this patient';
    if (!accept) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Decline request from $name?'),
          content: const Text("They'll be told you can't take the request. They can send a new one after 24 hours."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep request')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Decline'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy.add(r['id'].toString()));
    try {
      final res = await ref.read(apiClientProvider).post('/doctor/requests/${r['id']}/${accept ? 'accept' : 'decline'}');
      ref.invalidate(doctorHomeProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(accept ? 'Request accepted. $name is now in your chats.' : 'Request declined.')));
      _reload();
      if (accept && res is Map && res['conversationId'] != null) {
        pushPage(context, DoctorChatPage(conversationId: res['conversationId'].toString(), patient: Map<String, dynamic>.from(r['patient'] as Map)));
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(r['id'].toString()));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Consultation requests'), titleSpacing: AppSpacing.gutter),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.sm),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'pending', label: Text('Pending')),
                ButtonSegment(value: 'accepted', label: Text('Accepted')),
                ButtonSegment(value: 'declined', label: Text('Declined')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) {
                _tab = s.first;
                _reload();
              },
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(padding: EdgeInsets.all(AppSpacing.gutter), child: SkeletonList(rows: 3));
                }
                if (snap.hasError) return ErrorState(message: snap.error.toString(), onRetry: _reload);
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return ListView(children: [
                    const SizedBox(height: AppSpacing.xxxl),
                    EmptyState(
                      title: switch (_tab) { 'pending' => 'No pending requests', 'accepted' => 'No accepted requests yet', _ => 'No declined requests' },
                      detail: _tab == 'pending' ? 'When a patient asks for a consultation, it appears here.' : 'Requests you answer are kept here.',
                      icon: Icons.assignment_ind_outlined,
                    ),
                  ]);
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.xl),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) => RequestCard(
                    request: rows[i],
                    busy: _busy.contains(rows[i]['id'].toString()),
                    onAccept: () => _respond(rows[i], true),
                    onDecline: () => _respond(rows[i], false),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class RequestCard extends StatelessWidget {
  const RequestCard({super.key, required this.request, required this.onAccept, required this.onDecline, this.busy = false});
  final Map<String, dynamic> request;
  final VoidCallback onAccept, onDecline;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = Map<String, dynamic>.from(request['patient'] as Map? ?? {});
    final status = request['status']?.toString() ?? '';
    final pending = status == 'REQUESTED';
    final meta = [pidOf(p['id']), if (p['age'] != null) 'Age ${p['age']}', relativeTime(request['createdAt'])].join(' · ');
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PatientAvatar(patient: p, size: 52),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p['name']?.toString() ?? 'Patient', style: AppText.titleSm, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(meta, style: AppText.caption),
                  ],
                ),
              ),
              if (!pending)
                StatusPill(
                  label: switch (status) { 'GRANTED' => 'Accepted', 'REVOKED' => 'Ended', 'REJECTED' => 'Declined', 'EXPIRED' => 'Expired', _ => humanizeEnum(status) },
                  color: status == 'GRANTED' ? AppColors.success : AppColors.inkSecondary,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(request['reason']?.toString() ?? '', style: AppText.bodyStrong),
          if ((request['firstMessage'] ?? '').toString().isNotEmpty)
            Text('"${request['firstMessage']}"', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodySm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(0, 48), padding: EdgeInsets.zero),
              onPressed: () => _details(context),
              child: const Text('View details'),
            ),
          ),
          if (pending)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      shape: const StadiumBorder(),
                      foregroundColor: AppColors.danger,
                      side: BorderSide(color: AppColors.danger.withValues(alpha: .5)),
                    ),
                    onPressed: busy ? null : onDecline,
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                    onPressed: busy ? null : onAccept,
                    child: busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Accept'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  void _details(BuildContext context) {
    final p = Map<String, dynamic>.from(request['patient'] as Map? ?? {});
    final pending = request['status'] == 'REQUESTED';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                PatientAvatar(patient: p, size: 56),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p['name']?.toString() ?? 'Patient', style: AppText.title),
                    Text(pidOf(p['id']), style: AppText.bodySm),
                  ]),
                ),
              ]),
              const SizedBox(height: AppSpacing.lg),
              Text('Reason', style: AppText.caption),
              Text(request['reason']?.toString() ?? '', style: AppText.bodyStrong),
              if ((request['firstMessage'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text('Message', style: AppText.caption),
                Text(request['firstMessage'].toString(), style: AppText.body),
              ],
              const SizedBox(height: AppSpacing.md),
              Text('Sent ${formatTimestamp(request['createdAt'])}', style: AppText.bodySm),
              if (pending) ...[
                const SizedBox(height: AppSpacing.xl),
                PrimaryButton(label: 'Accept', icon: Icons.check_rounded, onPressed: () {
                  Navigator.pop(c);
                  onAccept();
                }),
                const SizedBox(height: AppSpacing.xs),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.danger, minimumSize: const Size.fromHeight(48)),
                  onPressed: () {
                    Navigator.pop(c);
                    onDecline();
                  },
                  child: const Text('Decline'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================================
// Patients, Monitoring, Alerts, Follow-ups
// =============================================================================================

class DoctorPatientsTab extends ConsumerStatefulWidget {
  const DoctorPatientsTab({super.key, this.title = 'My patients', this.onPick});
  final String title;

  /// When set, tapping a patient returns it instead of opening the summary.
  final ValueChanged<Map<String, dynamic>>? onPick;
  @override
  ConsumerState<DoctorPatientsTab> createState() => _DoctorPatientsTabState();
}

class _DoctorPatientsTabState extends ConsumerState<DoctorPatientsTab> {
  final _search = TextEditingController();
  String _filter = 'ALL';
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() => ref.read(apiClientProvider).list('/doctor/patients');

  bool _inFilter(Map<String, dynamic> p) => switch (_filter) {
    // Active = messaged in the last 7 days.
    'ACTIVE' => (parseBackendTime(p['lastMessageAt'])?.isAfter(DateTime.now().subtract(const Duration(days: 7))) ?? false),
    'MONITORING' => p['monitoring'] != null && p['monitoring'] != 'NO_RECENT_DATA',
    'ALERTS' => p['emergency'] == true,
    _ => true,
  };
  void _reload() => setState(() => _future = _load());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      titleSpacing: (ModalRoute.of(context)?.impliesAppBarDismissal ?? false) ? 0 : AppSpacing.gutter,
      actions: [
        if (widget.onPick == null)
          IconButton(tooltip: 'Scan patient QR', onPressed: () => pushPage(context, const DoctorScannerPage()), icon: const Icon(Icons.qr_code_scanner_rounded)),
        const SizedBox(width: AppSpacing.xs),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.sm),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Search by name or Patient ID', prefixIcon: Icon(Icons.search_rounded)),
          ),
        ),
        if (widget.onPick == null)
          ChipFilter(
            value: _filter,
            onChanged: (v) => setState(() => _filter = v),
            options: const [('ALL', 'All'), ('ACTIVE', 'Active'), ('MONITORING', 'Monitoring'), ('ALERTS', 'Alerts')],
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(padding: EdgeInsets.all(AppSpacing.gutter), child: SkeletonList(rows: 4));
                }
                if (snap.hasError) return ErrorState(message: snap.error.toString(), onRetry: _reload);
                final q = _search.text.trim().toLowerCase();
                final rows = snap.data!
                    .where((p) => q.isEmpty || p['name'].toString().toLowerCase().contains(q) || pidOf(p['id']).toLowerCase().contains(q) || p['id'].toString().contains(q))
                    .where((p) => widget.onPick != null || _inFilter(p))
                    .toList();
                if (rows.isEmpty) {
                  return ListView(children: [
                    const SizedBox(height: AppSpacing.xxxl),
                    EmptyState(
                      title: snap.data!.isEmpty ? 'No patients yet' : 'No matches',
                      detail: snap.data!.isEmpty ? 'Patients appear here after you accept their consultation request.' : 'Try another name or Patient ID.',
                      icon: Icons.groups_outlined,
                    ),
                  ]);
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.xl),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) {
                    final p = rows[i];
                    final last = p['lastReadingAt'];
                    if (widget.onPick == null) return _PatientCard(patient: p, onChanged: _reload);
                    return SectionCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        minVerticalPadding: AppSpacing.sm,
                        onTap: () => widget.onPick != null ? widget.onPick!(p) : pushPage(context, PatientSummaryPage(patientId: p['id'].toString())),
                        leading: PatientAvatar(patient: p, size: 48),
                        title: Text(p['name']?.toString() ?? 'Patient', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [pidOf(p['id']), if (p['age'] != null) 'Age ${p['age']}', last == null ? 'No readings yet' : 'Last reading ${relativeTime(last)}'].join(' · '),
                          style: AppText.bodySm,
                        ),
                        trailing: p['emergency'] == true
                            ? const StatusPill(label: 'Emergency', color: AppColors.danger)
                            : const Icon(Icons.chevron_right_rounded, color: AppColors.inkSecondary),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({required this.patient, required this.onChanged});
  final Map<String, dynamic> patient;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    final p = patient;
    final (label, color) = riskStyle(p['monitoring']);
    String when(Object? ts) => ts == null ? 'None yet' : relativeTime(ts);
    Future<void> open() async {
      await pushPage(context, PatientSummaryPage(patientId: p['id'].toString()));
      onChanged();
    }

    return SectionCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: AppRadius.cardAll,
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              PatientAvatar(patient: p, size: 52),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p['name']?.toString() ?? 'Patient', style: AppText.titleSm, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text([pidOf(p['id']), if (p['age'] != null) 'Age ${p['age']}'].join(' · '), style: AppText.caption),
                  const SizedBox(height: AppSpacing.xxs),
                  p['emergency'] == true ? const StatusPill(label: 'Emergency', color: AppColors.danger) : StatusPill(label: label, color: color),
                ]),
              ),
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text('Last consultation: ${when(p['lastConsultationAt'])}', style: AppText.bodySm),
            Text('Last vitals: ${when(p['lastReadingAt'])}', style: AppText.bodySm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(style: TextButton.styleFrom(minimumSize: const Size(0, 48)), onPressed: open, child: const Text('View profile')),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Kept for screens that need the not-found fallback for a missing patient.
Widget patientUnavailable(BuildContext context, String message) => FallbackView(
  kind: FallbackKind.permission,
  title: 'No access',
  message: message,
  actionLabel: 'Go back',
  onAction: () => Navigator.of(context).maybePop(),
);
