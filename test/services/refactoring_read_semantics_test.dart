import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('sr_read_semantics_');
    await databaseFactory.setDatabasesPath(root.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await LocalDbService.closeDb();
    await root.delete(recursive: true);
  });

  test(
    'overlapping disposition buckets never subtract away truly unknown reports',
    () async {
      final db = await LocalDbService.db;
      for (var i = 0; i < 3; i++) {
        await db.insert('reports', {
          'ID': 'R$i',
          'category': 'traffic',
          '처리상태': i == 1 ? '불수용' : '수용',
          '범칙금_과태료': i == 2 ? '' : '과태료 경고',
          '위도': 37.5,
          '경도': 127.0,
          '주소정규화': '합성 주소',
        });
      }
      final result = await LocalDbService.computeReportMapStats();
      final points = result['points'] as List;
      final totals = <String, int>{};
      for (final point in points) {
        for (final item in point['disposition_breakdown'] as List) {
          totals[item['label'] as String] =
              (totals[item['label']] ?? 0) + (item['count'] as int);
        }
      }
      expect(totals, {'과태료': 2, '경고/범칙금': 2, '불수용/기타': 1, '미확인': 1});
      expect(result['meta']['total_reports'], 3);
    },
  );

  test(
    'world coordinates and missing groups use the same population',
    () async {
      final db = await LocalDbService.db;
      for (final row in [
        {'ID': 'valid', '위도': 51.5, '경도': -0.1},
        {'ID': 'outside', '위도': 91.0, '경도': 127.0},
        {'ID': 'missing', '위도': null, '경도': null},
      ]) {
        await db.insert('reports', {
          ...row,
          'category': 'other',
          '위반장소': '합성 주소',
          '처리상태': '수용',
        });
      }
      final map = await LocalDbService.computeReportMapStats();
      final missing = await LocalDbService.computeReportMapMissingGroups();
      final page = await LocalDbService.getReportPage(scope: 'missing');
      expect(map['meta']['geocoded_reports'], 1);
      expect(missing['meta']['report_count'], 2);
      expect(page.total, 2);
      expect(page.reports.map((r) => r.id).toSet(), {'outside', 'missing'});
    },
  );

  test('invalid calendar days affect only the processing-duration sample', () {
    final stats = LocalDbService.buildStatsCategory([
      {
        'category': 'traffic',
        '처리기관': '합성 기관',
        '담당자': '합성 담당자',
        '처리상태': '수용',
        '신고일': '2026-02-30',
        '답변일': '2026-03-05',
        '별점': 5,
      },
      {
        'category': 'traffic',
        '처리기관': '합성 기관',
        '담당자': '합성 담당자',
        '처리상태': '수용',
        '신고일': '2026-03-01',
        '답변일': '2026-03-05',
        '별점': 3,
      },
    ], []);
    final agency = (stats['by_agency'] as List).single;
    expect(agency['total'], 2);
    expect(agency['avg_days_count'], 1);
    expect(agency['avg_days'], 4.0);
    expect(agency['rating_count'], 2);
    expect(agency['avg_rating'], 4.0);
  });

  test(
    'recent answers retain exact totals and disjoint pages beyond the preview cap',
    () async {
      final db = await LocalDbService.db;
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final batch = db.batch();
      for (var i = 0; i < 1001; i++) {
        batch.insert('reports', {
          'ID': 'R${i.toString().padLeft(4, '0')}',
          '신고번호': 'SPP-$i',
          'category': 'other',
          '처리상태': '수용',
          '답변일': today,
          'synced_at': i,
        });
      }
      batch.insert('reports', {
        'ID': 'not-completed',
        'category': 'other',
        '처리상태': '취하',
        '답변일': today,
      });
      await batch.commit(noResult: true);
      final first = await LocalDbService.getReportPage(scope: 'recent');
      final second = await LocalDbService.getReportPage(
        scope: 'recent',
        page: 1,
      );
      final last = await LocalDbService.getReportPage(scope: 'recent', page: 5);
      expect([first.total, second.total, last.total], [1001, 1001, 1001]);
      expect(
        [first.reports.length, second.reports.length, last.reports.length],
        [200, 200, 1],
      );
      expect(
        first.reports
            .map((r) => r.id)
            .toSet()
            .intersection(second.reports.map((r) => r.id).toSet()),
        isEmpty,
      );
      expect(first.reports.first.id, 'R1000');
      expect(last.reports.single.id, 'R0000');
    },
  );
}
