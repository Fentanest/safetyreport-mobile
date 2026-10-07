import '../cloud_availability.dart';
// 커뮤니티 업로더 — 공통 업로드 제어 UC-1(contracts/upload-control, PC `services/community_uploader.py` 와 같은 규칙·같은 순서).
//
// requestCommunityUpload(trigger) 하나가 realtime/manual/midnight/recovery/rebuild/reshare 를 모두 처리한다.
// - Client·데모 모드·삭제 정리 대기·게이트(requireFresh 60) → 영속 전송 제어(upload_control: 서비스·계정 cooldown)
//   → lease(`upload`, 실행별 owner `run:<uuid>:<trigger>`)
// - manual/midnight/recovery 면 현재 context 의 미ACK journal 을 outbox 에 넣는다(영수증 없는 옛 완료 기록은 다시 확인받는다)
// - 신고마다 보낼 수 있는 가장 앞 revision 하나만 후보(뒤 revision 이 먼저 가지 않음), 요청당 ≤20건·envelope UTF-8 ≤256KiB·신고당 1건
// - 실제 HTTP 요청마다 그 요청의 이벤트만 attempt_count+1. 요청 전 lease heartbeat(소유권을 잃으면 멈춤), 요청 간격 ≥1.1초,
//   실행 예산(요청 25개·90초) — 남으면 more_pending(앱 제어기가 곧바로 다시 깨운다)
// - 응답은 UC-1 로 판정: durable ACK(+receipt)만 완료(journal 기록+outbox 삭제 한 트랜잭션), 누락 ACK 는 백오프,
//   형식 오류는 invalid_ack(재시도, dead_letter 아님), 일시 장애면 남은 배치를 보내지 않고 cooldown, 413·payload 오류는 배치 이분
// - 401 은 거절된 토큰으로 실제 강제 갱신 1회(isolate 간 잠금) → 재전송. 갱신 네트워크 실패는 offline, 갱신 토큰 폐기는 auth_required
// - upload_runs 는 요청을 보냈거나 조치가 필요한 실행만 기록(최근 500행·30일). 미전송 사본은 정리하지 않는다
//
// Client 모드·데모 모드에서는 어떤 업로드·등록도 하지 않는다.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../models/app_mode.dart';
import '../../services/community_auth_service.dart'
    show CommunityTokenResult, CommunityTokenStatus;
import '../capture/community_capture.dart';
import '../capture/reshare.dart';
import '../capture/server_completed.dart' show deletionCleanupPending;
import '../community_store.dart';
import 'community_ingest_client.dart';
import 'upload_policy.dart' as policy;

export '../../services/community_auth_service.dart'
    show CommunityTokenResult, CommunityTokenStatus;

/// T5 의 CommunityGate 를 주입받는 인터페이스 (테스트는 가짜).
abstract class CommunityGateCheck {
  /// 60초 이내 검증된 gate 상태면 true.
  Future<bool> requireFresh();

  /// 마지막 확인에서 막힌 게이트 상태(consent_required·kakao_reauth_required 등). 통과했거나 모르면 null.
  String? get blockedState;

  /// 403 수신·철회 감지 시 캐시 무효화.
  void invalidate(String reason);
}

/// Optional synchronous fence for a live foreground authentication owner.
abstract class CommunityGenerationFence {
  Object get generation;
}

abstract class CommunityScopeFence {
  String? get contributorFingerprint;
}

/// 토큰 공급 (CommunityAuthService.getAccessTokenResult, 테스트는 가짜).
abstract class CommunityTokenSource {
  /// [rejected]: 서버가 401 로 거절한 토큰. 주면 실제로 강제 갱신한다(같은 토큰을 다시 주지 않음).
  Future<CommunityTokenResult> getAccessTokenResult({String? rejected});
}

/// 앱 모드 공급 (ReportProvider/AppMode — 직접 의존하지 않기 위해 주입).
typedef CommunityAppModeSource = Future<AppMode> Function();

const int maxEventsPerRequest = 20;
const int maxBodyBytes = 256 * 1024;
const Duration uploadLeaseDuration = Duration(seconds: 120);
const int runMaxRequests = 25;
const Duration runMaxDuration = Duration(seconds: 90);
const Duration minRequestInterval = Duration(milliseconds: 1100);
const int pageRows = 200;
const int runsKeepRows = 500;
const Duration runsKeepAge = Duration(days: 30);

/// 기록하는 결과(요청을 보냈거나 사용자 조치가 필요한 것). no_pending·not_due·cooldown·busy_other_run 은 상태만 돌려준다.
const Set<String> _recordedWithoutRequests = {
  'needs_auth',
  'needs_consent',
  'blocked_gate',
  'failed',
};
const Set<String> _rerunTriggers = {
  'manual',
  'midnight',
  'recovery',
  'reshare',
};
const Set<String> _enqueueTriggers = {'manual', 'midnight', 'recovery'};

/// UC-1 영수증(UUID) 형식의 SQLite GLOB — upload_policy 의 UUID 규칙과 같다(PC `RECEIPT_GLOB`).
final String receiptGlob = [
  8,
  4,
  4,
  4,
  12,
].map((n) => '[0-9a-f]' * n).join('-');
const String _ctxFilter =
    ' AND j.project_namespace IS ? AND j.contributor_fingerprint IS ? AND j.connection_id IS ?'
    " AND j.consent_grant_id IS ? AND (j.blocked_reason IS NULL OR j.blocked_reason='')";

/// 실행 결과. [result] 는 UC-1 결과 코드(sent·partial·no_pending·not_due·cooldown·busy_other_run·needs_auth·
/// needs_consent·blocked_gate·failed·more_pending).
class UploadRunResult {
  const UploadRunResult({
    required this.runId,
    required this.result,
    this.counts = const {},
    this.errorCode,
    this.requestIds = const [],
    this.nextAttemptAt,
  });

  final String runId;
  final String result;
  final Map<String, int> counts;
  final String? errorCode;
  final List<String> requestIds;

  /// cooldown 이면 다음 시도 가능 시각(UTC ISO).
  final String? nextAttemptAt;
}

/// 지도 탭 패널용 상태(현재 context 계정 것만, UC-1 §1-7). 원문·토큰 없음. 시각은 UTC ISO.
class UploadStatus {
  const UploadStatus({
    required this.pending,
    required this.blocked,
    required this.deadLetter,
    required this.lastResult,
    required this.lastFinishedAt,
    required this.reshareCandidateCount,
    required this.lastProjection,
    this.states = const {},
    this.blockedReasons = const {},
    this.authRequired = 0,
    this.quarantined = 0,
    this.stored = 0,
    this.published = 0,
    this.oldestUnsentAt,
    this.nextRetryAt,
    this.lastCentralAckAt,
    this.controlState = 'ready',
    this.controlUntil,
    this.controlReason,
    this.lastRequest,
  });

  /// 대기+재시도 대기+전송 중.
  final int pending;
  final int blocked;
  final int deadLetter;
  final String? lastResult;
  final String? lastFinishedAt;
  final int reshareCandidateCount;

  /// 마지막 ACK 의 projection_status 요약 (패널 문구용).
  final String? lastProjection;
  final Map<String, int> states;
  final Map<String, int> blockedReasons;
  final int authRequired;
  final int quarantined;

  /// 중앙 저장 확인(durable ACK) 건수와 그 중 지도 반영(published) 건수.
  final int stored;
  final int published;
  final String? oldestUnsentAt;
  final String? nextRetryAt;
  final String? lastCentralAckAt;

  /// ready | cooling_down | probing.
  final String controlState;
  final String? controlUntil;
  final String? controlReason;

  /// 마지막 요청 id 앞 8자.
  final String? lastRequest;
}

class _Row {
  _Row(this.data);
  final Map<String, Object?> data;
  Map<String, Object?>? event;
  String? reason;
  String get eventId => data['event_id'] as String;
  String get reportId => data['source_report_id'] as String;
  int get attempts => (data['attempt_count'] as int?) ?? 0;
  set attempts(int v) => data['attempt_count'] = v;
}

class _RunState {
  String? errorCode;
  String? nextAttemptAt;
}

