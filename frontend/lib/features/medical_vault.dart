import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../theme/tokens.dart';
import '../ui/app_icons.dart' show SkeletonList;
import '../ui/components.dart';
import '../ui/format.dart';
import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame;

const _categories = ['Lab', 'Prescription', 'Scan', 'Other'];
const _maxBytes = 20 * 1024 * 1024;

/// Maps old category values (LAB_REPORT, Report, ...) onto the four filter chips.
String vaultCategory(Object? raw) {
  final c = (raw ?? '').toString().toUpperCase();
  if (c.startsWith('LAB')) return 'Lab';
  if (c.startsWith('PRESC')) return 'Prescription';
  if (c.contains('SCAN') || c.contains('IMAG') || c.contains('XRAY') || c.contains('X-RAY')) return 'Scan';
  return 'Other';
}

String _guessCategory(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'lab|cbc|blood|test|report').hasMatch(n)) return 'Lab';
  if (RegExp(r'rx|prescri|medic').hasMatch(n)) return 'Prescription';
  if (RegExp(r'scan|xray|x-ray|mri|ct|ultra|\.(jpe?g|png|heic|heif)$').hasMatch(n)) return 'Scan';
  return 'Other';
}

String _size(Object? bytes) {
  final b = (bytes is num) ? bytes.toDouble() : 0.0;
  return b >= 1024 * 1024 ? '${(b / 1024 / 1024).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';
}

IconData _typeIcon(String contentType) => contentType == 'application/pdf'
    ? Icons.picture_as_pdf_outlined
    : contentType.startsWith('image/')
    ? Icons.image_outlined
    : Icons.description_outlined;

class MedicalVaultPage extends ConsumerStatefulWidget {
  const MedicalVaultPage({super.key});
  @override
  ConsumerState<MedicalVaultPage> createState() => _MedicalVaultPageState();
}

