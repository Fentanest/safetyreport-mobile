// 2026-10-17 명세 5절: 공용 검색 조건은 신고내역·별점·데이터 수정을 떠나면 비운다.
// 드릴다운은 별도 조건이라 영향 없고, 숨은 탭은 스캔을 미루며 버려진 스캔도 로딩을 남기지 않는다.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/navigation/main_tabs.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/screens/report_management_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
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

/// 네트워크·DB 없이 빈 목록만 돌려준다.
class _QuietProvider extends ReportProvider {
  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> fetchWatchlistNumbers() async {}

  @override
  Future<void> fetchAppConfig() async {}

  @override
  Future<void> fetchDuplicateReports() async {}

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {}

  @override
  Future<bool> supportsServerSearch({bool Function()? isCancelled}) async =>
      false;

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (reports: const <Report>[], total: 0);
}

/// 자료 세대를 시험에서 올릴 수 있는 Client 스캔용 프로바이더.
class _EpochScanProvider extends _QuietProvider {
  int testEpoch = 0;
  int reads = 0;
  Completer<void>? hangFirstRead;

  @override
  int get datasetEpoch => testEpoch;

  void bumpEpoch() {
    testEpoch++;
    notifyListeners();
  }

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async {
    reads++;
    final hang = hangFirstRead;
    if (hang != null && reads == 1) {
      await hang.future;
    }
    if (isCancelled?.call() == true) {
      throw const QueryCancelled();
    }
    return (reports: const <Report>[], total: 0);
  }
}

const _perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<_QuietProvider> _pumpMain(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    AppPrefsKeys.appMode: 'standalone',
    AppPrefsKeys.standaloneUsername: 'user1',
  });
  final provider = _QuietProvider();
  await provider.init();
  addTearDown(provider.dispose);
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
  await _settle(tester);
  return provider;
}

