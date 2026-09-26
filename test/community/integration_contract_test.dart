// 통합 검수(2026-09-26)에서 추가: 병렬 작업 사이에 비어 있던 계약 검사.
// - observations.json 의 event_decisions 10건(T6 는 파일이 없다고 보고 — 실제로는 observations.json 안에 있다)
// - manifest 요청·응답 계약(POST 본문, 형식 검증, total·중복·dataset/epoch·토큰 규칙) — PC 와 같은 규칙
// - 게이트: writer 충돌·공식 계정 없음이면 업로드 context 를 켜지 않고, 연결 비밀은 암호학적 난수
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/capture/canonical_json.dart';
import 'package:safetyreport/community/capture/capture_retry_store.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/server_completed.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/upload/community_ingest_client.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_account.dart';

Map<String, Object?> _vectors() =>
    jsonDecode(File('contracts/community-ingest/vectors/observations.json').readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> page(List<String> keys,
        {String token = '7', int? total, String? next, String dataset = 'd', int epoch = 1}) =>
    {
      'protocol': 1,
      'dataset_key': dataset,
      'writer_epoch': epoch,
      'total': total ?? keys.length,
      'manifest_token': token,
      'key_prefixes': keys,
      'next_after': next,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('event_decisions vectors (observations.json)', () {
    final v = _vectors();
    final cases = {
      for (final c in (v['cases'] as List).cast<Map<String, Object?>>()) c['name'] as String: c,
    };
    for (final d in (v['event_decisions'] as List).cast<Map<String, Object?>>()) {
      test(d['name'] as String, () {
        final obs = cases[d['observation']]!;
        final payload = obs['expected_payload'] as Map<String, Object?>;
        final sha = sha256.convert(utf8.encode(canonicalJson(payload))).toString();
        final prev = d['prev'] as Map<String, Object?>?;
        expect(
          decideEvent(
            eligible: obs['eligible'] as bool,
            prevSha: prev?['payload_sha256'] as String?,
            prevEligible: prev?['eligible'] as bool?,
            payloadSha: sha,
            serverCompletedHit: d['server_completed'] == true,
          ),
          d['expect'],
        );
      });
    }
  });

  group('manifest contract', () {
    late Directory tmp;
    late String dbPath;
    late CommunityStore store;
    final k = [for (final c in 'abcdef'.split('')) c * 24];
    final cursor = 'e' * 64;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('manifest_contract');
      dbPath = '${tmp.path}/community.db';
      store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
    });
    tearDown(() async {
      await CommunityStore.closeForTest(dbPath);
      await tmp.delete(recursive: true);
    });

    Future<List<String>> rows() async => [
          for (final r in await store.db.rawQuery('SELECT key_prefix FROM server_completed ORDER BY key_prefix'))
            r['key_prefix'] as String
        ];

    Future<bool> run(List<Map<String, Object?>> pages) {
      var i = 0;
      return refreshServerCompleted(
        datasetKey: 'd',
        writerEpoch: 1,
        store: store,
        fetchPage: (after, limit) async => i < pages.length ? ManifestPage.fromJson(pages[i++]) : null,
      );
    }

    test('replaces only when every rule holds; failures keep the old list', () async {
      expect(await run([page(k.sublist(0, 2), total: 3, next: cursor), page([k[2]], total: 3)]), isTrue);
      expect(await rows(), k.sublist(0, 3));
      expect(await store.meta('manifest_scope'), 'd:1');
      for (final bad in [
        [page([k[4]], total: 2)],
        [page([k[4], k[4]])],
        [page([k[4]], dataset: 'other')],
        [page([k[4]], epoch: 2)],
        [
          page([k[4]], token: '7', next: cursor), page([k[5]], token: '8'),
          page([k[4]], token: '9', next: cursor), page([k[5]], token: '10'),
          page([k[4]], token: '11', next: cursor), page([k[5]], token: '12'),
        ],
      ]) {
        expect(await run(bad), isFalse, reason: '$bad');
        expect(await rows(), k.sublist(0, 3));
      }
      expect(await run([page([k[0]], token: '7', total: 2, next: cursor), page([k[1]], token: '8', total: 2), page([k[5]], token: '9')]),
          isTrue, reason: '토큰이 바뀌면 처음부터 다시');
      expect(await rows(), [k[5]]);
      expect(await run([page([], token: '0')]), isTrue);
      expect(await rows(), isEmpty);
    });

    test('client POSTs the contract body and rejects malformed pages', () async {
      late Map<String, Object?> sent;
      late String method;
      Map<String, Object?> reply = page([k[0]]);
      final client = CommunityIngestClient(
        supabaseUrl: 'http://127.0.0.1:56321',
        publishableKey: 'sb_publishable_x',
        httpClient: MockClient((req) async {
          method = req.method;
          sent = jsonDecode(req.body) as Map<String, Object?>;
          return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200);
        }),
      );
      final ok = await client.fetchManifestPage('tok', 'conn-1', limit: 9000);
      expect(ok, isNotNull);
      expect(method, 'POST');
      expect(sent, {'protocol': 1, 'connection_id': 'conn-1', 'after': null, 'limit': 5000});
      for (final broken in [
        {...page([k[0]]), 'key_prefixes': ['zz']},
        {...page([k[0]]), 'manifest_token': 'x'},
        {...page([k[0]]), 'next_after': 'short'},
        {...page([k[0]]), 'total': -1},
        {'keys': [k[0]]},
      ]) {
        reply = broken;
        expect(await client.fetchManifestPage('tok', 'conn-1'), isNull, reason: '$broken');
      }
    });
  });

  group('sync fail-closed (Sol H-01)', () {
    for (final active in [false, true]) {
      test('no community store (captureActive=$active) → CaptureStoreUnavailable before any personal save', () async {
        final retry = File('${Directory.systemTemp.path}/retry-${DateTime.now().microsecondsSinceEpoch}.json');
        await expectLater(
          SyncEngine.captureAndSaveDetail(
            cNo: 'R1', item: const {}, detail: const {}, trigger: 'realtime', tracker: CaptureTracker(),
            communityStore: null, retryFile: retry, projectNamespace: 'ns', captureActive: active,
          ),
          throwsA(isA<CaptureStoreUnavailable>()),
        );
        expect(retry.existsSync(), isFalse, reason: '개인 저장 경로에 들어가지 않았다');
      });
    }
  });

  group('gate writer rules', () {
    late Directory tmp;
    late String dbPath;
    late CommunityStore store;
    late StubAuthService auth;

    setUp(() async {
      setUpSecureStorage();
      tmp = await Directory.systemTemp.createTemp('gate_writer_rules');
      dbPath = '${tmp.path}/community.db';
      store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
      auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    });
    tearDown(() async {
      await CommunityStore.closeForTest(dbPath);
      await tmp.delete(recursive: true);
    });

    CommunityGate gateWith(FakeAccountServer server, {Future<String?> Function()? official}) {
      final g = CommunityGate(
        config: testAuthConfig(),
        auth: auth,
        store: store,
        accountClient: server.accountClient(),
        configStatus: () => 'ok',
        appMode: () => 'standalone',
        officialAccountId: official ?? () async => 'User@Example.com',
      );
      addTearDown(g.dispose);
      return g;
    }

    test('writer conflict: entry allowed, upload context off, other device shown', () async {
      final server = FakeAccountServer(registerThrows: {
        'code': 'writer_conflict',
        'message': 'taken',
        'active_writer': {'device_label': '거실 PC', 'platform': 'windows', 'source_app': 'safetyreport', 'created_at': 'x'},
      });
      final g = gateWith(server);
      expect((await g.refreshNow()).canEnter, isTrue);
      expect(g.writerConflict?.deviceLabel, '거실 PC');
      final ctx = await store.context();
      expect(ctx?['state'], 'inactive');
      expect(ctx?['inactive_reason'], 'writer:writer_conflict');
    });

    test('no official account: entry allowed, no connection, upload context off', () async {
      final server = FakeAccountServer();
      final g = gateWith(server, official: () async => null);
      expect((await g.refreshNow()).canEnter, isTrue);
      expect(server.count('/connections'), 0);
      expect((await store.context())?['inactive_reason'], 'writer:official_account_required');
    });

    test('connection secret is 32 random bytes, never the same twice', () async {
      final secrets = <String>{};
      for (var i = 0; i < 2; i++) {
        final server = FakeAccountServer();
        final g = gateWith(server);
        await g.refreshNow();
        final reg = server.requests.firstWhere((r) => r.url.path.endsWith('/connections'));
        final secret = (jsonDecode(reg.body) as Map)['connection_secret'] as String;
        expect(base64Url.decode(base64Url.normalize(secret)).length, 32);
        secrets.add(secret);
        await g.handleContributionsDeleted(); // 저장 연결을 지워 다음 반복이 새로 등록하게
      }
      expect(secrets.length, 2);
    });
  });
}
