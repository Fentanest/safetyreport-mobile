// 온보딩 화면 — F01·F02·F03·F04·F07.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
    checkDataOwner: ownerOk,
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
    final server = FakeAccountServer(status: () => statusJson(consentState: 'none', consentPolicy: null))
      ..consentThrows = {'code': 'contributor_suspended', 'message': '이 계정의 공유가 중지되어 있습니다.'};
    final gate = _makeGate(auth, server);
    await tester.pumpWidget(
      _wrap(
        gate: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: server.accountClient(),
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
    var consented = false;
    final server = FakeAccountServer(
        status: () => consented ? statusJson() : statusJson(consentState: 'none', consentPolicy: null))
      ..onConsent = () => consented = true;
    final gate = _makeGate(auth, server);
    await gate.refreshNow();
    expect(gate.state.state, 'consent_required');
    final statusCalls = server.statusCalls;
    var nextCalls = 0;
    await tester.pumpWidget(
      _wrap(
        gate: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: server.accountClient(),
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

  // 2026-09-27 dev 빌드: main.dart 가 accountClient 를 넘기지 않아 "커뮤니티 서버 설정이 없어 동의를 저장할 수 없습니다" 로 막혔다.
  // 앱과 같은 방식(gate.accountClient)으로 넘기면 서버에 동의가 저장된다.
  testWidgets('consent is saved through the gate account client, the way main.dart wires it', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    var consented = false;
    final server = FakeAccountServer(
        status: () => consented ? statusJson() : statusJson(consentState: 'none', consentPolicy: null))
      ..onConsent = () => consented = true;
    final gate = _makeGate(auth, server);
    await gate.refreshNow();
    await tester.pumpWidget(
      _wrap(
        gate: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: gate.accountClient,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '동의하고 계속'));
    await tester.pumpAndSettle();
    expect(find.textContaining('커뮤니티 서버 설정이 없어'), findsNothing);
    expect(find.text('동의 완료'), findsOneWidget);
    expect(server.requests.where((r) => r.url.path.endsWith('/consent')), hasLength(1));
  });

  // 2026-09-27: 동의문은 중앙 `policy` 로 받는다 — 보인 본문의 버전·해시로 동의한다.
  testWidgets('the consent text comes from the center and the consent carries its hash', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer(status: () => statusJson(consentState: 'none', consentPolicy: null))
      ..policyText = '# 중앙 동의문\n\n중앙에서 받은 본문입니다.\n';
    final gate = _makeGate(auth, server);
    await gate.refreshNow();
    await tester.pumpWidget(_wrap(
      gate: gate,
      child: CommunityOnboardingScreen(gate: gate, auth: auth, accountClient: gate.accountClient),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('동의문 전문 보기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('중앙에서 받은 본문입니다.'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '동의하고 계속'));
    await tester.pumpAndSettle();
    final body = jsonDecode(server.requests.lastWhere((r) => r.url.path.endsWith('/consent')).body) as Map;
    expect(body['policy_version'], '2026-09-28.1');
    expect(body['consent_text_sha256'], sha256.convert(utf8.encode(server.policyText)).toString(),
        reason: '서버가 알려 준 해시가 아니라 보인 본문의 해시');
  });

  testWidgets('a text that does not match its hash is never shown or consented to', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer(status: () => statusJson(consentState: 'none', consentPolicy: null))
      ..policyHashOverride = 'f' * 64;
    final gate = _makeGate(auth, server);
    await tester.pumpWidget(_wrap(
      gate: gate,
      child: CommunityOnboardingScreen(gate: gate, auth: auth, accountClient: gate.accountClient),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('동의문 전문 보기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('동의 문서를 확인하지 못했습니다'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged, isNull);
  });

  testWidgets('before Kakao login the text is not loaded; it loads once login completes', (tester) async {
    final auth = StubAuthService();
    final server = FakeAccountServer(status: () => statusJson(consentState: 'none', consentPolicy: null));
    final gate = _makeGate(auth, server);
    await tester.pumpWidget(_wrap(
      gate: gate,
      child: CommunityOnboardingScreen(gate: gate, auth: auth, accountClient: gate.accountClient),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('동의문 전문 보기'));
    await tester.pumpAndSettle();
    expect(find.text('카카오 인증을 마치면 동의 문서를 불러옵니다.'), findsOneWidget);
    expect(server.count('/policy'), 0);
    auth.setPhase(CommunityAccountPhase.connected);
    await tester.pumpAndSettle();
    expect(server.count('/policy'), 1);
    expect(find.textContaining('시험용 동의문 본문'), findsOneWidget);
  });

  testWidgets('an account that already consented elsewhere shows it as done (no second consent)', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer();  // 같은 카카오 계정이 서버(PC)에서 이미 동의함
    final gate = _makeGate(auth, server);
    await gate.refreshNow();
    await tester.pumpWidget(_wrap(
      gate: gate,
      child: CommunityOnboardingScreen(gate: gate, auth: auth, accountClient: gate.accountClient),
    ));
    await tester.pumpAndSettle();
    expect(find.text('동의 완료'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '동의하고 계속'), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '다음')).enabled, isTrue);
    expect(server.count('/consent'), 0);
  });

  testWidgets('a changed text on consent (policy_mismatch) reloads the new text and asks again', (tester) async {
    final auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer(status: () => statusJson(consentState: 'none', consentPolicy: null))
      ..consentThrows = {'code': 'policy_mismatch', 'message': '바뀜'};
    final gate = _makeGate(auth, server);
    await tester.pumpWidget(_wrap(
      gate: gate,
      child: CommunityOnboardingScreen(gate: gate, auth: auth, accountClient: gate.accountClient),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    server.policyText = '# 바뀐 동의문\n';
    await tester.tap(find.widgetWithText(FilledButton, '동의하고 계속'));
    await tester.pumpAndSettle();
    expect(server.count('/policy'), 2, reason: '새 본문을 다시 받는다');
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse, reason: '새 본문을 읽고 다시 체크');
    expect(find.textContaining('동의 문서가 바뀌었습니다'), findsOneWidget);
  });

  test('main.dart passes the account client to the onboarding screen', () {
    // 화면 조립부 회귀 방지: 온보딩 생성자에 accountClient 가 빠지면 실제 앱에서 동의를 저장할 수 없다.
    final src = File('lib/main.dart').readAsStringSync();
    final start = src.indexOf('return CommunityOnboardingScreen(');
    expect(start, greaterThan(0));
    expect(src.substring(start, src.indexOf(');', start)), contains('accountClient: gate.accountClient'));
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
