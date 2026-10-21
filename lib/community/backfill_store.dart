import 'dart:convert';
import 'community_store.dart';
import 'raw_backfill.dart';

const backfillSchema = <String>[
  "CREATE TABLE IF NOT EXISTS raw_backfill_items (run_id TEXT NOT NULL,report_id TEXT NOT NULL,position INTEGER NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,eligible INTEGER NOT NULL DEFAULT 0,was_missing INTEGER NOT NULL DEFAULT 0,event_id TEXT,filled INTEGER NOT NULL DEFAULT 0,unfilled INTEGER NOT NULL DEFAULT 0,detail_json TEXT NOT NULL DEFAULT '{}',PRIMARY KEY(run_id,report_id))",
  'CREATE INDEX IF NOT EXISTS raw_backfill_position ON raw_backfill_items(run_id,position)',
  'CREATE INDEX IF NOT EXISTS raw_backfill_state ON raw_backfill_items(run_id,state,position)',
  'CREATE TABLE IF NOT EXISTS raw_backfill_supplements (local_dataset_id TEXT NOT NULL,report_id TEXT NOT NULL,kind TEXT NOT NULL,status TEXT NOT NULL,PRIMARY KEY(local_dataset_id,report_id,kind))',
  'CREATE TABLE IF NOT EXISTS raw_body_blobs (sha256 TEXT PRIMARY KEY,raw_zlib BLOB NOT NULL)',
];
const _keys = [
  'state',
  'attempts',
  'eligible',
  'was_missing',
  'event_id',
  'filled',
  'unfilled',
];

class SqliteBackfillItems implements BackfillItems {
  SqliteBackfillItems(this.store, this.check);
  final CommunityStore store;
  final Future<void> Function() check;
  Map<String, Object?> values(Map<String, dynamic> i) => {
    for (final k in _keys)
      k: (k == 'eligible' || k == 'was_missing')
          ? (i[k] == true ? 1 : 0)
          : i[k] ?? (['attempts', 'filled', 'unfilled'].contains(k) ? 0 : null),
    'detail_json': jsonEncode({
      for (final e in i.entries)
        if (!_keys.contains(e.key)) e.key: e.value,
    }),
  };
  Map<String, dynamic> item(Map<String, Object?> r) => {
    ...(jsonDecode(r['detail_json'] as String) as Map).cast<String, dynamic>(),
    for (final k in _keys)
      k: (k == 'eligible' || k == 'was_missing') ? r[k] == 1 : r[k],
  };
  @override
  Future<void> reset(
    String run,
    Map<String, Map<String, dynamic>> items,
  ) async {
    await check();
    await store.transaction((tx) async {
      // Only the current run's rows are kept (earlier runs are finished or replaced).
      await tx.delete(
        'raw_backfill_items',
        where: 'run_id=? OR run_id<>?',
        whereArgs: [run, run],
      );
      final batch = tx.batch();
      var p = 0;
      for (final e in items.entries) {
        batch.insert('raw_backfill_items', {
          'run_id': run,
          'report_id': e.key,
          'position': p++,
          ...values(e.value),
        });
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> loadLegacy(String run, Map<String, dynamic> items) async {
    if (await size(run) == 0) {
      await reset(run, {
        for (final e in items.entries)
          e.key: (e.value as Map).cast<String, dynamic>(),
      });
    }
  }

  @override
  Future<void> retry(String run) async {
    await check();
    await store.db.rawUpdate(
      "UPDATE raw_backfill_items SET state='pending',attempts=0,event_id=NULL WHERE run_id=? AND state='hold'",
      [run],
    );
  }

  @override
  Future<List<(int, String, Map<String, dynamic>)>> page(
    String run,
    int cursor,
    int limit,
  ) async => [
    for (final r in await store.db.query(
      'raw_backfill_items',
      where: 'run_id=? AND position>=?',
      whereArgs: [run, cursor],
      orderBy: 'position',
      limit: limit,
    ))
      (r['position'] as int, r['report_id'] as String, item(r)),
  ];
  @override
  Future<List<(String, Map<String, dynamic>)>> queued(
    String run,
    int limit,
  ) async => [
    for (final r in await store.db.query(
      'raw_backfill_items',
      where: "run_id=? AND state='queued'",
      whereArgs: [run],
      orderBy: 'position',
      limit: limit,
    ))
      (r['report_id'] as String, item(r)),
  ];
  @override
  Future<void> put(String run, String id, Map<String, dynamic> i) async {
    await check();
    await store.db.update(
      'raw_backfill_items',
      values(i),
      where: 'run_id=? AND report_id=?',
      whereArgs: [run, id],
    );
  }

  @override
  Future<int> size(String run) async =>
      (await store.db.rawQuery(
            'SELECT COUNT(*) n FROM raw_backfill_items WHERE run_id=?',
            [run],
          )).first['n']
          as int;
  @override
  Future<Map<String, int>> summary(String run) async {
    final row = (await store.db.rawQuery(
      """SELECT COUNT(CASE WHEN eligible=1 AND state!='not_eligible' THEN 1 END) total,
      COUNT(CASE WHEN eligible=1 AND state='raw_unavailable' THEN 1 END) raw_unavailable,
      COUNT(CASE WHEN eligible=1 AND state='stored' THEN 1 END) sent,
      COALESCE(SUM(filled),0) filled,COALESCE(SUM(unfilled),0) unfilled,COALESCE(SUM(was_missing),0) missing_reports,
      COUNT(CASE WHEN state='hold' THEN 1 END) holds,
      COUNT(CASE WHEN state NOT IN ('stored','raw_unavailable','not_eligible') THEN 1 END) unfinished
      FROM raw_backfill_items WHERE run_id=?""",
      [run],
    )).first;
    final result = {
      for (final e in row.entries) e.key: (e.value as num).toInt(),
    };
    result['available'] = result['total']! - result['raw_unavailable']!;
    return result;
  }
}
