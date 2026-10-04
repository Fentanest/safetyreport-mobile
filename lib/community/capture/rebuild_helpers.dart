// rebuild 모드 상세 오류 분류 + staging 병합 (rebuild.md).
//
// - 네트워크·5xx·타임아웃 → failed_retryable (최대 5회, 그 뒤 permanent)
// - 접근 거절·삭제된 원본 → failed_permanent (+ 당시 목록 라벨을 last_list_label 에)
// - 로그인 실패·토큰 만료 → run 전체 paused(auth) — 호출자가 먼저 rethrow 한다.
import 'package:sqflite/sqflite.dart';

import '../community_store.dart';

/// Only a decoded, explicit permanent rejection may discard a work obligation.
/// HTTP status strings and exhausted retries are not such evidence.
class PermanentDetailFailure implements Exception {
  const PermanentDetailFailure(this.code);
  final String code;
  @override
  String toString() => 'PermanentDetailFailure($code)';
}

String classifyDetailError(Object error) => error is PermanentDetailFailure
    ? 'failed_permanent' : 'failed_retryable';

String nextItemStateAfterFailure(int attemptsAfterIncrement) => 'failed_retryable';

/// committing: staging 행을 report_latest 에 upsert 병합 (한 트랜잭션).
///
/// staging 에 없는 신고(영구 실패·목록 부재)는 기존 행을 그대로 둔다
/// (carry-forward, 삭제 없음). 병합된 건수를 반환한다.
Future<int> mergeRebuildStaging(String runId, {CommunityStore? store, DatabaseExecutor? executor}) async {
  final s = store ?? await CommunityStore.open();
  Future<int> merge(DatabaseExecutor tx) async {
    final localDatasetId = await s.meta('local_dataset_id', tx) ?? '';
    final generation =
        (int.tryParse(await s.meta('source_generation', tx) ?? '0') ?? 0) + 1;
    await s.setMeta('source_generation', '$generation', tx);
    final rows = await tx.rawQuery(
      'SELECT source_report_id, event_id, payload_sha256, eligible '
      'FROM report_latest_staging WHERE run_id=?',
      [runId],
    );
    for (final row in rows) {
      await tx.insert('report_latest', {
        'local_dataset_id': localDatasetId,
        'source_report_id': row['source_report_id'],
        'event_id': row['event_id'],
        'payload_sha256': row['payload_sha256'],
        'eligible': row['eligible'],
        'source_generation': generation,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return rows.length;
  }
  return executor == null ? s.transaction(merge) : merge(executor);
}
