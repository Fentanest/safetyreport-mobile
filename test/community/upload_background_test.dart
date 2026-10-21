// 백그라운드·앱 업로드 제어 (요청서 §12-B): 헤드리스 게이트 재확인, 캐시 무효화 공유, WorkManager 결과, 데모·Client 가드,
// 앱 제어기의 깨우기(실행 중 알림 보존)·재시도 타이머.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'fake_account.dart' show pcGateOk;
import 'package:safetyreport/services/sync_operation_admission.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/consent_history.dart';
import 'package:safetyreport/community/gate/gate_state.dart'
    show datasetKeyForOfficialId;
import 'package:safetyreport/community/cloud_availability.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/community/upload/community_schedule.dart';
import 'package:safetyreport/community/upload/community_uploader.dart';
import 'package:safetyreport/community/upload/upload_background.dart';
import 'package:safetyreport/community/upload/upload_controller.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/community_auth_config.dart';

const connectionId = '11111111-2222-4333-8444-555555555555';

Map<String, Object?> status({
  String consent = 'active',
  Map<String, Object?>? connection,
  bool bound = true,
}) => {
  'protocol': 1,
  'gate': {'kakao': true},
  'policy': {'required_version': '2026-09-28.1', 'consent_text_sha256': 'abc'},
  'consent': {
    'state': consent,
    'grant_id': 'grant-1',
    'policy_version': '2026-09-28.1',
    'consent_text_sha256': 'abc',
  },
  'contributor': {'status': 'active'},
  'connection':
      connection ??
      {
        'connection_id': connectionId,
        'status': 'active',
        'bound_to_current_session': bound,
      },
  'account': {'fingerprint': 'fp1', 'display_name': '테스터'},
};

class Tokens implements CommunityTokenSource {
  Tokens(this.result);
  CommunityTokenResult result;
  @override
  Future<CommunityTokenResult> getAccessTokenResult({String? rejected}) async =>
      result;
}

class CountingUploader extends CommunityUploader {
  CountingUploader(this.onRun)
    : super(
        gate: CacheGateCheck(),
        tokens: Tokens(
          const CommunityTokenResult(CommunityTokenStatus.ok, 't'),
        ),
        appMode: () async => AppMode.standalone,
        supabaseUrl: 'https://example.supabase.co',
        publishableKey: 'k',
        clientVersion: '1',
      );
  final Future<UploadRunResult> Function(String trigger) onRun;
  DateTime? due;
  @override
  Future<UploadRunResult> requestCommunityUpload(String trigger) =>
      onRun(trigger);
  @override
  Future<DateTime?> nextDueAt() async => due;
}

