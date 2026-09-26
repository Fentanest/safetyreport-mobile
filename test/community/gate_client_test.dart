// community-account REST 클라이언트 — 가짜 HTTP 주입, 네트워크 없음.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';

const _url = 'https://proj.supabase.test';
const _key = 'sb_publishable_test';
const _token = 'access-test';

Map<String, Object?> _statusJson({
  String consentState = 'active',
  String? consentPolicy = '2026-09-26.1',
  String contributor = 'active',
  bool kakao = true,
}) => {
      'protocol': 1,
      'gate': {'kakao': kakao, 'consent': true, 'can_enter': true, 'reasons': []},
      'policy': {
        'required_version': '2026-09-26.1',
        'consent_text_sha256': 'abc123',
      },
      'consent': {
        'state': consentState,
        'grant_id': 'grant-1',
        'policy_version': consentPolicy,
        'granted_at': '2026-09-26T03:00:00.000Z',
      },
      'contributor': {'status': contributor},
      'connection': null,
      'projection': {'ready': false},
      'account': {'fingerprint': 'fp-32hex', 'display_name': '테스터'},
      'server_time': '2026-09-26T03:00:00.000Z',
    };

CommunityAccountClient _client(MockClient mock) => CommunityAccountClient(
      supabaseUrl: _url,
      publishableKey: _key,
      client: mock,
    );

void main() {
  test('status sends apikey + Bearer + protocol:1, parses gate input', () async {
    late http.Request seen;
    final mock = MockClient((req) async {
      seen = req;
      return http.Response.bytes(utf8.encode(jsonEncode(_statusJson())), 200);
    });
    final status = await _client(mock).status(accessToken: _token);
    expect(seen.url.toString(), '$_url/functions/v1/community-account/status');
    expect(seen.headers['apikey'], _key);
    expect(seen.headers['Authorization'], 'Bearer $_token');
    expect(jsonDecode(seen.body)['protocol'], 1);
    expect(status.kakao, isTrue);
    expect(status.consentState, 'active');
    expect(status.fingerprint, 'fp-32hex');
    expect(status.toGateInput()['gate'], {'kakao': true});
  });

  test('consent posts policy + via mobile_standalone', () async {
    late http.Request seen;
    final mock = MockClient((req) async {
      seen = req;
      return http.Response(
        jsonEncode({
          'protocol': 1,
          'grant_id': 'g-9',
          'policy_version': '2026-09-26.1',
          'granted_at': '2026-09-26T03:00:00.000Z',
          'created': true,
        }),
        200,
      );
    });
    final res = await _client(mock).consent(
      accessToken: _token,
      policyVersion: '2026-09-26.1',
      consentTextSha256: 'abc123',
      via: 'mobile_standalone',
    );
    final body = jsonDecode(seen.body) as Map;
    expect(body['via'], 'mobile_standalone');
    expect(body['accepted'], isTrue);
    expect(body['policy_version'], '2026-09-26.1');
    expect(res.grantId, 'g-9');
  });

  test('errors carry code: stale_grant, writer_conflict, auth_required', () async {
    Future<CommunityAccountError> capture(
      String path, {
      required int status,
      required Map<String, Object?> body,
    }) async {
      final mock = MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(body)), status));
      try {
        if (path == 'revoke') {
          await _client(mock).revokeConsent(accessToken: _token, grantId: 'old');
        } else if (path == 'register') {
          await _client(mock).registerConnection(
            accessToken: _token,
            sourceMode: 'standalone',
            platform: 'android',
            deviceLabel: 'mobile',
            datasetKey: 'd' * 64,
            connectionSecret: 'secret',
          );
        } else {
          await _client(mock).status(accessToken: _token);
        }
        fail('should throw');
      } on CommunityAccountError catch (e) {
        return e;
      }
    }

    final stale = await capture(
      'revoke',
      status: 409,
      body: {
        'error': {'code': 'stale_grant', 'message': 'stale', 'requestTraceId': 't'}
      },
    );
    expect(stale.code, 'stale_grant');

    final conflict = await capture(
      'register',
      status: 409,
      body: {
        'error': {'code': 'writer_conflict', 'message': 'conflict', 'requestTraceId': 't'}
      },
    );
    expect(conflict.code, 'writer_conflict');

    final auth = await capture(
      'status',
      status: 401,
      body: {
        'error': {'code': 'auth_required', 'message': 'login', 'requestTraceId': 't'}
      },
    );
    expect(auth.code, 'auth_required');
    expect(auth.isAuth, isTrue);
  });

  test('revoke parses lineage_active:false; delete parses deletion', () async {
    final mock = MockClient((req) async {
      if (req.url.path.endsWith('consent-revoke')) {
        return http.Response(
          jsonEncode({'protocol': 1, 'grant_id': 'g-1', 'revoked': true, 'already_revoked': false, 'lineage_active': false}),
          200,
        );
      }
      return http.Response(
        jsonEncode({'protocol': 1, 'deletion_id': 'del-1', 'deleted_facts': 3, 'revoked_connections': ['c1'], 'deleted_at': '2026-09-26T03:00:00.000Z'}),
        200,
      );
    });
    final client = _client(mock);
    final revoke = await client.revokeConsent(accessToken: _token, grantId: 'g-1');
    expect(revoke.lineageActive, isFalse);
    final del = await client.deleteContributions(accessToken: _token);
    expect(del.deletionId, 'del-1');
    expect(del.revokedConnections, ['c1']);
  });

  test('offline maps to CommunityAccountError', () async {
    final mock = MockClient((_) async => throw http.ClientException('nope'));
    try {
      await _client(mock).status(accessToken: _token);
      fail('should throw');
    } on CommunityAccountError catch (e) {
      expect(e.code, 'offline');
    }
  });
}
