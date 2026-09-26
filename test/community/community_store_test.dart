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
      expect(await store.meta('schema_version'), '1');
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

    test('project namespace matches the PC rule', () {
      expect(projectNamespace('https://X.supabase.co/'), projectNamespace('https://x.supabase.co'));
      expect(projectNamespace(''), 'unconfigured');
      // same digest as Python hashlib.sha256('https://x.supabase.co').hexdigest()[:16]
      expect(projectNamespace('https://x.supabase.co'), sha256.convert(utf8.encode('https://x.supabase.co')).toString().substring(0, 16));
    });
  });
}
