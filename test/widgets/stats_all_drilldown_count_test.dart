import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/large_data_fixture.dart';

/// 통계 전체 탭 카드 → 목록: 카드 건수 = 목록 건수(2026-10-18 Astra 교차 확인).
/// 통계 계산의 정적 대기열이 위젯 시험 사이의 가짜 시간 영역을 넘지 못해, 다른 통계 위젯 시험과 파일을 나눈다.

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets);
}

final _loadedBody = find.textContaining(RegExp(r'^전체 [1-9][\d,]*건 · '));

int _bodyTotal(WidgetTester tester) {
  final text = tester.widgetList<Text>(_loadedBody).last.data!;
  return int.parse(
    RegExp(r'^전체 ([\d,]+)건').firstMatch(text)!.group(1)!.replaceAll(',', ''),
  );
}

Future<ReportProvider> _standaloneProvider(WidgetTester tester) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = Directory.systemTemp.createTempSync('sr_stats_all_drill_');
  SharedPreferences.setMockInitialValues({
    AppPrefsKeys.appMode: 'standalone',
    AppPrefsKeys.standaloneUsername: 'fixture',
    AppPrefsKeys.standalonePhoneNumber: 'fixture',
  });
  final p = ReportProvider();
  addTearDown(
    () => tester.runAsync(() async {
      p.dispose();
      await LocalDbService.closeDb();
      dir.deleteSync(recursive: true);
    }),
  );
  await tester.runAsync(() async {
    await databaseFactory.setDatabasesPath(dir.path);
    await seedLargeDataFixture(await LocalDbService.db, 3300);
    await p.init();
  });
  return p;
}

Future<void> _pumpApp(
  WidgetTester tester,
  ReportProvider provider,
  Widget home,
) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(theme: AppTheme.build(Brightness.light), home: home),
    ),
  );
}

void main() {
  testWidgets('전체 탭 기관 카드 → 목록: 카드 건수 = 목록 건수(조회 조건만, 공용 필터 그대로)', (
    tester,
  ) async {
    final p = await _standaloneProvider(tester);
    await _pumpApp(tester, p, const StatisticsScreen());
    final card = find.textContaining(RegExp(r'^예시(경찰서|\s시청) \d+$'));
    await _waitFor(tester, find.text('상세 통계'));
    final list = find
        .descendant(
          of: find.byKey(const PageStorageKey('stats-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    for (var i = 0; i < 40 && card.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pump();
    }
    await tester.ensureVisible(card.first);
    await tester.pump();
    final cardTotal = int.parse(
      RegExp(r'^총 (\d+)건$')
          .firstMatch(
            tester
                .widgetList<RichText>(
                  find.descendant(
                    of: find
                        .ancestor(of: card.first, matching: find.byType(Card))
                        .first,
                    matching: find.byType(RichText),
                  ),
                )
                .map((t) => t.text.toPlainText())
                .firstWhere((t) => RegExp(r'^총 \d+건$').hasMatch(t)),
          )!
          .group(1)!,
    );
    await tester.tap(card.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _waitFor(tester, _loadedBody);
    expect(_bodyTotal(tester), cardTotal);
    expect(p.filter, const ReportFilter());
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox());
  });
}
