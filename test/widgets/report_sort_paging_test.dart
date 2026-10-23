import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/models/report_sort.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import '../../tool/large_data_fixture.dart';

void main() {
  testWidgets(
    'changing sort returns from next page to page one and scrolls to top',
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
        dir = await Directory.systemTemp.createTemp('sort-scroll-');
        await databaseFactory.setDatabasesPath(dir.path);
        await seedLargeDataFixture(await LocalDbService.db, 2100);
        await provider.init();
      });
      addTearDown(() async {
        provider.dispose();
        await LocalDbService.closeDb();
        await dir.delete(recursive: true);
      });
      var sort = ReportSort.defaults;
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    TextButton(
                      onPressed: () => setState(
                        () => sort = const ReportSort(
                          field: ReportSortField.reportDate,
                          ascending: true,
                        ),
                      ),
                      child: const Text('change sort'),
                    ),
                    Expanded(
                      child: LocalPagedReportList(
                        category: 'traffic',
                        sort: sort,
                        itemBuilder: (_, r) =>
                            SizedBox(height: 70, child: Text(r.id)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> ready() async {
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(ListView).evaluate().isNotEmpty) {
            return;
          }
        }
        fail('list not ready');
      }

      await ready();
      await tester.tap(find.byTooltip('다음 페이지'));
      await tester.pump();
      await ready();
      expect(find.textContaining('2 / 4 페이지'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -350));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      expect(controller.offset, greaterThan(0));
      await tester.tap(find.text('change sort'));
      await tester.pump();
      await ready();
      expect(find.textContaining('1 / 4 페이지'), findsOneWidget);
      expect(controller.offset, 0);
      await tester.runAsync(() async {
        final db = await LocalDbService.db;
        await db.transaction((_) async {});
      });
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
