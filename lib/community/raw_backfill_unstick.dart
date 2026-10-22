// 이미 멈춘 기기 풀기 — CLIENT-RULES 2절(2-3). 새 버전 첫 실행에 한 번.
//
// 한 트랜잭션에서 지금 run(`meta.raw_backfill.run_id`)의 항목과 marker 를 함께 바꾸고,
// 끝나면 `meta.raw_backfill_unstick = "2026-10-22.1"` 을 쓴다(값이 있으면 다시 하지 않는다).
// PC `community_raw_backfill` 의 같은 이행과 같은 표다.
import 'dart:convert';

import 'backfill_store.dart';
import 'community_store.dart';
import 'raw_backfill.dart';

const rawBackfillUnstickKey = 'raw_backfill_unstick';
const rawBackfillUnstickVersion = '2026-10-22.1';

/// 공식 로그인 수동 표시(`raw_backfill_runtime.dart` 의 `_manualLoginKey` 와 같은 키).
const rawLoginManualKey = 'raw_login_manual';

/// 결과: 이미 했으면 null, 했으면 되돌린 항목 수(run 이 없으면 0).
Future<int?> unstickRawBackfill(CommunityStore store) async {
  if (await store.meta(rawBackfillUnstickKey) != null) return null;
  final codec = SqliteBackfillItems(store, () async {});
  return store.transaction<int?>((tx) async {
    if (await store.meta(rawBackfillUnstickKey, tx) != null) return null;
    var reverted = 0;
    Map<String, dynamic>? marker;
    try {
      final text = await store.meta('raw_backfill', tx);
      final decoded = text == null ? null : jsonDecode(text);
      marker = decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      marker = null;
    }
    final run = marker?['run_id'];
    if (marker != null && run is String) {
      bool revert(Map<String, dynamic> item) {
        if (item['state'] == 'hold') {
          resetHold(item);
          return true;
        }
        if (item['state'] == 'not_eligible' &&
            item['error'] == 'upload_rejected') {
          item.addAll({
            'state': 'pending',
            'attempts': 0,
            'eligible': true,
            'event_id': null,
          });
          item.remove('error');
          return true;
        }
        return false;
      }

      for (final r in await tx.query(
        'raw_backfill_items',
        where: "run_id=? AND state IN ('hold','not_eligible')",
        whereArgs: [run],
      )) {
        final item = codec.item(r);
        if (!revert(item)) continue;
        reverted++;
        await tx.update(
          'raw_backfill_items',
          codec.values(item),
          where: 'run_id=? AND report_id=?',
          whereArgs: [run, r['report_id']],
        );
      }
      // Markers written before the item table kept the items inline.
      final inline = marker['items'];
      if (inline is Map) {
        for (final entry in inline.entries) {
          final value = entry.value;
          if (value is! Map) continue;
          final item = value.cast<String, dynamic>();
          if (revert(item)) {
            reverted++;
            inline[entry.key] = item;
          }
        }
      }
      final state = marker['state'];
      if (state == 'paused') {
        final manual =
            marker['reason'] == 'official_login_required' &&
            await store.meta(rawLoginManualKey, tx) != null;
        if (!manual) {
          marker.addAll({
            'next_attempt_at': 0,
            'transient_failures': 0,
            'failures': 0,
          });
        }
      } else if ((state == 'done' || state == 'holds') && reverted > 0) {
        marker.addAll({'state': 'filling', 'phase': 'filling', 'cursor': 0});
      }
      await store.setMeta('raw_backfill', jsonEncode(marker), tx);
    }
    await store.setMeta(rawBackfillUnstickKey, rawBackfillUnstickVersion, tx);
    return reverted;
  });
}
