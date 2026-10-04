// EO R-02: 목록 필터 — 서버 tests/test_report_filter_spec.py 와 같은 파일 contracts/report-filter-vectors.json
// (두 레포 바이트 동일)로 SQL 목록(ReportQuery)과 메모리 목록(ReportProvider)이 같은 행을 고르는지 본다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_filter.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/report_filter_spec.dart';
import 'package:safetyreport/services/report_query.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _columns = [
  '신고명',
  '위반장소',
  '처리기관',
  '신고일',
  '발생일자',
  '답변일',
  '발생시각',
  '위반법규',
  '처리상태',
];

ReportFilter _filterOf(Map<String, dynamic> f) => ReportFilter(
  name: f['reportName'] as String? ?? '',
  location: f['location'] as String? ?? '',
  agency: f['agency'] as String? ?? '',
  law: f['law'] as String? ?? '',
  statuses: ((f['statuses'] as List?) ?? const []).cast<String>(),
  reportDateStart: f['reportDateStart'] as String? ?? '',
  reportDateEnd: f['reportDateEnd'] as String? ?? '',
  occurDateStart: f['occurDateStart'] as String? ?? '',
  occurDateEnd: f['occurDateEnd'] as String? ?? '',
  responseDateStart: f['responseDateStart'] as String? ?? '',
  responseDateEnd: f['responseDateEnd'] as String? ?? '',
  occurTimeStart: f['occurTimeStart'] as String? ?? '',
  occurTimeEnd: f['occurTimeEnd'] as String? ?? '',
  excludePolice: f['excludePolice'] == true,
  onlyPolice: f['onlyPolice'] == true,
);

void main() {
  final doc =
      jsonDecode(
            File('contracts/report-filter-vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final rows = (doc['rows'] as List).cast<Map<String, dynamic>>();
  final cases = [
    for (final c in (doc['cases'] as List).cast<Map<String, dynamic>>())
      if ((c['targets'] as List).contains('mobile_list')) c,
  ];

  test('모바일 목록 대상 벡터가 충분하다', () {
    expect(cases.length, greaterThan(20));
  });

  group('SQL 목록(ReportQuery)', () {
    late Database db;
    setUpAll(() async {
      sqfliteFfiInit();
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'CREATE TABLE r (idx INTEGER, ${_columns.map((c) => '$c TEXT').join(', ')}, '
        '신고번호 TEXT, ID TEXT, 별점사유 TEXT, 담당자 TEXT, 차량번호 TEXT, 범칙금_과태료 TEXT, '
        '보완횟수 INTEGER, 신고내용 TEXT, 처리내용 TEXT, 별점 INTEGER, 만족도조사여부 TEXT)',
      );
      for (var i = 0; i < rows.length; i++) {
        await db.insert('r', {
          'idx': i,
          for (final c in _columns) c: rows[i][c],
        });
      }
    });
    tearDownAll(() => db.close());

    test('벡터와 같은 행', () async {
      for (final c in cases) {
        final q = ReportQuery(
          _filterOf(c['filters'] as Map<String, dynamic>),
          agencyExpression: "IFNULL(처리기관,'')",
        );
        final got = (await db.rawQuery(
          'SELECT idx FROM r WHERE ${q.where} ORDER BY idx',
          q.args,
        )).map((r) => r['idx']).toList();
        expect(got, c['expected'], reason: '${c['name']}: ${q.where}');
      }
    });
  });

  group('메모리 목록(ReportProvider)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('벡터와 같은 행', () {
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      final reports = [
        for (final row in rows)
          Report.fromJson({for (final c in _columns) c: row[c]}),
      ];
      for (final c in cases) {
        final filter = _filterOf(c['filters'] as Map<String, dynamic>);
        final got = [
          for (var i = 0; i < reports.length; i++)
            if (provider.matchesFilter(reports[i], filter: filter)) i,
        ];
        expect(got, c['expected'], reason: c['name'] as String);
      }
    });
  });

  test('순수 판정 도우미', () {
    expect(ReportFilterSpec.parseGroups(' A & b , ,c '), [
      ['a', 'b'],
      ['c'],
    ]);
    expect(ReportFilterSpec.parseGroups(' , & '), isEmpty);
    expect(
      ReportFilterSpec.rangeKey('2024-02-29 10:00', time: false),
      '2024-02-29',
    );
    expect(ReportFilterSpec.rangeKey('2023-02-29', time: false), isNull);
    expect(ReportFilterSpec.rangeKey('08:05:30', time: true), '08:05');
    expect(ReportFilterSpec.rangeKey('24:00', time: true), isNull);
  });
}
