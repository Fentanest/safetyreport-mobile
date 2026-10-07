// 게이트·온보딩 테스트 공용 가짜: 카카오 세션, community-account HTTP, secure storage.
import 'dart:convert';

import 'package:crypto/crypto.dart';

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

  @override
  Future<String?> sessionFingerprint() async => 'fp-32hex';

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

  /// 로그인한 카카오 회원번호(게이트의 자료 주인 확인·로그아웃 판단용).
  String? kakaoId = '910001';

  @override
  Future<String?> currentKakaoId() async => kakaoId;

  @override
  Future<String?> sessionKakaoId() async => kakaoId;
}

/// 게이트의 자료 주인 확인 — 시험 기본값은 "이 계정의 자료"(주인 판정 자체는 test/storage/account_owner_test.dart).
Future<String> ownerOk(String? kakaoId) async => 'ok';

/// 가짜 중앙이 `policy` 로 내려주는 동의문(2026-09-27 — 앱에 동의문을 넣어 두지 않는다).
const fakePolicyText = '# [필수] 신고 결과 공유 동의\n정책 버전: 2026-09-28.1\n\n시험용 동의문 본문\n';
final fakePolicyHash = sha256.convert(utf8.encode(fakePolicyText)).toString();

Map<String, Object?> statusJson({
  String consentState = 'active',
  String? consentPolicy = '2026-09-28.1',
  String? consentHash,
  String contributor = 'active',
  bool kakao = true,
  String fingerprint = 'fp-32hex',
}) => {
      'protocol': 1,
      'gate': {'kakao': kakao, 'consent': true, 'can_enter': true, 'reasons': []},
      'policy': {
        'required_version': '2026-09-28.1',
        'consent_text_sha256': fakePolicyHash,
      },
      'consent': {
        'state': consentState,
        'grant_id': 'grant-1',
        'policy_version': consentPolicy,
        'consent_text_sha256': consentPolicy == null ? null : (consentHash ?? fakePolicyHash),
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

  /// 다른 기기가 writer 인 상태: takeover 없이 등록하면 writer_conflict, takeover=true 면 성공.
  bool conflictUnlessTakeover = false;

  /// `/connections` 요청 본문의 takeover 값 기록.
  final registerTakeovers = <bool>[];

  /// consent 실패 주입 (F04). 예: {'code':'policy_mismatch',...} → 409.
  Map<String, Object?>? consentThrows;

  final requests = <http.Request>[];
  int statusCalls = 0;
  int statusFailures = 0;
  Map<String, Object?> deleteResponse = {'official_account_released': true};
  void Function()? onDelete;


  /// `policy` 가 내려줄 동의문(바꾸면 해시도 따라 바뀐다). [policyHashOverride] 로 본문과 다른 해시(변조)를 흉내 낸다.
  String policyText = fakePolicyText;
  String? policyHashOverride;

  /// 동의 성공 응답 뒤 부른다(시험이 status 를 '동의함'으로 바꾸게).
  void Function()? onConsent;

  /// 남은 횟수만큼 `policy` 가 일시 오류(503)를 낸다.
  int policyFailures = 0;

  /// 설정하면 status 응답이 이 Future 가 끝날 때까지 늦게 온다(늦게 도착한 이전 세션 응답 흉내).
  Future<void>? statusDelay;

  late final MockClient client = MockClient((req) async {
    requests.add(req);
    final path = req.url.path;
    if (path.endsWith('/status')) {
      statusCalls++;
      if (statusFailures > 0) {
        statusFailures--;
        return http.Response('{"error":{"code":"busy","retryable":true}}', 503);
      }
      final delay = statusDelay;
      if (delay != null) await delay;
      return http.Response.bytes(utf8.encode(jsonEncode(statusFn())), 200);
    }
    if (path.endsWith('/contributions-delete')) {
      onDelete?.call();
      return http.Response(jsonEncode(deleteResponse), 200);
    }
    if (path.endsWith('/policy')) {
      if (policyFailures > 0) {
        policyFailures--;
        return http.Response.bytes(
            utf8.encode(jsonEncode({'error': {'code': 'busy', 'message': 'busy', 'retryable': true}})), 503);
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'protocol': 1,
          'policy': {
            'version': '2026-09-28.1',
            'consent_text_sha256': policyHashOverride ?? sha256.convert(utf8.encode(policyText)).toString(),
            'consent_text': policyText,
          },
        })),
        200,
      );
    }
    if (path.endsWith('/consent')) {
      if (consentThrows != null) {
        return http.Response.bytes(utf8.encode(jsonEncode({'error': consentThrows})), 409);
      }
      onConsent?.call();
      return http.Response(
        jsonEncode(
          consentResponse ??
              {
                'protocol': 1,
                'grant_id': 'grant-1',
                'policy_version': '2026-09-28.1',
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
      final takeover = (jsonDecode(req.body) as Map)['takeover'] == true;
      registerTakeovers.add(takeover);
      if (conflictUnlessTakeover && !takeover) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({'error': {'code': 'writer_conflict', 'message': 'taken'}})),
          409,
        );
      }
      if (registerThrows != null) {
        final code = registerThrows!['code'];
        final status = code == 'writer_conflict' || code == 'official_account_mismatch' || code == 'official_account_taken' ? 409 : 400;
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
