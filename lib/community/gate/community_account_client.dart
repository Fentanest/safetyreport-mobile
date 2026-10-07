import '../cloud_availability.dart';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'community_client_rules.dart';

/// `community-account` 함수 REST 클라이언트 (`contracts/community-ingest/account-api.md`).
///
/// 헤더: `apikey: <publishable key>`, `Authorization: Bearer <사용자 access token>`.
/// 본문 `{"protocol":1, …}`, 30초 타임아웃. 네트워크·형식 오류는 [CommunityAccountError] 로.
/// 테스트는 `http.Client` 가짜를 주입한다.
class CommunityAccountClient {
  CommunityAccountClient({
    required this.supabaseUrl,
    required this.publishableKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client;

  final String supabaseUrl;
  final String publishableKey;
  final http.Client? _client;
  final Duration timeout;

  Future<CommunityAccountStatus> status({
    required String accessToken,
    String? connectionId,
  }) async {
    final json = await _post('status', {
      if (connectionId != null && connectionId.isNotEmpty)
        'connection_id': connectionId,
    }, accessToken);
    return CommunityAccountStatus.parse(json);
  }

  /// 지금 필수 동의 정책(버전·해시·본문, 계약 account-api.md `policy`, 2026-09-27).
  /// 동의문은 앱에 넣어 두지 않고 중앙에서 받는다. 본문의 sha256(UTF-8)이 해시와 같을 때만 돌려준다 — 보여 줄 본문 = 동의할 해시.
  Future<CommunityPolicy> policy({required String accessToken}) async {
    final json = await _post('policy', const {}, accessToken);
    final p = json['policy'];
    if (p is Map) {
      final version = p['version'];
      final hash = p['consent_text_sha256'];
      final text = p['consent_text'];
      if (version is String &&
          hash is String &&
          text is String &&
          sha256.convert(utf8.encode(text)).toString() == hash) {
        return CommunityPolicy(
          version: version,
          consentTextSha256: hash,
          consentText: text,
        );
      }
    }
    throw const CommunityAccountError(
      code: 'policy_invalid',
      message: '동의 문서를 확인하지 못했습니다. 잠시 뒤 다시 시도해 주세요.',
    );
  }

  Future<CommunityConsentResult> consent({
    required String accessToken,
    required String policyVersion,
    required String consentTextSha256,
    required String via,
  }) async {
    final json = await _post('consent', {
      'policy_version': policyVersion,
      'consent_text_sha256': consentTextSha256,
      'via': via,
      'accepted': true,
    }, accessToken);
    return CommunityConsentResult.parse(json);
  }

  Future<CommunityRevokeResult> revokeConsent({
    required String accessToken,
    required String grantId,
  }) async {
    final json = await _post('consent-revoke', {
      'grant_id': grantId,
    }, accessToken);
    return CommunityRevokeResult.parse(json);
  }

  Future<CommunityConnectionResult> registerConnection({
    required String accessToken,
    required String sourceMode,
    required String platform,
    required String deviceLabel,
    required String datasetKey,
    required String connectionSecret,
    bool takeover = false,
  }) async {
    final json = await _post('connections', {
      'source_app': 'safetyreport-mobile',
      'source_mode': sourceMode,
      'platform': platform,
      'device_label': deviceLabel,
      'dataset_key': datasetKey,
      'connection_secret': connectionSecret,
      'takeover': takeover,
    }, accessToken);
    return CommunityConnectionResult.parse(json);
  }

  Future<CommunityConnectionResult> rebindConnection({
    required String accessToken,
    required String connectionId,
    required String connectionSecret,
  }) async {
    final json = await _post('connections-rebind', {
      'connection_id': connectionId,
      'connection_secret': connectionSecret,
    }, accessToken);
    return CommunityConnectionResult.parse(json);
  }

  Future<void> revokeConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    await _post('connections-revoke', {
      'connection_id': connectionId,
    }, accessToken);
  }

  // 공식 계정 변경: 공유자료 삭제와 바인딩 해제 확인을 함께 사용한다.
  Future<CommunityDeleteResult> deleteContributions({
    required String accessToken,
  }) async {
    final json = await _post('contributions-delete', {
      'confirm': 'DELETE_MY_SHARED_REPORTS',
    }, accessToken);
    return CommunityDeleteResult.parse(json);
  }

  Future<Map<String, Object?>> _post(
    String action,
    Map<String, Object?> body,
    String accessToken,
  ) async {
    final uri = Uri.parse(
      '${supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/functions/v1/community-account/$action',
    );
    final owned = CloudHttpClient(_client ?? http.Client());
    try {
      final res = await owned
          .post(
            uri,
            headers: {
              'apikey': publishableKey,
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'protocol': 1, ...body}),
          )
          .timeout(timeout);
      return _decode(
        res.statusCode,
        utf8.decode(res.bodyBytes, allowMalformed: true),
        res.headers,
      );
    } on TimeoutException {
      throw const CommunityAccountError(
        code: 'timeout',
        message: '서버 응답이 늦습니다. 다시 시도해 주세요.',
        transient: true,
      );
    } on CommunityAccountError {
      rethrow;
    } catch (_) {
      throw const CommunityAccountError(
        code: 'offline',
        message: '서버에 연결할 수 없습니다.',
        transient: true,
      );
    } finally {
      if (_client == null) owned.close();
    }
  }

