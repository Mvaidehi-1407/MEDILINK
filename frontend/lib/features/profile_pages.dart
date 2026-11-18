import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/brand.dart';
import '../ui/components.dart';
import '../ui/fallback.dart';
import '../widgets/common.dart';
import 'contacts.dart';
import 'dashboard.dart' show ConsentPage;
import 'medical_vault.dart';

// ---------------------------------------------------------------------------------------------
// Avatar: stored on the backend through the existing profile route
// `PATCH /{patients|doctors|caregivers}/{profileId}` (no avatar endpoint exists).
// Hospital accounts have no profile route (hospital_profiles is not exposed): NOT FOUND.
// ---------------------------------------------------------------------------------------------

const _avatarField = 'avatarDataUrl';

String? _profileCollection(String role) => switch (role) {
  'PATIENT' => 'patients',
  'DOCTOR' => 'doctors',
  'CAREGIVER' => 'caregivers',
  _ => null,
};

/// The signed-in user's avatar as a `data:image/png;base64,...` URL, or null.
final avatarProvider = NotifierProvider<AvatarNotifier, String?>(AvatarNotifier.new);

class AvatarNotifier extends Notifier<String?> {
  String? _profileId;
  String _cacheKey(String userId) => 'medilink_avatar_$userId';

  @override
  String? build() {
    final userId = ref.watch(sessionProvider.select((s) => s.userId));
    if (userId.isNotEmpty) Future.microtask(() => _load(userId));
    return null;
  }

  bool get supported => _profileCollection(ref.read(sessionProvider).role) != null;

  Future<void> _load(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey(userId));
    if (cached != null) state = cached;
    try {
      final profile = await _findProfile();
      final remote = profile?[_avatarField]?.toString();
      if (remote != null && remote.startsWith('data:image')) {
        state = remote;
        await prefs.setString(_cacheKey(userId), remote);
      }
    } catch (_) {
      // Offline or no profile: keep the cached photo (or the default avatar).
    }
  }

  Future<Map<String, dynamic>?> _findProfile() async {
    final session = ref.read(sessionProvider);
    final collection = _profileCollection(session.role);
    if (collection == null) return null;
    final profiles = await ref.read(apiClientProvider).list('/$collection');
    for (final p in profiles) {
      if (p['userId']?.toString() == session.userId) {
        _profileId = p['id']?.toString();
        return p;
      }
    }
    return null;
  }

  /// Saves [png] (already cropped and resized) on the backend, then locally. Throws on failure.
  Future<void> upload(Uint8List png) async {
    final session = ref.read(sessionProvider);
    final collection = _profileCollection(session.role);
    if (collection == null) throw ApiException('Profile photos are not available for this account type.');
    if (_profileId == null) await _findProfile();
    if (_profileId == null) throw ApiException("We couldn't find your profile. Try again later.");
    final dataUrl = 'data:image/png;base64,${base64Encode(png)}';
    await ref.read(apiClientProvider).patch('/$collection/$_profileId', body: {_avatarField: dataUrl});
    state = dataUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey(session.userId), dataUrl);
  }

  Future<void> remove() async {
    final session = ref.read(sessionProvider);
    final collection = _profileCollection(session.role);
    if (collection == null) return;
    if (_profileId == null) await _findProfile();
    if (_profileId == null) throw ApiException("We couldn't find your profile. Try again later.");
    await ref.read(apiClientProvider).patch('/$collection/$_profileId', body: {_avatarField: null});
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey(session.userId));
  }
}

ImageProvider? avatarImage(String? dataUrl) {
  if (dataUrl == null) return null;
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  try {
    return MemoryImage(base64Decode(dataUrl.substring(comma + 1)));
  } catch (_) {
    return null;
  }
}

