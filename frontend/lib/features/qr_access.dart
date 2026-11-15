import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/fallback.dart';
import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame;
import 'medical_vault.dart' show AiSummaryView;

/// Patient's share QR: a signed, expiring, revocable link to a read-only page with their
/// report summaries. Never triggers AI summarization.
class QrPage extends ConsumerStatefulWidget {
  const QrPage({super.key});
  @override
  ConsumerState<QrPage> createState() => _QrPageState();
}

class _QrPageState extends ConsumerState<QrPage> {
  Map<String, dynamic>? _share; // {id, url, expiresAt} or null when none is active
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Timer? _clock;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  void initState() {
    super.initState();
    _load();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _toast(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final r = Map<String, dynamic>.from(await _api.get('/qr/share/current') as Map);
      if (!mounted) return;
      setState(() {
        _share = r['active'] == true ? r : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is ApiException ? e.message : "Can't reach MediLink";
          _loading = false;
        });
      }
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await _api.post('/qr/share') as Map);
      if (mounted) setState(() => _share = r);
    } catch (e) {
      _toast(e is ApiException ? e.message : "We couldn't create a QR code. Check your connection and try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _revoke() async {
    final share = _share;
    if (share == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off this QR code?'),
        content: const Text('Anyone who scans it, or already has the link, will no longer see your reports.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _api.post('/qr/share/${share['id']}/revoke');
      if (mounted) setState(() => _share = null);
      _toast('QR code turned off.');
    } catch (e) {
      _toast(e is ApiException ? e.message : "We couldn't turn off the QR code. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  /// QR as a PNG with a white quiet zone.
  Future<File> _qrFile(String data) async {
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
    return File('${dir.path}/medilink_health_qr.png')..writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  Future<void> _download() async {
    try {
      final file = await _qrFile(_share!['url'].toString());
      _toast('Saved to app storage: ${file.path}');
    } catch (_) {
      _toast("We couldn't save the QR code. Please try again.");
    }
  }

  Future<void> _shareLink() async {
    try {
      final url = _share!['url'].toString();
      final file = await _qrFile(url);
      await SharePlus.instance.share(ShareParams(
        subject: 'My MediLink health summary',
        text: 'View my MediLink health summary (read-only, expires ${_expiryText()}): $url',
        files: [XFile(file.path, mimeType: 'image/png')],
      ));
    } catch (_) {
      _toast("We couldn't open sharing. Please try again.");
    }
  }

  DateTime? get _expiresAt => DateTime.tryParse(_share?['expiresAt']?.toString() ?? '')?.toLocal();

  String _expiryText() {
    final left = _expiresAt?.difference(DateTime.now());
    if (left == null) return 'soon';
    if (left.isNegative) return 'now';
    if (left.inMinutes < 1) return 'in under a minute';
    if (left.inMinutes < 60) return 'in ${left.inMinutes} min';
    final h = left.inHours, m = left.inMinutes % 60;
    return 'in $h h${m > 0 ? ' $m min' : ''}';
  }

  void _scan() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrScanPage()));

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'QR Access',
    actions: [
      IconButton(
        tooltip: "Scan someone's QR",
        onPressed: _scan,
        icon: const Icon(Icons.qr_code_scanner_rounded, color: AppColors.primary),
      ),
    ],
    child: _body(),
  );

  Widget _body() {
    if (_loading) return const LoadingState(label: 'Loading your QR code…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final share = _share;
    final expired = _expiresAt != null && _expiresAt!.isBefore(DateTime.now());
    final active = share != null && !expired;
    final session = ref.watch(sessionProvider);
    final id = session.userId;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xl, AppSpacing.gutter, AppSpacing.xxl),
      children: [
        Center(
          child: CustomPaint(
            painter: _QrCorners(),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: SizedBox.square(
                dimension: 220,
                child: active
                    ? Semantics(
                        label: 'QR code that opens your read-only health summary',
                        image: true,
                        child: QrImageView(data: share['url'].toString(), size: 220, padding: EdgeInsets.zero, backgroundColor: AppColors.surface),
                      )
                    : const Center(child: Icon(Icons.qr_code_2_rounded, size: 150, color: AppColors.borderStrong)),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          active ? 'Show this to your doctor or hospital' : expired ? 'This QR code has expired' : 'Share your reports with a QR code',
          textAlign: TextAlign.center,
          style: AppText.title,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          active
              ? 'Expires ${_expiryText()}${id.length >= 8 ? ' · ID ML-${id.substring(id.length - 8).toUpperCase()}' : ''}'
              : 'A doctor scans it to see your report summaries. No app or login needed.',
          textAlign: TextAlign.center,
          style: AppText.bodySm,
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: const BoxDecoration(color: AppColors.warningTint, borderRadius: AppRadius.buttonAll),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.privacy_tip_outlined, size: 20, color: AppColors.warning),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  'Anyone who scans this code can see your name, photo, MediLink ID and report summaries '
                  'until it expires or you turn it off. They can\'t see or download the original files.',
                  style: AppText.bodySm.copyWith(color: AppColors.ink),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        if (!active)
          PrimaryButton(
            label: expired ? 'Create a new QR code' : 'I agree, create QR code',
            icon: Icons.qr_code_2_rounded,
            onPressed: _busy ? null : _create,
          )
        else ...[
          FilledButton.icon(
            onPressed: _busy ? null : _download,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56), shape: const StadiumBorder()),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download QR'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: _busy ? null : _shareLink,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), shape: const StadiumBorder()),
            icon: const Icon(Icons.share_outlined),
            label: const Text('Share'),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('New code'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: _busy ? null : _revoke,
                  style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                  icon: const Icon(Icons.link_off_rounded),
                  label: const Text('Turn off'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.xs),
        TextButton.icon(
          onPressed: _scan,
          icon: const Icon(Icons.qr_code_scanner_outlined),
          label: const Text("Scan someone's QR"),
        ),
      ],
    );
  }
}

/// Teal corner brackets around the QR, per the QR reference.
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

class QrScanPage extends ConsumerStatefulWidget {
  const QrScanPage({super.key});
  @override
  ConsumerState<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends ConsumerState<QrScanPage> {
  bool _handled = false;
  Map<String, dynamic>? _info;
  String? _error;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;
    setState(() => _handled = true);
    final uri = Uri.tryParse(raw);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.path.startsWith('/share/')) {
      // A MediLink share QR: open its read-only page in the browser.
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (opened) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _error = "Couldn't open the link. Try again.";
          _handled = false;
        });
      }
      return;
    }
    try {
      final result = await ref.read(apiClientProvider).get('/qr/$raw');
      if (result is! Map) throw const FormatException('Unexpected response');
      if (mounted) setState(() => _info = Map<String, dynamic>.from(result));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is ApiException ? e.message : "That isn't a MediLink QR code. Try scanning again.";
          _handled = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Scan QR',
    child: _info != null
        ? _PatientInfoResult(info: _info!)
        : Column(
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Semantics(liveRegion: true, child: Text(_error!, style: AppText.body.copyWith(color: AppColors.danger))),
                ),
              Expanded(
                child: MobileScanner(
                  onDetect: _onDetect,
                  errorBuilder: (_, _) => const FallbackView(kind: FallbackKind.permission, message: 'MediLink needs the camera to scan QR codes.'),
                ),
              ),
            ],
          ),
  );
}

