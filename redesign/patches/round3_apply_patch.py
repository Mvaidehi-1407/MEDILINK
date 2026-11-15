"""Applies the Round 3 edits (Home, Emergency UI, QR, Profile, nav, fallbacks, setState fixes).
Every replacement asserts it matched exactly once. Files keep CRLF line endings."""
import pathlib, re, sys

FE = pathlib.Path(sys.argv[1])  # .../frontend
log = []


def load(rel):
    return (FE / rel).read_bytes().decode('utf-8')


def save(rel, s):
    (FE / rel).write_bytes(s.encode('utf-8'))


def crlf(t):
    return t.replace('\r\n', '\n').replace('\n', '\r\n')


def rep(s, old, new, rel, count=1):
    o, n = crlf(old), crlf(new)
    c = s.count(o)
    if c != count:
        raise SystemExit(f'[{rel}] expected {count} match(es), found {c}: {old[:90]!r}')
    log.append(f'{rel}: replaced {old.strip().splitlines()[0][:70]!r}')
    return s.replace(o, n)


def rep_between(s, start, end, new, rel, keep_end=True):
    a = s.index(crlf(start))
    b = s.index(crlf(end), a + len(crlf(start)))
    log.append(f'{rel}: rewrote block {start.strip().splitlines()[0][:60]!r}')
    return s[:a] + crlf(new) + (s[b:] if keep_end else s[b + len(crlf(end)):])


# ---------------------------------------------------------------- tokens.dart
r = 'lib/theme/tokens.dart'
s = load(r)
s = rep(s, '  static const expressive = Duration(milliseconds: 650);',
        '  static const medium = Duration(milliseconds: 250);\n'
        '  // Capped at 400 ms: every transition in the app runs 150-400 ms.\n'
        '  static const expressive = Duration(milliseconds: 400);', r)
save(r, s)

# ---------------------------------------------------------------- components.dart
r = 'lib/ui/components.dart'
s = load(r)
s = rep(s, "import 'package:flutter/material.dart';\n", "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\n", r)
s = rep(s, '''    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.tint = AppColors.tintBlue,
  });
  final IconData icon;''', '''    this.icon,
    this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.tint = AppColors.tintBlue,
  }) : assert(icon != null || leading != null);
  final IconData? icon;

  /// Replaces the icon badge, e.g. a reference [AssetBadge].
  final Widget? leading;''', r)
s = rep(s, '''      child: InkWell(
        onTap: onTap,''', '''      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },''', r)
s = rep(s, '              IconBadge(icon: icon, tint: tint, size: 52),',
        '              leading ?? IconBadge(icon: icon!, tint: tint, size: 52),', r)
s = rep(s, '              Text(title, style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)),',
        '              Text(title, style: AppText.title.copyWith(fontSize: 19)),', r)
s = rep(s, '          minimumSize: const Size.fromHeight(56),\n',
        '          minimumSize: const Size.fromHeight(56),\n          shape: const StadiumBorder(),\n', r)
save(r, s)

# ---------------------------------------------------------------- common.dart
r = 'lib/widgets/common.dart'
s = load(r)
s = rep(s, "import '../ui/components.dart';\n",
        "import '../ui/app_icons.dart';\nimport '../ui/components.dart';\nimport '../ui/fallback.dart';\n", r)
s = rep_between(s, 'class LoadingState extends StatelessWidget {', 'class EmptyState extends StatelessWidget {', '''class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label = 'Loading your care data...'});
  final String label;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SkeletonList(),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            liveRegion: true,
            child: Text(label, textAlign: TextAlign.center, style: AppText.body),
          ),
        ],
      ),
    ),
  );
}

/// Error body for lists and pages. Uses the app-wide [FallbackView]; raw exception text is never
/// shown, while server messages written for people are kept.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final kind = fallbackKindFor(message);
    return FallbackView(
      kind: kind,
      message: kind == FallbackKind.offline || looksRaw(message) ? null : message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

''', r)
save(r, s)

