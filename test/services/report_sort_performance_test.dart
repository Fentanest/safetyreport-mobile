import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/models/report_sort.dart';
import 'package:safetyreport/services/local_db_service.dart';
import '../../tool/large_data_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '50k all sort fields/directions and whole-group pages stay within 5s per query',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('sort-perf-');
      await databaseFactory.setDatabasesPath(dir.path);
      SharedPreferences.setMockInitialValues({});
      try {
        await seedLargeDataFixture(await LocalDbService.db, 50000);
        for (final grouped in [false, true]) {
          for (final field in ReportSortField.values) {
            if (!grouped && field == ReportSortField.duplicateCount) continue;
            for (final asc in [true, false]) {
              final clock = Stopwatch()..start();
              final page = await LocalDbService.getReportPage(
                scope: grouped ? 'duplicates' : '',
                groupPage: grouped,
                sort: ReportSort(field: field, ascending: asc),
                pageSize: grouped ? 20 : 50,
                compact: true,
              );
              clock.stop();
              expect(page.total, grouped ? 10000 : 50000);
              expect(page.reports.length, grouped ? 100 : 50);
              // ignore: avoid_print
              print(
                'sort budget: grouped=$grouped field=${field.name} asc=$asc ${clock.elapsedMilliseconds}ms',
              );
              expect(clock.elapsedMilliseconds, lessThan(5000));
            }
          }
        }
      } finally {
        await LocalDbService.closeDb();
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
