// 커뮤니티 capture (contracts/community-ingest/observation.md 4절, local-store.md).
//
// 인터페이스 계약 interfaces.md 모바일 절의 Dart 동등 이름:
//   buildAdapterInput / buildPayload / canonicalJson / capture / markPersonalSave.
// buildPayload 는 observation_rules.dart, canonicalJson 은 canonical_json.dart.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../community_store.dart';
import 'canonical_json.dart';
import 'observation_rules.dart';

export 'canonical_json.dart' show canonicalJson;
export 'observation_rules.dart' show buildPayload;

/// 공유 payload 버전을 올리지 않고 파서만 구분한다.
const String mobileParserVersion = 'mobile-parser-1';

/// 공식 주소로 조회한 geocode_cache 행. null = 캐시 없음(나중에 location_supplement).
class GeocodeHit {
  const GeocodeHit({required this.status, this.lat, this.lng});

  final String status;
  final Object? lat;
  final Object? lng;

  Map<String, Object?> toAdapterGeo() =>
      {'status': status, 'lat': lat, 'lng': lng};
}

/// Report → 어댑터 입력 (observation.md 2절 모바일 열).
///
/// progressStatus = 상세의 C_NOW 라벨(`report.result`). detail_status 기록용이며
/// payload 에는 들어가지 않는다. geo 는 **공식 주소(`report.location`) 정규화 키로
/// 조회한 geocode_cache 행**만 쓴다. override 좌표·주소는 절대 넣지 않는다.
Map<String, Object?> buildAdapterInput(
  // Report 타입에 직접 의존하지 않고(테스트에서 가짜를 쓰기 위해) 필드만 받는다.
  {
  required String status,
  required String fineInfo,
  required String date,
  required String responseDate,
  required String agency,
  required String manager,
  required String carNumber,
  required String location,
  required String penaltyPoints,
  required String entryValue,
  GeocodeHit? geo,
  required String progressStatus,
}) {
  return <String, Object?>{
    'processing_status': status,
    'penalty_amount': fineInfo,
    'report_date': date,
    'response_date': responseDate,
    'processing_agency': agency,
    'person_in_charge': manager,
    'car_number': carNumber,
    'violation_location': location,
    'entry_value': entryValue,
    'penalty_points': penaltyPoints,
    'geocode': geo?.toAdapterGeo(),
    'progress_status': progressStatus,
  };
}

class CaptureResult {
  const CaptureResult({
    required this.eventId,
    required this.eventType,
    required this.eligible,
    required this.payloadSha256,
    required this.sourceRevision,
  });

  /// 새 이벤트가 없으면 null.
  final String? eventId;

  /// completed_observation | status_correction | null(새 이벤트 없음).
  final String? eventType;
  final bool eligible;
  final String payloadSha256;

  /// 새 이벤트가 없으면 null.
  final int? sourceRevision;
}

class CaptureStoreUnavailable extends StateError {
  CaptureStoreUnavailable(super.message);
}

/// event 결정 (observation.md 4절).
///
/// [prevSha]/[prevEligible] = 같은 로컬 데이터셋의 가장 최근 journal 행
/// (없으면 null). [serverCompletedHit] = prev 가 없는데 그 신고의
/// source_report_key 앞 24hex 가 server_completed 에 있음 → prev 를
/// "eligible, 해시 불명"으로 본다.
String? decideEvent({
  required bool eligible,
  required String? prevSha,
  required bool? prevEligible,
  required String payloadSha,
  required bool serverCompletedHit,
}) {
  if (eligible) {
    if (prevSha != null && prevSha == payloadSha) return null;
    return 'completed_observation';
  }
  final effectivePrevEligible = prevEligible ?? serverCompletedHit;
  if (effectivePrevEligible) return 'status_correction';
  return null;
}

/// `safetyreport|<sourceReportId>` sha256 앞 24hex (서버 source_report_key 규칙).
String sourceReportKeyPrefix(String sourceReportId) => sha256
    .convert(utf8.encode('safetyreport|$sourceReportId'))
    .toString()
    .substring(0, 24);

