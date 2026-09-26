// schedule catchUp·게이트 캐시 테스트 (순수 벡터는 contract_vectors_test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/upload/community_schedule.dart';
import 'package:safetyreport/community/upload/community_uploader.dart';

Future<CommunityStore> openStore() async {
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('sr_t6_sched_');
  final store = await CommunityStore.open(
      path: '${dir.path}/community.db', factory: databaseFactoryFfi);
  await store.setContext({
    'contributor_fingerprint': 'fp1',
    'connection_id': '11111111-1111-4111-8111-111111111111',
    'writer_epoch': 1,
    'dataset_key': 'ds1',
    'consent_grant_id': '22222222-2222-4222-8222-222222222222',
    'policy_version': '2026-09-26.1',
    'consent_text_sha256': 'abc',
    'source_app': 'safetyreport-mobile',
    'source_mode': 'standalone',
  });
  return store;
}

Future<void> closeStore(CommunityStore store) async {
  final path = store.path;
  await store.db.close();
  await CommunityStore.closeForTest(path);
  try {
    await Directory(File(path).parent.path).delete(recursive: true);
  } catch (_) {}
}

void main() {
  group('catchUp', () {
    late CommunityStore store;
    setUp(() async => store = await openStore());
    tearDown(() async => closeStore(store));

    test('첫 실행은 midnight 업로드를 한 번 실행한다', () async {
      var triggers = <String>[];
      final state = await catchUp('os',
          store: store,
          runUpload: (t) async {
            triggers.add(t);
            return const UploadRunResult(
                runId: 'r1', result: 'success', counts: {'sent': 2});
          },
          now: DateTime.utc(2026, 9, 26, 3));
      expect(state, equals('succeeded'));
      expect(triggers, equals(['midnight']));
      final rows = await store.db.rawQuery('SELECT state FROM schedule_runs');
      expect(rows.first['state'], equals('succeeded'));
    });

    test('succeeded 키는 다시 실행하지 않는다', () async {
      var calls = 0;
      Future<UploadRunResult> run(String t) async {
        calls++;
        return const UploadRunResult(runId: 'r', result: 'success');
      }

      final now = DateTime.utc(2026, 9, 26, 3);
      await catchUp('os', store: store, runUpload: run, now: now);
      final again =
          await catchUp('os', store: store, runUpload: run, now: now);
      expect(again, equals('succeeded'));
      expect(calls, equals(1));
    });

    test('context 없으면 deferred', () async {
      await store.deactivateContext('test');
      final state = await catchUp('os',
          store: store,
          runUpload: (t) async =>
              const UploadRunResult(runId: 'r', result: 'success'),
          now: DateTime.utc(2026, 9, 26, 3));
      expect(state, equals('deferred'));
    });
  });

  group('gate cache', () {
    test('ok + 600초 이내만 true', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      expect(await isGateCacheFresh(prefs, now), isFalse);
      await prefs.setString('community_gate_cache_v1',
          '{"state":"ok","verified_at":${now.millisecondsSinceEpoch}}');
      expect(await isGateCacheFresh(prefs, now), isTrue);
      expect(
          await isGateCacheFresh(
              prefs, now.add(const Duration(seconds: 601))),
          isFalse);
      await prefs.setString('community_gate_cache_v1',
          '{"state":"consent_required","verified_at":${now.millisecondsSinceEpoch}}');
      expect(await isGateCacheFresh(prefs, now), isFalse);
    });
  });
}
