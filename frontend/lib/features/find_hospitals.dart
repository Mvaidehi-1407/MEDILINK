import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/common.dart';
import 'dashboard.dart' show PageFrame;

/// "Find My Hospital" (Phase 21): key-less, billing-free nearby-hospital search.
///
/// Everything here runs on free, no-key services -- OpenStreetMap's Overpass API for the data,
/// OSM raster tiles for the map, and a plain Google Maps universal link for directions. No Google
/// Maps SDK, no API key, no billing account.
///
/// This file is standalone: it does not touch the emergency/escalation or calling paths. It only
/// reuses the same GPS/permission pattern the emergency dispatch confirm step already uses.

/// Public Overpass endpoints, tried in order. The retry after a failure deliberately switches
/// hosts -- overpass-api.de's usual failure mode is rate-limiting or a queued slot, and an
/// immediate retry against the same host fails the same way.
///
/// Mirror health was measured before picking these, and it matters: the obvious mirror
/// (overpass.kumi.systems) is currently dead, returning 504 after 33s, and overpass.osm.jp does
/// not resolve at all. Both were rejected. private.coffee answers the app's own query in ~1.8s,
/// matching the primary.
const _overpassEndpoints = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

/// Top of the 8-10s budget. Every second here is a second a stressed user spends watching a
/// skeleton, but too tight a deadline turns a merely slow answer into a false error -- and on
/// mobile data the TLS handshake alone can eat a second before the query starts.
const _overpassTimeout = Duration(seconds: 10);

/// What Overpass itself is told it may spend. Deliberately a little under the client deadline so
/// the server gives up first and returns a real error, rather than the client walking away from a
/// query the server is still running.
const _overpassServerBudgetSeconds = 8;

/// Search radii, in metres. The empty state walks the user up this ladder one step at a time.
const _radiusLadder = [5000, 10000, 25000, 50000];

/// Above this horizontal accuracy (metres) the fix is too coarse to trust for a "nearby" search,
/// so the screen says so instead of presenting distances computed from a bad centre.
const _poorAccuracyMetres = 100.0;

class Hospital {
  const Hospital({
    required this.id,
    required this.name,
    required this.point,
    required this.distanceMetres,
    this.address,
    this.phone,
    this.emergency = false,
  });

  final String id;
  final String name;
  final LatLng point;
  final double distanceMetres;

  /// Null when OpenStreetMap has no usable address tags for this entry. OSM is community
  /// maintained and plenty of hospitals carry only a name and a location, so the UI must render
  /// this absence as "nothing at all" -- never as "null" or a blank line.
  final String? address;
  final String? phone;

  /// `emergency=yes` on the OSM entry. Informational only -- absence does not mean "no A&E",
  /// it usually just means nobody tagged it, so the UI never presents this as a negative.
  final bool emergency;

  String get distanceLabel => distanceMetres < 1000
      ? '${distanceMetres.round()} m away'
      : '${(distanceMetres / 1000).toStringAsFixed(1)} km away';
}

/// How a load failed. The screen must never show the same thing for "your phone has no
/// connection" and "Overpass didn't answer" -- the first is fixed by reconnecting, the second by
/// retrying, and conflating them leaves the user guessing.
enum HospitalSearchFailure {
  noInternet,
  serverUnreachable,
  locationPermissionDenied,
  locationServicesOff,
  locationUnavailable,
}

class HospitalSearchException implements Exception {
  const HospitalSearchException(this.kind);
  final HospitalSearchFailure kind;
}

/// A resolved GPS fix plus the accuracy the OS reported for it.
class LocationFix {
  const LocationFix(this.point, this.accuracyMetres);
  final LatLng point;
  final double accuracyMetres;
  bool get isCoarse => accuracyMetres > _poorAccuracyMetres;
}

