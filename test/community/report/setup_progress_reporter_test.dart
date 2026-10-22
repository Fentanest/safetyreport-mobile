import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/community/report/report_env.dart';
import 'package:safetyreport/community/report/setup_progress_reporter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'report_test_support.dart';

const _client = <String, Object?>{
  'server_reachable': true,
  'server_version': '3.6.2',
  'server_community_supported': true,
  'server_logged_in': false,
  'server_consent_active': null,
  'account_match': null,
};

void main() {
  late FakeNet net;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    net = FakeNet((_) => http.Response('{"protocol":1,"stored":true}', 200));
    net.install();
  });
  tearDown(ReportEnv.reset);

  test('경로·헤더(버전 헤더 포함)·본문', () async {
    await SetupProgressReporter.report(
      stage: 'official_login_failed',
      reason: 'captcha_required',
      mode: 'standalone',
    );
    final r = net.requests.single;
    expect(
      r.url.toString(),
      'https://example.supabase.co/functions/v1/community-account/setup-progress',
    );
    expect(r.headers['apikey'], 'sb_publishable_test');
    expect(r.headers['Authorization'], 'Bearer tok-test');
    expect(r.headers['X-Client-Version'], '2.5.1');
    expect(r.headers['X-Client-App'], 'mobile/android');
    expect(jsonDecode(r.body), {
      'protocol': 1,
      'client_version': '2.5.1',
      'source_app': 'safetyreport-mobile',
      'platform': 'android',
      'mode': 'standalone',
      'stage': 'official_login_failed',
      'reason': 'captcha_required',
      'client': null,
    });
    expect(utf8.encode(r.body).length, lessThanOrEqualTo(2048));
  });

  test('마지막 보낸 내용과 같으면 보내지 않고, 단계·reason·mode 가 다르면 보낸다', () async {
    Future<void> go(
      String stage, {
      String? reason,
      String mode = 'standalone',
    }) =>
        SetupProgressReporter.report(stage: stage, reason: reason, mode: mode);
    await go('kakao_ok');
    await go('kakao_ok');
    expect(net.requests, hasLength(1));
    await go('consent_ok');
    await go('official_login_started');
    await go('official_login_failed', reason: 'invalid_credentials');
    await go('official_login_failed', reason: 'invalid_credentials');
    await go('official_login_failed', reason: 'network');
    expect(net.requests, hasLength(5));
    await go('official_login_failed', reason: 'network', mode: 'demo');
    expect(net.requests, hasLength(6));
  });

  test(
    'connection_registered 를 보낸 뒤에는 보내지 않는다(새 로그인 kakao_ok 로 다시 시작)',
    () async {
      Future<void> go(String stage) =>
          SetupProgressReporter.report(stage: stage, mode: 'standalone');
      await go('official_login_ok');
      await go('connection_registered');
      expect(net.requests, hasLength(2));
      await go('official_login_started');
      await go('connection_registered');
      expect(net.requests, hasLength(2));
      await go('kakao_ok');
      expect(net.requests, hasLength(3));
    },
  );

  test('429 같은 실패는 보낸 것으로 치지 않아 같은 단계를 다음 호출에 다시 보낸다', () async {
    net.handler = (_) =>
        http.Response('{}', 429, headers: {'retry-after': '60'});
    await SetupProgressReporter.report(stage: 'kakao_ok', mode: 'standalone');
    net.handler = (_) => http.Response('{}', 200);
    await SetupProgressReporter.report(stage: 'kakao_ok', mode: 'standalone');
    await SetupProgressReporter.report(stage: 'kakao_ok', mode: 'standalone');
    expect(net.requests, hasLength(2));
  });

  test('Client 모드 client_server_checked: 정확히 6키, 내용이 바뀌면 다시 보낸다', () async {
    await SetupProgressReporter.report(
      stage: 'client_server_checked',
      mode: 'client',
      client: _client,
    );
    final body = jsonDecode(net.requests.single.body) as Map;
    expect(
      (body['client'] as Map).keys.toSet(),
      SetupProgressReporter.clientKeys,
    );
    await SetupProgressReporter.report(
      stage: 'client_server_checked',
      mode: 'client',
      client: _client,
    );
    expect(net.requests, hasLength(1));
    await SetupProgressReporter.report(
      stage: 'client_server_checked',
      mode: 'client',
      client: {..._client, 'server_logged_in': true},
    );
    expect(net.requests, hasLength(2));
  });

  test('client 가 6키가 아니거나 값 형식이 틀리면 보내지 않는다', () async {
    Future<void> go(Map<String, Object?>? c, {String mode = 'client'}) =>
        SetupProgressReporter.report(
          stage: 'client_server_checked',
          mode: mode,
          client: c,
        );
    await go(null);
    await go({..._client, 'server_url': 'https://x.example'});
    await go({..._client}..remove('account_match'));
    await go({..._client, 'server_reachable': null});
    await go({..._client, 'server_version': 'http://evil'});
    await go({..._client, 'account_match': 'yes'});
    await go(_client, mode: 'standalone');
    expect(net.requests, isEmpty);
  });

  test('client 단계가 아니면 client 는 항상 null, 이상한 reason 은 값을 버린다', () async {
    final body = SetupProgressReporter.buildBody(
      clientVersion: '2.5.1',
      platform: 'android',
      stage: 'official_login_failed',
      reason: 'https://official.example/login?id=hong',
      mode: 'standalone',
      client: _client,
    )!;
    expect(body['client'], isNull);
    expect(body['reason'], 'other');
    expect(jsonEncode(body), isNot(contains('official.example')));
    // 성공 단계에는 reason 이 없다.
    expect(
      SetupProgressReporter.buildBody(
        clientVersion: '2.5.1',
        platform: 'android',
        stage: 'kakao_ok',
        reason: 'x',
        mode: 'standalone',
      )!['reason'],
      isNull,
    );
  });

  test('모르는 단계·모드는 보내지 않고, 본문에 금지 키가 없다', () async {
    await SetupProgressReporter.report(stage: 'nope', mode: 'standalone');
    await SetupProgressReporter.report(stage: 'kakao_ok', mode: 'server');
    expect(net.requests, isEmpty);
    await SetupProgressReporter.report(stage: 'kakao_ok', mode: 'unselected');
    final keys = (jsonDecode(net.requests.single.body) as Map).keys.toSet();
    expect(keys, {
      'protocol',
      'client_version',
      'source_app',
      'platform',
      'mode',
      'stage',
      'reason',
      'client',
    });
  });

  test('토큰이 없거나 설정이 없으면 조용히 끝난다', () async {
    ReportEnv.tokenOverride = () async => null;
    await SetupProgressReporter.report(stage: 'kakao_ok', mode: 'standalone');
    expect(net.requests, isEmpty);
  });
}
