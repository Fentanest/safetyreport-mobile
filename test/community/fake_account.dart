// 게이트·온보딩 테스트 공용 가짜: 카카오 세션, community-account HTTP, secure storage.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/services/community_auth_config.dart';
import 'package:safetyreport/services/community_auth_service.dart';

CommunityAuthConfig testAuthConfig() => CommunityAuthConfig.validate(
      url: 'https://proj.supabase.test',
      key: 'sb_publishable_test',
    );

/// 네트워크 없이 토큰을 주는 카카오 세션 스텁.
class StubAuthService extends CommunityAuthService {
  StubAuthService()
      : super(
          config: testAuthConfig(),
          storage: const FlutterSecureStorage(),
        );

  String? tokenResult = 'test-access-token';

  void setPhase(CommunityAccountPhase phase, {String name = '테스터'}) {
    state.value = CommunityAuthState(
      phase,
      account: phase == CommunityAccountPhase.disconnected ||
              phase == CommunityAccountPhase.unconfigured
          ? null
          : CommunityAccountInfo(displayName: name),
    );
  }

  @override
  Future<String?> getAccessToken() async => tokenResult;
}

Map<String, Object?> statusJson({
  String consentState = 'active',
  String? consentPolicy = '2026-09-26.1',
  String contributor = 'active',
  bool kakao = true,
  String fingerprint = 'fp-32hex',
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
      'account': {'fingerprint': fingerprint, 'display_name': '테스터'},
      'server_time': '2026-09-26T03:00:00.000Z',
    };

/// community-account 가짜. action 별 응답·요청 기록.
class FakeAccountServer {
  FakeAccountServer({
    Map<String, Object?> Function()? status,
    this.consentResponse,
    this.connectionsResponse,
    this.rebindResponse,
    this.revokeResponse,
    this.registerThrows,
  }) : statusFn = status ?? statusJson;

  final Map<String, Object?> Function() statusFn;
  final Map<String, Object?>? consentResponse;
  final Map<String, Object?>? connectionsResponse;
  final Map<String, Object?>? rebindResponse;
  final Map<String, Object?>? revokeResponse;

  /// 테스트 중 바꿀 수 있다(충돌 → 해소 흐름).
  Map<String, Object?>? registerThrows;

  /// consent 실패 주입 (F04). 예: {'code':'policy_mismatch',...} → 409.
  Map<String, Object?>? consentThrows;

  final requests = <http.Request>[];
  int statusCalls = 0;

  late final MockClient client = MockClient((req) async {
    requests.add(req);
    final path = req.url.path;
    if (path.endsWith('/status')) {
      statusCalls++;
      return http.Response.bytes(utf8.encode(jsonEncode(statusFn())), 200);
    }
    if (path.endsWith('/consent')) {
      if (consentThrows != null) {
        return http.Response.bytes(utf8.encode(jsonEncode({'error': consentThrows})), 409);
      }
      return http.Response(
        jsonEncode(
          consentResponse ??
              {
                'protocol': 1,
                'grant_id': 'grant-1',
                'policy_version': '2026-09-26.1',
                'granted_at': '2026-09-26T03:00:00.000Z',
                'created': true,
              },
        ),
        200,
      );
    }
    if (path.endsWith('/connections-rebind')) {
      return http.Response(
        jsonEncode(
          rebindResponse ??
              {'protocol': 1, 'connection_id': 'conn-1', 'writer_epoch': 3},
        ),
        200,
      );
    }
    if (path.endsWith('/connections')) {
      if (registerThrows != null) {
        final code = registerThrows!['code'];
        final status = code == 'writer_conflict' ? 409 : 400;
        return http.Response.bytes(utf8.encode(jsonEncode({'error': registerThrows})), status);
      }
      return http.Response(
        jsonEncode(
          connectionsResponse ??
              {'protocol': 1, 'connection_id': 'conn-1', 'writer_epoch': 3},
        ),
        200,
      );
    }
    if (path.endsWith('/consent-revoke')) {
      return http.Response(
        jsonEncode(
          revokeResponse ??
              {
                'protocol': 1,
                'grant_id': 'grant-1',
                'revoked': true,
                'already_revoked': false,
                'lineage_active': false,
              },
        ),
        200,
      );
    }
    return http.Response('{"error":{"code":"server_error"}}', 500);
  });

  CommunityAccountClient accountClient() => CommunityAccountClient(
        supabaseUrl: 'https://proj.supabase.test',
        publishableKey: 'sb_publishable_test',
        client: client,
      );

  int count(String suffix) =>
      requests.where((r) => r.url.path.endsWith(suffix)).length;
}

void setUpSecureStorage() {
  FlutterSecureStorage.setMockInitialValues({});
  addTearDown(() async {
    FlutterSecureStorage.setMockInitialValues({});
  });
}
