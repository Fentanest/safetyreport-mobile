import 'package:shared_preferences/shared_preferences.dart';
// Client mode: "PC 서버 연결 대기" is shown where the user sees it (main navigation banner),
// never as a lock.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
import 'package:safetyreport/widgets/cloud_delay_banner.dart';

import '../community/fake_account.dart';

void main() {
  setUp(() {
    setUpSecureStorage();
    SharedPreferences.setMockInitialValues({});
  });

  CommunityGate makeGate(Future<CommunityGateLinkResult> Function() serverGate) {
    final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    final gate = CommunityGate(
      checkDataOwner: ownerOk,
      serverGate: serverGate,
      config: testAuthConfig(),
      auth: auth,
      store: null,
      accountClient: FakeAccountServer().accountClient(),
      configStatus: () => 'ok',
      appMode: () => 'server',
      officialAccountId: () async => null,
    );
    addTearDown(gate.dispose);
    return gate;
  }

  testWidgets('unreachable PC shows the waiting note and does not lock', (tester) async {
    final gate = makeGate(
      () async => CommunityGateLinkResult.failure(code: 'offline', offline: true),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ClientServerWaitingBanner(gate: gate))),
    );
    expect(find.textContaining('PC 서버 연결 대기'), findsNothing);
    await tester.runAsync(() => gate.refreshNow());
    await tester.pump();
    expect(gate.canEnter, isTrue);
    expect(find.textContaining('PC 서버 연결 대기'), findsOneWidget);
  });

  testWidgets('a failed version recheck marks waiting, the next gate check clears it', (tester) async {
    final gate = makeGate(pcGateOk);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ClientServerWaitingBanner(gate: gate))),
    );
    await tester.runAsync(() => gate.refreshNow());
    await tester.pump();
    expect(find.textContaining('PC 서버 연결 대기'), findsNothing);
    gate.markClientServerUnreachable();
    await tester.pump();
    expect(find.textContaining('PC 서버 연결 대기'), findsOneWidget);
    expect(gate.canEnter, isTrue);
    await tester.runAsync(() async {
      gate.invalidate('poll');
      await gate.refreshNow();
    });
    await tester.pump();
    expect(find.textContaining('PC 서버 연결 대기'), findsNothing);
  });
}
