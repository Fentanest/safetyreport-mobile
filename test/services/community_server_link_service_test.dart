import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _base = 'https://nas.example.test';
const _key = 'device-api-key';

Map<String, dynamic> statusJson(String state, {bool canManage = true}) => {
  'state': state,
  'can_manage': canManage,
  'pending': state == 'pending'
      ? {
          'request_id': 'req-1',
          'display_code': 'ABCD-2345',
          'bootstrap_url': 'https://worklazy.net/safeauth/#r=req-1&t=ticket',
          'expires_at': '2026-09-25T01:10:00Z',
          'phase': 'claimed',
        }
      : null,
  'candidate': state == 'confirm_required'
      ? {
          'request_id': 'req-1',
          'display_name': '서버계정',
          'has_email': false,
          'is_different_account': true,
        }
      : null,
  'account': state == 'connected'
      ? {
          'display_name': '연결된계정',
          'connected_at': '2026-09-24T12:00:00Z',
          'session_state': 'active',
        }
      : null,
  'last_error': null,
  'upload_enabled': false,
};

http.Response jsonResponse(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('status: X-API-Key 헤더로 GET, data 해석', () async {
    late http.Request seen;
    final client = MockClient((req) async {
      seen = req;
      return jsonResponse({'data': statusJson('connected')}, 200);
    });
    final r = await CommunityServerLinkService.fetchStatus(
      baseUrl: '$_base/',
      apiKey: _key,
      client: client,
    );
    expect(seen.method, 'GET');
    expect(seen.url.toString(), '$_base/api/v1/community-auth/status');
    expect(seen.headers[ServerContract.apiKeyHeader], _key);
    expect(r.isOk, isTrue);
    expect(r.status!.state, CommunityServerState.connected);
    expect(r.status!.account!.displayName, '연결된계정');
    expect(r.status!.account!.connectedAt, isNotNull);
    expect(r.status!.needsPolling, isFalse);
  });

  test('pending/candidate 해석, 폴링 필요', () {
    final p = CommunityServerLinkService.parseResponse(
      200,
      jsonEncode({'data': statusJson('pending')}),
    );
    expect(p.status!.state, CommunityServerState.pending);
    expect(p.status!.pending!.displayCode, 'ABCD-2345');
    expect(p.status!.pending!.safeBootstrapUri, isNotNull);
    expect(p.status!.needsPolling, isTrue);

    final c = CommunityServerLinkService.parseResponse(
      200,
      jsonEncode({'data': statusJson('confirm_required')}),
    );
    expect(c.status!.state, CommunityServerState.confirmRequired);
    expect(c.status!.candidate!.isDifferentAccount, isTrue);
    expect(c.status!.needsPolling, isTrue);
  });

  test('모든 상태 문자열 해석', () {
    const map = {
      'unconfigured': CommunityServerState.unconfigured,
      'disabled': CommunityServerState.disabled,
      'disconnected': CommunityServerState.disconnected,
      'pending': CommunityServerState.pending,
      'confirm_required': CommunityServerState.confirmRequired,
      'connected': CommunityServerState.connected,
      'reauth_required': CommunityServerState.reauthRequired,
      'store_unreadable': CommunityServerState.storeUnreadable,
      'something_new': CommunityServerState.unknown,
    };
    map.forEach((raw, expected) {
      final r = CommunityServerLinkService.parseResponse(
        200,
        jsonEncode({
          'data': {'state': raw, 'can_manage': false},
        }),
      );
      expect(r.status!.state, expected, reason: raw);
    });
  });

  test('https 가 아닌 bootstrap_url 은 열지 않는다', () {
    const p = CommunityServerPending(
      requestId: 'r',
      displayCode: 'X',
      bootstrapUrl: 'javascript:alert(1)',
      expiresAt: null,
      phase: '',
    );
    expect(p.safeBootstrapUri, isNull);
  });

  test('403 permission_required → 권한 안내', () async {
    final client = MockClient(
      (_) async => jsonResponse({
        'detail': '서버 관리자 화면에서 이 기기의 커뮤니티 계정 관리 권한을 허용해야 합니다.',
        'code': 'permission_required',
      }, 403),
    );
    final r = await CommunityServerLinkService.start(
      baseUrl: _base,
      apiKey: _key,
      client: client,
    );
    expect(r.isOk, isFalse);
    expect(r.error!.kind, CommunityServerErrorKind.permissionRequired);
    expect(r.error!.message, contains('서버 관리자 화면'));
  });

  test('404 → 서버가 아직 지원하지 않음', () async {
    final client = MockClient(
      (_) async => jsonResponse({'detail': 'Not Found'}, 404),
    );
    final r = await CommunityServerLinkService.fetchStatus(
      baseUrl: _base,
      apiKey: _key,
      client: client,
    );
    expect(r.error!.kind, CommunityServerErrorKind.unsupported);
    expect(r.error!.message, '서버가 이 기능을 아직 지원하지 않습니다.');
  });

  test('오류 코드 대응', () {
    const cases = {
      503: {
        'community_disabled': CommunityServerErrorKind.disabled,
        'community_unconfigured': CommunityServerErrorKind.unconfigured,
      },
      409: {
        'no_pending': CommunityServerErrorKind.noPending,
        'request_mismatch': CommunityServerErrorKind.requestMismatch,
        'invalid_state': CommunityServerErrorKind.invalidState,
      },
      410: {'expired': CommunityServerErrorKind.expired},
      429: {'rate_limited': CommunityServerErrorKind.rateLimited},
      502: {'relay_unavailable': CommunityServerErrorKind.relayUnavailable},
    };
    cases.forEach((status, codes) {
      codes.forEach((code, kind) {
        final r = CommunityServerLinkService.parseResponse(
          status,
          jsonEncode({'detail': 'x', 'code': code}),
        );
        expect(r.error!.kind, kind, reason: '$status $code');
      });
    });
    // detail 안에 code 가 있는 FastAPI 모양도 읽는다.
    final nested = CommunityServerLinkService.parseResponse(
      409,
      jsonEncode({
        'detail': {'code': 'no_pending', 'message': 'x'},
      }),
    );
    expect(nested.error!.kind, CommunityServerErrorKind.noPending);
    expect(
      CommunityServerLinkService.parseResponse(401, '{}').error!.kind,
      CommunityServerErrorKind.unauthorized,
    );
  });

  test('POST 본문과 경로 — 자동 재시도 없음', () async {
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      return jsonResponse({'error': 'boom'}, 500);
    });
    await CommunityServerLinkService.start(
      baseUrl: _base,
      apiKey: _key,
      client: client,
    );
    await CommunityServerLinkService.confirm(
      baseUrl: _base,
      apiKey: _key,
      requestId: 'req-1',
      client: client,
    );
    await CommunityServerLinkService.cancel(
      baseUrl: _base,
      apiKey: _key,
      requestId: 'req-1',
      client: client,
    );
    await CommunityServerLinkService.disconnect(
      baseUrl: _base,
      apiKey: _key,
      client: client,
    );
    expect(seen.map((r) => r.url.path), [
      '/api/v1/community-auth/start',
      '/api/v1/community-auth/confirm',
      '/api/v1/community-auth/cancel',
      '/api/v1/community-auth/disconnect',
    ]);
    expect(seen.every((r) => r.method == 'POST'), isTrue);
    expect(
      seen.every((r) => r.headers[ServerContract.apiKeyHeader] == _key),
      isTrue,
    );
    expect(jsonDecode(seen[0].body), <String, dynamic>{});
    expect(jsonDecode(seen[1].body), {'request_id': 'req-1'});
    expect(jsonDecode(seen[2].body), {'request_id': 'req-1'});
    expect(jsonDecode(seen[3].body), <String, dynamic>{});
  });

  test(
    '서버 오프라인 → 오류만, Supabase 주소는 부르지 않고 폰에 아무것도 저장하지 않음 (M06·M07)',
    () async {
      final secure = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(secure);
      SharedPreferences.setMockInitialValues({});
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        throw const SocketException('Connection refused');
      });
      final r = await CommunityServerLinkService.start(
        baseUrl: _base,
        apiKey: _key,
        client: client,
      );
      expect(r.error!.kind, CommunityServerErrorKind.offline);
      expect(r.error!.message, '서버에 연결할 수 없어 요청을 시작하지 못했습니다.');
      expect(hosts, ['nas.example.test']); // 한 번, 재시도 없음, 서버 주소만.
      expect(secure, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
    },
  );

  test('성공 응답에 토큰 같은 필드가 와도 모델에 담지 않는다 (M06)', () {
    final data = statusJson('connected')
      ..['access_token'] = 'leak'
      ..['refresh_token'] = 'leak';
    final r = CommunityServerLinkService.parseResponse(
      200,
      jsonEncode({'data': data}),
    );
    expect(r.isOk, isTrue);
    // 모델은 정해진 필드만 가진다 — 토큰을 꺼낼 방법이 없다.
    expect(r.status.toString(), isNot(contains('leak')));
  });
}
