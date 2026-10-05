import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/selection_action_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/large_data_fixture.dart';

/// WP4: 신고내역 앱바 건수 배지(SQ-U01)와 드릴다운의 지역 필터(SQ-U02).

Report _report(String number, {String manager = '담당자 가'}) => Report(
  id: 'id-$number',
  reportNumber: number,
  name: '테스트 신고 $number',
  date: '2026-08-14',
  responseDate: '',
  agency: '예시 교통 담당 기관',
  manager: manager,
  status: '처리중',
  result: '',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '도로교통법',
  location: '서울',
  occurrenceDate: '2026-08-13',
  occurrenceTime: '12:00',
  reportContent: '신고 내용',
  processContent: '처리 내용',
  category: 'traffic',
);

/// Client 모드: 서버 페이지가 전체 1,234건 중 한 페이지만 돌려준다.
class _ClientProvider extends ReportProvider {
  final List<Report> traffic = [
    _report('SPP-2608-0000001'),
    _report('SPP-2608-0000002', manager: '담당자 나'),
    for (var i = 2; i < 1234; i++)
      _report(
        'SPP-2608-${(i + 1).toString().padLeft(7, '0')}',
        manager: i == 1233 ? '담당자 가' : '담당자 나',
      ),
  ];
  final List<ReportFilter> filtersSeen = [];
  int categoryLoads = 0;

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (
    reports: category == 'traffic'
        ? traffic.skip(offset).take(limit).toList()
        : <Report>[],
    total: category == 'traffic' ? 1234 : 0,
  );

  @override
  Future<void> fetchCategoryReports(String category) async {
    categoryLoads++;
  }

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {}

  @override
  Future<void> fetchDuplicateReports() async {}

  @override
  void setFilter(ReportFilter filter) {
    filtersSeen.add(filter);
    super.setFilter(filter);
  }

  final List<Report> duplicates = [
    _report('SPP-2608-0000101'),
    _report('SPP-2608-0000102'),
  ];

  @override
  List<Report> get duplicateReports => duplicates;

  @override
  List<Report> get filteredDuplicateReports => duplicates;
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

/// 실제 sqflite(ffi) 조회는 runAsync 안에서만 진행된다.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets);
}

/// 조회가 끝난 본문(초기값 "전체 0건" 이 아닌 것).
final _loadedBody = find.textContaining(RegExp(r'^전체 [1-9][\d,]*건 · '));

String _comma(int v) =>
    v.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// 본문(LocalPagedReportList)의 "전체 N건 · ..." 에서 N 을 읽는다.
int _bodyTotal(WidgetTester tester) {
  final text = tester.widgetList<Text>(_loadedBody).last.data!;
  return int.parse(
    RegExp(r'^전체 ([\d,]+)건').firstMatch(text)!.group(1)!.replaceAll(',', ''),
  );
}

Finder _inAppBar(Finder f) =>
    find.descendant(of: find.byType(AppBar), matching: f);

Future<ReportProvider> _standaloneProvider(WidgetTester tester) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = Directory.systemTemp.createTempSync('sr_list_badge_');
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

