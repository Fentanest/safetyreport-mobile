// community.db 골격(contracts/community-ingest/local-store.md)과 계약 사본 무결성.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('contract copy matches MANIFEST.sha256', () {
    final dir = Directory('contracts/community-ingest');
    final listed = <String>{};
    for (final line in File('${dir.path}/MANIFEST.sha256').readAsLinesSync()) {
      final digest = line.substring(0, 64);
      final rel = line.substring(66).replaceFirst('./', '');
      listed.add(rel);
      expect(sha256.convert(File('${dir.path}/$rel').readAsBytesSync()).toString(), digest, reason: rel);
    }
    final actual = dir.listSync(recursive: true).whereType<File>()
        .map((f) => f.path.substring(dir.path.length + 1)).where((p) => p != 'MANIFEST.sha256').toSet();
    expect(actual, listed);
  });

  group('CommunityStore', () {
    late Directory tmp;
    late String path;
    late CommunityStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('community_store_test');
      path = '${tmp.path}/community.db';
      store = await CommunityStore.open(path: path, factory: databaseFactoryFfi);
    });

    tearDown(() async {
      await CommunityStore.closeForTest(path);
      await tmp.delete(recursive: true);
    });

    test('schema, meta and WAL', () async {
      final tables = (await store.db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
          .map((r) => r['name']).toSet();
      for (final t in ['meta', 'context', 'source_journal', 'outbox', 'report_latest', 'report_latest_staging',
        'detail_status', 'server_completed', 'upload_runs', 'schedule_runs', 'leases', 'rebuild_jobs', 'rebuild_items']) {
        expect(tables, contains(t));
      }
      expect(await store.meta('schema_version'), '$communityStoreSchemaVersion');
      expect(await store.localDatasetId(), isNotEmpty);
      expect((await store.db.rawQuery('PRAGMA journal_mode')).first.values.first, 'wal');
    });

    test('revision is file-wide monotonic across dataset rotation', () async {
      final first = await store.transaction((tx) => store.nextRevision(tx));
      final old = await store.localDatasetId();
      final rotated = await store.rotateDataset('restore');
      expect(rotated, isNot(old));
      final history = jsonDecode((await store.meta('dataset_history'))!) as List;
      expect(history.single['reason'], 'restore');
      final second = await store.transaction((tx) => store.nextRevision(tx));
      expect(second, first + 1);
      await store.raiseRevisionFloor(100);
      expect(await store.transaction((tx) => store.nextRevision(tx)), 101);
    });

    test('context active / inactive and unknown fields', () async {
      expect(await store.activeContext(), isNull);
      await store.setContext({'contributor_fingerprint': 'f' * 32, 'connection_id': 'c', 'writer_epoch': 3,
        'dataset_key': 'd' * 64, 'consent_grant_id': 'g', 'policy_version': '2026-09-26.1',
        'consent_text_sha256': 'h' * 64, 'source_app': 'safetyreport-mobile', 'source_mode': 'standalone'});
      expect((await store.activeContext())!['writer_epoch'], 3);
      await store.deactivateContext('consent_revoked');
      expect(await store.activeContext(), isNull);
      expect((await store.context())!['inactive_reason'], 'consent_revoked');
      expect(() => store.setContext({'token': 'x'}), throwsArgumentError);
    });

    test('lease is exclusive until released', () async {
      expect(await store.acquireLease('upload', 'a', const Duration(minutes: 1)), isTrue);
      expect(await store.acquireLease('upload', 'b', const Duration(minutes: 1)), isFalse);
      await store.releaseLease('upload', 'a');
      expect(await store.acquireLease('upload', 'b', const Duration(minutes: 1)), isTrue);
    });

    test('a v1 file upgrades to v2 keeping every row (PC test_v1_file_upgrades_to_v2_keeping_every_row)', () async {
      // v1 파일을 만든다: v2 로 연 뒤 v2 단계를 되돌린다(upload_control 없음, 옛 결과 CHECK 의 upload_runs, schema_version 1).
      await CommunityStore.closeForTest(path);
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.execute('DROP TABLE upload_control');
      await raw.execute('DROP TABLE upload_runs');
      await raw.execute('''CREATE TABLE upload_runs (
  run_id TEXT PRIMARY KEY, trigger TEXT NOT NULL, schedule_key TEXT, contributor_fingerprint TEXT,
  started_at TEXT NOT NULL, finished_at TEXT,
  result TEXT CHECK (result IN ('running','no_change','success','partial','auth_required','consent_required',
                                'connection_required','offline','failed','deferred')),
  counts_json TEXT NOT NULL DEFAULT '{}', request_ids TEXT NOT NULL DEFAULT '[]', error_code TEXT)''');
      await raw.execute('DROP INDEX IF EXISTS journal_ack');
      await raw.execute("UPDATE meta SET value='1' WHERE key='schema_version'");
      await raw.execute("UPDATE meta SET value='ds-1' WHERE key='local_dataset_id'");
      await raw.execute("INSERT INTO source_journal(event_id, project_namespace, local_dataset_id, source_report_id,"
          " source_revision, event_type, captured_at, capture_trigger, schema_version, parser_version,"
          " payload_json, payload_sha256, eligible) VALUES ('e1','ns','ds-1','R1',7,'completed_observation',"
          " '2026-09-26T00:00:00.000Z','realtime',1,'p','{\"a\":\"한글\"}','h',1)");
      await raw.execute("INSERT INTO outbox(event_id, state, attempt_count, next_retry_at, enqueued_trigger, enqueued_at)"
          " VALUES ('e1','retry_wait',3,'2026-09-26T01:00:00.000Z','realtime','2026-09-26T00:00:00.000Z')");
      await raw.execute("INSERT INTO upload_runs(run_id, trigger, started_at, finished_at, result)"
          " VALUES ('r1','realtime','2026-09-26T00:00:00.000Z','2026-09-26T00:00:01.000Z','deferred')");
      await expectLater(
          raw.execute("INSERT INTO upload_runs(run_id, trigger, started_at, result) VALUES ('x','recovery','t','cooldown')"),
          throwsA(anything), reason: 'v1 은 새 결과 코드를 받지 않는다(재생성이 필요한 이유)');
      await raw.close();
      store = await CommunityStore.open(path: path, factory: databaseFactoryFfi);
      expect(await store.meta('schema_version'), '2');
      expect(await store.localDatasetId(), 'ds-1');
      final row = (await store.db.rawQuery('SELECT * FROM outbox')).single;
      expect((row['state'], row['attempt_count'], row['next_retry_at']), ('retry_wait', 3, '2026-09-26T01:00:00.000Z'));
      expect((await store.db.rawQuery('SELECT payload_json FROM source_journal')).single['payload_json'], '{"a":"한글"}');
      expect((await store.db.rawQuery('SELECT result FROM upload_runs')).single['result'], 'deferred');
      await store.db.execute("INSERT INTO upload_runs(run_id, trigger, started_at, result) VALUES ('r2','recovery','t','cooldown')");
      expect(await store.db.rawQuery('SELECT * FROM upload_control'), isEmpty);
    });

    test('lease renew only by its owner', () async {
      expect(await store.acquireLease('upload', 'run:a', const Duration(seconds: 60)), isTrue);
      expect(await store.renewLease('upload', 'run:a', const Duration(seconds: 60)), isTrue);
      expect(await store.renewLease('upload', 'run:b', const Duration(seconds: 60)), isFalse);
      expect(await store.acquireLease('upload', 'run:b', const Duration(seconds: 60)), isFalse);
    });

    test('project namespace matches the PC rule', () {
      expect(projectNamespace('https://X.supabase.co/'), projectNamespace('https://x.supabase.co'));
      expect(projectNamespace(''), 'unconfigured');
      // same digest as Python hashlib.sha256('https://x.supabase.co').hexdigest()[:16]
      expect(projectNamespace('https://x.supabase.co'), sha256.convert(utf8.encode('https://x.supabase.co')).toString().substring(0, 16));
    });
  });
}