# ---------------------------------------------------------------- main.dart
r = 'lib/main.dart'
s = load(r)
s = rep(s, "import 'core/crash_reporting.dart';\n", "import 'core/crash_reporting.dart';\nimport 'ui/fallback.dart';\n", r)
s = rep(s, '      await CrashReporting.initialize();\n',
        '      await CrashReporting.initialize();\n'
        '      // Friendly fallback instead of the red/grey crash box anywhere in the tree.\n'
        '      ErrorWidget.builder = fallbackErrorWidget;\n', r)
save(r, s)

# ---------------------------------------------------------------- app.dart
r = 'lib/app.dart'
s = load(r)
s = rep(s, "import 'ui/components.dart';\n", "import 'ui/components.dart';\nimport 'ui/fallback.dart';\n", r)
s = rep(s, "final appRouter = GoRouter(\n  initialLocation: '/',\n",
        "final appRouter = GoRouter(\n  initialLocation: '/',\n"
        "  // Unknown location: themed \"page not found\" instead of go_router's default error page.\n"
        "  errorBuilder: (context, state) => FallbackScreen(\n"
        "    kind: FallbackKind.notFound,\n"
        "    appBarTitle: 'MediLink',\n"
        "    actionLabel: 'Go home',\n"
        "    onAction: () => context.go('/'),\n"
        "  ),\n", r)
save(r, s)

# ---------------------------------------------------------------- auth_flow.dart (server address link)
r = 'lib/features/auth_flow.dart'
s = load(r)
s = rep(s, "import '../widgets/common.dart';\n", "import '../widgets/common.dart';\nimport 'profile_pages.dart' show ServerSettingsPage;\n", r)
s = rep(s, '''                        ? 'Need an account? Sign up'
                        : 'Already have an account? Sign in',
                  ),
                ),
              ),
''', '''                        ? 'Need an account? Sign up'
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
''', r)
save(r, s)

# ---------------------------------------------------------------- setState(() => _future = ...) fixes
pat = re.compile(r'setState\(\(\) => (_(?:future|reports) = .+?)\);')
for r in ['lib/features/contacts.dart', 'lib/features/emergency_map.dart', 'lib/features/medical_vault.dart',
          'lib/features/patients.dart', 'lib/features/dashboard.dart']:
    s = load(r)
    s, n = pat.subn(lambda m: 'setState(() {\n      ' .replace('\n', '\r\n') + m.group(1) + ';\r\n    });', s)
    log.append(f'{r}: fixed {n} setState-returns-Future call(s)')
    save(r, s)

# ---------------------------------------------------------------- dashboard.dart
r = 'lib/features/dashboard.dart'
s = load(r)
s = rep(s, "import 'dart:io';\n", "import 'dart:io';\nimport 'dart:ui' as ui;\n", r)
s = rep(s, "import 'package:flutter/services.dart';\n", "import 'package:flutter/scheduler.dart';\nimport 'package:flutter/services.dart';\n", r)
s = rep(s, "import 'package:mobile_scanner/mobile_scanner.dart';\n",
        "import 'package:mobile_scanner/mobile_scanner.dart';\nimport 'package:path_provider/path_provider.dart';\n", r)
s = rep(s, "import '../ui/brand.dart';\n", "import '../ui/app_icons.dart';\nimport '../ui/brand.dart';\n", r)
s = rep(s, "import '../ui/components.dart';\n", "import '../ui/components.dart';\nimport '../ui/fallback.dart';\n", r)
s = rep(s, "import 'patients.dart';\n", "import 'patients.dart';\nimport 'profile_pages.dart';\n", r)

