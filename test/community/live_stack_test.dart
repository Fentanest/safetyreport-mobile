// 모바일(Standalone) 커뮤니티 경로 — 실제 로컬 통합 스택(합성 Supabase ci0926-int) 수직 테스트. 기본은 건너뛴다.
//
// 실행(map integration worktree 에서 스택·가짜 카카오·함수 서빙이 떠 있어야 한다):
//   COMMUNITY_STACK=1 COMMUNITY_PUBLISHABLE_KEY=<npx supabase status 의 PUBLISHABLE_KEY> \
//     flutter test --no-pub test/community/live_stack_test.dart
// 실제: GoTrue·PostgREST·Postgres·edge-runtime. 가짜: 카카오(로컬 mock). 호스팅 카카오·실기기 아님.
// 위젯 바인딩을 초기화하지 않는다(flutter_test 의 HTTP 차단을 피하려고).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/community_wiring.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/community/upload/community_ingest_client.dart';
import 'package:safetyreport/community/upload/community_uploader.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const api = String.fromEnvironment('COMMUNITY_API_URL', defaultValue: 'http://127.0.0.1:56321');
final env = Platform.environment;
final enabled = env['COMMUNITY_STACK'] == '1' && (env['COMMUNITY_PUBLISHABLE_KEY'] ?? '').isNotEmpty;
final mockKakaoHost = env['COMMUNITY_MOCK_KAKAO_HOST'] ?? '172.17.0.1';
const policy = '2026-09-26.1';

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Future<Map<String, Object?>> kakaoSession(String key, String choice) async {
  final rng = Random.secure();
  final verifier = _b64(List<int>.generate(32, (_) => rng.nextInt(256)));
  final challenge = _b64(sha256.convert(utf8.encode(verifier)).bytes);
  final client = http.Client();
  Future<Uri> hop(Uri u) async {
    final req = http.Request('GET', u)..followRedirects = false;
    final res = await client.send(req);
    await res.stream.drain<void>();
    return Uri.parse(res.headers['location']!);
  }

  final kakao = await hop(Uri.parse('$api/auth/v1/authorize').replace(queryParameters: {
    'provider': 'kakao', 'redirect_to': 'http://127.0.0.1:56480/callback.html',
    'code_challenge': challenge, 'code_challenge_method': 's256',
  }));
  final decide = Uri(scheme: 'http', host: mockKakaoHost, port: kakao.port, path: '/oauth/decide',
      queryParameters: {'state': kakao.queryParameters['state']!, 'choice': choice});
  final callback = await hop(decide);
  final landed = await hop(callback);
  final res = await client.post(Uri.parse('$api/auth/v1/token?grant_type=pkce'),
      headers: {'apikey': key, 'content-type': 'application/json'},
      body: jsonEncode({'auth_code': landed.queryParameters['code'], 'code_verifier': verifier}));
  expect(res.statusCode, 200, reason: res.body);
  return jsonDecode(res.body) as Map<String, Object?>;
}

String sql(String q) => (Process.runSync('docker', ['exec', '-i', 'supabase_db_ci0926-int', 'psql', '-U', 'postgres', '-tAqc', q])
        .stdout as String)
    .trim();

class _Gate implements CommunityGateCheck {
  @override
  Future<bool> requireFresh() async => true; // 게이트 판정 자체는 gate 테스트·PC 수직 테스트가 본다. 서버는 매번 다시 확인한다.
  @override
  void invalidate(String reason) {}
}

class _Tokens implements CommunityTokenSource {
  _Tokens(this.token);
  final String token;
  @override
  Future<String?> getAccessToken() async => token;
}