  /// 응답 분류는 서버·auth 와 같은 규칙(client-rules §2, [classifyAccountResponse]).
  Map<String, Object?> _decode(
    int statusCode,
    String body, [
    Map<String, String> headers = const {},
  ]) {
    final result = classifyAccountResponse(statusCode, body, headers);
    if (result.success) return result.data!;
    throw CommunityAccountError(
      code: result.code!,
      message:
          officialAccountErrorMessage(result.code!) ??
          result.message ??
          _defaultMessage(statusCode, result.code!),
      httpStatus: statusCode,
      extra: result.extra,
      transient: result.transient,
      retryAfterSeconds: result.retryAfterSeconds,
    );
  }

  String _defaultMessage(int status, String code) {
    switch (code) {
      case 'auth_required':
        return '로그인이 필요합니다. 카카오 인증을 다시 해주세요.';
      case 'kakao_required':
        return '카카오 인증이 필요합니다.';
      case 'policy_mismatch':
        return '동의 문서가 바뀌었습니다. 새 동의 내용을 확인해 주세요.';
      case 'contributor_suspended':
        return '커뮤니티 이용이 정지된 계정입니다.';
      case 'writer_conflict':
        return '다른 기기가 이 신고자 이름으로 업로드하고 있습니다.';
      case 'stale_grant':
        return '동의 상태가 바뀌었습니다. 최신 상태를 다시 확인합니다.';
      case 'not_found':
        return '요청한 정보를 찾을 수 없습니다.';
    }
    if (status == 401) return '로그인이 필요합니다. 카카오 인증을 다시 해주세요.';
    return '서버 오류: HTTP $status';
  }
}

String? officialAccountErrorMessage(String code) => switch (code) {
  'official_account_mismatch' =>
    '연결된 안전신문고 계정이 다릅니다. 바인딩된 계정으로 로그인하거나 계정 변경 절차를 완료해 주세요.',
  'official_account_taken' =>
    '이 안전신문고 계정은 이미 다른 카카오 계정에 연결되어 있습니다. 운영자에게 문의해 주세요.',
  _ => null,
};

class CommunityAccountError implements Exception {
  final String code;
  final String message;
  final int? httpStatus;

  /// `writer_conflict` 의 `active_writer`(device_label·platform·source_app·created_at) 등 표시용 부가 정보.
  final Map<String, Object?> extra;

  /// 일시 오류(네트워크·시간 초과·바쁨·요청 과다 등, client-rules §2). 아니면 게이트를 무효화한다.
  final bool transient;
  final double? retryAfterSeconds;
  const CommunityAccountError({
    required this.code,
    required this.message,
    this.httpStatus,
    this.extra = const {},
    this.transient = false,
    this.retryAfterSeconds,
  });

  // A failed service request must never become an account/consent verdict.
  bool get serviceUnavailable =>
      transient ||
      httpStatus == 429 ||
      httpStatus == 408 ||
      (httpStatus != null && httpStatus! >= 500);

  bool get isAuth => code == 'auth_required' || httpStatus == 401;
  bool get isForbidden =>
      code == 'kakao_required' ||
      code == 'consent_required' ||
      code == 'contributor_suspended' ||
      httpStatus == 403;

  @override
  String toString() => 'CommunityAccountError($code): $message';
}

/// status 응답 읽기 전용 보기. 게이트 판정은 [evaluateGate] 가 `toGateInput()` 으로 한다.
class CommunityAccountStatus {
  CommunityAccountStatus(this.raw);

  final Map<String, Object?> raw;

  Map<String, Object?>? _map(String key) {
    final v = raw[key];
    return v is Map ? v.cast<String, Object?>() : null;
  }

  bool get kakao => _map('gate')?['kakao'] == true;
  String? get consentState => _map('consent')?['state'] as String?;
  String? get consentGrantId => _map('consent')?['grant_id'] as String?;
  String? get consentPolicyVersion =>
      _map('consent')?['policy_version'] as String?;
  String? get contributorStatus => _map('contributor')?['status'] as String?;
  String get requiredPolicyVersion =>
      (_map('policy')?['required_version'] as String?) ?? '';

  /// 중앙의 지금 정책 동의문 해시.
  String get consentTextSha256 =>
      (_map('policy')?['consent_text_sha256'] as String?) ?? '';

