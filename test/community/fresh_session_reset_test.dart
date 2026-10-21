// A disconnect webhook removes the session along with the consent. The user logs in again with
// the same Kakao account: that NEW session must not be cut by the remote reset (no second login).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/consent_history.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/soft_reset.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;
  late StubAuthService auth;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    setUpSecureStorage();
    tmp = await Directory.systemTemp.createTemp('fresh_session_reset_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(
      path: dbPath,
      factory: databaseFactoryFfi,
    );
    auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
  });
  tearDown(() async {
    CommunityReset.pauseForegroundRetry();
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityGate makeGate(FakeAccountServer server) {
    final gate = CommunityGate(
      checkDataOwner: ownerOk,
      serverGate: pcGateOk,
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => 'standalone',
      officialAccountId: () async => 'User@Example.com',
    );
    addTearDown(gate.dispose);
    return gate;
  }

  Map<String, Object?> status({
    String consent = 'active',
    String contributor = 'active',
    bool kakao = true,
    List<String> reasons = const [],
  }) {
    final s = statusJson(consentState: consent, contributor: contributor);
    s['gate'] = {
      'kakao': kakao,
      'consent': true,
      'can_enter': true,
      'reasons': reasons,
    };
    return s;
  }

  Future<Map<String, Object?>?> history() =>
      ConsentHistory(store).latest('fp-32hex');

  const s1 = '2026-10-21T01:00:00.000Z', s2 = '2026-10-21T02:00:00.000Z';

  /// The webhook removed the session; the user logs in again with the same Kakao account (new
  /// session). The login itself triggers the gate check, as in the app.
  Future<void> relogin(CommunityGate gate) async {
    auth.setPhase(CommunityAccountPhase.disconnected);
    await Future<void>.delayed(
      const Duration(milliseconds: 400),
    ); // the gate settles on kakao_required
    auth.connectedAt = s2;
    auth.setPhase(CommunityAccountPhase.connected);
    // Wait until the reset consumed the G1 evidence (the check after a login is asynchronous).
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if ((await history())?['reset_completed_at'] != null) break;
    }
    for (var i = 0; i < 100; i++) {
      if (gate.state.state != 'verification_required') break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  test(
    'G1(S1) -> relogin(S2) -> revoked: reset keeps the new session, consent screen',
    () async {
      var current = status();
      final gate = makeGate(FakeAccountServer(status: () => current));
      expect((await gate.refreshNow()).canEnter, isTrue);
      expect(((await history())!['last_g1'] as Map)['session'], s1);

      current = status(consent: 'revoked');
      await relogin(gate);
      expect(gate.state.state, 'consent_required');
      expect(auth.state.value.phase, CommunityAccountPhase.connected);
      expect((await history())!['last_g1'], isNull, reason: '근거는 소모된다');

      // The reset is once per G1: the same revoked answer stays the consent screen.
      gate.invalidate('poll');
      expect((await gate.refreshNow()).state, 'consent_required');
      expect(auth.state.value.phase, CommunityAccountPhase.connected);
    },
  );

  test('same session S1 revoked still disconnects (kakao_required)', () async {
    var current = status();
    final gate = makeGate(FakeAccountServer(status: () => current));
    await gate.refreshNow();
    current = status(consent: 'revoked');
    gate.invalidate('poll');
    expect((await gate.refreshNow()).state, 'kakao_required');
    expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
  });

  test('seeded G1 (no session) still disconnects on a new session', () async {
    var current = status();
    final gate = makeGate(FakeAccountServer(status: () => current));
    await gate.refreshNow();
    final h = (await history())!;
    (h['last_g1'] as Map).remove(
      'session',
    ); // upgrade seed: no session recorded
    await ConsentHistory(
      store,
    ).storage.write(key: ConsentHistory.key('fp-32hex'), value: jsonEncode(h));
    current = status(consent: 'revoked');
    await relogin(gate);
    expect(gate.state.state, 'kakao_required');
    expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
  });

  test(
    'contributor none (G8) and kakao missing (G7) use the same fresh rule',
    () async {
      for (final bad in [
        status(contributor: 'none'),
        status(kakao: false, reasons: ['kakao_missing']),
      ]) {
        auth.connectedAt = s1;
        auth.setPhase(CommunityAccountPhase.connected);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        var current = status();
        final gate = makeGate(FakeAccountServer(status: () => current));
        await gate.refreshNow();
        current = bad;
        await relogin(gate);
        // G7: the server itself still says kakao=false, so the gate stays kakao_required afterwards;
        // the point is that the reset did not cut the new session.
        if (bad['gate'] is Map && (bad['gate'] as Map)['kakao'] == true) {
          expect(gate.state.state, 'consent_required', reason: '$bad');
        }
        expect(auth.state.value.phase, CommunityAccountPhase.connected);
        await ConsentHistory(store).clearG1('fp-32hex');
      }
    },
  );

  test(
    'markG1 refreshes the session; a caller without one keeps the earlier value',
    () async {
      final h = ConsentHistory(store);
      await h.markG1('fp-32hex', 'kakao-1', 'ds', session: s1);
      expect(((await history())!['last_g1'] as Map)['session'], s1);
      await h.markG1('fp-32hex', 'kakao-1', 'ds', session: s2);
      expect(((await history())!['last_g1'] as Map)['session'], s2);
      await h.markG1('fp-32hex', 'kakao-1', 'ds');
      expect(((await history())!['last_g1'] as Map)['session'], s2);
    },
  );
}
