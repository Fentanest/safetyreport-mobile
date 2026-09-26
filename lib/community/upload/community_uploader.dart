// 커뮤니티 업로더 (interfaces.md 모바일 절).
//
// requestCommunityUpload(trigger): 게이트 requireFresh(60s) → single-flight +
// community.db lease → (manual/midnight/recovery) 미ACK enqueue +
// location_supplement → drain(요청당 ≤20건·≤256KiB, 같은 신고는 한 요청에 하나) →
// 이벤트별 ACK 적용 → upload_runs 기록.
//
// 오류 분기(plan-final §8.2): 401 → 토큰 갱신 1회 후 재시도, 실패면 auth_required.
// 403(consent_*/connection_*/writer_superseded/contributor_suspended/
// session_revoked) → 해당 행 blocked + 게이트 무효화. conflict·rejected →
// dead_letter/blocked 보존. 400/413/422 → dead_letter. 429 → Retry-After.
// 5xx/timeout/503 busy → 지수 백오프(1s→최대 1h)+지터 ±20%.
// durable ACK(accepted/duplicate/no_change/stale_ignored/quarantined)만 outbox 삭제.
//
// Client 모드에서는 어떤 업로드·등록도 하지 않는다.
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../models/app_mode.dart';
import '../capture/community_capture.dart';
import '../capture/reshare.dart';
import '../capture/server_completed.dart' show deletionCleanupPending;
import '../community_store.dart';
import 'community_ingest_client.dart';

/// T5 의 CommunityGate 를 주입받는 인터페이스 (테스트는 가짜).
abstract class CommunityGateCheck {
  /// 60초 이내 검증된 gate 상태면 true.
  Future<bool> requireFresh();

  /// 403 수신·철회 감지 시 캐시 무효화.
  void invalidate(String reason);
}

/// 토큰 공급 (CommunityAuthService.getAccessToken, 테스트는 가짜).
abstract class CommunityTokenSource {
  Future<String?> getAccessToken();
}

/// 앱 모드 공급 (ReportProvider/AppMode — 직접 의존하지 않기 위해 주입).
typedef CommunityAppModeSource = Future<AppMode> Function();

class UploadRunResult {
  const UploadRunResult({
    required this.runId,
    required this.result,
    this.counts = const {},
    this.errorCode,
  });

  final String runId;
  final String result;
  final Map<String, int> counts;
  final String? errorCode;
}

class UploadStatus {
  const UploadStatus({
    required this.pending,
    required this.blocked,
    required this.deadLetter,
    required this.lastResult,
    required this.lastFinishedAt,
    required this.reshareCandidateCount,
    required this.lastProjection,
  });

  final int pending;
  final int blocked;
  final int deadLetter;
  final String? lastResult;
  final String? lastFinishedAt;
  final int reshareCandidateCount;

  /// 마지막 ACK 의 projection_status 요약 (패널 문구용).
  final String? lastProjection;
}

const Set<String> _durableAck = {
  'accepted',
  'duplicate',
  'no_change',
  'stale_ignored',
  'quarantined',
};

