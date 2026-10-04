// SQ-U05: 대시보드가 아닌 하단 탭에서 뒤로가기는 대시보드(0)로 가고, 0 에서만 앱을 닫는다.
// SQ-B05: 메인 화면이 뜨기 전에 온 알림 탭 이동은 보관했다가 메인 화면이 붙으면 전달한다.
// SQ-U06: 대시보드 "감시 목록 › 관리"는 화면을 새로 쌓지 않고 하단 탭 2(신고관리)의 "감시 목록"으로 전환한다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/navigation/native_call_router.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/dashboard_screen.dart';
import 'package:safetyreport/screens/report_management_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
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

/// 대시보드 본문(감시 목록 섹션)이 보이도록 요약을 고정한다.
class _StatsProvider extends ReportProvider {
  final DashboardStats _fixed = DashboardStats.fromJson({'total': 1});

  @override
  DashboardStats? get stats => _fixed;

  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> fetchWatchlistNumbers() async {}
}

const _perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

void main() {
  late List<MethodCall> platformCalls;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    platformCalls = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_perm, (_) async => null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_perm, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    StandaloneAuthService.stopKeepAlive();
  });

  bool exitedApp() =>
      platformCalls.any((c) => c.method == 'SystemNavigator.pop');

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<ReportProvider> pumpMain(WidgetTester tester) async {
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
    return provider;
  }

  int selectedTab(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets(
    'U05: non-dashboard tab back goes to dashboard, dashboard back exits',
    (tester) async {
      await pumpMain(tester);
      for (final label in ['알림', '통계', '신고관리', '신고내역']) {
        await tester.tap(find.text(label).last);
        await settle(tester);
        expect(selectedTab(tester), isNot(0));

        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(selectedTab(tester), 0, reason: '$label 탭 뒤로가기는 대시보드로');
        expect(exitedApp(), isFalse, reason: '$label 탭 뒤로가기로 앱이 닫히면 안 된다');
      }

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(exitedApp(), isTrue, reason: '대시보드에서만 앱을 닫는다');
      await drainTimers(tester);
    },
  );

  testWidgets(
    'U05: a pushed route still pops normally over a non-dashboard tab',
    (tester) async {
      await pumpMain(tester);
      await tester.tap(find.text('통계').last);
      await settle(tester);
      Navigator.of(tester.element(find.byType(NavigationBar))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('pushed')),
        ),
      );
      await settle(tester);
      expect(find.text('pushed'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('pushed'), findsNothing);
      expect(selectedTab(tester), 3, reason: '위에 쌓인 화면만 닫고 탭은 그대로');
      expect(exitedApp(), isFalse);
      await drainTimers(tester);
    },
  );

  testWidgets('U06: dashboard watchlist 관리 switches to 신고관리 tab / 감시 목록', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpMain(tester);
    final manage = find.widgetWithText(TextButton, '관리');
    await tester.scrollUntilVisible(
      manage,
      200,
      scrollable: find
          .descendant(
            of: find.byType(DashboardScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await settle(tester);

    final size = tester.getSize(manage);
    expect(size.height, greaterThanOrEqualTo(48), reason: '터치 영역 48dp 이상');
    expect(
      find.descendant(of: manage, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );

    await tester.tap(manage);
    await settle(tester);

    expect(selectedTab(tester), 2);
    expect(
      Navigator.of(tester.element(find.byType(NavigationBar))).canPop(),
      isFalse,
      reason: '하단 탭 없는 신고관리 화면을 새로 쌓지 않는다',
    );
    expect(find.byType(ReportManagementScreen), findsOneWidget);
    final tabBar = tester.widget<TabBar>(
      find.descendant(
        of: find.byType(ReportManagementScreen),
        matching: find.byType(TabBar),
      ),
    );
    expect(tabBar.controller!.index, 1, reason: '감시 목록 하위 탭');

    // 하위 탭을 바꾼 뒤 다시 "관리"로 오면 다시 감시 목록이다.
    tabBar.controller!.index = 3;
    await tester.tap(find.text('대시보드').last);
    await settle(tester);
    await tester.tap(manage);
    await settle(tester);
    expect(selectedTab(tester), 2);
    expect(tabBar.controller!.index, 1);
    await drainTimers(tester);
  });

  testWidgets(
    'B05: navigateToTab sent before the main screen exists opens the tab',
    (tester) async {
      NativeCallRouter.instance.resetForTest();
      addTearDown(NativeCallRouter.instance.resetForTest);
      NativeCallRouter.instance.install();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'com.fentanest.mysafetyreport/permissions',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('navigateToTab', {'tab': 3}),
            ),
            (_) {},
          );
      await pumpMain(tester);
      expect(selectedTab(tester), 3, reason: '콜드 스타트 요청이 유실되지 않는다');

      // 메인 화면이 사라진 뒤의 요청은 옛 화면을 건드리지 않고(예외 없이) 보관된다.
      await tester.pumpWidget(const SizedBox());
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'com.fentanest.mysafetyreport/permissions',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('navigateToTab', {'tab': 4}),
            ),
            (_) {},
          );
      expect(tester.takeException(), isNull);
      expect(NativeCallRouter.instance.pendingRequest?.tab, 4);
      await drainTimers(tester);
    },
  );
}