void main() {
  group('SQ-U01 앱바 건수 배지는 페이지 목록의 전체 건수', () {
    testWidgets('Standalone: 필터 없음 → DB 전체 건수(천 단위 쉼표)', (tester) async {
      final p = await _standaloneProvider(tester);
      await _pumpApp(tester, p, const ReportListScreen());
      await _waitFor(tester, _loadedBody);
      await tester.pump();
      final total = _bodyTotal(tester);
      expect(total, greaterThanOrEqualTo(1000));
      expect(_inAppBar(find.text('${_comma(total)}건')), findsOneWidget);
      expect(_inAppBar(find.text('0건')), findsNothing);

      // 다른 분류 탭으로 넘기면 그 탭의 전체 건수로 바뀐다.
      await tester.tap(find.text('주정차'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await _waitFor(tester, _loadedBody);
      expect(_loadedBody, findsOneWidget, reason: '전환이 끝나면 주정차 페이지만 남는다');
      final parkingTotal = _bodyTotal(tester);
      expect(_inAppBar(find.text('${_comma(parkingTotal)}건')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Standalone: 필터 적용 → "검색 N건" 은 조건에 맞는 DB 건수', (tester) async {
      final p = await _standaloneProvider(tester);
      p.setFilter(const ReportFilter(agency: '예시경찰서 2'));
      await _pumpApp(tester, p, const ReportListScreen());
      await _waitFor(tester, _loadedBody);
      await tester.pump();
      final total = _bodyTotal(tester);
      expect(total, greaterThan(0));
      expect(total, lessThan(1000));
      expect(_inAppBar(find.text('검색 ${_comma(total)}건')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('SQ-U01 Client', () {
    testWidgets('필터 없음 → 서버 페이지의 전체 건수', (tester) async {
      final p = _ClientProvider();
      addTearDown(p.dispose);
      await _pumpApp(tester, p, const ReportListScreen());
      await tester.pump();
      await tester.pump();
      expect(_inAppBar(find.text('1,234건')), findsOneWidget);
    });

    testWidgets('중복차량 탭: 배지·선택·일괄 선택이 그 탭의 목록을 쓴다', (tester) async {
      final p = _ClientProvider();
      addTearDown(p.dispose);
      await _pumpApp(tester, p, const ReportListScreen(initialTabIndex: 3));
      await tester.pump();
      await tester.pump();
      expect(_inAppBar(find.text('2건')), findsOneWidget);

      await tester.longPress(find.text('테스트 신고 SPP-2608-0000101'));
      await tester.pump();
      expect(_inAppBar(find.text('1개 선택됨')), findsOneWidget);
      // 예전에는 분류 목록에서 찾아 빈 목록을 넘겼다.
      expect(
        tester
            .widget<SelectionActionBar>(find.byType(SelectionActionBar))
            .selectedReports
            .map((r) => r.reportNumber),
        ['SPP-2608-0000101'],
      );
      await tester.tap(find.text('일괄 선택'));
      await tester.pump();
      expect(_inAppBar(find.text('2개 선택됨')), findsOneWidget);
      expect(
        tester
            .widget<SelectionActionBar>(find.byType(SelectionActionBar))
            .selectedReports,
        hasLength(2),
      );
    });

    testWidgets('필터 있음 → 마지막 서버 페이지까지 검색해 정확한 배지를 표시한다', (tester) async {
      final p = _ClientProvider();
      addTearDown(p.dispose);
      p.setFilter(const ReportFilter(manager: '담당자 가'));
      await _pumpApp(tester, p, const ReportListScreen());
      await tester.pump();
      await tester.pump();
      expect(_inAppBar(find.text('검색 2건')), findsOneWidget);
      expect(find.textContaining('전체 2건'), findsOneWidget);
      expect(find.text('테스트 신고 SPP-2608-0001234'), findsOneWidget);
    });
  });

  group('SQ-U02 드릴다운은 앱 전체 필터를 바꾸지 않는다', () {
    testWidgets('상세 시트 "같은 조건" → 목록 → 뒤로: 신고내역 탭 필터 그대로', (tester) async {
      final p = _ClientProvider();
      addTearDown(p.dispose);
      SharedPreferences.setMockInitialValues({});
      await _pumpApp(tester, p, const ReportListScreen());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('테스트 신고 SPP-2608-0000001'));
      await tester.pumpAndSettle();
      // 상세 시트의 담당자 값(링크)을 누른다.
      await tester.tap(find.text('담당자 가').last);
      await tester.pumpAndSettle();

      // 드릴다운 화면: 제목에 조건, 목록은 조건으로 걸러짐, 공용 필터는 그대로.
      expect(find.text('담당자 가 · 신고'), findsOneWidget);
      expect(find.text('담당자: 담당자 가'), findsOneWidget);
      expect(find.text('테스트 신고 SPP-2608-0000002'), findsNothing);
      expect(p.filter, const ReportFilter());
      expect(p.hasFilter, isFalse);
      expect(p.filtersSeen, isEmpty);
      // SQ-P09: 분류만 확인하고 200건 목록을 읽지 않는다.
      expect(p.categoryLoads, 0);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('신고내역'), findsOneWidget);
      expect(find.text('담당자: 담당자 가'), findsNothing);
      expect(find.text('테스트 신고 SPP-2608-0000002'), findsOneWidget);
      expect(p.filter, const ReportFilter());
    });

    testWidgets('드릴다운 화면의 검색/필터는 그 화면에만 적용된다', (tester) async {
      final p = _ClientProvider();
      addTearDown(p.dispose);
      await _pumpApp(
        tester,
        p,
        const ReportListScreen(
          filter: ReportFilter(manager: '담당자 가'),
          title: '담당자 가 · 신고',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('담당자 가 · 신고'), findsOneWidget);
      await tester.tap(find.byTooltip('검색/필터'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('전체 초기화'));
      await tester.pumpAndSettle();
      expect(p.filter, const ReportFilter());
      expect(p.filtersSeen, isEmpty);
      expect(find.text('담당자: 담당자 가'), findsNothing);
      expect(find.text('테스트 신고 SPP-2608-0000002'), findsOneWidget);
    });

    testWidgets('통계 기관 카드 → 목록 → 뒤로: 공용 필터 그대로', (tester) async {
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
      final agency = tester.widget<Text>(card.first).data!;
      await tester.tap(card.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, _loadedBody);
      expect(find.text('$agency · 신고'), findsOneWidget);
      expect(find.text('기관: $agency'), findsOneWidget);
      expect(p.filter, const ReportFilter());
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(p.filter, const ReportFilter());
      expect(p.hasFilter, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