# -- nav bar (RoleShell.build is outside the frozen escalation/SOS listener block)
s = rep_between(s, '          child: NavigationBar(\n', '''class RoleOverview extends StatelessWidget {''', '''          child: MedilinkNavBar(
            selectedIndex: index,
            onDestinationSelected: (v) => setState(() => index = v),
            items: labels.map(_navItem).toList(),
          ),
        ),
      ),
    );
  }

  // Reference icons (cropped from the approved screenshots) where the references show them;
  // Material icons for clinician-only tabs the references don't cover.
  NavItem _navItem(String l) => switch (l) {
    'Home' => const NavItem('Home', asset: AppIcons.navHome),
    'Health' => const NavItem('Health', asset: AppIcons.navHealth),
    'Emergency' || 'Emergencies' || 'Alerts' => NavItem(l, asset: AppIcons.navSiren),
    'Connections' => const NavItem('Connections', asset: AppIcons.navConnections),
    'Profile' => const NavItem('Profile', asset: AppIcons.navProfile),
    'Patients' => const NavItem('Patients', icon: Icons.groups_outlined),
    'Messages' => const NavItem('Messages', icon: Icons.chat_bubble_outline),
    'Command' => const NavItem('Command', icon: Icons.space_dashboard_outlined),
    _ => NavItem(l, icon: Icons.circle_outlined),
  };
}

''', r)

# -- Patient home (per reference 1)
s = rep_between(s, '    return Scaffold(\n      appBar: AppBar(\n        toolbarHeight: 72,', 'class HealthStatusCard extends ConsumerWidget {', '''    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.lg, AppSpacing.gutter, AppSpacing.xl),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      label: 'Good day',
                      excludeSemantics: true,
                      child: Text(
                        'Good day \\u{1F44B}',
                        style: AppText.headline.copyWith(fontSize: 30, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text('Your health, our priority', style: AppText.body.copyWith(fontSize: 16)),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                tooltip: 'Notifications',
                onPressed: () => _open(context, const NotificationsPage()),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surface,
                  side: const BorderSide(color: AppColors.border),
                  minimumSize: const Size(52, 52),
                ),
                icon: const Icon(Icons.notifications_none, color: AppColors.ink),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          HealthStatusCard(patientId: id),
          const SizedBox(height: AppSpacing.md),
          AiInsightCard(reading: reading),
          const SizedBox(height: AppSpacing.lg),
          TileGrid(
            children: [
              FeatureTile(
                title: 'Health',
                subtitle: 'Track your health information',
                leading: const AssetBadge(AppIcons.badgeHealth, size: 56),
                onTap: () => _open(context, const HealthPage()),
              ),
              FeatureTile(
                title: 'Emergency',
                subtitle: 'Get immediate assistance',
                leading: const AssetBadge(AppIcons.badgeEmergency, size: 56),
                onTap: () => _open(context, const EmergencyPage()),
              ),
              FeatureTile(
                title: 'Vault',
                subtitle: 'Secure your medical records',
                leading: const AssetBadge(AppIcons.badgeVault, size: 56),
                onTap: () => _open(context, const MedicalVaultPage()),
              ),
              // Existing home-screen hospital tile -- destination unchanged: the key-less
              // OpenStreetMap "Find my hospital" search (Phase 21).
              FeatureTile(
                title: 'Hospitals',
                subtitle: 'Find nearby hospitals',
                leading: const AssetBadge(AppIcons.badgeHospitals, size: 56),
                onTap: () => _open(context, const FindHospitalsPage()),
              ),
              FeatureTile(
                title: 'QR',
                subtitle: 'Quick access to your health ID',
                leading: const AssetBadge(AppIcons.badgeQr, size: 56),
                onTap: () => _open(context, const QrPage()),
              ),
              FeatureTile(
                title: 'Messages',
                subtitle: 'Talk to your doctor',
                leading: const AssetBadge(AppIcons.badgeMessages, size: 56),
                onTap: () => _open(context, const ChatPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

''', r)

