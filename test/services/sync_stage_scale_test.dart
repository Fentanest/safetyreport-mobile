import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/services/sync_run_stage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '500000 staged source IDs retain bounded pages and exact previous-state membership',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final root = await Directory.systemTemp.createTemp('sr_stage_scale_');
      await databaseFactory.setDatabasesPath(root.path);
      SharedPreferences.setMockInitialValues({});
      final store = await CommunityStore.open(
        path: '${root.path}/community.db',
        factory: databaseFactoryFfi,
      );
      final db = await LocalDbService.db;
      final stage = await SyncRunStage.create(db, store);
      final timer = Stopwatch()..start();
      var maxRows = 0;
      PerformanceTrace.observer = (event) {
        if (event['stage'] == 'sync.stage_page') {
          final rows = event['rows'] as int;
          if (rows > maxRows) maxRows = rows;
        }
      };
      try {
        await db.insert('reports', {
          'ID': 'source-0',
          'category': 'traffic',
          '처리상태': '처리중',
        });
        for (var start = 0; start < 500000; start += 200) {
          await stage.addPage(
            List.generate(
              200,
              (i) => {
                'C_NO': 'source-${start + i}',
                'C_STATE': '수용',
                'C_TITLE': '합성 목록',
              },
            ),
          );
        }
        final stagedMs = timer.elapsedMilliseconds;
        expect(await stage.count, 500000);
        await db.update(
          'reports',
          {'처리상태': '수용'},
          where: 'ID=?',
          whereArgs: ['source-0'],
        );
        var visited = 0;
        await for (final page in stage.pages()) {
          if (visited == 0) expect(page.first.previous!['처리상태'], '처리중');
          if (visited > 0) expect(page.first.previous, isNull);
          visited += page.length;
        }
        expect(visited, 500000);
        expect(maxRows, 200);
        expect(await stage.orphanCount, 0);
        expect(await stage.todoCount, 0);
        // Host diagnostics; not Android latency, Dart heap or a percentile.
        // ignore: avoid_print
        print(
          'SR_SYNC_STAGE_HOST rows=500000 staging_ms=$stagedMs total_ms=${timer.elapsedMilliseconds} max_page=$maxRows rss=${ProcessInfo.currentRss} peak_rss=${ProcessInfo.maxRss}',
        );
      } finally {
        PerformanceTrace.observer = null;
        await stage.close();
        await LocalDbService.closeDb();
        await CommunityStore.closeForTest(store.path);
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['SR_LARGE_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