void main() {
  sqfliteFfiInit();
  final config = CommunityAuthConfig.validate(
    url: 'https://proj.supabase.test',
    key: 'sb_publishable_test',
  );
  late CommunityStore store;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.baseUrl: 'https://pc.invalid',
      AppPrefsKeys.apiKey: 'synthetic',
    });
    FlutterSecureStorage.setMockInitialValues({
      'community_connection_v1': jsonEncode({
        'connection_id': connectionId,
        'dataset_key': 'ds1',
        'writer_epoch': 1,
      }),
    });
    dir = await Directory.systemTemp.createTemp('sr_bg_');
    store = await CommunityStore.open(
      path: '${dir.path}/community.db',
      factory: databaseFactoryFfi,
    );
    await store.setContext({
      'contributor_fingerprint': 'fp1',
      'connection_id': connectionId,
      'writer_epoch': 1,
      'dataset_key': 'ds1',
      'consent_grant_id': 'grant-1',
      'policy_version': '2026-09-28.1',
      'consent_text_sha256': 'abc',
      'source_app': 'safetyreport-mobile',
      'source_mode': 'standalone',
    });
  });
  tearDown(() async {
    await CommunityStore.closeForTest(store.path);
    await dir.delete(recursive: true);
  });

  CommunityAccountClient client(Object Function() reply) =>
      CommunityAccountClient(
        supabaseUrl: config.supabaseUrl,
        publishableKey: config.publishableKey,
        client: MockClient((req) async {
          final r = reply();
          if (r is Exception) throw r;
          final (code, body) = r as (int, Map<String, Object?>);
          return http.Response.bytes(utf8.encode(jsonEncode(body)), code);
        }),
      );

  Future<Map<String, Object?>?> cache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('community_gate_cache_v1');
    return raw == null ? null : jsonDecode(raw) as Map<String, Object?>;
  }

  group('headless gate refresh (stale cache in the background)', () {
    test('late status after reset cannot restore writer or ok cache', () async {
      final reply = Completer<http.Response>();
      final called = Completer<void>();
      final accountClient = CommunityAccountClient(
        supabaseUrl: config.supabaseUrl,
        publishableKey: config.publishableKey,
        client: MockClient((_) {
          called.complete();
          return reply.future;
        }),
      );
      final result = refreshGateHeadless(
        store,
        config: config,
        tokens: Tokens(
          const CommunityTokenResult(CommunityTokenStatus.ok, 'synthetic'),
        ),
        client: accountClient,
      );
      await called.future;
      await SyncOperationAdmission.cancelAll(store);
      await store.deactivateContext('reset');
      reply.complete(
        http.Response.bytes(utf8.encode(jsonEncode(status())), 200),
      );
      await expectLater(result, throwsStateError);
      expect(await store.activeContext(), isNull);
      expect(await cache(), isNull);
    });
    test('Client refreshes stale gate without a Standalone writer', () async {
      await store.deactivateContext('client_mode');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'community_gate_cache_v1',
        jsonEncode({'state': 'ok', 'owner': 'fp1', 'verified_at': 1}),
      );
      final result = await refreshGateHeadless(
        store,
        config: config,
        tokens: Tokens(
          const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
        ),
        client: client(() => (200, status(bound: false))),
        clientMode: true,
        serverGate: pcGateOk,
        expectedOwner: 'fp1',
      );
      expect(result, HeadlessGate.ok);
      expect(await store.activeContext(), isNull);
      expect((await cache())!['verified_at'], greaterThan(1));
    });

    test(
      'Client refuses a different owner and scope changes during refresh',
      () async {
        final tokens = Tokens(
          const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
        );
        expect(
          await refreshGateHeadless(
            store,
            config: config,
            tokens: tokens,
            client: client(() => (200, status())),
            clientMode: true,
            serverGate: pcGateOk,
            expectedOwner: 'another-owner',
          ),
          HeadlessGate.needsForeground,
        );
        expect(await cache(), isNull);
        await expectLater(
          refreshGateHeadless(
            store,
            config: config,
            tokens: tokens,
            client: client(() => (200, status())),
            clientMode: true,
            serverGate: pcGateOk,
            validateScope: () async => throw StateError('scope changed'),
          ),
          throwsStateError,
        );
        expect(await cache(), isNull);
      },
    );

    test('Client consent refusal stays blocked', () async {
      expect(
        await refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
          ),
          client: client(() => (200, status(consent: 'revoked'))),
          clientMode: true,
          serverGate: pcGateOk,
          expectedOwner: 'fp1',
        ),
        HeadlessGate.blocked,
      );
      expect((await cache())!['state'], isNot('ok'));
    });

    test(
      'markG1 stores the dataset of the LOCAL official id and a missing id never erases it',
      () async {
        SharedPreferences.setMockInitialValues({
          AppPrefsKeys.baseUrl: 'https://pc.invalid',
          AppPrefsKeys.apiKey: 'synthetic',
          AppPrefsKeys.standaloneUsername: 'User@Example.com',
        });
        Future<HeadlessGate> run() => refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
          ),
          client: client(() => (200, status())),
          sessionMember: () async => '910001',
        );
        expect(await run(), HeadlessGate.ok);
        final expected = datasetKeyForOfficialId('User@Example.com');
        var history = await ConsentHistory(store).latest('fp1');
        expect((history!['last_g1'] as Map)['dataset'], expected);
        expect((history['last_g1'] as Map)['member'], '910001');
        // The id is gone (e.g. prefs cleared): the known dataset is kept, never overwritten with null.
        SharedPreferences.setMockInitialValues({
          AppPrefsKeys.baseUrl: 'https://pc.invalid',
          AppPrefsKeys.apiKey: 'synthetic',
        });
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(await run(), HeadlessGate.ok);
        history = await ConsentHistory(store).latest('fp1');
        expect((history!['last_g1'] as Map)['dataset'], isNotNull);
      },
    );

    test(
      'suspension is judged before a reset, and a reset needs prior G1 evidence',
      () async {
        Map<String, Object?> revokedAndSuspended() => {
          ...status(consent: 'revoked'),
          'contributor': {'status': 'suspended'},
        };
        // No G1 evidence on this device: revoked is the consent screen (G4), never a reset.
        final first = await refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
          ),
          client: client(() => (200, status(consent: 'revoked'))),
          sessionMember: () async => '910001',
        );
        expect(first, HeadlessGate.blocked);
        expect((await cache())!['state'], 'consent_required');
        // With evidence and suspension together, suspension wins (no reset: the context stays recorded).
        await ConsentHistory(store).markG1('fp1', '910001', 'ds1');
        final second = await refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
          ),
          client: client(() => (200, revokedAndSuspended())),
          sessionMember: () async => '910001',
        );
        expect(second, HeadlessGate.blocked);
        expect((await cache())!['state'], isNot('kakao_required'));
        expect(
          (await ConsentHistory(store).latest('fp1'))!['last_g1'],
          isNotNull,
        );
      },
    );

    test(
      'ok: same judgement as the app gate + bound active connection matching the context → cache refreshed',
      () async {
        final r = await refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
          ),
          client: client(() => (200, status())),
        );
        expect(r, HeadlessGate.ok);
        expect((await cache())!['state'], 'ok');
        final prefs = await SharedPreferences.getInstance();
        expect(await isGateCacheFresh(prefs, DateTime.now()), isTrue);
      },
    );

    test(
      'inactive context waits through shared cooldown then restores after fresh status',
      () async {
        var time = DateTime.utc(2026, 10, 7);
        var calls = 0;
        await store.deactivateContext('cloud_unavailable');
        CloudAvailability.shared = CloudAvailability(
          store,
          config.supabaseUrl,
          now: () => time,
        );
        addTearDown(() => CloudAvailability.shared = null);
        await CloudAvailability.shared!.failed(retryAfterSeconds: 900);
        final mock = client(() {
          calls++;
          return (200, status());
        });
        final tokens = Tokens(
          const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
        );
        expect(
          await refreshGateHeadless(
            store,
            config: config,
            tokens: tokens,
            client: mock,
          ),
          HeadlessGate.transient,
        );
        expect(calls, 0);
        time = time.add(const Duration(seconds: 901));
        expect(
          await refreshGateHeadless(
            store,
            config: config,
            tokens: tokens,
            client: mock,
          ),
          HeadlessGate.ok,
        );
        expect(calls, 1);
        expect(await store.activeContext(), isNotNull);
      },
    );

    test(
      'transient: token or status network failure keeps everything as it was',
      () async {
        for (final (tokens, reply) in [
          (
            Tokens(
              const CommunityTokenResult(
                CommunityTokenStatus.temporarilyUnavailable,
              ),
            ),
            () => (200, status()),
          ),
          (
            Tokens(const CommunityTokenResult(CommunityTokenStatus.ok, 'acc')),
            () => const SocketException('down'),
          ),
          (
            Tokens(const CommunityTokenResult(CommunityTokenStatus.ok, 'acc')),
            () => (
              503,
              <String, Object?>{
                'error': {'code': 'busy', 'message': 'm'},
              },
            ),
          ),
        ]) {
          final r = await refreshGateHeadless(
            store,
            config: config,
            tokens: tokens,
            client: client(reply),
          );
          expect(r, HeadlessGate.transient);
          expect(await cache(), isNull);
          expect(await store.activeContext(), isNotNull);
        }
      },
    );

    test(
      'explicit refusal (consent revoked · re-login needed) is recorded and the context is turned off',
      () async {
        final r = await refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
          ),
          client: client(() => (200, status(consent: 'revoked'))),
        );
        expect(r, HeadlessGate.blocked);
        expect((await cache())!['state'], 'consent_required');
        expect(await store.activeContext(), isNull);
        await store.setContext({
          ...?(await store.context())
            ?..remove('id')
            ..remove('state')
            ..remove('verified_at')
            ..remove('inactive_reason'),
        });
        final r2 = await refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.reauthRequired),
          ),
        );
        expect(r2, HeadlessGate.blocked);
        expect((await cache())!['state'], 'kakao_reauth_required');
      },
    );

    test(
      'a connection that needs rebind is left for the foreground gate (no writes in the background)',
      () async {
        final r = await refreshGateHeadless(
          store,
          config: config,
          tokens: Tokens(
            const CommunityTokenResult(CommunityTokenStatus.ok, 'acc'),
          ),
          client: client(() => (200, status(bound: false))),
        );
        expect(r, HeadlessGate.needsForeground);
        expect(await cache(), isNull);
        expect(await store.activeContext(), isNotNull);
      },
    );
  });

  test('cache gate invalidation is written for other isolates', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'community_gate_cache_v1',
      jsonEncode({
        'state': 'ok',
        'verified_at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    final gate = CacheGateCheck();
    expect(await gate.requireFresh(), isTrue);
    gate.invalidate('consent_revoked');
    await pumpEventQueue();
    expect(await gate.requireFresh(), isFalse);
    expect(gate.blockedState, 'invalidated:consent_revoked');
  });

  group('WorkManager task', () {
    test('Client and demo modes do nothing and report success', () async {
      for (final prefs in [
        {AppPrefsKeys.appMode: AppMode.server.name},
        {
          AppPrefsKeys.appMode: AppMode.standalone.name,
          AppPrefsKeys.standaloneDemoMode: true,
        },
      ]) {
        SharedPreferences.setMockInitialValues(prefs);
        expect(await runCommunityUploadTask(communityPeriodicTaskName), isTrue);
      }
    });

    test(
      'an unexpected failure before saving state asks the OS to retry',
      () async {
        SharedPreferences.setMockInitialValues({
          AppPrefsKeys.appMode: AppMode.standalone.name,
          AppPrefsKeys.secureStorageV10Migrated: true,
        });
        // 플러그인 없는 테스트 환경: 기본 경로의 community.db 를 열 수 없다 → 저장 전 실패
        expect(
          await runCommunityUploadTask(communityMidnightTaskName),
          isFalse,
        );
      },
    );
  });

  test(
    'the hourly task runs recovery even when the midnight key is held by another run',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: AppMode.standalone.name,
        AppPrefsKeys.secureStorageV10Migrated:
            true, // 포그라운드 앱이 보안 저장소 이관을 끝낸 설치본
        'community_gate_cache_v1': jsonEncode({
          'state': 'ok',
          'verified_at': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      final now = DateTime.now().toUtc();
      // 다른 실행이 오늘 자정 key 를 잡고 있다(유효 lease) → catchUp 은 deferred
      await store.db.insert('schedule_runs', {
        'project_namespace': projectNamespace(
          CommunityAuthConfig.fromEnvironment.supabaseUrl,
        ),
        'contributor_fingerprint': 'fp1',
        'local_dataset_id': await store.localDatasetId(),
        'writer_epoch': 1,
        'schedule_key': dueKey(now),
        'scheduled_date_kst': dueKey(now).substring(9),
        'due_at_utc': isoUtc(dueAtUtc(dueKey(now))),
        'state': 'running',
        'attempts': 1,
        'lease_owner': 'scheduler:os:other',
        'lease_until': isoUtc(now.add(const Duration(minutes: 5))),
      });
      final triggers = <String>[];
      final ok = await runCommunityUploadTask(
        communityPeriodicTaskName,
        now: now,
        openStore: () async => store,
        verifyGate: (s, p) async => HeadlessGate.ok,
        upload: (t) async {
          triggers.add(t);
          return UploadRunResult(runId: 'r', result: 'sent');
        },
        recoveryCheck: (s, {now}) async => true,
      );
      expect(ok, isTrue);
      expect(triggers, ['recovery'], reason: '자정은 다른 실행 몫(deferred), 복구는 따로');
    },
  );

  test(
    'a background 403 invalidation is written before the task ends',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'community_gate_cache_v1',
        jsonEncode({
          'state': 'ok',
          'verified_at': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      final gate = CacheGateCheck();
      gate.invalidate('consent_revoked');
      await gate.flush();
      expect(
        jsonDecode(prefs.getString('community_gate_cache_v1')!)['state'],
        'invalidated:consent_revoked',
      );
    },
  );

  group('app upload controller', () {
    test(
      'a wake that arrives during a run is not lost; triggers merge to the wider one',
      () async {
        final triggers = <String>[];
        final release = Completer<void>();
        late CommunityUploadController controller;
        final uploader = CountingUploader((trigger) async {
          triggers.add(trigger);
          if (triggers.length == 1) await release.future;
          return UploadRunResult(runId: 'r', result: 'sent');
        });
        controller = CommunityUploadController();
        controller.start(() async => uploader); // recovery
        await pumpEventQueue();
        controller.wake(); // realtime while running
        controller.wake('manual');
        controller.wake();
        release.complete();
        await controller.idle();
        expect(triggers, ['recovery', 'manual']);
        controller.stop();
      },
    );

    test(
      'schedules the next retry; waits nothing for auth/consent/gate; continues right away after more_pending',
      () async {
        final now = DateTime.utc(2026, 9, 27);
        final controller = CommunityUploadController(now: () => now);
        var result = 'cooldown';
        final uploader = CountingUploader(
          (t) async => UploadRunResult(runId: 'r', result: result),
        );
        uploader.due = now.add(const Duration(minutes: 3));
        controller.start(() async => uploader);
        await controller.idle();
        expect(controller.scheduledAt, now.add(const Duration(minutes: 3)));
        for (final r in ['needs_auth', 'needs_consent', 'blocked_gate']) {
          result = r;
          controller.wake();
          await controller.idle();
          expect(controller.scheduledAt, isNull, reason: r);
        }
        result = 'more_pending';
        controller.wake();
        await controller.idle();
        expect(controller.scheduledAt, now.add(minRequestInterval));
        result = 'busy_other_run';
        controller.wake();
        await controller.idle();
        expect(controller.scheduledAt, now.add(const Duration(seconds: 5)));
        controller.stop();
        expect(controller.scheduledAt, isNull);
        controller.wake();
        await controller.idle();
        expect(controller.scheduledAt, isNull, reason: '멈춘 뒤에는 깨우지 않는다');
      },
    );
  });
}
