// 커뮤니티 공유용 로컬 저장소 `community.db` (contracts/community-ingest/local-store.md).
//
// 개인 DB(mysafetyreport.db)와 별도 파일이다. DB 백업·복원·서버 DB 가져오기·clearAll 은 이 파일을 건드리지 않는다.
// 앱 isolate 와 Workmanager 백그라운드 isolate 가 함께 열 수 있다 → WAL + busy_timeout, 쓰기는 짧은 트랜잭션,
// 동시 업로드·초기화는 leases 표로 막는다. 비밀(토큰·연결 비밀)은 여기에 두지 않는다(secure storage).
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const int communityStoreSchemaVersion = 1;
const String communityStoreFileName = 'community.db';

const List<String> _schema = [
  '''CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS context (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  state TEXT NOT NULL CHECK (state IN ('active','inactive')),
  contributor_fingerprint TEXT, connection_id TEXT, writer_epoch INTEGER, dataset_key TEXT,
  consent_grant_id TEXT, policy_version TEXT, consent_text_sha256 TEXT, source_app TEXT, source_mode TEXT,
  verified_at TEXT, inactive_reason TEXT)''',
  '''CREATE TABLE IF NOT EXISTS source_journal (
  event_id TEXT PRIMARY KEY,
  project_namespace TEXT NOT NULL, local_dataset_id TEXT NOT NULL, dataset_key TEXT,
  source_report_id TEXT NOT NULL, source_revision INTEGER NOT NULL,
  event_type TEXT NOT NULL, captured_at TEXT NOT NULL, capture_trigger TEXT NOT NULL,
  rebuild_run_id TEXT, schema_version INTEGER NOT NULL, parser_version TEXT NOT NULL,
  payload_json TEXT NOT NULL, payload_sha256 TEXT NOT NULL, eligible INTEGER NOT NULL,
  contributor_fingerprint TEXT, connection_id TEXT, writer_epoch INTEGER, consent_grant_id TEXT,
  personal_save_state TEXT NOT NULL DEFAULT 'pending' CHECK (personal_save_state IN ('pending','saved','failed')),
  ack_status TEXT, receipt_id TEXT, acked_at TEXT, projection_status TEXT, blocked_reason TEXT,
  UNIQUE (local_dataset_id, source_revision))''',
  '''CREATE INDEX IF NOT EXISTS source_journal_report ON source_journal(local_dataset_id, source_report_id, source_revision)''',
  '''CREATE TABLE IF NOT EXISTS outbox (
  event_id TEXT PRIMARY KEY REFERENCES source_journal(event_id),
  state TEXT NOT NULL CHECK (state IN ('pending','in_flight','retry_wait','auth_required','blocked','dead_letter')),
  attempt_count INTEGER NOT NULL DEFAULT 0, next_retry_at TEXT, lease_owner TEXT, lease_until TEXT,
  last_error_code TEXT, last_request_id TEXT, enqueued_trigger TEXT NOT NULL, enqueued_at TEXT NOT NULL)''',
  '''CREATE INDEX IF NOT EXISTS outbox_due ON outbox(state, next_retry_at)''',
  '''CREATE TABLE IF NOT EXISTS report_latest (
  local_dataset_id TEXT NOT NULL, source_report_id TEXT NOT NULL, event_id TEXT NOT NULL,
  payload_sha256 TEXT NOT NULL, eligible INTEGER NOT NULL, source_generation INTEGER NOT NULL,
  PRIMARY KEY (local_dataset_id, source_report_id))''',
  '''CREATE TABLE IF NOT EXISTS report_latest_staging (
  run_id TEXT NOT NULL, source_report_id TEXT NOT NULL, event_id TEXT NOT NULL,
  payload_sha256 TEXT NOT NULL, eligible INTEGER NOT NULL, PRIMARY KEY (run_id, source_report_id))''',
  '''CREATE TABLE IF NOT EXISTS detail_status (
  local_dataset_id TEXT NOT NULL, source_report_id TEXT NOT NULL, c_now_label TEXT NOT NULL, observed_at TEXT NOT NULL,
  PRIMARY KEY (local_dataset_id, source_report_id))''',
  '''CREATE TABLE IF NOT EXISTS server_completed (
  dataset_key TEXT NOT NULL, key_prefix TEXT NOT NULL, fetched_at TEXT NOT NULL, PRIMARY KEY (dataset_key, key_prefix))''',
  '''CREATE TABLE IF NOT EXISTS upload_runs (
  run_id TEXT PRIMARY KEY, trigger TEXT NOT NULL, schedule_key TEXT, contributor_fingerprint TEXT,
  started_at TEXT NOT NULL, finished_at TEXT,
  result TEXT CHECK (result IN ('running','no_change','success','partial','auth_required','consent_required',
                                'connection_required','offline','failed','deferred')),
  counts_json TEXT NOT NULL DEFAULT '{}', request_ids TEXT NOT NULL DEFAULT '[]', error_code TEXT)''',
  '''CREATE TABLE IF NOT EXISTS schedule_runs (
  project_namespace TEXT NOT NULL, contributor_fingerprint TEXT NOT NULL, local_dataset_id TEXT NOT NULL,
  writer_epoch INTEGER NOT NULL, schedule_key TEXT NOT NULL, scheduled_date_kst TEXT NOT NULL, due_at_utc TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('due','running','succeeded','deferred','failed')),
  attempts INTEGER NOT NULL DEFAULT 0, last_attempt_at TEXT, finished_at TEXT, deferred_reason TEXT,
  lease_owner TEXT, lease_until TEXT, run_id TEXT,
  PRIMARY KEY (project_namespace, contributor_fingerprint, local_dataset_id, writer_epoch, schedule_key))''',
  '''CREATE TABLE IF NOT EXISTS leases (name TEXT PRIMARY KEY, owner TEXT NOT NULL, until TEXT NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS rebuild_jobs (
  run_id TEXT PRIMARY KEY, required_version TEXT NOT NULL, local_dataset_id TEXT NOT NULL,
  source_account_namespace TEXT NOT NULL, state TEXT NOT NULL, phase TEXT, confirmed_at TEXT,
  started_at TEXT, updated_at TEXT NOT NULL, completed_at TEXT, list_complete INTEGER NOT NULL DEFAULT 0,
  counts_json TEXT NOT NULL DEFAULT '{}', backup_ref TEXT, backup_check TEXT, last_error TEXT,
  source_generation INTEGER, gaps_accepted_at TEXT)''',
  '''CREATE UNIQUE INDEX IF NOT EXISTS rebuild_one_active ON rebuild_jobs(required_version, local_dataset_id, source_account_namespace)
  WHERE state NOT IN ('completed','completed_with_gaps','abandoned')''',
  '''CREATE TABLE IF NOT EXISTS rebuild_items (
  run_id TEXT NOT NULL, source_report_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending','fetched','failed_retryable','failed_permanent')),
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, event_id TEXT, last_list_label TEXT,
  PRIMARY KEY (run_id, source_report_id))''',
];

