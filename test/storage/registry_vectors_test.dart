// shared/agency-region-registry Dart port check: same vectors as Python/TS.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../shared/agency-region-registry/resolvers/resolve.dart';

Map<String, dynamic> _load(String name) => jsonDecode(
  File('shared/agency-region-registry/$name').readAsStringSync(),
);

void main() {
  final manifest = _load('manifest.json') as Map<String, dynamic>;
  final registryVersion = manifest['registry_version'] as String;
  final links =
      (_load('data/agency_links.json')['links'] as List).cast<Map<String, dynamic>>();
  final rows = (_load('data/agency_index.json')['rows'] as List);
  final index = <String, dynamic>{
    for (final r in rows) (r as List).first as String: (r as List).sublist(1),
  };
  final legacy =
      _load('data/agency_legacy.json') as Map<String, dynamic>;
  final institutions =
      (_load('data/agency_institutions.json')['institutions'] as Map)
          .cast<String, dynamic>();
  final snap = AgencySnapshot(
    links: links,
    index: index,
    forward: (legacy['forward'] as Map).cast<String, dynamic>(),
    multi: (legacy['multi'] as Map).cast<String, dynamic>(),
    institutions: institutions,
    registryVersion: registryVersion,
    asOfDate: manifest['as_of_date'] as String?,
  );
  final events =
      (_load('data/region_events.json')['events'] as List).cast<Map<String, dynamic>>();
  final cases =
      (_load('vectors/resolve_cases.json')['cases'] as List).cast<Map<String, dynamic>>();

  test('registry version matches the snapshot', () {
    expect(registryVersion, equals('2026-09-29.3'));
  });

  for (final c in cases) {
    test('${c['name']}', () {
      final input = Map<String, dynamic>.from(c['input'] as Map);
      final Map<String, dynamic> got;
      if (c['kind'] == 'agency') {
        got = resolveAgency(
          input['code'] as String?,
          input['name'] as String?,
          input['answered_at'] as String?,
          snap,
        );
      } else {
        got = resolveRegionGap(
          input['code'] as String?,
          input['date'] as String?,
          events,
          registryVersion,
        );
      }
      final expected = Map<String, dynamic>.from(c['expected'] as Map);
      for (final key in expected.keys) {
        expect(got[key], equals(expected[key]), reason: '${c['name']} · $key');
      }
    });
  }

  test('display never invents the (구) prefix for unresolved rows', () {
    final agency = resolveAgency(
      '9999999',
      '어딘가구청',
      '2026-09-01',
      snap,
    );
    expect(displayAgency('어딘가구청', agency), equals('어딘가구청'));
    final region = resolveRegionGap(
      '4159100000',
      '2026-09-01',
      events,
      registryVersion,
    );
    expect(displayRegion('경기도 화성시', region), equals('경기도 화성시'));
  });

  test('display uses the historical prefix only for known nodes', () {
    final region = resolveRegionGap(
      '2811000000',
      '2026-09-01',
      events,
      registryVersion,
    );
    expect(displayRegion('인천광역시 중구', region), equals('(구)인천광역시 중구'));
  });
}
