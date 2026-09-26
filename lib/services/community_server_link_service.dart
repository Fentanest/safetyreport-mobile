import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_contract.dart';

/// Client 모드: 연결된 safetyreport 서버의 커뮤니티 계정 관리.
///
/// 서버가 인증·세션의 주인이다. 폰은 서버 API(`X-API-Key`)만 부르고 Supabase 토큰을 받거나
/// 저장하지 않는다(M06). 서버에 닿지 못해도 Standalone 로그인으로 바꾸지 않는다(M07).
/// start/confirm/cancel/disconnect 는 부작용이 있으므로 자동 재시도하지 않는다.
class CommunityServerLinkService {
  CommunityServerLinkService._();

  static const _timeout = Duration(seconds: 10);

  static Future<CommunityServerResult> fetchStatus({
    required String baseUrl,
    required String apiKey,
    http.Client? client,
  }) => _call(
    baseUrl,
    apiKey,
    ServerContract.communityAuthStatusPath,
    null,
    client: client,
    offlineMessage: '서버에 연결할 수 없어 상태를 확인하지 못했습니다.',
  );

  static Future<CommunityServerResult> start({
    required String baseUrl,
    required String apiKey,
    String? deviceLabel,
    http.Client? client,
  }) => _call(
    baseUrl,
    apiKey,
    ServerContract.communityAuthStartPath,
    {
      if (deviceLabel != null && deviceLabel.trim().isNotEmpty)
        'device_label': deviceLabel.trim(),
    },
    client: client,
    offlineMessage: '서버에 연결할 수 없어 요청을 시작하지 못했습니다.',
  );

  static Future<CommunityServerResult> confirm({
    required String baseUrl,
    required String apiKey,
    required String requestId,
    http.Client? client,
  }) => _call(
    baseUrl,
    apiKey,
    ServerContract.communityAuthConfirmPath,
    {'request_id': requestId},
    client: client,
    offlineMessage: '서버에 연결할 수 없어 연결을 확정하지 못했습니다.',
  );

  static Future<CommunityServerResult> cancel({
    required String baseUrl,
    required String apiKey,
    String? requestId,
    http.Client? client,
  }) => _call(
    baseUrl,
    apiKey,
    ServerContract.communityAuthCancelPath,
    {if (requestId != null && requestId.isNotEmpty) 'request_id': requestId},
    client: client,
    offlineMessage: '서버에 연결할 수 없어 요청을 취소하지 못했습니다.',
  );

  static Future<CommunityServerResult> disconnect({
    required String baseUrl,
    required String apiKey,
    http.Client? client,
  }) => _call(
    baseUrl,
    apiKey,
    ServerContract.communityAuthDisconnectPath,
    const <String, Object?>{},
    client: client,
    offlineMessage: '서버에 연결할 수 없어 연결을 해제하지 못했습니다.',
  );

  /// Client 서버 게이트 조회 (`GET /api/v1/community/gate`).
  /// 403 `COMMUNITY_ONBOARDING_REQUIRED` 면 서버 연결 승인·설정 복구 UI만 보인다.
  static Future<CommunityGateLinkResult> fetchCommunityGate({
    required String baseUrl,
    required String apiKey,
    http.Client? client,
  }) => _callGate(
    baseUrl,
    apiKey,
    ServerContract.communityGatePath,
    null,
    null,
    client: client,
    offlineMessage: '서버에 연결할 수 없어 서버 게이트를 확인하지 못했습니다.',
  );

  /// Client 서버 초기화 job 조회.
  static Future<CommunityGateLinkResult> fetchCommunityRebuild({
    required String baseUrl,
    required String apiKey,
    String? userToken,
    http.Client? client,
  }) => _callGate(
    baseUrl,
    apiKey,
    ServerContract.communityRebuildPath,
    null,
    userToken,
    client: client,
    offlineMessage: '서버에 연결할 수 없어 초기화 상태를 확인하지 못했습니다.',
  );

