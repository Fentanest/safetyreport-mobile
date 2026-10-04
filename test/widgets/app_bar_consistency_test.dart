// SQ-U16: 하단 5개 탭 앱바는 모두 설정으로 끝나고 탭별 동작은 그 왼쪽에 둔다. 제목은 하단 탭 이름과 같다.
// 목록형 화면의 검색/필터는 앱바 아이콘 하나 + 조건 칩 줄(칩 × 로 그 조건만 해제, "초기화"로 모두 해제).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/dashboard_screen.dart';
import 'package:safetyreport/screens/notifications_screen.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/screens/report_management_screen.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/sr_app_bar_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _OpenGate extends CommunityGate {
  _OpenGate() : super(configStatus: () => 'ok');

  @override
  bool get canEnter => true;

  @override
  bool get isChecked => true;

  @override
  Future<GateState> refreshNow({bool silent = false}) async => state;

  @override
  void startPolling() {}
}

class _StatsProvider extends ReportProvider {
  final DashboardStats _fixed = DashboardStats.fromJson({'total': 1});

  @override
  DashboardStats? get stats => _fixed;

  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> fetchWatchlistNumbers() async {}
}

/// Client 신고내역: 서버 페이지가 비어 있는 목록.
class _ClientProvider extends ReportProvider {
  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (reports: <Report>[], total: 0);

  @override
  Future<void> fetchCategoryReports(String category) async {}

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {}

  @override
  Future<void> fetchDuplicateReports() async {}
}