class _MedicalVaultPageState extends ConsumerState<MedicalVaultPage> {
  List<Map<String, dynamic>>? _records;
  Map<String, dynamic> _combined = const {'status': 'NONE'};
  String? _error;
  bool _uploading = false;
  String _filter = 'All';
  String _query = '';
  final _pending = <String>{}; // record ids with a summary job running
  final _openWhenReady = <String>{};
  bool _combinedPending = false;
  Timer? _poll;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _toast(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _friendly(Object e) => e is ApiException ? e.message : "Something went wrong. Please try again.";

  Future<void> _load() async {
    if (mounted && _records == null) setState(() => _error = null);
    try {
      final records = await _api.medicalRecords();
      Map<String, dynamic> combined = const {'status': 'NONE'};
      try {
        combined = Map<String, dynamic>.from(await _api.get('/documents/summary/combined') as Map);
      } catch (_) {
        // The combined card just shows its default state.
      }
      if (!mounted) return;
      setState(() {
        _records = records;
        _combined = combined;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    }
  }

  // ---- Summaries --------------------------------------------------------------------------
  void _ensurePolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  Future<void> _tick() async {
    for (final id in _pending.toList()) {
      await _summarize(id, poll: true);
    }
    if (_combinedPending) await _summarizeAll(poll: true);
    if (_pending.isEmpty && !_combinedPending) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _summarize(String id, {bool regenerate = false, bool poll = false}) async {
    if (!poll) {
      setState(() => _pending.add(id));
      _openWhenReady.add(id);
    }
    Map<String, dynamic> result;
    try {
      result = Map<String, dynamic>.from(
        await _api.post('/documents/$id/summary${regenerate ? '?regenerate=true' : ''}') as Map,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _pending.remove(id));
      _toast(_friendly(e));
      return;
    }
    if (!mounted) return;
    if (result['status'] == 'PENDING') {
      _ensurePolling();
      return;
    }
    final record = _records?.firstWhere((r) => r['id'] == id, orElse: () => {});
    setState(() {
      _pending.remove(id);
      if (record != null && record.isNotEmpty) record['aiSummary'] = result;
    });
    if (result['status'] == 'READY' && _openWhenReady.remove(id) && record != null && record.isNotEmpty) {
      _showSummary(record['filename']?.toString() ?? 'Report', result['summary'], onRegenerate: () => _summarize(id, regenerate: true));
    } else if (result['status'] != 'READY') {
      _openWhenReady.remove(id);
      _toast(result['message']?.toString() ?? "We couldn't summarize this report. Please try again.");
    }
  }

  Future<void> _summarizeAll({bool regenerate = false, bool poll = false}) async {
    if (!poll) setState(() => _combinedPending = true);
    Map<String, dynamic> result;
    try {
      result = Map<String, dynamic>.from(
        await _api.post('/documents/summary/combined${regenerate ? '?regenerate=true' : ''}') as Map,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _combinedPending = false);
      _toast(_friendly(e));
      return;
    }
    if (!mounted) return;
    if (result['status'] == 'PENDING') {
      _ensurePolling();
      return;
    }
    setState(() {
      _combinedPending = false;
      _combined = result;
    });
    if (result['status'] == 'READY') {
      _openCombined();
    } else if (result['status'] != 'NONE') {
      _toast(result['message']?.toString() ?? "We couldn't summarize your reports. Please try again.");
    }
  }

  void _openCombined() {
    final s = _combined['summary'];
    if (s is! Map) return;
    _showSummary('All reports', s, onRegenerate: () => _summarizeAll(regenerate: true));
  }

  void _showSummary(String title, Object? summary, {VoidCallback? onRegenerate}) {
    if (summary is! Map) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .85,
        minChildSize: .4,
        maxChildSize: .95,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.xxl),
          children: [
            Text('AI summary', style: AppText.caption.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.xxs),
            Semantics(header: true, child: Text(title, style: AppText.title)),
            const SizedBox(height: AppSpacing.md),
            AiSummaryView(summary: Map<String, dynamic>.from(summary), titleFor: _titleForDocId),
            if (onRegenerate != null) ...[
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  onRegenerate();
                },
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Regenerate summary'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _titleForDocId(String id) =>
      _records?.firstWhere((r) => r['id'] == id, orElse: () => const {})['filename']?.toString();

  // ---- File actions -----------------------------------------------------------------------
  Future<void> _upload() async {
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'heic', 'heif', 'docx', 'doc'],
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) return _toast("We couldn't read that file. Please try another one.");
    if (file.name.toLowerCase().endsWith('.doc')) {
      return _toast("Old Word (.doc) files aren't supported. Save it as .docx or PDF and upload again.");
    }
    if (bytes.length > _maxBytes) return _toast('This file is over 20 MB. Upload a smaller file.');
    final category = await _pickCategory(_guessCategory(file.name));
    if (category == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      await _api.uploadMedicalRecord(
        patientId: ref.read(sessionProvider).userId,
        category: category,
        filename: file.name,
        bytes: bytes,
        contentType: 'application/octet-stream', // the server decides the type from the extension
      );
      _toast('Report uploaded.');
      await _load();
    } catch (e) {
      _toast(_friendly(e));
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<String?> _pickCategory(String initial) => showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (sheetContext) {
      var selected = initial;
      return StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What kind of report is this?', style: AppText.titleSm),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final c in _categories)
                      ChoiceChip(label: Text(c), selected: selected == c, onSelected: (_) => setSheet(() => selected = c)),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetContext, selected),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  child: const Text('Upload'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Future<void> _download(Map<String, dynamic> record) async {
    try {
      final bytes = await _api.downloadMedicalRecord(record['id'].toString());
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/${record['filename']}';
      await File(path).writeAsBytes(bytes);
      _toast('Saved to app storage: $path');
    } catch (e) {
      _toast(e is ApiException ? e.message : "We couldn't save this file. Please try again.");
    }
  }

  Future<void> _rename(Map<String, dynamic> record) async {
    final current = record['filename']?.toString() ?? '';
    final dot = current.lastIndexOf('.');
    final controller = TextEditingController(text: dot > 0 ? current.substring(0, dot) : current);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename report'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Report name'),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('Rename')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    try {
      final updated = await _api.patch('/medical-records/${record['id']}', body: {'filename': name.trim()});
      if (!mounted) return;
      setState(() => record['filename'] = (updated as Map)['filename']);
    } catch (e) {
      _toast(_friendly(e));
    }
  }

  Future<void> _delete(Map<String, dynamic> record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this report?'),
        content: Text('"${record['filename']}" and its summary will be removed from your vault. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deleteMedicalRecord(record['id'].toString());
      if (!mounted) return;
      setState(() => _records?.remove(record));
      _toast('Report deleted.');
    } catch (e) {
      _toast(_friendly(e));
    }
  }

  void _view(Map<String, dynamic> record) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DocumentViewerPage(
        record: record,
        onSummary: () => _openDocSummary(record),
        onDownload: () => _download(record),
      ),
    ),
  );

  void _openDocSummary(Map<String, dynamic> record) {
    final id = record['id'].toString();
    final s = record['aiSummary'];
    if (s is Map && s['status'] == 'READY') {
      _showSummary(record['filename']?.toString() ?? 'Report', s['summary'], onRegenerate: () => _summarize(id, regenerate: true));
    } else {
      _summarize(id);
    }
  }

  // ---- UI --------------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Medical vault',
    actions: [
      IconButton(
        tooltip: 'Upload a report',
        onPressed: _uploading ? null : _upload,
        icon: _uploading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.upload_file_outlined),
      ),
    ],
    child: _body(),
  );

  Widget _body() {
    final records = _records;
    if (records == null && _error != null) return ErrorState(message: _error!, onRetry: _load);
    if (records == null) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.gutter),
        child: Column(children: [SkeletonList(rows: 4)]),
      );
    }
    if (records.isEmpty) {
      return Column(
        children: [
          const Expanded(
            child: EmptyState(
              title: 'Your vault is empty',
              detail: 'Upload a lab report, prescription or scan (PDF, photo or Word file, up to 20 MB).',
              icon: Icons.folder_open_outlined,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: PrimaryButton(label: 'Upload a report', onPressed: _uploading ? null : _upload, icon: Icons.upload_file_outlined),
          ),
        ],
      );
    }
    final q = _query.toLowerCase();
    final visible = records.where((r) {
      final cat = vaultCategory(r['category']);
      return (_filter == 'All' || cat == _filter) &&
          (q.isEmpty || '${r['filename']} $cat'.toLowerCase().contains(q));
    }).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, AppSpacing.xxl),
        children: [
          _CombinedCard(
            count: records.length,
            state: _combined,
            pending: _combinedPending,
            stale: _isStale(records),
            onSummarize: () => _summarizeAll(regenerate: _combined['status'] == 'READY' || _combined['status'] == 'FAILED'),
            onOpen: _openCombined,
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            onChanged: (v) => setState(() => _query = v),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search reports',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final c in ['All', ..._categories])
                ChoiceChip(label: Text(c), selected: _filter == c, onSelected: (_) => setState(() => _filter = c)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: EmptyState(title: 'No matching reports', detail: 'Try another search or filter.', icon: Icons.search_off_rounded),
            ),
          for (final r in visible)
            Padding(
              key: ValueKey(r['id']),
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _DocumentCard(
                record: r,
                pending: _pending.contains(r['id']),
                onView: () => _view(r),
                onSummary: () => _openDocSummary(r),
                onRename: () => _rename(r),
                onDownload: () => _download(r),
                onDelete: () => _delete(r),
              ),
            ),
        ],
      ),
    );
  }

  bool _isStale(List<Map<String, dynamic>> records) {
    final ids = (_combined['documentIds'] as List?)?.map((e) => e.toString()).toSet();
    if (_combined['status'] != 'READY' || ids == null) return false;
    return ids.length != records.length || !records.every((r) => ids.contains(r['id']));
  }
}

