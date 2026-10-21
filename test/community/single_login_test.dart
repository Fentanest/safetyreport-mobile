// 새 설치 Standalone: 계정을 한 번만 입력한다(2026-10-21).
// 첫 로그인 입력은 메모리에만 두었다가 게이트(카카오·동의)·권한 뒤 같은 로그인 경로로 자동 실행한다.
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
import 'package:safetyreport/services/pending_standalone_credentials.dart';
import 'package:safetyreport/services/server_connection_service.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Gate extends CommunityGate {
  _Gate() : super(configStatus: () => 'ok');

  bool enter = false;

  @override
  GateState get state =>
      GateState(state: enter ? 'ok' : 'verification_required', canEnter: enter);

  void setEnter(bool v) {
    enter = v;
    notifyListeners();
  }

  @override
  bool get canEnter => enter;
  @override
  bool get canBrowse => enter;
  @override
  bool get isChecked => true;
  @override
  Future<GateState> refreshNow({bool silent = false}) async => state;
  @override
  void startPolling() {}
}

class _Provider extends ReportProvider {
  _Provider(this.events);
  final List<String> events;

  @override
  Future<void> setStandaloneConfig(
    String username, {
    required String phoneNumber,
    bool isDemoMode = false,
    Future<bool> Function()? confirmAccountReset,
  }) async {
    events.add('activate:$username:$phoneNumber:demo=$isDemoMode');
  }

  @override
  Future<void> refreshAll() async {}
}

Widget _app(ReportProvider p, CommunityGate g) => MultiProvider(
  providers: [
    ChangeNotifierProvider<ReportProvider>.value(value: p),
    ChangeNotifierProvider<CommunityGate>.value(value: g),
    ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
  ],
  child: SafetyReportApp(
    serverVersionCheck: (_, _) async =>
        ServerConnectionResult.ok(normalizedUrl: 'http://test'),
  ),
);

