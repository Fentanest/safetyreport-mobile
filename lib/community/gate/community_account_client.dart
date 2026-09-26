import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// `community-account` 함수 REST 클라이언트 (`contracts/community-ingest/account-api.md`).
///
/// 헤더: `apikey: <publishable key>`, `Authorization: Bearer <사용자 access token>`.
/// 본문 `{"protocol":1, …}`, 10초 타임아웃. 네트워크·형식 오류는 [CommunityAccountError] 로.
/// 테스트는 `http.Client` 가짜를 주입한다.
class CommunityAccountClient {
  CommunityAccountClient({
    required this.supabaseUrl,
    required this.publishableKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
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
    final json = await _post('consent-revoke', {'grant_id': grantId}, accessToken);
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
    await _post('connections-revoke', {'connection_id': connectionId}, accessToken);
  }

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
    final owned = _client ?? http.Client();
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
      return _decode(res.statusCode, res.body);
    } on TimeoutException {
      throw const CommunityAccountError(code: 'timeout', message: '서버 응답이 늦습니다. 다시 시도해 주세요.');
    } on CommunityAccountError {
      rethrow;
    } catch (_) {
      throw const CommunityAccountError(code: 'offline', message: '서버에 연결할 수 없습니다.');
    } finally {
      if (_client == null) owned.close();
    }
  }

  Map<String, Object?> _decode(int statusCode, String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      json = null;
    }
    if (statusCode == 200 && json is Map) {
      return json.cast<String, Object?>();
    }
    String code = 'server_error';
    String? message;
    if (json is Map) {
      final err = json['error'];
      if (err is Map) {
        if (err['code'] is String) code = err['code'] as String;
        if (err['message'] is String) message = err['message'] as String;
      }
    }
    throw CommunityAccountError(
      code: code,
      message: message ?? _defaultMessage(statusCode, code),
      httpStatus: statusCode,
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

class CommunityAccountError implements Exception {
  final String code;
  final String message;
  final int? httpStatus;
  const CommunityAccountError({required this.code, required this.message, this.httpStatus});

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
  String? get consentPolicyVersion => _map('consent')?['policy_version'] as String?;
  String? get contributorStatus => _map('contributor')?['status'] as String?;
  String get requiredPolicyVersion =>
      (_map('policy')?['required_version'] as String?) ?? '';
  String get consentTextSha256 =>
      (_map('policy')?['consent_text_sha256'] as String?) ?? '';
  String? get fingerprint => _map('account')?['fingerprint'] as String?;
  String? get displayName => _map('account')?['display_name'] as String?;

  Map<String, Object?>? get connection => _map('connection');

  Map<String, Object?> toGateInput() => {
        'gate': {'kakao': kakao},
        'contributor': {'status': contributorStatus},
        'consent': {
          'state': consentState,
          'policy_version': consentPolicyVersion,
        },
        'policy': {'required_version': requiredPolicyVersion},
      };

  static CommunityAccountStatus parse(Map<String, Object?> json) =>
      CommunityAccountStatus(Map<String, Object?>.from(json));
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

  static CommunityRevokeResult parse(Map<String, Object?> json) => CommunityRevokeResult(
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
  final List<Object?> revokedConnections;
  const CommunityDeleteResult({required this.deletionId, this.revokedConnections = const []});

  static CommunityDeleteResult parse(Map<String, Object?> json) => CommunityDeleteResult(
        deletionId: (json['deletion_id'] as String?) ?? '',
        revokedConnections: json['revoked_connections'] is List
            ? List<Object?>.from(json['revoked_connections'] as List)
            : const [],
      );
}
