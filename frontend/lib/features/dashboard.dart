import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../widgets/common.dart';

void _open(BuildContext c, Widget p) =>
    Navigator.of(c).push(MaterialPageRoute(builder: (_) => p));

class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
  });
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      actions: actions,
    ),
    body: child,
  );
}

class RoleShell extends ConsumerStatefulWidget {
  const RoleShell({super.key});
  @override
  ConsumerState<RoleShell> createState() => _RoleShellState();
}

class _RoleShellState extends ConsumerState<RoleShell> {
  int index = 0;
  @override
  Widget build(BuildContext context) {
    final role = ref.watch(sessionProvider).role;
    final views = role == 'PATIENT'
        ? [
            const PatientHome(),
            const HealthPage(),
            const EmergencyPage(),
            const ConnectionsPage(),
            const ProfilePage(),
          ]
        : role == 'DOCTOR'
        ? [
            const RoleOverview('Doctor dashboard'),
            const PatientConnections(),
            const EmergencyList(),
            const ChatPage(),
            const ProfilePage(),
          ]
        : role == 'HOSPITAL'
        ? [
            const RoleOverview('Hospital command center'),
            const EmergencyList(),
            const PatientConnections(),
            const ProfilePage(),
          ]
        : [
            const RoleOverview('Caregiver home'),
            const PatientConnections(),
            const EmergencyList(),
            const ProfilePage(),
          ];
    final labels = role == 'PATIENT'
        ? ['Home', 'Health', 'Emergency', 'Connections', 'Profile']
        : role == 'DOCTOR'
        ? ['Home', 'Patients', 'Alerts', 'Messages', 'Profile']
        : role == 'HOSPITAL'
        ? ['Command', 'Emergencies', 'Patients', 'Profile']
        : ['Home', 'Patients', 'Alerts', 'Profile'];
    if (index >= views.length) index = 0;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const OfflineBanner(),
            Expanded(child: views[index]),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (v) => setState(() => index = v),
        destinations: labels
            .map((l) => NavigationDestination(icon: Icon(_icon(l)), label: l))
            .toList(),
      ),
    );
  }

  IconData _icon(String l) =>
      l == 'Emergency' || l == 'Emergencies' || l == 'Alerts'
      ? Icons.emergency_outlined
      : l == 'Health'
      ? Icons.monitor_heart_outlined
      : l == 'Profile'
      ? Icons.person_outline
      : l == 'Messages'
      ? Icons.chat_bubble_outline
      : l == 'Patients'
      ? Icons.groups_outlined
      : Icons.home_outlined;
}

class RoleOverview extends StatelessWidget {
  const RoleOverview(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => PageFrame(
    title: title,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionCard(
          child: Text(
            'Connected MEDILINK workspace. Statuses are shown only after the backend confirms them.',
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ActionTile(
              'Patients',
              Icons.groups_outlined,
              () => _open(context, const PatientConnections()),
            ),
            ActionTile(
              'Alerts',
              Icons.emergency_outlined,
              () => _open(context, const EmergencyList()),
            ),
            ActionTile(
              'Messages',
              Icons.chat_bubble_outline,
              () => _open(context, const ChatPage()),
            ),
            ActionTile(
              'Hospitals',
              Icons.local_hospital_outlined,
              () => _open(context, const HospitalsPage()),
            ),
          ],
        ),
      ],
    ),
  );
}

class ActionTile extends StatelessWidget {
  const ActionTile(this.label, this.icon, this.tap, {super.key});
  final String label;
  final IconData icon;
  final VoidCallback tap;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 112,
    height: 96,
    child: InkWell(
      onTap: tap,
      child: SectionCard(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: MedilinkColors.blue),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    ),
  );
}

final currentReadingProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, id) async {
      try {
        return await ref.read(apiClientProvider).currentReading(id);
      } on ApiException catch (e) {
        if (e.statusCode == 404) return null;
        rethrow;
      }
    });

