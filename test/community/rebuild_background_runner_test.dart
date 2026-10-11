// Standalone 신고 내역 다시 불러오기 — 백그라운드 실행기(2026-10-11 사용자 결정).
// 실제 상태기계(CommunityRebuild)·community.db 위에서 안내 확인 기록, 재시작 뒤 같은 run 이어서,
// 동기화·DB 파일 작업 직렬화, 알림(진행·완료·누락·중단)을 확인한다. 수집 엔진·백업만 가짜다.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/community/rebuild/standalone_rebuild_runner.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:safetyreport/services/sync_operation_admission.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Engine extends RebuildEngine {
  _Engine({this.gaps = const []});
  final List<String> gaps;
  late CommunityStore store;
  final List<String> runs = [];
  Completer<void>? hold;
  final entered = Completer<void>();

  @override
  Future<RebuildRunOutcome> run({required String runId}) async {
    runs.add(runId);
    if (!entered.isCompleted) entered.complete();
    await hold?.future;
    await store.db.update(
      'rebuild_jobs',
      {'list_complete': 1},
      where: 'run_id=?',
      whereArgs: [runId],
    );
    for (final id in gaps) {
      await store.db.insert('rebuild_items', {
        'run_id': runId,
        'source_report_id': id,
        'state': 'failed_permanent',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return RebuildRunOutcome(
      listComplete: true,
      fetched: 0,
      permanentFailures: gaps,
      orphanCount: 0,
    );
  }

  @override
  void cancel() {}
}

class _Sink extends RebuildNotificationSink {
  final progress_ = <String>[];
  final milestones = <String>[];

  @override
  Future<void> progress(
    String title,
    String message,
    int? current,
    int? total,
  ) async => progress_.add(message);

  @override
  Future<void> milestone(String title, String body) async =>
      milestones.add('$title|$body');
}

Future<void> _until(bool Function() done, {int tries = 400}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'condition not reached');
}

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rebuild_runner_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(
      path: dbPath,
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    CommunityRebuildGuard.active = false;
    SyncEngine.openCommunityStoreForTest = null;
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityRebuild make(_Engine engine, {String namespace = 'ns-1'}) {
    engine.store = store;
    final rebuild = CommunityRebuild(
      store: store,
      localDatasetId: store.localDatasetId,
      sourceNamespace: () async => namespace,
      gateFresh: () async => true,
      engine: engine,
      backup: (_) async =>
          const RebuildBackupResult(ok: true, ref: 'b', check: 'ok'),
      manifestCheck: () async => true,
      pollInterval: const Duration(milliseconds: 50),
    );
    addTearDown(rebuild.dispose);
    return rebuild;
  }

  StandaloneRebuildRunner runner(_Sink sink) {
    final r = StandaloneRebuildRunner(
      sink: sink,
      retryDelay: const Duration(milliseconds: 50),
    );
    addTearDown(r.dispose);
    return r;
  }

  Future<void> interrupted({String state = 'running', String? error}) async {
    await store.db.insert('rebuild_jobs', {
      'run_id': 'old-run',
      'required_version': communityRebuildRequiredVersion,
      'local_dataset_id': await store.localDatasetId(),
      'source_account_namespace': 'ns-1',
      'state': state,
      'phase': 'collect',
      'last_error': error,
      'backup_ref': 'b',
      'backup_check': 'ok',
      'updated_at': '2026-01-01T00:00:00Z',
    });
  }

  test('the guide is acknowledged once per scope key', () async {
    final first = make(_Engine());
    expect(await first.guideAcknowledged(), isFalse);
    await first.acknowledgeGuide();
    expect(await make(_Engine()).guideAcknowledged(), isTrue);
    // 다른 공식 계정(범위 키)은 다시 안내한다.
    expect(
      await make(_Engine(), namespace: 'ns-2').guideAcknowledged(),
      isFalse,
    );
  });

  test('an existing job counts as an acknowledged guide', () async {
    await interrupted();
    expect(await make(_Engine()).guideAcknowledged(), isTrue);
  });

  test(
    'restart: an interrupted run resumes the same run in the background and completes',
    () async {
      await interrupted();
      final engine = _Engine();
      final sink = _Sink();
      final r = runner(sink);
      var refreshed = 0;
      r.onRunFinished = () async => refreshed++;
      final rebuild = make(engine);
      r.adopt(rebuild);
      await rebuild.refresh(); // 죽은 프로세스의 running → paused(interrupted)
      expect(rebuild.state, RebuildStates.paused);
      expect(StandaloneRebuildRunner.shouldAutoResume(rebuild), isTrue);
      expect(r.resumeIfDue(), isTrue);
      await _until(() => rebuild.state == RebuildStates.completed);
      await _until(() => !rebuild.isExecuting);
      expect(engine.runs, ['old-run']);
      await _until(() => sink.milestones.isNotEmpty);
      expect(sink.milestones.single, startsWith('신고 내역 다시 불러오기 완료|'));
      expect(refreshed, greaterThan(0));
      expect(r.syncBlockReason(), isNull);
      expect(r.visible, isTrue);
      r.dismissCompletion();
      expect(r.visible, isFalse);
    },
  );

  test('a user pause is not resumed automatically', () async {
    await interrupted(state: 'paused', error: 'user_paused');
    final rebuild = make(_Engine());
    final r = runner(_Sink())..adopt(rebuild);
    await rebuild.refresh();
    expect(StandaloneRebuildRunner.shouldAutoResume(rebuild), isFalse);
    expect(r.resumeIfDue(), isFalse);
    expect(rebuild.isExecuting, isFalse);
    expect(r.syncBlockReason(), contains('먼저 마쳐야'));
  });

  test(
    'sync, manual sync admission and DB file operations wait behind a running rebuild',
    () async {
      final engine = _Engine()..hold = Completer<void>();
      final r = runner(_Sink());
      final rebuild = make(engine);
      r.adopt(rebuild);
      r.runInBackground();
      await engine.entered.future;
      expect(rebuild.isExecuting, isTrue);
      // 일반 동기화(수동·자동·개별 처리)는 같은 작업 소유권을 얻지 못한다.
      SyncEngine.openCommunityStoreForTest = () async => store;
      final sync = await SyncEngine.start();
      expect(sync.busy, isTrue);
      expect(
        await SyncOperationAdmission.run(
          () async => true,
          false,
          openStore: () async => store,
        ),
        isFalse,
      );
      // DB 백업·복원·서버 DB 가져오기는 무엇이든 바꾸기 전에 거절된다(무결성 §3-1).
      expect(LocalDbService.hasBackgroundWork, isTrue);
      await expectLater(
        LocalDbService.exportBackup('${tmp.path}/x.db'),
        throwsA(isA<DbBusyException>()),
      );
      await expectLater(
        LocalDbService.replaceFromBackup('${tmp.path}/x.db'),
        throwsA(isA<DbBusyException>()),
      );
      expect(r.syncBlockReason(), contains('진행 중'));
      expect(r.fileOperationBlockReason('DB 복원을'), contains('DB 복원을'));
      engine.hold!.complete();
      await _until(() => !rebuild.isExecuting);
      expect(rebuild.state, RebuildStates.completed);
      expect(LocalDbService.hasBackgroundWork, isFalse);
      expect(r.fileOperationBlockReason('DB 복원을'), isNull);
    },
  );

  test(
    'permanent gaps wait for consent, then finish with gaps; notifications follow',
    () async {
      final engine = _Engine(gaps: ['gap-1', 'gap-2']);
      final sink = _Sink();
      final r = runner(sink);
      final rebuild = make(engine);
      r.adopt(rebuild);
      r.runInBackground();
      await _until(
        () => !rebuild.isExecuting && rebuild.state == RebuildStates.validating,
      );
      final p = RebuildProgress.of(rebuild);
      expect(p.needsGapConsent, isTrue);
      expect(StandaloneRebuildRunner.shouldAutoResume(rebuild), isFalse);
      await _until(() => sink.milestones.isNotEmpty);
      expect(sink.milestones.last, contains('확인 필요'));
      expect(sink.progress_, isNotEmpty);
      r.acceptGapsInBackground();
      await _until(
        () =>
            !rebuild.isExecuting &&
            rebuild.state == RebuildStates.completedWithGaps,
      );
      await _until(() => sink.milestones.length == 2);
      expect(sink.milestones.last, contains('일부 누락'));
      expect(RebuildProgress.of(rebuild).headline, contains('2건'));
    },
  );

  test(
    'a lease left by a dead process is retried until it expires (resume continues)',
    () async {
      await interrupted();
      await store.acquireLease(
        'personal_sync',
        'dead-process',
        const Duration(minutes: 10),
      );
      final engine = _Engine();
      final r = runner(_Sink());
      final rebuild = make(engine);
      r.adopt(rebuild);
      r.runInBackground(confirmedBy: 'resume', userAction: false);
      await _until(() => rebuild.waitingForWorker && !rebuild.isExecuting);
      expect(engine.runs, isEmpty);
      expect(RebuildProgress.of(rebuild).headline, contains('종료를 확인'));
      // 이전 프로세스의 lease 가 만료되면 자동 재시도가 같은 run 을 이어서 끝낸다.
      await store.db.update('leases', {'until': '2026-01-01T00:00:00Z'});
      await _until(() => rebuild.state == RebuildStates.completed);
      await _until(() => !rebuild.isExecuting);
      expect(engine.runs, ['old-run']);
    },
  );
}