class _CombinedCard extends StatelessWidget {
  const _CombinedCard({
    required this.count,
    required this.state,
    required this.pending,
    required this.stale,
    required this.onSummarize,
    required this.onOpen,
  });
  final int count;
  final Map<String, dynamic> state;
  final bool pending;
  final bool stale;
  final VoidCallback onSummarize;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final status = state['status']?.toString() ?? 'NONE';
    final summary = state['summary'];
    final overview = summary is Map ? (summary['overview'] ?? summary) : null;
    final findings = overview is Map ? ((overview['keyFindings'] as List?) ?? const []) : const [];
    final reports = count == 1 ? '1 report' : '$count reports';
    String detail;
    if (pending) {
      detail = 'Reading $reports. This usually takes under a minute.';
    } else if (status == 'READY') {
      detail = stale ? 'New reports were added after this summary. Update it to include them.' : 'Covers $reports.';
    } else if (status == 'FAILED' || status == 'UNAVAILABLE') {
      detail = state['message']?.toString() ?? "We couldn't summarize your reports.";
    } else {
      detail = 'Get one plain-language summary of your $reports.';
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.primaryTint,
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: AppColors.primary.withValues(alpha: .18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconBadge(icon: Icons.auto_awesome_outlined, tint: (AppColors.surface, AppColors.primary), size: 40),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('AI summary of your reports', style: AppText.titleSm)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(liveRegion: true, child: Text(detail, style: AppText.bodySm.copyWith(color: AppColors.ink))),
          if (status == 'READY' && findings.isNotEmpty && !pending) ...[
            const SizedBox(height: AppSpacing.xs),
            for (final f in findings.take(3))
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
                child: Text('•  $f', style: AppText.bodySm.copyWith(color: AppColors.ink), maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (pending)
            const LinearProgressIndicator(minHeight: 4, borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)))
          else if (status != 'UNAVAILABLE')
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                if (status == 'READY')
                  FilledButton(onPressed: onOpen, style: FilledButton.styleFrom(minimumSize: const Size(0, 44)), child: const Text('View summary')),
                if (status == 'READY')
                  OutlinedButton(
                    onPressed: onSummarize,
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                    child: Text(stale ? 'Update summary' : 'Regenerate'),
                  )
                else
                  FilledButton.icon(
                    onPressed: onSummarize,
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    icon: Icon(status == 'FAILED' ? Icons.refresh_rounded : Icons.auto_awesome_outlined, size: 18),
                    label: Text(status == 'FAILED' ? 'Try again' : 'Summarize all reports'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({
    required this.record,
    required this.pending,
    required this.onView,
    required this.onSummary,
    required this.onRename,
    required this.onDownload,
    required this.onDelete,
  });
  final Map<String, dynamic> record;
  final bool pending;
  final VoidCallback onView, onSummary, onRename, onDownload, onDelete;

  @override
  Widget build(BuildContext context) {
    final ai = record['aiSummary'];
    final ready = ai is Map && ai['status'] == 'READY';
    final failed = ai is Map && ai['status'] == 'FAILED';
    final contentType = record['contentType']?.toString() ?? '';
    final meta = [
      vaultCategory(record['category']),
      if (record['createdAt'] != null) formatTimestamp(record['createdAt']).split(',').first,
      _size(record['size']),
    ].join(' · ');
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xxs, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onView,
            borderRadius: AppRadius.cardAll,
            child: Row(
              children: [
                IconBadge(icon: _typeIcon(contentType), tint: AppColors.tintBlue, size: 44),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(record['filename']?.toString() ?? 'Report', style: AppText.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(meta, style: AppText.caption),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  onSelected: (v) => switch (v) {
                    'view' => onView(),
                    'rename' => onRename(),
                    'download' => onDownload(),
                    _ => onDelete(),
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'view', child: ListTile(leading: Icon(Icons.visibility_outlined), title: Text('View'))),
                    PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename'))),
                    PopupMenuItem(value: 'download', child: ListTile(leading: Icon(Icons.download_outlined), title: Text('Download'))),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                        title: Text('Delete', style: TextStyle(color: AppColors.danger)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.only(left: 44 + AppSpacing.sm - 8),
            child: pending
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.sm),
                    child: Row(
                      children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: AppSpacing.xs),
                        Text('Summarizing…'),
                      ],
                    ),
                  )
                : TextButton.icon(
                    onPressed: onSummary,
                    icon: Icon(ready ? Icons.article_outlined : failed ? Icons.refresh_rounded : Icons.auto_awesome_outlined, size: 18),
                    label: Text(ready ? 'View summary' : failed ? 'Try summary again' : 'Summarize this report'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Renders a Gemini summary map: one document, or many with a combined overview.
class AiSummaryView extends StatelessWidget {
  const AiSummaryView({super.key, required this.summary, this.titleFor});
  final Map<String, dynamic> summary;
  final String? Function(String id)? titleFor;

  @override
  Widget build(BuildContext context) {
    final docs = (summary['documents'] as List?)?.whereType<Map>().toList();
    final overview = summary['overview'];
    // Reports the combined summary had to leave out (e.g. file missing on the server).
    final skipped = (summary['skippedDocuments'] as List?)?.whereType<Map>().toList() ?? const <Map>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (docs == null) ..._sections(summary),
        if (overview is Map) ...[
          Text('Overview', style: AppText.titleSm),
          ..._sections(Map<String, dynamic>.from(overview)),
          const Divider(height: AppSpacing.xxl),
        ],
        if (docs != null)
          for (final d in docs) ...[
            Text(
              titleFor?.call(d['documentId']?.toString() ?? '') ?? d['documentType']?.toString() ?? 'Report',
              style: AppText.titleSm,
            ),
            ..._sections(Map<String, dynamic>.from(d)),
            const SizedBox(height: AppSpacing.lg),
          ],
        if (skipped.isNotEmpty) ...[
          Text('Not included', style: AppText.titleSm),
          for (final s in skipped)
            Text('• ${s['filename'] ?? 'Report'}: ${s['reason'] ?? "This file couldn't be read."}', style: AppText.bodySm),
          const SizedBox(height: AppSpacing.md),
        ],
        const SizedBox(height: AppSpacing.sm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: const BoxDecoration(color: AppColors.warningTint, borderRadius: AppRadius.buttonAll),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.warning),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  summary['disclaimer']?.toString() ?? 'Informational only. Not a medical diagnosis. Consult your doctor.',
                  style: AppText.bodySm.copyWith(color: AppColors.ink),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _sections(Map<String, dynamic> s) {
    final meta = [s['documentType'], s['date']].where((v) => v != null && '$v'.trim().isNotEmpty).join(' · ');
    List<String> list(String k) => ((s[k] as List?) ?? const []).map((e) => '$e').where((e) => e.trim().isNotEmpty).toList();
    final abnormal = ((s['abnormalValues'] as List?) ?? const []).whereType<Map>().toList();
    Widget heading(String t) => Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xxs),
      child: Semantics(header: true, child: Text(t, style: AppText.caption.copyWith(fontWeight: FontWeight.w700))),
    );
    Widget bullets(List<String> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final i in items) Padding(padding: const EdgeInsets.only(top: 2), child: Text('•  $i', style: AppText.body.copyWith(color: AppColors.ink)))],
    );
    return [
      if (meta.isNotEmpty) Text(meta, style: AppText.bodySm),
      if (s['unreadable'] == true) ...[
        const SizedBox(height: AppSpacing.xs),
        Text("This document couldn't be read clearly. Try a sharper photo or the original file.", style: AppText.body),
      ],
      for (final (key, title) in [('keyFindings', 'Key findings')])
        if (list(key).isNotEmpty) ...[heading(title), bullets(list(key))],
      if (abnormal.isNotEmpty) ...[
        heading('Values outside the normal range'),
        for (final a in abnormal)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: AppSpacing.xxs),
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: const BoxDecoration(color: AppColors.dangerTint, borderRadius: AppRadius.buttonAll),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${a['name'] ?? ''}  ${a['value'] ?? ''}', style: AppText.bodyStrong.copyWith(color: AppColors.dangerPressed)),
                if ('${a['range'] ?? ''}'.isNotEmpty) Text('Normal range: ${a['range']}', style: AppText.bodySm),
                if ('${a['explanation'] ?? ''}'.isNotEmpty) Text('${a['explanation']}', style: AppText.bodySm.copyWith(color: AppColors.ink)),
              ],
            ),
          ),
      ],
      for (final (key, title) in [('medications', 'Medications'), ('diagnoses', 'Diagnoses'), ('followUps', 'Follow-ups')])
        if (list(key).isNotEmpty) ...[heading(title), bullets(list(key))],
    ];
  }
}

/// Full-screen viewer: PDF pages (rendered by the server), zoomable image, or Word/text as text.
class DocumentViewerPage extends ConsumerStatefulWidget {
  const DocumentViewerPage({super.key, required this.record, required this.onSummary, required this.onDownload});
  final Map<String, dynamic> record;
  final VoidCallback onSummary;
  final VoidCallback onDownload;
  @override
  ConsumerState<DocumentViewerPage> createState() => _DocumentViewerPageState();
}

class _DocumentViewerPageState extends ConsumerState<DocumentViewerPage> {
  String? _error;
  Uint8List? _image;
  String? _text;
  final _pages = <Uint8List>[];
  int? _pageCount;

  String get _type => widget.record['contentType']?.toString() ?? '';
  String get _id => widget.record['id'].toString();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    final api = ref.read(apiClientProvider);
    try {
      if (_type == 'application/pdf') {
        for (var i = _pages.length; _pageCount == null || i < _pageCount!; i++) {
          final page = await api.get('/medical-records/$_id/pages/$i') as Map;
          final bytes = base64Decode(page['png'].toString());
          if (!mounted) return;
          setState(() {
            _pageCount = (page['pageCount'] as num).toInt();
            _pages.add(bytes);
          });
        }
      } else if (_type.startsWith('image/')) {
        final bytes = Uint8List.fromList(await api.downloadMedicalRecord(_id));
        if (mounted) setState(() => _image = bytes);
      } else {
        final text = (await api.get('/medical-records/$_id/text') as Map)['text']?.toString() ?? '';
        if (mounted) setState(() => _text = text.trim().isEmpty ? 'This file has no readable text.' : text);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : "We couldn't open this file.");
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.record['filename']?.toString() ?? 'Report', overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(tooltip: 'AI summary', onPressed: widget.onSummary, icon: const Icon(Icons.auto_awesome_outlined)),
        IconButton(tooltip: 'Download', onPressed: widget.onDownload, icon: const Icon(Icons.download_outlined)),
        const SizedBox(width: AppSpacing.xs),
      ],
    ),
    body: _content(),
  );

