// reshare + location_supplement 후보 (observation.md 4절).
//
// reshare: 재동의·writer 전환 뒤 사용자가 지도 탭에서 명시적으로 요청할 때만.
// 신고별 최신 eligible journal 행의 payload·captured_at 을 그대로 두고
// 새 event_id·새 source_revision·현재 grant/connection/epoch 로 발급한다.
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../community_store.dart';
import 'server_completed.dart' show deletionCleanupPending;
import 'community_capture.dart';

/// reshare 후보 수 (최신 journal 행이 eligible 이고 차단되지 않은 신고).
Future<int> reshareCandidates({CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  final rows = await s.db.rawQuery('''
SELECT COUNT(*) AS cnt FROM report_latest rl
JOIN source_journal j ON j.event_id = rl.event_id
WHERE j.eligible = 1 AND j.blocked_reason IS NULL
''');
  return int.tryParse('${rows.first['cnt']}') ?? 0;
}

/// 한 신고의 reshare 이벤트를 발급한다. 후보가 없으면 null.
Future<String?> issueReshare(
  String sourceReportId, {
  CommunityStore? store,
  DateTime? now,
}) async {
  final s = store ?? await CommunityStore.open();
  if (await deletionCleanupPending(store: s)) return null; // 삭제 뒤 정리가 끝나기 전에는 다시 공유하지 않는다(H-03)
  return s.transaction((tx) async {
    final contextRows =
        await tx.rawQuery('SELECT * FROM context WHERE id=1');
    if (contextRows.isEmpty || contextRows.first['state'] != 'active') {
      return null;
    }
    final context = contextRows.first;
    final localDatasetId = await s.meta('local_dataset_id', tx) ?? '';
    final latest = await tx.rawQuery(
      'SELECT event_id FROM report_latest WHERE local_dataset_id=? AND source_report_id=?',
      [localDatasetId, sourceReportId],
    );
    if (latest.isEmpty) return null;
    final journals = await tx.rawQuery(
      'SELECT * FROM source_journal WHERE event_id=?',
      [latest.first['event_id']],
    );
    if (journals.isEmpty) return null;
    final journal = journals.first;
    if ((journal['eligible'] as int? ?? 0) != 1) return null;
    if (journal['blocked_reason'] != null) return null;
    final revision = await s.nextRevision(tx);
    final eventId = newUuidV4();
    await tx.insert('source_journal', {
      'event_id': eventId,
      'project_namespace': journal['project_namespace'],
      'local_dataset_id': localDatasetId,
      'dataset_key': context['dataset_key'],
      'source_report_id': sourceReportId,
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

/// location_supplement 후보: 최신 journal 행이 eligible 이고 location.source="none"
/// 인데 그 행의 address 로 공식 캐시가 이제 ok 인 신고 ID 목록.
Future<List<String>> locationSupplementCandidates(
  Future<Map<String, Object?>?> Function(String address) lookupCache, {
  CommunityStore? store,
}) async {
  final s = store ?? await CommunityStore.open();
  final rows = await s.db.rawQuery('''
SELECT rl.source_report_id AS id, j.payload_json AS payload
FROM report_latest rl
JOIN source_journal j ON j.event_id = rl.event_id
WHERE j.eligible = 1 AND j.blocked_reason IS NULL
''');
  final out = <String>[];
  for (final row in rows) {
    try {
      final payload =
          (await _decodePayload(row['payload'] as String)) ?? const {};
      final location = payload['location'];
      if (location is! Map || location['source'] != 'none') continue;
      final address = payload['address']?.toString() ?? '';
      if (address.isEmpty) continue;
      final hit = await lookupCache(address);
      if (hit != null && hit['status'] == 'ok') {
        out.add(row['id'] as String);
      }
    } catch (_) {
      continue;
    }
  }
  return out;
}

Future<Map<String, Object?>?> _decodePayload(String raw) async {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}
