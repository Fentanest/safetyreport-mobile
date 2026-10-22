// Client 모드 계정 일치 잠금(CLIENT-RULES 7절, 2026-10-22). 예전 안내 카드(ClientAccountMismatchNotice)를 대신한다.
// - 둘 다 32자리 16진이고 다르면 `client_account_mismatch` 잠금: 동의 카드 숨김, "로그아웃 후 다시 로그인".
// - 같은 지문·서버 계정 사라짐(account: null)이면 해제.
// - 서버에 닿지 못함·시간 초과·5xx·형식 이상·account 키 없음·지문 빈 값/형식 틀림이면 새로 잠그지 않는다(먹통 회귀).
// - 서버 "온보딩 필요" 거절은 지금처럼 잠금 + "서버의 커뮤니티 계정" 카드로 가는 버튼.
// - 503 community_unconfigured 는 잠그지 않고 안내만.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/screens/community_onboarding_screen.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_account.dart';

const phoneFp = '0123456789abcdef0123456789abcdef';
const otherFp = 'fedcba9876543210fedcba9876543210';

CommunityGateLinkResult pcWith(Object? account) =>
    CommunityGateLinkResult.success({
      'can_local': true,
      'can_enter': true,
      'kakao': true,
      'consent': {'state': 'active'},
      'account': account,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    setUpSecureStorage();
    SharedPreferences.setMockInitialValues({});
  });

  Future<(CommunityGate, StubAuthService)> clientGate(
    Future<CommunityGateLinkResult> Function() pc, {
    String phone = phoneFp,
  }) async {
    final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer(
      status: () => statusJson(fingerprint: phone),
    );
    final gate = CommunityGate(
      checkDataOwner: ownerOk,
      serverGate: pc,
      config: testAuthConfig(),
      auth: auth,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => 'server',
    );
    addTearDown(gate.dispose);
    await gate.refreshNow();
    return (gate, auth);
  }

  group('serverAccountMismatch / clientAccountVerdict', () {
    test('only two 32-hex fingerprints that differ are a mismatch', () {
      expect(serverAccountMismatch(phoneFp, otherFp), isTrue);
      expect(serverAccountMismatch(phoneFp, phoneFp), isFalse);
      expect(serverAccountMismatch('aa', 'bb'), isFalse);
      expect(serverAccountMismatch(phoneFp, ''), isFalse);
      expect(serverAccountMismatch(null, otherFp), isFalse);
      expect(serverAccountMismatch(phoneFp, otherFp.toUpperCase()), isFalse);
    });

    test('decision table', () {
      Map<String, Object?> data(Object? account) => {'account': account};
      expect(
        clientAccountVerdict(data({'fingerprint': otherFp}), phoneFp),
        'lock',
      );
      expect(
        clientAccountVerdict(data({'fingerprint': phoneFp}), phoneFp),
        'unlock',
      );
      expect(clientAccountVerdict(data(null), phoneFp), 'unlock');
      expect(clientAccountVerdict(null, phoneFp), 'keep');
      expect(clientAccountVerdict({'can_enter': true}, phoneFp), 'keep');
      expect(clientAccountVerdict(data('x'), phoneFp), 'keep');
      expect(clientAccountVerdict(data({'fingerprint': ''}), phoneFp), 'keep');
      expect(
        clientAccountVerdict(data({'fingerprint': 'not-hex'}), phoneFp),
        'keep',
      );
      expect(
        clientAccountVerdict(data({'fingerprint': otherFp}), 'fp-32hex'),
        'keep',
      );
    });
  });

  group('gate', () {
    test('the same fingerprint passes', () async {
      final (gate, _) = await clientGate(
        () async => pcWith({'fingerprint': phoneFp, 'display_name': '서버'}),
      );
      expect(gate.state.state, 'ok');
      expect(gate.clientAccountLocked, isFalse);
    });

    test('a different fingerprint locks, and unlocks after the same account returns', () async {
      var server = otherFp;
      final (gate, _) = await clientGate(
        () async => pcWith({'fingerprint': server, 'display_name': '서버계정'}),
      );
      expect(gate.state.state, 'client_account_mismatch');
      expect(gate.canBrowse, isFalse);
      expect(gate.clientAccountServerName, '서버계정');
      // Restart: the lock is kept while the PC cannot be asked.
      final (again, _) = await clientGate(() async => throw Exception('offline'));
      expect(again.state.state, 'client_account_mismatch');
      // The phone logs in with the server's account → unlocked.
      server = phoneFp;
      await gate.refreshNow();
      expect(gate.state.state, 'ok');
      expect(gate.clientAccountLocked, isFalse);
    });

    test('the server account disappearing (account: null) unlocks', () async {
      Object? account = {'fingerprint': otherFp};
      final (gate, _) = await clientGate(() async => pcWith(account));
      expect(gate.state.state, 'client_account_mismatch');
      account = null;
      await gate.refreshNow();
      expect(gate.clientAccountLocked, isFalse);
      expect(gate.state.state, 'ok');
    });

    for (final entry in <String, Future<CommunityGateLinkResult> Function()>{
      'unreachable': () async => CommunityGateLinkResult.failure(
        code: 'offline',
        offline: true,
      ),
      'timeout/exception': () async => throw Exception('timeout'),
      '5xx': () async =>
          CommunityGateLinkResult.failure(code: 'server_error', httpStatus: 502),
      'malformed': () async => CommunityGateLinkResult.parse(200, '<html>'),
      'no account key': () async =>
          CommunityGateLinkResult.success({'can_enter': true}),
      'empty fingerprint': () async => pcWith({'fingerprint': ''}),
      'malformed fingerprint': () async => pcWith({'fingerprint': 'abc'}),
    }.entries) {
      test('${entry.key} never locks (no-hang regression)', () async {
        final (gate, _) = await clientGate(entry.value);
        expect(gate.state.state, isNot('client_account_mismatch'));
        expect(gate.clientAccountLocked, isFalse);
      });
    }

    test('503 community_unconfigured does not lock; it only marks the notice', () async {
      final (gate, _) = await clientGate(
        () async => CommunityGateLinkResult.parse(
          503,
          '{"code":"community_unconfigured","message":"x"}',
        ),
      );
      expect(gate.state.state, 'ok');
      expect(gate.clientServerUnconfigured, isTrue);
      expect(gate.clientServerCheckPending, isFalse);
    });

    test('server onboarding required keeps the existing lock', () async {
      final (gate, _) = await clientGate(
        () async => CommunityGateLinkResult.parse(
          403,
          '{"code":"COMMUNITY_ONBOARDING_REQUIRED"}',
        ),
      );
      expect(gate.state.state, 'server_consent_required');
      expect(gate.clientServerNeedsOnboarding, isTrue);
    });

    test('mismatch wins over the consent step (consent cannot be changed)', () async {
      final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
      final server = FakeAccountServer(
        status: () =>
            statusJson(fingerprint: phoneFp, consentState: 'none'),
      );
      final gate = CommunityGate(
        checkDataOwner: ownerOk,
        serverGate: () async => pcWith({'fingerprint': otherFp}),
        config: testAuthConfig(),
        auth: auth,
        accountClient: server.accountClient(),
        configStatus: () => 'ok',
        appMode: () => 'server',
      );
      addTearDown(gate.dispose);
      await gate.refreshNow();
      expect(gate.state.state, 'client_account_mismatch');
    });
  });

  group('lock screen', () {
    testWidgets('mismatch: message and relogin button, no consent card', (
      tester,
    ) async {
      final result = await tester.runAsync(
        () => clientGate(
          () async => pcWith({'fingerprint': otherFp, 'display_name': '서버계정'}),
        ),
      );
      final (gate, auth) = result!;
      await tester.pumpWidget(
        MaterialApp(
          home: CommunityOnboardingScreen(
            gate: gate,
            auth: auth,
            accountClient: FakeAccountServer().accountClient(),
            clientServer: (baseUrl: 'https://nas.example.test', apiKey: 'k'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('clientAccountMismatch')), findsOneWidget);
      expect(
        find.text('서버에 연결된 카카오 계정(서버계정)으로 다시 로그인해 주세요.'),
        findsOneWidget,
      );
      expect(find.text('로그아웃 후 다시 로그인'), findsOneWidget);
      expect(find.text('신고내용 공유 동의'), findsNothing);
    });

    testWidgets('server onboarding: button to the server account card', (
      tester,
    ) async {
      final result = await tester.runAsync(
        () => clientGate(
          () async => CommunityGateLinkResult.parse(
            403,
            '{"code":"COMMUNITY_ONBOARDING_REQUIRED"}',
          ),
        ),
      );
      final (gate, auth) = result!;
      await tester.pumpWidget(
        MaterialApp(
          home: CommunityOnboardingScreen(
            gate: gate,
            auth: auth,
            accountClient: FakeAccountServer().accountClient(),
            clientServer: (baseUrl: 'https://nas.example.test', apiKey: 'k'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('openServerAccountCard')), findsOneWidget);
      expect(find.text('서버의 커뮤니티 계정 열기'), findsOneWidget);
    });
  });
}
