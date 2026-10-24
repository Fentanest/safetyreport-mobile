// 1회 전송(raw_backfill) 오류 분류·간격 (CLIENT-RULES 1절, PC `community_raw_backfill.classify_backfill_error` 와 같은 표).
//
// - 일시적(transient): 네트워크·시간 초과·공식 사이트 5xx/429·`result` 없는 응답·다른 작업의 잠금(sync_busy)·
//   로컬 DB 잠김·커뮤니티 서버 503 maintenance/5xx/429. 신고별 시도 횟수에 넣지 않고 run 을 paused 로 둔다.
// - 고정적(fixed): 파서 예외·저장/이벤트 만들기 실패·**분류 못 한 예외 전부**. 신고별 3회면 보류(hold).
// - 공식 로그인 문제(official_login_*)는 이 표 밖이다(BackfillPaused 로 따로 온다).
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show DatabaseException;

import '../services/standalone_auth_service.dart'
    show OfficialNetworkException, OfficialRateLimitedException;

import 'raw_backfill.dart' show BackfillPaused;

/// 1회 전송 안에서 "일시적"으로 확정한 사유를 싣는 예외(예: 상세 응답에 `result` 가 없음 → `no_result`).
class BackfillTransient implements Exception {
  BackfillTransient(this.reason);
  final String reason;
  @override
  String toString() => 'BackfillTransient($reason)';
}

/// 공식 사이트 API 가 던지는 일반 예외 문구(`상세 조회 실패 (id, 503)`, `목록 조회 실패 (429)`)의 HTTP 상태.
final _officialHttp = RegExp(r'조회 실패 \((?:[^,()]*, )?(\d{3})\)');

/// `StandaloneApiService._getWithRetry` 가 재시도를 다 쓴 네트워크 오류 문구.
const _officialNetwork = '네트워크 오류';

/// 일시적이면 사유 코드(진행 보고 `reason` 과 같은 값), 고정적이면 null.
String? transientBackfillReason(Object error) {
  if (error is BackfillTransient) return error.reason;
  if (error is BackfillPaused) {
    // sync_busy·list_* 등 이미 사유가 정해진 멈춤. 로그인 멈춤은 표 밖이지만 일시적으로 다룬다(횟수에 넣지 않음).
    return error.reason;
  }
  if (error is TimeoutException) return 'timeout';
  // 상세 API 의 네트워크 재시도 소진(2.5.2부터 문구 대신 타입으로 온다).
  if (error is OfficialNetworkException) return 'network';
  // 공식 사이트 요청 속도 제한(429)을 기다려도 풀리지 않았다 — 신고 탓이 아니다.
  if (error is OfficialRateLimitedException) return 'rate_limited';
  if (error is SocketException ||
      error is HandshakeException ||
      error is TlsException ||
      error is http.ClientException) {
    return 'network';
  }
  if (error is DatabaseException) {
    final text = error.toString().toLowerCase();
    // sqflite 에는 잠김 전용 판별이 없다 — SQLite 의 "database is locked"(SQLITE_BUSY, code 5) 문구로 본다.
    if (text.contains('database is locked') ||
        text.contains('(code 5)') ||
        text.contains('database_locked') ||
        text.contains('sqlite_busy')) {
      return 'db_locked';
    }
    return null;
  }
  // 파서·상태 예외는 같은 입력이면 같은 결과다(고정적).
  if (error is FormatException ||
      error is TypeError ||
      error is RangeError ||
      error is StateError) {
    return null;
  }
  final text = error.toString();
  final match = _officialHttp.firstMatch(text);
  if (match != null) {
    final status = int.parse(match.group(1)!);
    if (status == 429) return 'rate_limited';
    if (status >= 500 && status <= 599) return 'server_5xx';
    return null;
  }
  if (text.contains(_officialNetwork)) return 'network';
  if (text.toLowerCase().contains('database is locked')) return 'db_locked';
  return null;
}

/// 규칙 문서 1절의 분류 함수(`classify_backfill_error(exc) -> 'transient'|'fixed'`).
String classifyBackfillError(Object error) =>
    transientBackfillReason(error) == null ? 'fixed' : 'transient';

/// 연속 일시적 오류 횟수 → 다음 시도까지 초(1회 60 → 2회 300 → 3회 900 → 4회 이상 3600).
int transientBackoffSeconds(int consecutive) {
  if (consecutive <= 1) return 60;
  if (consecutive == 2) return 300;
  if (consecutive == 3) return 900;
  return 3600;
}

/// 보류 횟수 → 다음 자동 재시도까지 초(1 → 15분, 2 → 1시간, 3 → 6시간, 4 이상 → 24시간).
int holdBackoffSeconds(int holdCount) {
  if (holdCount <= 1) return 15 * 60;
  if (holdCount == 2) return 3600;
  if (holdCount == 3) return 6 * 3600;
  return 24 * 3600;
}

/// 처음 보류된 뒤 이 기간이 지나면 `stale=true`(지우지 않고 하루 1번 계속 시도).
const int holdStaleSeconds = 30 * 24 * 3600;

/// 공식 로그인 사유(1절 표 밖 — 지금 규칙 그대로 자기 간격을 쓴다).
const officialLoginReasons = {'official_login_required', 'official_login_retry'};
