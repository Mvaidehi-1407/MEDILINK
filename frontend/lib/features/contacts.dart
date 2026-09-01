import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame;

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});
  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _future = ref.read(apiClientProvider).emergencyContacts());
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _ContactForm(existing: existing),
      ),
    );
    if (result == true) _load();
  }

  Future<void> _delete(String id) async {
    try {
      await ref.read(apiClientProvider).deleteEmergencyContact(id);
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Emergency contacts',
    actions: [
      IconButton(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.person_add_alt_outlined),
      ),
    ],
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) return const LoadingState();
        if (snapshot.hasError) {
          return ErrorState(message: snapshot.error.toString(), onRetry: _load);
        }
        final contacts = snapshot.data!;
        if (contacts.isEmpty) {
          return Column(
            children: [
              const Expanded(
                child: EmptyState(
                  title: 'No emergency contacts yet',
                  detail: 'Add someone who should be called and texted first if a real emergency is confirmed.',
                  icon: Icons.contact_phone_outlined,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: PrimaryButton(
                  label: 'Add emergency contact',
                  onPressed: () => _openForm(),
                  icon: Icons.person_add_alt_outlined,
                ),
              ),
            ],
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: contacts.length,
          itemBuilder: (context, i) {
            final contact = contacts[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: MedilinkColors.blue.withValues(alpha: .1),
                      child: const Icon(Icons.person_outline, color: MedilinkColors.blue),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(contact['name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                              if (contact['isPrimary'] == true) ...[
                                const SizedBox(width: 8),
                                const StatusBadge(label: 'PRIMARY'),
                              ],
                            ],
                          ),
                          Text('${contact['phone'] ?? ''}${contact['relation'] != null ? ' · ${contact['relation']}' : ''}'),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') _openForm(existing: contact);
                        if (value == 'delete') _delete(contact['id'].toString());
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Remove')),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class _ContactForm extends ConsumerStatefulWidget {
  const _ContactForm({this.existing});
  final Map<String, dynamic>? existing;
  @override
  ConsumerState<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends ConsumerState<_ContactForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?['name']?.toString());
  late final _phone = TextEditingController(text: widget.existing?['phone']?.toString());
  late final _relation = TextEditingController(text: widget.existing?['relation']?.toString());
  bool _primary = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _primary = widget.existing?['isPrimary'] == true;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      if (widget.existing != null) {
        await api.updateEmergencyContact(widget.existing!['id'].toString(), {
          'name': _name.text.trim(),
          'phone': _phone.text.trim(),
          'relation': _relation.text.trim().isEmpty ? null : _relation.text.trim(),
          'isPrimary': _primary,
        });
      } else {
        await api.addEmergencyContact(
          name: _name.text.trim(),
          phone: _phone.text.trim(),
          relation: _relation.text.trim(),
          isPrimary: _primary,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.existing != null ? 'Edit contact' : 'Add emergency contact',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone (+countrycode...)'),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Phone is required';
              if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(v.trim())) return 'Use E.164 format, e.g. +919876543210';
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _relation,
            decoration: const InputDecoration(labelText: 'Relation (optional)'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _primary,
            onChanged: (v) => setState(() => _primary = v),
            title: const Text('Primary contact'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: const TextStyle(color: MedilinkColors.red)),
            ),
          PrimaryButton(label: 'Save', loading: _saving, onPressed: _save, icon: Icons.check),
        ],
      ),
    ),
  );
}