# -- HealthStatusCard: loading per reference, error via FallbackView, no eyebrow label
s = rep_between(s, '      loading: () => SectionCard(\n        child: Row(\n          children: [\n            const IconBadge(icon: Icons.favorite_outline_rounded, tint: AppColors.tintBlue, size: 56),',
                '      data: (data) {\n        final risk = data?[\'risk\'] as Map?;\n        final timestamp', '''      loading: () => SectionCard(
        child: Row(
          children: [
            const AssetBadge(AppIcons.badgeHeart, size: 60),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Loading your care data...', style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('Please wait while we analyze your information', style: AppText.bodySm),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            const SizedBox.square(
              dimension: 30,
              child: CircularProgressIndicator(
                strokeWidth: 3.5,
                strokeCap: StrokeCap.round,
                color: AppColors.accent,
                backgroundColor: AppColors.accentTint,
              ),
            ),
          ],
        ),
      ),
      // Never shows exception text: themed fallback, existing retry action kept.
      error: (e, s) => SectionCard(
        child: FallbackView(
          kind: fallbackKindFor(e.toString()),
          compact: true,
          title: 'Vitals unavailable',
          message: "We couldn't load your latest reading.",
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(currentReadingProvider(patientId)),
        ),
      ),
''', r)
s = rep(s, '''                  const IconBadge(icon: Icons.favorite_outline_rounded, tint: AppColors.tintRed, size: 40),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'HEALTH STATUS',
                      style: AppText.caption.copyWith(letterSpacing: .8, fontWeight: FontWeight.w700),
                    ),
                  ),''', '''                  const AssetBadge(AppIcons.badgeHeart, size: 44),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text('Health status', style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)),
                  ),''', r)

# -- AiInsightCard: loading per reference (bars icon, progress, stethoscope-shield art)
s = rep_between(s, '      loading: () => SectionCard(\n        child: Row(\n          children: [\n            const IconBadge(icon: Icons.insights_rounded, tint: AppColors.tintViolet, size: 44),',
                '      error: (e, s) => const SizedBox.shrink(),', '''      loading: () => SectionCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Image.asset(AppIcons.insightBars, width: 26, height: 30, excludeFromSemantics: true),
                      const SizedBox(width: AppSpacing.sm),
                      Text('Analyzing...', style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text('Getting insights for better care', style: AppText.bodySm),
                  const SizedBox(height: AppSpacing.md),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: const LinearProgressIndicator(
                      minHeight: 8,
                      color: AppColors.primary,
                      backgroundColor: AppColors.accentTint,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Image.asset(AppIcons.illusStethoscope, width: 84, excludeFromSemantics: true),
          ],
        ),
      ),
''', r)
s = rep(s, '              const IconBadge(icon: Icons.insights_rounded, tint: AppColors.tintViolet, size: 44),',
        '              Image.asset(AppIcons.insightBars, width: 26, height: 30, excludeFromSemantics: true),', r)

# -- Health trends placeholder -> honest "coming soon" fallback
s = rep_between(s, '          // Static placeholder as before (no history is fetched); no fake chart data.\n',
                '        ],\n      ),\n    );\n  }\n}\n\n/// One decoded vitals frame', '''          // Trends are not fetched yet (ApiClient.healthHistory is never called): honest placeholder,
          // no fake chart data.
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Health trends', style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.md),
                const FallbackView(
                  kind: FallbackKind.comingSoon,
                  compact: true,
                  title: 'Trends coming soon',
                  message: 'Your 24-hour, 7-day and 30-day charts will appear here.',
                ),
              ],
            ),
          ),
''', r)

# -- Emergency page UI (after the freeze marker only)
marker = '  // ---- UI (build) ----\n'
assert s.count(crlf(marker)) == 1
s = rep_between(s, "  @override\n  Widget build(BuildContext context) => PageFrame(\n    title: 'Emergency',",
                "  /// Neutral strip for the page's own status `message` (unchanged text).", '''  @override
  Widget build(BuildContext context) {
    final bg = _activeId != null ? AppColors.dangerTint : AppColors.canvas;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: const Text('Emergency'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => _open(context, const NotificationsPage()),
            icon: const Icon(Icons.notifications_none_rounded),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      // Scrolls only if it must (large text); otherwise stays vertically centred. No decorative motion.
      body: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: AppSpacing.lg),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight - 2 * AppSpacing.lg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: _activeId == null
                  ? _idleContent(context)
                  : resolved
                  ? _resolvedContent(context)
                  : _verifyingContent(context),
            ),
          ),
        ),
      ),
    );
  }

''', r)
s = rep(s, '    const IconBadge(icon: Icons.shield_outlined, tint: AppColors.tintMint, size: 96),',
        '    const AssetBadge(AppIcons.badgeEmergency, size: 112),', r)
