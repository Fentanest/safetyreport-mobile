// 커뮤니티 업로드 공통 판정 규칙 UC-1 (PC `services/community_upload_policy.py` 와 같은 뜻).
//
// 순수 함수만 둔다(네트워크·DB 없음). 두 앱이 `contracts/upload-control/vectors.json` 으로 같은 결과를 확인한다.
// - 응답 해석: 전송 계층(실제 HTTP 상태·헤더·본문 바이트)과 서버 JSON 을 분리한다. 본문 필드가 상태를 덮지 않는다.
// - ACK 확정: HTTP 200 ∧ protocol==1 ∧ request_id ∧ results ∧ 보낸 event_id ∧ 중복 없음 ∧ durable==true ∧ 허용 상태 ∧ receipt_id(UUID).
// - 오류 분류: offline / rate_limited / server_busy / invalid_ack / auth_required / consent_rejected / connection_rejected /
//   request_too_large / payload_invalid / request_rejected. 오류 envelope 가 없는 4xx 는 payload 오류로 보지 않는다.
// - 대기: 로컬 백오프 min(300, 5·2^(n-1))·(0.5+0.5u), 서버 지시(Retry-After 초·HTTP-date, 본문 retry_after_seconds)는 최댓값,
//   실제 대기 = max(서버 지시, 로컬 백오프). HTTP-date 는 응답 Date 헤더 기준. 24시간 초과 지시는 24시간(비정상 값 방어, 유일한 예외).
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math' as math;

const double backoffBaseSeconds = 5;
const double backoffCapSeconds = 300;
const int serverHintCapSeconds = 24 * 3600;

const Set<String> durableStatuses = {'accepted', 'duplicate', 'no_change', 'stale_ignored', 'quarantined'};
const Set<String> nonDurableStatuses = {'rejected', 'conflict'};
const Set<String> projections = {'published', 'removed', 'held', 'not_public', 'not_applicable'};
final RegExp _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// 영수증이 UUID 형식인가(ACK 판정·옛 완료 재확인이 같은 규칙을 쓴다).
bool isReceiptUuid(Object? value) => value is String && _uuid.hasMatch(value);

/// 오류 분류 → 전송 제어 범위. 없으면 제어기를 건드리지 않는다(행 상태만).
const Map<String, String> retryableClasses = {
  'offline': 'service',
  'server_busy': 'service',
  'invalid_ack': 'service',
  'rate_limited': 'account',
  'request_rejected': 'service',
};
const Set<String> authCodes = {'auth_required', 'kakao_required', 'session_revoked'};
const Set<String> consentCodes = {'consent_missing', 'consent_revoked', 'consent_outdated', 'consent_grant_unknown'};
const Set<String> connectionCodes = {
  'connection_unknown', 'connection_revoked', 'connection_suspended', 'connection_session_mismatch',
  'connection_mode_mismatch', 'writer_superseded', 'contributor_suspended',
};
const Set<String> eventPayloadCodes = {'payload_hash_mismatch', 'event_type_mismatch'};
const Set<String> ambiguousPayloadCodes = {'invalid_request', 'schema_invalid'};
const Set<String> requestCodes = {'method_not_allowed', 'unsupported_media_type'};

/// n 번째 연속 실패(1부터)의 로컬 대기(초). u∈[0,1) 난수(테스트에서 주입). 지터 뒤에도 상한 300초.
double backoffSeconds(int n, double u) {
  final k = n < 1 ? 1 : n;
  final base = math.min(backoffCapSeconds, backoffBaseSeconds * math.pow(2, math.min(k - 1, 30)));
  final uu = u < 0 ? 0.0 : (u > 1 ? 1.0 : u);
  return base * (0.5 + 0.5 * uu);
}

/// 서버 지시보다 일찍 보내지 않고, 서버 지시를 로컬 상한으로 줄이지 않는다.
double retryDelaySeconds(int n, double u, int? hint) {
  final local = backoffSeconds(n, u);
  return (hint != null && hint > 0) ? math.max(local, hint.toDouble()) : local;
}

