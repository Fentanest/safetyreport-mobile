// 백그라운드(WorkManager) isolate 의 다시 불러오기 차단 판정 — 포그라운드 main.dart 의 standaloneRebuild(...).required() 와
// 같은 규칙을 ReportProvider 없이 계산한다(2026-10-12, Standalone 백그라운드 다시 불러오기 병합 뒤 남은 위험).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/gate_state.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late String dbPath;
  late CommunityStore store;
  const id = 'reporter01';
  Future<PersonalDbFacts> existing() async => (reports: 12, legacyReset: null);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bg_rebuild_block');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(
      path: dbPath,
      factory: databaseFactoryFfi,
    );
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.standaloneUsername: id,
    });
  });

  tearDown(() async {
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  Future<void> job(String state) async => store.db.insert('rebuild_jobs', {
    'run_id': 'run-$state',
    'required_version': communityRebuildRequiredVersion,
    'local_dataset_id': await store.localDatasetId(),
    'source_account_namespace': datasetKeyForOfficialId(id),
    'state': state,
    'phase': 'collect',
    'updated_at': '2026-10-12T00:00:00Z',
  });

  test('기존 신고가 있는데 다시 불러오기를 안 했으면 막는다', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(
      await headlessRebuildRequired(store, prefs, personalDbFacts: existing),
      isTrue,
    );
  });

  test('다시 불러오기가 일시정지 중이면 막는다(백그라운드 전체 수집이 먼저 돌지 않게)', () async {
    await job(RebuildStates.paused);
    final prefs = await SharedPreferences.getInstance();
    expect(
      await headlessRebuildRequired(store, prefs, personalDbFacts: existing),
      isTrue,
    );
  });

  test('완료했으면 막지 않는다', () async {
    await job(RebuildStates.completed);
    final prefs = await SharedPreferences.getInstance();
    expect(
      await headlessRebuildRequired(store, prefs, personalDbFacts: existing),
      isFalse,
    );
  });

  test('새 설치(기존 신고 없음)는 막지 않는다', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(
      await headlessRebuildRequired(
        store,
        prefs,
        personalDbFacts: () async => (reports: 0, legacyReset: null),
      ),
      isFalse,
    );
  });
}
