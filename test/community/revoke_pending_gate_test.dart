// (revoke pending lock) Gate review fixes (mobile-review 1, 4, 5, 7, 8, 16 + low items): a revoked account can log in
// again and reach the consent screen, Client mode is not locked by an unreachable PC, upgrade
// seeding of the 72-hour grace, and the background withdrawal retry back-off.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/soft_reset.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
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
    tmp = await Directory.systemTemp.createTemp('gate_review_test');
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

  CommunityGate makeGate(
    FakeAccountServer server, {
    String mode = 'standalone',
    Future<CommunityGateLinkResult> Function()? serverGate,
  }) {
    final gate = CommunityGate(
      checkDataOwner: ownerOk,
      serverGate: serverGate ?? pcGateOk,
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => mode,
      officialAccountId: () async => 'User@Example.com',
    );
    addTearDown(gate.dispose);
    return gate;
  }

  group('revoke pending without a usable session', () {
    for (final phase in [
      CommunityAccountPhase.reauthRequired,
      CommunityAccountPhase.disconnected,
    ]) {
      test('stays revoke_pending when the session is $phase', () async {
        final server = FakeAccountServer(status: () => statusJson());
        final gate = makeGate(server);
        await CommunityReset.begin(store, 'g', auth: auth, client: server.accountClient());
        auth.setPhase(phase);
        await gate.refreshNow();
        expect(gate.state.state, 'revoke_pending');
        expect(gate.canEnter, isFalse);
        expect(gate.canBrowse, isFalse);
      });
    }

    test('stays revoke_pending when the token is gone', () async {
      final server = FakeAccountServer(status: () => statusJson());
      final gate = makeGate(server);
      await CommunityReset.begin(store, 'g', auth: auth, client: server.accountClient());
      auth.tokenResult = null;
      await gate.refreshNow();
      expect(gate.state.state, 'revoke_pending');
    });
  });
  group('revoke completes', () {
    test('after a fresh login keeps that session and shows the consent screen (one login only)', () async {
      var current = statusJson();
      final server = FakeAccountServer(status: () => current);
      final gate = makeGate(server);
      expect((await gate.refreshNow()).canEnter, isTrue);
      await CommunityReset.begin(store, 'g', auth: auth, client: server.accountClient());
      auth.tokenResult = null; // the token is gone, so the revoke cannot complete
      expect(await CommunityReset.attempt(store, auth: auth, client: server.accountClient(), force: true), isFalse);
      expect(await CommunityReset.pending(store), isNotNull);
      auth.setPhase(CommunityAccountPhase.disconnected);
      // Fresh Kakao login made while the revoke is pending.
      current = statusJson(consentState: 'revoked');
      auth.tokenResult = 'fresh-token';
      auth.connectedAt = '2026-10-21T02:00:00.000Z';
      auth.setPhase(CommunityAccountPhase.connected);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await CommunityReset.pending(store), isNull, reason: 'revoke completed');
      expect(auth.state.value.phase, CommunityAccountPhase.connected, reason: 'no second login');
      gate.invalidate('poll');
      expect((await gate.refreshNow()).state, 'consent_required');
      expect(auth.state.value.phase, CommunityAccountPhase.connected);
      expect(gate.canEnter, isFalse);
      expect(await store.activeContext(), isNull);
      // Let the gate-started attempt finish releasing its lease before the store is closed.
      for (var i = 0; i < 100; i++) {
        if (await CommunityReset.attempt(store, auth: auth)) break; // false while the attempt is in flight
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500)); // background gate refresh settles
    });

    test('with the original session disconnects to the Kakao step (unchanged)', () async {
      final server = FakeAccountServer(status: () => statusJson());
      await CommunityReset.begin(store, 'g', auth: auth, client: server.accountClient());
      // A background attempt left by an earlier test may still hold the static in-flight flag; retry briefly.
      var ok = false;
      for (var i = 0; i < 20 && !ok; i++) {
        ok = await CommunityReset.attempt(store, auth: auth, client: server.accountClient(), force: true);
        if (!ok) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(ok, isTrue);
      expect(await CommunityReset.pending(store), isNull);
      expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
    });
  });
}