/// Avatar with the reference's edit badge. Tapping opens camera / gallery / remove.
class ProfileAvatar extends ConsumerStatefulWidget {
  const ProfileAvatar({super.key, this.size = 104});
  final double size;
  @override
  ConsumerState<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends ConsumerState<ProfileAvatar> {
  bool _busy = false;

  Future<void> _change() async {
    final notifier = ref.read(avatarProvider.notifier);
    if (!notifier.supported) {
      await FallbackScreen.open(
        context,
        FallbackKind.comingSoon,
        appBarTitle: 'Profile photo',
        message: "Profile photos for hospital accounts aren't available yet.",
      );
      return;
    }
    final hasPhoto = ref.read(avatarProvider) != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(c, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(c, 'gallery'),
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                title: Text('Remove photo', style: AppText.bodyStrong.copyWith(color: AppColors.danger)),
                onTap: () => Navigator.pop(c, 'remove'),
              ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'remove') return _run(() => notifier.remove(), 'Profile photo removed');

    XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      final denied = e.code.contains('access_denied') || e.code.contains('permission');
      await FallbackScreen.open(
        context,
        denied ? FallbackKind.permission : FallbackKind.error,
        appBarTitle: 'Profile photo',
        message: denied
            ? 'Allow ${choice == 'camera' ? 'camera' : 'photo'} access in your phone settings to set a profile photo.'
            : "We couldn't open the ${choice == 'camera' ? 'camera' : 'gallery'}. Please try again.",
      );
      return;
    }
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => AvatarCropPage(bytes: bytes)),
    );
    if (cropped == null || !mounted) return;
    await _run(() => notifier.upload(cropped), 'Profile photo updated');
  }

  Future<void> _run(Future<void> Function() job, String done) async {
    setState(() {
      _busy = true;
    });
    String text = done;
    try {
      await job();
    } on ApiException catch (e) {
      text = looksRaw(e.message) ? "We couldn't save your photo. Please try again." : e.message;
    } catch (_) {
      text = "We couldn't save your photo. Please try again.";
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final image = avatarImage(ref.watch(avatarProvider));
    final s = widget.size;
    return Semantics(
      button: true,
      label: 'Profile photo. Double tap to change.',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: _busy ? null : _change,
        child: SizedBox(
          width: s + 8,
          height: s + 8,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accentTint,
                  image: image == null ? null : DecorationImage(image: image, fit: BoxFit.cover),
                  boxShadow: AppElevation.card,
                ),
                alignment: Alignment.center,
                child: _busy
                    ? const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3))
                    : image == null
                    ? Icon(Icons.person_rounded, size: s * .56, color: AppColors.primary)
                    : null,
              ),
              Positioned(
                right: 2,
                bottom: 2,
                child: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppElevation.card,
                  ),
                  child: const Icon(Icons.edit_rounded, size: 18, color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Square crop with a circular guide: pinch to zoom, drag to position, then save a 320 px PNG.
class AvatarCropPage extends StatefulWidget {
  const AvatarCropPage({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<AvatarCropPage> {
  final _boundary = GlobalKey();
  final _transform = TransformationController();
  Size? _imageSize;
  double? _side;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.bytes).then((img) {
      if (!mounted) return;
      setState(() {
        _imageSize = Size(img.width.toDouble(), img.height.toDouble());
      });
      img.dispose();
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final side = _side;
    final box = _boundary.currentContext?.findRenderObject();
    if (side == null || box is! RenderRepaintBoundary) return;
    setState(() {
      _saving = true;
    });
    final image = await box.toImage(pixelRatio: 320 / side);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (!mounted) return;
    Navigator.of(context).pop(data?.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Crop photo')),
    body: SafeArea(
      child: _imageSize == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      var side = box.maxWidth - 2 * AppSpacing.gutter;
                      if (side > box.maxHeight - AppSpacing.xl) side = box.maxHeight - AppSpacing.xl;
                      if (side < 120) side = 120;
                      final img = _imageSize!;
                      final cover = side / (img.width < img.height ? img.width : img.height);
                      final cw = img.width * cover, ch = img.height * cover;
                      if (_side != side) {
                        _side = side;
                        _transform.value = Matrix4.translationValues(-(cw - side) / 2, -(ch - side) / 2, 0);
                      }
                      return Center(
                        child: SizedBox.square(
                          dimension: side,
                          child: Stack(
                            children: [
                              RepaintBoundary(
                                key: _boundary,
                                child: ClipRect(
                                  child: InteractiveViewer(
                                    transformationController: _transform,
                                    constrained: false,
                                    minScale: 1,
                                    maxScale: 5,
                                    child: SizedBox(
                                      width: cw,
                                      height: ch,
                                      child: Image.memory(widget.bytes, fit: BoxFit.cover),
                                    ),
                                  ),
                                ),
                              ),
                              IgnorePointer(child: CustomPaint(size: Size.square(side), painter: _CircleGuide())),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.lg),
                  child: Column(
                    children: [
                      Text('Pinch to zoom and drag to position.', style: AppText.bodySm),
                      const SizedBox(height: AppSpacing.md),
                      PrimaryButton(
                        label: 'Use photo',
                        icon: Icons.check_rounded,
                        loading: _saving,
                        onPressed: _save,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );
}

class _CircleGuide extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = size.center(Offset.zero);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: c, radius: r));
    canvas.drawPath(outside, Paint()..color = const Color(0x8C14213D));
    canvas.drawCircle(c, r - 1, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = AppColors.onDark);
  }

  @override
  bool shouldRepaint(_CircleGuide oldDelegate) => false;
}

// ---------------------------------------------------------------------------------------------
// Profile page body (per reference 4).
// ---------------------------------------------------------------------------------------------

class ProfileBody extends ConsumerWidget {
  const ProfileBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final user = session.user ?? {};
    final isPatient = session.role == 'PATIENT';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'App settings',
            onPressed: () => _push(context, const AppSettingsPage()),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
        children: [
          const Center(child: ProfileAvatar()),
          const SizedBox(height: AppSpacing.md),
          Text(
            user['name']?.toString() ?? 'MEDILINK user',
            textAlign: TextAlign.center,
            style: AppText.title.copyWith(fontSize: 22),
          ),
          const SizedBox(height: AppSpacing.xxs),
          SelectableText(
            'MEDILINK ID: ${user['id'] ?? ''}',
            textAlign: TextAlign.center,
            style: AppText.bodySm.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xl),
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
            onPressed: () async {
              await ref.read(sessionProvider.notifier).clear();
              if (context.mounted) context.go('/welcome');
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: const StadiumBorder(),
              foregroundColor: AppColors.ink,
              side: const BorderSide(color: AppColors.borderStrong),
            ),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Logout'),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                if (isPatient) ...[
                  _Row(
                    icon: Icons.assignment_outlined,
                    tint: AppColors.tintMint,
                    label: 'My Medical Records',
                    onTap: () => _push(context, const MedicalVaultPage()),
                  ),
                  const Divider(height: 1, indent: 64),
                ],
                _Row(
                  icon: Icons.settings_outlined,
                  tint: AppColors.tintBlue,
                  label: 'App Settings',
                  onTap: () => _push(context, const AppSettingsPage()),
                ),
                const Divider(height: 1, indent: 64),
                _Row(
                  icon: Icons.info_outline_rounded,
                  tint: AppColors.tintBlue,
                  label: 'About MediLink',
                  onTap: () => _push(context, const AboutPage()),
                ),
                const Divider(height: 1, indent: 64),
                _Row(
                  icon: Icons.help_outline_rounded,
                  tint: AppColors.tintMint,
                  label: 'Help & Support',
                  onTap: () => _push(context, const HelpPage()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _push(BuildContext context, Widget page) {
  HapticFeedback.selectionClick();
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.tint, required this.label, required this.onTap, this.subtitle});
  final IconData icon;
  final (Color, Color) tint;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    minVerticalPadding: AppSpacing.sm,
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
    leading: IconBadge(icon: icon, tint: tint, size: 36),
    title: Text(label, style: AppText.bodyStrong),
    subtitle: subtitle == null ? null : Text(subtitle!, style: AppText.bodySm),
    trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.inkSecondary),
  );
}

Widget _section(String title, List<Widget> rows) => Padding(
  padding: const EdgeInsets.only(bottom: AppSpacing.lg),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: AppSpacing.xxs, bottom: AppSpacing.xs),
        child: Text(title, style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)),
      ),
      SectionCard(padding: EdgeInsets.zero, child: Column(children: rows)),
    ],
  ),
);

// ---------------------------------------------------------------------------------------------
// App settings
// ---------------------------------------------------------------------------------------------

class AppSettingsPage extends ConsumerWidget {
  const AppSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final isPatient = session.role == 'PATIENT';
    return Scaffold(
      appBar: AppBar(title: const Text('App settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
        children: [
          _section('Display', [
            SwitchListTile(
              value: session.seniorMode,
              onChanged: (v) => ref.read(sessionProvider.notifier).setSeniorMode(v),
              title: Text('Senior Mode', style: AppText.bodyStrong),
              subtitle: Text('Larger text across the app', style: AppText.bodySm),
            ),
          ]),
          if (isPatient)
            _section('Safety', [
              _Row(
                icon: Icons.contact_phone_outlined,
                tint: AppColors.tintRed,
                label: 'Emergency contacts',
                subtitle: 'Who gets called and texted first',
                onTap: () => _push(context, const ContactsPage()),
              ),
              const Divider(height: 1, indent: 64),
              _Row(
                icon: Icons.verified_user_outlined,
                tint: AppColors.tintViolet,
                label: 'Consent',
                subtitle: 'Who can see your vitals and records',
                onTap: () => _push(context, const ConsentPage()),
              ),
            ]),
          _section('Phone', [
            _Row(
              icon: Icons.lock_open_outlined,
              tint: AppColors.tintAmber,
              label: 'App permissions',
              subtitle: 'Bluetooth, location, calls, SMS, notifications',
              onTap: () => openAppSettings(),
            ),
          ]),
          _section('Connection', [
            _Row(
              icon: Icons.dns_outlined,
              tint: AppColors.tintBlue,
              label: 'Server address',
              subtitle: ref.read(sessionProvider.notifier).apiBaseUrl ?? defaultApiBaseUrl,
              onTap: () => _push(context, const ServerSettingsPage()),
            ),
          ]),
        ],
      ),
    );
  }
}

// defaultApiBaseUrl / normalizeApiBaseUrl live in core/session.dart (shared with ApiClient + WS).
const _apiUrlPref = 'medilink_api_url';

/// Lets a physical phone point at the backend. The emulator default (10.0.2.2) is the reason a
/// real phone shows "Can't reach MediLink servers". Saved under the preference the app already reads.
class ServerSettingsPage extends ConsumerStatefulWidget {
  const ServerSettingsPage({super.key});
  @override
  ConsumerState<ServerSettingsPage> createState() => _ServerSettingsPageState();
}

class _ServerSettingsPageState extends ConsumerState<ServerSettingsPage> {
  late final TextEditingController _url = TextEditingController(
    text: ref.read(sessionProvider.notifier).apiBaseUrl ?? defaultApiBaseUrl,
  );
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  String _normalise(String raw) => normalizeApiBaseUrl(raw);

  Future<void> _test() async {
    final url = _normalise(_url.text);
    _url.text = url;
    setState(() {
      _testing = true;
      _result = null;
    });
    var ok = false;
    String msg;
    try {
      final root = url.replaceFirst(RegExp(r'/api$'), '');
      final res = await http.get(Uri.parse('$root/healthz')).timeout(const Duration(seconds: 8));
      ok = res.statusCode >= 200 && res.statusCode < 300;
      msg = ok ? 'Connected. The MediLink server answered.' : 'The server answered with an error (${res.statusCode}).';
    } on TimeoutException {
      msg = 'No answer within 8 seconds. Check the address and that your phone and the server are on the same network.';
    } catch (_) {
      msg = "Can't reach that address. Check it and try again.";
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ok = ok;
      _result = msg;
    });
  }

  Future<void> _save({bool reset = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final session = ref.read(sessionProvider.notifier);
    // Saving the build default stores nothing, so a future default change still applies.
    if (reset || _normalise(_url.text) == defaultApiBaseUrl) {
      await prefs.remove(_apiUrlPref);
      session.apiBaseUrl = null;
      _url.text = defaultApiBaseUrl;
    } else {
      final url = _normalise(_url.text);
      if (url.isEmpty) return;
      _url.text = url;
      await prefs.setString(_apiUrlPref, url);
      session.apiBaseUrl = url;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(reset ? 'Server address reset to the default.' : 'Server address saved.')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Server address')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, AppSpacing.xl),
      children: [
        Text(
          'Enter the address of your MediLink server. On a real phone this is usually your computer\'s '
          'Wi-Fi address, for example http://192.168.1.20:8000/api.',
          style: AppText.body,
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Server address', prefixIcon: Icon(Icons.dns_outlined)),
          onSubmitted: (_) => _test(),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_result != null)
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: _ok ? AppColors.successTint : AppColors.warningTint,
              borderRadius: AppRadius.inputAll,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _ok ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
                  size: 20,
                  color: _ok ? AppColors.success : AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(child: Text(_result!, style: AppText.bodySm.copyWith(color: AppColors.ink))),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          onPressed: _testing ? null : _test,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: _testing
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_tethering_rounded),
          label: const Text('Test connection'),
        ),
        const SizedBox(height: AppSpacing.sm),
        PrimaryButton(label: 'Save', icon: Icons.check_rounded, onPressed: _testing ? null : () => _save()),
        const SizedBox(height: AppSpacing.xs),
        TextButton(onPressed: () => _save(reset: true), child: const Text('Reset to default')),
        const SizedBox(height: AppSpacing.lg),
        Text('Tips', style: AppText.titleSm.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '• Start the server so other devices can reach it: uvicorn app.main:app --host 0.0.0.0 --port 8000\n'
          '• Your phone and computer must be on the same Wi-Fi, and the firewall must allow port 8000.\n'
          '• With a USB cable you can also run "adb reverse tcp:8000 tcp:8000" and use http://127.0.0.1:8000/api.',
          style: AppText.bodySm,
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------------------------
// About and Help
// ---------------------------------------------------------------------------------------------

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('About MediLink')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xl, AppSpacing.gutter, AppSpacing.xl),
      children: [
        const Center(child: MedilinkLockup(fontSize: 30, vertical: true)),
        const SizedBox(height: AppSpacing.sm),
        Text('Monitor. Detect. Connect. Respond.', textAlign: TextAlign.center, style: AppText.body),
        const SizedBox(height: AppSpacing.xl),
        SectionCard(
          child: Text(
            'MediLink connects your wearable, your phone and your care team. It watches your vitals, '
            'checks with you when something looks unusual, and if you need help it calls and texts '
            'your caretakers from your own phone and alerts a nearby hospital.',
            style: AppText.body.copyWith(color: AppColors.ink),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SectionCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded, color: AppColors.inkSecondary, size: 20),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  'MediLink gives decision-support information. It is not a medical diagnosis. '
                  'In an emergency, always call your local emergency number.',
                  style: AppText.bodySm,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const _faq = [
    (
      'How does SOS work?',
      'On the Emergency tab, press and hold the SOS button for about 2 seconds. You then have 30 seconds '
          'to tap "I\'m OK". If you tap "I NEED HELP", or don\'t answer, your caretakers are called and texted.',
    ),
    (
      'Why must my phone stay on?',
      'Calls and texts to your caretakers go out from this phone\'s own SIM. Keep it charged, with signal.',
    ),
    (
      'How do I connect my wearable?',
      'Open Health, then "Connect a device". Keep Bluetooth on and the band close to your phone.',
    ),
    (
      'Who can see my health data?',
      'Only people you grant consent to. You can review them under App settings > Consent.',
    ),
    (
      'The app says it can\'t reach MediLink servers',
      'Your phone can\'t reach the server address. Check your internet, then the server address in '
          'App settings > Server address.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Help & support')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xl),
      children: [
        SectionCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < _faq.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Text(_faq[i].$1, style: AppText.bodyStrong),
                  childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(_faq[i].$2, style: AppText.body)],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _section('Still need help?', [
          _Row(
            icon: Icons.dns_outlined,
            tint: AppColors.tintBlue,
            label: 'Server address',
            subtitle: 'Fix "can\'t reach MediLink servers"',
            onTap: () => _push(context, const ServerSettingsPage()),
          ),
          const Divider(height: 1, indent: 64),
          _Row(
            icon: Icons.lock_open_outlined,
            tint: AppColors.tintAmber,
            label: 'App permissions',
            subtitle: 'Open your phone settings for MediLink',
            onTap: () => openAppSettings(),
          ),
        ]),
        Text(
          'For questions about your care, message your doctor or caregiver from Messages.',
          style: AppText.bodySm,
        ),
      ],
    ),
  );
}