class PatientHome extends ConsumerWidget {
  const PatientHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(sessionProvider).userId;
    return PageFrame(
      title: 'Good day',
      actions: [
        IconButton(
          onPressed: () => _open(context, const NotificationsPage()),
          icon: const Icon(Icons.notifications_none),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          HealthStatusCard(patientId: id),
          const SizedBox(height: 16),
          const SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI insight',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 8),
                Text(
                  'Your recent readings are within your configured monitoring range.',
                ),
                Text(
                  'Informational only.',
                  style: TextStyle(color: Colors.blueGrey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ActionTile(
                'Health',
                Icons.monitor_heart_outlined,
                () => _open(context, const HealthPage()),
              ),
              ActionTile(
                'Emergency',
                Icons.emergency_outlined,
                () => _open(context, const EmergencyPage()),
              ),
              ActionTile(
                'Vault',
                Icons.folder_copy_outlined,
                () => _open(context, const MedicalVaultPage()),
              ),
              ActionTile(
                'Hospitals',
                Icons.local_hospital_outlined,
                () => _open(context, const HospitalsPage()),
              ),
              ActionTile(
                'QR',
                Icons.qr_code_2_outlined,
                () => _open(context, const QrPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class HealthStatusCard extends ConsumerWidget {
  const HealthStatusCard({super.key, required this.patientId});
  final String patientId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(currentReadingProvider(patientId));
    return state.when(
      loading: () => const SectionCard(
        child: SizedBox(height: 150, child: LoadingState()),
      ),
      error: (e, s) => SectionCard(
        child: ErrorState(
          message: e.toString(),
          onRetry: () => ref.invalidate(currentReadingProvider(patientId)),
        ),
      ),
      data: (data) {
        final risk = data?['risk'] as Map?;
        return SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'HEALTH STATUS',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  StatusBadge(
                    label: risk?['riskLevel']?.toString() ?? 'STABLE',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '${data?['heartRate'] ?? '--'} BPM',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: MedilinkColors.blue,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'SpO2 ${data?['spo2'] ?? '--'}%   BP ${data?['systolicBP'] ?? '--'}/${data?['diastolicBP'] ?? '--'}   Temp ${data?['temperature'] ?? '--'} C',
              ),
              const SizedBox(height: 8),
              Text(
                'Last sync: ${data?['timestamp'] ?? 'No readings yet'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

class HealthPage extends ConsumerWidget {
  const HealthPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => PageFrame(
    title: 'Health',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        HealthStatusCard(patientId: ref.watch(sessionProvider).userId),
        const SizedBox(height: 16),
        const SectionCard(
          child: SizedBox(
            height: 130,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Health trends: 24H | 7D | 30D'),
                Icon(Icons.show_chart, size: 64, color: MedilinkColors.teal),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'BLE devices',
          onPressed: () => _open(context, const BlePage()),
          icon: Icons.bluetooth_outlined,
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _open(context, const SimulatorPage()),
          icon: const Icon(Icons.science_outlined),
          label: const Text('Open development simulator'),
        ),
      ],
    ),
  );
}

class SimulatorPage extends ConsumerStatefulWidget {
  const SimulatorPage({super.key});
  @override
  ConsumerState<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends ConsumerState<SimulatorPage> {
  String mode = 'NORMAL';
  bool sending = false;
  String? result;
  static const data = {
    'NORMAL': [72, 98, 120, 80],
    'WARNING': [110, 93, 145, 90],
    'HIGH_RISK': [145, 87, 170, 110],
  };
  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Health simulator',
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const StatusBadge(label: 'SIMULATED DATA'),
          const SizedBox(height: 16),
          const Text(
            'Development-only readings are submitted through the same backend pipeline as BLE data.',
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'NORMAL', label: Text('Normal')),
              ButtonSegment(value: 'WARNING', label: Text('Warning')),
              ButtonSegment(value: 'HIGH_RISK', label: Text('High risk')),
            ],
            selected: {mode},
            onSelectionChanged: (v) => setState(() => mode = v.first),
          ),
          const SizedBox(height: 20),
          Text(
            'HR ${data[mode]![0]} | SpO2 ${data[mode]![1]}% | BP ${data[mode]![2]}/${data[mode]![3]}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(result!),
            ),
          const Spacer(),
          PrimaryButton(
            label: 'Submit to monitoring pipeline',
            loading: sending,
            onPressed: _send,
            icon: Icons.send_outlined,
          ),
        ],
      ),
    ),
  );
  Future<void> _send() async {
    setState(() {
      sending = true;
      result = null;
    });
    try {
      final v = data[mode]!;
      final r = await ref.read(apiClientProvider).submitReading({
        'patientId': ref.read(sessionProvider).userId,
        'heartRate': v[0],
        'spo2': v[1],
        'systolicBP': v[2],
        'diastolicBP': v[3],
        'temperature': 36.8,
        'deviceId': 'development-simulator',
        'source': 'DEMO',
      });
      final reading = r['reading'] as Map;
      final emergency = r['emergency'] as Map?;
      setState(
        () => result =
            'Backend accepted reading. Risk: ${(reading['risk'] as Map?)?['riskLevel'] ?? 'UNKNOWN'}${r['emergency'] == null ? '' : '. Emergency verification started.'}',
      );
      if (emergency != null && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmergencyPage(emergencyId: emergency['id'].toString())));
      }
    } on ApiException catch (e) {
      setState(() => result = e.message);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }
}

class BlePage extends StatefulWidget {
  const BlePage({super.key});
  @override
  State<BlePage> createState() => _BlePageState();
}

class _BlePageState extends State<BlePage> {
  StreamSubscription<List<ScanResult>>? sub;
  List<ScanResult> devices = [];
  bool scanning = false;
  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  Future<void> scan() async {
    setState(() {
      scanning = true;
      devices = [];
    });
    sub = FlutterBluePlus.scanResults.listen((v) {
      if (mounted) setState(() => devices = v);
    });
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    await Future<void>.delayed(const Duration(seconds: 8));
    if (mounted) setState(() => scanning = false);
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Connected devices',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          child: ListTile(
            leading: Icon(
              scanning ? Icons.radar : Icons.bluetooth_outlined,
              color: MedilinkColors.blue,
            ),
            title: Text(
              scanning ? 'Searching for BLE devices' : 'No device connected',
            ),
            trailing: TextButton(
              onPressed: scanning ? null : scan,
              child: const Text('Scan'),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (devices.isEmpty && !scanning)
          const EmptyState(
            title: 'No nearby devices',
            detail: 'Turn on Bluetooth and scan for a compatible wearable.',
            icon: Icons.bluetooth_disabled,
          ),
        ...devices.map(
          (d) => SectionCard(
            child: ListTile(
              title: Text(
                d.device.platformName.isEmpty
                    ? 'Unnamed BLE device'
                    : d.device.platformName,
              ),
              subtitle: Text('Signal ${d.rssi} dBm'),
              trailing: TextButton(
                onPressed: () => d.device.connect(license: License.nonprofit),
                child: const Text('Connect'),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class EmergencyPage extends ConsumerStatefulWidget {
  const EmergencyPage({super.key, this.emergencyId});
  final String? emergencyId;
  @override
  ConsumerState<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends ConsumerState<EmergencyPage> {
  int seconds = 10;
  Timer? timer;
  bool busy = false;
  String? message;
  @override
  void initState() { super.initState(); if (widget.emergencyId != null) { timer = Timer.periodic(const Duration(seconds: 1), (value) { if (seconds == 0) { value.cancel(); _action('no-response'); } else if (mounted) { setState(() => seconds--); } }); } }
  @override
  void dispose() { timer?.cancel(); super.dispose(); }
  Future<void> _action(String action) async {
    if (widget.emergencyId == null || busy) return;
    timer?.cancel(); setState(() => busy = true);
    try {
      final body = action == 'cancel' ? {'patientResponse': 'IM_OK', 'reason': 'Patient confirmed safe'} : action == 'confirm' ? {'patientResponse': 'GET_HELP'} : null;
      final response = await ref.read(apiClientProvider).emergencyAction(widget.emergencyId!, action, body);
      if (mounted) setState(() => message = 'Emergency status: ${response['status']}');
    } on ApiException catch (error) { if (mounted) setState(() => message = error.message); } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => PageFrame(title: 'Emergency', child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    const Icon(Icons.emergency, size: 82, color: MedilinkColors.red), const SizedBox(height: 20), Text('POTENTIAL EMERGENCY', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, color: MedilinkColors.red)), const SizedBox(height: 12), const Text('An abnormal health pattern has been detected.', textAlign: TextAlign.center), if (widget.emergencyId != null) ...[const SizedBox(height: 16), Text('Verification countdown: $seconds', style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900))], const SizedBox(height: 20), PrimaryButton(label: "I'm OK", onPressed: widget.emergencyId == null ? () => Navigator.pop(context) : () => _action('cancel'), loading: busy, icon: Icons.check_circle_outline), const SizedBox(height: 12), SizedBox(width: double.infinity, height: 54, child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: MedilinkColors.red), onPressed: widget.emergencyId == null ? null : () => _action('confirm'), icon: const Icon(Icons.call), label: const Text('GET HELP'))), if (message != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(message!)), const SizedBox(height: 20), const Text('PRESS AND HOLD FOR SOS', style: TextStyle(fontWeight: FontWeight.w800, color: MedilinkColors.red))])));
}

class EmergencyList extends ConsumerWidget {
  const EmergencyList({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => PageFrame(
    title: 'Emergency alerts',
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: ref
          .read(apiClientProvider)
          .emergencies(ref.watch(sessionProvider).userId),
      builder: (c, s) {
        if (!s.hasData) return const LoadingState();
        if (s.data!.isEmpty)
          return const EmptyState(
            title: 'No emergency alerts',
            detail: 'Active and historical events will appear here.',
            icon: Icons.emergency_outlined,
          );
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: s.data!.length,
          itemBuilder: (c, i) {
            final e = s.data![i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                child: ListTile(
                  leading: const Icon(
                    Icons.emergency,
                    color: MedilinkColors.red,
                  ),
                  title: Text('Emergency ${e['id']}'),
                  subtitle: Text('Patient ${e['patientId']}'),
                  trailing: StatusBadge(label: e['status'].toString()),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class ConnectionsPage extends StatelessWidget {
  const ConnectionsPage({super.key});
  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Connections',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          child: ListTile(
            leading: const Icon(Icons.bluetooth_outlined),
            title: const Text('Connected devices'),
            onTap: () => _open(context, const BlePage()),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          child: ListTile(
            leading: const Icon(Icons.local_hospital_outlined),
            title: const Text('Nearby hospitals'),
            onTap: () => _open(context, const HospitalsPage()),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          child: ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Consent'),
            onTap: () => _open(context, const ConsentPage()),
          ),
        ),
      ],
    ),
  );
}

class HospitalsPage extends ConsumerStatefulWidget {
  const HospitalsPage({super.key});
  @override
  ConsumerState<HospitalsPage> createState() => _HospitalsPageState();
}

class _HospitalsPageState extends ConsumerState<HospitalsPage> {
  Future<List<Map<String, dynamic>>>? future;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    double lat = 17.385, lng = 78.4867;
    try {
      final p = await Geolocator.getCurrentPosition();
      lat = p.latitude;
      lng = p.longitude;
    } catch (_) {}
    if (mounted)
      setState(
        () => future = ref.read(apiClientProvider).nearbyHospitals(lat, lng),
      );
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Nearby hospitals',
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (c, s) {
        if (!s.hasData)
          return const LoadingState(label: 'Finding hospitals...');
        if (s.hasError)
          return ErrorState(message: s.error.toString(), onRetry: load);
        if (s.data!.isEmpty)
          return const EmptyState(
            title: 'No hospitals found',
            detail: 'Check location permission and try again.',
            icon: Icons.local_hospital_outlined,
          );
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: s.data!.length,
          itemBuilder: (c, i) {
            final h = s.data![i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                child: ListTile(
                  leading: const Icon(
                    Icons.local_hospital,
                    color: MedilinkColors.red,
                  ),
                  title: Text(h['name']?.toString() ?? 'Hospital'),
                  subtitle: Text(
                    '${(h['departments'] as List? ?? []).join(', ')}${h['demo'] == true ? '\nDemo facility' : ''}',
                  ),
                  trailing: StatusBadge(
                    label: h['emergencyAvailability'] == true
                        ? 'Available'
                        : 'Unavailable',
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

class MedicalVaultPage extends ConsumerWidget {
  const MedicalVaultPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => PageFrame(
    title: 'Medical vault',
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: ref.read(apiClientProvider).list('/medical-records'),
      builder: (c, s) {
        if (!s.hasData) return const LoadingState();
        if (s.data!.isEmpty)
          return const EmptyState(
            title: 'Your vault is empty',
            detail: 'Authorized GridFS records appear here.',
            icon: Icons.folder_open_outlined,
          );
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: s.data!.length,
          itemBuilder: (c, i) {
            final r = s.data![i];
            return SectionCard(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(r['filename']?.toString() ?? 'Medical record'),
                subtitle: Text('AI: ${r['summaryStatus'] ?? 'UNAVAILABLE'}'),
              ),
            );
          },
        );
      },
    ),
  );
}

class QrPage extends ConsumerStatefulWidget {
  const QrPage({super.key});
  @override
  ConsumerState<QrPage> createState() => _QrPageState();
}

class _QrPageState extends ConsumerState<QrPage> {
  String? token;
  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'QR center',
    child: Center(
      child: SectionCard(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'MY PROFILE QR',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 16),
              if (token != null)
                QrImageView(data: token!, size: 180)
              else
                const Icon(
                  Icons.qr_code_2,
                  size: 160,
                  color: MedilinkColors.blue,
                ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _create,
                child: const Text('Create profile QR'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> _create() async {
    final r = await ref
        .read(apiClientProvider)
        .post('/qr', body: {'purpose': 'PROFILE', 'expiresInMinutes': 15});
    if (mounted) setState(() => token = (r as Map)['token']?.toString());
  }
}

class ConsentPage extends ConsumerWidget {
  const ConsentPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => PageFrame(
    title: 'Consent',
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: ref.read(apiClientProvider).list('/consents'),
      builder: (c, s) {
        if (!s.hasData) return const LoadingState();
        if (s.data!.isEmpty)
          return const EmptyState(
            title: 'No consent requests',
            detail: 'Medical-data access remains consent based.',
            icon: Icons.privacy_tip_outlined,
          );
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: s.data!.length,
          itemBuilder: (c, i) {
            final x = s.data![i];
            final scopes = (x['requestedScopes'] as List? ?? []).join(', ');
            return SectionCard(
              child: ListTile(
                title: Text('Requester: ${x['requesterId']}'),
                subtitle: Text(scopes),
                trailing: StatusBadge(label: x['status'].toString()),
              ),
            );
          },
        );
      },
    ),
  );
}

class PatientConnections extends StatelessWidget {
  const PatientConnections({super.key});
  @override
  Widget build(BuildContext context) => const PageFrame(
    title: 'Patients',
    child: EmptyState(
      title: 'No patient connection selected',
      detail: 'Consent-approved patient records will appear here.',
      icon: Icons.groups_outlined,
    ),
  );
}

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});
  @override
  Widget build(BuildContext context) => const PageFrame(
    title: 'Messages',
    child: EmptyState(
      title: 'Select a conversation',
      detail: 'Messages are backed by the MEDILINK message API.',
      icon: Icons.chat_bubble_outline,
    ),
  );
}

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => PageFrame(
    title: 'Notifications',
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: ref.read(apiClientProvider).list('/notifications'),
      builder: (c, s) {
        if (!s.hasData) return const LoadingState();
        if (s.data!.isEmpty)
          return const EmptyState(
            title: 'No notifications',
            detail: 'Emergency, health, and system updates appear here.',
            icon: Icons.notifications_none,
          );
        return ListView.builder(
          itemCount: s.data!.length,
          itemBuilder: (c, i) => ListTile(
            title: Text(s.data![i]['title']?.toString() ?? 'MEDILINK update'),
          ),
        );
      },
    ),
  );
}

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).user ?? {};
    return PageFrame(
      title: 'Profile',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(user['name']?.toString() ?? 'MEDILINK user'),
              subtitle: Text('MEDILINK ID: ${user['id'] ?? ''}'),
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: SwitchListTile(
              value: ref.watch(sessionProvider).seniorMode,
              onChanged: (v) =>
                  ref.read(sessionProvider.notifier).setSeniorMode(v),
              title: const Text('Senior Mode'),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () async {
              await ref.read(sessionProvider.notifier).clear();
              if (context.mounted) context.go('/welcome');
            },
            icon: const Icon(Icons.logout),
            label: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}
