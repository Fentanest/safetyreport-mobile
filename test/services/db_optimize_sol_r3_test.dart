// Sol 3차 검수 지적 2건 재현 시험 — 실제 경로, 실DB, skip·완화 없음.
//
// 각 시험은 수정 전 코드에서 실패한다(확인 순서: lib/ 만 stash → 이 파일 실행 →
// 실패 → 복원).
// R3-1a·R3-1b: 수정 전 `reevaluateDbOptimize` 가 메모리 표시를 새 DB 기준으로
//   다시 맞추지 않아 이전 DB 의 오류가 남는다(실행 실패).
// R3-2: 수정 전 drain 예외 종료에서 `notifySyncFinished` 를 건너뛰어 보류가
//   시작되지 않는다(실행 실패).
// R3-2b: SyncEngine 예외 종료 경로 확인용 — 수정 전후 동일하게 통과한다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/db_optimize_state.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/services/standalone_auto_sync_service.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> resetDb() async {
  DbOptimize.resetForTest();
  MaintenanceService.resetForTest();
  SyncEngine.openCommunityStoreForTest = null;
  SyncEngine.localAccessAllowed = null;
  SyncEngine.rebuildBlocks = null;
  SyncEngine.retryFileForTest = null;
  LocalDbService.onDatabaseReplaced = null;
  await LocalDbService.closeDb();
  final dbPath = await LocalDbService.getDbPath();
  await deleteDatabase(dbPath);
  for (final ext in ['-wal', '-shm']) {
    final sidecar = File('$dbPath$ext');
    if (sidecar.existsSync()) await sidecar.delete();
  }
  LocalDbService.upgradeLog.clear();
  LocalDbService.upgradeRunning = false;
}

Future<void> waitShort(
  Future<bool> Function() cond, {
  required String what,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('timeout: $what');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDbDir = Directory.systemTemp.createTempSync('sr_solr3_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetDb();
  });
  tearDown(() async {
    await resetDb();
  });

  test('R3-1a. 오류 표시 중 완료 메타 DB 로 복원 → 표시줄 오류 사라짐', () async {
    // 이전 DB 에서 오류가 난 상태(메모리 + 영속)를 시뮬레이션한다.
    DbOptimizeState.update(state: 'error', stage: 'error', message: 'StateError');
    DbOptimizeState.appendLog('오류로 멈춤(StateError)');
    await DbOptimize.persistLastError('StateError');
    expect(DbOptimizeState.state, 'error');

    // 새 DB: 최적화 완료 메타 + 오류 기록 없음.
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': 'x',
      'done': true,
      'total': 1,
      'stats': {},
    });
    await DbOptimize.clearLastError();

    // 기본 provider(server)라 최적화 시작은 하지 않고 표시 재동기화만 한다.
    ReportProvider().reevaluateDbOptimize();
    await waitShort(
      () async => DbOptimizeState.state != 'error',
      what: 'restored done db clears stale error display',
    );
    expect(DbOptimizeState.jobForStatus(), isNull);
  });

  test('R3-1b. 오류 기록 있는 DB 로 복원 → 그 오류만 표시', () async {
    // 새 DB 의 오류 기록을 남긴다(메모리 로그를 새 오류 내용으로 해서 영속).
    DbOptimizeState.update(
      state: 'error',
      stage: 'error',
      message: 'NEW_ERROR',
    );
    DbOptimizeState.appendLog('NEW log line');
    await DbOptimize.persistLastError('NEW_ERROR');
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': '',
      'done': false,
      'total': 1,
      'stats': {},
    });
    // 복원 전 메모리 상태 = 다른 DB 의 낡은 오류 표시로 되돌린다.
    DbOptimizeState.update(
      state: 'error',
      stage: 'error',
      message: 'OLD_ERROR',
    );
    DbOptimizeState.appendLog('OLD log line');

    ReportProvider().reevaluateDbOptimize();
    await waitShort(
      () async => '${DbOptimizeState.jobForStatus()?['message']}' == 'NEW_ERROR',
      what: 'restored error snapshot replaces stale error',
    );
    final job = DbOptimizeState.jobForStatus()!;
    expect(job['state'], 'error');
    final logs = (job['log'] as List).map((e) => '$e').join('\n');
    expect(logs, contains('NEW log line'));
    expect(logs, isNot(contains('OLD log line')));
  });

  test('R3-2. drain 예외 종료 뒤 보류 1회 시작', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    var starts = 0;
    DbOptimize.manualStarter = () async {
      starts++;
      return true;
    };
    // 소유권 저장소 확인 실패 → drain 예외 종료를 재현한다.
    SyncEngine.openCommunityStoreForTest = () async =>
        throw Exception('sol_r3_ownership_lost');
    try {
      final ok = await StandaloneAutoSyncService.drainIfPending();
      expect(ok, isFalse);
    } finally {
      SyncEngine.openCommunityStoreForTest = null;
    }
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNull);
  });

  test('R3-2b. SyncEngine 예외 종료에서도 보류 재확인(유지)한다', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    var starts = 0;
    DbOptimize.manualStarter = () async {
      starts++;
      return SyncEngine.runDeferredManual();
    };
    // 저장소 확인 실패 → SyncEngine.start 예외 종료를 재현한다.
    SyncEngine.openCommunityStoreForTest = () async =>
        throw Exception('sol_r3_store_unavailable');
    try {
      final result = await SyncEngine.start();
      expect(result.failed, isTrue);
    } finally {
      SyncEngine.openCommunityStoreForTest = null;
    }
    // 종료 훅이 보류를 꺼내 시작을 시도한다(실패이므로 보류는 유지 — 유실 없음).
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNotNull);
  });
}