  /// 내 grant 가 동의한 동의문 해시(업로드 context 에 기록).
  String? get grantConsentTextSha256 =>
      _map('consent')?['consent_text_sha256'] as String?;
  String? get fingerprint => _map('account')?['fingerprint'] as String?;
  String? get displayName => _map('account')?['display_name'] as String?;

  /// 필드가 없는 구서버는 대조만 생략한다. 필드가 있는데 형식이 틀리면 차단한다.
  bool get hasOfficialAccount => raw.containsKey('official_account');
  bool get officialAccountValid {
    final value = raw['official_account'];
    if (value is! Map || !value.containsKey('dataset_key')) return false;
    final key = value['dataset_key'];
    return key == null ||
        (key is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(key));
  }

  String? get officialDatasetKey => officialAccountValid
      ? (raw['official_account'] as Map)['dataset_key'] as String?
      : null;

  Map<String, Object?>? get connection => _map('connection');

  Map<String, Object?> toGateInput() => {
    'gate': {'kakao': kakao},
    'contributor': {'status': contributorStatus},
    'consent': {
      'state': consentState,
      'policy_version': consentPolicyVersion,
      'consent_text_sha256': grantConsentTextSha256,
    },
    'policy': {
      'required_version': requiredPolicyVersion,
      'consent_text_sha256': consentTextSha256,
    },
  };

  /// 게이트 관련 필드를 정해진 형으로 맞춘 뒤 보관한다(client-rules §1, 서버 normalize_status 와 같음).
  static CommunityAccountStatus parse(Map<String, Object?> json) =>
      CommunityAccountStatus(normalizeAccountStatus(json)!);
}

/// 중앙이 내려준 지금 필수 동의 정책(본문 해시 확인 뒤).
class CommunityPolicy {
  const CommunityPolicy({
    required this.version,
    required this.consentTextSha256,
    required this.consentText,
  });

  final String version;
  final String consentTextSha256;
  final String consentText;
}

class CommunityConsentResult {
  final String grantId;
  final String policyVersion;
  final String? grantedAt;
  final bool created;
  const CommunityConsentResult({
    required this.grantId,
    required this.policyVersion,
    this.grantedAt,
    this.created = true,
  });

  static CommunityConsentResult parse(Map<String, Object?> json) {
    final grant = json['grant_id'];
    final version = json['policy_version'];
    if (grant is! String || version is! String) {
      throw const CommunityAccountError(
        code: 'invalid_response',
        message: '서버 응답을 해석하지 못했습니다.',
      );
    }
    return CommunityConsentResult(
      grantId: grant,
      policyVersion: version,
      grantedAt: json['granted_at'] as String?,
      created: json['created'] != false,
    );
  }
}

class CommunityRevokeResult {
  final String grantId;
  final bool revoked;
  final bool lineageActive;
  const CommunityRevokeResult({
    required this.grantId,
    required this.revoked,
    required this.lineageActive,
  });

  static CommunityRevokeResult parse(Map<String, Object?> json) =>
      CommunityRevokeResult(
        grantId: (json['grant_id'] as String?) ?? '',
        revoked: json['revoked'] == true,
        lineageActive: json['lineage_active'] != false,
      );
}

class CommunityConnectionResult {
  final String connectionId;
  final int writerEpoch;
  final bool supersededPrevious;
  final int? lastAcceptedRevision;
  const CommunityConnectionResult({
    required this.connectionId,
    required this.writerEpoch,
    this.supersededPrevious = false,
    this.lastAcceptedRevision,
  });

  static CommunityConnectionResult parse(Map<String, Object?> json) {
    final id = json['connection_id'];
    if (id is! String) {
      throw const CommunityAccountError(
        code: 'invalid_response',
        message: '서버 응답을 해석하지 못했습니다.',
      );
    }
    return CommunityConnectionResult(
      connectionId: id,
      writerEpoch: (json['writer_epoch'] as num?)?.toInt() ?? 0,
      supersededPrevious: json['superseded_previous'] == true,
      lastAcceptedRevision: (json['last_accepted_revision'] as num?)?.toInt(),
    );
  }
}

class CommunityDeleteResult {
  final String deletionId;
  final bool officialAccountReleased;
  final List<Object?> revokedConnections;
  const CommunityDeleteResult({
    required this.deletionId,
    this.officialAccountReleased = false,
    this.revokedConnections = const [],
  });

  static CommunityDeleteResult parse(Map<String, Object?> json) =>
      CommunityDeleteResult(
        deletionId: (json['deletion_id'] as String?) ?? '',
        officialAccountReleased: json['official_account_released'] == true,
        revokedConnections: json['revoked_connections'] is List
            ? List<Object?>.from(json['revoked_connections'] as List)
            : const [],
      );
}
