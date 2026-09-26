// 초기화 상태기계 — 가짜 엔진·백업 주입 (G01·G02·G05·G06·G07·G12·G16 해당 부분).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeEngine extends RebuildEngine {
  _FakeEngine({this.outcome});

  RebuildRunOutcome? outcome;
  Object? error;
  final List<String> runs = [];

  @override
  Future<RebuildRunOutcome> run({required String runId}) async {
    runs.add(runId);
    if (error != null) throw error!;
    return outcome ??
        const RebuildRunOutcome(
          listComplete: true,
          fetched: 5,
          permanentFailures: [],
          orphanCount: 2,
        );
  }
}

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rebuild_state_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
  });

  tearDown(() async {
    CommunityRebuildGuard.active = false;
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityRebuild makeRebuild({
    _FakeEngine? engine,
    Future<RebuildBackupResult> Function(String runId)? backup,
    Future<bool> Function()? gateFresh,
    Future<bool> Function()? manifestCheck,
    String namespace = 'ns-1',
  }) {
    final rebuild = CommunityRebuild(
      store: store,
      localDatasetId: store.localDatasetId,
      sourceNamespace: () async => namespace,
      gateFresh: gateFresh ?? () async => true,
      engine: engine ?? _FakeEngine(),
      backup:
          backup ?? (_) async => const RebuildBackupResult(ok: true, ref: 'b', check: 'ok'),
      manifestCheck: manifestCheck ?? () async => true,
    );
    addTearDown(rebuild.dispose);
    return rebuild;
  }

  test('G01: no completed row means required; success completes', () async {
    final engine = _FakeEngine();
    final rebuild = makeRebuild(engine: engine);
    expect(await rebuild.required(), isTrue);
    expect(await rebuild.start(confirmedBy: 'user'), isTrue);
    expect(rebuild.state, RebuildStates.completed);
    expect(await rebuild.required(), isFalse);
    expect(engine.runs, hasLength(1));
    expect(rebuild.counts()['orphan_preserved'], 2);
    expect(CommunityRebuildGuard.active, isFalse);
  });

  test('G02: gate not fresh blocks before manifest and engine', () async {
    var manifestCalls = 0;
    final engine = _FakeEngine();
    final rebuild = makeRebuild(
      engine: engine,
      gateFresh: () async => false,
      manifestCheck: () async {
        manifestCalls++;
        return true;
      },
    );
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect(rebuild.state, RebuildStates.prerequisitesRequired);
    expect(manifestCalls, 0);
    expect(engine.runs, isEmpty);
  });

  test('G05: manifest failure blocks engine start', () async {
    final engine = _FakeEngine();
    final rebuild = makeRebuild(engine: engine, manifestCheck: () async => false);
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect((rebuild.job?['last_error'] as String?), 'manifest_unavailable');
    expect(engine.runs, isEmpty);
  });

  test('G06: backup failure leaves failed with no changes', () async {
    final engine = _FakeEngine();
    final rebuild = makeRebuild(
      engine: engine,
      backup: (_) async => const RebuildBackupResult(ok: false, error: 'no_space'),
    );
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect(rebuild.state, RebuildStates.failed);
    expect(engine.runs, isEmpty);
    expect(rebuild.job?['backup_ref'], isNull);
  });

  test('G07: partial list failure retries the same run', () async {
    final engine = _FakeEngine(
      outcome: const RebuildRunOutcome(
        listComplete: false,
        fetched: 0,
        permanentFailures: [],
        orphanCount: 0,
      ),
    );
    final rebuild = makeRebuild(engine: engine);
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect(rebuild.state, RebuildStates.failed);
    final firstRun = rebuild.job?['run_id'];
    engine.outcome = const RebuildRunOutcome(
      listComplete: true,
      fetched: 1,
      permanentFailures: [],
      orphanCount: 0,
    );
    expect(await rebuild.start(confirmedBy: 'user'), isTrue);
    expect(rebuild.job?['run_id'], firstRun, reason: '같은 run 재개');
  });

  test('G12: permanent gaps need explicit accept', () async {
    final engine = _FakeEngine(
      outcome: const RebuildRunOutcome(
        listComplete: true,
        fetched: 4,
        permanentFailures: ['R-1', 'R-2'],
        orphanCount: 1,
      ),
    );
    final rebuild = makeRebuild(engine: engine);
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect(rebuild.state, RebuildStates.validating);
    expect(rebuild.notice, contains('2건'));
    await rebuild.acceptGaps();
    expect(rebuild.state, RebuildStates.completedWithGaps);
    expect(await rebuild.required(), isFalse);
  });

  test('G16: revoke during run pauses; resume continues', () async {
    final engine = _FakeEngine()..error = Exception('consent revoked');
    final rebuild = makeRebuild(engine: engine);
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect(rebuild.state, RebuildStates.paused);
    engine.error = null;
    await rebuild.resume();
    expect(rebuild.state, RebuildStates.completed);
  });

  test('app restart resumes the same run', () async {
    final engine = _FakeEngine();
    final rebuild = makeRebuild(engine: engine);
    await rebuild.start(confirmedBy: 'user');
    final runId = rebuild.job?['run_id'];
    final rebuild2 = makeRebuild(engine: engine);
    await rebuild2.load();
    expect(rebuild2.job?['run_id'], runId);
    expect(rebuild2.state, RebuildStates.completed);
  });
}
