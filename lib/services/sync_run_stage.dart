import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../community/community_store.dart';
import 'performance_trace.dart';

class SyncStagedItem {
  const SyncStagedItem(this.item, this.previous);
  final Map<String, dynamic> item;
  final Map<String, String>? previous;
}

/// One run owns these private TEMP tables. All account-sized state stays in
/// SQLite; list/status payloads cross to Dart in at most 200-row pages.
class SyncRunStage {
  SyncRunStage._(this.personal, this.community, this.table, this.events);
  final Database personal;
  final CommunityStore community;
  final String table;
  final String events;

  static Future<SyncRunStage> create(Database personal, CommunityStore community) async {
    final suffix = newUuidV4().replaceAll('-', '');
    final stage = SyncRunStage._(personal, community, 'sr_sync_$suffix', 'sr_sync_events_$suffix');
    await personal.execute('CREATE TEMP TABLE ${stage.table}(seq INTEGER PRIMARY KEY, source_id TEXT UNIQUE NOT NULL, item TEXT NOT NULL, original_exists INTEGER NOT NULL, original_status TEXT, original_finished TEXT, original_supplement TEXT, todo INTEGER NOT NULL DEFAULT 0)');
    try { await community.db.execute('CREATE TEMP TABLE ${stage.events}(event_id TEXT PRIMARY KEY NOT NULL)'); }
    catch (_) { await personal.execute('DROP TABLE temp.${stage.table}'); rethrow; }
    return stage;
  }

  Future<void> addPage(List<Map<String,dynamic>> items) => personal.transaction((tx) async {
    final batch = tx.batch();
    for (final item in items) {
      batch.rawInsert('INSERT INTO $table(source_id,item,original_exists,original_status,original_finished,original_supplement) SELECT ?,?,r.ID IS NOT NULL,r.처리상태,r.종결여부,r.보완_미응답 FROM (SELECT 1) LEFT JOIN reports r ON r.ID=?', [item['C_NO'].toString(),jsonEncode(item),item['C_NO'].toString()]);
    }
    await batch.commit(noResult:true);
  });

  Stream<List<SyncStagedItem>> pages({bool todoOnly=false}) async* {
    var cursor=0;
    while(true) {
      final rows=await PerformanceTrace.sql('sync.stage_page',()=>personal.rawQuery('SELECT * FROM $table WHERE seq>? ${todoOnly?'AND todo=1':''} ORDER BY seq LIMIT 200',[cursor]));
      if(rows.isEmpty) return;
      cursor=rows.last['seq'] as int;
      yield [for(final row in rows) SyncStagedItem(Map<String,dynamic>.from(jsonDecode(row['item'] as String) as Map),row['original_exists']==1?{
        '처리상태':row['original_status']?.toString()??'',
        '종결여부':row['original_finished']?.toString()??'',
        '보완_미응답':row['original_supplement']=='Y'?'Y':'N',
      }:null)];
    }
  }

  Future<void> select(Iterable<String> ids) => personal.transaction((tx) async {
    final batch=tx.batch();
    for(final id in ids) { batch.rawUpdate('UPDATE $table SET todo=1 WHERE source_id=?',[id]); }
    await batch.commit(noResult:true);
  });
  Future<int> get todoCount async => Sqflite.firstIntValue(await personal.rawQuery('SELECT COUNT(*) FROM $table WHERE todo=1'))??0;
  Future<int> get count async => Sqflite.firstIntValue(await personal.rawQuery('SELECT COUNT(*) FROM $table'))??0;
  Future<int> get orphanCount async => Sqflite.firstIntValue(await personal.rawQuery('SELECT COUNT(*) FROM reports r WHERE NOT EXISTS(SELECT 1 FROM $table s WHERE s.source_id=r.ID)'))??0;
  Future<void> recordEvent(String id) => community.db.insert(events,{'event_id':id},conflictAlgorithm:ConflictAlgorithm.ignore);
  Future<({int acked,int queued})> progress() async {
    final row=(await PerformanceTrace.sql('sync.progress',()=>community.db.rawQuery('SELECT COALESCE(SUM(j.acked_at IS NOT NULL),0) AS acked,COALESCE(SUM(j.acked_at IS NOT NULL OR o.event_id IS NOT NULL),0) AS queued FROM $events e JOIN source_journal j ON j.event_id=e.event_id LEFT JOIN outbox o ON o.event_id=j.event_id'))).first;
    return (acked:(row['acked'] as num).toInt(),queued:(row['queued'] as num).toInt());
  }
  Future<void> close() async {
    try { await personal.execute('DROP TABLE IF EXISTS temp.$table'); }
    finally { await community.db.execute('DROP TABLE IF EXISTS temp.$events'); }
  }
}
