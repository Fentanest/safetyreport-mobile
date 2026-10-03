import 'dart:io';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../tool/large_data_fixture.dart';

void main() {
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_large_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });
  final full = Platform.environment['SR_LARGE_TEST'] == '1';
  for (final n in full ? [0, 1, 3000, 58388, 100000, 500000] : [0, 1, 3000]) {
    test(
      '$n deterministic reports: native grouping, totals, pages, same-count mutations and cancellation',
      () async {
        final db = await LocalDbService.db;
        await seedLargeDataFixture(db, n);
        final expectedRaw = n <= 3000
            ? await db.query(
                LocalDbService.effectiveReportsView,
                columns: [
                  'category',
                  '처리상태',
                  '범칙금_과태료',
                  '처리기관',
                  '처리기관코드',
                  '담당자',
                  '별점',
                  '신고일',
                  '답변일',
                  '신고명',
                  '위반법규',
                  'entry_value',
                  '차량번호',
                  '발생시각',
                  '사진_첫촬영',
                  '사진_끝촬영',
                ],
              )
            : <Map<String, Object?>>[];
        final expected = LocalDbService.summarizeOverviewRows(expectedRaw);
        final t = Stopwatch()..start();
        final events = <Map<String, Object?>>[];
        PerformanceTrace.observer = events.add;
        final summary = await LocalDbService.computeSummary();
        final actual = await LocalDbService.computeStatsBundle();
        PerformanceTrace.observer = null;
        expect(summary.total, n);
        if (n <= 3000) expect(actual['overview']['all'], expected);
        expect(actual['overview']['all']['total'], n);
        expect(
          events
              .where((e) => e['stage'] == 'stats.sql_page')
              .every((e) => (e['rows'] as int) <= 1000),
          isTrue,
        );
        final canonical = await LocalDbService.computeStatsBundle(
          useRepresentativeRecords: true,
        );
        final removed = Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM duplicate_member m JOIN duplicate_group g USING(group_id) WHERE g.status='confirmed_duplicate' AND m.is_representative=0",
          ),
        )!;
        expect(canonical['overview']['all']['total'], n - removed);
        final map = await LocalDbService.computeReportMapStats(
          useRepresentativeRecords: true,
        );
        expect((map['points'] as List).length, lessThanOrEqualTo(1024));
        expect(map['meta']['total_reports'], n - removed);
        expect(
          (map['points'] as List).fold<int>(
            0,
            (sum, r) => sum + (r['total'] as int),
          ),
          map['meta']['geocoded_reports'],
        );
        final first = await LocalDbService.getReportPage();
        expect(first.total, n);
        expect(first.reports.length, n.clamp(0, 200));
        if (n > 200) {
          final next = await LocalDbService.getReportPage(page: 1);
          expect(
            first.reports
                .map((r) => r.id)
                .toSet()
                .intersection(next.reports.map((r) => r.id).toSet()),
            isEmpty,
          );
        }
        if (n > 0) {
          final before = actual['overview']['all']['accept'] as int;
          await db.update(
            'reports',
            {'처리상태': '불수용'},
            where: 'ID=?',
            whereArgs: ['fixture-000000000'],
          );
          final after = await LocalDbService.computeStatsBundle();
          expect(after['overview']['all']['accept'], before - 1);
          expect(
            (await LocalDbService.computeSummary()).acceptCount,
            summary.acceptCount - 1,
          );
          await db.insert('report_override', {
            'ID': 'fixture-000000000',
            'column_name': '처리상태',
            'value': '수용',
            'updated_at': 0,
          });
          expect(
            (await LocalDbService.computeStatsBundle())['overview']['all']['accept'],
            before,
          );
          expect(
            (await LocalDbService.computeSummary()).acceptCount,
            summary.acceptCount,
          );
          await db.delete(
            'reports',
            where: 'ID=?',
            whereArgs: ['fixture-000000000'],
          );
          expect(
            (await LocalDbService.computeStatsBundle())['overview']['all']['total'],
            n - 1,
          );
          expect((await LocalDbService.computeSummary()).total, n - 1);
        }
        await expectLater(
          LocalDbService.computeStatsBundle(
            year: '1900',
            isCancelled: () => true,
          ),
          throwsA(isA<QueryCancelled>()),
        );
        expect(
          await db.rawQuery(
            "SELECT name FROM sqlite_temp_master WHERE name LIKE 'sr_stats_%'",
          ),
          isEmpty,
        );
        // Host test timings validate fixture correctness only, not product performance.
        // ignore: avoid_print
        print(
          'SR_HOST rows=$n ms=${t.elapsedMilliseconds} rss=${ProcessInfo.currentRss}',
        );
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
  test(
    'SQL list filtering agrees with the existing ReportFilter predicate',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 100);
      final all = await LocalDbService.getAllReports();
      final provider = ReportProvider();
      for (final f in [
        const ReportFilter(name: '버스&위반,합성 신고 1'),
        const ReportFilter(ratings: ['__none__', '3']),
        const ReportFilter(statuses: ['처리중', '일부수용']),
        const ReportFilter(
          reportDateStart: '2024',
          responseDateEnd: '2025-12-31',
        ),
        const ReportFilter(law: '__없음__'),
        const ReportFilter(agency: '시청', onlyPolice: false),
        const ReportFilter(reportContent: '합성 긴', supplementCount: '0,1'),
      ]) {
        final expected = all
            .where((r) => provider.matchesFilter(r, filter: f))
            .map((r) => r.id)
            .toSet();
        final result = await LocalDbService.getReportPage(filter: f);
        expect(
          result.reports.map((r) => r.id).toSet(),
          expected,
          reason: f.activeLabels.join(','),
        );
        expect(result.total, expected.length);
      }
    },
  );
}
