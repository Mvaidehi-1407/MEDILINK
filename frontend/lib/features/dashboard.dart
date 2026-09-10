import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/api_client.dart';
import '../core/crash_reporting.dart';
import '../core/native_comm_service.dart';
import '../core/realtime_service.dart';
import '../core/session.dart';
import '../core/vitals_simulator.dart';
import '../widgets/common.dart';
import 'contacts.dart';
import 'emergency_map.dart';
import 'find_hospitals.dart';
import 'medical_vault.dart';
import 'messaging.dart';
import 'patients.dart';

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
  RealtimeConnection? _escalationConnection;
  StreamSubscription? _escalationSubscription;
  String? _escalationPatientId;

  // The native SMS/call bridge must stay live for the entire patient session, not just while the
  // Home tab happens to be visible -- RoleShell swaps `views[index]` in and out of the tree on
  // every tab change (and pushed routes like the confirmation/simulator screens sit on top of
  // this same shell), so a listener living inside one tab's widget gets disposed the moment the
  // patient navigates away, silently dropping every escalation.attempt that arrives after that.
  void _ensureEscalationListener(String? role, String patientId) {
    if (role != 'PATIENT' || patientId.isEmpty) return;
    if (_escalationPatientId == patientId && _escalationConnection != null) return;
    _escalationSubscription?.cancel();
    _escalationConnection?.dispose();
    _escalationPatientId = patientId;
    _escalationConnection = RealtimeService(ref.read(sessionProvider.notifier), ref.read(apiClientProvider)).patientChannel(patientId);
    _escalationSubscription = _escalationConnection!.events.listen((event) {
      if (event['event'] != 'escalation.attempt') return;
      final data = Map<String, dynamic>.from(event['data'] as Map);
      final emergencyId = data['emergencyId']?.toString();
      if (emergencyId != null) {
        NativeCommService().handleEscalationAttempt(ref.read(apiClientProvider), emergencyId, data);
      }
    });
  }

  @override
  void dispose() {
    _escalationSubscription?.cancel();
    _escalationConnection?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final role = session.role;
    _ensureEscalationListener(role, session.userId);
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
            RoleOverview('Doctor dashboard', role: role),
            const PatientConnections(),
            const EmergencyList(),
            const ChatPage(),
            const ProfilePage(),
          ]
        : role == 'HOSPITAL'
        ? [
            RoleOverview('Hospital command center', role: role),
            const EmergencyList(),
            const PatientConnections(),
            const ChatPage(),
            const ProfilePage(),
          ]
        : [
            RoleOverview('Caregiver home', role: role),
            const PatientConnections(),
            const EmergencyList(),
            const ChatPage(),
            const ProfilePage(),
          ];
    final labels = role == 'PATIENT'
        ? ['Home', 'Health', 'Emergency', 'Connections', 'Profile']
        : role == 'DOCTOR'
        ? ['Home', 'Patients', 'Alerts', 'Messages', 'Profile']
        : role == 'HOSPITAL'
        ? ['Command', 'Emergencies', 'Patients', 'Messages', 'Profile']
        : ['Home', 'Patients', 'Alerts', 'Messages', 'Profile'];
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
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
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
  const RoleOverview(this.title, {super.key, required this.role});
  final String title;
  final String role;

  String get _blurb => switch (role) {
    'DOCTOR' => 'Your connected patients, alerts, and AI-assisted clinical summaries.',
    'HOSPITAL' => 'Incoming emergencies and the patients/doctors your facility is connected with.',
    _ => 'Your assigned patients and the emergency alerts that need your acknowledgement.',
  };

  @override
  Widget build(BuildContext context) => PageFrame(
    title: title,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(child: Text(_blurb)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ActionTile(
              role == 'HOSPITAL' ? 'Emergencies' : 'Patients',
              role == 'HOSPITAL' ? Icons.emergency_outlined : Icons.groups_outlined,
              () => _open(context, role == 'HOSPITAL' ? const EmergencyList() : const PatientConnections()),
            ),
            ActionTile(
              role == 'HOSPITAL' ? 'Patients' : 'Alerts',
              role == 'HOSPITAL' ? Icons.groups_outlined : Icons.emergency_outlined,
              () => _open(context, role == 'HOSPITAL' ? const PatientConnections() : const EmergencyList()),
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
            ActionTile(
              'Map',
              Icons.map_outlined,
              () => _open(context, const EmergencyMapPage()),
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
    height: 104,
    child: InkWell(
      onTap: tap,
      child: SectionCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: MedilinkColors.blue),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
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

class PatientHome extends ConsumerStatefulWidget {
  const PatientHome({super.key});
  @override
  ConsumerState<PatientHome> createState() => _PatientHomeState();
}

class _PatientHomeState extends ConsumerState<PatientHome> {
  RealtimeConnection? _connection;
  StreamSubscription? _subscription;
  String? _patientId;

  void _ensureSubscribed(String patientId) {
    if (_patientId == patientId && _connection != null) return;
    _subscription?.cancel();
    _connection?.dispose();
    _patientId = patientId;
    _connection = RealtimeService(ref.read(sessionProvider.notifier), ref.read(apiClientProvider)).patientChannel(patientId);
    // Live update reaches the UI with no manual refresh: any health.reading or
    // emergency.updated push from the backend invalidates the current-reading provider.
    // escalation.attempt is handled globally by RoleShell (which outlives this tab), not here --
    // see _RoleShellState._ensureEscalationListener.
    _subscription = _connection!.events.listen((event) {
      if (mounted) ref.invalidate(currentReadingProvider(patientId));
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = ref.watch(sessionProvider).userId;
    if (id.isNotEmpty) _ensureSubscribed(id);
    final reading = ref.watch(currentReadingProvider(id));
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
          AiInsightCard(reading: reading),
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
              // Existing home-screen hospital tile -- unchanged icon, label, colour and position.
              // Only its destination moved, from the backend-registered HospitalsPage to the
              // key-less OpenStreetMap "Find my hospital" search (Phase 21).
              ActionTile(
                'Hospitals',
                Icons.local_hospital_outlined,
                () => _open(context, const FindHospitalsPage()),
              ),
              ActionTile(
                'QR',
                Icons.qr_code_2_outlined,
                () => _open(context, const QrPage()),
              ),
              ActionTile(
                'Messages',
                Icons.chat_bubble_outline,
                () => _open(context, const ChatPage()),
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
                  if (data?['source'] == 'DEMO') ...[
                    const DevSimulatedBadge(),
                    const SizedBox(width: 8),
                  ],
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

class DevSimulatedBadge extends StatelessWidget {
  const DevSimulatedBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: MedilinkColors.amber.withValues(alpha: .15),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: MedilinkColors.amber.withValues(alpha: .4)),
    ),
    child: const Text(
      'DEV/SIMULATED',
      style: TextStyle(
        color: MedilinkColors.amber,
        fontWeight: FontWeight.w800,
        fontSize: 10,
      ),
    ),
  );
}

class AiInsightCard extends StatelessWidget {
  const AiInsightCard({super.key, required this.reading});
  final AsyncValue<Map<String, dynamic>?> reading;
  @override
  Widget build(BuildContext context) {
    return reading.when(
      loading: () => const SectionCard(
        child: SizedBox(height: 90, child: LoadingState(label: 'Analyzing...')),
      ),
      error: (e, s) => const SizedBox.shrink(),
      data: (data) {
        final risk = data?['risk'] as Map?;
        final recommendation = risk?['recommendation']?.toString();
        final engineUsed = risk?['engineUsed']?.toString();
        final isSimulated = data?['source'] == 'DEMO';
        return SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'AI insight',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (isSimulated) const DevSimulatedBadge(),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                recommendation ??
                    'No readings yet. Insight will appear once vitals are recorded.',
              ),
              if (engineUsed != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Engine: $engineUsed',
                  style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
                ),
              ],
              const Text(
                'Informational only. Not a medical diagnosis.',
                style: TextStyle(color: Colors.blueGrey),
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
  Widget build(BuildContext context, WidgetRef ref) {
    final devModeEnabled = ref.watch(sessionProvider).devModeEnabled;
    return PageFrame(
      title: 'Health',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          HealthStatusCard(patientId: ref.watch(sessionProvider).userId),
          const SizedBox(height: 16),
          const BleNoDeviceCard(),
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
          if (devModeEnabled) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _open(context, const SimulatorPage()),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Open development simulator (Dev Mode)'),
            ),
          ],
        ],
      ),
    );
  }
}

class SimulatorPage extends ConsumerStatefulWidget {
  const SimulatorPage({super.key});
  @override
  ConsumerState<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends ConsumerState<SimulatorPage> {
  final _engine = VitalsSimulatorEngine();
  SimulatedVitals? preview;
  bool sending = false;
  bool streaming = false;
  Timer? _streamTimer;
  String? result;
  // Guards against the periodic stream timer firing a new send while a confirmation page is
  // already open for this emergency -- without this every subsequent 5s tick (still returning
  // the same open emergency from the backend) would push a duplicate EmergencyPage on top.
  String? _shownEmergencyId;

  @override
  void initState() {
    super.initState();
    setState(() => preview = _engine.next());
  }

  @override
  void dispose() {
    _streamTimer?.cancel();
    super.dispose();
  }

  void _toggleStreaming(bool value) {
    setState(() => streaming = value);
    if (value) {
      _streamTimer = Timer.periodic(const Duration(seconds: 5), (_) => _send());
    } else {
      _streamTimer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = preview;
    return PageFrame(
      title: 'Health simulator',
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const DevSimulatedBadge(),
            const SizedBox(height: 16),
            const Text(
              'Development-only readings with realistic natural variation and occasional threshold-breaching '
              'spikes are submitted through the exact same /api/health pipeline a real BLE reading would use.',
            ),
            const SizedBox(height: 20),
            if (v != null) ...[
              Text(
                'HR ${v.heartRate} | SpO2 ${v.spo2}% | BP ${v.systolicBP}/${v.diastolicBP} | Temp ${v.temperature}C',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Generator regime: ${v.regime}',
                style: const TextStyle(color: Colors.blueGrey),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: streaming ? null : () => setState(() => preview = _engine.next()),
              icon: const Icon(Icons.refresh),
              label: const Text('Generate new reading'),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              value: streaming,
              onChanged: _toggleStreaming,
              title: const Text('Auto-stream every 5s'),
              subtitle: const Text('Mimics a continuously connected wearable pushing readings.'),
            ),
            if (result != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(result!),
              ),
            const Spacer(),
            PrimaryButton(
              label: streaming ? 'Streaming to monitoring pipeline...' : 'Submit to monitoring pipeline',
              loading: sending,
              onPressed: streaming ? null : _send,
              icon: Icons.send_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    // Don't fire a new reading while the previous one is still in flight, or while the
    // confirmation page is already open for an emergency this loop just created.
    if (sending || _shownEmergencyId != null) return;
    final v = preview ?? _engine.next();
    setState(() {
      sending = true;
      result = null;
    });
    try {
      final r = await ref.read(apiClientProvider).submitReading({
        'patientId': ref.read(sessionProvider).userId,
        'heartRate': v.heartRate,
        'spo2': v.spo2,
        'systolicBP': v.systolicBP,
        'diastolicBP': v.diastolicBP,
        'temperature': v.temperature,
        'deviceId': 'development-simulator',
        'source': 'DEMO',
      });
      final reading = r['reading'] as Map;
      final emergency = r['emergency'] as Map?;
      if (!mounted) return;
      setState(() {
        result =
            'Backend accepted reading. Risk: ${(reading['risk'] as Map?)?['riskLevel'] ?? 'UNKNOWN'}${r['emergency'] == null ? '' : '. Emergency verification started.'}';
        preview = _engine.next();
      });
      if (emergency != null && mounted) {
        final emergencyId = emergency['id'].toString();
        _shownEmergencyId = emergencyId;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmergencyPage(emergencyId: emergencyId)));
        _shownEmergencyId = null;
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => result = e.message);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }
}

/// One decoded vitals frame from a wearable. The BLE link carries newline-delimited JSON over the
/// Nordic UART service, so a frame that is truncated, malformed, or outside the ranges the backend
/// accepts (`HealthReadingCreate`) is dropped here rather than being submitted and rejected.
class BleVitals {
  const BleVitals({
    required this.heartRate,
    required this.spo2,
    required this.systolicBP,
    required this.diastolicBP,
    required this.temperature,
  });

  final int heartRate;
  final int spo2;
  final int systolicBP;
  final int diastolicBP;
  final double temperature;

  static BleVitals? tryParse(List<int> frame) {
    if (frame.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final heartRate = _int(decoded['heartRate'] ?? decoded['hr']);
    final spo2 = _int(decoded['spo2']);
    final systolic = _int(decoded['systolicBP'] ?? decoded['sys']);
    final diastolic = _int(decoded['diastolicBP'] ?? decoded['dia']);
    final temperature = _double(decoded['temperature'] ?? decoded['temp']);
    if (heartRate == null || spo2 == null || systolic == null || diastolic == null || temperature == null) {
      return null;
    }
    final inRange = heartRate > 0 && heartRate < 260 &&
        spo2 > 0 && spo2 <= 100 &&
        systolic > 0 && systolic < 300 &&
        diastolic > 0 && diastolic < 200 &&
        temperature > 30 && temperature < 45;
    if (!inRange) return null;
    return BleVitals(
      heartRate: heartRate,
      spo2: spo2,
      systolicBP: systolic,
      diastolicBP: diastolic,
      temperature: temperature,
    );
  }

  static int? _int(Object? value) => value is int ? value : (value is num ? value.round() : null);
  static double? _double(Object? value) => value is num ? value.toDouble() : null;

  String get summary =>
      'HR $heartRate | SpO2 $spo2% | BP $systolicBP/$diastolicBP | Temp ${temperature.toStringAsFixed(1)}C';
}

/// A BLE peripheral only sometimes tells us who it is: `platformName` is the GAP name the OS has
/// resolved (often empty until the device has been connected to once), and `advName` is the name
/// carried in the advertisement. Prefer the resolved name, fall back to the advertised one, and
/// never invent a placeholder that looks like a real name.
String bleDeviceName(BluetoothDevice device, {String? advertisedName}) {
  if (device.platformName.isNotEmpty) return device.platformName;
  if (device.advName.isNotEmpty) return device.advName;
  return advertisedName?.trim() ?? '';
}

/// What the patient sees. An anonymous peripheral is identified by its MAC/remote id so two of them
/// are still tellable apart -- "Unnamed BLE device" three times over is useless when picking a device.
String bleDeviceLabel(BluetoothDevice device, {String? advertisedName}) {
  final name = bleDeviceName(device, advertisedName: advertisedName);
  return name.isEmpty ? 'Unknown device — ${device.remoteId.str}' : name;
}

/// The MEDILINK wearable advertises under this prefix. Matching devices are pulled to the top of the
/// scan list and given a highlighted card, so the one device that matters is not lost among the
/// earbuds, watches and TVs that any real room full of BLE radios produces.
const bleTargetNamePrefix = 'MEDILINK';

bool isBleTargetDevice(BluetoothDevice device, {String? advertisedName}) =>
    bleDeviceName(device, advertisedName: advertisedName).toUpperCase().startsWith(bleTargetNamePrefix);

enum BleStatus { idle, connecting, discovering, streaming, reconnecting, failed }

class BleState {
  const BleState({
    this.device,
    this.deviceName,
    this.status = BleStatus.idle,
    this.message,
    this.lastVitals,
    this.lastSubmittedAt,
    this.retryAt,
  });

  final BluetoothDevice? device;
  /// Captured when the connection starts: a device dropped mid-session can stop reporting a name,
  /// and the connected card must not degrade into a bare MAC address while it is still streaming.
  final String? deviceName;
  final BleStatus status;
  final String? message;
  final BleVitals? lastVitals;
  final DateTime? lastSubmittedAt;
  /// When the next retry fires, during a backoff wait. The UI counts down to it so a 32-second
  /// wait never looks like a frozen screen.
  final DateTime? retryAt;

  bool get isBusy =>
      status == BleStatus.connecting || status == BleStatus.discovering || status == BleStatus.reconnecting;

  BleState copyWith({
    BluetoothDevice? device,
    String? deviceName,
    BleStatus? status,
    String? message,
    BleVitals? lastVitals,
    DateTime? lastSubmittedAt,
    DateTime? retryAt,
    bool clearMessage = false,
    bool clearRetryAt = false,
  }) => BleState(
    device: device ?? this.device,
    deviceName: deviceName ?? this.deviceName,
    status: status ?? this.status,
    message: clearMessage ? null : message ?? this.message,
    lastVitals: lastVitals ?? this.lastVitals,
    lastSubmittedAt: lastSubmittedAt ?? this.lastSubmittedAt,
    retryAt: clearRetryAt ? null : retryAt ?? this.retryAt,
  );
}

/// Owns the live wearable link. It deliberately lives in a provider rather than in `_BlePageState`:
/// the BLE page is a pushed route the patient closes as soon as the device is paired, and a device
/// handle or notification subscription held in that widget would be dropped on the next `dispose()`,
/// silently ending the vitals stream the monitoring pipeline depends on.
class BleController extends Notifier<BleState> {
  // The wearable exposes its vitals stream over the Nordic UART service, notifying newline-delimited
  // JSON frames on the TX characteristic.
  static final _vitalsServiceUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final _vitalsCharacteristicUuid = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');
  static const _connectTimeout = Duration(seconds: 10);
  static const _connectAttempts = 3;
  static const _reconnectAttempts = 6;
  static const _initialBackoff = Duration(seconds: 2);
  static const _maxBackoff = Duration(seconds: 32);
  // A wearable can notify several times a second; the monitoring pipeline is fed at the same
  // cadence as the simulator instead of once per notification.
  static const _minSubmitInterval = Duration(seconds: 5);
  static const _maxFrameBytes = 4096;

  StreamSubscription<List<int>>? _vitalsSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  final List<int> _frameBuffer = [];
  bool _disconnectRequested = false;
  bool _submitting = false;
  DateTime? _lastSubmitAt;

  @override
  BleState build() {
    ref.onDispose(_cancelSubscriptions);
    return const BleState();
  }

  Future<void> connect(BluetoothDevice device, {String? advertisedName}) async {
    if (state.isBusy) return;
    _cancelSubscriptions();
    _disconnectRequested = false;
    _lastSubmitAt = null;
    final name = bleDeviceLabel(device, advertisedName: advertisedName);
    state = BleState(
      device: device,
      deviceName: name,
      status: BleStatus.connecting,
      message: 'Checking Bluetooth permission...',
    );
    if (!await _ensureConnectPermission(name)) return;
    await _connectWithRetry(device, attempts: _connectAttempts, reconnecting: false);
  }

  /// Android 12+ (API 31+) gates every GATT operation behind the runtime BLUETOOTH_CONNECT
  /// permission. The manifest's `<uses-permission>` only declares intent -- it grants nothing by
  /// itself -- and without an explicit runtime request here, the OS denies the underlying native
  /// connect with no Dart-catchable exception: `device.connect()` just never completes or streams
  /// data, which reads to the patient as "I tapped Connect and nothing happened". This must run
  /// before every connect attempt (a permission can be revoked in Settings between taps), not only
  /// the first ever call.
  Future<bool> _ensureConnectPermission(String name) async {
    if (!Platform.isAndroid) return true;
    var result = await Permission.bluetoothConnect.status;
    debugPrint('BLE: BLUETOOTH_CONNECT status before connect = $result');
    if (!result.isGranted) {
      result = await Permission.bluetoothConnect.request();
      debugPrint('BLE: BLUETOOTH_CONNECT status after request = $result');
    }
    if (result.isGranted) return true;
    state = state.copyWith(
      status: BleStatus.failed,
      message: result.isPermanentlyDenied
          ? 'MEDILINK needs Bluetooth permission to connect to $name. Enable it in Settings > Apps > MEDILINK > Permissions, then try again.'
          : 'MEDILINK needs Bluetooth permission to connect to $name. Grant it when prompted, then try again.',
    );
    return false;
  }

  Future<void> disconnect() async {
    final device = state.device;
    _disconnectRequested = true;
    _cancelSubscriptions();
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    state = const BleState();
  }

  Future<void> _connectWithRetry(
    BluetoothDevice device, {
    required int attempts,
    required bool reconnecting,
  }) async {
    final name = state.deviceName ?? bleDeviceLabel(device);
    var backoff = _initialBackoff;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (_disconnectRequested) return;
      state = state.copyWith(
        status: reconnecting ? BleStatus.reconnecting : BleStatus.connecting,
        message: '${reconnecting ? 'Reconnecting to' : 'Connecting to'} $name '
            '(attempt $attempt of $attempts)...',
        clearRetryAt: true,
      );
      try {
        debugPrint('BLE: connect() attempt $attempt/$attempts -> ${device.remoteId.str} ($name)');
        await device.connect(license: License.nonprofit, timeout: _connectTimeout);
        debugPrint('BLE: connect() succeeded -> ${device.remoteId.str} ($name)');
        await _startVitalsStream(device);
        return;
      } catch (error, stackTrace) {
        // Always log the real error, not just the friendly message shown on screen -- this is
        // the only place a developer can see *why* a connect actually failed on a real device.
        debugPrint('BLE: connect() failed -> ${device.remoteId.str} ($name): $error');
        debugPrintStack(stackTrace: stackTrace, label: 'BLE connect error');
        // A failed connect can still leave a half-open link that blocks the next attempt.
        try {
          await device.disconnect();
        } catch (_) {}
        if (attempt == attempts || _disconnectRequested) {
          state = state.copyWith(
            status: BleStatus.failed,
            message: _friendlyError(error, name),
            clearRetryAt: true,
          );
          return;
        }
        // Publishing the retry deadline lets the screen count down through the backoff instead of
        // sitting on a motionless "connecting" for up to 32 seconds.
        state = state.copyWith(retryAt: DateTime.now().add(backoff));
        await Future<void>.delayed(backoff);
        backoff = backoff * 2 > _maxBackoff ? _maxBackoff : backoff * 2;
      }
    }
  }

  /// BLE plugin exceptions stringify into things like `FlutterBluePlusException | connect | ...`,
  /// which tells a patient nothing. Map the cases they can actually act on.
  static String _friendlyError(Object error, String name) {
    final text = error.toString().toLowerCase();
    if (error is TimeoutException || text.contains('timed out') || text.contains('timeout')) {
      return '$name did not respond in time. Move it closer to your phone and try again.';
    }
    if (text.contains('bluetooth must be turned on') || text.contains('adapter is off') || text.contains('poweredoff')) {
      return 'Bluetooth is off. Turn Bluetooth on, then connect again.';
    }
    if (text.contains('permission') || text.contains('unauthorized')) {
      return 'MEDILINK needs Bluetooth permission to reach $name. Grant it in Settings, then try again.';
    }
    if (text.contains('android-code: 133') || text.contains('connection failed')) {
      return 'Could not reach $name. Make sure it is switched on and not paired with another phone.';
    }
    return 'Could not connect to $name. Check that it is switched on and nearby, then try again.';
  }

  Future<void> _startVitalsStream(BluetoothDevice device) async {
    final name = state.deviceName ?? bleDeviceLabel(device);
    state = state.copyWith(
      status: BleStatus.discovering,
      message: 'Connected to $name. Reading its services...',
      clearRetryAt: true,
    );
    final services = await device.discoverServices();
    BluetoothCharacteristic? vitals;
    for (final service in services) {
      if (service.serviceUuid != _vitalsServiceUuid) continue;
      for (final characteristic in service.characteristics) {
        if (characteristic.characteristicUuid == _vitalsCharacteristicUuid &&
            (characteristic.properties.notify || characteristic.properties.indicate)) {
          vitals = characteristic;
        }
      }
    }
    if (vitals == null) {
      _disconnectRequested = true;
      try {
        await device.disconnect();
      } catch (_) {}
      state = state.copyWith(
        status: BleStatus.failed,
        message: '$name is not a MEDILINK vitals device — it does not publish readings this app can use.',
      );
      return;
    }
    _frameBuffer.clear();
    await vitals.setNotifyValue(true);
    _vitalsSubscription = vitals.onValueReceived.listen(_onNotification);
    _connectionSubscription = device.connectionState.listen((connectionState) {
      if (connectionState == BluetoothConnectionState.disconnected) _handleDisconnect(device);
    });
    state = state.copyWith(
      status: BleStatus.streaming,
      message: 'Receiving vitals from $name.',
      clearRetryAt: true,
    );
  }

  void _handleDisconnect(BluetoothDevice device) {
    if (_disconnectRequested || state.status == BleStatus.reconnecting) return;
    _cancelSubscriptions();
    _connectWithRetry(device, attempts: _reconnectAttempts, reconnecting: true);
  }

  void _onNotification(List<int> packet) {
    _frameBuffer.addAll(packet);
    var newline = _frameBuffer.indexOf(0x0a);
    while (newline != -1) {
      final frame = _frameBuffer.sublist(0, newline);
      _frameBuffer.removeRange(0, newline + 1);
      final vitals = BleVitals.tryParse(frame);
      if (vitals != null) _submit(vitals);
      newline = _frameBuffer.indexOf(0x0a);
    }
    // A device that never sends the delimiter must not grow this buffer without bound.
    if (_frameBuffer.length > _maxFrameBytes) _frameBuffer.clear();
  }

  /// Readings go through the same `/health/readings` submission the simulator uses -- identical
  /// body shape, labelled `source: BLE` instead of `DEMO`.
  Future<void> _submit(BleVitals vitals) async {
    final now = DateTime.now();
    if (_submitting) return;
    if (_lastSubmitAt != null && now.difference(_lastSubmitAt!) < _minSubmitInterval) {
      state = state.copyWith(lastVitals: vitals);
      return;
    }
    final patientId = ref.read(sessionProvider).userId;
    if (patientId.isEmpty) return;
    _submitting = true;
    _lastSubmitAt = now;
    try {
      await ref.read(apiClientProvider).submitReading({
        'patientId': patientId,
        'heartRate': vitals.heartRate,
        'spo2': vitals.spo2,
        'systolicBP': vitals.systolicBP,
        'diastolicBP': vitals.diastolicBP,
        'temperature': vitals.temperature,
        'deviceId': state.device?.remoteId.str ?? 'ble-device',
        'source': 'BLE',
      });
      state = state.copyWith(lastVitals: vitals, lastSubmittedAt: now, clearMessage: true);
      ref.invalidate(currentReadingProvider(patientId));
    } on ApiException catch (error) {
      state = state.copyWith(lastVitals: vitals, message: 'Reading not accepted: ${error.message}');
    } finally {
      _submitting = false;
    }
  }

  void _cancelSubscriptions() {
    _vitalsSubscription?.cancel();
    _vitalsSubscription = null;
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
  }
}

final bleProvider = NotifierProvider<BleController, BleState>(BleController.new);

/// How each connection state is presented. Deliberately reuses the app's existing colour language
/// rather than introducing a second one: teal is "monitoring is live" (as on the supervision-mode
/// badge), blue is neutral/in-progress, and amber is "needs your attention". Red is reserved
/// throughout MEDILINK for genuine danger -- a wearable that failed to pair is a setup problem, not
/// a medical emergency, and colouring it like one would blunt the emergency screens' own signal.
/// Every state carries an icon and a word, so the state never depends on colour alone.
({String label, IconData icon, Color color, bool inProgress}) bleStatusPresentation(BleStatus status) =>
    switch (status) {
      BleStatus.idle => (
          label: 'Not connected',
          icon: Icons.bluetooth_outlined,
          color: MedilinkColors.blue,
          inProgress: false,
        ),
      BleStatus.connecting => (
          label: 'Connecting',
          icon: Icons.bluetooth_searching,
          color: MedilinkColors.blue,
          inProgress: true,
        ),
      BleStatus.discovering => (
          label: 'Setting up',
          icon: Icons.settings_bluetooth,
          color: MedilinkColors.blue,
          inProgress: true,
        ),
      BleStatus.streaming => (
          label: 'Connected',
          icon: Icons.bluetooth_connected,
          color: MedilinkColors.teal,
          inProgress: false,
        ),
      BleStatus.reconnecting => (
          label: 'Reconnecting',
          icon: Icons.sync,
          color: MedilinkColors.amber,
          inProgress: true,
        ),
      BleStatus.failed => (
          label: 'Not connected',
          icon: Icons.error_outline,
          color: MedilinkColors.amber,
          inProgress: false,
        ),
    };

/// Icon + word + colour, matching `StatusBadge`/`EscalationStageBadge`. The label is never dropped,
/// so the state survives a colourblind reader and a screen reader alike.
class BleStatusBadge extends StatelessWidget {
  const BleStatusBadge({super.key, required this.status});
  final BleStatus status;

  @override
  Widget build(BuildContext context) {
    final presentation = bleStatusPresentation(status);
    return Semantics(
      label: 'Device status ${presentation.label}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: presentation.color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: presentation.color.withValues(alpha: .4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (presentation.inProgress)
              SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: presentation.color),
              )
            else
              Icon(presentation.icon, size: 14, color: presentation.color),
            const SizedBox(width: 6),
            Text(
              presentation.label,
              style: TextStyle(color: presentation.color, fontWeight: FontWeight.w700, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slow opacity pulse, used only where the app is genuinely waiting on something outside its
/// control. It honours the platform "reduce motion" setting, and it is calm on purpose: waiting for
/// a wearable during setup is normal, so this must not read like an alarm.
class BleWaitingPulse extends StatefulWidget {
  const BleWaitingPulse({super.key, required this.child});
  final Widget child;
  @override
  State<BleWaitingPulse> createState() => _BleWaitingPulseState();
}

class _BleWaitingPulseState extends State<BleWaitingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    return FadeTransition(
      opacity: Tween<double>(begin: .45, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// The vitals screen's answer to "why is nothing here?". Shown on the Health page whenever no
/// wearable is streaming, it states the situation plainly and offers the one action that fixes it,
/// without borrowing the emergency screens' red.
class BleNoDeviceCard extends ConsumerWidget {
  const BleNoDeviceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ble = ref.watch(bleProvider);
    final presentation = bleStatusPresentation(ble.status);
    final connected = ble.status == BleStatus.streaming;
    final waiting = connected && ble.lastVitals == null;
    final (title, detail) = connected
        ? waiting
              ? ('Waiting for device data...', 'Connected to ${ble.deviceName ?? 'your wearable'}. Readings appear here as they arrive.')
              : ('${ble.deviceName ?? 'Your wearable'} is sending readings', ble.lastVitals!.summary)
        : ble.isBusy
        ? (presentation.label, ble.message ?? 'Setting up your wearable...')
        : (
            'No device connected',
            ble.message ?? 'Connect a wearable to stream live vitals. Your health history stays available either way.',
          );
    final icon = Icon(presentation.icon, color: presentation.color, size: 28);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              waiting || ble.isBusy ? BleWaitingPulse(child: icon) : icon,
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              BleStatusBadge(status: ble.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
          if (ble.isBusy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 3),
          ],
          if (!connected) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
                onPressed: () => _open(context, const BlePage()),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Connect a device'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class BlePage extends ConsumerStatefulWidget {
  const BlePage({super.key});
  @override
  ConsumerState<BlePage> createState() => _BlePageState();
}

class _BlePageState extends ConsumerState<BlePage> {
  static const _scanDuration = Duration(seconds: 8);
  // Every tappable row and button on this screen clears the 44pt minimum touch target: the patient
  // may be using it one-handed, in a hurry, or with shaky hands.
  static const _minTouchTarget = 48.0;

  StreamSubscription<List<ScanResult>>? sub;
  List<ScanResult> devices = [];
  bool scanning = false;
  // Drives the retry countdown so a backoff wait always shows something moving.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(bleProvider).retryAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    _ticker?.cancel();
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
    await FlutterBluePlus.startScan(timeout: _scanDuration);
    await Future<void>.delayed(_scanDuration);
    if (mounted) setState(() => scanning = false);
  }

  /// The MEDILINK wearable first, then everything that at least told us its name, then the
  /// anonymous radios -- strongest signal first within each group.
  List<ScanResult> _sorted() {
    final sorted = [...devices];
    sorted.sort((a, b) {
      final aTarget = isBleTargetDevice(a.device, advertisedName: a.advertisementData.advName);
      final bTarget = isBleTargetDevice(b.device, advertisedName: b.advertisementData.advName);
      if (aTarget != bTarget) return aTarget ? -1 : 1;
      final aNamed = bleDeviceName(a.device, advertisedName: a.advertisementData.advName).isNotEmpty;
      final bNamed = bleDeviceName(b.device, advertisedName: b.advertisementData.advName).isNotEmpty;
      if (aNamed != bNamed) return aNamed ? -1 : 1;
      return b.rssi.compareTo(a.rssi);
    });
    return sorted;
  }

  /// The status of one scan row: the live connection state for the device we are talking to,
  /// `null` for every other row (which is simply available to connect to).
  BleStatus? _statusFor(ScanResult result, BleState ble) =>
      ble.device?.remoteId == result.device.remoteId ? ble.status : null;

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleProvider);
    final results = _sorted();
    return PageFrame(
      title: 'Connected devices',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _summaryCard(ble),
          const SizedBox(height: 16),
          if (results.isEmpty)
            scanning
                ? const SectionCard(
                    child: SizedBox(
                      height: 120,
                      child: LoadingState(label: 'Looking for nearby devices...'),
                    ),
                  )
                : const EmptyState(
                    title: 'No nearby devices',
                    detail: 'Turn on Bluetooth, make sure your wearable is switched on, then scan again.',
                    icon: Icons.bluetooth_disabled,
                  ),
          ...results.map((result) => _deviceCard(result, ble)),
        ],
      ),
    );
  }

  Widget _summaryCard(BleState ble) {
    final presentation = bleStatusPresentation(ble.status);
    final retryIn = ble.retryAt?.difference(DateTime.now()).inSeconds;
    final icon = Icon(presentation.icon, color: presentation.color, size: 28);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ble.isBusy ? BleWaitingPulse(child: icon) : icon,
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  ble.deviceName ?? (scanning ? 'Searching for devices' : 'No device connected'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              BleStatusBadge(status: ble.status),
            ],
          ),
          if (ble.message != null) ...[
            const SizedBox(height: 8),
            Text(ble.message!, style: Theme.of(context).textTheme.bodySmall),
          ],
          // Never leave a connection attempt sitting still: something on screen is always moving
          // while the app is waiting, and a backoff wait shows the seconds ticking down.
          if (ble.isBusy) ...[
            const SizedBox(height: 10),
            if (retryIn != null && retryIn > 0)
              Text(
                'Next attempt in ${retryIn}s...',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: MedilinkColors.amber),
              ),
            const SizedBox(height: 6),
            const LinearProgressIndicator(minHeight: 3),
          ],
          if (ble.lastVitals != null) ...[
            const SizedBox(height: 10),
            Text(ble.lastVitals!.summary, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              ble.lastSubmittedAt == null
                  ? 'Not submitted yet'
                  : 'Last submitted ${_clock(ble.lastSubmittedAt!)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(88, _minTouchTarget)),
                  onPressed: scanning ? null : scan,
                  icon: scanning
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar),
                  label: Text(scanning ? 'Scanning...' : 'Scan'),
                ),
              ),
              if (ble.device != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(88, _minTouchTarget),
                      foregroundColor: MedilinkColors.blue,
                    ),
                    onPressed: () => ref.read(bleProvider.notifier).disconnect(),
                    icon: const Icon(Icons.bluetooth_disabled),
                    label: const Text('Disconnect'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _deviceCard(ScanResult result, BleState ble) {
    final advertisedName = result.advertisementData.advName;
    final label = bleDeviceLabel(result.device, advertisedName: advertisedName);
    final named = bleDeviceName(result.device, advertisedName: advertisedName).isNotEmpty;
    final isTarget = isBleTargetDevice(result.device, advertisedName: advertisedName);
    final status = _statusFor(result, ble);
    final isConnected = status == BleStatus.streaming;
    final isBusyHere = status != null && ble.isBusy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        // The device the patient is actually looking for gets a highlighted card; the surrounding
        // BLE noise (earbuds, watches, TVs) stays visually quiet so it cannot be mistaken for it.
        decoration: isTarget
            ? BoxDecoration(
                color: MedilinkColors.teal.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: MedilinkColors.teal, width: 2),
              )
            : null,
        child: SectionCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    isTarget ? Icons.monitor_heart_outlined : Icons.bluetooth,
                    color: isTarget ? MedilinkColors.teal : Colors.blueGrey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isTarget || named ? FontWeight.w800 : FontWeight.w500,
                            color: named ? null : Colors.blueGrey,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isTarget
                              ? 'MEDILINK wearable · signal ${result.rssi} dBm'
                              : 'Signal ${result.rssi} dBm',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (status != null) BleStatusBadge(status: status),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: _minTouchTarget,
                child: isConnected
                    // Once connected the row stops offering "Connect" and offers the only useful
                    // action left, so the screen never shows a button that does nothing.
                    ? OutlinedButton.icon(
                        onPressed: () => ref.read(bleProvider.notifier).disconnect(),
                        icon: const Icon(Icons.bluetooth_disabled),
                        label: Text('Disconnect ${ble.deviceName ?? label}', overflow: TextOverflow.ellipsis),
                      )
                    : FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: isTarget ? MedilinkColors.teal : null,
                        ),
                        onPressed: ble.isBusy ? null : () => ref.read(bleProvider.notifier).connect(result.device, advertisedName: advertisedName),
                        icon: isBusyHere
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.link),
                        label: Text(isBusyHere ? bleStatusPresentation(ble.status).label : 'Connect'),
                      ),
              ),
              if (status == BleStatus.failed && ble.message != null) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: MedilinkColors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        ble.message!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: MedilinkColors.amber),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}

class EmergencyPage extends ConsumerStatefulWidget {
  const EmergencyPage({super.key, this.emergencyId});
  final String? emergencyId;
  @override
  ConsumerState<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends ConsumerState<EmergencyPage> {
  int seconds = 30;
  Timer? timer;
  Timer? hapticTimer;
  bool busy = false;
  bool loadingCountdown = true;
  String? message;
  String? callProviderMode;
  String? panicAttackType;
  String? emergencyStatus;
  Timer? sosHoldTimer;
  double sosHoldProgress = 0;
  bool sosSending = false;
  bool resolved = false;
  // Auto-resolve/cooldown state (mirrors the fields emergency_service.py stamps on the doc) --
  // drives the "N more normal readings" / "cooldown ends in..." indicators below.
  int? _consecutiveNormalReadings;
  int? _autoResolveThreshold;
  DateTime? _resolvedAt;
  int? _cooldownSeconds;
  Timer? _cooldownTicker;
  RealtimeConnection? _connection;
  StreamSubscription? _realtimeSubscription;
  static const _sosHoldDuration = Duration(milliseconds: 1800);
  // A manual SOS started from this same screen stays on this same widget instance instead of
  // navigating to a new route -- this page can be a bottom-nav tab (not just a pushed route), so
  // replacing the route would replace the whole app shell (bottom nav + Home's WebSocket
  // connection) out from under the escalation, breaking both navigation and the caretaker relay.
  String? _sosEmergencyId;
  String? get _activeId => widget.emergencyId ?? _sosEmergencyId;

  @override
  void initState() {
    super.initState();
    if (_activeId != null) {
      _loadCountdownAndStart();
      // Patient Confirmation must be impossible to miss (20.5/20.13) -- this is the one
      // screen in the app that deliberately breaks the "no decorative motion" rule with a
      // repeating haptic pulse, since a missed alert here is the worst possible outcome.
      hapticTimer = Timer.periodic(const Duration(milliseconds: 900), (_) => HapticFeedback.heavyImpact());
      HapticFeedback.heavyImpact();
      _subscribeRealtime();
    }
    ref.read(apiClientProvider).systemStatus().then((status) {
      if (mounted) setState(() => callProviderMode = status['callProviderMode']?.toString());
    }).catchError((_) {});
  }

  /// Keeps the auto-resolve/cooldown indicators live once the countdown screen is left behind --
  /// without this, an emergency that later auto-resolves server-side (vitals normalizing while
  /// CONFIRMED/ACKNOWLEDGED/RESPONDING) would leave this screen frozen on a stale status forever,
  /// since nothing else here re-fetches after the initial load.
  void _subscribeRealtime() {
    final patientId = ref.read(sessionProvider).userId;
    _realtimeSubscription?.cancel();
    _connection?.dispose();
    _connection = RealtimeService(ref.read(sessionProvider.notifier), ref.read(apiClientProvider)).patientChannel(patientId);
    _realtimeSubscription = _connection!.events.listen((event) {
      if (event['event'] != 'emergency.updated') return;
      final data = event['data'];
      if (data is Map && data['id']?.toString() == _activeId) {
        _applyEmergencyData(Map<String, dynamic>.from(data));
      }
    });
  }

  void _applyEmergencyData(Map<String, dynamic> data) {
    if (!mounted) return;
    final status = data['status']?.toString();
    setState(() {
      _consecutiveNormalReadings = (data['consecutiveNormalReadings'] as num?)?.toInt();
      _autoResolveThreshold = (data['autoResolveThreshold'] as num?)?.toInt();
      _cooldownSeconds = (data['cooldownSeconds'] as num?)?.toInt();
      final resolvedAtRaw = data['resolvedAt']?.toString();
      _resolvedAt = (resolvedAtRaw != null && resolvedAtRaw.isNotEmpty) ? DateTime.tryParse(resolvedAtRaw) : null;
      if (status != null) {
        emergencyStatus = status;
        resolved = status != 'VERIFICATION';
      }
    });
    if (resolved) {
      timer?.cancel();
      hapticTimer?.cancel();
      _startCooldownTicker();
    }
  }

  /// Ticks once a second so the "cooldown ends in Xs" text on the resolved screen counts down
  /// live instead of only updating on the next realtime push.
  void _startCooldownTicker() {
    _cooldownTicker?.cancel();
    if (_resolvedAt == null || (_cooldownSeconds ?? 0) <= 0) return;
    _cooldownTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _cooldownRemainingSeconds <= 0) {
        t.cancel();
        return;
      }
      setState(() {});
    });
  }

  int get _cooldownRemainingSeconds {
    if (_resolvedAt == null || _cooldownSeconds == null) return 0;
    final elapsed = DateTime.now().toUtc().difference(_resolvedAt!.toUtc()).inSeconds;
    return (_cooldownSeconds! - elapsed).clamp(0, _cooldownSeconds!);
  }

  static String _formatClock(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Future<void> _loadCountdownAndStart() async {
    // Reset from any previous emergency's countdown -- otherwise a leftover `seconds == 0` from
    // the last SOS would fire an immediate (and wrong) no-response on the very first tick here.
    seconds = 30;
    try {
      final emergency = await ref.read(apiClientProvider).getEmergency(_activeId!);
      panicAttackType = emergency['panicAttackType']?.toString();
      // If this screen is opened on an emergency that already moved past VERIFICATION (e.g. a
      // stale deep link, or reopening after the fact), don't start a countdown that would try
      // an invalid transition -- just show the resolved/current state, with its auto-resolve and
      // cooldown fields, exactly as a realtime push would.
      _applyEmergencyData(Map<String, dynamic>.from(emergency));
      final timeline = (emergency['timeline'] as List?) ?? const [];
      final verificationEvent = timeline.lastWhere(
        (e) => e is Map && e['event'] == 'VERIFICATION',
        orElse: () => null,
      );
      if (verificationEvent is Map) {
        final details = verificationEvent['details'];
        if (details is Map && details['countdownSeconds'] is int) {
          seconds = details['countdownSeconds'] as int;
        }
      }
    } catch (_) {
      // Keep the sane default (45s) if the emergency can't be fetched -- the countdown still
      // runs rather than stalling the patient-confirmation flow.
    }
    if (mounted) setState(() => loadingCountdown = false);
    if (resolved) return;
    timer = Timer.periodic(const Duration(seconds: 1), (value) {
      if (seconds == 0) {
        value.cancel();
        _action('no-response');
      } else if (mounted) {
        setState(() => seconds--);
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    hapticTimer?.cancel();
    sosHoldTimer?.cancel();
    _cooldownTicker?.cancel();
    _realtimeSubscription?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  void _startSosHold() {
    if (_activeId != null || sosSending) return;
    HapticFeedback.selectionClick();
    const tickMs = 60;
    var elapsed = 0;
    sosHoldTimer?.cancel();
    sosHoldTimer = Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      elapsed += tickMs;
      final progress = (elapsed / _sosHoldDuration.inMilliseconds).clamp(0.0, 1.0);
      if (mounted) setState(() => sosHoldProgress = progress);
      if (progress >= 1.0) {
        t.cancel();
        _triggerManualSos();
      }
    });
  }

  void _cancelSosHold() {
    sosHoldTimer?.cancel();
    if (mounted) setState(() => sosHoldProgress = 0);
  }

  void _backToHome() {
    timer?.cancel();
    hapticTimer?.cancel();
    if (widget.emergencyId != null) {
      // Opened as a pushed route for a specific emergency (e.g. from the dev vitals simulator) --
      // there's a real route to pop back to.
      Navigator.of(context).maybePop();
      return;
    }
    _cooldownTicker?.cancel();
    // Manual SOS on the Emergency tab itself -- this widget IS the tab, not a pushed route, so
    // "back to home" means resetting back to the pre-SOS screen in place.
    setState(() {
      _sosEmergencyId = null;
      resolved = false;
      message = null;
      emergencyStatus = null;
      seconds = 30;
      sosHoldProgress = 0;
      _consecutiveNormalReadings = null;
      _autoResolveThreshold = null;
      _resolvedAt = null;
      _cooldownSeconds = null;
    });
  }

  Future<void> _triggerManualSos() async {
    setState(() {
      sosSending = true;
      sosHoldProgress = 0;
    });
    HapticFeedback.heavyImpact();
    try {
      final patientId = ref.read(sessionProvider).userId;
      final created = await ref.read(apiClientProvider).createManualSos(patientId);
      final emergencyId = created['id']?.toString();
      if (mounted && emergencyId != null) {
        setState(() {
          _sosEmergencyId = emergencyId;
          resolved = false;
          message = null;
          emergencyStatus = null;
          loadingCountdown = true;
          _consecutiveNormalReadings = null;
          _autoResolveThreshold = null;
          _resolvedAt = null;
          _cooldownSeconds = null;
        });
        hapticTimer?.cancel();
        hapticTimer = Timer.periodic(const Duration(milliseconds: 900), (_) => HapticFeedback.heavyImpact());
        _subscribeRealtime();
        await _loadCountdownAndStart();
      }
    } on ApiException catch (e) {
      // 409 means the backend's dedup guard already found an open emergency (manual OR
      // AI-detected) for this patient -- show that exact reason rather than a generic "SOS
      // failed", so the tap never reads as having silently done nothing.
      if (mounted) setState(() => message = e.statusCode == 409 ? e.message : 'SOS failed: ${e.message}');
    } finally {
      if (mounted) setState(() => sosSending = false);
    }
  }

  Future<void> _action(String action) async {
    if (_activeId == null || busy || resolved) return;
    timer?.cancel();
    hapticTimer?.cancel();
    setState(() => busy = true);
    try {
      Map<String, dynamic>? body;
      if (action == 'cancel') {
        body = {'patientResponse': 'IM_OK', 'reason': 'Patient confirmed safe'};
      } else if (action == 'confirm') {
        body = {'patientResponse': 'NEED_HELP'};
        // Real device GPS, captured at confirm time -- no mocked/hardcoded coordinates.
        try {
          var permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          if (permission != LocationPermission.denied && permission != LocationPermission.deniedForever) {
            final position = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
            );
            body['location'] = {'latitude': position.latitude, 'longitude': position.longitude};
          }
        } catch (_) {
          // Location capture failed (permission denied / GPS off) -- confirm still proceeds
          // without coordinates rather than sending a fake location.
        }
      }
      final response = await ref.read(apiClientProvider).emergencyAction(_activeId!, action, body);
      if (!mounted) return;
      // VERIFICATION is the only status the confirm/cancel buttons apply to -- once it moves on
      // (CONFIRMED/CANCELLED/etc), stop offering actions that the backend will now correctly
      // reject as an invalid transition. Show the outcome ("You're marked safe at HH:MM:SS")
      // rather than silently reverting to the idle screen -- a resolved/cancelled event still
      // needs to be visibly confirmed, not just dismissed.
      _applyEmergencyData(Map<String, dynamic>.from(response));
    } on ApiException catch (error) {
      if (mounted) setState(() => message = error.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Emergency',
    child: Container(
      color: _activeId != null ? MedilinkColors.red.withValues(alpha: .06) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
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
  );

  List<Widget> _idleContent(BuildContext context) => [
    const Icon(Icons.shield_outlined, size: 82, color: MedilinkColors.blue),
    const SizedBox(height: 20),
    Text(
      'Emergency SOS',
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, color: MedilinkColors.blue),
    ),
    const SizedBox(height: 12),
    const Text(
      'Press and hold below if you need help. This starts the same verification and caretaker-calling flow as an automatically detected emergency.',
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: 28),
    GestureDetector(
      onTapDown: (_) => _startSosHold(),
      onTapUp: (_) => _cancelSosHold(),
      onTapCancel: _cancelSosHold,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: MedilinkColors.red.withValues(alpha: 0.08 + sosHoldProgress * 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MedilinkColors.red, width: 2),
        ),
        child: Column(
          children: [
            if (sosSending)
              const CircularProgressIndicator(color: MedilinkColors.red)
            else
              const Text('PRESS AND HOLD FOR SOS', style: TextStyle(fontWeight: FontWeight.w800, color: MedilinkColors.red)),
            if (sosHoldProgress > 0 && !sosSending) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: sosHoldProgress, color: MedilinkColors.red),
            ],
          ],
        ),
      ),
    ),
    if (message != null)
      Padding(padding: const EdgeInsets.only(top: 16), child: Text(message!)),
  ];

  List<Widget> _verifyingContent(BuildContext context) => [
    const Icon(Icons.emergency, size: 82, color: MedilinkColors.red),
    const SizedBox(height: 20),
    Text(
      'POTENTIAL EMERGENCY',
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, color: MedilinkColors.red),
    ),
    const SizedBox(height: 12),
    Text(
      panicAttackType != null && panicAttackType != 'NONE_DETECTED'
          ? 'Possible panic-attack pattern detected. This is decision-support information, not a diagnosis.'
          : 'An abnormal health pattern has been detected.',
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: 20),
    if (loadingCountdown)
      const CircularProgressIndicator()
    else
      Semantics(
        liveRegion: true,
        label: 'Confirmation countdown: $seconds seconds remaining',
        child: Text(
          '$seconds',
          style: Theme.of(context).textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w900, color: MedilinkColors.red, fontSize: 72),
        ),
      ),
    const Text('seconds to respond', style: TextStyle(fontWeight: FontWeight.w700)),
    const SizedBox(height: 24),
    PrimaryButton(
      label: "I'm OK",
      onPressed: () => _action('cancel'),
      loading: busy,
      icon: Icons.check_circle_outline,
    ),
    const SizedBox(height: 12),
    SizedBox(
      width: double.infinity,
      height: 54,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: MedilinkColors.red),
        onPressed: () => _action('confirm'),
        icon: const Icon(Icons.call),
        label: const Text('I NEED HELP'),
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Caretakers are called/texted from this phone\'s own SIM — keep it on and connected.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: MedilinkColors.amber),
      ),
    ),
    if (message != null)
      Padding(padding: const EdgeInsets.only(top: 16), child: Text(message!)),
  ];

  /// The confirmation screen's outcome depends entirely on which status the emergency actually
  /// landed in -- a safe outcome (CANCELLED/RESOLVED) must never look identical to an active one
  /// (CONFIRMED/HOSPITAL_ESCALATED) that's still calling caretakers.
  static const _safeStatuses = {'CANCELLED', 'RESOLVED'};

  List<Widget> _resolvedContent(BuildContext context) {
    final isSafe = _safeStatuses.contains(emergencyStatus);
    final color = isSafe ? MedilinkColors.teal : MedilinkColors.red;
    final (icon, title, body) = switch (emergencyStatus) {
      'CANCELLED' => (
          Icons.check_circle,
          "You're marked safe",
          'You confirmed you\'re OK. No caretakers were contacted for this alert.',
        ),
      'RESOLVED' => (
          Icons.check_circle,
          'Vitals back to normal',
          'Your readings returned to a normal range while under monitoring, so this alert was closed automatically.',
        ),
      'HOSPITAL_ESCALATED' => (
          Icons.local_hospital,
          'Escalated to hospital',
          'No caretaker acknowledged in time, so the nearest hospital command center has been notified with your location.',
        ),
      _ => (
          Icons.emergency,
          'EMERGENCY CONFIRMED',
          'Caretakers are being called and texted from this device. Keep it on and connected.',
        ),
    };
    return [
      Icon(icon, size: 82, color: color),
      const SizedBox(height: 20),
      Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, color: color),
      ),
      const SizedBox(height: 20),
      SectionCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(isSafe ? Icons.check_circle : Icons.info_outline, color: isSafe ? MedilinkColors.teal : MedilinkColors.amber, size: 40),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
              // A closed event must say so plainly -- "Emergency resolved at 14:32:05" -- rather
              // than the screen just quietly reverting, which reads as if nothing happened.
              if (isSafe) ...[
                const SizedBox(height: 8),
                Text(
                  '${emergencyStatus == 'CANCELLED' ? 'Marked safe' : 'Emergency resolved'} at ${_formatClock(_resolvedAt ?? DateTime.now())}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w800, color: MedilinkColors.teal),
                ),
              ],
              if (isSafe && _cooldownRemainingSeconds > 0) ...[
                const SizedBox(height: 6),
                Text(
                  'A new alert can trigger again in ${_cooldownRemainingSeconds}s.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (!isSafe && emergencyStatus != 'HOSPITAL_ESCALATED' && _autoResolveThreshold != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${((_autoResolveThreshold! - (_consecutiveNormalReadings ?? 0)).clamp(0, _autoResolveThreshold!))} more normal reading(s) needed to auto-resolve.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (message != null && message != body) ...[
                const SizedBox(height: 8),
                Text(message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: _backToHome,
        child: const Text('Back to home'),
      ),
    ];
  }
}

