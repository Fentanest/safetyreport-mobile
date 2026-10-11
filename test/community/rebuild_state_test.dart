// 초기화 상태기계 — 가짜 엔진·백업 주입 (G01·G02·G05·G06·G07·G12·G16 해당 부분).
import 'dart:io';
import 'dart:async';

import 'package:safetyreport/community/rebuild/rebuild_coordinator.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:safetyreport/services/sync_operation_admission.dart';
import 'package:safetyreport/community/upload_hooks.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeEngine extends RebuildEngine {
  _FakeEngine({this.outcome});

  CommunityStore? store;
  Future<void> Function(String runId)? afterItems;
  RebuildRunOutcome? outcome;
  Object? error;
  final List<String> runs = [];

  @override
  Future<RebuildRunOutcome> run({required String runId}) async {
    runs.add(runId);
    if (error != null) throw error!;
    final result =
        outcome ??
        const RebuildRunOutcome(
          listComplete: true,
          fetched: 5,
          permanentFailures: [],
          orphanCount: 2,
        );
    if (result.listComplete) {
      for (var i = 0; i < result.fetched; i++) {
        final id = 'fetched-$i';
        await capture(
          {
            'processing_status': '처리중',
            'penalty_amount': '',
            'report_date': '2026-09-01',
            'response_date': '',
            'processing_agency': '합성기관',
            'person_in_charge': '',
            'car_number': '',
            'violation_location': '',
            'entry_value': '',
            'penalty_points': '',
            'progress_status': '처리중',
          },
          sourceReportId: id,
          trigger: 'rebuild',
          rebuildRunId: runId,
          store: store,
          projectNamespace: 'fixture',
        );
        await store!.db.insert('rebuild_items', {
          'run_id': runId,
          'source_report_id': id,
          'state': 'fetched',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final id in result.permanentFailures) {
        await store!.db.insert('rebuild_items', {
          'run_id': runId,
          'source_report_id': id,
          'state': 'failed_permanent',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    await afterItems?.call(runId);
    return result;
  }
}

class _ProgressClock extends Stopwatch {
  Duration idle = Duration.zero;
  @override
  Duration get elapsed => idle;
  @override
  void reset() {
    idle = Duration.zero;
  }
}

class _WaitingEngine extends _FakeEngine {
  final entered = Completer<void>();
  final finish = Completer<RebuildRunOutcome>();
  int cancellations = 0;
  @override
  Future<RebuildRunOutcome> run({required String runId}) {
    runs.add(runId);
    entered.complete();
    return finish.future;
  }

  @override
  void cancel() {
    cancellations++;
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
    store = await CommunityStore.open(
      path: dbPath,
      factory: databaseFactoryFfi,
    );
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
    Stopwatch? progressClock,
    Duration stallTimeout = const Duration(minutes: 5),
    Duration pollInterval = const Duration(seconds: 2),
  }) {
    engine ??= _FakeEngine();
    engine.store = store;
    final rebuild = CommunityRebuild(
      store: store,
      progressClock: progressClock,
      stallTimeout: stallTimeout,
      pollInterval: pollInterval,
      localDatasetId: store.localDatasetId,
      sourceNamespace: () async => namespace,
      gateFresh: gateFresh ?? () async => true,
      engine: engine,
      backup:
          backup ??
          (_) async =>
              const RebuildBackupResult(ok: true, ref: 'b', check: 'ok'),
      manifestCheck: manifestCheck ?? () async => true,
    );
    addTearDown(rebuild.dispose);
    return rebuild;
  }

  Future<void> abandoned({
    String state = 'running',
    String phase = 'collect',
  }) async {
    await store.db.insert('rebuild_jobs', {
      'run_id': 'old-run',
      'required_version': communityRebuildRequiredVersion,
      'local_dataset_id': await store.localDatasetId(),
      'source_account_namespace': 'ns-1',
      'state': state,
      'phase': phase,
      'updated_at': '2026-01-01T00:00:00Z',
    });
  }

  for (final phase in [
    'running',
    'preparing_backup',
    'awaiting_confirmation',
    'committing',
  ]) {
    test('recovers stale $phase without deleting the checkpoint', () async {
      await abandoned(state: phase);
      await store.db.insert('rebuild_items', {
        'run_id': 'old-run',
        'source_report_id': 'remaining',
        'state': 'pending',
      });
      await store.db.insert('leases', {
        'name': 'rebuild',
        'owner': 'dead-process',
        'until': '2026-01-01T00:30:00Z',
      });
      final rebuild = makeRebuild();
      await rebuild.refresh();
      expect(rebuild.state, RebuildStates.paused);
      expect(rebuild.job!['run_id'], 'old-run');
      expect(rebuild.lastProgressAt, DateTime.utc(2026));
      expect(rebuild.counts()['pending'], 1);
      expect(rebuild.notice, contains('중단'));
      expect(await store.db.query('rebuild_items'), hasLength(1));
    });
  }

  test(
    'expired running resumes the same run and preserves its initial backup',
    () async {
      await abandoned();
      final engine = _FakeEngine();
      final rebuild = makeRebuild(engine: engine);
      await rebuild.refresh();
      expect(await rebuild.start(confirmedBy: 'resume'), isTrue);
      expect(engine.runs, ['old-run']);
      expect(rebuild.state, RebuildStates.completed);
    },
  );

  test(
    'a fresh foreign lease is never stolen and becomes recoverable after expiry',
    () async {
      await abandoned();
      await store.acquireLease('rebuild', 'other', const Duration(minutes: 30));
      final engine = _FakeEngine();
      final rebuild = makeRebuild(engine: engine);
      await rebuild.refresh();
      expect(rebuild.waitingForWorker, isTrue);
      expect(rebuild.state, RebuildStates.running);
      expect(await rebuild.start(confirmedBy: 'user'), isFalse);
      expect(engine.runs, isEmpty);
      expect((await store.db.query('leases')).single['owner'], 'other');
      await store.db.update('leases', {'until': '2026-01-01T00:00:00Z'});
      await rebuild.refresh();
      expect(rebuild.waitingForWorker, isFalse);
      expect(rebuild.state, RebuildStates.paused);
    },
  );

  test(
    'single flight, route reattachment and pause hold ownership until late completion',
    () async {
      final engine = _WaitingEngine();
      final rebuild = makeRebuild(engine: engine);
      final coordinator = RebuildCoordinator();
      expect(coordinator.attach('same-scope', () => rebuild), same(rebuild));
      final run = rebuild.start(confirmedBy: 'user');
      await engine.entered.future;
      expect(
        coordinator.attach('same-scope', () => throw StateError('must reuse')),
        same(rebuild),
      );
      expect(rebuild.start(confirmedBy: 'double tap'), same(run));
      await rebuild.refresh();
      expect(rebuild.state, RebuildStates.running);
      rebuild.requestPause();
      expect(rebuild.stopping, isTrue);
      expect(engine.cancellations, 1);
      expect(
        await SyncOperationAdmission.run(
          () async => true,
          false,
          openStore: () async => store,
        ),
        isFalse,
      );
      engine.finish.complete(
        const RebuildRunOutcome(
          listComplete: true,
          fetched: 0,
          permanentFailures: [],
          orphanCount: 0,
        ),
      );
      expect(await run, isFalse);
      expect(rebuild.state, RebuildStates.paused);
      expect(rebuild.isExecuting, isFalse);
      expect(await store.meta('source_generation'), isNull);
      expect(await store.db.query('leases'), isEmpty);
    },
  );

  test(
    'watchdog requests cancellation without releasing a still-running future',
    () async {
      final engine = _WaitingEngine();
      final clock = _ProgressClock();
      final rebuild = makeRebuild(
        engine: engine,
        progressClock: clock,
        stallTimeout: const Duration(minutes: 5),
        pollInterval: const Duration(milliseconds: 10),
      );
      final run = rebuild.start(confirmedBy: 'user');
      await engine.entered.future;
      clock.idle = const Duration(minutes: 6);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rebuild.stopping, isTrue);
      expect(rebuild.isExecuting, isTrue);
      expect(engine.cancellations, 1);
      engine.finish.complete(
        const RebuildRunOutcome(
          listComplete: true,
          fetched: 0,
          permanentFailures: [],
          orphanCount: 0,
        ),
      );
      expect(await run, isFalse);
      expect(rebuild.job?['last_error'], 'progress_timeout');
      expect(rebuild.notice, contains('일정 시간'));
    },
  );

  test(
    'refresh exposes persisted progress while the worker is still running',
    () async {
      final engine = _WaitingEngine();
      final rebuild = makeRebuild(engine: engine);
      final run = rebuild.start(confirmedBy: 'user');
      await engine.entered.future;
      await store.db.insert('rebuild_items', {
        'run_id': rebuild.job!['run_id'],
        'source_report_id': 'saved',
        'state': 'fetched',
      });
      await store.db.update('rebuild_jobs', {'list_complete': 1});
      await rebuild.refresh();
      expect(rebuild.counts()['fetched'], 1);
      expect(rebuild.job?['list_complete'], 1);
      rebuild.requestPause();
      engine.finish.complete(
        const RebuildRunOutcome(
          listComplete: true,
          fetched: 1,
          permanentFailures: [],
          orphanCount: 0,
        ),
      );
      await run;
      expect(
        (await store.db.query('rebuild_jobs')).single['list_complete'],
        1,
        reason: 'state writes must not replace the engine checkpoint',
      );
    },
  );

  test(
    'validation resumes without collection and gaps remain explicit',
    () async {
      final first = makeRebuild(
        engine: _FakeEngine(
          outcome: const RebuildRunOutcome(
            listComplete: true,
            fetched: 2,
            permanentFailures: ['gap'],
            orphanCount: 0,
          ),
        ),
      );
      await first.start(confirmedBy: 'user');
      final engine = _FakeEngine();
      final restored = makeRebuild(engine: engine);
      await restored.refresh();
      expect(restored.state, RebuildStates.validating);
      expect(await restored.start(confirmedBy: 'resume'), isFalse);
      expect(engine.runs, isEmpty);
      expect(restored.counts()['fetched'], 2);
      await restored.acceptGaps();
      expect(restored.state, RebuildStates.completedWithGaps);
    },
  );

  test(
    'cloud upload failure or indefinite delivery cannot hold rebuild completion',
    () async {
      var wakes = 0;
      CommunityUploadHooks.uploadBeforeSync = () =>
          throw StateError('must not wait for cloud');
      CommunityUploadHooks.wakeUpload = (_) => wakes++;
      addTearDown(() {
        CommunityUploadHooks.uploadBeforeSync = null;
        CommunityUploadHooks.wakeUpload = null;
      });
      await SyncEngine.finishCollectionUpload(isRebuild: true);
      expect(wakes, 1);
    },
  );

  test(
    'lost admission ownership rejects late publication and personal writes',
    () async {
      final engine = _FakeEngine()
        ..afterItems = (_) async {
          await store.db.update(
            'leases',
            {'owner': 'replacement'},
            where: 'name=?',
            whereArgs: ['personal_sync'],
          );
          var published = false;
          await expectLater(
            SyncOperationAdmission.protectWrite(() async {
              published = true;
            }),
            throwsStateError,
          );
          expect(published, isFalse);
        };
      final rebuild = makeRebuild(engine: engine);
      expect(await rebuild.start(confirmedBy: 'user'), isFalse);
      expect(await store.meta('source_generation'), isNull);
      expect(await store.db.query('report_latest'), isEmpty);
      expect(
        (await store.db.query(
          'leases',
          where: 'name=?',
          whereArgs: ['personal_sync'],
        )).single['owner'],
        'replacement',
      );
    },
  );

  test(
    'resumed counts include successful details from previous attempts',
    () async {
      final engine = _FakeEngine()
        ..afterItems = (_) async => throw StateError('network interrupted');
      final rebuild = makeRebuild(engine: engine);
      expect(await rebuild.start(confirmedBy: 'user'), isFalse);
      engine.afterItems = null;
      engine.outcome = const RebuildRunOutcome(
        listComplete: true,
        fetched: 1,
        permanentFailures: [],
        orphanCount: 0,
      );
      expect(await rebuild.start(confirmedBy: 'resume'), isTrue);
      expect(rebuild.counts()['fetched'], 5);
    },
  );

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
    final rebuild = makeRebuild(
      engine: engine,
      manifestCheck: () async => false,
    );
    expect(await rebuild.start(confirmedBy: 'user'), isFalse);
    expect((rebuild.job?['last_error'] as String?), 'manifest_unavailable');
    expect(engine.runs, isEmpty);
  });

  test('G06: backup failure leaves failed with no changes', () async {
    final engine = _FakeEngine();
    final rebuild = makeRebuild(
      engine: engine,
      backup: (_) async =>
          const RebuildBackupResult(ok: false, error: 'no_space'),
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

  test(
    'pending work cannot publish or complete despite a successful return',
    () async {
      final engine = _FakeEngine()
        ..afterItems = (runId) async {
          await store.db.insert('rebuild_items', {
            'run_id': runId,
            'source_report_id': 'late',
            'state': 'failed_retryable',
          });
        };
      final rebuild = makeRebuild(engine: engine);
      expect(await rebuild.start(confirmedBy: 'user'), isFalse);
      expect(rebuild.state, RebuildStates.paused);
      expect(await store.meta('source_generation'), isNull);
      expect(await store.db.query('report_latest'), isEmpty);
    },
  );

  test(
    'generation changes after scope await prevent final projection publication',
    () async {
      var generation = 0;
      final engine = _FakeEngine()..store = store;
      late final CommunityRebuild rebuild;
      rebuild = CommunityRebuild(
        store: store,
        localDatasetId: store.localDatasetId,
        scopeGeneration: () => generation,
        sourceNamespace: () async {
          if (rebuild.state == RebuildStates.validating) generation++;
          return 'ns-1';
        },
        gateFresh: () async => true,
        engine: engine,
        backup: (_) async =>
            const RebuildBackupResult(ok: true, ref: 'b', check: 'ok'),
        manifestCheck: () async => true,
      );
      addTearDown(rebuild.dispose);
      expect(await rebuild.start(confirmedBy: 'user'), isFalse);
      expect(rebuild.state, RebuildStates.paused);
      expect(await store.db.query('report_latest'), isEmpty);
      expect(await store.meta('source_generation'), isNull);
    },
  );

  test(
    'gap acceptance rejects new pending work and preserves the previous projection',
    () async {
      final rebuild = makeRebuild(
        engine: _FakeEngine(
          outcome: const RebuildRunOutcome(
            listComplete: true,
            fetched: 1,
            permanentFailures: ['missing'],
            orphanCount: 0,
          ),
        ),
      );
      await rebuild.start(confirmedBy: 'user');
      await store.db.insert('rebuild_items', {
        'run_id': rebuild.job!['run_id'],
        'source_report_id': 'late',
        'state': 'pending',
      });
      await rebuild.acceptGaps();
      expect(rebuild.state, RebuildStates.paused);
      expect(await store.meta('source_generation'), isNull);
      expect(await store.db.query('report_latest'), isEmpty);
    },
  );

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