/// Same permission handshake the emergency dispatch confirm step uses, with high-accuracy GPS
/// requested explicitly: a network/low-power fix can land kilometres away, which would silently
/// centre the whole search on the wrong neighbourhood.
Future<LocationFix> resolveLocationFix() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const HospitalSearchException(HospitalSearchFailure.locationServicesOff);
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
    throw const HospitalSearchException(HospitalSearchFailure.locationPermissionDenied);
  }
  try {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LocationFix(LatLng(position.latitude, position.longitude), position.accuracy);
  } catch (_) {
    throw const HospitalSearchException(HospitalSearchFailure.locationUnavailable);
  }
}

String buildOverpassQuery(LatLng centre, int radiusMetres) {
  final lat = centre.latitude;
  final lng = centre.longitude;
  final around = '$radiusMetres,$lat,$lng';
  // Ways and relations carry no coordinates of their own, so `out center` is what makes a mapped
  // hospital *building* usable as a point. Both amenity=hospital and healthcare=hospital are
  // queried because OSM tagging practice varies by region.
  //
  // The server-side `timeout:` must not exceed the client's own deadline. It used to say 25s
  // while the client gave up at 9, so Overpass would still be working on a query nobody was
  // listening for any more -- burning one of the caller's few rate-limit slots and guaranteeing
  // the retry got throttled too.
  //
  // `out ... 60` caps the result set. Uncapped, this query returns ~120KB for a dense city;
  // capped it returns ~25KB for the same area with no loss of usable results, since the list is
  // distance-sorted and nobody scrolls to the 60th nearest hospital. On mobile data that is the
  // difference between comfortably inside the deadline and not.
  return '''
[out:json][timeout:$_overpassServerBudgetSeconds];
(
  node["amenity"="hospital"](around:$around);
  way["amenity"="hospital"](around:$around);
  relation["amenity"="hospital"](around:$around);
  node["healthcare"="hospital"](around:$around);
  way["healthcare"="hospital"](around:$around);
);
out center tags 60;
''';
}

/// Builds a one-line address from whatever `addr:*` tags the entry happens to have. Returns null
/// -- not an empty or placeholder string -- when there is nothing real to show.
String? addressFromTags(Map<String, dynamic> tags) {
  final full = tags['addr:full']?.toString().trim();
  if (full != null && full.isNotEmpty) return full;
  final parts = [
    [tags['addr:housenumber'], tags['addr:street']]
        .where((p) => p != null && p.toString().trim().isNotEmpty)
        .map((p) => p.toString().trim())
        .join(' '),
    tags['addr:suburb'],
    tags['addr:city'] ?? tags['addr:town'] ?? tags['addr:village'],
  ].map((p) => p?.toString().trim()).where((p) => p != null && p.isNotEmpty).cast<String>().toList();
  if (parts.isEmpty) return null;
  return parts.join(', ');
}

/// Overpass signals runtime failures inside an otherwise-normal 200 response, as a `remark`
/// string ("runtime error: Query timed out", "Too many requests", ...). Returns that text when
/// the response is an error dressed as a success, and null when the response is genuinely usable.
String? overpassRemark(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return 'unreadable response';
    final remark = decoded['remark']?.toString().trim();
    if (remark != null && remark.isNotEmpty) return remark;
    // No elements key at all means this was not an Overpass result document.
    if (decoded['elements'] is! List) return 'unexpected response shape';
    return null;
  } catch (_) {
    // Not JSON at all -- Overpass mirrors return an HTML error page under load.
    return 'unreadable response';
  }
}

