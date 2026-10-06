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
import 'package:safetyreport/screens/cloud_unavailable_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/server_connection_service.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 네트워크 없이 고정된 게이트 결과만 주는 스텁.
class StubGate extends CommunityGate {
  StubGate({required this.enter}) : super(configStatus: () => 'ok');

  bool enter;
  String blockedState = 'verification_required';
  @override
  GateState get state =>
      GateState(state: enter ? 'ok' : blockedState, canEnter: enter);

  void setEnter(bool value) {
    enter = value;
    notifyListeners();
  }

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

Widget _app(
  ReportProvider provider,
  StubGate gate, {
  Future<ServerConnectionResult> Function(String, String)? serverVersionCheck,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<ReportProvider>.value(value: provider),
    ChangeNotifierProvider<CommunityGate>.value(value: gate),
    ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
  ],
  child: SafetyReportApp(
    serverVersionCheck:
        serverVersionCheck ??
        (_, _) async => ServerConnectionResult.ok(normalizedUrl: 'http://test'),
  ),
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

  testWidgets(
    'gate closes pushed route; cloud and account recovery switch while blocked',
    (tester) async {
      final provider = await _providerWith({
        AppPrefsKeys.appMode: 'standalone',
        AppPrefsKeys.standaloneUsername: 'user1',
      });
      final gate = StubGate(enter: true);
      addTearDown(gate.dispose);
      await tester.pumpWidget(_app(provider, gate));
      await tester.pumpAndSettle();
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('private pushed route')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('private pushed route'), findsOneWidget);
      gate.blockedState = 'cloud_unavailable';
      gate.setEnter(false);
      await tester.pumpAndSettle();
      expect(find.text('private pushed route'), findsNothing);
      expect(find.byType(CloudUnavailableScreen), findsOneWidget);
      gate.blockedState = 'official_account_mismatch';
      gate.setEnter(false);
      await tester.pumpAndSettle();
      expect(find.byType(CloudUnavailableScreen), findsNothing);
      expect(
        tester.widget<SetupScreen>(find.byType(SetupScreen)).accountRecovery,
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SetupScreen), findsOneWidget);
      expect(find.byType(MainNavigationScreen), findsNothing);
    },
  );

  testWidgets(
    'pending import and live login wait for Kakao after demo credential check',
    (tester) async {
      final provider = await _providerWith({
        AppPrefsKeys.pendingDbImport: 'copy:/synthetic/backup.db',
      });
      final gate = StubGate(enter: false);
      addTearDown(gate.dispose);
      await tester.pumpWidget(_app(provider, gate));
      await tester.pumpAndSettle();
      tester
          .widget<InkWell>(
            find.ancestor(
              of: find.text('Standalone 모드'),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!();
      await tester.pumpAndSettle();
      // Play 심사 자격을 게이트 전에 입력할 수 있어야 한다. 일반 자격은
      // 로그인 API·대기 가져오기를 시작하기 전에 기존 온보딩으로 이동한다.
      expect(find.widgetWithText(TextField, '아이디'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '아이디'), 'user');
      await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'pw');
      await tester.tap(find.text('로그인'));
      await tester.pumpAndSettle();
      expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
      expect(find.widgetWithText(TextField, '아이디'), findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getString(
          AppPrefsKeys.pendingDbImport,
        ),
        'copy:/synthetic/backup.db',
      );
    },
  );

  testWidgets(
    'F01: fresh install selects mode before onboarding, zero permission calls',
    (tester) async {
      final provider = await _providerWith({});
      final gate = StubGate(enter: false);
      addTearDown(gate.dispose);
      await tester.pumpWidget(_app(provider, gate));
      await tester.pumpAndSettle();
      expect(find.byType(SetupScreen), findsOneWidget);
      expect(find.text('Demo 보기'), findsOneWidget);
      expect(find.byType(PermissionScreen), findsNothing);
      expect(find.byType(MainNavigationScreen), findsNothing);
      expect(
        permCalls,
        isEmpty,
        reason: '게이트 전 PermissionScreen·OS 권한 요청 호출 0',
      );
      tester
          .widget<InkWell>(
            find.ancestor(
              of: find.text('Client 모드'),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!();
      await tester.pumpAndSettle();
      expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
      expect(find.byType(PermissionScreen), findsNothing);
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('모드 선택으로 돌아가기'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('Demo 보기'), findsOneWidget);
    },
  );

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

  testWidgets('F12: legacy completion flags do not bypass gate', (
    tester,
  ) async {
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

  testWidgets('S-21: mode selection precedes common permissions', (
    tester,
  ) async {
    final provider = await _providerWith({});
    final gate = StubGate(enter: true);
    addTearDown(gate.dispose);
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.byType(PermissionScreen), findsNothing);
    tester
        .widget<InkWell>(
          find.ancestor(
            of: find.text('Client 모드'),
            matching: find.byType(InkWell),
          ),
        )
        .onTap!();
    await tester.pumpAndSettle();
    expect(find.byType(PermissionScreen), findsOneWidget);
    expect(
      tester.widget<PermissionScreen>(find.byType(PermissionScreen)).phase,
      PermissionPhase.common,
    );
    expect(find.text('백그라운드 서버 연결 (WebSocket)'), findsNothing);
    // common 완료 → 선택한 Client 설정 화면.
    final later = find.widgetWithText(FilledButton, '나중에 설정하기');
    await tester.ensureVisible(later);
    await tester.pumpAndSettle();
    tester.widget<FilledButton>(later).onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.text('서버 연결 설정'), findsOneWidget);
    await provider.setConfig('http://127.0.0.1:9', 'k');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byType(PermissionScreen),
      findsNothing,
      reason: '서버 설정을 저장한 뒤 권한 화면이 다시 열리면 안 된다',
    );
  });

  testWidgets(
    'S-21: server mode starts WebSocket without reopening permissions',
    (tester) async {
      final provider = await _providerWith({
        AppPrefsKeys.appMode: 'server',
        AppPrefsKeys.baseUrl: 'http://127.0.0.1:9',
        AppPrefsKeys.apiKey: 'k',
      });
      final gate = StubGate(enter: true);
      addTearDown(gate.dispose);
      await tester.pumpWidget(_app(provider, gate));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(PermissionScreen), findsNothing);
      expect(permCalls, contains('startWsService'));
    },
  );

  testWidgets('S-21: personal DB unavailable cannot bypass account binding', (
    tester,
  ) async {
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
    expect(find.byType(MainNavigationScreen), findsNothing);
    expect(find.text('개인 DB를 확인하지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
    expect(find.text('재시도'), findsOneWidget);
    StandaloneAuthService.stopKeepAlive();
  });

  testWidgets('stored Client config blocks a PC server below v3', (
    tester,
  ) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'http://old-server',
      AppPrefsKeys.apiKey: 'k',
    });
    final gate = StubGate(enter: true);
    addTearDown(gate.dispose);
    await tester.pumpWidget(
      _app(
        provider,
        gate,
        serverVersionCheck: (_, _) async =>
            ServerConnectionResult.incompatibleServer(
              normalizedUrl: 'http://old-server',
            ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('v3 이상'), findsOneWidget);
    expect(find.byType(MainNavigationScreen), findsNothing);
    expect(permCalls, isNot(contains('startWsService')));
  });

  testWidgets('retry enters Client flow after the PC server is updated', (
    tester,
  ) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'http://old-server',
      AppPrefsKeys.apiKey: 'k',
    });
    final gate = StubGate(enter: true);
    addTearDown(gate.dispose);
    var updated = false;
    await tester.pumpWidget(
      _app(
        provider,
        gate,
        serverVersionCheck: (_, _) async => updated
            ? ServerConnectionResult.ok(normalizedUrl: 'http://old-server')
            : ServerConnectionResult.incompatibleServer(
                normalizedUrl: 'http://old-server',
              ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('다시 확인'), findsOneWidget);
    updated = true;
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '다시 확인'))
        .onPressed!();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('다시 확인'), findsNothing);
    expect(permCalls, contains('startWsService'));
  });

  testWidgets('Kakao consent gate remains in front of server version error', (
    tester,
  ) async {
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'http://old-server',
      AppPrefsKeys.apiKey: 'k',
    });
    final gate = StubGate(enter: false);
    addTearDown(gate.dispose);
    await tester.pumpWidget(
      _app(
        provider,
        gate,
        serverVersionCheck: (_, _) async =>
            ServerConnectionResult.incompatibleServer(
              normalizedUrl: 'http://old-server',
            ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
    expect(find.textContaining('v3 이상'), findsNothing);
    expect(find.byType(MainNavigationScreen), findsNothing);
  });

  /// MainNavigationScreen 은 유지 애니메이션 때문에 고정 pump 로 진행한다.
  Future<void> pumpMain(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  // 2.0.3에서 추가된 '데모도 게이트 필수/하위 화면 닫기' 기대를 정정한다.
  // 합성 자료는 카카오·클라우드·실계정 바인딩 상태와 무관하게 탐색한다.
  for (final blockedState in [
    'verification_required',
    'cloud_unavailable',
    'official_account_mismatch',
    'official_account_taken',
    'official_account_change_required',
  ]) {
    testWidgets('demo enters and keeps navigation despite $blockedState', (
      tester,
    ) async {
      final provider = await _providerWith({
        AppPrefsKeys.appMode: 'standalone',
        AppPrefsKeys.standaloneUsername: 'demo',
        AppPrefsKeys.standaloneDemoMode: true,
      });
      final gate = StubGate(enter: false)..blockedState = blockedState;
      addTearDown(gate.dispose);
      var serviceStarts = 0;
      ReportProvider.scheduleLoginCheckHook = () async => serviceStarts++;
      ReportProvider.drainAndRefreshHook = () async => serviceStarts++;
      ReportProvider.startWsServiceHook = () async {
        serviceStarts++;
        return true;
      };
      await tester.pumpWidget(_app(provider, gate));
      await pumpMain(tester);
      expect(find.byType(MainNavigationScreen), findsOneWidget);
      expect(find.byType(CommunityOnboardingScreen), findsNothing);
      expect(find.byType(CloudUnavailableScreen), findsNothing);
      expect(find.byType(PermissionScreen), findsNothing);
      expect(find.byType(SetupScreen), findsNothing);
      expect(
        communityNavAllowed(tester.element(find.byType(NavigationBar))),
        isTrue,
      );
      expect(serviceStarts, 0);
      expect(
        permCalls.where(
          (c) => c.startsWith('request') || c.startsWith('start'),
        ),
        isEmpty,
      );
      gate.setEnter(true);
      await pumpMain(tester);
      Navigator.of(tester.element(find.byType(MainNavigationScreen))).push(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('demo detail')),
        ),
      );
      await tester.pumpAndSettle();
      gate.setEnter(false);
      await tester.pumpAndSettle();
      expect(find.text('demo detail'), findsOneWidget);
      expect(find.byType(CommunityOnboardingScreen), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('F06: navigation allowed again after gate passes', (
    tester,
  ) async {
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
    expect(
      communityNavAllowed(tester.element(find.byType(NavigationBar))),
      isTrue,
    );
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

  testWidgets('F06: navigateToTab and payload open ignored while gated', (
    tester,
  ) async {
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
    final before = tester
        .widget<NavigationBar>(find.byType(NavigationBar))
        .selectedIndex;
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
    expect(
      communityNavAllowed(tester.element(find.byType(NavigationBar))),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
  });
}
