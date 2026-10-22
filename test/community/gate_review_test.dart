// Gate review fixes (mobile-review 1, 4, 5, 7, 8, 16 + low items): a revoked account can log in
// again and reach the consent screen, Client mode is not locked by an unreachable PC, upgrade
// seeding of the 72-hour grace, and the background withdrawal retry back-off.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/consent_history.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
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

  Map<String, Object?> status({
    String consent = 'active',
    String contributor = 'active',
    bool? kakao = true,
    List<String> reasons = const [],
    bool omitGate = false,
  }) {
    final s = statusJson(consentState: consent, contributor: contributor);
    if (omitGate) {
      s.remove('gate');
    } else {
      s['gate'] = {
        'kakao': ?kakao,
        'consent': true,
        'can_enter': true,
        'reasons': reasons,
      };
    }
    return s;
  }

  Future<Map<String, Object?>?> history() =>
      ConsentHistory(store).latest('fp-32hex');

  group('revoked account can come back (no endless reset)', () {
    test(
      're-login after a server-confirmed revoke reaches the consent screen, then consent works',
      () async {
        var current = status();
        final gate = makeGate(FakeAccountServer(status: () => current));
        expect((await gate.refreshNow()).canEnter, isTrue);
        expect((await history())!['last_g1'], isNotNull);

        current = status(consent: 'revoked');
        gate.invalidate('poll');
        final reset = await gate.refreshNow();
        expect(reset.state, 'kakao_required');
        expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
        expect(
          (await history())!['last_g1'],
          isNull,
          reason: '리셋은 G1 근거를 소모한다',
        );

        // Same account logs in again; the server still says revoked.
        auth.setPhase(CommunityAccountPhase.connected);
        // 로그인 알림이 시작한 확인이 끝날 때까지(고정 100ms 는 부하가 큰 전체 실행에서 모자랐다 — 2026-10-22).
        for (var i = 0; i < 100 && gate.state.state != 'consent_required'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        // 그 확인의 남은 정리(context 끄기)까지 끝난 뒤 본다(진행 중이면 합류, 아니면 같은 결과로 한 번 더).
        await gate.refreshNow();
        expect(gate.state.state, 'consent_required', reason: '동의 화면(G4)');
        expect(
          auth.state.value.phase,
          CommunityAccountPhase.connected,
          reason: '다시 로그아웃(리셋)되지 않는다',
        );
        // And again: still the consent screen, never a second reset.
        gate.invalidate('poll');
        expect((await gate.refreshNow()).state, 'consent_required');
        expect(auth.state.value.phase, CommunityAccountPhase.connected);

        // Re-consent: the server shows a fresh active grant.
        await gate.recordConsentAccepted();
        current = status();
        gate.invalidate('poll');
        expect((await gate.refreshNow()).canEnter, isTrue);
        expect((await history())!['last_g1'], isNotNull);
      },
    );

    test('contributor none after a reset is also the consent screen', () async {
      var current = status();
      final gate = makeGate(FakeAccountServer(status: () => current));
      await gate.refreshNow();
      current = status(contributor: 'none');
      gate.invalidate('poll');
      expect((await gate.refreshNow()).state, 'kakao_required');
      auth.setPhase(CommunityAccountPhase.connected);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate.invalidate('poll');
      await gate.refreshNow();
      expect(auth.state.value.phase, CommunityAccountPhase.connected);
      expect(gate.canEnter, isFalse);
    });

    test(
      'a new device (no G1 evidence) with a revoked account sees the consent screen at once',
      () async {
        final gate = makeGate(
          FakeAccountServer(status: () => status(consent: 'revoked')),
        );
        expect((await gate.refreshNow()).state, 'consent_required');
        expect(auth.state.value.phase, CommunityAccountPhase.connected);
      },
    );
  });

  group('G7 and G9 precedence', () {
    test('only kakao:false WITH reason kakao_missing resets', () async {
      var current = status();
      final gate = makeGate(FakeAccountServer(status: () => current));
      await gate.refreshNow();
      // session_missing / user_not_eligible are not a lost Kakao connection.
      current = status(kakao: false, reasons: ['session_missing']);
      gate.invalidate('poll');
      await gate.refreshNow();
      expect(auth.state.value.phase, CommunityAccountPhase.connected);
      expect(gate.canEnter, isFalse);
      current = status(kakao: false, reasons: ['user_not_eligible']);
      gate.invalidate('poll');
      await gate.refreshNow();
      expect(auth.state.value.phase, CommunityAccountPhase.connected);
      current = status(kakao: false, reasons: ['kakao_missing']);
      gate.invalidate('poll');
      expect((await gate.refreshNow()).state, 'kakao_required');
      expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
    });

    test(
      'a malformed identity block is "cannot verify", not a reset and not an opening',
      () async {
        var current = status();
        final gate = makeGate(FakeAccountServer(status: () => current));
        await gate.refreshNow();
        current = status(omitGate: true);
        gate.invalidate('poll');
        await gate.refreshNow();
        expect(auth.state.value.phase, CommunityAccountPhase.connected);
        expect(gate.canEnter, isFalse);
        current = status(kakao: null);
        gate.invalidate('poll');
        await gate.refreshNow();
        expect(auth.state.value.phase, CommunityAccountPhase.connected);
        expect(gate.canEnter, isFalse);
      },
    );

    test(
      'suspension together with a revoke is G9 (suspended), not a reset',
      () async {
        var current = status();
        final gate = makeGate(FakeAccountServer(status: () => current));
        await gate.refreshNow();
        current = status(consent: 'revoked', contributor: 'suspended');
        gate.invalidate('poll');
        await gate.refreshNow();
        expect(auth.state.value.phase, CommunityAccountPhase.connected);
        expect(gate.state.state, isNot('kakao_required'));
        expect(
          (await history())!['last_g1'],
          isNotNull,
          reason: '리셋하지 않았으므로 근거 유지',
        );
      },
    );
  });

  group('Client mode and the PC', () {
    test(
      'an unreachable PC is not a lock: the Client keeps working and shows "waiting"',
      () async {
        final gate = makeGate(
          FakeAccountServer(status: () => status()),
          mode: 'server',
          serverGate: () async =>
              CommunityGateLinkResult.failure(code: 'offline', offline: true),
        );
        final result = await gate.refreshNow();
        expect(result.canEnter, isTrue);
        expect(gate.clientServerCheckPending, isTrue);
        expect(gate.state.state, isNot('server_consent_required'));
      },
    );

    test(
      'a 5xx or malformed answer from the PC is not a refusal either',
      () async {
        for (final answer in <CommunityGateLinkResult>[
          CommunityGateLinkResult.failure(code: 'http_500', httpStatus: 500),
          CommunityGateLinkResult.success({'state': 'x'}),
        ]) {
          final gate = makeGate(
            FakeAccountServer(status: () => status()),
            mode: 'server',
            serverGate: () async => answer,
          );
          expect((await gate.refreshNow()).canEnter, isTrue);
        }
      },
    );

    test(
      'only an explicit can_local=false (or onboarding required) locks',
      () async {
        final gate = makeGate(
          FakeAccountServer(status: () => status()),
          mode: 'server',
          serverGate: () async => CommunityGateLinkResult.success({
            'can_local': false,
            'can_enter': false,
          }),
        );
        await gate.refreshNow();
        expect(gate.state.state, 'server_consent_required');
        expect(gate.canEnter, isFalse);
        final onboarding = makeGate(
          FakeAccountServer(status: () => status()),
          mode: 'server',
          serverGate: () async => CommunityGateLinkResult.failure(
            code: 'COMMUNITY_ONBOARDING_REQUIRED',
            httpStatus: 403,
          ),
        );
        await onboarding.refreshNow();
        expect(onboarding.state.state, 'server_consent_required');
      },
    );

    test(
      'the phone\'s own revoked consent is not described as the PC\'s',
      () async {
        var current = status();
        final gate = makeGate(
          FakeAccountServer(status: () => current),
          mode: 'server',
        );
        await gate.refreshNow();
        current = status(consent: 'revoked');
        gate.invalidate('poll');
        await gate.refreshNow();
        expect(gate.state.state, 'consent_required');
        expect(gate.notice, isNot(contains('서버 동의 필요')));
        expect((await history())!['last_g1'], isNull);
      },
    );
  });

  group('72-hour grace seeded on upgrade', () {
    test(
      'an existing user whose first status check fails offline is not locked',
      () async {
        // History written by the previous app version: no last_g1, only the verified ok transition.
        await ConsentHistory(store).storage.write(
          key: ConsentHistory.key('fp-32hex'),
          value: jsonEncode({
            'result': 'ok',
            'consent_state': 'active',
            'grant_id': 'grant-1',
            'local_revoke': false,
            'suspended': false,
            'transitions': [
              {
                'state': 'ok',
                'consent_state': 'active',
                'source': 'server-status',
                'at': DateTime.now()
                    .toUtc()
                    .subtract(const Duration(hours: 5))
                    .toIso8601String(),
                'grant_id': 'grant-1',
              },
            ],
          }),
        );
        final server = FakeAccountServer(status: () => status())
          ..statusFailures = 5;
        final gate = makeGate(server);
        final first = await gate.refreshNow();
        expect(first.canEnter, isFalse);
        expect(
          gate.canBrowse,
          isTrue,
          reason: '이관된 last_g1 로 72시간 안에는 로컬 사용 허용',
        );
        expect((await history())!['last_g1'], isNotNull);
      },
    );

    test('the seed uses the first run (now), not the old transition time, and happens once', () async {
      await ConsentHistory(store).storage.write(
        key: ConsentHistory.key('fp-32hex'),
        value: jsonEncode({
          'result': 'ok',
          'consent_state': 'active',
          'transitions': [
            {
              'state': 'ok',
              'at': DateTime.now().toUtc().subtract(const Duration(days: 90)).toIso8601String(),
            },
          ],
        }),
      );
      final server = FakeAccountServer(status: () => status())..statusFailures = 5;
      final gate = makeGate(server);
      await gate.refreshNow();
      expect(gate.canBrowse, isTrue, reason: '오래된 사용자도 업그레이드 직후 오프라인에서 잠기지 않는다');
      final h = (await history())!;
      final at = (h['last_g1'] as Map)['at'] as int;
      expect(DateTime.now().toUtc().millisecondsSinceEpoch - at, lessThan(60000));
      expect(h['g1_seeded'], true);
      // After a reset the evidence is gone and is never seeded again.
      await ConsentHistory(store).clearG1('fp-32hex');
      final after = (await history())!;
      expect(after['last_g1'], isNull);
      expect(after['reset_completed_at'], isNotNull);
      expect(await ConsentHistory(store).seedLastG1('fp-32hex', '910001', null), isNull);
    });

    test('a history whose newest result is not active is not seeded', () async {
      for (final consent in ['revoked', 'outdated', 'none']) {
        await ConsentHistory(store).storage.write(
          key: ConsentHistory.key('fp-32hex'),
          value: jsonEncode({'result': 'consent_required', 'consent_state': consent, 'transitions': []}),
        );
        expect(await ConsentHistory(store).seedLastG1('fp-32hex', '910001', null), isNull);
      }
    });

    test('a user who never passed G1 is not seeded', () async {
      final server = FakeAccountServer(status: () => status())
        ..statusFailures = 5;
      final gate = makeGate(server);
      await gate.refreshNow();
      expect(gate.canBrowse, isFalse);
    });
  });

  group('withdrawal retry', () {
    test('back-off doubles from 60s and stops at 30 minutes', () {
      expect(
        [for (var a = 1; a <= 8; a++) CommunityReset.backoffSeconds(a)],
        [60, 120, 240, 480, 960, 1800, 1800, 1800],
      );
    });

    test(
      'a background run before the next attempt time does not call the server',
      () async {
        var calls = 0;
        final client = CommunityAccountClient(
          supabaseUrl: testAuthConfig().supabaseUrl,
          publishableKey: 'synthetic',
          client: MockClient((_) async {
            calls++;
            return http.Response(
              '{"error":{"code":"busy","retryable":true}}',
              503,
            );
          }),
        );
        await CommunityReset.begin(store, 'g', auth: auth, client: client);
        expect(
          await CommunityReset.attempt(
            store,
            auth: auth,
            client: client,
            force: true,
          ),
          isFalse,
        );
        expect(calls, 1);
        final pending = (await CommunityReset.pending(store))!;
        expect(pending['attempts'], 1);
        final wait =
            (pending['next_attempt_at'] as num) -
            DateTime.now().millisecondsSinceEpoch / 1000;
        expect(wait, greaterThan(50));
        expect(wait, lessThanOrEqualTo(61));
        // The WorkManager task wakes early: it must honour the stored back-off.
        expect(
          await CommunityReset.attempt(
            store,
            auth: auth,
            client: client,
            fromWorker: true,
          ),
          isFalse,
        );
        expect(calls, 1, reason: '백오프 중에는 요청하지 않는다');
        // A failed attempt from the worker doubles the delay.
        await store.setMeta(
          'revoke_pending',
          jsonEncode({...pending, 'next_attempt_at': 0}),
        );
        await CommunityReset.attempt(
          store,
          auth: auth,
          client: client,
          fromWorker: true,
        );
        expect(calls, 2);
        final second = (await CommunityReset.pending(store))!;
        expect(second['attempts'], 2);
        final wait2 =
            (second['next_attempt_at'] as num) -
            DateTime.now().millisecondsSinceEpoch / 1000;
        expect(wait2, greaterThan(110));
      },
    );

    test('a Kakao login while the withdrawal is pending finishes it', () async {
      var accept = false;
      final client = CommunityAccountClient(
        supabaseUrl: testAuthConfig().supabaseUrl,
        publishableKey: 'synthetic',
        client: MockClient((req) async {
          if (!accept) {
            return http.Response(
              '{"error":{"code":"busy","retryable":true}}',
              503,
            );
          }
          return http.Response(
            '{"protocol":1,"grant_id":"g","revoked":true,"already_revoked":false,"lineage_active":false}',
            200,
          );
        }),
      );
      makeGate(FakeAccountServer(status: () => status()));
      await CommunityReset.begin(store, 'g', auth: auth, client: client);
      await CommunityReset.attempt(
        store,
        auth: auth,
        client: client,
        force: true,
      );
      expect(await CommunityReset.pending(store), isNotNull);
      // The Kakao session is gone, then the user logs in again; the server now accepts.
      auth.setPhase(CommunityAccountPhase.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      accept = true;
      auth.setPhase(CommunityAccountPhase.connected);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        await CommunityReset.pending(store),
        isNull,
        reason: '로그인 성공으로 철회 완료',
      );
    });
  });
}
