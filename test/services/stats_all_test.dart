import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _cats = ['traffic', 'parking', 'safety', 'living', 'other'];
const _counts = [
  'total', 'fines', 'warnings', 'rejects', 'unconfirmed', 'in_progress',
  'disposition_unknown', 'no_penalty', 'unclassified', 'total_fine_amount',
  'fine_amount_unknown', 'estimated_fine_amount', 'estimated_fine_count',
  'avg_days_count', 'rating_count',
];

void _assertSums(Map<String, dynamic> stats) {
  // by_law 는 분류별 합이 아니다: 전체 탭은 모든 분류 행을 한 범위로 상위 조문에 묶는다(서버와 같은 소속).
  for (final table in [
    'by_agency', 'by_person', 'police_by_agency', 'police_by_person',
    'other_by_agency', 'other_by_person',
  ]) {
    String key(Map row) => jsonEncode(
        [row['agency_key'], if (table.contains('person')) row['person']]);
    final expected = <String, Map<String, int>>{};
    for (final cat in _cats) {
      for (final row in stats[cat][table] as List) {
        final target = expected.putIfAbsent(key(row as Map), () => {
          for (final field in _counts) field: 0,
        });
        for (final field in _counts) {
          target[field] = target[field]! + (row[field] as int);
        }
      }
    }
    final rows = stats['all'][table] as List;
    final actual = {
      for (final row in rows)
        key(row as Map): {for (final field in _counts) field: row[field]},
    };
    expect(actual.length, rows.length, reason: 'unique keys $table');
    expect(actual, expected, reason: table);
  }
  for (final field in ['total_fine_amount', 'estimated_fine_amount', 'estimated_fine_count']) {
    expect(stats['all'][field], _cats.fold<int>(0, (n, c) => n + (stats[c][field] as int)), reason: field);
  }
  expect(stats['all']['available_laws'], {
    for (final c in _cats) ...stats[c]['available_laws'] as List,
  }.toList()..sort());
  expect(stats['all']['has_empty_law'], _cats.any((c) => stats[c]['has_empty_law'] == true));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vector = jsonDecode(File('contracts/stats-all-vectors.json').readAsStringSync()) as Map;
  final rows = (vector['rows'] as List).cast<Map<String, dynamic>>();
  final expected = vector['expected'] as Map;
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('sr_stats_all_');
    await databaseFactory.setDatabasesPath(dir.path);
    final db = await LocalDbService.db;
    for (final row in rows) {
      await db.insert('reports', row);
    }
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  test('all matches category sums in raw/canonical, filters and both withdraw settings', () async {
    for (final rep in [false, true]) {
      for (final ew in [false, true]) {
        for (final law in [null, rows[1]['위반법규'] as String, '도로교통법 제32조', '__없음__', '없는 법규']) {
          final bundle = await LocalDbService.computeStatsBundle(
            useRepresentativeRecords: rep, excludeWithdraw: ew, law: law,
          );
          final stats = bundle['stats'] as Map<String, dynamic>;
          final overview = bundle['overview'] as Map;
          _assertSums(stats);
          expect(overview['all']['total'], _cats.fold<int>(0, (n, c) => n + (overview[c]['total'] as int)));
          if (law == null) {
            expect(overview['all']['total'], expected[ew ? 'total_without_withdraw' : 'total_with_withdraw']);
            expect(stats['all']['total_fine_amount'], expected['confirmed_amount']);
            expect(stats['all']['estimated_fine_amount'], expected['estimated_amount']);
            expect(stats['all']['estimated_fine_count'], expected['estimated_count']);
            expect(stats['all']['available_laws'], contains(rows[1]['위반법규']));
            final shared = (stats['all']['by_agency'] as List).singleWhere((r) => r['agency'] == '합성 공통기관');
            expect(shared['total'], expected['shared_agency_total']);
            expect(shared['avg_days'], expected['shared_agency_avg_days']);
            expect(shared['avg_rating'], expected['shared_agency_avg_rating']);
            // 안전신고에는 제32조제1항만 있다. 분류별 표 제32조에는 빠지지만 전체 표 제32조에는 들어간다.
            final laws = {
              for (final r in stats['all']['by_law'] as List) r['law']: r['total'],
            };
            expect(laws['도로교통법 제32조'], 4);
            expect(laws['도로교통법 제32조제1항'], 2);
            expect((stats['safety']['by_law'] as List).map((r) => r['law']),
                isNot(contains('도로교통법 제32조')));
          }
        }
      }
    }
  });

  test('empty year has an empty all section', () async {
    final stats = await LocalDbService.computeStats(year: '1900');
    _assertSums(stats);
    expect(stats['all']['by_agency'], isEmpty);
    expect(stats['all']['by_law'], isEmpty);
    expect(stats['all']['has_empty_law'], isFalse);
  });

  test('shared vector helper and streaming computation agree on all tables', () async {
    final direct = LocalDbService.buildStatsCategory(rows, rows);
    final streamed = (await LocalDbService.computeStats())['all'];
    expect(streamed, direct);
  });
}