  Widget _content() {
    if (_error != null && _pages.isEmpty) return ErrorState(message: _error!, onRetry: _load);
    if (_type == 'application/pdf') {
      if (_pages.isEmpty) return const LoadingState(label: 'Opening PDF…');
      return InteractiveViewer(
        maxScale: 5,
        child: ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.sm),
          itemCount: _pages.length + (_pages.length < (_pageCount ?? 0) || _error != null ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
          itemBuilder: (_, i) => i < _pages.length
              ? Semantics(
                  label: 'Page ${i + 1} of $_pageCount',
                  image: true,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(color: AppColors.surface, boxShadow: AppElevation.card),
                    child: Image.memory(_pages[i], fit: BoxFit.fitWidth, gaplessPlayback: true),
                  ),
                )
              : _error != null
              ? TextButton(onPressed: _load, child: const Text('Load remaining pages'))
              : const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: Center(child: CircularProgressIndicator())),
        ),
      );
    }
    if (_type.startsWith('image/')) {
      if (_image == null) return const LoadingState(label: 'Opening image…');
      return InteractiveViewer(
        maxScale: 6,
        child: Center(child: Semantics(label: 'Report image. Pinch to zoom.', image: true, child: Image.memory(_image!))),
      );
    }
    if (_text == null) return const LoadingState(label: 'Opening document…');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: SelectableText(_text!, style: AppText.body.copyWith(color: AppColors.ink)),
    );
  }
}