/// Turns an Overpass response body into hospitals sorted nearest-first.
List<Hospital> parseOverpass(String body, LatLng centre) {
  final decoded = jsonDecode(body);
  if (decoded is! Map || decoded['elements'] is! List) return const [];
  final results = <Hospital>[];
  for (final raw in decoded['elements'] as List) {
    if (raw is! Map) continue;
    final centreTag = raw['center'];
    final lat = (raw['lat'] ?? (centreTag is Map ? centreTag['lat'] : null)) as num?;
    final lng = (raw['lon'] ?? (centreTag is Map ? centreTag['lon'] : null)) as num?;
    if (lat == null || lng == null) continue;
    final tags = (raw['tags'] is Map)
        ? Map<String, dynamic>.from(raw['tags'] as Map)
        : <String, dynamic>{};
    final name = tags['name']?.toString().trim();
    final phone = (tags['phone'] ?? tags['contact:phone'])?.toString().trim();
    results.add(Hospital(
      id: '${raw['type'] ?? 'node'}/${raw['id'] ?? results.length}',
      // An unnamed but correctly located hospital is still worth navigating to, so it stays in
      // the list under a generic label rather than being dropped or rendered as "null".
      name: (name == null || name.isEmpty) ? 'Hospital' : name,
      point: LatLng(lat.toDouble(), lng.toDouble()),
      distanceMetres: Geolocator.distanceBetween(
        centre.latitude,
        centre.longitude,
        lat.toDouble(),
        lng.toDouble(),
      ),
      address: addressFromTags(tags),
      phone: (phone == null || phone.isEmpty) ? null : phone,
      emergency: tags['emergency']?.toString() == 'yes',
    ));
  }
  results.sort((a, b) => a.distanceMetres.compareTo(b.distanceMetres));
  return dedupeHospitals(results);
}

/// A large hospital is frequently mapped several times over -- an `amenity=hospital` node for the
/// site plus a way for the building, sometimes a relation too. Same name within ~150m is the same
/// place; the nearest copy wins because the list is already sorted.
List<Hospital> dedupeHospitals(List<Hospital> sorted) {
  final kept = <Hospital>[];
  for (final candidate in sorted) {
    final duplicate = kept.any((k) =>
        k.name.toLowerCase() == candidate.name.toLowerCase() &&
        Geolocator.distanceBetween(
              k.point.latitude,
              k.point.longitude,
              candidate.point.latitude,
              candidate.point.longitude,
            ) <
            150);
    if (!duplicate) kept.add(candidate);
  }
  return kept;
}

/// Fetches hospitals from Overpass with a hard timeout and exactly one retry (against the second
/// mirror). Failures are classified before they leave this function so the UI never has to parse
/// an exception string to decide what to tell the user.
Future<List<Hospital>> fetchNearbyHospitals(
  LatLng centre,
  int radiusMetres, {
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  final query = buildOverpassQuery(centre, radiusMetres);
  Object? lastError;
  try {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await httpClient
            .post(
              Uri.parse(_overpassEndpoints[attempt % _overpassEndpoints.length]),
              body: {'data': query},
            )
            .timeout(_overpassTimeout);
        if (response.statusCode == 200) {
          // Overpass reports its *own* failures (rate limit, server-side timeout, out of memory)
          // as HTTP 200 with a `remark` and no elements. Parsing that as "zero hospitals" would
          // send the user to the empty state, telling them to widen a search that never ran --
          // so a remark is treated as a server failure and retried on the other host.
          final remark = overpassRemark(response.body);
          if (remark == null) return parseOverpass(response.body, centre);
          lastError = HttpException('Overpass remark: $remark');
        } else {
          lastError = HttpException('Overpass responded ${response.statusCode}');
        }
      } on TimeoutException catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      }
    }
  } finally {
    if (client == null) httpClient.close();
  }
  // A dead radio and a dead server look similar from inside an exception, so ask the platform
  // which one it actually is before choosing the message the user will act on.
  final connectivity = await Connectivity().checkConnectivity();
  final deviceOnline = connectivity.any((r) => r != ConnectivityResult.none);
  if (!deviceOnline || lastError is SocketException) {
    throw const HospitalSearchException(HospitalSearchFailure.noInternet);
  }
  throw const HospitalSearchException(HospitalSearchFailure.serverUnreachable);
}

