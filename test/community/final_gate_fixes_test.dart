// 최종 모바일 검토(2026-10-21) 항목 1, 2, 7, 10, 11 회귀 시험.
// 1: Client 도 서버 일시 장애에서 72시간 유예를 받는다(업그레이드 시드 포함). 2: 게이트의 일시 비활성화가 개인 동기화를 끊지 않는다.
// 7: 철회를 거친 재동의(계보 변경)만 원본 전송 완료 표시를 지운다. 10: 헤드리스 리셋 이력·세션 재읽기. 11: 다른 계정 로그인 안내.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/consent_catchup.dart';
import 'package:safetyreport/community/consent_history.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/soft_reset.dart';
import 'package:safetyreport/community/upload/upload_background.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/sync_operation_admission.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_account.dart';
import 'uploader_test.dart' as u;

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
    tmp = await Directory.systemTemp.createTemp('final_gate');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
    auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
  });
  tearDown(() async {
    CommunityReset.pauseForegroundRetry();
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityGate makeGate(FakeAccountServer server, {String mode = 'standalone'}) {
    final gate = CommunityGate(
      checkDataOwner: ownerOk,
      serverGate: pcGateOk,
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

  group('1. Client keeps working through a cloud outage (72h grace)', () {
    test('a good check, then a 503: browsing stays open, entry does not', () async {
      final server = FakeAccountServer();
      final gate = makeGate(server, mode: 'server');
      await gate.refreshNow();
      expect(gate.canEnter, isTrue);
      server.statusFailures = 5;
      gate.invalidate('poll');
      final second = await gate.refreshNow();
      expect(second.state, 'cloud_unavailable');
      expect(gate.canEnter, isFalse);
      expect(gate.canBrowse, isTrue, reason: 'base 는 Client 에 로컬 사용을 열어 두었다');
    });

    test('upgrade: a history without last_g1 is seeded for Client too (offline first start)', () async {
      final fp = (await auth.sessionFingerprint())!;
      await ConsentHistory(store).event(fp, 'ok', 'server-status', status: statusJson(), grant: 'g');
      expect((await ConsentHistory(store).latest(fp))!['last_g1'], isNull);
      final server = FakeAccountServer()..statusFailures = 5;
      final gate = makeGate(server, mode: 'server');
      final first = await gate.refreshNow();
      expect(first.state, 'cloud_unavailable');
      expect(gate.canBrowse, isTrue);
      expect((await ConsentHistory(store).latest(fp))!['last_g1'], isNotNull);
    });

    test('no earlier verification: Client is not opened by an outage', () async {
      final server = FakeAccountServer()..statusFailures = 5;
      final gate = makeGate(server, mode: 'server');
      await gate.refreshNow();
      expect(gate.canBrowse, isFalse);
    });

    test('an explicit consent refusal still locks Client', () async {
      final server = FakeAccountServer(status: () => statusJson(consentState: 'revoked'));
      final gate = makeGate(server, mode: 'server');
      await gate.refreshNow();
      expect(gate.canBrowse, isFalse);
    });

    test('standalone upgrade (offline first start) is unchanged', () async {
      final fp = (await auth.sessionFingerprint())!;
      await ConsentHistory(store).event(fp, 'ok', 'server-status', status: statusJson(), grant: 'g');
      final server = FakeAccountServer()..statusFailures = 5;
      final gate = makeGate(server);
      await gate.refreshNow();
      expect(gate.canBrowse, isTrue);
    });
  });

  group('2. personal sync survives a transient inactive context', () {
    late CommunityStore s;
    setUp(() async => s = await u.openStore());
    tearDown(() => u.closeStore(s));

    Future<R> inSync<R>(Future<R> Function() body) async {
      final result = await SyncOperationAdmission.run<R?>(body, null, openStore: () async => s);
      return result as R;
    }

    test('deactivating the context mid-sync does not fail the next ownership check', () async {
      await inSync(() async {
        await SyncOperationAdmission.checkOwnership();
        await s.deactivateContext('cloud_unavailable');
        await SyncOperationAdmission.checkOwnership();
        return 1;
      });
    });

    test('a different dataset or a new work generation still fails', () async {
      await expectLater(
        inSync(() async {
          await s.db.update('context', {'dataset_key': 'other-dataset'});
          await SyncOperationAdmission.checkOwnership();
          return 1;
        }),
        throwsA(predicate((e) => '$e'.contains('sync_context_changed'))),
      );
    });

    test('work_generation change fails', () async {
      await expectLater(
        inSync(() async {
          await SyncOperationAdmission.cancelAll(s);
          await SyncOperationAdmission.checkOwnership();
          return 1;
        }),
        throwsA(predicate((e) => '$e'.contains('sync_'))),
      );
    });
  });

  group('7. re-consent on a new lineage resends everything', () {
    test('history marks non-active -> active as a lineage change, a renewed grant is not', () async {
      final h = ConsentHistory(store);
      await h.event('fp', 'ok', 'status', status: statusJson(), grant: 'g0');
      await h.event('fp', 'ok', 'status', status: statusJson(consentState: 'revoked'), grant: 'g0');
      await h.event('fp', 'ok', 'status', status: statusJson(), grant: 'g1');
      expect(await h.catchupLineageChanged('fp', 'g1'), isTrue);
      // Same lineage: active -> active with a new grant (e.g. a new consent text).
      await h.event('other', 'ok', 'status', status: statusJson(), grant: 'a0');
      await h.event('other', 'ok', 'status', status: statusJson(), grant: 'a1');
      expect(await h.needsCatchup('other', 'a1'), isTrue);
      expect(await h.catchupLineageChanged('other', 'a1'), isFalse);
    });

    Future<void> runCatchup(CommunityStore s, {required bool lineageChanged}) async {
      final ctx = (await s.activeContext())!;
      await s.setMeta(
        'ingest_status',
        jsonEncode({
          'consent': {'state': 'active', 'grant_id': ctx['consent_grant_id'], 'policy_version': ctx['policy_version']},
          'ingest': {'contracts': [1, 2], 'raw_policy_version': ctx['policy_version']},
        }),
      );
      await s.setMeta('raw_backfill', jsonEncode({'state': 'done', 'run_id': 'old'}));
      await s.setMeta('raw_backfill_retry', 'true');
      await ConsentCatchup(s).schedule(ctx, lineageChanged: lineageChanged);
      await ConsentCatchup(s).run(
        verify: () async => true,
        manifest: () async => true,
        collectAll: () async => true,
      );
    }

    test('lineage-changed job drops the finished marker so a new run resends all', () async {
      final s = await u.openStore();
      addTearDown(() => u.closeStore(s));
      await runCatchup(s, lineageChanged: true);
      expect(await s.meta('raw_backfill'), isNull);
      expect(await s.meta('raw_backfill_retry'), isNull);
    });

    test('a same-lineage job keeps the marker', () async {
      final s = await u.openStore();
      addTearDown(() => u.closeStore(s));
      await runCatchup(s, lineageChanged: false);
      expect(await s.meta('raw_backfill'), isNotNull);
    });
  });

  group('10. headless reset leaves the remote-reset history; the foreground rereads the stored session', () {
    test('headlessSoftReset records a local revoke (same account re-login goes to consent, not another reset)', () async {
      final fp = (await auth.sessionFingerprint())!;
      await ConsentHistory(store).markG1(fp, '910001', 'ds1');
      await ConsentHistory(store).event(fp, 'ok', 'status', status: statusJson(), grant: 'g');
      await headlessSoftReset(store, fp, 'g', auth: auth);
      final history = (await ConsentHistory(store).latest(fp))!;
      expect(history['local_revoke'], true);
      expect(history['consent_state'], 'revoked');
      expect(history['result'], 'consent_required');
      expect(history['last_g1'], isNull, reason: 'G1 증거는 리셋이 소비한다');
      expect((history['transitions'] as List).last['source'], 'remote-reset');
    });

    test('a memory session that storage no longer has is dropped on the next check', () async {
      final server = FakeAccountServer();
      final gate = makeGate(server);
      await gate.refreshNow();
      expect(gate.canEnter, isTrue);
      auth.storedPhase = CommunityAccountPhase.disconnected; // 헤드리스가 저장소의 세션을 지웠다
      gate.invalidate('poll');
      final next = await gate.refreshNow();
      expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
      expect(next.state, 'kakao_required');
      expect(gate.canBrowse, isFalse);
    });
  });

  group('11. revoke pending with another Kakao account', () {
    test('begin records the display name; a different account is flagged with the pending name', () async {
      final server = FakeAccountServer();
      final gate = makeGate(server);
      await CommunityReset.begin(store, 'g', auth: auth, client: server.accountClient());
      final item = (await CommunityReset.pending(store))!;
      expect(item['display_name'], '테스터');
      await gate.refreshNow();
      expect(gate.state.state, 'revoke_pending');
      expect(gate.revokeAccountMismatch, isFalse, reason: '같은 계정');
      // 다른 카카오 계정으로 로그인한 것처럼: 대기 항목의 계정이 지금 세션과 다르다.
      item['account'] = 'another-fp';
      item['display_name'] = '철회계정';
      item['next_attempt_at'] = DateTime.now().millisecondsSinceEpoch / 1000 + 3600;
      await store.setMeta('revoke_pending', jsonEncode(item));
      gate.invalidate('poll');
      await gate.refreshNow();
      expect(gate.state.state, 'revoke_pending');
      expect(gate.revokeAccountMismatch, isTrue);
      expect(gate.revokeAccountName, '철회계정');
    });
  });
}