const List<String> contextFields = [
  'contributor_fingerprint', 'connection_id', 'writer_epoch', 'dataset_key', 'consent_grant_id',
  'policy_version', 'consent_text_sha256', 'source_app', 'source_mode',
];

String isoUtc(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${three(u.millisecond)}Z';
}

/// 공개 설정의 Supabase URL 로 만든 네임스페이스(PC `project_namespace` 와 같은 규칙).
String projectNamespace(String? supabaseUrl) {
  var s = (supabaseUrl ?? '').trim().toLowerCase();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return 'unconfigured';
  return sha256.convert(utf8.encode(s)).toString().substring(0, 16);
}

String newUuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class CommunityStore {
  CommunityStore._(this.db, this.path);

  final Database db;
  final String path;
  static final Map<String, Future<CommunityStore>> _open = {};

  /// `path` 를 주지 않으면 앱 DB 폴더의 `community.db`. 테스트는 databaseFactory(ffi)·임시 경로를 준다.
  static Future<CommunityStore> open({String? path, DatabaseFactory? factory}) async {
    final resolved = path ?? p.join(await getDatabasesPath(), communityStoreFileName);
    return _open.putIfAbsent(resolved, () async {
      final f = factory ?? databaseFactory;
      final db = await f.openDatabase(resolved, options: OpenDatabaseOptions(
        singleInstance: true,
        onConfigure: (d) async {
          await d.rawQuery('PRAGMA journal_mode=WAL');
          await d.rawQuery('PRAGMA busy_timeout=30000');
          await d.execute('PRAGMA foreign_keys=ON');
          await d.execute('PRAGMA synchronous=FULL');
        },
      ));
      final store = CommunityStore._(db, resolved);
      await store._migrate();
      return store;
    });
  }

  /// 테스트 전용: 열린 인스턴스를 닫고 캐시에서 뺀다.
  static Future<void> closeForTest(String path) async {
    final pending = _open.remove(path);
    if (pending != null) await (await pending).db.close();
  }

  Future<void> _migrate() async {
    for (final sql in _schema) {
      await db.execute(sql);
    }
    await db.transaction((tx) async {
      final rows = await tx.rawQuery("SELECT value FROM meta WHERE key='schema_version'");
      if (rows.isEmpty) {
        await tx.insert('meta', {'key': 'schema_version', 'value': '$communityStoreSchemaVersion'});
        await tx.insert('meta', {'key': 'local_dataset_id', 'value': newUuidV4()}, conflictAlgorithm: ConflictAlgorithm.ignore);
        await tx.insert('meta', {'key': 'next_revision', 'value': '1'}, conflictAlgorithm: ConflictAlgorithm.ignore);
        await tx.insert('meta', {'key': 'dataset_history', 'value': '[]'}, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else if (int.parse(rows.first['value'] as String) > communityStoreSchemaVersion) {
        throw StateError('community.db schema ${rows.first['value']} is newer than this app');
      }
    });
  }

  Future<T> transaction<T>(Future<T> Function(Transaction tx) action) => db.transaction(action, exclusive: true);

  Future<String?> meta(String key, [DatabaseExecutor? ex]) async {
    final rows = await (ex ?? db).rawQuery('SELECT value FROM meta WHERE key=?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value, [DatabaseExecutor? ex]) =>
      (ex ?? db).insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<String> localDatasetId() async => (await meta('local_dataset_id')) ?? '';

  /// 개인 DB 가 다른 데이터셋이 됐을 때(복원·서버 DB 가져오기·모드 전환·공식 계정 변경). 이전 journal/outbox 는 지우지 않는다.
  Future<String> rotateDataset(String reason) async {
    final newId = newUuidV4();
    await transaction((tx) async {
      final old = await meta('local_dataset_id', tx);
      final history = (jsonDecode(await meta('dataset_history', tx) ?? '[]') as List).cast<Object?>();
      history.add({'dataset_id': old, 'reason': reason, 'rotated_at': isoUtc(DateTime.now())});
      await setMeta('dataset_history', jsonEncode(history), tx);
      await setMeta('local_dataset_id', newId, tx);
    });
    return newId;
  }

  /// 트랜잭션 안에서만. 로컬 데이터셋 단조 증가 revision.
  Future<int> nextRevision(Transaction tx) async {
    final value = int.tryParse(await meta('next_revision', tx) ?? '1') ?? 1;
    await setMeta('next_revision', '${value + 1}', tx);
    return value;
  }

  Future<void> raiseRevisionFloor(int lastAccepted) => transaction((tx) async {
        final value = int.tryParse(await meta('next_revision', tx) ?? '1') ?? 1;
        if (value <= lastAccepted) await setMeta('next_revision', '${lastAccepted + 1}', tx);
      });

  Future<Map<String, Object?>?> context() async {
    final rows = await db.rawQuery('SELECT * FROM context WHERE id=1');
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  Future<Map<String, Object?>?> activeContext() async {
    final c = await context();
    return (c != null && c['state'] == 'active') ? c : null;
  }

  Future<void> setContext(Map<String, Object?> fields) async {
    final unknown = fields.keys.where((k) => !contextFields.contains(k)).toList();
    if (unknown.isNotEmpty) throw ArgumentError('unknown context fields: $unknown');
    final row = <String, Object?>{'id': 1, 'state': 'active', 'verified_at': isoUtc(DateTime.now()), 'inactive_reason': null};
    for (final k in contextFields) {
      row[k] = fields[k];
    }
    await db.insert('context', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deactivateContext(String reason) => transaction((tx) async {
        final n = await tx.rawUpdate("UPDATE context SET state='inactive', inactive_reason=? WHERE id=1", [reason]);
        if (n == 0) await tx.insert('context', {'id': 1, 'state': 'inactive', 'inactive_reason': reason});
      });

  Future<bool> acquireLease(String name, String owner, Duration duration) => transaction((tx) async {
        final now = DateTime.now();
        final rows = await tx.rawQuery('SELECT owner, until FROM leases WHERE name=?', [name]);
        if (rows.isNotEmpty && rows.first['owner'] != owner && (rows.first['until'] as String).compareTo(isoUtc(now)) > 0) {
          return false;
        }
        await tx.insert('leases', {'name': name, 'owner': owner, 'until': isoUtc(now.add(duration))},
            conflictAlgorithm: ConflictAlgorithm.replace);
        return true;
      });

  Future<void> releaseLease(String name, String owner) =>
      db.delete('leases', where: 'name=? AND owner=?', whereArgs: [name, owner]);
}