/// capture 한 트랜잭션 (local-store.md 그대로):
/// detail_status UPSERT + (이벤트면) journal·outbox(context active 일 때)·
/// meta.next_revision + report_latest UPSERT(rebuild 면 staging) 를 commit 한 뒤
/// 호출자가 개인 DB 저장을 진행한다.
///
/// 이벤트가 없고 prev 도 없으면 report_latest/staging 은 쓰지 않는다
/// (detail_status 만 — 이것도 capture 성공).
Future<CaptureResult> capture(
  Map<String, Object?> adapterInput, {
  required String sourceReportId,
  required String trigger,
  String? rebuildRunId,
  CommunityStore? store,
  String? projectNamespace,
  DateTime? now,
}) async {
  final s = store ?? await CommunityStore.open();
  final payload = buildPayload(adapterInput);
  final eligible = payloadEligible(payload);
  final canonical = canonicalJson(payload);
  final sha = sha256.convert(utf8.encode(canonical)).toString();
  final progressStatus =
      adapterInput['progress_status']?.toString() ?? '';
  final at = isoUtc(now ?? DateTime.now());

  return s.transaction((tx) async {
    final localDatasetId = await s.meta('local_dataset_id', tx) ?? '';
    final contextRows =
        await tx.rawQuery('SELECT * FROM context WHERE id=1');
    final contextRow = contextRows.isEmpty ? null : contextRows.first;
    final contextActive =
        contextRow != null && contextRow['state'] == 'active';
    final contextDatasetKey =
        contextActive ? contextRow['dataset_key']?.toString() : null;

    // prev: rebuild 중이면 이번 run 의 staging 을 먼저 본다.
    Map<String, Object?>? prev;
    if (rebuildRunId != null) {
      final staging = await tx.rawQuery(
        'SELECT event_id, payload_sha256, eligible FROM report_latest_staging '
        'WHERE run_id=? AND source_report_id=?',
        [rebuildRunId, sourceReportId],
      );
      if (staging.isNotEmpty) {
        final journals = await tx.rawQuery(
          'SELECT payload_sha256, eligible FROM source_journal WHERE event_id=?',
          [staging.first['event_id']],
        );
        if (journals.isNotEmpty) prev = journals.first;
      }
    }
    prev ??= await _latestJournal(tx, localDatasetId, sourceReportId);

    var serverCompletedHit = false;
    if (prev == null && contextDatasetKey != null) {
      final prefix = sourceReportKeyPrefix(sourceReportId);
      final rows = await tx.rawQuery(
        'SELECT 1 FROM server_completed WHERE dataset_key=? AND key_prefix=?',
        [contextDatasetKey, prefix],
      );
      serverCompletedHit = rows.isNotEmpty;
    }

    final eventType = decideEvent(
      eligible: eligible,
      prevSha: prev?['payload_sha256']?.toString(),
      prevEligible:
          prev == null ? null : (prev['eligible'] as int? ?? 0) == 1,
      payloadSha: sha,
      serverCompletedHit: serverCompletedHit,
    );

    // 상세를 받을 때마다 detail_status 를 같은 트랜잭션으로 기록한다.
    await tx.insert('detail_status', {
      'local_dataset_id': localDatasetId,
      'source_report_id': sourceReportId,
      'c_now_label': progressStatus,
      'observed_at': at,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    if (eventType == null) {
      if (rebuildRunId != null && prev != null) {
        // 무변경 포인터 carry-forward (cutover 병합용).
        final prevEvent = await _latestEventId(tx, localDatasetId,
            sourceReportId, stagingRunId: rebuildRunId);
        if (prevEvent != null) {
          await tx.insert('report_latest_staging', {
            'run_id': rebuildRunId,
            'source_report_id': sourceReportId,
            'event_id': prevEvent,
            'payload_sha256': prev['payload_sha256'],
            'eligible': prev['eligible'],
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      return CaptureResult(
        eventId: null,
        eventType: null,
        eligible: eligible,
        payloadSha256: sha,
        sourceRevision: null,
      );
    }

    final revision = await s.nextRevision(tx);
    final eventId = newUuidV4();
    final ns = projectNamespace ?? 'unconfigured';
    await tx.insert('source_journal', {
      'event_id': eventId,
      'project_namespace': ns,
      'local_dataset_id': localDatasetId,
      'dataset_key': contextDatasetKey,
      'source_report_id': sourceReportId,
      'source_revision': revision,
      'event_type': eventType,
      'captured_at': at,
      'capture_trigger': trigger,
      'rebuild_run_id': rebuildRunId,
      'schema_version': 1,
      'parser_version': mobileParserVersion,
      'payload_json': canonical,
      'payload_sha256': sha,
      'eligible': eligible ? 1 : 0,
      'contributor_fingerprint':
          contextActive ? contextRow['contributor_fingerprint'] : null,
      'connection_id': contextActive ? contextRow['connection_id'] : null,
      'writer_epoch': contextActive ? contextRow['writer_epoch'] : null,
      'consent_grant_id':
          contextActive ? contextRow['consent_grant_id'] : null,
      'personal_save_state': 'pending',
    });
    if (contextActive) {
      await tx.insert('outbox', {
        'event_id': eventId,
        'state': 'pending',
        'attempt_count': 0,
        'enqueued_trigger': trigger,
        'enqueued_at': at,
      });
    }
    if (rebuildRunId != null) {
      await tx.insert('report_latest_staging', {
        'run_id': rebuildRunId,
        'source_report_id': sourceReportId,
        'event_id': eventId,
        'payload_sha256': sha,
        'eligible': eligible ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      final generation =
          int.tryParse(await s.meta('source_generation', tx) ?? '0') ?? 0;
      await tx.insert('report_latest', {
        'local_dataset_id': localDatasetId,
        'source_report_id': sourceReportId,
        'event_id': eventId,
        'payload_sha256': sha,
        'eligible': eligible ? 1 : 0,
        'source_generation': generation,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return CaptureResult(
      eventId: eventId,
      eventType: eventType,
      eligible: eligible,
      payloadSha256: sha,
      sourceRevision: revision,
    );
  });
}

Future<Map<String, Object?>?> _latestJournal(
  DatabaseExecutor tx,
  String localDatasetId,
  String sourceReportId,
) async {
  final latest = await tx.rawQuery(
    'SELECT event_id FROM report_latest WHERE local_dataset_id=? AND source_report_id=?',
    [localDatasetId, sourceReportId],
  );
  if (latest.isEmpty) return null;
  final journals = await tx.rawQuery(
    'SELECT payload_sha256, eligible FROM source_journal WHERE event_id=?',
    [latest.first['event_id']],
  );
  return journals.isEmpty ? null : journals.first;
}

Future<String?> _latestEventId(
  DatabaseExecutor tx,
  String localDatasetId,
  String sourceReportId, {
  String? stagingRunId,
}) async {
  if (stagingRunId != null) {
    final rows = await tx.rawQuery(
      'SELECT event_id FROM report_latest_staging WHERE run_id=? AND source_report_id=?',
      [stagingRunId, sourceReportId],
    );
    if (rows.isNotEmpty) return rows.first['event_id']?.toString();
  }
  final rows = await tx.rawQuery(
    'SELECT event_id FROM report_latest WHERE local_dataset_id=? AND source_report_id=?',
    [localDatasetId, sourceReportId],
  );
  return rows.isEmpty ? null : rows.first['event_id']?.toString();
}

/// 개인 저장 결과를 최신 journal 행에 반영한다.
Future<void> markPersonalSave(String? eventId, bool ok,
    {CommunityStore? store}) async {
  if (eventId == null) return;
  final s = store ?? await CommunityStore.open();
  await s.db.rawUpdate(
    "UPDATE source_journal SET personal_save_state=? WHERE event_id=?",
    [ok ? 'saved' : 'failed', eventId],
  );
}

/// 시작 시 정리: 10분 넘게 pending 인 행을 개인 DB 원본과 대조해 saved/failed 로 맞춘다.
/// [lookupStatusRaw] = 신고별 개인 DB 원본 상세 행의 status_raw(C_NOW 라벨).
Future<int> reconcilePendingSaves(
  Future<String?> Function(String sourceReportId) lookupStatusRaw, {
  CommunityStore? store,
  DateTime? now,
}) async {
  final s = store ?? await CommunityStore.open();
  final cutoff = isoUtc(
    (now ?? DateTime.now()).subtract(const Duration(minutes: 10)),
  );
  final rows = await s.db.rawQuery(
    "SELECT event_id, source_report_id, payload_json FROM source_journal "
    "WHERE personal_save_state='pending' AND captured_at < ?",
    [cutoff],
  );
  var fixed = 0;
  for (final row in rows) {
    final site = await lookupStatusRaw(row['source_report_id'] as String);
    String? payloadRaw;
    try {
      final payload =
          jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
      payloadRaw = payload['status_raw']?.toString();
    } catch (_) {
      payloadRaw = null;
    }
    final ok = site != null && site == payloadRaw;
    await s.db.rawUpdate(
      'UPDATE source_journal SET personal_save_state=? WHERE event_id=?',
      [ok ? 'saved' : 'failed', row['event_id']],
    );
    fixed++;
  }
  return fixed;
}