class EmergencyList extends ConsumerStatefulWidget {
  const EmergencyList({super.key});
  @override
  ConsumerState<EmergencyList> createState() => _EmergencyListState();
}

class _EmergencyListState extends ConsumerState<EmergencyList> {
  RealtimeConnection? _connection;
  StreamSubscription? _subscription;
  Future<List<Map<String, dynamic>>>? _future;
  bool _autoEscalatedOnly = false;

  @override
  void initState() {
    super.initState();
    final role = ref.read(sessionProvider).role;
    final api = ref.read(apiClientProvider);
    _future = role == 'HOSPITAL' ? api.activeEmergencies() : api.emergencies(ref.read(sessionProvider).userId);
    // Hospital command center subscribes to the hospital-wide channel; other roles subscribe
    // to their own patient channel so a new/updated emergency refreshes the list live.
    _connection = role == 'HOSPITAL'
        ? RealtimeService(ref.read(sessionProvider.notifier), ref.read(apiClientProvider)).hospitalChannel()
        : RealtimeService(ref.read(sessionProvider.notifier), ref.read(apiClientProvider)).patientChannel(ref.read(sessionProvider).userId);
    _subscription = _connection!.events.listen((event) {
      if (mounted && event['event'] == 'emergency.updated') _load();
    });
  }