const _perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, null);
    StandaloneAuthService.stopKeepAlive();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  AppBar appBarOf(WidgetTester tester, Type screen) => tester.widget<AppBar>(
    find
        .descendant(of: find.byType(screen), matching: find.byType(AppBar))
        .first,
  );

  String titleOf(AppBar bar) {
    final title = bar.title;
    if (title is Text) return title.data!;
    // 대시보드 제목은 모드 배지와 함께 LayoutBuilder 안에 있다.
    return '';
  }

  testWidgets('U16: every bottom tab app bar ends with 설정 and titles match '
      'the bottom labels', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
    });
    final provider = _StatsProvider();
    await provider.init();
    final gate = _OpenGate();
    addTearDown(gate.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider<CommunityGate>.value(value: gate),
          ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const MainNavigationScreen(),
        ),
      ),
    );
    await settle(tester);

    const tabs = <String, Type>{
      '대시보드': DashboardScreen,
      '신고내역': ReportListScreen,
      '신고관리': ReportManagementScreen,
      '통계': StatisticsScreen,
      '알림': NotificationsScreen,
    };
    for (final MapEntry(key: label, value: screen) in tabs.entries) {
      await tester.tap(find.text(label).last);
      await settle(tester);
      final bar = appBarOf(tester, screen);
      expect(bar.actions, isNotNull, reason: '$label 앱바에 동작이 없다');
      expect(
        bar.actions!.last,
        isA<SettingsActionButton>(),
        reason: '$label 앱바의 마지막 동작은 설정이어야 한다',
      );
      expect(
        bar.actions!.whereType<SettingsActionButton>(),
        hasLength(1),
        reason: '$label 앱바의 설정은 한 개',
      );
      if (screen != DashboardScreen) {
        expect(titleOf(bar), label, reason: '제목은 하단 탭 이름과 같다');
      }
      final settings = find.descendant(
        of: find.byType(screen),
        matching: find.byKey(SettingsActionButton.defaultKey),
      );
      expect(settings, findsOneWidget);
      expect(
        find.descendant(of: settings, matching: find.byTooltip('설정')),
        findsOneWidget,
      );
    }

    // 통계: 지도 진입은 앱바 한 곳뿐.
    await tester.tap(find.text('통계').last);
    await settle(tester);
    expect(find.text('신고 지도 열기'), findsNothing);
    expect(find.byKey(const ValueKey('stats-open-map')), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('U16: 신고관리 filter icon follows the current sub-tab and '
      'sits left of 설정', (tester) async {
    final provider = _ClientProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ReportManagementScreen(),
        ),
      ),
    );
    await tester.pump();

    Future<void> goTo(String label) async {
      await tester.tap(find.text(label));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    List<Widget> actions() => appBarOf(tester, ReportManagementScreen).actions!;

    // 별점: 검색/필터 + 설정
    expect(actions().first, isA<FilterActionButton>());
    expect(actions().last, isA<SettingsActionButton>());
    // 본문에 따로 있던 "검색/필터" 글자 버튼은 없다.
    expect(find.widgetWithText(TextButton, '검색/필터'), findsNothing);

    await goTo('감시 목록');
    expect(actions().whereType<FilterActionButton>(), isEmpty);
    expect(actions().last, isA<SettingsActionButton>());

    await goTo('데이터 수정');
    expect(actions().first, isA<FilterActionButton>());
    expect(actions().last, isA<SettingsActionButton>());
    expect(find.byTooltip('상세검색'), findsNothing, reason: '본문 아이콘은 앱바로 옮겼다');

    // 데이터 수정의 조건 칩: × 로 그 조건만 해제.
    provider.setFilter(
      const ReportFilter(agency: '예시 기관', carNumber: '12가3456'),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('filter-chip-agency')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('filter-chip-agency')),
        matching: find.byTooltip('조건 해제'),
      ),
    );
    await tester.pump();
    expect(provider.filter, const ReportFilter(carNumber: '12가3456'));
    expect(find.byKey(const ValueKey('filter-chip-agency')), findsNothing);

    await goTo('별점');
    // 별점 탭은 별점 상태 조건(별점)을 칩으로 보이지 않는다.
    provider.setFilter(const ReportFilter(ratings: ['5'], location: '서울'));
    await tester.pump();
    expect(find.byKey(const ValueKey('filter-chip-ratings')), findsNothing);
    expect(find.byKey(const ValueKey('filter-chip-location')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filter-chips-clear')));
    await tester.pump();
    expect(provider.filter, const ReportFilter());
  });

  group('U16: 신고내역 condition chips', () {
    Future<void> pumpList(
      WidgetTester tester,
      ReportProvider p,
      Widget home,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: p,
          child: MaterialApp(theme: AppTheme.light(), home: home),
        ),
      );
      await tester.pump();
    }

    Finder deleteOf(String field) => find.descendant(
      of: find.byKey(ValueKey('filter-chip-$field')),
      matching: find.byTooltip('조건 해제'),
    );

    testWidgets('bottom tab: chip × removes only that condition from the '
        'shared filter', (tester) async {
      final p = _ClientProvider();
      addTearDown(p.dispose);
      p.setFilter(
        const ReportFilter(
          agency: '예시 기관',
          reportDateStart: '2026-01-01',
          reportDateEnd: '2026-02-01',
          statuses: ['수용'],
        ),
      );
      await pumpList(tester, p, const ReportListScreen());

      final bar = appBarOf(tester, ReportListScreen);
      expect(bar.actions!.last, isA<SettingsActionButton>());
      expect(
        bar.actions![bar.actions!.length - 2],
        isA<FilterActionButton>(),
        reason: '검색/필터는 설정 바로 왼쪽',
      );
      expect(find.byType(InputChip), findsNWidgets(3));

      await tester.ensureVisible(deleteOf('reportDate'));
      await tester.pump();
      await tester.tap(deleteOf('reportDate'));
      await tester.pump();
      expect(
        p.filter,
        const ReportFilter(agency: '예시 기관', statuses: ['수용']),
        reason: '신고일 범위(시작~끝)만 함께 풀린다',
      );

      await tester.ensureVisible(deleteOf('statuses'));
      await tester.pump();
      await tester.tap(deleteOf('statuses'));
      await tester.pump();
      expect(p.filter, const ReportFilter(agency: '예시 기관'));

      await tester.tap(find.byKey(const ValueKey('filter-chips-clear')));
      await tester.pump();
      expect(p.filter.isEmpty, isTrue);
      expect(find.byKey(const ValueKey('active-filter-chips')), findsNothing);
    });

    testWidgets('drill-down: chip × changes only the screen filter', (
      tester,
    ) async {
      final p = _ClientProvider();
      addTearDown(p.dispose);
      await pumpList(
        tester,
        p,
        const ReportListScreen(
          filter: ReportFilter(agency: '예시 기관', manager: '담당자 가'),
          title: '예시 기관 · 신고',
        ),
      );
      expect(find.text('예시 기관 · 신고'), findsOneWidget);

      await tester.ensureVisible(deleteOf('manager'));
      await tester.pump();
      await tester.tap(deleteOf('manager'));
      await tester.pump();
      expect(find.byKey(const ValueKey('filter-chip-manager')), findsNothing);
      expect(find.byKey(const ValueKey('filter-chip-agency')), findsOneWidget);
      expect(p.filter, const ReportFilter(), reason: '공용 필터는 그대로');
      expect(find.text('신고내역'), findsOneWidget, reason: '조건이 바뀌면 기본 제목');
    });
  });

  test('ReportFilter.without clears exactly one condition', () {
    const full = ReportFilter(
      name: 'a',
      reportNumber: 'b',
      id: 'c',
      ratings: ['1'],
      ratingCause: 'd',
      agency: 'e',
      manager: 'f',
      carNumber: 'g',
      law: 'h',
      location: 'i',
      fine: 'j',
      supplementCount: '1',
      reportContent: 'k',
      processContent: 'l',
      statuses: ['수용'],
      reportDateStart: '2026-01-01',
      reportDateEnd: '2026-01-02',
      occurDateStart: '2026-01-01',
      occurDateEnd: '2026-01-02',
      responseDateStart: '2026-01-01',
      responseDateEnd: '2026-01-02',
      occurTimeStart: '10:00',
      occurTimeEnd: '11:00',
      excludePolice: true,
      onlyPolice: true,
      pollStatus: '참여 가능',
    );
    final conditions = full.activeConditions;
    expect(
      conditions.map((c) => c.field).toSet(),
      ReportFilterField.values.toSet(),
    );
    expect(full.activeLabels, conditions.map((c) => c.label).toList());
    for (final field in ReportFilterField.values) {
      final rest = full.without(field).activeConditions.map((c) => c.field);
      expect(rest, isNot(contains(field)), reason: field.name);
      expect(rest.length, conditions.length - 1, reason: field.name);
    }
  });
}
