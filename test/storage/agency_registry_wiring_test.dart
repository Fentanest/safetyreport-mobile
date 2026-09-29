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
  index: {
    '1812314': ['광주광역시경찰청', '1812314', null, null],
    '1815198': ['광주경찰청', '1815198', null, null],
  },
  forward: const {},
  multi: const {},
  institutions: {
    '1812314': 'ag-gwangju-police-hq',
    '1815198': 'ag-gwangju-police-hq',
  },
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
      contains('shared/agency-region-registry/data/agency_index.json'),
    );
    expect(
      pubspec,
      contains('shared/agency-region-registry/data/agency_legacy.json'),
    );
    expect(
      pubspec,
      contains('shared/agency-region-registry/data/agency_institutions.json'),
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
      // 미확정 코드는 원문 기관명 그대로(경찰기관명 정규화 폐지, PC test_agency_registry 와 같음).
      expect(
        registryDisplayAgency('9999999', '서울특별시 강서경찰서 교통과'),
        equals('서울특별시 강서경찰서 교통과'),
      );
      expect(registryDisplayAgency(null, '서울특별시 중구청'), equals('서울특별시 중구청'));
    } finally {
      AgencyRegistry.testInject(null);
    }
  });

  test('successor codes resolve to the same institution (REVIEW3 높음-2)', () {
    // 동결 복사본(_resolveAgency)이 후계 코드를 역방향으로 따라가 같은 기관으로
    // 묶는지 직접 고정한다(표시 fallback 우회가 아니라 실제 해석).
    final snap = _snapshot();
    expect(
      snap.displayCurrentAgency('1812314', '광주광역시경찰청'),
      equals('광주경찰청'),
    );
    expect(
      snap.displayCurrentAgency('1815198', '광주경찰청'),
      equals('광주경찰청'),
    );
    expect(snap.displayCurrentAgency('9999999', '어딘가구청'), isNull);
    expect(snap.displayCurrentAgency(null, '어딘가구청'), isNull);
  });

  test('client JSON reports display current name and preserve source code', () {
    AgencyRegistry.testInject(_snapshot());
    try {
      final report = Report.fromJson({
        'ID': 'r1', '신고번호': 'SPP-1',
        '처리기관': '광주광역시경찰청', '처리기관코드': '1812314',
      });
      expect(report.agency, '광주경찰청');
      expect(report.agencyCode, '1812314');
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
      final got = LocalDbService.buildStatsCategory(rows, rows);
      final agencies = {
        for (final r in (got['by_agency'] as List)) (r['agency'] as String): r,
      };
      expect(agencies.keys, equals({'광주경찰청'}));
      expect(agencies['광주경찰청']!['total'], equals(2));
      expect(
        agencies['광주경찰청']!['agency_key'],
        equals('inst:ag-gwangju-police-hq'),
      );
    } finally {
      AgencyRegistry.testInject(null);
    }
  });

  test('stats split the same display with different codes (stat keys)', () {
    AgencyRegistry.testInject(_snapshot());
    try {
      final rows = [
        _row('s1', '어딘가구청', '9999991'),
        _row('s2', '어딘가구청', '9999992'),
      ];
      final got = LocalDbService.buildStatsCategory(rows, rows);
      final agencies = got['by_agency'] as List;
      expect(agencies.length, equals(2));
      expect(
        {for (final r in agencies) r['agency_key']},
        equals({'src:9999991:어딘가구청', 'src:9999992:어딘가구청'}),
      );
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

  test('stats group abolished dept codes under answer-time agencies (2026-09-29.3)', () {
    // 실제 스냅샷: 폐지 부서 코드는 재크롤링 없이 파생 재계산으로 집계기관에 묶인다.
    Map<String, dynamic> load(String name) => jsonDecode(
      File('shared/agency-region-registry/$name').readAsStringSync(),
    );
    final manifest = load('manifest.json') as Map<String, dynamic>;
    final links =
        (load('data/agency_links.json')['links'] as List);
    final rows = (load('data/agency_index.json')['rows'] as List);
    final index = <String, dynamic>{
      for (final r in rows) (r as List).first as String: (r as List).sublist(1),
    };
    final legacy = load('data/agency_legacy.json') as Map<String, dynamic>;
    final institutions =
        (load('data/agency_institutions.json')['institutions'] as Map)
            .cast<String, dynamic>();
    AgencyRegistry.testInject(AgencyRegistrySnapshot(
      links: links,
      index: index,
      forward: (legacy['forward'] as Map).cast<String, dynamic>(),
      multi: (legacy['multi'] as Map).cast<String, dynamic>(),
      institutions: institutions,
      registryVersion: manifest['registry_version'] as String,
      asOfDate: manifest['as_of_date'] as String,
    ));
    try {
      Map<String, dynamic> row(String id, String agency, String code, String answered) => {
        ..._row(id, agency, code),
        '답변일': answered,
      };
      final traffic = [
        row('a1', '경찰청 서울특별시경찰청 서울강서경찰서 교통과', '1810341', '2023-06-02'),
        row('a2', '경찰청 경기도남부경찰청 김포경찰서 교통과', '1814146', '2025-01-02'),
        row('a3', '서울특별시 동작구 생활경제국 주차관리과', '3190275', '2024-07-16'),
        row('a4', '서울특별시 동작구 행정자치국 주차관리과', '3190287', '2026-08-02'),
        row('a5', '경기도 파주시 안전건설교통국 도시경관과', '4060425', '2022-06-02'),
        row('a6', '경기도 김포시 교통건설국 교통과', '4090416', '2024-06-02'),
        row('a7', '전라남도 여수시 교통도로국 주차차량과', '4810475', '2025-01-02'),
        row('a8', '경기도 화성시 교통국 주차화물과', '5530626', '2025-01-02'),
      ];
      final got = LocalDbService.buildStatsCategory(traffic, traffic);
      final agencies = {
        for (final r in (got['by_agency'] as List)) (r['agency_key'] as String): r,
      };
      // 8건 모두 확정 키로 묶인다(미확정 src: 없음). 동작구 2건은 한 키로 합쳐진다.
      expect(
        agencies.keys,
        equals({
          'inst:ag-c1321068',
          'inst:ag-c1811029',
          'inst:ag-c3190000',
          'inst:ag-c4060316',
          'inst:ag-c4090000',
          'inst:ag-c4810000',
          'inst:ag-c4120000',
        }),
      );
      expect((agencies['inst:ag-c3190000']!['total'] as int), equals(2));
      expect(
        agencies['inst:ag-c4810000']!['agency'],
        equals('전라남도 여수시'),
      );
    } finally {
      AgencyRegistry.testInject(null);
    }
  });

  test('vendored resolver matches the shared port on all agency vectors', () {
    // lib/ 는 shared/ 를 import 할 수 없어 동결 복사본을 쓴다.
    // 정본이 바뀌면 이 테스트가 깨져 복사본 갱신을 강제한다.
    Map<String, dynamic> load(String name) => jsonDecode(
      File('shared/agency-region-registry/$name').readAsStringSync(),
    );
    final manifest = load('manifest.json') as Map<String, dynamic>;
    final links =
        (load('data/agency_links.json')['links'] as List);
    final rows = (load('data/agency_index.json')['rows'] as List);
    final index = <String, dynamic>{
      for (final r in rows) (r as List).first as String: (r as List).sublist(1),
    };
    final legacy = load('data/agency_legacy.json') as Map<String, dynamic>;
    final institutions =
        (load('data/agency_institutions.json')['institutions'] as Map)
            .cast<String, dynamic>();
    final version = manifest['registry_version'] as String;
    final asOf = manifest['as_of_date'] as String;
    final cases =
        (load('vectors/resolve_cases.json')['cases'] as List);
    final vendored = AgencyRegistrySnapshot(
      links: links,
      index: index,
      forward: (legacy['forward'] as Map).cast<String, dynamic>(),
      multi: (legacy['multi'] as Map).cast<String, dynamic>(),
      institutions: institutions,
      registryVersion: version,
      asOfDate: asOf,
    );
    final shared = shared_resolve.AgencySnapshot(
      links: links,
      index: index,
      forward: (legacy['forward'] as Map).cast<String, dynamic>(),
      multi: (legacy['multi'] as Map).cast<String, dynamic>(),
      institutions: institutions,
      registryVersion: version,
      asOfDate: asOf,
    );
    var agencyCases = 0;
    for (final c in cases.cast<Map<String, dynamic>>()) {
      if (c['kind'] != 'agency') continue;
      agencyCases++;
      final input = Map<String, dynamic>.from(c['input'] as Map);
      final want = shared_resolve.resolveAgency(
        input['code'] as String?,
        input['name'] as String?,
        input['answered_at'] as String?,
        shared,
      );
      final got = vendored.resolveForTest(
        input['code'] as String?,
        input['name'] as String?,
        input['answered_at'] as String?,
      );
      expect(got, equals(want), reason: '${c['name']}');
    }
    expect(agencyCases, greaterThan(0));
  });
}