  void _load() {
    final role = ref.read(sessionProvider).role;
    final api = ref.read(apiClientProvider);
    setState(() {
      _future = role == 'HOSPITAL' ? api.activeEmergencies() : api.emergencies(ref.read(sessionProvider).userId);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  Future<void> _acknowledge(String emergencyId) async {
    try {
      await ref.read(apiClientProvider).acknowledgeContactAlert(emergencyId);
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Closing an emergency isn't only bookkeeping: while one stays open the backend won't raise a
  /// new emergency for that patient, so the confirmation spells that out rather than presenting
  /// this as a cosmetic "mark done".
  Future<void> _resolve(String emergencyId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Resolve this emergency?'),
        content: const Text(
          'This closes the event for good. Until it is closed, this patient cannot be alerted '
          'for a new emergency. Only resolve it once the situation has actually been handled.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Resolve')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await ref.read(apiClientProvider).resolveEmergency(emergencyId, notes: 'Resolved from hospital command center.');
      _load();
      if (mounted) {
        final resolvedAtRaw = updated['resolvedAt']?.toString();
        final resolvedAt = (resolvedAtRaw != null && resolvedAtRaw.isNotEmpty) ? DateTime.tryParse(resolvedAtRaw) : null;
        // A clear confirmation state, not a silent list refresh -- staff need to see the action
        // actually landed, and when, since it's what frees this patient for a future alert.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Emergency resolved at ${_EmergencyPageState._formatClock(resolvedAt ?? DateTime.now())}'),
        ));
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.read(sessionProvider).role;
    return PageFrame(
      title: 'Emergency alerts',
      child: Column(
        children: [
          if (role == 'HOSPITAL')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  label: const Text('Auto-escalated only'),
                  selected: _autoEscalatedOnly,
                  onSelected: (v) => setState(() => _autoEscalatedOnly = v),
                ),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (c, s) {
          if (s.connectionState == ConnectionState.waiting) return const LoadingState();
          if (s.hasError) {
            return ErrorState(message: s.error.toString(), onRetry: _load);
          }
          final data = _autoEscalatedOnly ? s.data!.where((e) => e['autoEscalated'] == true).toList() : s.data!;
          if (data.isEmpty) {
            return const EmptyState(
              title: 'No emergency alerts',
              detail: 'Active and historical events will appear here.',
              icon: Icons.emergency_outlined,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: data.length,
            itemBuilder: (c, i) {
              final e = data[i];
              final autoEscalated = e['autoEscalated'] == true;
              final canAcknowledge = role == 'CAREGIVER' &&
                  e['escalationStage'] == 'CONTACT_NOTIFIED' &&
                  e['contactAcknowledgedAt'] == null;
              // Mirrors the backend: /resolve is hospital-only, and the state machine allows
              // RESOLVED only from these three statuses.
              final canResolve = role == 'HOSPITAL' &&
                  const {'CONFIRMED', 'ACKNOWLEDGED', 'RESPONDING'}.contains(e['status'].toString());
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.emergency,
                          color: autoEscalated ? MedilinkColors.red : MedilinkColors.blue,
                        ),
                        title: Row(
                          children: [
                            Expanded(child: Text('Emergency ${e['id']}')),
                            if (autoEscalated) ...[
                              const Icon(Icons.priority_high, size: 16, color: MedilinkColors.red),
                              const Text(' AUTO-ESCALATED', style: TextStyle(color: MedilinkColors.red, fontWeight: FontWeight.w800, fontSize: 11)),
                            ],
                          ],
                        ),
                        subtitle: Text('Patient ${e['patientId']}${e['panicAttackType'] != null && e['panicAttackType'] != 'NONE_DETECTED' ? ' · ${e['panicAttackType']}' : ''}'),
                        trailing: Wrap(
                          spacing: 6,
                          children: [
                            StatusBadge(label: e['status'].toString()),
                            if (e['escalationStage'] != null)
                              EscalationStageBadge(status: e['status'].toString(), escalationStage: e['escalationStage'].toString()),
                          ],
                        ),
                      ),
                      if (canAcknowledge)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _acknowledge(e['id'].toString()),
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('Acknowledge alert'),
                          ),
                        ),
                      if (canResolve)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _resolve(e['id'].toString()),
                            icon: const Icon(Icons.task_alt),
                            label: const Text('Resolve emergency'),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
            ),
          ),
        ],
      ),
    );
  }
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
        const SizedBox(height: 12),
        SectionCard(
          child: ListTile(
            leading: const Icon(Icons.contact_phone_outlined),
            title: const Text('Emergency contacts'),
            subtitle: const Text('Who gets called/texted first in a confirmed emergency'),
            onTap: () => _open(context, const ContactsPage()),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          child: ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Messages'),
            subtitle: const Text('Chat with your connected doctors and caregivers'),
            onTap: () => _open(context, const ChatPage()),
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
              if (_createError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_createError!, style: const TextStyle(color: MedilinkColors.red)),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const QrScanPage()),
                ),
                icon: const Icon(Icons.qr_code_scanner_outlined),
                label: const Text('Scan someone\'s QR'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  String? _createError;
  Future<void> _create() async {
    setState(() => _createError = null);
    try {
      final r = await ref
          .read(apiClientProvider)
          .post('/qr', body: {'purpose': 'PROFILE', 'expiresInMinutes': 15});
      if (mounted) setState(() => token = (r as Map)['token']?.toString());
    } catch (e) {
      if (mounted) setState(() => _createError = 'Could not create a QR code. Check your connection and try again.');
    }
  }
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
    try {
      final result = await ref.read(apiClientProvider).get('/qr/$raw');
      if (result is! Map) throw const FormatException('Unexpected response');
      setState(() => _info = Map<String, dynamic>.from(result));
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _handled = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not read that QR code. Try scanning again.';
        _handled = false;
      });
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
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: const TextStyle(color: MedilinkColors.red)),
                ),
              Expanded(child: MobileScanner(onDetect: _onDetect)),
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
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
            title: Text(patient?['name']?.toString() ?? 'Unknown patient'),
            subtitle: Text([
              if (patient?['age'] != null) 'Age ${patient!['age']}',
              if (patient?['phone'] != null) patient!['phone'].toString(),
            ].join(' · ')),
          ),
        ),
        const SizedBox(height: 16),
        Text('Emergency contacts', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (contacts.isEmpty)
          const Text('No emergency contacts on file.')
        else
          ...contacts.map((c) => SectionCard(
                child: ListTile(
                  leading: const Icon(Icons.phone_outlined),
                  title: Text(c['name']?.toString() ?? ''),
                  subtitle: Text(c['phone']?.toString() ?? ''),
                ),
              )),
        const SizedBox(height: 16),
        Text('Document summaries', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (documents.isEmpty)
          const Text('No AI-summarized documents on file.')
        else
          ...documents.map((d) {
            final summary = d['summary'] as Map?;
            final observations = (summary?['keyObservations'] as List?) ?? [];
            final explanation = summary?['simplifiedExplanation']?.toString() ?? '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d['filename']?.toString() ?? 'Document', style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (observations.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(observations.join('\n')),
                      ],
                      if (explanation.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(explanation, style: const TextStyle(fontStyle: FontStyle.italic)),
                      ],
                      if (summary?['disclaimer'] != null) ...[
                        const SizedBox(height: 6),
                        Text(summary!['disclaimer'].toString(), style: const TextStyle(color: Colors.blueGrey, fontSize: 11)),
                      ],
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }
}

class ConsentPage extends ConsumerStatefulWidget {
  const ConsentPage({super.key});
  @override
  ConsumerState<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends ConsumerState<ConsentPage> {
  Future<List<Map<String, dynamic>>>? _future;
  final Map<String, String> _namesById = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<List<Map<String, dynamic>>> _fetchConsents() async {
    final api = ref.read(apiClientProvider);
    final role = ref.read(sessionProvider).role;
    final consents = await api.list('/consents');
    for (final c in consents) {
      final otherId = (role == 'PATIENT' ? c['requesterId'] : c['patientId'])?.toString();
      if (otherId != null && !_namesById.containsKey(otherId)) {
        try {
          final user = await api.get('/users/$otherId') as Map?;
          if (user != null) _namesById[otherId] = user['name']?.toString() ?? otherId;
        } catch (_) {
          _namesById[otherId] = otherId;
        }
      }
    }
    return consents;
  }

  void _load() => setState(() => _future = _fetchConsents());

  Future<void> _respond(String consentId, String action) async {
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).post('/consents/$consentId/$action');
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectToPatient() async {
    final role = ref.read(sessionProvider).role;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _ConnectDialog(role: role),
    );
    if (result != null && mounted) {
      _load();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.read(sessionProvider).role;
    return PageFrame(
      title: 'Consent',
      actions: role != 'PATIENT'
          ? [IconButton(icon: const Icon(Icons.person_add_alt_outlined), onPressed: _connectToPatient)]
          : const [],
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (c, s) {
          if (s.connectionState == ConnectionState.waiting) return const LoadingState();
          if (!s.hasData || s.data!.isEmpty) {
            return EmptyState(
              title: 'No consent requests',
              detail: role == 'PATIENT'
                  ? 'When a doctor or caregiver requests access, it will show up here to grant or reject.'
                  : 'Tap the + icon above to request access to a patient by their email or phone.',
              icon: Icons.privacy_tip_outlined,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: s.data!.length,
            itemBuilder: (c, i) {
              final x = s.data![i];
              final scopes = (x['requestedScopes'] as List? ?? []).join(', ');
              final otherId = (role == 'PATIENT' ? x['requesterId'] : x['patientId'])?.toString();
              final otherName = _namesById[otherId] ?? otherId ?? 'Unknown';
              final isPatientAndPending = role == 'PATIENT' && x['status'] == 'REQUESTED';
              return SectionCard(
                child: ListTile(
                  title: Text(otherName),
                  subtitle: Text(scopes.isEmpty ? (x['purpose']?.toString() ?? '') : scopes),
                  trailing: isPatientAndPending
                      ? Wrap(spacing: 8, children: [
                          TextButton(
                            onPressed: _busy ? null : () => _respond(x['id'].toString(), 'reject'),
                            child: const Text('Reject'),
                          ),
                          PrimaryButton(
                            label: 'Grant',
                            loading: _busy,
                            onPressed: () => _respond(x['id'].toString(), 'grant'),
                          ),
                        ])
                      : StatusBadge(label: x['status'].toString()),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ConnectDialog extends ConsumerStatefulWidget {
  const _ConnectDialog({required this.role});
  final String role;
  @override
  ConsumerState<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends ConsumerState<_ConnectDialog> {
  final _identifier = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    final value = _identifier.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final matches = await api.list('/users/search', query: {'identifier': value, 'role': 'PATIENT'});
      if (matches.isEmpty) {
        setState(() => _error = 'No patient found with that email or phone.');
        return;
      }
      final patient = matches.first;
      final myId = ref.read(sessionProvider).userId;
      await api.post('/consents/request', body: {
        'patientId': patient['id'],
        'requesterId': myId,
        'requestedScopes': ['VITALS', 'RECORDS'],
        'purpose': 'Care coordination request',
      });
      if (mounted) Navigator.of(context).pop('Request sent to ${patient['name']}. They must grant it before you see their data.');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect with a patient'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Enter the patient\'s registered email or phone number.'),
        const SizedBox(height: 12),
        TextField(
          controller: _identifier,
          decoration: const InputDecoration(labelText: 'Email or phone number'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: MedilinkColors.red)),
          ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      PrimaryButton(label: 'Send request', loading: _loading, onPressed: _submit),
    ],
  );
}

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<List<Map<String, dynamic>>> _fetchContacts() async {
    final api = ref.read(apiClientProvider);
    final myId = ref.read(sessionProvider).userId;
    final role = ref.read(sessionProvider).role;
    final consents = await api.list('/consents');
    // Patients see their connected clinicians/caregivers; Doctors/Caregivers see their patients.
    final relevant = role == 'PATIENT'
        ? consents.where((c) => c['status'] == 'GRANTED' && c['patientId'] == myId)
        : consents.where((c) => c['status'] == 'GRANTED' && c['requesterId'] == myId);
    final otherPartyIds = relevant.map((c) => role == 'PATIENT' ? c['requesterId'] : c['patientId']).toSet();
    final contacts = <Map<String, dynamic>>[];
    for (final id in otherPartyIds) {
      try {
        final user = await api.get('/users/$id') as Map?;
        if (user != null) contacts.add(Map<String, dynamic>.from(user));
      } catch (_) {}
    }
    return contacts;
  }

  void _load() => setState(() => _future = _fetchContacts());

  @override
  Widget build(BuildContext context) {
    final myId = ref.read(sessionProvider).userId;
    return PageFrame(
      title: 'Messages',
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState();
          if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _load);
          final contacts = snapshot.data!;
          if (contacts.isEmpty) {
            return const EmptyState(
              title: 'No conversations yet',
              detail: 'Once you have a granted consent connection, you can message them here.',
              icon: Icons.chat_bubble_outline,
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
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                    title: Text(contact['name']?.toString() ?? 'Contact'),
                    subtitle: Text(contact['role']?.toString() ?? ''),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ConversationPage(
                        conversationId: conversationIdFor(myId, contact['id'].toString()),
                        otherPartyId: contact['id'].toString(),
                        title: contact['name']?.toString() ?? 'Conversation',
                      ),
                    )),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
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
          const SizedBox(height: 16),
          SectionCard(
            child: SwitchListTile(
              value: ref.watch(sessionProvider).devModeEnabled,
              onChanged: (v) =>
                  ref.read(sessionProvider.notifier).setDevMode(v),
              title: const Text('Dev Mode'),
              subtitle: const Text(
                'Reveals the vitals simulator for testing. Simulated readings are always labeled DEV/SIMULATED and never replace real BLE data.',
              ),
            ),
          ),
          if (ref.watch(sessionProvider).devModeEnabled) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: MedilinkColors.red),
              onPressed: () => CrashReporting.forceTestCrash(),
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Force test crash (Crashlytics)'),
            ),
          ],
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