class _PatientInfoResult extends StatelessWidget {
  const _PatientInfoResult({required this.info});
  final Map<String, dynamic> info;
  @override
  Widget build(BuildContext context) {
    final patient = info['patient'] as Map?;
    final contacts = (info['emergencyContacts'] as List?) ?? [];
    final documents = (info['documentSummaries'] as List?) ?? [];
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        SectionCard(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
            title: Text(patient?['name']?.toString() ?? 'Unknown patient'),
            subtitle: Text(
              [
                if (patient?['age'] != null) 'Age ${patient!['age']}',
                if (patient?['phone'] != null) patient!['phone'].toString(),
              ].join(' · '),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('Emergency contacts', style: AppText.titleSm),
        const SizedBox(height: AppSpacing.xs),
        if (contacts.isEmpty)
          Text('No emergency contacts on file.', style: AppText.body)
        else
          ...contacts.map(
            (c) => SectionCard(
              child: ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Text(c['name']?.toString() ?? ''),
                subtitle: Text(c['phone']?.toString() ?? ''),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Text('Report summaries', style: AppText.titleSm),
        const SizedBox(height: AppSpacing.xs),
        if (documents.isEmpty)
          Text('No report summaries on file.', style: AppText.body)
        else
          ...documents.map(
            (d) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d['filename']?.toString() ?? 'Report', style: AppText.label),
                    const SizedBox(height: AppSpacing.xs),
                    if (d['summary'] is Map) AiSummaryView(summary: Map<String, dynamic>.from(d['summary'] as Map)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