String? _header(Map<String, String>? headers, String name) {
  if (headers == null) return null;
  final wanted = name.toLowerCase();
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == wanted) return e.value;
  }
  return null;
}

DateTime? _httpDate(String text) {
  try {
    return HttpDate.parse(text.trim()).toUtc();
  } catch (_) {
    return null;
  }
}

/// 유효한 서버 지시(초) 중 최댓값. 과거·0·음수·파싱 불가는 무시, 24시간 초과는 24시간.
int? parseRetryAfter(Map<String, String>? headers, Object? body, DateTime now) {
  final hints = <int>[];
  final raw = _header(headers, 'Retry-After');
  if (raw != null) {
    final text = raw.trim();
    if (RegExp(r'^\d+$').hasMatch(text)) {
      final seconds = int.parse(text);
      if (seconds > 0) hints.add(seconds);
    } else if (text.isNotEmpty && !text.startsWith('-')) {
      final when = _httpDate(text);
      if (when != null) {
        final serverDate = _header(headers, 'Date');
        final base = (serverDate == null ? null : _httpDate(serverDate)) ?? now.toUtc();
        final seconds = when.difference(base).inSeconds;
        if (seconds > 0) hints.add(seconds);
      }
    }
  }
  if (body is Map && body['error'] is Map) {
    final value = (body['error'] as Map)['retry_after_seconds'];
    if (value is int && value >= 1) hints.add(value);
  }
  if (hints.isEmpty) return null;
  return math.min(hints.reduce(math.max), serverHintCapSeconds);
}

class EventOutcome {
  const EventOutcome({
    required this.eventId,
    required this.outcome,
    required this.status,
    this.receiptId,
    this.projectionStatus,
    this.errorCode,
  });

  final String eventId;
  final String outcome; // done | dead | blocked
  final String status;
  final String? receiptId;
  final String? projectionStatus;
  final String? errorCode;
}

class Interpretation {
  const Interpretation({
    required this.kind,
    this.httpStatus,
    this.requestId,
    this.events = const {},
    this.missing = const [],
    this.errorClass,
    this.code,
    this.scope,
    this.hint,
  });

  final String kind; // ack | error
  final int? httpStatus;
  final String? requestId;
  final Map<String, EventOutcome> events;
  final List<String> missing;
  final String? errorClass;
  final String? code;
  final String? scope;
  final int? hint;
}

Interpretation errorOf(String cls, int? status, {String? code, int? hint, String? requestId}) => Interpretation(
      kind: 'error',
      httpStatus: status,
      errorClass: cls,
      code: code ?? cls,
      scope: retryableClasses[cls],
      hint: hint,
      requestId: requestId,
    );

Object? _decode(List<int>? body) {
  if (body == null) return null;
  try {
    final text = utf8.decode(body);
    return text.trim().isEmpty ? null : jsonDecode(text);
  } catch (_) {
    return null;
  }
}

(String?, String?) _errorEnvelope(Object? obj) {
  if (obj is! Map || obj['error'] is! Map) return (null, null);
  final err = obj['error'] as Map;
  final code = err['code'];
  if (code is! String || code.isEmpty) return (null, null);
  final rid = err['request_id'];
  return (code, rid is String ? rid : null);
}

bool _validResult(Object? item) {
  if (item is! Map) return false;
  final eventId = item['event_id'];
  if (eventId is! String || eventId.isEmpty) return false;
  final status = item['status'];
  final durable = item['durable'];
  if (durable is! bool) return false;
  final projection = item['projection_status'];
  if (projection != null && !projections.contains(projection)) return false;
  if (durable) {
    final receipt = item['receipt_id'];
    return durableStatuses.contains(status) && receipt is String && _uuid.hasMatch(receipt);
  }
  final err = item['error'];
  return nonDurableStatuses.contains(status) && err is Map && err['code'] is String && err['retryable'] is bool;
}