  /// Client 서버 초기화 시작·재개. 409 `COMMUNITY_REBUILD_REQUIRED` 는 본문으로 전달.
  static Future<CommunityGateLinkResult> startCommunityRebuild({
    required String baseUrl,
    required String apiKey,
    String? userToken,
    http.Client? client,
  }) => _callGate(
    baseUrl,
    apiKey,
    ServerContract.communityRebuildStartPath,
    const <String, Object?>{},
    userToken,
    client: client,
    offlineMessage: '서버에 연결할 수 없어 초기화를 시작하지 못했습니다.',
  );

  static Future<CommunityGateLinkResult> resumeCommunityRebuild({
    required String baseUrl,
    required String apiKey,
    String? userToken,
    http.Client? client,
  }) => _callGate(
    baseUrl,
    apiKey,
    ServerContract.communityRebuildResumePath,
    const <String, Object?>{},
    userToken,
    client: client,
    offlineMessage: '서버에 연결할 수 없어 초기화를 재개하지 못했습니다.',
  );

  static Future<CommunityGateLinkResult> _callGate(
    String baseUrl,
    String apiKey,
    String path,
    Map<String, Object?>? body,
    String? userToken, {
    http.Client? client,
    required String offlineMessage,
  }) async {
    if (baseUrl.trim().isEmpty) {
      return CommunityGateLinkResult.failure(
        code: 'offline',
        message: offlineMessage,
        offline: true,
      );
    }
    final uri = ServerContract.apiUri(baseUrl, path);
    final owned = client ?? http.Client();
    try {
      final http.Response res;
      if (body == null) {
        res = await owned
            .get(uri, headers: {ServerContract.apiKeyHeader: apiKey})
            .timeout(const Duration(seconds: 10));
      } else {
        final headers = ServerContract.apiHeaders(apiKey);
        if (userToken != null && userToken.isNotEmpty) {
          headers[ServerContract.communityUserTokenHeader] = userToken;
        }
        res = await owned
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 10));
      }
      return CommunityGateLinkResult.parse(
        res.statusCode,
        utf8.decode(res.bodyBytes, allowMalformed: true),
      );
    } catch (_) {
      return CommunityGateLinkResult.failure(
        code: 'offline',
        message: offlineMessage,
        offline: true,
      );
    } finally {
      if (client == null) owned.close();
    }
  }

  /// [body] 가 null 이면 GET, 아니면 POST(JSON).
  static Future<CommunityServerResult> _call(
    String baseUrl,
    String apiKey,
    String path,
    Map<String, Object?>? body, {
    http.Client? client,
    required String offlineMessage,
  }) async {
    if (baseUrl.trim().isEmpty) {
      return CommunityServerResult.failure(
        CommunityServerError(
          CommunityServerErrorKind.offline,
          message: offlineMessage,
        ),
      );
    }
    final uri = ServerContract.apiUri(baseUrl, path);
    final owned = client ?? http.Client();
    http.Response res;
    try {
      if (body == null) {
        res = await owned
            .get(
              uri,
              headers: ServerContract.apiHeaders(
                apiKey,
                includeJsonContentType: false,
              ),
            )
            .timeout(_timeout);
      } else {
        res = await owned
            .post(
              uri,
              headers: ServerContract.apiHeaders(apiKey),
              body: jsonEncode(body),
            )
            .timeout(_timeout);
      }
    } catch (_) {
      return CommunityServerResult.failure(
        CommunityServerError(
          CommunityServerErrorKind.offline,
          message: offlineMessage,
        ),
      );
    } finally {
      if (client == null) owned.close();
    }
    return parseResponse(
      res.statusCode,
      utf8.decode(res.bodyBytes, allowMalformed: true),
    );
  }

  /// 응답 해석(테스트용으로 공개).
  static CommunityServerResult parseResponse(int statusCode, String body) {    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      json = null;
    }
    if (statusCode == 200) {
      final data = json is Map ? json['data'] : null;
      final status = data is Map
          ? CommunityServerStatus.tryParse(data.cast<String, dynamic>())
          : null;
      if (status == null) {
        return CommunityServerResult.failure(
          const CommunityServerError(
            CommunityServerErrorKind.invalidResponse,
            httpStatus: 200,
            message: '서버 응답을 해석하지 못했습니다.',
          ),
        );
      }
      return CommunityServerResult.success(status);
    }
    return CommunityServerResult.failure(
      CommunityServerError.fromHttp(statusCode, json),
    );
  }
}