s = rep(s, '      onTapCancel: _cancelSosHold,\n', '''      onTapCancel: () {
        // A completed hold swaps this screen for the countdown, which disposes this detector
        // mid-gesture; it then reports a cancel while the tree is locked. The hold timer has
        // already finished by then, so only stop it (no setState). Otherwise unchanged.
        if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
          sosHoldTimer?.cancel();
        } else {
          _cancelSosHold();
        }
      },
''', r)
s = rep(s, '''          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.danger, width: 2),''', '''          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.danger, width: 2),''', r)
s = rep(s, '    IconBadge(icon: Icons.emergency, tint: (AppColors.danger.withValues(alpha: .12), AppColors.danger), size: 96),',
        '    const AssetBadge(AppIcons.badgeEmergency, size: 112),', r)
s = rep(s, '''        color: AppColors.surface,
        borderRadius: AppRadius.inputAll,
        border: Border.all(color: AppColors.danger.withValues(alpha: .25)),''', '''        color: AppColors.danger.withValues(alpha: .08),
        borderRadius: AppRadius.cardAll,''', r)
s = rep(s, '      IconBadge(icon: icon, tint: (color.withValues(alpha: .12), color), size: 96),',
        '''      icon == Icons.emergency
          ? const AssetBadge(AppIcons.badgeEmergency, size: 112)
          : IconBadge(icon: icon, tint: (color.withValues(alpha: .12), color), size: 96),''', r)
s = rep(s, '''                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: MedilinkColors.teal,
                  ),''', '''                  style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w800, color: AppColors.primary),''', r)
s = rep(s, '''          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Back to home'),''', '''          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), shape: const StadiumBorder()),
          child: const Text('Back to home'),''', r)

