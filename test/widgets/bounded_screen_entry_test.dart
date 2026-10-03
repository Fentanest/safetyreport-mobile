import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/dashboard_screen.dart';
import 'package:safetyreport/screens/search_screen.dart';
import 'package:safetyreport/screens/data_editor_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/local_db_service.dart';
import '../../tool/large_data_fixture.dart';

class _EntryProvider extends ReportProvider {
  int summaries = 0, categories = 0;
  @override
  Future<void> fetchSummary() async {
    summaries++;
  }

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {
    categories++;
  }

  @override
  Future<void> fetchCategoryReports(String category) async {
    categories++;
  }
}

void main() {
  testWidgets(
    'dashboard and empty search never preload category Report bodies',
    (tester) async {
      final p = _EntryProvider();
      addTearDown(p.dispose);
      Future<void> show(Widget screen) async {
        await tester.pumpWidget(
          ChangeNotifierProvider<ReportProvider>.value(
            value: p,
            child: MaterialApp(home: screen),
          ),
        );
        await tester.pump();
      }

      await show(const DashboardScreen());
      expect(p.summaries, 1);
      expect(p.categories, 0);
      await show(const SearchScreen());
      expect(p.categories, 0);
      expect(find.text('검색 조건을 설정하세요.'), findsOneWidget);
    },
  );

  test(
    'legacy category refresh is bounded and filter metadata includes rows beyond its page',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('sr_entry_');
      await databaseFactory.setDatabasesPath(dir.path);
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'standalone',
        AppPrefsKeys.standaloneUsername: 'fixture',
        AppPrefsKeys.standalonePhoneNumber: 'fixture',
      });
      final p = ReportProvider();
      addTearDown(() async {
        p.dispose();
        await LocalDbService.closeDb();
        dir.deleteSync(recursive: true);
      });
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 3000);
      await db.update(
        'reports',
        {'처리상태': '사용자 상태', '위반법규': '페이지 밖 법규'},
        where: 'ID=?',
        whereArgs: ['fixture-000000000'],
      );
      await p.init();
      await p.ensureCategoryReportsLoaded();
      expect(p.trafficReports.length, 200);
      expect(p.parkingReports.length, 200);
      expect(p.otherReports.length, 200);
      expect(
        [
          ...p.trafficReports,
          ...p.parkingReports,
          ...p.otherReports,
        ].any((r) => r.id == 'fixture-000000000'),
        isFalse,
      );
      await p.fetchFilterOptions();
      expect(p.availableStatuses, contains('사용자 상태'));
      expect(p.availableLaws, contains('페이지 밖 법규'));
      final summary = await LocalDbService.computeSummary();
      expect(summary.total, 3000);
    },
  );
  testWidgets(
    'editor renders native pages and retains record editing without category preloading',
    (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('sr_editor_page_');
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'standalone',
        AppPrefsKeys.standaloneUsername: 'fixture',
        AppPrefsKeys.standalonePhoneNumber: 'fixture',
      });
      final p = ReportProvider();
      addTearDown(() async {
        p.dispose();
        await LocalDbService.closeDb();
        dir.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        await databaseFactory.setDatabasesPath(dir.path);
        await seedLargeDataFixture(await LocalDbService.db, 3000);
        await p.init();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: DataEditorPanel())),
        ),
      );
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(finder, findsOneWidget);
      }

      await waitFor(find.text('전체 998건 · 1 / 5 페이지'));
      expect(p.trafficReports, isEmpty);
      await waitFor(find.text('신고번호 SPP-000002997'));
      await tester.tap(find.byTooltip('다음 페이지'));
      await waitFor(find.text('전체 998건 · 2 / 5 페이지'));
      await waitFor(find.text('신고번호 SPP-000002397'));
      await tester.tap(find.text('신고번호 SPP-000002397'));
      await waitFor(find.text('신고 기본 정보'));
      expect(find.textContaining('fixture-000002397'), findsWidgets);
      // Cancel this synthetic editor without submitting any mutation.
      Navigator.of(tester.element(find.text('신고 기본 정보'))).pop();
      await tester.pumpAndSettle();
      expect(p.trafficReports, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
