import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../tool/large_data_fixture.dart';

void main() {
  testWidgets(
    'Standalone prefetch removes next-page SQL wait and revision invalidates cache',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'appMode': 'standalone',
        'standaloneUsername': 'fixture',
        'standalonePhoneNumber': 'fixture',
        'standaloneExcludeWithdraw': false,
        'standaloneUseRepresentativeRecords': false,
      });
      late Directory dir;
      final provider = ReportProvider();
      await tester.runAsync(() async {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        dir = Directory.systemTemp.createTempSync('sr_prefetch_');
        await databaseFactory.setDatabasesPath(dir.path);
        await seedLargeDataFixture(await LocalDbService.db, 2100);
        await provider.init();
      });
      var reads = 0;
      PerformanceTrace.observer = (e) {
        if (e['stage'] == 'list.sql_page') reads++;
      };
      addTearDown(() async {
        PerformanceTrace.observer = null;
        provider.dispose();
        await LocalDbService.closeDb();
        dir.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: LocalPagedReportList(
                category: 'traffic',
                itemBuilder: (_, r) => Text(r.id),
              ),
            ),
          ),
        ),
      );
      Future<void> waitUntil(bool Function() ready) async {
        for (var i = 0; i < 200 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
      }

      await waitUntil(() => reads == 2);
      // SQL timing fires before the read transaction closes; wait for that fence.
      await tester.runAsync(() async {
        final db = await LocalDbService.db;
        await db.transaction((_) async {});
      });
      await tester.pump();
      // The prefetched second page renders in one frame, before a new SQL read completes.
      await tester.tap(find.byTooltip('다음 페이지'));
      await tester.pump();
      expect(find.textContaining('2 / 4 페이지'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await waitUntil(() => reads == 3); // only the third page is fetched
      await tester.tap(find.byTooltip('이전 페이지'));
      await tester.pump();
      expect(reads, 3);
      provider.markDataChanged();
      await tester.pump();
      await waitUntil(() => reads == 5);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
