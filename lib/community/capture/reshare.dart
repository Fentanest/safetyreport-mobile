// reshare 후보 (observation.md 4절).
//
// reshare: 재동의·writer 전환 뒤 사용자가 지도 탭에서 명시적으로 요청할 때만.
// 신고별 최신 eligible journal 행의 payload·captured_at 을 그대로 두고
// 새 event_id·새 source_revision·현재 grant/connection/epoch 로 발급한다.
import 'package:sqflite/sqflite.dart';

import '../community_store.dart';
import 'server_completed.dart' show deletionCleanupPending;
import 'community_capture.dart';

/// reshare 후보 수 (현 계정의 최신 journal 행이 eligible 이고 차단되지 않은 신고).
/// 2026-09-28 계정 규칙: 타 계정 행은 후보가 아니며 현 연결로 rebind하지 않는다(PC와 같음).
Future<int> reshareCandidates({CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  final contextRows =
      await s.db.rawQuery('SELECT * FROM context WHERE id=1');
  if (contextRows.isEmpty || contextRows.first['state'] != 'active') {
    return 0;
  }
  final context = contextRows.first;
  final localDatasetId = await s.meta('local_dataset_id') ?? '';
  // 후보 정의는 기존과 같다(현 계정의 최신 eligible·미차단 행). 계정 범위만 좁힌다.
  final rows = await s.db.rawQuery('''
SELECT COUNT(*) AS cnt FROM (
  SELECT source_report_id, MAX(source_revision) AS rev FROM source_journal
  WHERE local_dataset_id=? AND eligible = 1 AND dataset_key IS ?
    AND contributor_fingerprint IS ?
  GROUP BY source_report_id
) scoped
JOIN source_journal j ON j.local_dataset_id=? AND j.source_report_id = scoped.source_report_id
  AND j.source_revision = scoped.rev AND j.dataset_key IS ? AND j.contributor_fingerprint IS ?
WHERE j.blocked_reason IS NULL
''', [
    localDatasetId,
    context['dataset_key'],
    context['contributor_fingerprint'],
    localDatasetId,
    context['dataset_key'],
    context['contributor_fingerprint'],
  ]);
  return int.tryParse('${rows.first['cnt']}') ?? 0;
}

/// 한 신고의 reshare 이벤트를 발급한다. 후보가 없으면 null.
Future<String?> issueReshare(
  String sourceReportId, {
  CommunityStore? store,
  DateTime? now,
}) async {
  final s = store ?? await CommunityStore.open();
  if (await deletionCleanupPending(store: s)) {
    return null; // 삭제 뒤 정리가 끝나기 전에는 다시 공유하지 않는다(H-03)
  }
  return s.transaction((tx) async {
    final contextRows = await tx.rawQuery('SELECT * FROM context WHERE id=1');
    if (contextRows.isEmpty || contextRows.first['state'] != 'active') {
      return null;
    }
    final context = contextRows.first;
    final localDatasetId = await s.meta('local_dataset_id', tx) ?? '';
    // 현 계정의 최신 eligible 행만 재발급한다(타 계정 행 rebind 금지).
    final journals = await tx.rawQuery(
      'SELECT * FROM source_journal WHERE local_dataset_id=? AND source_report_id=? '
      'AND eligible = 1 AND dataset_key IS ? AND contributor_fingerprint IS ? '
      'ORDER BY source_revision DESC LIMIT 1',
      [
        localDatasetId,
        sourceReportId,
        context['dataset_key'],
        context['contributor_fingerprint'],
      ],
    );
    if (journals.isEmpty) return null;
    final journal = journals.first;
    if (journal['blocked_reason'] != null) return null;
    final revision = await s.nextRevision(tx);
    final eventId = newUuidV4();
    await tx.insert('source_journal', {
      'event_id': eventId,
      'project_namespace': journal['project_namespace'],
      'local_dataset_id': localDatasetId,
      'dataset_key': context['dataset_key'],
      'source_report_id': sourceReportId,
      'report_number': journal['report_number'],
      'source_revision': revision,
      'event_type': 'reshare',
      'captured_at': journal['captured_at'],
      'capture_trigger': 'reshare',
      'rebuild_run_id': null,
      'schema_version': 1,
      'parser_version': mobileParserVersion,
      'payload_json': journal['payload_json'],
      'payload_sha256': journal['payload_sha256'],
      'eligible': 1,
      'contributor_fingerprint': context['contributor_fingerprint'],
      'connection_id': context['connection_id'],
      'writer_epoch': context['writer_epoch'],
      'consent_grant_id': context['consent_grant_id'],
      'personal_save_state': 'saved',
    });
    await tx.insert('outbox', {
      'event_id': eventId,
      'state': 'pending',
      'attempt_count': 0,
      'enqueued_trigger': 'reshare',
      'enqueued_at': isoUtc(now ?? DateTime.now()),
    });
    await tx.insert('report_latest', {
      'local_dataset_id': localDatasetId,
      'source_report_id': sourceReportId,
      'event_id': eventId,
      'payload_sha256': journal['payload_sha256'],
      'eligible': 1,
      'source_generation':
          int.tryParse(await s.meta('source_generation', tx) ?? '0') ?? 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return eventId;
  });
}
