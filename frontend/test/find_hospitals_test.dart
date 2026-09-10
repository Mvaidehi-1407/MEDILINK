import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