const Set<String> _gateInvalidating403 = {
  'kakao_required',
  'session_revoked',
  'consent_missing',
  'consent_revoked',
  'consent_outdated',
  'consent_grant_unknown',
  'connection_unknown',
  'connection_revoked',
  'connection_suspended',
  'connection_session_mismatch',
  'connection_mode_mismatch',
  'writer_superseded',
  'contributor_suspended',
};

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
  })  : _httpClient = httpClient,
        _openStore = openStore ?? (() => CommunityStore.open()),
        _random = random ?? Random.secure();

  final CommunityGateCheck gate;
  final CommunityTokenSource tokens;
  final CommunityAppModeSource appMode;
  final String supabaseUrl;
  final String publishableKey;
  final String clientVersion;
  final http.Client? _httpClient;
  final Future<CommunityStore> Function() _openStore;
  final Random _random;

  static bool _inFlight = false;

  /// 실시간 capture 뒤 호출 — 같은 프로세스에서 drain 을 깨운다.
  /// (모바일은 별도 wake 스레드 없이 다음 request 경로에서 처리한다.)
  void wake() {
    _wakePending = true;
  }

  static bool _wakePending = false;
  static bool get wakePending => _wakePending;
  static void clearWake() => _wakePending = false;

  Future<UploadRunResult> requestCommunityUpload(String trigger) async {
    final runId = newUuidV4(_random);
    final store = await _openStore();
    final startedAt = isoUtc(DateTime.now());

    Future<UploadRunResult> finish(String result,
        {Map<String, int> counts = const {}, String? errorCode}) async {
      await store.db.insert('upload_runs', {
        'run_id': runId,
        'trigger': trigger,
        'contributor_fingerprint': await _contextFingerprint(store),
        'started_at': startedAt,
        'finished_at': isoUtc(DateTime.now()),
        'result': result,
        'counts_json': jsonEncode(counts),
        'request_ids': jsonEncode(<String>[]),
        'error_code': errorCode,
      });
      return UploadRunResult(
          runId: runId, result: result, counts: counts, errorCode: errorCode);
    }

    if (await appMode() != AppMode.standalone) {
      return finish('no_change', counts: {'skipped_client_mode': 1});
    }
    // 삭제 뒤 로컬 차단이 끝나기 전에는 아무것도 보내지 않는다(Sol H-03, PC 와 같음).
    if (await deletionCleanupPending(store: store)) {
      return finish('deferred', errorCode: 'deletion_cleanup_pending');
    }
    if (!await gate.requireFresh()) {
      return finish('deferred', errorCode: 'gate_not_fresh');
    }
    if (_inFlight) {
      return finish('deferred', errorCode: 'already_running');
    }
    const owner = 'uploader';
    if (!await store.acquireLease(
        'upload', owner, const Duration(minutes: 5))) {
      return finish('deferred', errorCode: 'lease_busy');
    }
    _inFlight = true;
    try {
      if (trigger == 'manual' ||
          trigger == 'midnight' ||
          trigger == 'recovery') {
        await _enqueueUnacked(store, trigger);
      }
      final counts = await _drain(store, trigger);
      final result = _summarize(counts);
      return finish(result, counts: counts);
    } on _AuthRequired {
      return finish('auth_required', errorCode: 'auth_required');
    } on _Offline {
      return finish('offline', errorCode: 'offline');
    } catch (e) {
      return finish('failed', errorCode: '$e');
    } finally {
      _inFlight = false;
      _wakePending = false;
      await store.releaseLease('upload', owner);
    }
  }

  /// 지도 탭 패널용 상태.
  Future<UploadStatus> uploadStatus() async {
    final store = await _openStore();
    Future<int> count(String state) async {
      final rows = await store.db
          .rawQuery('SELECT COUNT(*) AS cnt FROM outbox WHERE state=?', [state]);
      return int.tryParse('${rows.first['cnt']}') ?? 0;
    }

    final pending = await count('pending') +
        await count('in_flight') +
        await count('retry_wait');
    final blocked = await count('blocked');
    final deadLetter = await count('dead_letter');
    final runs = await store.db.rawQuery(
      'SELECT result, finished_at FROM upload_runs ORDER BY started_at DESC LIMIT 1',
    );
    final acks = await store.db.rawQuery(
      'SELECT projection_status FROM source_journal WHERE projection_status IS NOT NULL '
      'ORDER BY acked_at DESC LIMIT 1',
    );
    var reshare = 0;
    try {
      reshare = await reshareCandidates(store: store);
    } catch (_) {}
    return UploadStatus(
      pending: pending,
      blocked: blocked,
      deadLetter: deadLetter,
      lastResult:
          runs.isEmpty ? null : runs.first['result']?.toString(),
      lastFinishedAt:
          runs.isEmpty ? null : runs.first['finished_at']?.toString(),
      reshareCandidateCount: reshare,
      lastProjection:
          acks.isEmpty ? null : acks.first['projection_status']?.toString(),
    );
  }

  /// 재동의·takeover 뒤 사용자가 명시적으로 요청한 reshare.
  Future<UploadRunResult> requestReshare() async {
    final store = await _openStore();
    if (await appMode() != AppMode.standalone) {
      return UploadRunResult(
          runId: newUuidV4(_random),
          result: 'no_change',
          counts: {'skipped_client_mode': 1});
    }
    if (!await gate.requireFresh()) {
      return UploadRunResult(
          runId: newUuidV4(_random),
          result: 'deferred',
          errorCode: 'gate_not_fresh');
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
          result: 'no_change',
          counts: {'reshare_issued': 0});
    }
    return requestCommunityUpload('reshare');
  }

  /// 삭제 성공 알림 뒤 (T5 카드가 호출).
  Future<void> onContributionsDeleted(DateTime deletedAt) async {
    final store = await _openStore();
    // capture 모듈의 동명 함수를 store 주입으로 호출한다.
    await _onDeleted(store, deletedAt);
  }

  // --- 내부 --------------------------------------------------------------

  Future<String?> _contextFingerprint(CommunityStore store) async {
    final c = await store.context();
    return c?['contributor_fingerprint']?.toString();
  }

  /// manual/midnight/recovery: 현재 context 의 미ACK journal → outbox.
  Future<void> _enqueueUnacked(CommunityStore store, String trigger) async {
    final context = await store.activeContext();
    if (context == null) return;
    final namespace =
        projectNamespace(supabaseUrl);
    final at = isoUtc(DateTime.now());
    // durable ACK 를 받은 journal 은 다시 보내지 않는다(PC 와 같은 조건 — 2026-09-26 감사 SOL-01).
    // 예전 버전이 ACK 뒤에 다시 만든 대기 행은 정리한다.
    await store.db.rawDelete('''
DELETE FROM outbox WHERE state IN ('pending','retry_wait') AND event_id IN (
SELECT event_id FROM source_journal WHERE ack_status IS NOT NULL)
''');
    final rows = await store.db.rawQuery('''
SELECT j.event_id AS event_id FROM source_journal j
LEFT JOIN outbox o ON o.event_id = j.event_id
WHERE o.event_id IS NULL AND j.ack_status IS NULL AND j.blocked_reason IS NULL
AND j.project_namespace = ? AND j.contributor_fingerprint = ?
AND j.connection_id = ? AND j.consent_grant_id = ?
''', [
      namespace,
      context['contributor_fingerprint'],
      context['connection_id'],
      context['consent_grant_id'],
    ]);
    for (final row in rows) {
      await store.db.insert('outbox', {
        'event_id': row['event_id'],
        'state': 'pending',
        'attempt_count': 0,
        'enqueued_trigger': trigger,
        'enqueued_at': at,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    // 현재 context 와 다른 귀속의 대기 행은 보존·표시한다.
    await store.db.rawUpdate('''
UPDATE outbox SET state='blocked', last_error_code='context_mismatch'
WHERE state IN ('pending','retry_wait') AND event_id IN (
SELECT j.event_id FROM source_journal j WHERE
j.project_namespace != ? OR j.contributor_fingerprint IS NOT ?
OR j.connection_id IS NOT ? OR j.consent_grant_id IS NOT ?)
''', [
      namespace,
      context['contributor_fingerprint'],
      context['connection_id'],
      context['consent_grant_id'],
    ]);
  }

  /// drain: context 일치 행만, 요청당 ≤20건·≤256KiB, 같은 신고는 한 요청에 하나.
  Future<Map<String, int>> _drain(CommunityStore store, String trigger) async {
    final counts = <String, int>{
      'sent': 0,
      'acked': 0,
      'dead_letter': 0,
      'blocked': 0,
      'retry_wait': 0,
    };
    while (true) {
      final context = await store.activeContext();
      if (context == null) break;
      final due = await store.db.rawQuery('''
SELECT j.* FROM source_journal j JOIN outbox o ON o.event_id = j.event_id
WHERE o.state IN ('pending','retry_wait')
AND (o.next_retry_at IS NULL OR o.next_retry_at <= ?)
AND j.project_namespace = ? AND j.contributor_fingerprint = ?
AND j.connection_id = ? AND j.consent_grant_id = ?
ORDER BY j.source_revision ASC LIMIT 60
''', [
        isoUtc(DateTime.now()),
        projectNamespace(supabaseUrl),
        context['contributor_fingerprint'],
        context['connection_id'],
        context['consent_grant_id'],
      ]);
      if (due.isEmpty) break;
      // 한 요청에 같은 신고 하나만 (revision 순서 유지).
      final batch = <Map<String, Object?>>[];
      final seenReports = <String>{};
      var sizeEstimate = 0;
      for (final row in due) {
        final reportId = row['source_report_id'] as String;
        if (seenReports.contains(reportId)) continue;
        final payload = row['payload_json'] as String;
        if (batch.length >= 20 ||
            sizeEstimate + payload.length > 256 * 1024) {
          break;
        }
        seenReports.add(reportId);
        batch.add(Map<String, Object?>.from(row));
        sizeEstimate += payload.length;
      }
      if (batch.isEmpty) break;
      final sent = await _sendBatch(store, context, batch, trigger, counts);
      if (!sent) break;
      if (batch.length < due.length) continue;
      // 다음 라운드에서 남은 행을 마저 보낸다.
      final remaining = await store.db.rawQuery(
          "SELECT COUNT(*) AS cnt FROM outbox WHERE state IN ('pending','retry_wait')");
      if ((int.tryParse('${remaining.first['cnt']}') ?? 0) == 0) break;
    }
    return counts;
  }

  /// 한 배치 전송. false = 더 진행하지 않는다(lease·gate 상실 등).
  Future<bool> _sendBatch(
    CommunityStore store,
    Map<String, Object?> context,
    List<Map<String, Object?>> batch,
    String trigger,
    Map<String, int> counts,
  ) async {
    final envelope = _buildEnvelope(context, batch, trigger);
    Map<String, Object?> res;
    try {
      res = await _postWithAuthRetry(envelope);
    } on _AuthRequired {
      for (final row in batch) {
        await _markOutbox(store, row['event_id'] as String, 'auth_required',
            'auth_required', counts);
      }
      rethrow;
    } on _Offline {
      for (final row in batch) {
        await _backoff(store, row, 'offline', null, counts);
      }
      throw _Offline();
    }
    final httpStatus = res['httpStatus'] as int? ?? 0;
    if (res.containsKey('results')) {
      final requestId = res['request_id']?.toString() ?? '';
      await _applyAcks(store, batch, res, requestId, counts);
      return true;
    }
    final error = res['error'];
    final code =
        error is Map ? error['code']?.toString() ?? '' : 'server_error';
    final retryable = error is Map && error['retryable'] == true;
    final retryAfter = error is Map
        ? int.tryParse('${error['retry_after_seconds'] ?? ''}')
        : null;
    if (httpStatus == 401) {
      for (final row in batch) {
        await _markOutbox(store, row['event_id'] as String, 'auth_required',
            'auth_required', counts);
      }
      throw _AuthRequired();
    }
    if (httpStatus == 403 || _gateInvalidating403.contains(code)) {
      gate.invalidate(code);
      for (final row in batch) {
        await _markOutbox(
            store, row['event_id'] as String, 'blocked', code, counts);
        await store.db.rawUpdate(
          'UPDATE source_journal SET blocked_reason=? WHERE event_id=?',
          [code, row['event_id']],
        );
      }
      counts['blocked'] = (counts['blocked'] ?? 0) + batch.length;
      return false;
    }
    if (httpStatus == 429 || code == 'rate_limited') {
      for (final row in batch) {
        await _backoff(store, row, 'rate_limited', retryAfter, counts);
      }
      return false;
    }
    if (httpStatus == 400 ||
        httpStatus == 413 ||
        httpStatus == 422 ||
        (!retryable && httpStatus >= 400 && httpStatus < 500)) {
      for (final row in batch) {
        await _markOutbox(store, row['event_id'] as String, 'dead_letter',
            code, counts);
      }
      counts['dead_letter'] = (counts['dead_letter'] ?? 0) + batch.length;
      return true;
    }
    // 5xx·busy·그 밖 — 백오프 후 다음 기회에.
    for (final row in batch) {
      await _backoff(store, row, code.isEmpty ? 'server_error' : code,
          retryAfter, counts);
    }
    return false;
  }

  Map<String, Object?> _buildEnvelope(
    Map<String, Object?> context,
    List<Map<String, Object?>> batch,
    String trigger,
  ) {
    return {
      'protocol': 1,
      'contract': 'community-ingest-v1',
      'source_app': 'safetyreport-mobile',
      'source_mode': 'standalone',
      'connection_id': context['connection_id'],
      'consent_grant_id': context['consent_grant_id'],
      'policy_version': context['policy_version'],
      'client_version': clientVersion,
      'parser_version': mobileParserVersion,
      'trigger': trigger,
      'events': [
        for (final row in batch)
          {
            'event_id': row['event_id'],
            'event_type': row['event_type'],
            'source_system': 'safetyreport',
            'source_report_id': row['source_report_id'],
            'source_revision': row['source_revision'],
            'writer_epoch': context['writer_epoch'],
            'captured_at': row['captured_at'],
            'payload': jsonDecode(row['payload_json'] as String),
            'payload_sha256': row['payload_sha256'],
          },
      ],
    };
  }

  Future<Map<String, Object?>> _postWithAuthRetry(
      Map<String, Object?> envelope) async {
    final client = CommunityIngestClient(
      supabaseUrl: supabaseUrl,
      publishableKey: publishableKey,
      httpClient: _httpClient,
      clientVersion: clientVersion,
    );
    var token = await tokens.getAccessToken();
    if (token == null || token.isEmpty) throw _AuthRequired();
    try {
      final res = await client.postIngest(token, envelope);
      if (res['httpStatus'] == 401) {
        token = await tokens.getAccessToken();
        if (token == null || token.isEmpty) throw _AuthRequired();
        final retry = await client.postIngest(token, envelope);
        if (retry['httpStatus'] == 401) throw _AuthRequired();
        return retry;
      }
      return res;
    } on CommunityIngestTransport {
      throw _Offline();
    }
  }

  Future<void> _applyAcks(
    CommunityStore store,
    List<Map<String, Object?>> batch,
    Map<String, Object?> res,
    String requestId,
    Map<String, int> counts,
  ) async {
    final results = res['results'];
    if (results is! List) return;
    final byId = <String, Map<String, Object?>>{};
    for (final row in batch) {
      byId[row['event_id'] as String] = row;
    }
    for (final item in results) {
      if (item is! Map) continue;
      final eventId = item['event_id']?.toString() ?? '';
      final status = item['status']?.toString() ?? '';
      final row = byId[eventId];
      if (row == null) continue;
      final error = item['error'];
      final errorCode =
          error is Map ? error['code']?.toString() ?? '' : '';
      final projection = item['projection_status']?.toString();
      final receipt = item['receipt_id']?.toString();
      final at = isoUtc(DateTime.now());
      counts['sent'] = (counts['sent'] ?? 0) + 1;
      if (_durableAck.contains(status)) {
        await store.transaction((tx) async {
          await tx.rawUpdate(
            'UPDATE source_journal SET ack_status=?, receipt_id=?, acked_at=?, '
            'projection_status=? WHERE event_id=?',
            [status, receipt, at, projection, eventId],
          );
          await tx.rawDelete('DELETE FROM outbox WHERE event_id=?', [eventId]);
        });
        counts['acked'] = (counts['acked'] ?? 0) + 1;
        if (status == 'quarantined') {
          // 확인 필요 표시 — outbox 는 정리, journal 에 상태 유지.
        }
        continue;
      }
      if (status == 'rejected') {
        await _markOutbox(store, eventId, 'blocked', errorCode, counts);
        await store.db.rawUpdate(
          'UPDATE source_journal SET blocked_reason=? WHERE event_id=?',
          [errorCode.isEmpty ? 'rejected' : errorCode, eventId],
        );
        counts['blocked'] = (counts['blocked'] ?? 0) + 1;
        continue;
      }
      if (status == 'conflict') {
        await _markOutbox(store, eventId, 'dead_letter',
            errorCode.isEmpty ? 'event_id_conflict' : errorCode, counts);
        counts['dead_letter'] = (counts['dead_letter'] ?? 0) + 1;
        continue;
      }
      await _backoff(store, row, errorCode.isEmpty ? 'unknown_ack' : errorCode,
          null, counts);
    }
  }

  Future<void> _markOutbox(CommunityStore store, String eventId, String state,
      String errorCode, Map<String, int> counts) async {
    await store.db.rawUpdate(
      'UPDATE outbox SET state=?, last_error_code=?, attempt_count=attempt_count+1 WHERE event_id=?',
      [state, errorCode, eventId],
    );
  }

  Future<void> _backoff(CommunityStore store, Map<String, Object?> row,
      String errorCode, int? retryAfterSeconds, Map<String, int> counts) async {
    final attempt = (row['attempt_count'] as int? ?? 0) + 1;
    Duration delay;
    if (retryAfterSeconds != null && retryAfterSeconds > 0) {
      delay = Duration(seconds: retryAfterSeconds);
    } else {
      final base = 1 << (attempt - 1 > 10 ? 10 : attempt - 1);
      final capped = base > 3600 ? 3600 : base;
      final jitter = ((_random.nextDouble() * 2 - 1) * 0.2 * capped).round();
      delay = Duration(seconds: capped + jitter);
    }
    await store.db.rawUpdate(
      'UPDATE outbox SET state=?, attempt_count=?, next_retry_at=?, '
      'last_error_code=? WHERE event_id=?',
      [
        'retry_wait',
        attempt,
        isoUtc(DateTime.now().add(delay)),
        errorCode,
        row['event_id'],
      ],
    );
    counts['retry_wait'] = (counts['retry_wait'] ?? 0) + 1;
  }

  String _summarize(Map<String, int> counts) {
    if ((counts['retry_wait'] ?? 0) > 0) return 'partial';
    if ((counts['sent'] ?? 0) == 0) return 'no_change';
    if ((counts['dead_letter'] ?? 0) > 0 || (counts['blocked'] ?? 0) > 0) {
      return 'partial';
    }
    return 'success';
  }
}

class _AuthRequired implements Exception {}

class _Offline implements Exception {}

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