enum CommunityServerState {
  unconfigured,
  disabled,
  disconnected,
  pending,
  confirmRequired,
  connected,
  reauthRequired,
  storeUnreadable,
  unknown,
}

CommunityServerState _stateFrom(String? s) => switch (s) {
  'unconfigured' => CommunityServerState.unconfigured,
  'disabled' => CommunityServerState.disabled,
  'disconnected' => CommunityServerState.disconnected,
  'pending' => CommunityServerState.pending,
  'confirm_required' => CommunityServerState.confirmRequired,
  'connected' => CommunityServerState.connected,
  'reauth_required' => CommunityServerState.reauthRequired,
  'store_unreadable' => CommunityServerState.storeUnreadable,
  _ => CommunityServerState.unknown,
};

String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

/// 서버가 만든 중앙 연결 요청. [bootstrapUrl] 은 1회용 민감 링크 — 로그·복사·저장 금지, 브라우저로 열기만.
class CommunityServerPending {
  final String requestId;
  final String displayCode;
  final String bootstrapUrl;
  final DateTime? expiresAt;
  final String phase;
  const CommunityServerPending({
    required this.requestId,
    required this.displayCode,
    required this.bootstrapUrl,
    required this.expiresAt,
    required this.phase,
  });

  /// https 링크만 연다.
  Uri? get safeBootstrapUri {
    final u = Uri.tryParse(bootstrapUrl);
    if (u == null || u.scheme != 'https' || u.host.isEmpty) return null;
    return u;
  }
}

class CommunityServerCandidate {
  final String requestId;
  final String displayName;
  final bool hasEmail;
  final bool isDifferentAccount;
  const CommunityServerCandidate({
    required this.requestId,
    required this.displayName,
    required this.hasEmail,
    required this.isDifferentAccount,
  });
}

class CommunityServerAccount {
  final String displayName;
  final DateTime? connectedAt;
  final String sessionState;
  const CommunityServerAccount({
    required this.displayName,
    required this.connectedAt,
    required this.sessionState,
  });
}

class CommunityServerStatus {
  final CommunityServerState state;
  final String rawState;
  final bool canManage;
  final CommunityServerPending? pending;
  final CommunityServerCandidate? candidate;
  final CommunityServerAccount? account;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final bool uploadEnabled;

  const CommunityServerStatus({
    required this.state,
    required this.rawState,
    required this.canManage,
    this.pending,
    this.candidate,
    this.account,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.uploadEnabled = false,
  });

  bool get needsPolling =>
      state == CommunityServerState.pending ||
      state == CommunityServerState.confirmRequired;

