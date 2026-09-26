// 중앙 manifest → server_completed 교체 + 삭제 처리 (S-04).
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../community_store.dart';

/// manifest 한 페이지. 키는 completed fact key 앞 24hex.
class ManifestPage {
  const ManifestPage({
    required this.keys,
    required this.manifestToken,
    this.after,
    this.total,
    this.datasetKey,
    this.writerEpoch,
  });

  /// 검증된 응답 JSON(`validManifestPage`)에서 만든다.
  factory ManifestPage.fromJson(Map<String, Object?> j) => ManifestPage(
        keys: (j['key_prefixes'] as List).cast<String>(),
        manifestToken: j['manifest_token'] as String,
        after: j['next_after'] as String?,
        total: j['total'] as int,
        datasetKey: j['dataset_key'] as String,
        writerEpoch: j['writer_epoch'] as int,
      );

  final List<String> keys;
  final String manifestToken;

  /// 다음 페이지 요청용 커서. null = 마지막 페이지.
  final String? after;

  /// 서버가 센 전체 개수(모든 페이지 같아야 함). null 이면 검사하지 않는다(단위 테스트용 페이지).
  final int? total;
  final String? datasetKey;
  final int? writerEpoch;
}

/// manifest 전 페이지를 받아 server_completed 를 교체한다 (S-04, PC `refresh_server_completed` 와 같은 규칙).
///
/// 모든 페이지의 manifest_token·total 이 같고, 받은 개수 = total, 중복 없음, 페이지의 dataset_key·writer_epoch 가
/// 현재 연결과 같을 때만 한 트랜잭션으로 교체한다. 토큰이 바뀌면 처음부터 다시(최대 3회). 실패하면 false 를 반환하고
/// 이전 목록을 그대로 둔다 — 수집·초기화를 시작하지 않는다(fail-closed, manifest_unavailable).
///
/// [fetchPage] = (after, limit) → page. limit ≤ 5000.
Future<bool> refreshServerCompleted({
  required String datasetKey,
  required int writerEpoch,
  required Future<ManifestPage?> Function(String? after, int limit) fetchPage,
  CommunityStore? store,
  DateTime? now,
}) async {
  const limit = 5000;
  List<String>? accepted;
  for (var attempt = 0; attempt < 3; attempt++) {
    final keys = <String>[];
    String? token;
    int? total;
    String? after;
    var retry = false;
    while (true) {
      final page = await fetchPage(after, limit);
      if (page == null) return false;
      if ((page.datasetKey != null && page.datasetKey != datasetKey) ||
          (page.writerEpoch != null && page.writerEpoch != writerEpoch)) {
        return false;
      }
      if (token == null) {
        token = page.manifestToken;
        total = page.total;
        if (token.isEmpty) return false;
      } else if (page.manifestToken != token || page.total != total) {
        retry = true;
        break;
      }
      keys.addAll(page.keys);
      if (page.after == null) break;
      after = page.after;
    }
    if (retry) continue;
    if ((total != null && keys.length != total) || keys.toSet().length != keys.length) return false;
    accepted = keys;
    break;
  }
  if (accepted == null) return false;
  final s = store ?? await CommunityStore.open();
  final at = isoUtc(now ?? DateTime.now());
  await s.transaction((tx) async {
    await tx.rawDelete(
        'DELETE FROM server_completed WHERE dataset_key=?', [datasetKey]);
    for (final key in accepted!) {
      await tx.insert('server_completed', {
        'dataset_key': datasetKey,
        'key_prefix': key,
        'fetched_at': at,
      });
    }
    await s.setMeta('manifest_scope', '$datasetKey:$writerEpoch', tx);
  });
  return true;
}

/// 삭제 뒤 로컬 차단 표시(SharedPreferences). 적용이 끝나야 지운다 — 남아 있으면 업로드·reshare 를 하지 않는다.
const String deletionPendingKey = 'community_deletion_pending_v1';

/// `contributions-delete` 성공 뒤(PC `on_contributions_deleted` 와 같은 규칙, Sol 통합 검토 H-03):
/// 그 시점에 있던 journal 행 전부를 **행 순번 경계**로 영구 제외한다(시계와 무관 — 앞선 시계의 captured_at 도 막힌다),
/// 그 행들의 outbox 를 막고 server_completed 를 비운다. 먼저 영속 표시를 쓰고, 적용이 끝나면 지운다.
/// 적용이 실패하면 예외를 올리고 표시는 남는다.
Future<void> onContributionsDeleted({
  required DateTime deletedAt,
  CommunityStore? store,
  String? deletionId,
}) async {
  final s = store ?? await CommunityStore.open();
  int? boundary;
  try {
    final r = await s.db.rawQuery('SELECT max(rowid) AS m FROM source_journal');
    boundary = (r.first['m'] as int?) ?? 0;
  } catch (_) {
    boundary = null; // 읽을 수 없으면 적용 시점의 전체 행을 막는다(보수적)
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(deletionPendingKey, jsonEncode({
    'deletion_id': deletionId,
    'journal_rowid_max': boundary,
    'recorded_at': isoUtc(deletedAt),
  }));
  await applyPendingDeletion(store: s);
}

/// 남은 삭제 표시가 없으면 true. 있으면 적용하고 지운다. 적용 실패는 예외.
Future<bool> applyPendingDeletion({CommunityStore? store}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final raw = prefs.getString(deletionPendingKey);
  if (raw == null) return true;
  Map<String, Object?> marker;
  try {
    marker = (jsonDecode(raw) as Map).cast<String, Object?>();
  } catch (_) {
    marker = const {}; // 손상된 표시: 경계 없이 적용 시점의 전체 행을 막는다(영구 잠김 대신 보수적 복구)
  }
  final s = store ?? await CommunityStore.open();
  await s.transaction((tx) async {
    var boundary = marker['journal_rowid_max'] as int?;
    if (boundary == null) {
      final r = await tx.rawQuery('SELECT max(rowid) AS m FROM source_journal');
      boundary = (r.first['m'] as int?) ?? 0;
    }
    await tx.rawUpdate(
      "UPDATE source_journal SET blocked_reason='deleted_by_user' "
      "WHERE rowid <= ? AND (blocked_reason IS NULL OR blocked_reason != 'deleted_by_user')",
      [boundary],
    );
    await tx.rawUpdate(
      "UPDATE outbox SET state='blocked', last_error_code='deleted_by_user' "
      "WHERE state != 'dead_letter' AND event_id IN (SELECT event_id FROM source_journal WHERE rowid <= ?)",
      [boundary],
    );
    await tx.rawDelete('DELETE FROM server_completed');
  });
  await prefs.remove(deletionPendingKey);
  return true;
}

/// 삭제 뒤 로컬 차단이 아직 끝나지 않았으면 다시 적용해 본다. 여전히 못 하면 true(업로드 금지).
Future<bool> deletionCleanupPending({CommunityStore? store}) async {
  try {
    return !(await applyPendingDeletion(store: store));
  } catch (_) {
    return true;
  }
}
