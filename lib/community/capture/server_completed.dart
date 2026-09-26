// 중앙 manifest → server_completed 교체 + 삭제 처리 (S-04).
import 'dart:convert';

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

/// 삭제 대기 표시: journal 과 같은 community.db 의 meta 에 트랜잭션으로 둔다(PC 와 같은 규칙, Sol 2차 H-03a/b).
const String deletionKeyPrefix = 'deletion_pending:';

/// 중앙 삭제를 요청하기 **전에** 표시를 남긴다. 못 쓰면 예외 → 호출자는 중앙 삭제를 요청하지 않는다.
/// 표시마다 고유 id 라 동시 삭제가 서로를 지우지 않는다.
Future<String> beginDeletion({CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  final id = newUuidV4();
  await s.transaction((tx) async {
    await s.setMeta('$deletionKeyPrefix$id', jsonEncode({'requested_at': isoUtc(DateTime.now())}), tx);
  });
  return id;
}

/// 중앙 삭제가 확실히 실패했을 때만 그 표시 하나를 지운다.
Future<void> cancelDeletion(String id, {CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  await s.transaction((tx) async {
    await tx.rawDelete('DELETE FROM meta WHERE key=?', ['$deletionKeyPrefix$id']);
  });
}

/// 남은 표시가 있으면 한 트랜잭션에서 적용하고 지운다: 그 시점까지의 journal 전부(행 순번 — 시계 무관) deleted_by_user,
/// 그 outbox blocked, server_completed 비움. 표시가 없으면 아무것도 하지 않는다. 실패는 예외.
Future<bool> applyPendingDeletion({CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  await s.transaction((tx) async {
    final keys = await tx.rawQuery('SELECT key FROM meta WHERE key LIKE ?', ['$deletionKeyPrefix%']);
    if (keys.isEmpty) return;
    final r = await tx.rawQuery('SELECT max(rowid) AS m FROM source_journal');
    final boundary = (r.first['m'] as int?) ?? 0;
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
    for (final k in keys) {
      await tx.rawDelete('DELETE FROM meta WHERE key=?', [k['key']]);
    }
  });
  return true;
}

/// 중앙 삭제 성공 뒤(표시는 [beginDeletion] 이 남겼다). 표시 없이 불리면 보수적으로 만든 뒤 적용한다.
Future<void> onContributionsDeleted({
  required DateTime deletedAt,
  CommunityStore? store,
  String? deletionId,
}) async {
  final s = store ?? await CommunityStore.open();
  if (deletionId == null) await beginDeletion(store: s);
  await applyPendingDeletion(store: s);
}

/// 표시가 남아 있으면 적용을 다시 시도한다. 여전히 못 하면(또는 저장소 오류) true — 업로드·reshare 금지.
Future<bool> deletionCleanupPending({CommunityStore? store}) async {
  try {
    return !(await applyPendingDeletion(store: store));
  } catch (_) {
    return true;
  }
}
