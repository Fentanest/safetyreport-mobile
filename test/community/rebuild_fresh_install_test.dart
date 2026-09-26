// 2026-09-26 초기화 크롤링 릴리스: 처음 실행(빈 개인 DB)은 안내 없이 평소대로, 이전 버전 DB 를 비운 기존 사용자는 안내한다.
// 서버 tests/test_community_rebuild.py FreshInstallAndLegacyResetTest 와 같은 규칙. 재시도 백업·일반 동기화 차단도 함께 본다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeEngine extends RebuildEngine {
  _FakeEngine();

  Object? error;
  final List<String> runs = [];

  @override
  Future<RebuildRunOutcome> run({required String runId}) async {
    runs.add(runId);
    if (error != null) throw error!;
    return const RebuildRunOutcome(listComplete: true, fetched: 1, permanentFailures: [], orphanCount: 0);
  }
}

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  setUp(() async {
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('rebuild_fresh_install_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
  });

  tearDown(() async {
    CommunityRebuildGuard.active = false;
    SyncEngine.rebuildBlocks = null;
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityRebuild makeRebuild({
    PersonalDbFacts? facts,
    bool noFacts = false,
    String namespace = 'ns-1',
    _FakeEngine? engine,
    Future<String> Function()? personalDbPath,
  }) {
    // 개인 DB 경로를 주면 실제 VACUUM INTO 백업을, 아니면 가짜 백업을 쓴다.
    final rebuild = CommunityRebuild(
      store: store,
      localDatasetId: store.localDatasetId,
      sourceNamespace: () async => namespace,
      gateFresh: () async => true,
      engine: engine ?? _FakeEngine(),
      manifestCheck: () async => true,
      backup: personalDbPath != null
          ? null
          : (_) async => const RebuildBackupResult(ok: true, ref: 'b', check: 'ok'),
      personalDbPath: personalDbPath,
      personalDbFacts: noFacts ? null : () async => facts ?? (reports: 0, legacyReset: null),
    );
    addTearDown(rebuild.dispose);
    return rebuild;
  }

  Future<List<Map<String, Object?>>> rows() =>
      store.db.rawQuery('SELECT state, confirmed_at, counts_json FROM rebuild_jobs');

  test('a fresh install needs no rebuild and records one baseline', () async {
    final rebuild = makeRebuild();
    expect(await rebuild.required(), isFalse);
    final recorded = await rows();
    expect(recorded.map((r) => (r['state'], r['confirmed_at'])),
        [(RebuildStates.completed, communityRebuildFreshInstallBaseline)]);
    // 첫 동기화로 신고가 생겨도 다시 필요해지지 않는다.
    final later = makeRebuild(facts: (reports: 12, legacyReset: null));
    expect(await later.required(), isFalse);
    expect(await rows(), hasLength(1));
    expect(later.legacyReset, isNull);
  });

  test('a fresh install without an official account is not announced and records nothing', () async {
    final rebuild = makeRebuild(namespace: '');
    expect(await rebuild.required(), isFalse);
    expect(await rows(), isEmpty);
    expect(await makeRebuild().required(), isFalse); // 계정을 저장하면 그때 기준선
    expect(await rows(), hasLength(1));
  });

  test('existing reports still require the rebuild', () async {
    final rebuild = makeRebuild(facts: (reports: 3, legacyReset: null));
    expect(await rebuild.required(), isTrue);
    expect(await rows(), isEmpty);
  });

  test('a legacy-reset user is guided even with an empty DB', () async {
    final legacy = {'from_version': 10, 'backup': '/data/standalone_reports.db.legacy_v10.1.bak'};
    final engine = _FakeEngine();
    final rebuild = makeRebuild(facts: (reports: 0, legacyReset: legacy), engine: engine);
    expect(await rebuild.required(), isTrue);
    expect(rebuild.legacyReset?['backup'], legacy['backup']);
    expect(await makeRebuild(facts: (reports: 0, legacyReset: legacy), namespace: '').required(), isTrue);
    expect(await rebuild.start(confirmedBy: 'user'), isTrue);
    expect(engine.runs, hasLength(1));
    expect(await rebuild.required(), isFalse);
  });

  test('unreadable personal DB or no facts at all is not a fresh install', () async {
    expect(await makeRebuild(facts: (reports: null, legacyReset: null)).required(), isTrue);
    expect(await makeRebuild(noFacts: true).required(), isTrue);
    expect(await rows(), isEmpty);
  });

  test('retrying a failed run makes a new backup instead of failing on the old copy', () async {
    // 예전: 같은 run 의 재시도가 같은 이름으로 VACUUM INTO 를 다시 해 "output file already exists" 로 실패했다.
    final personal = '${tmp.path}/personal.db';
    final db = await databaseFactoryFfi.openDatabase(personal);
    await db.execute('CREATE TABLE reports (ID TEXT PRIMARY KEY)');
    await db.insert('reports', {'ID': 'r1'});
    await db.close();
    final engine = _FakeEngine()..error = StateError('network down');
    final rebuild = makeRebuild(
      facts: (reports: 1, legacyReset: null),
      engine: engine,
      personalDbPath: () async => personal,
    );
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect(rebuild.state, RebuildStates.failed);
    final firstBackup = rebuild.job?['backup_ref'] as String?;
    expect(firstBackup, isNotNull);
    expect(File(firstBackup!).existsSync(), isTrue);

    engine.error = null;
    expect(await rebuild.start(confirmedBy: 'user'), isTrue);
    expect(rebuild.state, RebuildStates.completed);
    expect(rebuild.job?['backup_ref'], firstBackup, reason: '같은 run, 같은 이름의 새 사본');
    expect(rebuild.job?['backup_check'], 'ok');
    final copy = await databaseFactoryFfi.openDatabase(firstBackup, options: OpenDatabaseOptions(readOnly: true));
    expect((await copy.query('reports')).single['ID'], 'r1');
    await copy.close();
  });

  test('a rebuild that is required blocks a normal sync before any network call', () async {
    var asked = 0;
    SyncEngine.rebuildBlocks = () async {
      asked++;
      return true;
    };
    final result = await SyncEngine.start(fullSync: false);
    expect(asked, 1);
    expect(result.failed, isTrue);
    expect(result.errorMessage, SyncEngine.rebuildBlockedMessage);
    // 막힌 뒤 다시 시작할 수 있다(실행 중 표시가 남지 않음).
    final again = await SyncEngine.start(fullSync: true);
    expect(again.errorMessage, SyncEngine.rebuildBlockedMessage);
    expect(asked, 2);
  });

  test('a failing rebuild check also blocks a normal sync (fail-closed)', () async {
    SyncEngine.rebuildBlocks = () async => throw StateError('community store unavailable');
    final result = await SyncEngine.start(fullSync: false);
    expect(result.failed, isTrue);
    expect(result.errorMessage, SyncEngine.rebuildBlockedMessage);
  });

  test('an empty site list marks the rebuild list as complete', () async {
    await store.db.insert('rebuild_jobs', {
      'run_id': 'run-empty',
      'required_version': communityRebuildRequiredVersion,
      'local_dataset_id': await store.localDatasetId(),
      'source_account_namespace': 'ns-1',
      'state': RebuildStates.running,
      'updated_at': 't',
    });
    await SyncEngine.markRebuildListComplete(store, 'run-empty');
    final row = await store.db.rawQuery("SELECT list_complete FROM rebuild_jobs WHERE run_id='run-empty'");
    expect(row.single['list_complete'], 1);
  });
}