/// Plain Google Maps universal link -- no API key, no SDK, no billing. Navigation is by
/// coordinates, so it works for entries that have no address tags at all.
Uri directionsUri(Hospital hospital) => Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=${hospital.point.latitude},${hospital.point.longitude}'
      '&travelmode=driving',
    );

class FindHospitalsPage extends StatefulWidget {
  const FindHospitalsPage({super.key});
  @override
  State<FindHospitalsPage> createState() => _FindHospitalsPageState();
}

enum _Phase { locating, loading, ready, empty, failed }

class _FindHospitalsPageState extends State<FindHospitalsPage> {
  /// Fixed row height: it keeps map -> list syncing exact (`index * _rowExtent` is the offset)
  /// without pulling in a positioned-list package.
  static const double _rowExtent = 104;

  final MapController _map = MapController();
  final ScrollController _list = ScrollController();

  _Phase _phase = _Phase.locating;
  HospitalSearchFailure? _failure;
  LocationFix? _fix;
  List<Hospital> _hospitals = const [];
  int _radiusIndex = 0;
  int? _selected;
  bool _expanding = false;

  @override
  void initState() {
    super.initState();
    // Minimum taps under stress: locating and searching both start the moment the screen opens.
    // There is deliberately no "Search" button to press.
    _run();
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  Future<void> _run({bool keepFix = false}) async {
    setState(() {
      _phase = keepFix && _fix != null ? _Phase.loading : _Phase.locating;
      _failure = null;
      _selected = null;
    });
    try {
      final fix = keepFix && _fix != null ? _fix! : await resolveLocationFix();
      if (!mounted) return;
      setState(() {
        _fix = fix;
        _phase = _Phase.loading;
      });
      final hospitals = await fetchNearbyHospitals(fix.point, _radiusLadder[_radiusIndex]);
      if (!mounted) return;
      setState(() {
        _hospitals = hospitals;
        _phase = hospitals.isEmpty ? _Phase.empty : _Phase.ready;
        _expanding = false;
      });
    } on HospitalSearchException catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = e.kind;
        _phase = _Phase.failed;
        _expanding = false;
      });
    }
  }

  Future<void> _expandRadius() async {
    if (_radiusIndex >= _radiusLadder.length - 1) return;
    setState(() {
      _radiusIndex++;
      _expanding = true;
    });
    await _run(keepFix: true);
  }

  /// Map and list stay in step in both directions: selecting from either one centres the map and
  /// scrolls the matching row into view, so the user never has to hunt for the pair by hand.
  void _select(int index, {required bool fromMap}) {
    setState(() => _selected = index);
    final hospital = _hospitals[index];
    _map.move(hospital.point, _map.camera.zoom < 14 ? 14 : _map.camera.zoom);
    if (fromMap && _list.hasClients) {
      final target = (index * _rowExtent).clamp(0.0, _list.position.maxScrollExtent);
      _list.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  Future<void> _openDirections(Hospital hospital) async {
    final launched = await launchUrl(directionsUri(hospital), mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open a maps app for directions.')),
      );
    }
  }

  static String _radiusLabel(int metres) => '${(metres / 1000).round()} km';

  @override
  Widget build(BuildContext context) => PageFrame(
        title: 'Find my hospital',
        actions: [
          IconButton(
            tooltip: 'Search again',
            onPressed: _phase == _Phase.locating || _phase == _Phase.loading ? null : () => _run(),
            icon: const Icon(Icons.refresh),
          ),
        ],
        child: switch (_phase) {
          _Phase.locating || _Phase.loading => _LoadingSkeleton(
              label: _phase == _Phase.locating
                  ? 'Getting your location...'
                  : _expanding
                      ? 'Widening the search to ${_radiusLabel(_radiusLadder[_radiusIndex])}...'
                      : 'Finding hospitals within ${_radiusLabel(_radiusLadder[_radiusIndex])}...',
            ),
          _Phase.failed => _FailureView(kind: _failure!, onRetry: () => _run()),
          _Phase.empty => _EmptyView(
              radiusLabel: _radiusLabel(_radiusLadder[_radiusIndex]),
              canExpand: _radiusIndex < _radiusLadder.length - 1,
              nextRadiusLabel: _radiusIndex < _radiusLadder.length - 1
                  ? _radiusLabel(_radiusLadder[_radiusIndex + 1])
                  : null,
              onExpand: _expandRadius,
              onRetry: () => _run(),
            ),
          _Phase.ready => _results(),
        },
      );

  Widget _results() {
    final fix = _fix!;
    return Column(
      children: [
        if (fix.isCoarse)
          Container(
            width: double.infinity,
            color: MedilinkColors.amber.withValues(alpha: .10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: const Row(
              children: [
                Icon(Icons.my_location, size: 16, color: MedilinkColors.amber),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Location accuracy is low - results may not be fully nearby.',
                    style: TextStyle(fontSize: 12, color: MedilinkColors.amber),
                  ),
                ),
              ],
            ),
          ),
        SizedBox(
          height: 220,
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(initialCenter: fix.point, initialZoom: 13),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.medilink',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: fix.point,
                    width: 24,
                    height: 24,
                    child: const Icon(Icons.my_location, size: 20, color: MedilinkColors.blue),
                  ),
                  for (var i = 0; i < _hospitals.length; i++)
                    Marker(
                      point: _hospitals[i].point,
                      width: 44,
                      height: 44,
                      child: GestureDetector(
                        onTap: () => _select(i, fromMap: true),
                        child: Icon(
                          Icons.local_hospital,
                          size: _selected == i ? 40 : 30,
                          color: _selected == i ? MedilinkColors.blue : MedilinkColors.teal,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_hospitals.length} within ${_radiusLabel(_radiusLadder[_radiusIndex])}',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: MedilinkColors.blue),
                ),
              ),
              if (_radiusIndex < _radiusLadder.length - 1)
                TextButton(onPressed: _expandRadius, child: const Text('Search wider')),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _list,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemExtent: _rowExtent,
            itemCount: _hospitals.length,
            itemBuilder: (context, i) => _HospitalRow(
              hospital: _hospitals[i],
              selected: _selected == i,
              onTap: () => _select(i, fromMap: false),
              onDirections: () => _openDirections(_hospitals[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _HospitalRow extends StatelessWidget {
  const _HospitalRow({
    required this.hospital,
    required this.selected,
    required this.onTap,
    required this.onDirections,
  });
  final Hospital hospital;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDirections;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: selected ? MedilinkColors.blue.withValues(alpha: .06) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? MedilinkColors.blue : Colors.black12,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(child: _details()),
                  const SizedBox(width: 8),
                  // One obvious tap target -- not behind a menu, a swipe, or a detail page.
                  SizedBox(
                    height: 42,
                    child: FilledButton.icon(
                      onPressed: onDirections,
                      style: FilledButton.styleFrom(
                        backgroundColor: MedilinkColors.blue,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      icon: const Icon(Icons.directions, size: 18),
                      label: const Text('Directions', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _details() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Name leads the hierarchy, distance is the clear second line, and the address only
          // appears when OpenStreetMap actually has one -- never a blank or "null" line.
          Text(
            hospital.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, height: 1.15),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Text(
                hospital.distanceLabel,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: MedilinkColors.teal,
                ),
              ),
              if (hospital.emergency) ...[
                const SizedBox(width: 8),
                const Text(
                  'Emergency dept.',
                  style: TextStyle(fontSize: 12, color: MedilinkColors.green),
                ),
              ],
            ],
          ),
          if (hospital.address != null)
            Text(
              hospital.address!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
        ],
      );
}

/// Skeleton rows with a slow pulse. A static spinner during a 9s Overpass call reads as a frozen
/// screen; shaped, breathing placeholders read as work in progress.
class _LoadingSkeleton extends StatefulWidget {
  const _LoadingSkeleton({required this.label});
  final String label;
  @override
  State<_LoadingSkeleton> createState() => _LoadingSkeletonState();
}

class _LoadingSkeletonState extends State<_LoadingSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _bar(double width, double height) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(6),
        ),
      );

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: MedilinkColors.blue),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: MedilinkColors.blue),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FadeTransition(
            opacity: Tween<double>(begin: .45, end: .95).animate(_pulse),
            child: Column(
              children: [
                _bar(double.infinity, 200),
                const SizedBox(height: 16),
                for (var i = 0; i < 4; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _bar(double.infinity, 16),
                              const SizedBox(height: 8),
                              _bar(110, 12),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _bar(104, 40),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
}

/// Nothing found is not a dead end: the primary action widens the radius rather than leaving an
/// apology on screen with no way forward.
class _EmptyView extends StatelessWidget {
  const _EmptyView({
    required this.radiusLabel,
    required this.canExpand,
    required this.nextRadiusLabel,
    required this.onExpand,
    required this.onRetry,
  });
  final String radiusLabel;
  final bool canExpand;
  final String? nextRadiusLabel;
  final VoidCallback onExpand;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.travel_explore, size: 46, color: MedilinkColors.blue),
              const SizedBox(height: 12),
              Text(
                'No hospitals within $radiusLabel',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                'OpenStreetMap has no hospital mapped in this area yet.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (canExpand)
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: onExpand,
                    style: FilledButton.styleFrom(backgroundColor: MedilinkColors.blue),
                    icon: const Icon(Icons.zoom_out_map),
                    label: Text('Expand search to $nextRadiusLabel'),
                  ),
                )
              else
                const Text(
                  'Already searching the widest radius available.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              TextButton(onPressed: onRetry, child: const Text('Search again')),
            ],
          ),
        ),
      );
}