class _Drain {
  _Drain(this.owner);
  final String owner; // 이 실행의 lease owner — 보류 행 정리는 아직 내 것인 행만
  final List<List<_Row>> queue = []; // 이분한 배치(같은 event_id·payload 로 다시 보냄)
  bool succeeded = false; // 이번 실행에서 형식이 유효한 ACK 를 받았는가(= envelope·연결은 정상)
  final List<(_Row, String)> suspects =
      []; // 모호한 400/422 를 단건으로 받은 행(대조 요청 결과로 판정)
  bool singleNext = false;
}

class _Sent {
  const _Sent({this.token, this.httpStatus, this.notSent = false});
  final String? token;
  final int? httpStatus;
  final bool notSent;
}

/// 2026-09-28: status_correction 발급 중단 — 구버전이 적어 둔 미전송 잔여 행을 보내지 않고
/// blocked 로 보존한다(PC `block_superseded_corrections` 와 같은 규칙).
///
/// 대상: outbox 대기(pending/retry_wait/auth_required) 중 journal event_type='status_correction' 인 행 +
/// outbox 에 없고 미ACK 인 같은 event_type journal 행(journal blocked_reason 표시로 enqueue 제외).
/// 이미 전송돼 ACK 를 받은 행(역사 기록)은 건드리지 않는다. 반환=새로 차단한 outbox 행 수.
Future<int> blockSupersededCorrections({CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  return s.transaction((tx) async {
    final hit = await tx.rawQuery(
      "SELECT 1 FROM source_journal WHERE event_type='status_correction' AND ack_status IS NULL"
      " AND (blocked_reason IS NULL OR blocked_reason='') LIMIT 1",
    );
    if (hit.isEmpty) return 0;
    await tx.rawUpdate(
      "UPDATE source_journal SET blocked_reason='blocked:deprecated_status_correction'"
      " WHERE event_type='status_correction' AND ack_status IS NULL"
      " AND (blocked_reason IS NULL OR blocked_reason='')",
    );
    return await tx.rawUpdate(
      "UPDATE outbox SET state='blocked', last_error_code='deprecated_status_correction',"
      " lease_owner=NULL, lease_until=NULL WHERE state IN ('pending','retry_wait','auth_required')"
      " AND event_id IN (SELECT event_id FROM source_journal WHERE event_type='status_correction')",
    );
  });
}

class CommunityUploader {
  CommunityUploader({
    required this.gate,
    required this.tokens,
    required this.appMode,
    required this.supabaseUrl,
    required this.publishableKey,
    required this.clientVersion,
    http.Client? httpClient,
    Future<CommunityStore> Function()? openStore,
    Random? random,
    Future<bool> Function()? demoMode,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    int Function()? monotonicMs,
    this.onProgress,
    this.requestBudget = runMaxRequests,
    this.bodyLimit = maxBodyBytes,
  }) : _httpClient = httpClient,
       _openStore = openStore ?? (() => CommunityStore.open()),
       _random = random ?? Random.secure(),
       _demoMode = demoMode ?? (() async => false),
       _nowFn = now ?? (() => DateTime.now().toUtc()),
       _sleepFn =
           sleep ??
           ((d) => d > Duration.zero
               ? Future<void>.delayed(d)
               : Future<void>.value()),
       _monotonicFn = monotonicMs ?? _stopwatchMs;

  final CommunityGateCheck gate;
  final CommunityTokenSource tokens;
  final CommunityAppModeSource appMode;
  final String supabaseUrl;
  final String publishableKey;
  final String clientVersion;
  final void Function(String message)? onProgress;
  final http.Client? _httpClient;
  final Future<CommunityStore> Function() _openStore;
  final Random _random;
  final Future<bool> Function() _demoMode;
  final DateTime Function() _nowFn;
  final Future<void> Function(Duration) _sleepFn;
  final int Function() _monotonicFn;

  /// 실행 예산(요청 수)·envelope 한도. 테스트가 줄여 본다(PC 는 모듈 상수를 바꿔 끼운다).
  final int requestBudget;
  final int bodyLimit;

  static final Stopwatch _clock = Stopwatch()..start();
  static int _stopwatchMs() => _clock.elapsedMilliseconds;

  // 같은 isolate 의 동시 호출은 진행 중 실행에 합류한다(다른 isolate 는 lease 가 막는다).
  static Future<UploadRunResult>? _active;
  static int _runSeq = 0; // 이 isolate 에서 시작한 실행 수(합류 판단용)
  static int _activeSeq = 0;
  static String? _activeTrigger;

  DateTime _now() => _nowFn().toUtc();

  void _progress(String message) {
    try {
      onProgress?.call(message);
    } catch (_) {} // 로그 표시 실패가 영속 업로드를 막지 않게 한다.
  }

  String _backoffAt(int attempts, [int? hint]) {
    final seconds = policy.retryDelaySeconds(
      max(1, attempts),
      _random.nextDouble(),
      hint,
    );
    return isoUtc(_now().add(Duration(microseconds: (seconds * 1e6).round())));
  }

  // ── 공개 API ───────────────────────────────────────────────────────────────

  /// 업로드 1회 실행. 같은 isolate 의 동시 호출은 진행 중 실행에 합류한다. 합류한 호출이 manual/midnight/recovery/reshare 면
  /// 진행 중 실행이 끝난 뒤 자기 실행을 하고 그 결과를 돌려준다(enqueue 가 빠지지 않게, PC 와 같음).
  Future<UploadRunResult> requestCommunityUpload(String trigger) async {
    final arrived = _runSeq; // 내가 도착하기 전까지 시작된 실행 수
    final waits = _enqueueTriggers.contains(trigger);
    if (waits) _waitingEnqueue[trigger] = (_waitingEnqueue[trigger] ?? 0) + 1;
    try {
      return await _requestCommunityUpload(trigger, arrived);
    } finally {
      if (waits) _waitingEnqueue[trigger] = _waitingEnqueue[trigger]! - 1;
    }
  }

  /// 새 실행을 시작할 때: enqueue 가 필요한 호출이 기다리고 있으면 realtime 시작을 그 트리거로 올린다
  /// (realtime 이 연달아 먼저 시작해도 기다리는 manual/midnight/recovery 가 굶지 않는다 — PC `_effective_trigger` 와 같음).
  @visibleForTesting
  static String effectiveTrigger(String trigger) {
    if (_enqueueTriggers.contains(trigger) || trigger == 'reshare') {
      return trigger;
    }
    for (final waiting in const ['midnight', 'recovery', 'manual']) {
      if ((_waitingEnqueue[waiting] ?? 0) > 0) return waiting;
    }
    return trigger;
  }

  @visibleForTesting
  static final Map<String, int> waitingEnqueueForTest = _waitingEnqueue;
  static final Map<String, int> _waitingEnqueue = {};

  Future<UploadRunResult> _requestCommunityUpload(
    String requested,
    int arrived,
  ) async {
    var trigger = requested;
    while (true) {
      final active = _active;
      if (active == null) break;
      final activeSeq = _activeSeq;
      final activeTrigger = _activeTrigger;
      final joined = await active;
      // enqueue 가 필요한 호출은 **내가 도착한 뒤 시작한** 실행의 결과만 자기 것으로 쓴다(자정 key 를 앞선 실행의 결과로 끝내지 않게).
      // manual/midnight/recovery 는 그 실행도 enqueue 해야 하고, reshare 는 이미 outbox 에 넣었으므로 뒤에 시작한 어느 실행이든 된다.
      // 앞선 실행이면 다시 돌아 새 실행을 시작하거나 뒤에 시작한 실행에 합류한다 — 재귀·무한 대기 없음(PC 와 같음).
      if (!_rerunTriggers.contains(trigger)) return joined;
      if (activeSeq > arrived &&
          (trigger == 'reshare' || _enqueueTriggers.contains(activeTrigger))) {
        return joined;
      }
    }
    trigger = effectiveTrigger(trigger);
    final done = Completer<UploadRunResult>();
    _active = done.future;
    _activeSeq = ++_runSeq;
    _activeTrigger = trigger;
    final runId = newUuidV4(_random);
    UploadRunResult result;
    try {
      result = await _runUpload(runId, trigger);
    } catch (e) {
      result = UploadRunResult(
        runId: runId,
        result: 'failed',
        errorCode: e.runtimeType.toString(),
      );
      try {
        await _recordRun(await _openStore(), trigger, isoUtc(_now()), result);
      } catch (_) {}
    }
    _active = null;
    done.complete(result);
    return result;
  }

  /// 다음에 깨어날 시각: 신고별 가장 앞 대기 행의 next_retry_at 과 전송 제어 next_attempt_at 중 가장 이른 것.
  /// 전송 제어가 cooling_down 이면 그 시각 전에는 깨지 않는다. 보낼 것이 없으면 null.
  Future<DateTime?> nextDueAt() async {
    final store = await _openStore();
    final ctx = await store.activeContext();
    if (ctx == null) return null;
    final (control, waitUntil, _) = await _controlGate(store, _scopes(ctx));
    if (control == 'cooldown') return waitUntil;
    final rows = await store.db.rawQuery(
      "SELECT MIN(COALESCE(o.next_retry_at, '')) AS due FROM source_journal j JOIN outbox o ON o.event_id=j.event_id"
      ' JOIN (SELECT j2.source_report_id AS rid, MIN(j2.source_revision) AS rev FROM source_journal j2'
      " JOIN outbox o2 ON o2.event_id=j2.event_id WHERE o2.state IN ('pending','retry_wait','in_flight','auth_required')"
      '${_ctxFilter.replaceAll('j.', 'j2.')} GROUP BY j2.source_report_id) f'
      ' ON f.rid=j.source_report_id AND f.rev=j.source_revision'
      " WHERE o.state IN ('pending','retry_wait','auth_required')$_ctxFilter",
      [..._ctxArgs(ctx), ..._ctxArgs(ctx)],
    );
    final value = rows.isEmpty ? null : rows.first['due'] as String?;
    if (value == null) return null;
    return value.isEmpty ? _now() : DateTime.tryParse(value)?.toUtc();
  }

  /// 지도 탭 패널용 상태.
  Future<UploadStatus> uploadStatus() async {
    final store = await _openStore();
    final ctx = await store.activeContext();
    final fingerprint = ctx?['contributor_fingerprint'];
    final last = await store.db.rawQuery(
      'SELECT * FROM upload_runs ORDER BY started_at DESC LIMIT 1',
    );
    final states = {
      for (final s in [
        'pending',
        'retry_wait',
        'in_flight',
        'auth_required',
        'blocked',
        'dead_letter',
      ])
        s: 0,
    };
    final reasons = <String, int>{};
    String? oldest, nextRetry, lastAck, lastProjection;
    var quarantined = 0, stored = 0, published = 0;
    if (fingerprint != null) {
      for (final row in await store.db.rawQuery(
        'SELECT o.state AS s, COUNT(*) AS n FROM outbox o JOIN source_journal j ON j.event_id=o.event_id'
        ' WHERE j.contributor_fingerprint IS ? GROUP BY o.state',
        [fingerprint],
      )) {
        states[row['s'] as String] = row['n'] as int;
      }
      for (final row in await store.db.rawQuery(
        "SELECT COALESCE(j.blocked_reason, o.last_error_code, 'unknown') AS reason, COUNT(*) AS n"
        ' FROM outbox o JOIN source_journal j ON j.event_id=o.event_id'
        " WHERE o.state IN ('blocked','dead_letter') AND j.contributor_fingerprint IS ? GROUP BY reason",
        [fingerprint],
      )) {
        reasons[row['reason'] as String] = row['n'] as int;
      }
      final pendingRow = (await store.db.rawQuery(
        'SELECT MIN(j.captured_at) AS oldest, MIN(o.next_retry_at) AS next FROM outbox o JOIN source_journal j'
        " ON j.event_id=o.event_id WHERE o.state IN ('pending','retry_wait','in_flight','auth_required')"
        ' AND j.contributor_fingerprint IS ?',
        [fingerprint],
      )).first;
      oldest = pendingRow['oldest'] as String?;
      nextRetry = pendingRow['next'] as String?;
      final acked = (await store.db.rawQuery(
        "SELECT MAX(acked_at) AS last, SUM(ack_status='quarantined') AS q, SUM(ack_status IS NOT NULL) AS n,"
        " SUM(ack_status IS NOT NULL AND projection_status='published') AS p"
        ' FROM source_journal WHERE contributor_fingerprint IS ?',
        [fingerprint],
      )).first;
      lastAck = acked['last'] as String?;
      quarantined = (acked['q'] as int?) ?? 0;
      stored = (acked['n'] as int?) ?? 0;
      published = (acked['p'] as int?) ?? 0;
      final projection = await store.db.rawQuery(
        'SELECT projection_status FROM source_journal WHERE projection_status IS NOT NULL'
        ' AND contributor_fingerprint IS ? ORDER BY acked_at DESC LIMIT 1',
        [fingerprint],
      );
      lastProjection = projection.isEmpty
          ? null
          : projection.first['projection_status'] as String?;
    }
    var controlState = 'ready';
    String? controlUntil, controlReason;
    if (ctx != null) {
      final (mode, until, reason) = await _controlGate(store, _scopes(ctx));
      if (mode == 'cooldown') {
        controlState = 'cooling_down';
        controlUntil = until == null ? null : isoUtc(until);
        controlReason = reason;
      } else if (mode == 'probe') {
        controlState = 'probing';
      }
    }
    var reshare = 0;
    if (fingerprint != null) {
      try {
        reshare = await reshareCandidates(store: store);
      } catch (_) {}
    }
    String? lastRequest;
    if (last.isNotEmpty) {
      try {
        final ids =
            (jsonDecode(last.first['request_ids'] as String? ?? '[]') as List)
                .cast<Object?>();
        if (ids.isNotEmpty) {
          final id = '${ids.last}';
          lastRequest = id.length > 8 ? id.substring(0, 8) : id;
        }
      } catch (_) {}
    }
    return UploadStatus(
      pending:
          states['pending']! + states['retry_wait']! + states['in_flight']!,
      blocked: states['blocked']!,
      deadLetter: states['dead_letter']!,
      lastResult: last.isEmpty ? null : last.first['result'] as String?,
      lastFinishedAt: last.isEmpty
          ? null
          : last.first['finished_at'] as String?,
      reshareCandidateCount: reshare,
      lastProjection: lastProjection,
      states: states,
      blockedReasons: reasons,
      authRequired: states['auth_required']!,
      quarantined: quarantined,
      stored: stored,
      published: published,
      oldestUnsentAt: oldest,
      nextRetryAt: nextRetry,
      lastCentralAckAt: lastAck,
      controlState: controlState,
      controlUntil: controlUntil,
      controlReason: controlReason,
      lastRequest: lastRequest,
    );
  }

  /// 재동의·takeover 뒤 사용자가 명시적으로 요청한 reshare.
  Future<UploadRunResult> requestReshare() async {
    final store = await _openStore();
    if (await appMode() != AppMode.standalone || await _demoMode()) {
      return UploadRunResult(
        runId: newUuidV4(_random),
        result: 'blocked_gate',
        errorCode: 'client_mode',
      );
    }
    if (!await gate.requireFresh()) {
      return UploadRunResult(
        runId: newUuidV4(_random),
        result: _gateResult(gate.blockedState),
        errorCode: gate.blockedState ?? 'gate_not_fresh',
      );
    }
    final latest = await store.db.rawQuery('''
SELECT rl.source_report_id AS id FROM report_latest rl
JOIN source_journal j ON j.event_id = rl.event_id
WHERE j.eligible = 1 AND j.blocked_reason IS NULL
''');
    var issued = 0;
    for (final row in latest) {
      final id = await issueReshare(row['id'] as String, store: store);
      if (id != null) issued++;
    }
    if (issued == 0) {
      return UploadRunResult(
        runId: newUuidV4(_random),
        result: 'no_pending',
        counts: {'reshare_issued': 0},
      );
    }
    return requestCommunityUpload('reshare');
  }

  /// 삭제 성공 알림 뒤 (T5 카드가 호출).
  Future<void> onContributionsDeleted(DateTime deletedAt) async {
    final store = await _openStore();
    await _onDeleted(store, deletedAt);
  }

  // ── 실행 ───────────────────────────────────────────────────────────────────

  static String _gateResult(String? state) {
    final s = state ?? '';
    if (s.contains('consent') || s.contains('suspend')) return 'needs_consent';
    if (s.contains('kakao') || s.contains('session') || s.contains('auth')) {
      return 'needs_auth';
    }
    return 'blocked_gate';
  }

  Future<UploadRunResult> _runUpload(String runId, String trigger) async {
    final store = await _openStore();
    final started = isoUtc(_now());
    final counts = {
      'sent': 0,
      'acked': 0,
      'dead': 0,
      'blocked': 0,
      'retry': 0,
      'quarantined': 0,
      'requests': 0,
    };
    final requestIds = <String>[];
    final state = _RunState();

    Future<UploadRunResult> finish(String result) async {
      final out = UploadRunResult(
        runId: runId,
        result: result,
        counts: Map.of(counts),
        errorCode: state.errorCode,
        requestIds: List.of(requestIds),
        nextAttemptAt: state.nextAttemptAt,
      );
      await _recordRun(store, trigger, started, out);
      _progress(
        '결과 $result: 전송 ${counts['sent']}건, 확인 ${counts['acked']}건, 재시도 ${counts['retry']}건'
        '${state.errorCode == null ? '' : ' (${state.errorCode})'}',
      );
      return out;
    }

    if (await appMode() != AppMode.standalone || await _demoMode()) {
      state.errorCode = 'client_mode'; // 폰이 writer 가 아니다(Client·데모) — 기록하지 않는다
      return UploadRunResult(
        runId: runId,
        result: 'blocked_gate',
        errorCode: state.errorCode,
      );
    }
    // 삭제 뒤 로컬 차단이 끝나기 전에는 아무것도 보내지 않는다(Sol H-03, PC 와 같음).
    if (await deletionCleanupPending(store: store)) {
      state.errorCode = 'deletion_cleanup_pending';
      return finish('blocked_gate');
    }
    if (await CloudAvailability.shared?.coolingDown() ?? false) {
      state.errorCode = 'cloud_cooldown';
      state.nextAttemptAt = CloudAvailability.shared!.nextAttemptAt
          ?.toUtc()
          .toIso8601String();
      return finish('cooldown');
    }
    if (!await gate.requireFresh()) {
      state.errorCode = gate.blockedState ?? 'gate_not_fresh';
      return finish(_gateResult(gate.blockedState));
    }
    final ctx = await store.activeContext();
    if (ctx == null ||
        (gate is CommunityScopeFence &&
            (gate as CommunityScopeFence).contributorFingerprint !=
                ctx['contributor_fingerprint'])) {
      return finish('needs_auth');
    }
    if (gate is CommunityGenerationFence) {
      ctx['_gateGeneration'] = (gate as CommunityGenerationFence).generation;
    }
    final epoch = ctx['writer_epoch'];
    if (epoch is! int || epoch < 1) {
      state.errorCode = 'writer_epoch_missing'; // 지어낸 epoch 로 보내지 않는다
      return finish('blocked_gate');
    }
    final scopes = _scopes(ctx);
    final (control, waitUntil, lastError) = await _controlGate(store, scopes);
    if (control == 'cooldown') {
      state.errorCode = lastError;
      state.nextAttemptAt = waitUntil == null ? null : isoUtc(waitUntil);
      return finish('cooldown');
    }
    final owner = 'run:$runId:$trigger';
    if (!await store.acquireLease('upload', owner, uploadLeaseDuration)) {
      return finish('busy_other_run');
    }
    final client = CommunityIngestClient(
      supabaseUrl: supabaseUrl,
      publishableKey: publishableKey,
      httpClient: _httpClient,
      clientVersion: clientVersion,
    );
    try {
      final now = isoUtc(_now());
      // 죽은 실행이 남긴 in_flight(만료·빈 lease)만 되돌린다 — attempt 는 그대로
      await store.db.rawUpdate(
        "UPDATE outbox SET state='retry_wait', next_retry_at=?, lease_owner=NULL, lease_until=NULL"
        " WHERE state='in_flight' AND (lease_until IS NULL OR lease_until < ?)",
        [now, now],
      );
      // 잔여 status_correction 은 보내지 않는다(PC 와 같음).
      try {
        counts['blocked'] =
            counts['blocked']! + await blockSupersededCorrections(store: store);
      } catch (_) {}
      if (trigger == 'manual' ||
          trigger == 'midnight' ||
          trigger == 'recovery') {
        try {
          await _enqueueUnacked(store, trigger);
        } catch (_) {}
      }
      final probing = control == 'probe';
      if (probing) await _controlProbing(store, scopes);
      return await _drain(
        store,
        client,
        owner,
        trigger,
        ctx,
        scopes,
        probing,
        counts,
        requestIds,
        state,
        finish,
      );
    } finally {
      client.close();
      try {
        await store.releaseLease('upload', owner);
      } catch (_) {}
    }
  }

  Future<UploadRunResult> _drain(
    CommunityStore store,
    CommunityIngestClient client,
    String owner,
    String trigger,
    Map<String, Object?> ctx,
    Map<String, String> scopes,
    bool probing,
    Map<String, int> counts,
    List<String> requestIds,
    _RunState state,
    Future<UploadRunResult> Function(String) finish,
  ) async {
    final started = _monotonicFn();
    final run = _Drain(owner);
    final tried = <String>{}; // 이번 실행에서 결과가 정해진 행(다시 고르지 않음)
    var refreshed = false;
    var hadProblem = false;
    var budgetHit = false;
    int? lastRequestAt;
    while (true) {
      if (counts['requests']! >= requestBudget ||
          _monotonicFn() - started >= runMaxDuration.inMilliseconds) {
        budgetHit = true; // 남은 것은 앱 제어기가 곧바로 이어서(요청 간격은 다음 실행도 지킨다)
        break;
      }
      if (!await _sameScope(store, ctx)) {
        state.errorCode = 'scope_changed';
        return finish('blocked_gate');
      }
      List<_Row> batch;
      if (run.queue.isNotEmpty) {
        batch = run.queue.removeAt(0);
      } else {
        final rows = await _frontRows(
          store,
          ctx,
          isoUtc(_now()),
          pageRows,
          tried,
        );
        if (rows.isEmpty) break;
        final single = probing || run.singleNext;
        final (built, oversize) = await _buildBatch(
          store,
          rows,
          ctx,
          trigger,
          single ? 1 : maxEventsPerRequest,
        );
        batch = built;
        if (oversize.isNotEmpty) {
          for (final row in oversize) {
            await _deadLetter(store, [row], row.reason!);
            tried.add(row.eventId);
          }
          counts['dead'] = counts['dead']! + oversize.length;
          hadProblem = true;
        }
        if (batch.isEmpty) {
          if (oversize.isNotEmpty) continue;
          break;
        }
      }
      if (lastRequestAt != null) {
        final wait =
            minRequestInterval.inMilliseconds -
            (_monotonicFn() - lastRequestAt);
        if (wait > 0) await _sleepFn(Duration(milliseconds: wait));
      }
      if (!await store.renewLease('upload', owner, uploadLeaseDuration)) {
        state.errorCode = 'lease_lost'; // 요청 직전 heartbeat — 소유권을 잃었으면 보내지 않는다
        await _holdSuspects(store, run, state);
        return finish('busy_other_run');
      }
      var (sent, interp) = await _send(
        store,
        client,
        owner,
        batch,
        ctx,
        trigger,
        counts,
        requestIds,
      );
      lastRequestAt = _monotonicFn();
      if (interp.kind == 'error' &&
          interp.errorClass == 'auth_required' &&
          sent.httpStatus == 401 &&
          !refreshed &&
          sent.token != null) {
        refreshed = true;
        final rejected = sent.token!;
        final t = await tokens.getAccessTokenResult(rejected: rejected);
        final token = t.accessToken;
        if (t.status == CommunityTokenStatus.ok &&
            token != null &&
            token.isNotEmpty &&
            token != rejected) {
          // 재전송도 새 요청이다: 요청 간격을 지킨 뒤 요청 직전에 소유권 heartbeat
          final wait =
              minRequestInterval.inMilliseconds -
              (_monotonicFn() - lastRequestAt);
          if (wait > 0) await _sleepFn(Duration(milliseconds: wait));
          if (!await store.renewLease('upload', owner, uploadLeaseDuration)) {
            // 아직 내 것인 행만 되돌린다
            await store.transaction(
              (tx) =>
                  _retryRows(tx, batch, 'lease_lost', null, null, owner: owner),
            );
            state.errorCode = 'lease_lost';
            await _holdSuspects(store, run, state);
            return finish('busy_other_run');
          }
          (sent, interp) = await _send(
            store,
            client,
            owner,
            batch,
            ctx,
            trigger,
            counts,
            requestIds,
            token: token,
          );
          lastRequestAt = _monotonicFn();
        } else if (t.status == CommunityTokenStatus.temporarilyUnavailable) {
          interp = policy.errorOf('offline', null, code: 'auth_unavailable');
        } else {
          interp = policy.errorOf('auth_required', 401, code: 'auth_required');
        }
      }
      for (final row in batch) {
        tried.add(row.eventId);
      }
      if (interp.kind == 'ack') {
        await _applyAck(store, batch, interp, counts);
        _progress(
          '진행: 전송 ${counts['sent']}건, 확인 ${counts['acked']}건, 재시도 ${counts['retry']}건',
        );
        for (final scope in scopes.values) {
          await _controlMark(store, scope, ready: true);
        }
        probing = false;
        run.succeeded = true;
        run.singleNext = false;
        if (run.suspects.isNotEmpty) {
          // 같은 envelope 로 다른 이벤트가 저장됐다 → 앞서 거절된 단건은 그 이벤트 문제
          for (final (row, code) in run.suspects) {
            await _deadLetter(store, [row], code);
          }
          counts['dead'] = counts['dead']! + run.suspects.length;
          run.suspects.clear();
        }
        if (interp.missing.isNotEmpty ||
            counts['dead']! > 0 ||
            counts['blocked']! > 0) {
          hadProblem = true;
        }
        continue;
      }
      final outcome = await _applyError(
        store,
        batch,
        interp,
        scopes,
        counts,
        state,
        run,
      );
      _progress(
        '진행: 전송 ${counts['sent']}건, 확인 ${counts['acked']}건, 재시도 ${counts['retry']}건'
        '${state.errorCode == null ? '' : ' (${state.errorCode})'}',
      );
      if (outcome == 'continue') {
        continue; // 이분·대조는 문제가 아니다 — 최종 결과는 격리·차단·재시도 집계로 정한다
      }
      await _holdSuspects(store, run, state);
      return finish(outcome);
    }
    if (run.suspects.isNotEmpty) {
      // 대조할 다른 이벤트가 없었다 — 원인을 모르므로 버리지 않고 보류
      await _holdSuspects(store, run, state);
      return finish('failed');
    }
    if (counts['requests'] == 0 && counts['dead'] == 0) {
      return finish(
        await _sendableCount(store, ctx) > 0 ? 'not_due' : 'no_pending',
      );
    }
    final remaining = await _sendableCount(store, ctx);
    if (remaining > 0 &&
        (budgetHit ||
            (await _frontRows(
              store,
              ctx,
              isoUtc(_now()),
              1,
              const {},
            )).isNotEmpty)) {
      return finish('more_pending'); // 자정 key 를 끝났다고 적지 않는다
    }
    if (hadProblem ||
        counts['retry']! > 0 ||
        counts['dead']! > 0 ||
        counts['blocked']! > 0) {
      return finish('partial');
    }
    return finish(remaining == 0 ? 'sent' : 'not_due');
  }

  /// 실제 HTTP 요청 1회. 요청 전 토큰 확보(실패면 보내지 않음·attempt 미집계) → in_flight+attempt → 전송.
  Future<(_Sent, policy.Interpretation)> _send(
    CommunityStore store,
    CommunityIngestClient client,
    String owner,
    List<_Row> batch,
    Map<String, Object?> ctx,
    String trigger,
    Map<String, int> counts,
    List<String> requestIds, {
    String? token,
  }) async {
    if (token == null) {
      CommunityTokenResult t;
      try {
        t = await tokens.getAccessTokenResult();
      } catch (_) {
        t = const CommunityTokenResult(
          CommunityTokenStatus.temporarilyUnavailable,
        );
      }
      if (t.status != CommunityTokenStatus.ok ||
          (t.accessToken ?? '').isEmpty) {
        final offline = t.status == CommunityTokenStatus.temporarilyUnavailable;
        return (
          const _Sent(notSent: true),
          policy.errorOf(
            offline ? 'offline' : 'auth_required',
            null,
            code: offline
                ? 'auth_unavailable'
                : (t.status == CommunityTokenStatus.notConfigured
                      ? 'community_unconfigured'
                      : 'auth_required'),
          ),
        );
      }
      token = t.accessToken!;
    }
    final envelope = _envelope(ctx, trigger, [
      for (final row in batch) row.event!,
    ]);
    final body = utf8.encode(jsonEncode(envelope));
    if (body.length > bodyLimit) {
      return (
        const _Sent(notSent: true),
        policy.errorOf('request_too_large', null, code: 'payload_too_large'),
      );
    }
    if (!await _sameScope(store, ctx) ||
        !await _markInFlight(store, batch, owner, ctx)) {
      return (
        const _Sent(notSent: true),
        policy.errorOf('auth_required', null, code: 'scope_changed'),
      );
    }
    counts['requests'] = counts['requests']! + 1;
    counts['sent'] = counts['sent']! + batch.length;
    final transport = await client.postEnvelopeBytes(token, body);
    final interp = policy.interpretResponse(
      [for (final row in batch) row.eventId],
      transport.status,
      transport.headers,
      transport.body,
      _now(),
    );
    if (interp.requestId != null && interp.requestId!.isNotEmpty) {
      requestIds.add(interp.requestId!);
    }
    return (_Sent(token: token, httpStatus: transport.status), interp);
  }

  /// 요청 단위 오류 → 행 상태·전송 제어. 반환: 'continue'(이분·대조 계속) 또는 실행 결과 코드.
  Future<String> _applyError(
    CommunityStore store,
    List<_Row> batch,
    policy.Interpretation interp,
    Map<String, String> scopes,
    Map<String, int> counts,
    _RunState state,
    _Drain run,
  ) async {
    final cls = interp.errorClass!;
    final code = interp.code ?? cls;
    state.errorCode = code;
    if (cls == 'request_too_large' || cls == 'payload_invalid') {
      final ambiguous =
          cls == 'payload_invalid' &&
          policy.ambiguousPayloadCodes.contains(code);
      if (batch.length > 1) {
        // 같은 event_id·payload 로 반씩 다시(단건만 격리)
        final half = batch.length ~/ 2;
        await store.transaction((tx) async {
          for (final row in batch) {
            await tx.rawUpdate(
              "UPDATE outbox SET state='pending', lease_owner=NULL, lease_until=NULL WHERE event_id=?",
              [row.eventId],
            );
          }
        });
        run.queue.insert(0, batch.sublist(half));
        run.queue.insert(0, batch.sublist(0, half));
        return 'continue';
      }
      if (ambiguous && !run.succeeded) {
        // 단건 schema_invalid/invalid_request 인데 이번 실행에서 정상 저장된 것이 없다 → envelope 공통 문제일 수 있다.
        run.suspects.add((batch.first, code));
        if (run.suspects.length >= 2) {
          return 'failed'; // 다른 이벤트도 같은 거절 → 공통 문제: 버리지 않고 모두 보류(_holdSuspects)
        }
        run.singleNext = true; // 다음 이벤트 하나로 대조
        return 'continue';
      }
      await _deadLetter(
        store,
        batch,
        cls == 'payload_invalid' ? code : 'payload_too_large',
      );
      counts['dead'] = counts['dead']! + batch.length;
      return 'continue';
    }
    final scopeKind = policy.retryableClasses[cls];
    if (scopeKind != null) {
      await store.transaction(
        (tx) => _retryRows(tx, batch, code, interp.hint, interp.requestId),
      );
      counts['retry'] = counts['retry']! + batch.length;
      final until = await _controlMark(
        store,
        scopes[scopeKind]!,
        errorCode: code,
        hint: interp.hint,
      );
      state.nextAttemptAt = until == null ? null : isoUtc(until);
      return cls == 'request_rejected'
          ? 'failed'
          : 'cooldown'; // 남은 배치는 보내지 않는다
    }
    if (cls == 'auth_required') {
      await store.transaction((tx) async {
        for (final row in batch) {
          await tx.rawUpdate(
            "UPDATE outbox SET state='auth_required', last_error_code=?, next_retry_at=?,"
            ' lease_owner=NULL, lease_until=NULL WHERE event_id=?',
            [
              code,
              _backoffAt(row.attempts == 0 ? 1 : row.attempts),
              row.eventId,
            ],
          );
        }
      });
      counts['retry'] = counts['retry']! + batch.length;
      gate.invalidate(code);
      return 'needs_auth';
    }
    // consent_rejected / connection_rejected: 명시적 거절 → blocked(보존), 게이트 무효화
    await store.transaction((tx) async {
      for (final row in batch) {
        await tx.rawUpdate(
          "UPDATE outbox SET state='blocked', last_error_code=?, lease_owner=NULL, lease_until=NULL WHERE event_id=?",
          [code, row.eventId],
        );
        await tx.rawUpdate(
          'UPDATE source_journal SET blocked_reason=? WHERE event_id=?',
          ['blocked:$code', row.eventId],
        );
      }
    });
    counts['blocked'] = counts['blocked']! + batch.length;
    gate.invalidate(code);
    return cls == 'consent_rejected' ? 'needs_consent' : 'blocked_gate';
  }

  /// 모호한 400/422 단건들: 원인이 envelope(공통)인지 이벤트인지 모르면 버리지 않고 백오프로 보류한다.
  /// 아직 이 실행이 잡고 있는 in_flight 행만 바꾼다(lease 를 잃은 뒤 새 실행이 회수한 행을 덮지 않게).
  Future<void> _holdSuspects(
    CommunityStore store,
    _Drain run,
    _RunState state,
  ) async {
    if (run.suspects.isEmpty) return;
    await store.transaction((tx) async {
      for (final (row, code) in run.suspects) {
        await tx.rawUpdate(
          "UPDATE outbox SET state='retry_wait', next_retry_at=?, last_error_code=?, lease_owner=NULL,"
          " lease_until=NULL WHERE event_id=? AND state='in_flight' AND lease_owner=?",
          [
            _backoffAt(row.attempts == 0 ? 1 : row.attempts),
            code,
            row.eventId,
            run.owner,
          ],
        );
      }
    });
    state.errorCode ??= run.suspects.first.$2;
    run.suspects.clear();
  }

  // ── 영속 전송 제어(UC-1 §1-4) ─────────────────────────────────────────────

  Map<String, String> _scopes(Map<String, Object?> ctx) {
    final ns = projectNamespace(supabaseUrl);
    return {
      'service': 'service:$ns',
      'account': 'account:$ns:${ctx['contributor_fingerprint'] ?? '-'}',
    };
  }

  /// ('ready'|'probe'|'cooldown', 대기 끝 시각, 마지막 오류). cooling_down 이고 시각 전이면 cooldown.
  Future<(String, DateTime?, String?)> _controlGate(
    CommunityStore store,
    Map<String, String> scopes,
  ) async {
    var probe = false;
    DateTime? waitUntil;
    String? lastError;
    for (final scope in scopes.values) {
      final rows = await store.db.rawQuery(
        'SELECT * FROM upload_control WHERE scope=?',
        [scope],
      );
      if (rows.isEmpty || rows.first['state'] == 'ready') continue;
      final until = DateTime.tryParse(
        '${rows.first['next_attempt_at'] ?? ''}',
      )?.toUtc();
      if (until != null && until.isAfter(_now())) {
        if (waitUntil == null || until.isAfter(waitUntil)) {
          waitUntil = until;
          lastError = rows.first['last_error_code'] as String?;
        }
      } else {
        probe = true;
      }
    }
    if (waitUntil != null) return ('cooldown', waitUntil, lastError);
    return (probe ? 'probe' : 'ready', null, null);
  }

  /// 일시 장애면 cooling_down(연속 실패+1, next = now + max(서버 지시, 백오프)), [ready] 면 ready.
  Future<DateTime?> _controlMark(
    CommunityStore store,
    String scope, {
    bool ready = false,
    String? errorCode,
    int? hint,
  }) async {
    final now = _now();
    return store.transaction((tx) async {
      final rows = await tx.rawQuery(
        'SELECT consecutive_failures FROM upload_control WHERE scope=?',
        [scope],
      );
      final failures = rows.isEmpty
          ? 0
          : (rows.first['consecutive_failures'] as int? ?? 0);
      // SQLite 3.9+ (Android 7+): insert/update in this same write transaction.
      // Do not REPLACE: preserve the existing row and its update semantics.
      Future<void> save(Map<String, Object?> values) async {
        if (rows.isEmpty) {
          await tx.insert('upload_control', {'scope': scope, ...values});
        } else {
          await tx.update(
            'upload_control',
            values,
            where: 'scope=?',
            whereArgs: [scope],
          );
        }
      }

      if (ready) {
        await save({
          'state': 'ready',
          'next_attempt_at': null,
          'consecutive_failures': 0,
          'last_error_code': null,
          'updated_at': isoUtc(now),
        });
        return null;
      }
      final next = failures + 1;
      final seconds = policy.retryDelaySeconds(
        next,
        _random.nextDouble(),
        hint,
      );
      final until = now.add(Duration(microseconds: (seconds * 1e6).round()));
      await save({
        'state': 'cooling_down',
        'next_attempt_at': isoUtc(until),
        'consecutive_failures': next,
        'last_error_code': errorCode,
        'updated_at': isoUtc(now),
      });
      return until;
    });
  }

  Future<void> _controlProbing(
    CommunityStore store,
    Map<String, String> scopes,
  ) => store.transaction((tx) async {
    for (final scope in scopes.values) {
      await tx.rawUpdate(
        "UPDATE upload_control SET state='probing', updated_at=? WHERE scope=? AND state='cooling_down'",
        [isoUtc(_now()), scope],
      );
    }
  });

  // ── enqueue ────────────────────────────────────────────────────────────────

  /// manual/midnight/recovery: 현재 context 의 미ACK journal → outbox.
  Future<void> _enqueueUnacked(CommunityStore store, String trigger) async {
    final context = await store.activeContext();
    if (context == null) return;
    final namespace = projectNamespace(supabaseUrl);
    final at = isoUtc(_now());
    await store.transaction((tx) async {
      // 예전 코드가 durable 확인 없이 완료로 적은 행(영수증 없음·형식 틀림)은 같은 event_id 로 다시 확인받는다(UC-1 — 중앙은
      // duplicate 로 영수증을 돌려준다). 현재 연결·동의의 것만(PC 와 같음).
      // UC-1 과 같은 UUID 판정(소문자 16진 8-4-4-4-12, 길이만 보지 않는다)을 SQL GLOB 한 문장으로 — 이력을 메모리로 읽지 않는다
      await tx.rawUpdate(
        'UPDATE source_journal SET ack_status=NULL, receipt_id=NULL, acked_at=NULL, projection_status=NULL'
        " WHERE ack_status IN ('accepted','duplicate','no_change','stale_ignored','quarantined')"
        ' AND (receipt_id IS NULL OR receipt_id NOT GLOB ?)'
        ' AND contributor_fingerprint IS ? AND connection_id IS ? AND consent_grant_id IS ?',
        [
          receiptGlob,
          context['contributor_fingerprint'],
          context['connection_id'],
          context['consent_grant_id'],
        ],
      );
      // durable ACK 를 받은 journal 은 다시 보내지 않는다(PC 와 같은 조건 — 2026-09-26 감사 SOL-01).
      // 예전 버전이 ACK 뒤에 다시 만든 대기 행은 정리한다.
      await tx.rawDelete('''
DELETE FROM outbox WHERE state IN ('pending','retry_wait') AND event_id IN (
SELECT event_id FROM source_journal WHERE ack_status IS NOT NULL)
''');
      final rows = await tx.rawQuery(
        '''
SELECT j.event_id AS event_id FROM source_journal j
LEFT JOIN outbox o ON o.event_id = j.event_id
WHERE o.event_id IS NULL AND j.ack_status IS NULL AND j.blocked_reason IS NULL
AND j.project_namespace = ? AND j.contributor_fingerprint = ?
AND j.connection_id = ? AND j.consent_grant_id = ?
''',
        [
          namespace,
          context['contributor_fingerprint'],
          context['connection_id'],
          context['consent_grant_id'],
        ],
      );
      for (final row in rows) {
        await tx.insert('outbox', {
          'event_id': row['event_id'],
          'state': 'pending',
          'attempt_count': 0,
          'enqueued_trigger': trigger,
          'enqueued_at': at,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      // 현재 context 와 다른 귀속의 대기 행은 보존·표시한다.
      await tx.rawUpdate(
        '''
UPDATE outbox SET state='blocked', last_error_code='context_mismatch'
WHERE state IN ('pending','retry_wait') AND event_id IN (
SELECT j.event_id FROM source_journal j WHERE
j.project_namespace != ? OR j.contributor_fingerprint IS NOT ?
OR j.connection_id IS NOT ? OR j.consent_grant_id IS NOT ?)
''',
        [
          namespace,
          context['contributor_fingerprint'],
          context['connection_id'],
          context['consent_grant_id'],
        ],
      );
    });
  }

  // ── 후보 선택 ──────────────────────────────────────────────────────────────

  List<Object?> _ctxArgs(Map<String, Object?> ctx) => [
    projectNamespace(supabaseUrl),
    ctx['contributor_fingerprint'],
    ctx['connection_id'],
    ctx['consent_grant_id'],
  ];

  /// 신고마다 보낼 수 있는 가장 앞 revision 하나(그 행이 due 일 때만). 앞 revision 이 대기 중이면 그 신고는 건너뛴다.
  Future<List<_Row>> _frontRows(
    CommunityStore store,
    Map<String, Object?> ctx,
    String now,
    int limit,
    Set<String> exclude,
  ) async {
    final rows = await store.db.rawQuery(
      'SELECT o.event_id, o.attempt_count, o.state, j.source_report_id, j.source_revision, j.event_type, j.captured_at,'
      ' j.payload_sha256, j.eligible, j.writer_epoch, j.report_number FROM source_journal j JOIN outbox o ON o.event_id=j.event_id'
      ' JOIN (SELECT j2.source_report_id AS rid, MIN(j2.source_revision) AS rev FROM source_journal j2'
      " JOIN outbox o2 ON o2.event_id=j2.event_id WHERE o2.state IN ('pending','retry_wait','in_flight','auth_required')"
      '${_ctxFilter.replaceAll('j.', 'j2.')} GROUP BY j2.source_report_id) f'
      ' ON f.rid=j.source_report_id AND f.rev=j.source_revision'
      " WHERE o.state IN ('pending','retry_wait','auth_required') AND (o.next_retry_at IS NULL OR o.next_retry_at <= ?)"
      '$_ctxFilter ORDER BY j.source_revision ASC LIMIT ?',
      [..._ctxArgs(ctx), now, ..._ctxArgs(ctx), limit + exclude.length],
    );
    return [
      for (final r in rows)
        if (!exclude.contains(r['event_id']))
          _Row(Map<String, Object?>.from(r)),
    ].take(limit).toList();
  }

  Future<int> _sendableCount(
    CommunityStore store,
    Map<String, Object?> ctx,
  ) async {
    final rows = await store.db.rawQuery(
      'SELECT COUNT(*) AS n FROM outbox o JOIN source_journal j ON j.event_id=o.event_id'
      " WHERE o.state IN ('pending','retry_wait','in_flight','auth_required')$_ctxFilter",
      _ctxArgs(ctx),
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 저장된 불변 필드를 그대로 쓴다(event_id·event_type·revision·writer_epoch·captured_at·payload·sha).
  /// 중앙은 같은 event_id 의 재전송에서 이 값들이 다르면 conflict 로 본다 — 현재 context 의 epoch 로 바꾸지 않는다.
  Map<String, Object?> _event(_Row row, String payloadJson) => {
    'event_id': row.eventId,
    'event_type': row.data['event_type'],
    'source_system': 'safetyreport',
    'source_report_id': row.reportId,
    'report_number': row.data['report_number'],
    'source_revision': row.data['source_revision'],
    'writer_epoch': row.data['writer_epoch'],
    'captured_at': row.data['captured_at'],
    'payload': jsonDecode(payloadJson),
    'payload_sha256': row.data['payload_sha256'],
  };

  Map<String, Object?> _envelope(
    Map<String, Object?> ctx,
    String trigger,
    List<Map<String, Object?>> events,
  ) => {
    'protocol': 1,
    'contract': 'community-ingest-v1',
    'source_app': 'safetyreport-mobile',
    'source_mode': 'standalone',
    'connection_id': ctx['connection_id'],
    'consent_grant_id': ctx['consent_grant_id'],
    'policy_version': ctx['policy_version'],
    'client_version': clientVersion,
    'parser_version': mobileParserVersion,
    'trigger': events.any((e) => e['event_type'] == 'reshare')
        ? 'reshare'
        : const {
            'realtime',
            'manual',
            'midnight',
            'recovery',
            'rebuild',
            'reshare',
          }.contains(trigger)
        ? trigger
        : 'manual',
    'events': events,
  };

  /// (배치, 단건 초과·읽을 수 없음으로 격리한 행). envelope 전체 UTF-8 바이트를 정확히 계산한다(빈 envelope + 이벤트 + 쉼표).
  Future<(List<_Row>, List<_Row>)> _buildBatch(
    CommunityStore store,
    List<_Row> rows,
    Map<String, Object?> ctx,
    String trigger,
    int maxEvents,
  ) async {
    final base = utf8
        .encode(jsonEncode(_envelope(ctx, trigger, const [])))
        .length;
    final batch = <_Row>[];
    final oversize = <_Row>[];
    var total = base;
    final reports = <String>{};
    for (final row in rows) {
      if (batch.length >= maxEvents) break;
      if (reports.contains(row.reportId)) continue;
      final found = await store.db.rawQuery(
        'SELECT payload_json FROM source_journal WHERE event_id=?',
        [row.eventId],
      );
      if (found.isEmpty) continue;
      final epoch = row.data['writer_epoch'];
      if (epoch is! int || epoch < 1) {
        oversize.add(
          row..reason = 'writer_epoch_missing',
        ); // 지어낸 epoch 로 보내지 않는다
        continue;
      }
      final Map<String, Object?> event;
      try {
        event = _event(row, found.first['payload_json'] as String);
      } catch (_) {
        oversize.add(row..reason = 'payload_unreadable');
        continue;
      }
      final size = utf8.encode(jsonEncode(event)).length;
      if (base + size > bodyLimit) {
        oversize.add(row..reason = 'payload_too_large');
        continue;
      }
      final extra = size + (batch.isEmpty ? 0 : 1);
      if (total + extra > bodyLimit) continue;
      row.event = event;
      batch.add(row);
      reports.add(row.reportId);
      total += extra;
    }
    return (batch, oversize);
  }

  /// 테스트용: (빈 envelope 바이트, 이벤트별 바이트) — 실제로 보내는 직렬화와 같은 계산.
  @visibleForTesting
  Future<(int, List<int>)> measure(
    List<String> eventIds,
    String trigger,
  ) async {
    final store = await _openStore();
    final ctx = (await store.activeContext())!;
    final base = utf8
        .encode(jsonEncode(_envelope(ctx, trigger, const [])))
        .length;
    final sizes = <int>[];
    for (final id in eventIds) {
      final rows = await store.db.rawQuery(
        'SELECT j.*, o.attempt_count FROM source_journal j JOIN outbox o ON o.event_id=j.event_id WHERE j.event_id=?',
        [id],
      );
      final row = _Row(Map<String, Object?>.from(rows.first));
      sizes.add(
        utf8
            .encode(
              jsonEncode(_event(row, rows.first['payload_json'] as String)),
            )
            .length,
      );
    }
    return (base, sizes);
  }

  // ── 결과 적용 ──────────────────────────────────────────────────────────────

  Future<void> _deadLetter(
    CommunityStore store,
    List<_Row> rows,
    String code,
  ) => store.transaction((tx) async {
    for (final row in rows) {
      await tx.rawUpdate(
        "UPDATE outbox SET state='dead_letter', last_error_code=?, lease_owner=NULL, lease_until=NULL"
        ' WHERE event_id=?',
        [code, row.eventId],
      );
    }
  });

  /// 실제 HTTP 요청 직전: 이 요청의 이벤트만 attempt_count+1(UC-1 §1-3).
  static const _scopeFields = [
    'connection_id',
    'dataset_key',
    'writer_epoch',
    'contributor_fingerprint',
    'consent_grant_id',
  ];

  bool _sameGeneration(Map<String, Object?> ctx) =>
      (gate is! CommunityGenerationFence ||
          (gate as CommunityGenerationFence).generation ==
              ctx['_gateGeneration']) &&
      (gate is! CommunityScopeFence ||
          (gate as CommunityScopeFence).contributorFingerprint ==
              ctx['contributor_fingerprint']);

  Future<bool> _sameScope(
    CommunityStore store,
    Map<String, Object?> ctx,
  ) async {
    if (await appMode() != AppMode.standalone || await _demoMode()) {
      return false;
    }
    if (!await gate.requireFresh()) return false;
    final current = await store.activeContext();
    return _sameGeneration(ctx) &&
        current != null &&
        _scopeFields.every((key) => current[key] == ctx[key]);
  }

  Future<bool> _markInFlight(
    CommunityStore store,
    List<_Row> rows,
    String owner,
    Map<String, Object?> ctx,
  ) async {
    final until = isoUtc(_now().add(uploadLeaseDuration));
    try {
      await store.transaction((tx) async {
        final contexts = await tx.query(
          'context',
          where: 'id=1 AND state=?',
          whereArgs: ['active'],
        );
        final leases = await tx.query(
          'leases',
          where: 'name=? AND owner=? AND until>?',
          whereArgs: ['upload', owner, isoUtc(DateTime.now())],
        );
        if (!_sameGeneration(ctx) ||
            contexts.isEmpty ||
            leases.isEmpty ||
            !_scopeFields.every((key) => contexts.single[key] == ctx[key])) {
          throw StateError('scope_changed');
        }
        for (final row in rows) {
          final n = await tx.rawUpdate(
            "UPDATE outbox SET state='in_flight', attempt_count=attempt_count+1, lease_owner=?, lease_until=? WHERE event_id=? AND (state IN ('pending','retry_wait','auth_required') OR (state='in_flight' AND lease_owner=?)) AND event_id IN (SELECT event_id FROM source_journal WHERE source_revision=? AND acked_at IS NULL)",
            [owner, until, row.eventId, owner, row.data['source_revision']],
          );
          if (n != 1) throw StateError('outbox_claim_changed');
        }
      });
      for (final row in rows) {
        row.attempts = row.attempts + 1;
      }
      return true;
    } on StateError {
      return false;
    }
  }

  /// [owner] 를 주면 그 실행이 잡고 있는 in_flight 행만 바꾼다(lease 를 잃은 뒤 새 실행이 회수한 행을 덮지 않게).
  Future<void> _retryRows(
    Transaction tx,
    List<_Row> rows,
    String code,
    int? hint,
    String? requestId, {
    String? owner,
  }) async {
    final onlyMine = owner == null
        ? ''
        : " AND state='in_flight' AND lease_owner=?";
    for (final row in rows) {
      await tx.rawUpdate(
        "UPDATE outbox SET state='retry_wait', next_retry_at=?, last_error_code=?, last_request_id=COALESCE(?, last_request_id),"
        ' lease_owner=NULL, lease_until=NULL WHERE event_id=?$onlyMine',
        [
          _backoffAt(row.attempts == 0 ? 1 : row.attempts, hint),
          code,
          requestId,
          row.eventId,
          ?owner,
        ],
      );
    }
  }

  /// 확인된 이벤트: journal ack 기록 + outbox 삭제를 한 트랜잭션. 누락 ACK 는 백오프(같은 실행에서 다시 보내지 않음).
  Future<void> _applyAck(
    CommunityStore store,
    List<_Row> batch,
    policy.Interpretation interp,
    Map<String, int> counts,
  ) async {
    final now = isoUtc(_now());
    final byId = {for (final row in batch) row.eventId: row};
    await store.transaction((tx) async {
      for (final entry in interp.events.entries) {
        final eventId = entry.key;
        final ev = entry.value;
        if (ev.outcome == 'done') {
          await tx.rawDelete('DELETE FROM outbox WHERE event_id=?', [eventId]);
          await tx.rawUpdate(
            'UPDATE source_journal SET ack_status=?, receipt_id=?, acked_at=?, projection_status=? WHERE event_id=?',
            [ev.status, ev.receiptId, now, ev.projectionStatus, eventId],
          );
          final key = ev.status == 'quarantined' ? 'quarantined' : 'acked';
          counts[key] = counts[key]! + 1;
        } else if (ev.outcome == 'dead') {
          await tx.rawUpdate(
            "UPDATE outbox SET state='dead_letter', last_error_code=?, last_request_id=?,"
            ' lease_owner=NULL, lease_until=NULL WHERE event_id=?',
            [ev.errorCode ?? 'event_conflict', interp.requestId, eventId],
          );
          counts['dead'] = counts['dead']! + 1;
        } else {
          // rejected → blocked(보존)
          final code = ev.errorCode ?? 'rejected';
          await tx.rawUpdate(
            "UPDATE outbox SET state='blocked', last_error_code=?, last_request_id=?,"
            ' lease_owner=NULL, lease_until=NULL WHERE event_id=?',
            [code, interp.requestId, eventId],
          );
          await tx.rawUpdate(
            'UPDATE source_journal SET blocked_reason=? WHERE event_id=?',
            ['blocked:$code', eventId],
          );
          counts['blocked'] = counts['blocked']! + 1;
        }
        byId.remove(eventId);
      }
      final missing = [
        for (final id in interp.missing)
          if (byId[id] != null) byId[id]!,
      ];
      await _retryRows(tx, missing, 'ack_missing', null, interp.requestId);
      counts['retry'] = counts['retry']! + missing.length;
    });
  }

  /// 요청을 보냈거나 조치가 필요한 실행만 기록하고 오래된 기록을 정리한다(미전송 사본은 건드리지 않음).
  Future<void> _recordRun(
    CommunityStore store,
    String trigger,
    String started,
    UploadRunResult result,
  ) async {
    if (result.requestIds.isEmpty &&
        (result.counts['sent'] ?? 0) == 0 &&
        !_recordedWithoutRequests.contains(result.result)) {
      return;
    }
    final cutoff = isoUtc(_now().subtract(runsKeepAge));
    final fingerprint = (await store
        .activeContext())?['contributor_fingerprint'];
    await store.transaction((tx) async {
      await tx.insert('upload_runs', {
        'run_id': result.runId,
        'trigger': trigger,
        'contributor_fingerprint': fingerprint,
        'started_at': started,
        'finished_at': isoUtc(_now()),
        'result': result.result,
        'counts_json': jsonEncode(result.counts),
        'request_ids': jsonEncode(result.requestIds),
        'error_code': result.errorCode,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.rawDelete(
        'DELETE FROM upload_runs WHERE started_at < ? OR run_id NOT IN'
        ' (SELECT run_id FROM upload_runs ORDER BY started_at DESC LIMIT ?)',
        [cutoff, runsKeepRows],
      );
    });
  }
}

Future<void> _onDeleted(CommunityStore store, DateTime deletedAt) async {
  final at = isoUtc(deletedAt);
  await store.transaction((tx) async {
    await tx.rawUpdate(
      "UPDATE outbox SET state='blocked', last_error_code='deleted_by_user' "
      "WHERE state IN ('pending','in_flight','retry_wait','auth_required')",
    );
    await tx.rawUpdate(
      "UPDATE source_journal SET blocked_reason='deleted_by_user' "
      'WHERE captured_at < ? AND blocked_reason IS NULL',
      [at],
    );
    await tx.rawDelete('DELETE FROM server_completed');
  });
}

/// projection_status → 패널 문구.
String projectionMessage(String? projection) {
  switch (projection) {
    case 'published':
      return '지도 반영됨';
    case 'removed':
      return '지도에서 빠짐(정정)';
    case 'held':
      return '중앙 저장 완료·지도 반영 대기';
    case 'not_public':
      return '중앙 저장(지도 비표시: 날짜 없음/미완료)';
    case 'not_applicable':
      return '변경 없음';
    default:
      return '전송 대기';
  }
}
