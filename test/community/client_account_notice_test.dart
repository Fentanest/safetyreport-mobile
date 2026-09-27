// Client 모드: 이 앱과 서버(PC)의 카카오 계정이 다르면 알린다(2026-09-27). 같으면 아무것도 보이지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/client_account_notice.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/community_server_link_service.dart';

import 'fake_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecureStorage);

  Future<CommunityGate> clientGate(String phoneFingerprint) async {
    final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer(status: () => statusJson(fingerprint: phoneFingerprint));
    final gate = CommunityGate(
      checkDataOwner: ownerOk,
      config: testAuthConfig(),
      auth: auth,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => 'server',
    );
    addTearDown(gate.dispose);
    await gate.refreshNow();
    return gate;
  }

  Future<void> pumpNotice(WidgetTester tester, CommunityGate gate, String serverFingerprint) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClientAccountMismatchNotice(
          gate: gate,
          baseUrl: 'https://nas.example.test',
          apiKey: 'k',
          fetchServerGate: () async => CommunityGateLinkResult.success({
            'account': {'fingerprint': serverFingerprint, 'display_name': '서버계정'},
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('different accounts show the notice with both names', (tester) async {
    final gate = await tester.runAsync(() => clientGate('fp-phone'));
    await pumpNotice(tester, gate!, 'fp-server');
    expect(find.byKey(const Key('clientAccountMismatch')), findsOneWidget);
    expect(find.textContaining('서버: 서버계정'), findsOneWidget);
  });

  testWidgets('the same account shows nothing', (tester) async {
    final gate = await tester.runAsync(() => clientGate('fp-same'));
    await pumpNotice(tester, gate!, 'fp-same');
    expect(find.byKey(const Key('clientAccountMismatch')), findsNothing);
  });
}