/// Deliberately shaped so it can never be mistaken for the empty state: a different icon, an
/// explicit cause, and retry as the primary action instead of "widen the search".
class _FailureView extends StatelessWidget {
  const _FailureView({required this.kind, required this.onRetry});
  final HospitalSearchFailure kind;
  final VoidCallback onRetry;

  (IconData, String, String, String) get _presentation => switch (kind) {
        HospitalSearchFailure.noInternet => (
            Icons.wifi_off,
            'No internet connection',
            "Your phone isn't online, so the hospital map couldn't be loaded. Reconnect to Wi-Fi or mobile data, then try again.",
            'Try again',
          ),
        HospitalSearchFailure.serverUnreachable => (
            Icons.dns_outlined,
            "Hospital map service didn't respond",
            "You're online, but the OpenStreetMap service didn't answer in time. This is usually temporary.",
            'Retry search',
          ),
        HospitalSearchFailure.locationPermissionDenied => (
            Icons.location_disabled,
            'Location permission needed',
            'MediLink needs your location to find hospitals near you. Allow location access, then try again.',
            'Try again',
          ),
        HospitalSearchFailure.locationServicesOff => (
            Icons.location_off,
            'Location is switched off',
            'Turn on location (GPS) on your phone so nearby hospitals can be found.',
            'Try again',
          ),
        HospitalSearchFailure.locationUnavailable => (
            Icons.my_location,
            "Couldn't get a GPS fix",
            'Your position could not be determined. Moving somewhere with a clearer view of the sky usually helps.',
            'Try again',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, title, detail, action) = _presentation;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Amber, never red: red stays reserved for genuine emergency states elsewhere in the
            // app, so this screen never reads as "something is wrong with you".
            Icon(icon, size: 46, color: MedilinkColors.amber),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(detail, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: onRetry,
                style: FilledButton.styleFrom(backgroundColor: MedilinkColors.blue),
                icon: const Icon(Icons.refresh),
                label: Text(action),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
