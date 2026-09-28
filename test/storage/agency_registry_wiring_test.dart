// registry 런타임 연결 (REVIEW2 높음-3·중간-3): asset 번들 선언, 현행명 표시·집계,
// 원문 기관코드 NULL 왕복.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'package:safetyreport/services/local_db_service.dart';

import '../../shared/agency-region-registry/resolvers/resolve.dart'
    as shared_resolve;

// shared/agency-region-registry seed 와 같은 1:1 승계 (테스트용 인라인).
const _links = [
  {
    'from_code': '1812314',
    'from_name': '광주광역시경찰청',
    'to_code': '1815198',
    'to_name': '광주경찰청',
    'effective_date': '2026-07-01',
    'institution_id': 'ag-gwangju-police-hq',
  },
];

AgencyRegistrySnapshot _snapshot() => AgencyRegistrySnapshot(
  links: _links,
  events: const [],
  registryVersion: '2026-09-28.1-test',
  asOfDate: '2026-09-28',
);

Map<String, dynamic> _row(String id, String agency, String? code) => {
  'ID': id,
  '신고번호': 'SPP-$id',
  '신고일': '2026-08-01',
  '답변일': '2026-09-01',
  '처리상태': '수용',
  '처리기관': agency,
  '처리기관코드': code,
  '담당자': '김담당',
  '범칙금_과태료': '과태료: 50000원',
  '위반법규': '',
  'category': 'traffic',
  'entry_value': '자동차·교통위반-신호위반',
};

void main() {
  test('pubspec bundles the registry runtime snapshot', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('shared/agency-region-registry/manifest.json'));
    expect(
      pubspec,
      contains('shared/agency-region-registry/data/agency_links.json'),
    );
    expect(
      pubspec,
      contains('shared/agency-region-registry/data/region_events.json'),
    );
    // 번들 파일이 실제로 있다.
    expect(
      File(
        'shared/agency-region-registry/data/agency_links.json',
      ).existsSync(),
      isTrue,
    );
  });

  test('resolved rows show the current name, unresolved falls back', () {
    AgencyRegistry.testInject(_snapshot());
    try {
      expect(
        registryDisplayAgency('1812314', '광주광역시경찰청'),
        equals('광주경찰청'),
      );
      expect(registryDisplayAgency('1815198', '광주경찰청'), equals('광주경찰청'));
      // 미확정 코드는 기존 normalize 로 폴백.
      expect(
        registryDisplayAgency('9999999', '서울특별시 강서경찰서 교통과'),
        equals('서울특별시 강서경찰서'),
      );
      expect(registryDisplayAgency(null, '서울특별시 중구청'), equals('서울특별시 중구청'));
    } finally {
      AgencyRegistry.testInject(null);
    }
  });

  test('stats group old and new codes under the current name', () {    AgencyRegistry.testInject(_snapshot());
    try {
      final rows = [
        _row('c1', '광주광역시경찰청', '1812314'),
        _row('c2', '광주경찰청', '1815198'),
      ];
      final got = LocalDbService.buildStatsCategory(rows, rows, true);
      final agencies = {
        for (final r in (got['by_agency'] as List)) (r['agency'] as String): r,
      };
      expect(agencies.keys, equals({'광주경찰청'}));
      expect(agencies['광주경찰청']!['total'], equals(2));
    } finally {
      AgencyRegistry.testInject(null);
    }
  });

  test('agency code NULL survives the Report round trip (no empty-string merge)', () {    final report = Report.fromJson({
      'ID': 's1',
      '신고번호': 'SPP-1',
      '처리기관': '서울특별시 중구청',
    });
    expect(report.agencyCode, isNull);
    // Report→DB 행은 null 그대로(NULL 저장).
    expect(report.agencyCode, isNull);
    final cleared = Report.fromJson({
      'ID': 's1',
      '신고번호': 'SPP-1',
      '처리기관': '서울특별시 중구청',
      '처리기관코드': 'B410002',
    }).copyWith(clearAgencyCode: true);
    expect(cleared.agencyCode, isNull);
    final kept = Report.fromJson({
      'ID': 's1',
      '신고번호': 'SPP-1',
      '처리기관': '서울특별시 중구청',
      '처리기관코드': 'B410002',
    });
    expect(kept.agencyCode, equals('B410002'));
  });

  test('vendored resolver matches the shared port on all agency vectors', () {
    // lib/ 는 shared/ 를 import 할 수 없어 동결 복사본을 쓴다.
    // 정본이 바뀌면 이 테스트가 깨져 복사본 갱신을 강제한다.
    final manifest =
        jsonDecode(File('shared/agency-region-registry/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    final links =
        (jsonDecode(
              File(
                'shared/agency-region-registry/data/agency_links.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>)['links'] as List;
    final version = manifest['registry_version'] as String;
    final asOf = manifest['as_of_date'] as String;
    final cases =
        (jsonDecode(
              File(
                'shared/agency-region-registry/vectors/resolve_cases.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>)['cases'] as List;
    final vendored = AgencyRegistrySnapshot(
      links: links,
      events: const [],
      registryVersion: version,
      asOfDate: asOf,
    );
    var agencyCases = 0;
    for (final c in cases.cast<Map<String, dynamic>>()) {
      if (c['kind'] != 'agency') continue;
      agencyCases++;
      final input = Map<String, dynamic>.from(c['input'] as Map);
      final expected = shared_resolve.resolveAgency(
        input['code'] as String?,
        input['name'] as String?,
        asOf,
        links,
        version,
      );
      final wantDisplay = shared_resolve.displayAgency(
        input['name'] as String?,
        expected,
      );
      final wantCurrent = expected['resolution_status'] == 'resolved'
          ? wantDisplay
          : null;
      expect(
        vendored.displayCurrentAgency(
          input['code'] as String?,
          input['name'] as String?,
        ),
        equals(wantCurrent),
        reason: '${c['name']}',
      );
    }
    expect(agencyCases, greaterThan(0));
  });
}
