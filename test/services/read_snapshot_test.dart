import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/performance_trace.dart';
import '../../tool/large_data_fixture.dart';

void main() {
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_snapshot_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDownAll(() async {
    PerformanceTrace.observer = null;
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });
  test(
    'statistics reads a native snapshot while a same-count sync writer commits; next read invalidates',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(
        db,
        Platform.environment['SR_LARGE_TEST'] == '1' ? 500000 : 3000,
      );
      final before = (await db.rawQuery(
        "SELECT COUNT(*) n FROM reports WHERE 답변일 LIKE '2025%' AND 처리상태='수용'",
      )).single['n'];
      final snapshot = Completer<void>();
      PerformanceTrace.observer = (e) {
        if (e['stage'] == 'stats.sql_group' && !snapshot.isCompleted) {
          snapshot.complete();
        }
      };
      final read = LocalDbService.computeStatsBundle(year: '2025');
      await snapshot.future;
      await db.update(
        'reports',
        {'처리상태': '불수용'},
        where: 'ID=?',
        whereArgs: ['fixture-000000054'],
      );
      final old = await read;
      PerformanceTrace.observer = null;
      expect(old['overview']['all']['accept'], before);
      final fresh = await LocalDbService.computeStatsBundle(year: '2025');
      expect(fresh['overview']['all']['accept'], (before as int) - 1);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
  test('queued old-filter summary skips SQL after cancellation', () async {
    final db = await LocalDbService.db;
    await seedLargeDataFixture(db, 1000);
    final entered = Completer<void>(), release = Completer<void>();
    final holding = db.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    var cancelled = false, countQueries = 0;
    PerformanceTrace.observer = (e) {
      if (e['stage'] == 'summary.sql_counts') countQueries++;
    };
    final old = LocalDbService.computeSummary(isCancelled: () => cancelled);
    final rejected = expectLater(old, throwsA(isA<QueryCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancelled = true;
    release.complete();
    await holding;
    await rejected;
    expect(countQueries, 0);
    expect((await LocalDbService.computeSummary()).total, 1000);
    expect(countQueries, 1);
    PerformanceTrace.observer = null;
  });
  test(
    'covering watch count preserves overrides and canonical membership',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 1000);
      await db.insert('report_override', {
        'ID': 'fixture-000000000',
        'column_name': '처리상태',
        'value': '취하',
        'updated_at': 0,
      });
      final page = await LocalDbService.getReportPage(
        scope: 'watchlist',
        excludeWithdraw: true,
        useRepresentativeRecords: true,
      );
      final summary = await LocalDbService.computeSummary(
        excludeWithdraw: true,
        useRepresentativeRecords: true,
      );
      expect(summary.watchlistTotal, page.total);
      expect(
        summary.watchlist.map((r) => r.id).toSet(),
        page.reports.map((r) => r.id).toSet(),
      );
      expect(
        summary.watchlist.any((r) => r.id == 'fixture-000000000'),
        isFalse,
      );
    },
  );
  test(
    'abandoned navigation burst skips native statistics snapshots',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 3000);
      final started = Completer<void>();
      var grouped = 0;
      PerformanceTrace.observer = (e) {
        if (e['stage'] == 'stats.sql_group') {
          grouped++;
          if (!started.isCompleted) started.complete();
        }
      };
      final first = LocalDbService.computeStatsBundle();
      await started.future;
      var cancelled = false;
      final stale = List.generate(
        20,
        (i) => LocalDbService.computeStatsBundle(
          year: '202${i % 7}',
          isCancelled: () => cancelled,
        ).then<Object?>((_) => null, onError: (Object error) => error),
      );
      final current = LocalDbService.computeStatsBundle(year: '2026');
      cancelled = true;
      await first;
      expect(await Future.wait(stale), everyElement(isA<QueryCancelled>()));
      expect((await current)['overview']['all']['total'], greaterThan(0));
      expect(grouped, 2); // Active read and final screen, no stale native work.
      PerformanceTrace.observer = null;
    },
  );
  test(
    'viewport changes reuse full metadata; same-count coordinate edits invalidate',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 1000);
      var scans = 0;
      PerformanceTrace.observer = (e) {
        if (e['stage'] == 'map.sql_meta') scans++;
      };
      final first = await LocalDbService.computeReportMapStats();
      final second = await LocalDbService.computeReportMapStats(
        bounds: [30, 120, 40, 130],
      );
      expect(scans, 1);
      expect(second['meta']['total_reports'], first['meta']['total_reports']);
      await db.update('reports', {'위도': null, '경도': null});
      final changed = await LocalDbService.computeReportMapStats(
        bounds: [30, 120, 40, 130],
      );
      expect(scans, 2);
      expect(changed['meta']['total_reports'], first['meta']['total_reports']);
      expect(changed['meta']['geocoded_reports'], 0);
      PerformanceTrace.observer = null;
    },
  );
  test(
    'missing address drilldown and year groups agree and exclude NULL answer dates',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 100);
      await db.update('reports', {
        '위도': null,
        '경도': null,
        '위반장소': '서울 강서구 등촌동 101',
      });
      final groups = await LocalDbService.computeReportMapMissingGroups(
        year: '2026',
      );
      final rows = groups['groups'] as List;
      expect(rows, isNotEmpty);
      for (final g in rows) {
        final page = await LocalDbService.getReportPage(
          scope: 'missing',
          missingAddress: g['normalized_address'] as String,
          answerYear: '2026',
        );
        expect(page.total, g['report_count']);
        expect(
          page.reports.every((r) => r.responseDate.startsWith('2026')),
          isTrue,
        );
      }
    },
  );
}
