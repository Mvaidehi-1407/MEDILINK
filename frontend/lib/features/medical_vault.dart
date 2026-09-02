import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame;

class MedicalVaultPage extends ConsumerStatefulWidget {
  const MedicalVaultPage({super.key});
  @override
  ConsumerState<MedicalVaultPage> createState() => _MedicalVaultPageState();
}

class _MedicalVaultPageState extends ConsumerState<MedicalVaultPage> {
  Future<List<Map<String, dynamic>>>? _future;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _future = ref.read(apiClientProvider).medicalRecords());
  }

  Future<void> _upload() async {
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'txt'],
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) return;
    setState(() => _uploading = true);
    try {
      await ref.read(apiClientProvider).uploadMedicalRecord(
        patientId: ref.read(sessionProvider).userId,
        category: 'Report',
        filename: file.name,
        bytes: bytes,
        contentType: _contentTypeFor(file.name),
      );
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  static String _contentTypeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'text/plain';
  }

  Future<void> _view(Map<String, dynamic> record) async {
    try {
      final bytes = await ref.read(apiClientProvider).downloadMedicalRecord(record['id'].toString());
      if (!mounted) return;
      final contentType = record['contentType']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(record['filename']?.toString() ?? 'Medical record'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (contentType.startsWith('image/'))
                    Image.memory(Uint8List.fromList(bytes))
                  else if (contentType == 'text/plain')
                    Text(String.fromCharCodes(bytes))
                  else
                    Text('${(bytes.length / 1024).toStringAsFixed(1)} KB $contentType file. Use Download to save it.'),
                  if (record['summaryStatus'] == 'AVAILABLE' && record['summary'] != null) ...[
                    const Divider(height: 24),
                    const Text('AI summary', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    if ((record['summary']['keyObservations'] as List?)?.isNotEmpty ?? false) ...[
                      const Text('Key observations', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                      Text((record['summary']['keyObservations'] as List).join('\n')),
                      const SizedBox(height: 8),
                    ],
                    if ((record['summary']['simplifiedExplanation']?.toString() ?? '').isNotEmpty) ...[
                      const Text('In plain terms', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                      Text(record['summary']['simplifiedExplanation'].toString()),
                      const SizedBox(height: 8),
                    ],
                    if ((record['summary']['importantTerms'] as List?)?.isNotEmpty ?? false) ...[
                      const Text('Terms explained', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                      Text((record['summary']['importantTerms'] as List).join(', ')),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      record['summary']['disclaimer']?.toString() ?? '',
                      style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
                    ),
                  ] else if (record['summaryStatus'] == 'UNAVAILABLE') ...[
                    const Divider(height: 24),
                    const Text(
                      'No AI summary available for this file type (images aren\'t text-extracted). PDF and text files get a real summary.',
                      style: TextStyle(color: Colors.blueGrey, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            TextButton(onPressed: () => _saveToDevice(record, bytes), child: const Text('Download')),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _saveToDevice(Map<String, dynamic> record, List<int> bytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/${record['filename']}';
      await File(path).writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to app storage: $path')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _download(Map<String, dynamic> record) async {
    try {
      final bytes = await ref.read(apiClientProvider).downloadMedicalRecord(record['id'].toString());
      await _saveToDevice(record, bytes);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(Map<String, dynamic> record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove record?'),
        content: Text('This deletes "${record['filename']}" permanently.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(apiClientProvider).deleteMedicalRecord(record['id'].toString());
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Medical vault',
    actions: [
      IconButton(
        onPressed: _uploading ? null : _upload,
        icon: _uploading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.upload_file_outlined),
      ),
    ],
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (c, s) {
        if (s.connectionState == ConnectionState.waiting) return const LoadingState();
        if (s.hasError) return ErrorState(message: s.error.toString(), onRetry: _load);
        if (s.data!.isEmpty) {
          return Column(
            children: [
              const Expanded(
                child: EmptyState(
                  title: 'Your vault is empty',
                  detail: 'Upload a real medical record (PDF, image, or text) to store it securely.',
                  icon: Icons.folder_open_outlined,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: PrimaryButton(label: 'Upload a record', onPressed: _upload, icon: Icons.upload_file_outlined),
              ),
            ],
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: s.data!.length,
          itemBuilder: (c, i) {
            final r = s.data![i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(r['filename']?.toString() ?? 'Medical record'),
                  subtitle: Text('${r['category'] ?? 'Report'} · AI summary: ${r['summaryStatus'] ?? 'UNAVAILABLE'}'),
                  onTap: () => _view(r),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'view') _view(r);
                      if (value == 'download') _download(r);
                      if (value == 'delete') _delete(r);
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'view', child: Text('View')),
                      PopupMenuItem(value: 'download', child: Text('Download')),
                      PopupMenuItem(value: 'delete', child: Text('Remove')),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