void main() {
  sqfliteFfiInit();

  test('standalone capture → upload ACK → public → manifest → remote revoke blocks', () async {
    final key = env['COMMUNITY_PUBLISHABLE_KEY']!;
    sql("delete from private.rate_limits; delete from private.community_auth_rate_limits; "
        "update private.analytics_state set ready = true, published_at = coalesce(published_at, now()) where singleton;");
    final session = await kakaoSession(key, 'C');
    final token = session['access_token'] as String;
    final userId = (session['user'] as Map)['id'] as String;
    final account = CommunityAccountClient(supabaseUrl: api, publishableKey: key);
    final hash = File('contracts/community-ingest/consent/share-consent-2026-09-26.1.sha256').readAsStringSync().split(RegExp(r'\s'))[0];
    var status = await account.status(accessToken: token);
    if (status.consentState == 'active') {
      await account.revokeConsent(accessToken: token, grantId: status.consentGrantId!);
    }
    final grant = await account.consent(accessToken: token, policyVersion: policy, consentTextSha256: hash, via: 'mobile_standalone');
    final datasetKey = sha256.convert(utf8.encode('safetyreport-dataset|v1|mobile-live-${DateTime.now().microsecondsSinceEpoch}')).toString();
    final rng = Random.secure();
    final secret = _b64(List<int>.generate(32, (_) => rng.nextInt(256)));
    final conn = await account.registerConnection(accessToken: token, sourceMode: 'standalone', platform: 'android',
        deviceLabel: '통합 테스트 폰', datasetKey: datasetKey, connectionSecret: secret);
    status = await account.status(accessToken: token, connectionId: conn.connectionId);

    final tmp = await Directory.systemTemp.createTemp('mobile_live');
    final dbPath = '${tmp.path}/community.db';
    final store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
    addTearDown(() async {
      await CommunityStore.closeForTest(dbPath);
      await tmp.delete(recursive: true);
    });
    await store.setContext({
      'contributor_fingerprint': status.fingerprint, 'connection_id': conn.connectionId, 'writer_epoch': conn.writerEpoch,
      'dataset_key': datasetKey, 'consent_grant_id': grant.grantId, 'policy_version': policy,
      'consent_text_sha256': hash, 'source_app': 'safetyreport-mobile', 'source_mode': 'standalone',
    });

    final ingest = CommunityIngestClient(supabaseUrl: api, publishableKey: key);
    // 새 연결: manifest 먼저(빈 dataset "0")
    expect(await CommunityWiring.refreshManifest(store, client: ingest, token: () async => token), isTrue);
    expect(await store.meta('manifest_scope'), '$datasetKey:${conn.writerEpoch}');

    final vectors = jsonDecode(File('contracts/community-ingest/vectors/observations.json').readAsStringSync()) as Map;
    final input = Map<String, Object?>.from((vectors['cases'] as List).first['input'] as Map);
    final reportId = 'MLIVE${DateTime.now().microsecondsSinceEpoch}';
    final ns = projectNamespace(api);
    final captured = await capture(input, sourceReportId: reportId, trigger: 'realtime', store: store, projectNamespace: ns);
    expect(captured.eventId, isNotNull);

    final uploader = CommunityUploader(gate: _Gate(), tokens: _Tokens(token), appMode: () async => AppMode.standalone,
        supabaseUrl: api, publishableKey: key, clientVersion: 'it', openStore: () async => store);
    final run = await uploader.requestCommunityUpload('manual');
    expect(run.result, 'success', reason: '${run.result} ${run.errorCode} ${run.counts}');
    final journal = await store.db.rawQuery('SELECT ack_status, projection_status FROM source_journal WHERE event_id=?', [captured.eventId]);
    expect(journal.single['ack_status'], 'accepted');
    expect(journal.single['projection_status'], 'published');
    expect(sql("select count(*) from jsonb_array_elements(public.internal_analytics_v2_facts(date '2024-01-01', date '2028-12-31', 'all', null, null, null, null)) e "
        "where e->>'contributor_id' = '$userId';"), '1');
    expect(sql("select left(source_report_key, 24) from private.community_ingest_events where source_report_id = '$reportId';"),
        sourceReportKeyPrefix(reportId), reason: '모바일 키 = 서버 계산 키 = PC 키');

    expect(await CommunityWiring.refreshManifest(store, client: ingest, token: () async => token), isTrue);
    final keys = await store.db.rawQuery('SELECT key_prefix FROM server_completed');
    expect([for (final r in keys) r['key_prefix']], [sourceReportKeyPrefix(reportId)]);

    // 원격 철회 → 대기 이벤트는 거절되고 원장·공개는 늘지 않는다
    await account.revokeConsent(accessToken: token, grantId: grant.grantId);
    final ledger = sql('select count(*) from private.community_ingest_events;');
    final other = Map<String, Object?>.from(input);
    await capture(other, sourceReportId: '${reportId}B', trigger: 'realtime', store: store, projectNamespace: ns);
    final blocked = await uploader.requestCommunityUpload('manual');
    expect(blocked.result, isNot('success'));
    expect(sql('select count(*) from private.community_ingest_events;'), ledger);
    expect(sql("select count(*) from jsonb_array_elements(public.internal_analytics_v2_facts(date '2024-01-01', date '2028-12-31', 'all', null, null, null, null)) e "
        "where e->>'contributor_id' = '$userId';"), '0');
  }, skip: enabled ? false : 'COMMUNITY_STACK=1 과 COMMUNITY_PUBLISHABLE_KEY 가 필요하다(실제 로컬 스택)');
}