/// HTTP 200 본문(이미 JSON 해석) 판정. 형식이 하나라도 틀리면 invalid_ack(보낸 행 전부 재시도).
Interpretation interpretAck(List<String> sentIds, Object? obj) {
  if (obj is! Map || obj['protocol'] != 1 || obj['request_id'] is! String || obj['results'] is! List) {
    return errorOf('invalid_ack', 200);
  }
  final requestId = obj['request_id'] as String;
  final sent = sentIds.toSet();
  final seen = <String>{};
  final events = <String, EventOutcome>{};
  for (final item in obj['results'] as List) {
    if (!_validResult(item)) return errorOf('invalid_ack', 200, requestId: requestId);
    final m = item as Map;
    final eventId = m['event_id'] as String;
    if (!sent.contains(eventId) || seen.contains(eventId)) {
      return errorOf('invalid_ack', 200, requestId: requestId);
    }
    seen.add(eventId);
    final status = m['status'] as String;
    final outcome = m['durable'] == true ? 'done' : (status == 'conflict' ? 'dead' : 'blocked');
    final err = m['error'] is Map ? m['error'] as Map : null;
    events[eventId] = EventOutcome(
      eventId: eventId,
      outcome: outcome,
      status: status,
      receiptId: m['receipt_id'] as String?,
      projectionStatus: m['projection_status'] as String?,
      errorCode: err?['code'] as String?,
    );
  }
  return Interpretation(
    kind: 'ack',
    httpStatus: 200,
    requestId: requestId,
    events: events,
    missing: [for (final id in sentIds) if (!seen.contains(id)) id],
  );
}

/// 전송 결과 판정. status=null 은 전송 계층 실패(연결·timeout).
Interpretation interpretResponse(
  List<String> sentIds,
  int? status,
  Map<String, String>? headers,
  List<int>? body,
  DateTime now,
) {
  if (status == null) return errorOf('offline', null);
  final obj = _decode(body);
  if (status == 200) return interpretAck(sentIds, obj);
  final hint = parseRetryAfter(headers, obj, now);
  final (code, requestId) = _errorEnvelope(obj);
  if (status == 429) {
    return errorOf('rate_limited', status, code: code ?? 'rate_limited', hint: hint, requestId: requestId);
  }
  if ((status == 405 || status == 415) && code == null) {
    return errorOf('request_rejected', status, code: status == 405 ? 'method_not_allowed' : 'unsupported_media_type');
  }
  if (status == 413) return errorOf('request_too_large', status, code: code ?? 'payload_too_large', requestId: requestId);
  if (status == 401) return errorOf('auth_required', status, code: code ?? 'auth_required', requestId: requestId);
  if (code != null) {
    if (authCodes.contains(code)) return errorOf('auth_required', status, code: code, requestId: requestId);
    if (consentCodes.contains(code)) return errorOf('consent_rejected', status, code: code, requestId: requestId);
    if (connectionCodes.contains(code)) return errorOf('connection_rejected', status, code: code, requestId: requestId);
    if (code == 'payload_too_large') return errorOf('request_too_large', status, code: code, requestId: requestId);
    if ((eventPayloadCodes.contains(code) || ambiguousPayloadCodes.contains(code)) && status >= 400 && status < 500) {
      return errorOf('payload_invalid', status, code: code, requestId: requestId);
    }
    if (requestCodes.contains(code)) return errorOf('request_rejected', status, code: code, requestId: requestId);
    if (code == 'rate_limited') return errorOf('rate_limited', status, code: code, hint: hint, requestId: requestId);
  }
  // 5xx, 오류 envelope 없는 4xx(HTML 404 등), 모르는 코드: 서버 이상 → 서비스 단위 재시도
  return errorOf('server_busy', status, code: code ?? 'http_$status', hint: hint, requestId: requestId);
}
