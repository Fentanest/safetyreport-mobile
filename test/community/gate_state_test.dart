// CommunityGate — 캐시·무효화·연결 등록·컨텍스트 기록 (네트워크 없이 가짜 주입).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;
  late StubAuthService auth;
  late FakeAccountServer server;

  setUp(() async {
    setUpSecureStorage();
    tmp = await Directory.systemTemp.createTemp('gate_state_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
    auth = StubAuthService();
    auth.setPhase(CommunityAccountPhase.connected);
    server = FakeAccountServer();
  });

  tearDown(() async {
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityGate makeGate({
    String Function()? configStatus,
    String Function()? appMode,
    Future<String?> Function()? officialAccountId,
  }) {
    final gate = CommunityGate(
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: server.accountClient(),
      configStatus: configStatus ?? () => 'ok',
      appMode: appMode ?? () => 'standalone',
      officialAccountId: officialAccountId ?? () async => 'User@Example.com',
    );
    addTearDown(gate.dispose);
    return gate;
  }

  test('F13: fresh cache needs no re-login and no extra HTTP', () async {
    final gate = makeGate();
    final first = await gate.refreshNow();
    expect(first.canEnter, isTrue);
    expect(server.statusCalls, 1);
    expect(gate.isChecked, isTrue);
    final second = await gate.requireFresh();
    expect(second.canEnter, isTrue);
    expect(server.statusCalls, 1, reason: '유효 캐시면 재요청 없음');
    final ctx = await store.context();
    expect(ctx?['state'], 'active');
    expect(ctx?['contributor_fingerprint'], 'fp-32hex');
    expect(ctx?['dataset_key'], isNotNull);
    expect((ctx?['dataset_key'] as String).length, 64);
  });

  test('F14: revoke and policy change re-evaluate to consent_required', () async {
    final gate = makeGate();
    expect((await gate.refreshNow()).canEnter, isTrue);

    server = FakeAccountServer(
      status: () => statusJson(consentState: 'revoked', consentPolicy: null),
    );
    final gate2 = CommunityGate(
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      officialAccountId: () async => 'User@Example.com',
    );
    addTearDown(gate2.dispose);
    final revoked = await gate2.refreshNow();
    expect(revoked.state, 'consent_required');
    expect((await store.context())?['state'], 'inactive');

    final server3 = FakeAccountServer(
      status: () => statusJson(consentState: 'outdated', consentPolicy: '2026-01-01.1'),
    );
    final gate3 = CommunityGate(
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: server3.accountClient(),
      configStatus: () => 'ok',
      officialAccountId: () async => 'User@Example.com',
    );
    addTearDown(gate3.dispose);
    expect((await gate3.refreshNow()).state, 'consent_required');
  });

  test('invalidate forces verification_required; suspended deactivates', () async {
    final gate = makeGate();
    expect((await gate.refreshNow()).canEnter, isTrue);
    gate.invalidate('test');
    expect(gate.state.state, 'verification_required');
    expect(gate.canEnter, isFalse);

    final suspended = FakeAccountServer(
      status: () => statusJson(contributor: 'suspended'),
    );
    final gate2 = CommunityGate(
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: suspended.accountClient(),
      configStatus: () => 'ok',
      officialAccountId: () async => 'User@Example.com',
    );
    addTearDown(gate2.dispose);
    expect((await gate2.refreshNow()).state, 'suspended');
  });

  test('no session: no status call, kakao_required', () async {
    auth.setPhase(CommunityAccountPhase.disconnected);
    auth.tokenResult = null;
    final gate = makeGate();
    final state = await gate.refreshNow();
    expect(state.state, 'kakao_required');
    expect(server.statusCalls, 0);
  });

  test('writer_conflict surfaces takeover path; takeover clears it', () async {
    server = FakeAccountServer(
      registerThrows: {'code': 'writer_conflict', 'message': 'taken'},
    );
    final gate = makeGate();
    expect((await gate.refreshNow()).canEnter, isTrue);
    expect(gate.writerConflict, isNotNull);
    expect(server.count('/connections'), 1);
    // takeover 재등록 성공 시 충돌 해소.
    server.registerThrows = null;
    final ok = await gate.requestTakeover();
    expect(ok, isTrue);
    expect(gate.writerConflict, isNull);
  });

  test('F16/F17 client: no writer registration, upload context stays off', () async {
    final gate = makeGate(
      appMode: () => 'server',
      officialAccountId: () async => 'User@Example.com',
    );
    expect((await gate.refreshNow()).canEnter, isTrue);
    expect(server.count('/connections'), 0);
    expect(server.count('/connections-rebind'), 0);
    // 통합 검수(2026-09-26): Client 폰은 writer 가 아니므로 업로드 context 를 켜지 않는다(서버가 올린다).
    final ctx = await store.context();
    expect(ctx?['state'], 'inactive');
    expect(ctx?['inactive_reason'], 'client_mode');
  });
}