Future<void> _tapMode(WidgetTester tester, String title) async {
  tester
      .widget<InkWell>(
        find.ancestor(of: find.text(title), matching: find.byType(InkWell)),
      )
      .onTap!();
  await tester.pumpAndSettle();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _text(WidgetTester tester, String label) => tester
    .widget<TextField>(find.widgetWithText(TextField, label))
    .controller!
    .text;

void main() {
  late List<String> events;
  late _Provider provider;
  late _Gate gate;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    events = [];
    provider = _Provider(events);
    await provider.init();
    gate = _Gate();
    SetupScreen.standaloneLoginOverride = (u, p) async =>
        events.add('login:$u:$p');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.fentanest.mysafetyreport/permissions'),
          (call) async => null,
        );
  });

  tearDown(() {
    SetupScreen.standaloneLoginOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.fentanest.mysafetyreport/permissions'),
          null,
        );
    StandaloneAuthService.stopKeepAlive();
    gate.dispose();
    provider.dispose();
  });

  Future<void> firstLogin(WidgetTester tester, {String pw = 'pw1'}) async {
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    await _tapMode(tester, 'Standalone 모드');
    await tester.enterText(find.widgetWithText(TextField, '아이디'), 'user');
    await tester.enterText(find.widgetWithText(TextField, '비밀번호'), pw);
    await tester.enterText(
      find.widgetWithText(TextField, '휴대폰번호'),
      '010-1234-5678',
    );
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
  }

  Future<void> passGateAndPermissions(WidgetTester tester) async {
    gate.setEnter(true);
    await tester.pumpAndSettle();
    expect(find.byType(PermissionScreen), findsOneWidget);
    final later = find.widgetWithText(FilledButton, '나중에 설정하기');
    await tester.ensureVisible(later);
    await tester.pumpAndSettle();
    tester.widget<FilledButton>(later).onPressed!();
  }

  testWidgets('credentials typed once are used after gate and permissions', (
    tester,
  ) async {
    await firstLogin(tester);
    expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
    expect(events, isEmpty, reason: '게이트 전에는 로그인·저장 없음');
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);

    await passGateAndPermissions(tester);
    await _settle(tester);

    expect(events, [
      'login:user:pw1',
      'activate:user:01012345678:demo=false',
    ], reason: '처음 입력한 값으로 로그인 경로가 정확히 한 번 실행된다');
    // 비어 있는 두 번째 로그인 폼이 아니다.
    expect(_text(tester, '아이디'), 'user');
    expect(_text(tester, '비밀번호'), 'pw1');
  });

  testWidgets('failure shows the form prefilled with the error', (
    tester,
  ) async {
    SetupScreen.standaloneLoginOverride = (u, p) async {
      events.add('login:$u:$p');
      throw Exception('비밀번호가 올바르지 않습니다');
    };
    await firstLogin(tester, pw: 'wrong');
    await passGateAndPermissions(tester);
    await _settle(tester);

    expect(events, ['login:user:wrong']);
    expect(find.text('비밀번호가 올바르지 않습니다'), findsOneWidget);
    expect(_text(tester, '아이디'), 'user');
    expect(_text(tester, '비밀번호'), 'wrong');
    expect(_text(tester, '휴대폰번호'), '010-1234-5678');
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '비밀번호'))
          .obscureText,
      isTrue,
    );

    // 고쳐서 한 번 제출하면 성공한다. 이전 값은 다시 자동 실행되지 않는다.
    SetupScreen.standaloneLoginOverride = (u, p) async =>
        events.add('login:$u:$p');
    await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'right');
    await tester.tap(find.text('로그인'));
    await _settle(tester);
    expect(events, [
      'login:user:wrong',
      'login:user:right',
      'activate:user:01012345678:demo=false',
    ]);
  });

  testWidgets('going back to mode selection drops the carried credentials', (
    tester,
  ) async {
    await firstLogin(tester);
    expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
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

    await _tapMode(tester, 'Standalone 모드');
    expect(_text(tester, '아이디'), isEmpty);
    await tester.enterText(find.widgetWithText(TextField, '아이디'), 'other');
    await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'pw2');
    await tester.enterText(
      find.widgetWithText(TextField, '휴대폰번호'),
      '01099998888',
    );
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    await passGateAndPermissions(tester);
    await _settle(tester);
    expect(events.first, 'login:other:pw2');
    expect(events.where((e) => e.startsWith('login:')).length, 1);
  });

  testWidgets('incomplete first login is rejected before the gate', (
    tester,
  ) async {
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    await _tapMode(tester, 'Standalone 모드');
    await tester.enterText(find.widgetWithText(TextField, '아이디'), 'user');
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    expect(find.byType(CommunityOnboardingScreen), findsNothing);
    expect(find.textContaining('모두 입력'), findsOneWidget);
  });

  testWidgets('demo/demo enters demo immediately without the gate', (
    tester,
  ) async {
    await tester.pumpWidget(_app(provider, gate));
    await tester.pumpAndSettle();
    await _tapMode(tester, 'Standalone 모드');
    await tester.enterText(find.widgetWithText(TextField, '아이디'), 'demo');
    await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'demo');
    await tester.tap(find.text('로그인'));
    await _settle(tester);
    expect(find.byType(CommunityOnboardingScreen), findsNothing);
    // 테스트 환경에서는 실제 데모 DB 시드가 실패할 수 있다. 그래도 데모 경로를 탔다는 증거(활성화 또는 시드 실패 안내)가 있어야 한다.
    expect(
      events.any((e) => e.endsWith('demo=true')) ||
          find.textContaining('데모 데이터 준비 실패').evaluate().isNotEmpty,
      isTrue,
    );
    expect(events.any((e) => e.startsWith('login:')), isFalse);
  });

  test('PendingStandaloneCredentials is memory-only and clearable', () {
    final c = PendingStandaloneCredentials();
    expect(c.isEmpty, isTrue);
    c.set(username: 'a', password: 'b', phone: '010');
    expect(c.isEmpty, isFalse);
    expect(c.password, 'b');
    c.clear();
    expect(c.isEmpty, isTrue);
    expect(c.password, isEmpty);
  });
}
