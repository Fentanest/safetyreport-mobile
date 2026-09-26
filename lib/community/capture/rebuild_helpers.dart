// rebuild 모드 상세 오류 분류 + staging 병합 (rebuild.md).
//
// - 네트워크·5xx·타임아웃 → failed_retryable (최대 5회, 그 뒤 permanent)
// - 접근 거절·삭제된 원본 → failed_permanent (+ 당시 목록 라벨을 last_list_label 에)
// - 로그인 실패·토큰 만료 → run 전체 paused(auth) — 호출자가 먼저 rethrow 한다.
import 'package:sqflite/sqflite.dart';

import '../community_store.dart';

String classifyDetailError(Object error) {
  final msg = error.toString();
  if (msg.contains('삭제') ||
      msg.contains('없습니다') ||
      msg.contains('찾을 수 없') ||
      msg.contains('404') ||
      msg.contains('거부') ||
      msg.contains('권한') ||
      msg.contains('삭제된')) {
    return 'failed_permanent';
  }
  return 'failed_retryable';
}

/// 재시도 횟수 초과(5회)면 permanent 로 승격한다.
String nextItemStateAfterFailure(int attemptsAfterIncrement) =>
    attemptsAfterIncrement >= 5 ? 'failed_permanent' : 'failed_retryable';

/// committing: staging 행을 report_latest 에 upsert 병합 (한 트랜잭션).
///
/// staging 에 없는 신고(영구 실패·목록 부재)는 기존 행을 그대로 둔다
/// (carry-forward, 삭제 없음). 병합된 건수를 반환한다.
Future<int> mergeRebuildStaging(String runId, {CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  return s.transaction((tx) async {
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
  });
}
