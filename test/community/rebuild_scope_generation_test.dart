import 'package:safetyreport/community/manifest_result.dart';
// Astra 재검수2 #4 회귀 — 백그라운드 다시 불러오기 진행 중 표시 필터('취하 데이터 숨기기'·'중복 신고 대표건만
// 반영')를 바꿔도 scopeGeneration(`main.dart` standaloneRebuild)·scope(standaloneRebuildScope) 가
// 계정이 바뀐 것으로 오판해 중단하지 않아야 한다. 실제 계정·모드 교체(ReportProvider.accountConfigEpoch)는
// 여전히 중단해야 한다. 이미 이 버그로 멈춘(비정상 종료) run 이 같은 계정·자료셋에서 자동 재개 대상인지도 본다.
//
// standaloneRebuild() 는 main.dart 의 실제 운영 와이어링을 그대로 쓴다 — engine·backup·manifestCheck 만
// 시험용으로 주입한다(gateFresh 가 이미 쓰는 것과 같은 패턴).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/community/rebuild/standalone_rebuild_runner.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 수집이 끝나지 않은 채로 잡아 둔다(테스트가 중간에 세대를 바꿀 시간을 번다).
class _HoldEngine extends RebuildEngine {
  final entered = Completer<void>();
  final hold = Completer<RebuildRunOutcome>();
  final runs = <String>[];

  @override
  Future<RebuildRunOutcome> run({required String runId}) async {
    runs.add(runId);
    if (!entered.isCompleted) entered.complete();
    return hold.future;
  }

  @override
  void cancel() {}
}

const _doneOutcome = RebuildRunOutcome(
  listComplete: true,
  fetched: 0,
  permanentFailures: [],
  orphanCount: 0,
);

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;
  late ReportProvider provider;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rebuild_scope_gen_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
    SharedPreferences.setMockInitialValues({});
    provider = ReportProvider();
    await provider.init();
  });

  tearDown(() async {
    provider.dispose();
    CommunityRebuildGuard.active = false;
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityRebuild make(_HoldEngine engine) {
    final rebuild = standaloneRebuild(
      store,
      provider,
      gateFresh: () async => true,
      engine: engine,
      backup: (_) async =>
          const RebuildBackupResult(ok: true, ref: 'b', check: 'ok'),
      manifestCheck: () async => const ManifestResult(ManifestStatus.ok),
    );
    addTearDown(rebuild.dispose);
    return rebuild;
  }

  test('진행 중 표시 필터를 바꿔도 다시 불러오기가 중단되지 않는다', () async {
    final engine = _HoldEngine();
    final rebuild = make(engine);
    final run = rebuild.start(confirmedBy: 'user');
    await engine.entered.future;
    expect(rebuild.isExecuting, isTrue);

    // 설정 화면의 '취하 데이터 숨기기'·'중복 신고 대표건만 반영' 토글과 같은 호출.
    await provider.setStandaloneFilter(excludeWithdraw: false);
    await provider.setStandaloneFilter(useRepresentativeRecords: false);
    expect(provider.datasetEpoch, greaterThan(0), reason: '표시 필터 세대는 올라간다');
    expect(provider.accountConfigEpoch, 0, reason: '계정·DB 세대는 그대로다');

    engine.hold.complete(_doneOutcome);
    expect(await run, isTrue);
    expect(rebuild.state, RebuildStates.completed);
    expect(rebuild.job?['last_error'], isNull);
  });

  test('진행 중 실제 계정·모드 전환이면 여전히 중단된다', () async {
    final engine = _HoldEngine();
    final rebuild = make(engine);
    final run = rebuild.start(confirmedBy: 'user');
    await engine.entered.future;
    expect(rebuild.isExecuting, isTrue);

    // setConfig·setStandaloneConfig·resetConfig 가 공통으로 하는 일(모드 전환·계정 변경·로그아웃).
    provider.accountConfigEpoch++;

    engine.hold.complete(_doneOutcome);
    expect(await run, isFalse);
    expect(rebuild.state, isNot(RebuildStates.completed));
    expect(rebuild.job?['last_error'], contains('rebuild_generation_changed'));
  });

  for (final stuckState in [RebuildStates.paused, RebuildStates.failed]) {
    test(
      '이 버그로 $stuckState 상태로 멈춘 run 은 같은 계정·자료셋이면 다음 실행에서 자동 재개된다',
      () async {
        // 고치기 전 코드가 남겼을 법한 job: 생성 불일치로 실패/중단됐지만 정체성(local_dataset_id·
        // source_account_namespace)은 그대로다.
        await store.db.insert('rebuild_jobs', {
          'run_id': 'stuck-run',
          'required_version': communityRebuildRequiredVersion,
          'local_dataset_id': await store.localDatasetId(),
          'source_account_namespace': '',
          'state': stuckState,
          'phase': 'collect',
          'last_error': 'Bad state: rebuild_generation_changed',
          'backup_ref': 'b',
          'backup_check': 'ok',
          'updated_at': '2026-01-01T00:00:00Z',
        });
        final engine = _HoldEngine();
        final rebuild = make(engine);
        final runner = StandaloneRebuildRunner(
          sink: const _QuietSink(),
        );
        addTearDown(runner.dispose);
        runner.adopt(rebuild);
        await rebuild.refresh();
        expect(rebuild.job?['run_id'], 'stuck-run');
        expect(
          StandaloneRebuildRunner.shouldAutoResume(rebuild),
          isTrue,
          reason: 'user_paused·누락 동의 대기가 아니면 다시 불러오기는 재개 대상이다',
        );
        expect(runner.resumeIfDue(), isTrue);
        await engine.entered.future;
        expect(engine.runs, ['stuck-run'], reason: '같은 run 을 이어서 진행한다');
        engine.hold.complete(_doneOutcome);
        for (var i = 0; i < 20 && rebuild.isExecuting; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(rebuild.state, RebuildStates.completed);
      },
    );
  }

  test(
    '다른 계정(범위)의 멈춘 run 은 재사용하지 않는다',
    () async {
      await store.db.insert('rebuild_jobs', {
        'run_id': 'other-account-run',
        'required_version': communityRebuildRequiredVersion,
        'local_dataset_id': await store.localDatasetId(),
        'source_account_namespace': 'ns-other-account',
        'state': RebuildStates.failed,
        'phase': 'collect',
        'last_error': 'Bad state: rebuild_generation_changed',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      // provider.standaloneUsername 은 비어 있다 → source_account_namespace == ''.
      final engine = _HoldEngine();
      final rebuild = make(engine);
      await rebuild.refresh();
      expect(
        rebuild.job,
        isNull,
        reason: '다른 계정 범위의 job 은 이 scope 에 보이지 않는다',
      );
    },
  );
}

class _QuietSink extends RebuildNotificationSink {
  const _QuietSink();
  @override
  Future<void> progress(
    String title,
    String message,
    int? current,
    int? total,
  ) async {}
  @override
  Future<void> milestone(String title, String body) async {}
}