  static CommunityServerStatus? tryParse(Map<String, dynamic> j) {
    final raw = j['state'];
    if (raw is! String) return null;
    final p = j['pending'];
    final c = j['candidate'];
    final a = j['account'];
    final e = j['last_error'];
    return CommunityServerStatus(
      state: _stateFrom(raw),
      rawState: raw,
      canManage: j['can_manage'] == true,
      pending: p is Map
          ? CommunityServerPending(
              requestId: _str(p['request_id']),
              displayCode: _str(p['display_code']),
              bootstrapUrl: _str(p['bootstrap_url']),
              expiresAt: DateTime.tryParse(_str(p['expires_at']))?.toLocal(),
              phase: _str(p['phase']),
            )
          : null,
      candidate: c is Map
          ? CommunityServerCandidate(
              requestId: _str(c['request_id']),
              displayName: _str(c['display_name']).trim().isEmpty
                  ? '카카오 사용자'
                  : _str(c['display_name']).trim(),
              hasEmail: c['has_email'] == true,
              isDifferentAccount: c['is_different_account'] == true,
            )
          : null,
      account: a is Map
          ? CommunityServerAccount(
              displayName: _str(a['display_name']).trim().isEmpty
                  ? '카카오 사용자'
                  : _str(a['display_name']).trim(),
              connectedAt: DateTime.tryParse(
                _str(a['connected_at']),
              )?.toLocal(),
              sessionState: _str(a['session_state']),
            )
          : null,
      lastErrorCode: e is Map ? _str(e['code']) : null,
      lastErrorMessage: e is Map ? _str(e['message']) : null,
      uploadEnabled: j['upload_enabled'] == true,
    );
  }
}

enum CommunityServerErrorKind {
  /// 네트워크·타임아웃 — 서버에 닿지 못함. Standalone 로그인으로 대체하지 않는다.
  offline,
  unauthorized,
  permissionRequired,

  /// 404 — 서버가 이 기능을 모름(구버전).
  unsupported,
  disabled,
  unconfigured,
  noPending,
  requestMismatch,
  invalidState,
  expired,
  rateLimited,
  relayUnavailable,
  server,
  invalidResponse,
}

class CommunityServerError {
  final CommunityServerErrorKind kind;
  final int? httpStatus;
  final String? code;

  /// 사용자에게 보일 한국어 문구.
  final String message;

  const CommunityServerError(
    this.kind, {
    this.httpStatus,
    this.code,
    required this.message,
  });

  static const permissionMessage = '서버 관리자 화면에서 이 기기의 커뮤니티 계정 관리 권한을 허용해야 합니다.';
  static const unsupportedMessage = '서버가 이 기능을 아직 지원하지 않습니다.';

  factory CommunityServerError.fromHttp(int status, Object? json) {
    String code = '';
    if (json is Map) {
      final c = json['code'];
      final d = json['detail'];
      final e = json['error'];
      if (c is String) {
        code = c;
      } else if (d is Map && d['code'] is String) {
        code = d['code'] as String;
      } else if (e is Map && e['code'] is String) {
        code = e['code'] as String;
      }
    }
    CommunityServerError err(CommunityServerErrorKind k, String m) =>
        CommunityServerError(k, httpStatus: status, code: code, message: m);
    if (status == 401) {
      return err(CommunityServerErrorKind.unauthorized, 'API Key 인증 실패 (401)');
    }
    if (status == 403 || code == 'permission_required') {
      return err(
        CommunityServerErrorKind.permissionRequired,
        permissionMessage,
      );
    }
    if (status == 404) {
      return err(CommunityServerErrorKind.unsupported, unsupportedMessage);
    }
    switch (code) {
      case 'community_disabled':
        return err(CommunityServerErrorKind.disabled, '서버에서 커뮤니티 기능이 꺼져 있습니다.');
      case 'community_unconfigured':
        return err(CommunityServerErrorKind.unconfigured, '서버에 커뮤니티 설정이 없습니다.');
      case 'no_pending':
        return err(
          CommunityServerErrorKind.noPending,
          '진행 중인 연결 요청이 없습니다. 다시 시작해 주세요.',
        );
      case 'request_mismatch':
        return err(
          CommunityServerErrorKind.requestMismatch,
          '다른 연결 요청이 진행 중입니다. 상태를 새로 고친 뒤 다시 확인해 주세요.',
        );
      case 'invalid_state':
        return err(
          CommunityServerErrorKind.invalidState,
          '지금 상태에서는 할 수 없습니다. 상태를 새로 고쳐 주세요.',
        );
      case 'expired':
        return err(
          CommunityServerErrorKind.expired,
          '연결 요청 시간이 지났습니다. 다시 시작해 주세요.',
        );
      case 'rate_limited':
        return err(
          CommunityServerErrorKind.rateLimited,
          '요청이 너무 잦습니다. 잠시 후 다시 시도해 주세요.',
        );
      case 'relay_unavailable':
        return err(
          CommunityServerErrorKind.relayUnavailable,
          '서버가 커뮤니티 인증 중계에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.',
        );
    }
    if (status == 410) {
      return err(
        CommunityServerErrorKind.expired,
        '연결 요청 시간이 지났습니다. 다시 시작해 주세요.',
      );
    }
    if (status == 429) {
      return err(
        CommunityServerErrorKind.rateLimited,
        '요청이 너무 잦습니다. 잠시 후 다시 시도해 주세요.',
      );
    }
    if (status == 502) {
      return err(
        CommunityServerErrorKind.relayUnavailable,
        '서버가 커뮤니티 인증 중계에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.',
      );
    }
    if (status == 503) {
      return err(CommunityServerErrorKind.disabled, '서버에서 커뮤니티 기능을 쓸 수 없습니다.');
    }
    if (status == 409) {
      return err(
        CommunityServerErrorKind.invalidState,
        '지금 상태에서는 할 수 없습니다. 상태를 새로 고쳐 주세요.',
      );
    }
    return err(CommunityServerErrorKind.server, '서버 오류: HTTP $status');
  }
}

