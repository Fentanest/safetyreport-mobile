// 중앙 manifest → server_completed 교체 + 삭제 처리 (S-04).
import '../community_store.dart';

/// manifest 한 페이지. 키는 completed fact key 앞 24hex.
class ManifestPage {
  const ManifestPage({
    required this.keys,
    required this.manifestToken,
    this.after,
  });

  final List<String> keys;
  final String manifestToken;

  /// 다음 페이지 요청용 커서. null = 마지막 페이지.
  final String? after;
}

/// manifest 전 페이지를 받아 server_completed 를 교체한다 (S-04).
///
/// 모든 페이지의 manifest_token 이 같아야 교체한다. 다르면 처음부터 다시
/// 받는다(최대 3회). 실패하면 false 를 반환하고 수집·초기화를 시작하지 않는다
/// (fail-closed, manifest_unavailable).
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
    String? after;
    var ok = true;
    while (true) {
      final page = await fetchPage(after, limit);
      if (page == null) {
        ok = false;
        break;
      }
      if (token == null) {
        token = page.manifestToken;
        if (token.isEmpty) {
          ok = false;
          break;
        }
      } else if (page.manifestToken != token) {
        ok = false;
        break;
      }
      keys.addAll(page.keys);
      if (page.after == null) break;
      after = page.after;
    }
    if (ok) {
      accepted = keys.toSet().toList(growable: false);
      break;
    }
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

/// `contributions-delete` 성공 뒤 호출된다 (T5 카드가 호출).
///
/// - outbox 대기 행 전부 `blocked:deleted_by_user`
/// - 삭제 시각 이전 journal 행 `blocked_reason='deleted_by_user'`
///   (reshare·location_supplement 후보 영구 제외)
/// - server_completed 비움
Future<void> onContributionsDeleted({
  required DateTime deletedAt,
  CommunityStore? store,
}) async {
  final s = store ?? await CommunityStore.open();
  final at = isoUtc(deletedAt);
  await s.transaction((tx) async {
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
