import 'dart:convert';

/// 커뮤니티 계정 응답을 읽는 클라이언트 규칙(D2-10). 정본 `contracts/community-client/client-rules.md`,
/// 벡터 `contracts/community-client/vectors/*.json`(서버·auth 와 같은 파일).

String? _s(Object? value) => value is String ? value : null;

/// status 응답의 게이트 관련 필드를 정해진 형으로 맞춘다(형이 다르면 없는 값). 최상위가 객체가 아니면 null.
Map<String, Object?>? normalizeAccountStatus(Object? raw) {
  if (raw is! Map) return null;
  final source = raw.cast<String, Object?>();
  Map<String, Object?> obj(String key) {
    final value = source[key];
    return value is Map ? value.cast<String, Object?>() : <String, Object?>{};
  }

  final gate = obj('gate');
  final contributor = obj('contributor');
  final consent = obj('consent');
  final policy = obj('policy');
  final account = obj('account');
  final reasons = gate['reasons'];
  return {
    ...source,
    'gate': {
      ...gate,
      'kakao': gate['kakao'] == true,
      'reasons': reasons is List
          ? reasons.whereType<String>().toList()
          : <String>[],
    },
    'contributor': {...contributor, 'status': _s(contributor['status'])},
    'consent': {
      ...consent,
      for (final k in const [
        'state',
        'grant_id',
        'policy_version',
        'consent_text_sha256',
      ])
        k: _s(consent[k]),
    },
    'policy': {
      ...policy,
      for (final k in const ['required_version', 'consent_text_sha256'])
        k: _s(policy[k]),
    },
    'account': {
      ...account,
      for (final k in const ['fingerprint', 'display_name']) k: _s(account[k]),
    },
    'connection': source['connection'] is Map
        ? (source['connection'] as Map).cast<String, Object?>()
        : null,
  };
}

class AccountResponse {
  final bool success;
  final Map<String, Object?>? data;
  final String? code;
  final String? message;
  final bool transient;
  final double? retryAfterSeconds;
  final bool auth;
  final Map<String, Object?> extra;

  const AccountResponse({
    required this.success,
    this.data,
    this.code,
    this.message,
    this.transient = false,
    this.retryAfterSeconds,
    this.auth = false,
    this.extra = const {},
  });
}

const _transientCodes = {'rate_limited', 'busy', 'server_error'};
final _retryAfterHeader = RegExp(r'^\d+$');

/// HTTP 응답을 성공 또는 (코드, 일시 오류 여부, 재시도 대기, 인증 오류)로 나눈다(client-rules §2).
AccountResponse classifyAccountResponse(
  int statusCode,
  String body,
  Map<String, String> headers,
) {
  Object? json;
  try {
    json = body.isEmpty ? null : jsonDecode(body);
  } catch (_) {
    json = null;
  }
  if (statusCode == 200 && json is Map && !json.containsKey('error')) {
    return AccountResponse(success: true, data: json.cast<String, Object?>());
  }
  final err = json is Map && json['error'] is Map
      ? (json['error'] as Map).cast<String, Object?>()
      : <String, Object?>{};
  final bodyCode = _s(err['code']);
  final code = bodyCode ?? 'server_error';
  final retryable = err['retryable'];
  // 본문에 코드가 없어 server_error 로 채운 경우는 HTTP 상태로만 판단한다(401·400·깨진 200 을 재시도하지 않게).
  final transient = retryable is bool
      ? retryable
      : (_transientCodes.contains(bodyCode) || statusCode >= 500);
  double? retryAfter;
  final after = err['retryAfterSeconds'];
  if (after is num && after >= 0) {
    retryAfter = after.toDouble();
  } else {
    String? header;
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'retry-after') header = e.value.trim();
    }
    if (header != null && _retryAfterHeader.hasMatch(header)) {
      retryAfter = double.parse(header);
    }
  }
  final extra = <String, Object?>{};
  if (err['active_writer'] is Map) {
    extra['active_writer'] = (err['active_writer'] as Map)
        .cast<String, Object?>();
  }
  if (err['required_version'] is String) {
    extra['required_version'] = err['required_version'];
  }
  return AccountResponse(
    success: false,
    code: code,
    message: _s(err['message']),
    transient: transient,
    retryAfterSeconds: retryAfter,
    auth: code == 'auth_required' || statusCode == 401,
    extra: extra,
  );
}

/// status 조회를 시작한 때와 받은 때의 (세대, 모드, 계정)이 같고 세션이 유효해야 그 응답을 쓴다(client-rules §4).
bool isCurrentResponse(Map<String, Object?> started, Map<String, Object?> now) {
  if (now['session'] != 'valid') return false;
  if (started['generation'] != now['generation'] ||
      started['mode'] != now['mode']) {
    return false;
  }
  return started['user_id'] == null || started['user_id'] == now['user_id'];
}
