// 진입 순서·게이트 가드 — F01·F05·F06·F12·F18, S-21 순서.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/community_onboarding_screen.dart';
import 'package:safetyreport/screens/permission_screen.dart';
import 'package:safetyreport/screens/setup_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 네트워크 없이 고정된 게이트 결과만 주는 스텁.
class StubGate extends CommunityGate {
  StubGate({required this.enter}) : super(configStatus: () => 'ok');

  final bool enter;

  @override
  bool get canEnter => enter;

  @override
  bool get isChecked => true;

  @override
  Future<GateState> refreshNow({bool silent = false}) async => state;

  @override
  void startPolling() {}
}

Future<ReportProvider> _providerWith(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final provider = ReportProvider();
  await provider.init();
  return provider;
}

Widget _app(ReportProvider provider, StubGate gate) => MultiProvider(
      providers: [
        ChangeNotifierProvider<ReportProvider>.value(value: provider),
        ChangeNotifierProvider<CommunityGate>.value(value: gate),
        ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
      ],
      child: const SafetyReportApp(),
    );

void main() {
  late List<String> permCalls;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    permCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.fentanest.mysafetyreport/permissions'),
      (call) async {
        permCalls.add(call.method);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.fentanest.mysafetyreport/permissions'),
      null,
    );
    ReportProvider.scheduleLoginCheckHook = null;
    ReportProvider.drainAndRefreshHook = null;
    ReportProvider.startWsServiceHook = null;
    StandaloneAuthService.stopKeepAlive();
  });

  testWidgets('F01: fresh install first screen is onboarding, zero permission calls',
      (tester) async {
    final provider = await _providerWith({});
    final gate = StubGate(enter: false);
    addTearDown(gate.dispose);
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
    expect(find.byType(PermissionScreen), findsNothing);
    expect(find.byType(MainNavigationScreen), findsNothing);
    expect(
      permCalls,
      isEmpty,
      reason: '게이트 전 PermissionScreen·OS 권한 요청 호출 0',
    );
  });

  testWidgets('F05: configured user still gated', (tester) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
    });
    expect(provider.isConfigured, isTrue);
    final gate = StubGate(enter: false);
    addTearDown(gate.dispose);
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
    expect(find.byType(MainNavigationScreen), findsNothing);
  });

  testWidgets('F12: legacy completion flags do not bypass gate', (tester) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
      'communityOnboardingDone': true,
      'communityGatePassed': true,
    });
    final gate = StubGate(enter: false);
    addTearDown(gate.dispose);
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
  });

  testWidgets('S-21: gate passed + new install shows common permissions first',
      (tester) async {
    final provider = await _providerWith({});
    final gate = StubGate(enter: true);
    addTearDown(gate.dispose);
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionScreen), findsOneWidget);
    expect(
      tester.widget<PermissionScreen>(find.byType(PermissionScreen)).phase,
      PermissionPhase.common,
    );
    // common 완료 → 기존 SetupScreen.
    final later = find.widgetWithText(FilledButton, '나중에 설정하기');
    await tester.ensureVisible(later);
    await tester.pumpAndSettle();
    await tester.tap(later, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(SetupScreen), findsOneWidget);
  });

  testWidgets('S-21: server mode shows mode supplement after setup', (tester) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'http://127.0.0.1:9',
      AppPrefsKeys.apiKey: 'k',
    });
    final gate = StubGate(enter: true);
    addTearDown(gate.dispose);
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    // WsService 미실행이면 모드 보충 화면이 나온다.
    expect(find.byType(PermissionScreen), findsOneWidget);
    expect(
      tester.widget<PermissionScreen>(find.byType(PermissionScreen)).phase,
      PermissionPhase.mode,
    );
  });

  testWidgets('S-21: standalone configured skips to main when store unavailable',
      (tester) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
    });
    final gate = StubGate(enter: true);
    addTearDown(gate.dispose);
    await tester.pumpWidget(_app(provider, gate));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      if (find.byType(MainNavigationScreen).evaluate().isNotEmpty) break;
    }
    expect(find.byType(MainNavigationScreen), findsOneWidget);
  });

  /// MainNavigationScreen 은 유지 애니메이션(BusyRing 등)으로 settle 이 안 되므로
  /// 고정 pump 로만 진행한다.
  Future<void> pumpMain(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('F06: navigation allowed again after gate passes', (tester) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
    });
    final gate = StubGate(enter: true);
    addTearDown(gate.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider<CommunityGate>.value(value: gate),
          ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
        ],
        child: const MaterialApp(home: MainNavigationScreen()),
      ),
    );
    await pumpMain(tester);
    expect(communityNavAllowed(tester.element(find.byType(NavigationBar))), isTrue);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.fentanest.mysafetyreport/permissions',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('navigateToTab', {'tab': 4}),
      ),
      (_) {},
    );
    await pumpMain(tester);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );
    // DashboardScreen 의 fetchSummary 5초 타임아웃 등 잔여 타이머를 비운다.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('F06: navigateToTab and payload open ignored while gated',
      (tester) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
    });
    final gate = StubGate(enter: false);
    addTearDown(gate.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider<CommunityGate>.value(value: gate),
          ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
        ],
        child: const MaterialApp(home: MainNavigationScreen()),
      ),
    );
    await pumpMain(tester);
    final before =
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.fentanest.mysafetyreport/permissions',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('navigateToTab', {'tab': 4}),
      ),
      (_) {},
    );
    await pumpMain(tester);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      before,
      reason: '게이트 미충족이면 알림 탭 이동 무시',
    );
    expect(communityNavAllowed(tester.element(find.byType(NavigationBar))), isFalse);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
  });
}