# -- QR page (per reference 3)
s = rep_between(s, "  Widget build(BuildContext context) => PageFrame(\n    title: 'QR center',", '  String? _createError;', '''  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('QR Access'),
      actions: [
        IconButton(
          tooltip: "Scan someone's QR",
          onPressed: _scan,
          icon: const Icon(Icons.qr_code_scanner_rounded, color: AppColors.primary),
        ),
        const SizedBox(width: AppSpacing.xs),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xl, AppSpacing.gutter, AppSpacing.xl),
      children: [
        Center(
          child: CustomPaint(
            painter: _QrCorners(),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: SizedBox.square(
                dimension: 220,
                child: token != null
                    ? Semantics(
                        label: 'Your health ID QR code',
                        image: true,
                        child: QrImageView(data: token!, size: 220, padding: EdgeInsets.zero, backgroundColor: AppColors.surface),
                      )
                    : const Center(child: Icon(Icons.qr_code_2_rounded, size: 150, color: AppColors.borderStrong)),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          token != null
              ? 'Scan this QR code to quickly access your health ID'
              : 'Create a QR code so a doctor or hospital can quickly open your health ID',
          textAlign: TextAlign.center,
          style: AppText.bodyStrong.copyWith(fontSize: 16),
        ),
        if (token != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text('Valid for 15 minutes.', textAlign: TextAlign.center, style: AppText.bodySm),
        ],
        if (_createError != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              _createError!,
              textAlign: TextAlign.center,
              style: AppText.bodySm.copyWith(color: AppColors.danger),
            ),
          ),
        const SizedBox(height: AppSpacing.xl),
        if (token == null)
          PrimaryButton(label: 'Create profile QR', icon: Icons.qr_code_2_rounded, onPressed: _create)
        else ...[
          FilledButton.icon(
            onPressed: _download,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56), shape: const StadiumBorder()),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download QR'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            // Sharing needs a share package (share_plus) that isn't approved yet.
            onPressed: () => FallbackScreen.open(
              context,
              FallbackKind.comingSoon,
              appBarTitle: 'Share',
              message: "Sharing your QR isn't available yet. Use Download QR for now.",
            ),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), shape: const StadiumBorder()),
            icon: const Icon(Icons.share_outlined),
            label: const Text('Share'),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextButton(onPressed: _create, child: const Text('Create profile QR')),
        ],
        const SizedBox(height: AppSpacing.xs),
        TextButton.icon(
          onPressed: _scan,
          icon: const Icon(Icons.qr_code_scanner_outlined),
          label: const Text('Scan someone\\'s QR'),
        ),
      ],
    ),
  );

  void _scan() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrScanPage()));

  /// Saves the current QR as a PNG (white background) in app storage, like the vault's Download.
  Future<void> _download() async {
    final data = token;
    if (data == null) return;
    String text;
    try {
      const size = 1024.0, pad = 64.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), Paint()..color = Colors.white);
      canvas.translate(pad, pad);
      QrPainter(data: data, version: QrVersions.auto, gapless: true).paint(canvas, const Size.square(size - 2 * pad));
      final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/medilink_health_id_qr.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      text = 'Saved to app storage: ${file.path}';
    } catch (_) {
      text = "We couldn't save the QR code. Please try again.";
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

''', r)
s = rep(s, 'class QrScanPage extends ConsumerStatefulWidget {', '''/// Teal corner brackets around the QR, per the QR reference.
class _QrCorners extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const len = 30.0, r = 12.0;
    final p = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    for (final (x, y, sx, sy) in [(0.0, 0.0, 1.0, 1.0), (w, 0.0, -1.0, 1.0), (0.0, h, 1.0, -1.0), (w, h, -1.0, -1.0)]) {
      final path = Path()
        ..moveTo(x, y + sy * len)
        ..lineTo(x, y + sy * r)
        ..quadraticBezierTo(x, y, x + sx * r, y)
        ..lineTo(x + sx * len, y);
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_QrCorners oldDelegate) => false;
}

class QrScanPage extends ConsumerStatefulWidget {''', r)

# -- Notifications: themed error instead of an endless spinner
s = rep(s, '        if (!s.hasData) return const LoadingState();\n', '''        if (s.hasError) {
          return FallbackView(
            kind: fallbackKindFor(s.error.toString()),
            message: fallbackKindFor(s.error.toString()) == FallbackKind.offline
                ? null
                : 'Your notifications could not be loaded right now.',
            actionLabel: 'Go back',
            onAction: () => Navigator.of(c).maybePop(),
          );
        }
        if (!s.hasData) return const LoadingState();
''', r)

# -- Profile page -> reference layout in profile_pages.dart
a = s.index(crlf('class ProfilePage extends ConsumerWidget {'))
s = s[:a] + crlf('''class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => const ProfileBody();
}
''')
log.append(f'{r}: ProfilePage -> ProfileBody')
save(r, s)

# ---------------------------------------------------------------- pubspec.yaml
r = 'pubspec.yaml'
s = load(r)
s = rep(s, '  connectivity_plus: ^7.0.0\n', '  connectivity_plus: ^7.0.0\n'
        '  # Profile photo from camera or gallery (flutter.dev). No manifest changes: gallery uses the\n'
        '  # system photo picker; camera uses the CAMERA permission already declared for QR scanning.\n'
        '  image_picker: ^1.1.2\n', r)
s = rep(s, '  uses-material-design: true\n', '  uses-material-design: true\n  assets:\n    - assets/icons/\n', r)
save(r, s)

print('\n'.join(log))
print('OK', len(log), 'edits')
