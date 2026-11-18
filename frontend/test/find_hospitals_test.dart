import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:medilink/features/find_hospitals.dart';

const _centre = LatLng(17.385, 78.4867);

void main() {
  group('addressFromTags', () {
    test('returns null when OSM has no address tags at all', () {
      expect(addressFromTags({'name': 'City Hospital'}), isNull);
    });

    test('never emits a stray separator when only some parts exist', () {
      expect(addressFromTags({'addr:city': 'Hyderabad'}), 'Hyderabad');
      expect(
        addressFromTags({'addr:housenumber': '12', 'addr:street': 'MG Road'}),
        '12 MG Road',
      );
    });

    test('prefers addr:full when present', () {
      expect(addressFromTags({'addr:full': 'Plot 5, Banjara Hills'}), 'Plot 5, Banjara Hills');
    });
  });

  group('parseOverpass', () {
    String body(List<Map<String, dynamic>> elements) => jsonEncode({'elements': elements});

    test('reads way/relation centres as well as node coordinates', () {
      final parsed = parseOverpass(
        body([
          {'type': 'node', 'id': 1, 'lat': 17.39, 'lon': 78.49, 'tags': {'name': 'Near Node'}},
          {
            'type': 'way',
            'id': 2,
            'center': {'lat': 17.50, 'lon': 78.60},
            'tags': {'name': 'Far Way'},
          },
        ]),
        _centre,
      );
      expect(parsed.map((h) => h.name), ['Near Node', 'Far Way']);
    });

    test('sorts nearest first', () {
      final parsed = parseOverpass(
        body([
          {'type': 'node', 'id': 1, 'lat': 17.60, 'lon': 78.60, 'tags': {'name': 'Far'}},
          {'type': 'node', 'id': 2, 'lat': 17.386, 'lon': 78.487, 'tags': {'name': 'Close'}},
        ]),
        _centre,
      );
      expect(parsed.first.name, 'Close');
      expect(parsed.first.distanceMetres, lessThan(parsed.last.distanceMetres));
    });

    test('keeps an untagged hospital under a generic label rather than showing null', () {
      final parsed = parseOverpass(
        body([
          {'type': 'node', 'id': 1, 'lat': 17.39, 'lon': 78.49},
        ]),
        _centre,
      );
      expect(parsed.single.name, 'Hospital');
      expect(parsed.single.address, isNull);
    });

    test('drops elements with no resolvable coordinates', () {
      final parsed = parseOverpass(
        body([
          {'type': 'relation', 'id': 9, 'tags': {'name': 'No geometry'}},
        ]),
        _centre,
      );
      expect(parsed, isEmpty);
    });

    test('collapses the node/way duplicates OSM keeps for one site', () {
      final parsed = parseOverpass(
        body([
          {'type': 'node', 'id': 1, 'lat': 17.3900, 'lon': 78.4900, 'tags': {'name': 'Apollo'}},
          {'type': 'way', 'id': 2, 'center': {'lat': 17.3901, 'lon': 78.4901}, 'tags': {'name': 'Apollo'}},
        ]),
        _centre,
      );
      expect(parsed, hasLength(1));
    });

    test('tolerates a malformed body instead of throwing', () {
      expect(parseOverpass('{"remark":"rate limited"}', _centre), isEmpty);
    });
  });

  group('overpassRemark', () {
    test('accepts a genuine result document', () {
      expect(overpassRemark('{"elements":[]}'), isNull);
    });

    test('catches a rate-limit error that arrives dressed as HTTP 200', () {
      // This is what Overpass actually sends when it throttles: a 200, no elements, a remark.
      // Treating it as "zero hospitals" would send the user to the empty state by mistake.
      expect(
        overpassRemark('{"remark":"runtime error: Query timed out","elements":[]}'),
        contains('timed out'),
      );
    });

    test('catches an HTML error page from an overloaded mirror', () {
      expect(overpassRemark('<html><body>504 Gateway Timeout</body></html>'), isNotNull);
    });

    test('catches a document that is not an Overpass result at all', () {
      expect(overpassRemark('{"something":"else"}'), isNotNull);
    });
  });

  group('directionsUri', () {
    test('navigates by coordinates, so a missing address cannot break it', () {
      final uri = directionsUri(const Hospital(
        id: 'node/1',
        name: 'Hospital',
        point: LatLng(17.39, 78.49),
        distanceMetres: 120,
      ));
      expect(uri.host, 'www.google.com');
      expect(uri.queryParameters['destination'], '17.39,78.49');
      // No key parameter: this link must stay free and unauthenticated.
      expect(uri.queryParameters.containsKey('key'), isFalse);
    });
  });

  group('buildOverpassQuery', () {
    test('never lets the server outlive the client deadline', () {
      // A server budget above the client timeout leaves Overpass working on a query nobody is
      // waiting for, which burns a rate-limit slot and poisons the retry.
      final match = RegExp(r'timeout:(\d+)').firstMatch(buildOverpassQuery(_centre, 5000));
      expect(match, isNotNull);
      expect(int.parse(match!.group(1)!), lessThan(10));
    });

    test('bounds the search by the requested radius and centre', () {
      final query = buildOverpassQuery(_centre, 5000);
      expect(query, contains('around:5000,17.385,78.4867'));
      expect(query, contains('out center tags 60;'));
    });
  });

  group('fetchNearbyHospitals mirror fallback', () {
    test('falls through failing mirrors to a later one that answers cleanly', () async {
      final calledUrls = <String>[];
      final mock = MockClient((request) async {
        calledUrls.add(request.url.toString());
        // The first two mirrors "fail" the way a real overloaded Overpass instance does: a 200
        // carrying a remark instead of elements, which must not be mistaken for zero hospitals.
        if (calledUrls.length < 3) {
          return http.Response('{"remark":"runtime error: Query timed out"}', 200);
        }
        return http.Response(jsonEncode({'elements': []}), 200);
      });
      final result = await fetchOverpassHospitals(_centre, 5000, client: mock);
      expect(result, isEmpty);
      // Stops at the third mirror rather than continuing to try every configured one -- a
      // mirror that actually answers must end the search immediately.
      expect(calledUrls, hasLength(3));
    });

    test('tries every configured mirror, in order, before giving up', () async {
      final calledUrls = <String>[];
      final mock = MockClient((request) async {
        calledUrls.add(request.url.toString());
        return http.Response('', 503);
      });
      // Connectivity checking hits a real platform channel that isn't wired up in a plain unit
      // test, so only the retry loop itself (which runs entirely before that check) is asserted
      // here; whatever exception surfaces afterwards is not the point of this test.
      await fetchOverpassHospitals(_centre, 5000, client: mock).catchError((_) => const <Hospital>[]);
      expect(calledUrls, hasLength(4));
      expect(calledUrls.toSet(), hasLength(4)); // four distinct hosts, never the same one twice
    });

    test('identifies the app: Dart\'s default User-Agent gets a 406 from overpass-api.de', () async {
      final agents = <String?>[];
      final mock = MockClient((request) async {
        agents.add(request.headers['User-Agent'] ?? request.headers['user-agent']);
        return http.Response(jsonEncode({'elements': []}), 200);
      });
      await fetchOverpassHospitals(_centre, 5000, client: mock);
      expect(agents.single, startsWith('MediLink/'));
    });
  });

  group('fetchNearbyHospitals: Nominatim first, Overpass fallback', () {
    Map<String, dynamic> place(String name, double lat, double lon, {int id = 1}) => {
          'osm_type': 'node', 'osm_id': id, 'name': name, 'lat': '$lat', 'lon': '$lon',
          'address': {'road': 'MG Road', 'city': 'Hyderabad', 'postcode': '500001'},
          'extratags': {'phone': '+91 40 1234', 'emergency': 'yes'},
        };

    test('uses Nominatim results, nearest first, inside the radius only, without calling Overpass', () async {
      final hosts = <String>[];
      final mock = MockClient((request) async {
        hosts.add(request.url.host);
        expect(request.headers['User-Agent'], startsWith('MediLink/'));
        return http.Response(jsonEncode([
          place('Far', 17.42, 78.4867, id: 1), // ~3.9 km
          place('Near', 17.386, 78.4867, id: 2), // ~110 m
          place('Outside the circle', 17.43, 78.53, id: 3), // in the box's corner, >5 km
        ]), 200);
      });
      final result = await fetchNearbyHospitals(_centre, 5000, client: mock);
      expect(result.map((h) => h.name), ['Near', 'Far']);
      expect(result.first.address, 'MG Road, Hyderabad, 500001');
      expect(result.first.phone, '+91 40 1234');
      expect(result.first.emergency, isTrue);
      expect(hosts, ['nominatim.openstreetmap.org']);
    });

    test('falls back to the Overpass chain when Nominatim fails', () async {
      final hosts = <String>[];
      final mock = MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'nominatim.openstreetmap.org') return http.Response('<html>busy</html>', 503);
        return http.Response(jsonEncode({'elements': [
          {'type': 'node', 'id': 7, 'lat': 17.386, 'lon': 78.4867, 'tags': {'name': 'From Overpass'}},
        ]}), 200);
      });
      final result = await fetchNearbyHospitals(_centre, 5000, client: mock);
      expect(result.single.name, 'From Overpass');
      expect(hosts, ['nominatim.openstreetmap.org', 'overpass-api.de']);
    });

    test('an empty Nominatim answer is a real "no hospitals", not a failure', () async {
      final hosts = <String>[];
      final mock = MockClient((request) async {
        hosts.add(request.url.host);
        return http.Response('[]', 200);
      });
      expect(await fetchNearbyHospitals(_centre, 5000, client: mock), isEmpty);
      expect(hosts, ['nominatim.openstreetmap.org']);
    });

    test('a capped (50-result) wide search also merges a 2 km search so the closest is not lost', () async {
      final viewboxes = <String>[];
      final mock = MockClient((request) async {
        viewboxes.add(request.url.queryParameters['viewbox']!);
        if (viewboxes.length == 1) {
          return http.Response(jsonEncode([for (var i = 0; i < 50; i++) place('Big $i', 17.42, 78.4867, id: 100 + i)]), 200);
        }
        return http.Response(jsonEncode([place('Small clinic hospital', 17.3855, 78.4867, id: 9)]), 200);
      });
      final result = await fetchNearbyHospitals(_centre, 10000, client: mock);
      expect(viewboxes, hasLength(2));
      expect(result.first.name, 'Small clinic hospital');
    });
  });

  group('distanceLabel', () {
    Hospital at(double metres) => Hospital(
          id: 'x',
          name: 'H',
          point: const LatLng(0, 0),
          distanceMetres: metres,
        );

    test('uses metres below a kilometre and one decimal above', () {
      expect(at(340).distanceLabel, '340 m away');
      expect(at(2450).distanceLabel, '2.5 km away');
    });
  });
}