class CommunityServerResult {
  final CommunityServerStatus? status;
  final CommunityServerError? error;
  const CommunityServerResult._(this.status, this.error);

  factory CommunityServerResult.success(CommunityServerStatus s) =>
      CommunityServerResult._(s, null);
  factory CommunityServerResult.failure(CommunityServerError e) =>
      CommunityServerResult._(null, e);

  bool get isOk => status != null;
}

/// Client 서버 게이트·초기화 job 원시 응답.
///
/// 403 `COMMUNITY_ONBOARDING_REQUIRED`·409 `COMMUNITY_REBUILD_REQUIRED` 는
/// 오류가 아니라 화면 분기 신호이므로 `code` 로 그대로 들고 있는다.
class CommunityGateLinkResult {
  final Map<String, dynamic>? data;
  final String? code;
  final String? message;
  final int? httpStatus;
  final bool offline;
  const CommunityGateLinkResult._({
    this.data,
    this.code,
    this.message,
    this.httpStatus,
    this.offline = false,
  });

  factory CommunityGateLinkResult.success(Map<String, dynamic> data) =>
      CommunityGateLinkResult._(data: data);
  factory CommunityGateLinkResult.failure({
    String? code,
    String? message,
    int? httpStatus,
    bool offline = false,
  }) => CommunityGateLinkResult._(
    code: code,
    message: message,
    httpStatus: httpStatus,
    offline: offline,
  );

  bool get isOk => data != null;
  bool get needsOnboarding => code == 'COMMUNITY_ONBOARDING_REQUIRED';
  bool get needsRebuild => code == 'COMMUNITY_REBUILD_REQUIRED';

  static CommunityGateLinkResult parse(int statusCode, String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      json = null;
    }
    Map<String, dynamic>? data;
    if (json is Map) {
      final d = json['data'];
      if (d is Map) data = d.cast<String, dynamic>();
    }
    if (statusCode == 200 && data != null) {
      return CommunityGateLinkResult.success(data);
    }
    String code = '';
    String? message;
    if (json is Map) {
      final c = json['code'];
      final e = json['error'];
      if (c is String) code = c;
      if (e is Map && e['code'] is String) code = e['code'] as String;
      final m = json['message'];
      if (m is String) message = m;
    }
    return CommunityGateLinkResult.failure(
      code: code.isEmpty ? 'server_error' : code,
      message: message ?? '서버 오류: HTTP $statusCode',
      httpStatus: statusCode,
    );
  }
}


