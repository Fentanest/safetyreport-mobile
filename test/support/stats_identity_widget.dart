import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'stats_identity_fixture.dart';

Future<void> _waitFor(WidgetTester tester, Finder finder, {int tries = 150}) async {
  for (var i = 0; i < tries && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets);
}

/// 호출 파일당 통계 위젯 시험 하나. 같은 시험 안에서 기관·담당자 카드를 차례로 확인한다.
/// 카드가 적어 통계 화면 아래 Sunwi(전국 현황)가 바로 그려지고 외부 조회를 지역마다 보낸다 — 시험 HTTP 는 즉시 빈 정상 응답(재시도 없음).
Future<void> checkIdentityCards(WidgetTester tester, String category) =>
    http.runWithClient(() => _checkIdentityCards(tester, category),
        () => MockClient((_) async => http.Response('{"result": []}', 200)));

Future<void> _checkIdentityCards(WidgetTester tester, String category) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = Directory.systemTemp.createTempSync('sr-identity-widget-');
  SharedPreferences.setMockInitialValues({
    AppPrefsKeys.appMode: 'standalone',
    AppPrefsKeys.standaloneUsername: 'fixture',
    AppPrefsKeys.standalonePhoneNumber: 'fixture',
  });
  final provider = ReportProvider();
  addTearDown(() => tester.runAsync(() async {
    provider.dispose();
    await LocalDbService.closeDb();
    AgencyRegistry.testInject(null);
    dir.deleteSync(recursive: true);
  }));
  await tester.runAsync(() async {
    await databaseFactory.setDatabasesPath(dir.path);
    await seedIdentityReports();
    // 이 위젯 시험은 동명 1건/200건 카드만. 옛 기관은 로컬 검색 시험에서 검증한다.
    await (await LocalDbService.db).delete('reports', where: 'ID = ?', whereArgs: ['old']);
    await provider.init();
  });
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: provider,
    child: MaterialApp(theme: AppTheme.build(Brightness.light), home: const StatisticsScreen()),
  ));
  await _waitFor(tester, find.text('상세 통계'));
  if (category != 'all') {
    await tester.tap(find.byKey(ValueKey('stats-category-$category')));
    await tester.pump();
  }
  for (final person in [false, true]) {
    if (person) {
      // 기관 카드까지 내려간 목록을 맨 위로 올려 보기 선택(기관별/담당자별)을 누를 수 있게 한다.
      final top = find.descendant(of: find.byKey(const PageStorageKey('stats-list')),
          matching: find.byType(Scrollable)).first;
      for (var i = 0; i < 40 && find.text('담당자별').hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(top, const Offset(0, 300));
        await tester.pump();
      }
      await tester.tap(find.text('담당자별').hitTestable());
      await tester.pump();
    }
    final one = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == '총 1건');
    final scroll = find.descendant(of: find.byKey(const PageStorageKey('stats-list')),
        matching: find.byType(Scrollable)).first;
    for (var i = 0; i < 40 && one.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -250));
      await tester.pump();
    }
    await _waitFor(tester, one);
    await tester.ensureVisible(one);
    await tester.tap(one);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final body = find.textContaining(RegExp(r'^전체 1건 · '));
    await _waitFor(tester, body, tries: 300);
    final lists = tester.widgetList<LocalPagedReportList>(find.byType(LocalPagedReportList));
    expect(lists.any((w) => w.filter.agencyKey == 'src:9999991:합성기관' &&
        w.filter.managerExact == person && w.predicate == null), isTrue);
    expect(find.text('정확한 대상 신고'), findsWidgets);
    expect(provider.filter, const ReportFilter());
    Navigator.of(tester.element(find.byType(LocalPagedReportList))).pop();
    for (var i = 0; i < 20 && find.byType(LocalPagedReportList).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(LocalPagedReportList), findsNothing);
  }
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}
