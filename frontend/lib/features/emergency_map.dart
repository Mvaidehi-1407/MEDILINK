import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame;

class _EmergencyPin {
  _EmergencyPin(this.id, this.point, this.autoEscalated, this.status);
  final String id;
  final LatLng point;
  final bool autoEscalated;
  final String status;
}

/// Real map view (Phase 11/14): Hospital sees every active emergency with a captured GPS
/// location; Caregiver sees a single patient's live emergency pin. Both are backed by the
/// exact same real coordinates captured in Phase 6, not placeholders.
class EmergencyMapPage extends ConsumerStatefulWidget {
  const EmergencyMapPage({super.key, this.singlePatientId});
  /// When set, shows only that patient's active emergency (Caregiver use case).
  final String? singlePatientId;
  @override
  ConsumerState<EmergencyMapPage> createState() => _EmergencyMapPageState();
}

class _EmergencyMapPageState extends ConsumerState<EmergencyMapPage> {
  Future<List<_EmergencyPin>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<List<_EmergencyPin>> _fetchPins() async {
    final api = ref.read(apiClientProvider);
    final role = ref.read(sessionProvider).role;
    final myId = ref.read(sessionProvider).userId;
    List<Map<String, dynamic>> emergencies;
    if (widget.singlePatientId != null) {
      emergencies = await api.emergencies(widget.singlePatientId!);
    } else if (role == 'HOSPITAL') {
      emergencies = await api.activeEmergencies();
    } else if (role == 'CAREGIVER') {
      final consents = await api.list('/consents');
      final patientIds = consents.where((c) => c['status'] == 'GRANTED' && c['requesterId'] == myId).map((c) => c['patientId'].toString()).toSet();
      emergencies = [];
      for (final id in patientIds) {
        emergencies.addAll(await api.emergencies(id));
      }
    } else {
      emergencies = [];
    }
    final pins = <_EmergencyPin>[];
    for (final e in emergencies) {
      final location = e['location'];
      if (location is! Map) continue;
      final coords = location['coordinates'];
      if (coords is! List || coords.length != 2) continue;
      final lng = (coords[0] as num).toDouble();
      final lat = (coords[1] as num).toDouble();
      pins.add(_EmergencyPin(e['id'].toString(), LatLng(lat, lng), e['autoEscalated'] == true, e['status'].toString()));
    }
    return pins;
  }

  void _load() => setState(() => _future = _fetchPins());

  @override
  Widget build(BuildContext context) => PageFrame(
    title: widget.singlePatientId != null ? 'Patient location' : 'Emergency map',
    child: FutureBuilder<List<_EmergencyPin>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState();
        if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _load);
        final pins = snapshot.data!;
        if (pins.isEmpty) {
          return const EmptyState(
            title: 'No located emergencies',
            detail: 'A pin appears here once a real GPS location is captured on confirm.',
            icon: Icons.map_outlined,
          );
        }
        final center = pins.first.point;
        return FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 12),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.medilink',
            ),
            MarkerLayer(
              markers: pins.map((pin) => Marker(
                point: pin.point,
                width: 48,
                height: 48,
                child: Tooltip(
                  message: 'Emergency ${pin.id} · ${pin.status}${pin.autoEscalated ? ' · AUTO-ESCALATED' : ''}',
                  child: Icon(
                    Icons.location_on,
                    size: 40,
                    color: pin.autoEscalated ? MedilinkColors.red : MedilinkColors.blue,
                  ),
                ),
              )).toList(),
            ),
          ],
        );
      },
    ),
  );
}
