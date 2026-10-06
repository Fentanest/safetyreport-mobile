// SQ-P01 ③: 게이트의 조용한 갱신(60초 poll·앱 복귀)은 결과가 같으면 알리지 않는다.
// 알림마다 루트·화면이 다시 빌드되므로 상태가 실제로 바뀔 때만 알린다.
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';

import 'fake_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StubAuthService auth;
  late FakeAccountServer server;

  setUp(() {
    setUpSecureStorage();
    auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    server = FakeAccountServer();
  });

  CommunityGate gate({String mode = 'server'}) {
    final g = CommunityGate(
      checkDataOwner: ownerOk,
      config: testAuthConfig(),
      auth: auth,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => mode,
    );
    addTearDown(g.dispose);
    return g;
  }

  test('official dataset change invalidates gate even in the same mode', () async {
    var generation = 0;
    final g = CommunityGate(
      checkDataOwner: ownerOk,
      config: testAuthConfig(), auth: auth,
      accountClient: server.accountClient(), configStatus: () => 'ok',
      appMode: () => 'server', datasetGeneration: () => generation,
    );
    addTearDown(g.dispose);
    await g.refreshNow();
    expect(g.canEnter, isTrue);
    final checked = server.statusCalls;
    generation++;
    g.onAppModeChanged();
    expect(g.canEnter, isFalse);
    await g.refreshNow();
    expect(g.canEnter, isTrue);
    expect(server.statusCalls, greaterThan(checked));
  });

  test('silent refresh with the same result does not notify', () async {
    final g = gate();
    expect((await g.refreshNow()).canEnter, isTrue);
    var notified = 0;
    g.addListener(() => notified++);

    await g.refreshNow(silent: true);
    await g.refreshNow(silent: true);
    expect(server.statusCalls, greaterThanOrEqualTo(3), reason: '실제로 다시 확인했다');
    expect(notified, 0, reason: '같은 결과면 알리지 않는다');
    expect(g.canEnter, isTrue);
  });

  test('silent refresh that changes the result still notifies', () async {
    final g = gate();
    expect((await g.refreshNow()).canEnter, isTrue);
    var notified = 0;
    g.addListener(() => notified++);

    auth.tokenResult = null;
    await g.refreshNow(silent: true);
    expect(g.canEnter, isFalse);
    expect(notified, greaterThan(0), reason: '상태가 바뀌면 알린다');
  });

  test(
    'silent refresh while not configured: first check notifies, repeats do not',
    () async {
      final g = CommunityGate(
        config: testAuthConfig(),
        auth: auth,
        accountClient: server.accountClient(),
        configStatus: () => 'missing',
        appMode: () => 'server',
      );
      addTearDown(g.dispose);
      var notified = 0;
      g.addListener(() => notified++);
      await g.refreshNow(silent: true);
      expect(g.isChecked, isTrue);
      expect(notified, greaterThan(0), reason: '첫 확인 완료는 알린다');
      final first = notified;
      await g.refreshNow(silent: true);
      await g.refreshNow(silent: true);
      expect(notified, first);
    },
  );
}
