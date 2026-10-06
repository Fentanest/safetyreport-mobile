import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_account.dart';

class _CountingAuth extends StubAuthService {
  int tokenReads = 0;

  @override
  Future<String?> getAccessToken() async {
    tokenReads++;
    return super.getAccessToken();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    setUpSecureStorage();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'demo skips tokens, account checks, first-pass hooks and polling; '
    'live mode resumes all checks',
    (tester) async {
      final auth = _CountingAuth()..setPhase(CommunityAccountPhase.connected);
      final server = FakeAccountServer();
      var mode = 'demo';
      var ownerChecks = 0;
      var accountChecks = 0;
      var firstPass = 0;
      final gate = CommunityGate(
        auth: auth,
        config: testAuthConfig(),
        configStatus: () => 'ok',
        appMode: () => mode,
        accountClient: server.accountClient(),
        deviceLabel: () => 'Test device',
        platformName: () => 'android',
        checkDataOwner: (_) async {
          ownerChecks++;
          return 'ok';
        },
        checkAccountChangeComplete: () async {
          accountChecks++;
        },
        officialAccountId: () async => 'demo-local',
      );
      addTearDown(gate.dispose);
      gate.addOnFirstPassed(() {
        firstPass++;
      });
      gate.startPolling();
      await gate.refreshNow();
      gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(minutes: 6));
      await gate.requireFresh();
      expect(gate.state.state, 'demo_mode');
      expect(
        gate.canEnter,
        isFalse,
        reason: 'UI bypass grants no upload permission',
      );
      expect(auth.tokenReads, 0);
      expect(server.requests, isEmpty);
      expect(ownerChecks, 0);
      expect(accountChecks, 0);
      expect(firstPass, 0);

      mode = 'standalone';
      gate.onAppModeChanged();
      await gate.refreshNow();
      expect(gate.canEnter, isTrue);
      expect(auth.tokenReads, greaterThan(0));
      expect(ownerChecks, 1);
      expect(accountChecks, 1);
      expect(firstPass, 1);
      final calls = server.statusCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final resumedCalls = server.statusCalls;
      expect(resumedCalls, greaterThan(calls));
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(server.statusCalls, greaterThan(resumedCalls));
      gate.stopPolling();
    },
  );

  test(
    'switching to demo invalidates an in-flight live cloud response',
    () async {
      final auth = _CountingAuth()..setPhase(CommunityAccountPhase.connected);
      final response = Completer<void>();
      final server = FakeAccountServer()..statusDelay = response.future;
      var mode = 'server';
      final gate = CommunityGate(
        auth: auth,
        config: testAuthConfig(),
        configStatus: () => 'ok',
        appMode: () => mode,
        accountClient: server.accountClient(),
        deviceLabel: () => 'Test device',
        platformName: () => 'android',
      );
      addTearDown(gate.dispose);
      final pending = gate.refreshNow();
      // Allow the request to reach the fake server, with no real network.
      await Future<void>.delayed(Duration.zero);
      mode = 'demo';
      gate.onAppModeChanged();
      response.complete();
      await pending;
      await gate.refreshNow();
      expect(gate.state.state, 'demo_mode');
      expect(gate.canEnter, isFalse);
      expect(server.statusCalls, 1);
      expect(server.count('/connections'), 0);
    },
  );
}