Future<void> _pumpManagement(
  WidgetTester tester,
  ReportProvider provider, {
  int initialTabIndex = 0,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: ReportManagementScreen(initialTabIndex: initialTabIndex),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_perm, (_) async => null);
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_perm, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    StandaloneAuthService.stopKeepAlive();
  });

  group('명세 5절: 탭을 떠나면 공용 검색 조건을 비운다', () {
    testWidgets('신고내역에서 건 조건은 별점 탭으로 가면 비어 있고 돌아와도 비어 있다', (tester) async {
      final provider = await _pumpMain(tester);

      await tester.tap(find.text('신고내역').last);
      await _settle(tester);
      provider.setFilter(const ReportFilter(manager: '담당자 가'));
      await tester.pump();
      expect(provider.hasFilter, isTrue);

      await tester.tap(find.text('신고관리').last);
      await _settle(tester);
      expect(
        provider.filter,
        const ReportFilter(),
        reason: '신고내역을 떠나면 공용 조건을 비운다',
      );

      await tester.tap(find.text('신고내역').last);
      await _settle(tester);
      expect(provider.filter, const ReportFilter(), reason: '돌아와도 비어 있어야 한다');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('별점에서 건 조건은 다른 하위 탭으로 가면 비운다', (tester) async {
      final provider = _QuietProvider();
      addTearDown(provider.dispose);
      provider.setFilter(const ReportFilter(manager: '담당자 가'));
      await _pumpManagement(tester, provider, initialTabIndex: 0);
      expect(provider.hasFilter, isTrue);

      await tester.tap(find.text('감시 목록'));
      await _settle(tester);
      expect(
        provider.filter,
        const ReportFilter(),
        reason: '별점을 떠나면 공용 조건을 비운다',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('데이터 수정에서 건 조건은 다른 하위 탭으로 가면 비운다', (tester) async {
      final provider = _QuietProvider();
      addTearDown(provider.dispose);
      provider.setFilter(const ReportFilter(manager: '담당자 가'));
      await _pumpManagement(tester, provider, initialTabIndex: 3);
      expect(provider.hasFilter, isTrue);

      await tester.tap(find.text('중복 신고'));
      await _settle(tester);
      expect(
        provider.filter,
        const ReportFilter(),
        reason: '데이터 수정을 떠나면 공용 조건을 비운다',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('감시 목록에서 떠나면 조건을 그대로 둔다', (tester) async {
      final provider = _QuietProvider();
      addTearDown(provider.dispose);
      provider.setFilter(const ReportFilter(manager: '담당자 가'));
      await _pumpManagement(tester, provider, initialTabIndex: 1);
      expect(provider.hasFilter, isTrue);

      await tester.tap(find.text('별점'));
      await _settle(tester);
      expect(
        provider.filter,
        const ReportFilter(manager: '담당자 가'),
        reason: '조건을 쓰지 않는 탭을 떠날 때는 비우지 않는다',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('하단 탭 이동은 MainTabs 신고관리 하위 탭 요청과 함께 비운다', (tester) async {
      final provider = await _pumpMain(tester);
      await tester.tap(find.text('신고내역').last);
      await _settle(tester);
      provider.setFilter(const ReportFilter(agency: '예시 기관'));
      await tester.pump();
      expect(provider.hasFilter, isTrue);

      await tester.tap(find.text('통계').last);
      await _settle(tester);
      expect(provider.filter, const ReportFilter());
      expect(MainTabs.reports, 1);
      expect(MainTabs.management, 2);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('명세 5절: 드릴다운은 공용 조건과 무관하다', () {
    testWidgets('드릴다운 화면은 공용 조건을 비워도 자기 조건을 유지한다', (tester) async {
      final provider = _QuietProvider();
      addTearDown(provider.dispose);
      const drilldown = ReportFilter(manager: '담당자 가');
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ReportListScreen(
              filter: drilldown,
              title: '담당자 가 · 신고',
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('담당자 가 · 신고'), findsOneWidget);

      provider.setFilter(const ReportFilter(agency: '예시 기관'));
      await tester.pump();
      provider.clearFilter();
      await tester.pump();

      expect(provider.filter, const ReportFilter());
      final list = tester.widget<LocalPagedReportList>(
        find.byType(LocalPagedReportList).first,
      );
      expect(list.filter, drilldown, reason: '드릴다운 목록은 공용 조건과 다른 자기 조건을 쓴다');
      expect(find.text('담당자 가 · 신고'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('명세 5절: 별점 스캔 로딩 결함', () {
    testWidgets('스캔 중 자료 세대가 바뀌어도 로딩이 남지 않는다', (tester) async {
      final provider = _EpochScanProvider();
      addTearDown(provider.dispose);
      provider.hangFirstRead = Completer<void>();
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          // 숨은 탭에서 스캔 중 세대가 바뀌면 새 읽기를 예약하지 않으므로
          // 예전 코드는 스피너가 그대로 남았다.
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: TickerMode(
                enabled: false,
                child: LocalPagedReportList(scope: 'rating'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(provider.reads, greaterThanOrEqualTo(1));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      provider.bumpEpoch();
      provider.hangFirstRead!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: '버려진 스캔 뒤에도 스피너가 남으면 안 된다',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('숨은 탭은 필터 변경에 스캔하지 않고 보일 때 한 번 실행한다', (tester) async {
      final provider = _EpochScanProvider();
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: TickerMode(
                enabled: false,
                child: LocalPagedReportList(scope: 'rating'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final readsAfterFirstLoad = provider.reads;
      expect(readsAfterFirstLoad, greaterThan(0));

      // 숨은 동안 조건이 바뀌어도 새로 훑지 않는다.
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: TickerMode(
                enabled: false,
                child: LocalPagedReportList(
                  scope: 'rating',
                  filter: ReportFilter(manager: '담당자 가'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        provider.reads,
        readsAfterFirstLoad,
        reason: '숨은 탭은 필터 변경마다 전체 스캔을 다시 시작하지 않는다',
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);

      // 다시 보이면 한 번 실행한다.
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: TickerMode(
                enabled: true,
                child: LocalPagedReportList(
                  scope: 'rating',
                  filter: ReportFilter(manager: '담당자 가'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(provider.reads, greaterThan(readsAfterFirstLoad));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
