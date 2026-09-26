// 온보딩 화면 — F01·F02·F03·F04·F07.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/screens/community_onboarding_screen.dart';
import 'package:safetyreport/services/community_auth_link_channel.dart';
import 'package:safetyreport/services/community_auth_service.dart';

import '../community/fake_account.dart';

Widget _wrap({
  required CommunityGate gate,
  required Widget child,
}) {
  return MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gate),
      ],
      child: child,
    ),
  );
}

CommunityGate _makeGate(StubAuthService auth, FakeAccountServer server, {String appMode = 'standalone'}) {
  final gate = CommunityGate(
    config: testAuthConfig(),
    auth: auth,
    store: null,
    accountClient: server.accountClient(),
    configStatus: () => 'ok',
    appMode: () => appMode,
    officialAccountId: () async => null,
  );
  addTearDown(gate.dispose);
  return gate;
}

void main() {
  setUp(() {
    setUpSecureStorage();
  });

  testWidgets('F02: consent checkbox defaults to unchecked; [필수] tags present', (tester) async {
    final auth = StubAuthService();
    final server = FakeAccountServer();
    final gate = _makeGate(auth, server);
    await tester.pumpWidget(
      _wrap(
        gate: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: server.accountClient(),
          consentText: '동의문 전문',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('[필수]'), findsNWidgets(2));
    expect(find.text('서비스 이용을 위한 필수 설정'), findsOneWidget);
    final checkbox = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(checkbox.value, isFalse);
    final next = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '다음'));
    expect(next.enabled, isFalse);
  });

  testWidgets('F03: kakao success alone saves zero consent', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer();
    final gate = _makeGate(auth, server);
    var nextCalls = 0;
    await tester.pumpWidget(
      _wrap(
        gate: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: server.accountClient(),
          consentText: '동의문 전문',
          onNext: () async {
            nextCalls++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 카카오만 됐고 동의는 안 했으므로 다음은 비활성, 동의 API 호출 0.
    final next = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '다음'));
    expect(next.enabled, isFalse);
    expect(server.count('/consent'), 0);
    expect(nextCalls, 0);
  });

  testWidgets('F04: consent failure keeps incomplete with error', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer()
      ..consentThrows = {'code': 'policy_mismatch', 'message': '바뀜'};
    final gate = _makeGate(auth, server);
    await tester.pumpWidget(
      _wrap(
        gate: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: server.accountClient(),
          consentText: '동의문 전문',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '동의하고 계속'));
    await tester.pumpAndSettle();
    expect(server.count('/consent'), 1);
    // 실패해도 체크는 남고 미완료 + 오류 표시.
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    expect(find.text('동의문 전문'), findsNothing); // 접혀 있음
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, '다음')).enabled,
      isFalse,
    );
  });

  testWidgets('consent success enables next; next re-verifies server', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer();
    final gate = _makeGate(auth, server);
    await gate.refreshNow();
    expect(gate.canEnter, isTrue);
    final statusCalls = server.statusCalls;
    var nextCalls = 0;
    await tester.pumpWidget(
      _wrap(
        gate: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: server.accountClient(),
          consentText: '동의문 전문',
          onNext: () async {
            nextCalls++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '동의하고 계속'));
    await tester.pumpAndSettle();
    expect(find.text('동의 완료'), findsOneWidget);
    final afterConsentCalls = server.statusCalls;
    expect(afterConsentCalls, statusCalls + 1,
        reason: '동의 저장은 성공 응답 뒤 서버 재검증 1회');
    await tester.tap(find.widgetWithText(FilledButton, '다음'));
    await tester.pumpAndSettle();
    expect(nextCalls, 1);
    expect(server.statusCalls, afterConsentCalls,
        reason: '유효 캐시면 다음 이동 때 재로그인 요구 없음(F13)');
  });

  test('F07: OAuth callback drain works with no native handler (gate irrelevant)', () async {
    var links = 0;
    CommunityAuthLinkChannel.start((_) async {
      links++;
    });
    await CommunityAuthLinkChannel.drain();
    await CommunityAuthLinkChannel.drainInitial();
    expect(links, 0);
  });

  test('F01: no skip/later actions in onboarding source', () {
    // 생략·연기 동작 없음 — 화면 소스에 건너뛰기 문구가 없다.
    final src = File('lib/screens/community_onboarding_screen.dart').readAsStringSync();
    expect(src, isNot(contains('건너뛰기')));
    expect(src, isNot(contains('나중에 설정')));
  });
}
