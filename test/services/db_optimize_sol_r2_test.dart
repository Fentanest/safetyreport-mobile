// Sol 재검수 R2 5건 재현 시험 — 실제 경로, 실DB, skip·완화 없음.
//
// 각 시험은 수정 전 코드에서 실패한다(확인 순서: lib/ 만 stash → 이 파일 실행 → 실패 → 복원).
// 1·2a·2b·2c·3e·4b·5c·5d는 수정 전 해당 API·위젯이 없어 컴파일 실패한다.
// 3a·3b·3c·3d·5a·5b는 수정 전 실행 실패(보류 유실·오류 미표시·자동 숨김)한다.
// 4a·4c는 규칙 문서화(성공 뒤 삭제·실패 유지 — 전후 동일 동작)다.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/db_optimize_state.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:safetyreport/services/sync_operation_admission.dart';
import 'package:safetyreport/widgets/maintenance_status_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> envelopeFor(String id) => {
  'resultCode': '0000',
  'result': {
    'C_NO': id,
    'C_NAME': '홍길동',
    'C_EMAIL': 'a@b.c',
    'C_PHONE': '01012345678',
    'C_PHONE2': '010-1234-5678',
    'C_ID': 'fixtureid1',
    'C_NOW': 10,
    'C_A_CONTENTS':
        '본 신고는 안전신문고 앱의 자동차·교통위반 메뉴로 접수된 신고입니다\n'
        '* 차량번호 : 12가3456\n* 발생일자 : 2026-09-01\n* 발생시각 : 08:00\n신고합니다',
    'RN_ADRES': '서울특별시 강서구 마곡동 1',
    'STTEMNT_NO': 'SPP-2512-$id',
    'C_A_TITLE': '(자동차·교통위반) 신호위반',
    'C_DATE': '2025-12-30 23:40:00',
    'answers': [
      {
        'C_MANAGER_TYPE_NM': '수용',
        'C_MANAGE_CONTENTS': '과태료 40,000원을 부과하였습니다.',
        'C_MANAGE_ORG_NAME': '서울특별시 강서경찰서 교통과',
        'C_MANAGE_MAN': '김담당',
        'C_DATE': '2026-01-02',
      },
    ],
  },
};

Report reportFor(String id) => Report(
  id: id,
  reportNumber: 'SPP-2512-$id',
  name: '(자동차·교통위반) 신호위반',
  date: '2025-12-30',
  responseDate: '',
  agency: '',
  manager: '',
  status: '처리중',
  result: '진행',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
  attachedPhotos: '',
);

Future<void> resetDb() async {
  DbOptimize.resetForTest();
  MaintenanceService.resetForTest();
  SyncEngine.openCommunityStoreForTest = null;
  SyncEngine.retryFileForTest = null;
  SyncEngine.rebuildBlocks = null;
  SyncEngine.localAccessAllowed = null;
  DbOptimize.openStoreForTest = null;
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

Future<void> seedReports(List<String> ids) async {
  for (final id in ids) {
    await LocalDbService.upsertReport(
      reportFor(id),
      'traffic',
      '자동차·교통위반-신호위반',
    );
  }
}

Future<void> insertRaw(String id, Map<String, dynamic> envelope) async {
  final prepared = prepareRawDetail(envelope);
  final d = await LocalDbService.db;
  await d.insert('report_detail_raw', {
    'ID': id,
    'raw_zlib': compressRawDetail(prepared.canonical),
    'raw_sha256': prepared.sha256,
    'raw_size': prepared.canonical.length,
    'fetched_at': '2026-10-17T12:00:00.000Z',
    'source': 'crawl',
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<CaptureResult?> Function(Map<String, Object?> adapterInput, String id)
fakeCapture() => (_, id) async => CaptureResult(
  eventId: 'event-$id',
  eventType: 'completed_observation',
  eligible: true,
  payloadSha256: 'x',
  sourceRevision: 1,
);

Future<void> waitForCondition(
  Future<bool> Function() cond, {
  required String what,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
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
    tempDbDir = Directory.systemTemp.createTempSync('sr_solr2_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetDb();
    DbOptimize.requestInterval = Duration.zero;
    DbOptimize.waitInterval = const Duration(milliseconds: 1);
    DbOptimize.loginRetryInterval = const Duration(milliseconds: 1);
  });
  tearDown(() async {
    await resetDb();
  });

  testWidgets('1. DB 열기가 늦어도 시작 화면과 업그레이드 단계 문구가 보인다', (
    tester,
  ) async {
    // 실제 main 시작 경로와 같은 순서(runApp → DB 열기): 가짜 오프너가 실제 _open 처럼
    // 시작 표시 → 단계 로그 streaming → 끝 순서로 상태를 바꾼다.
    Future<void> fakeOpen() async {
      LocalDbService.upgradeRunning = true;
      DbOptimizeState.notifyChanged();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      LocalDbService.upgradeLog.add('업그레이드 전 백업 완료(before_v18_1.bak)');
      DbOptimizeState.notifyChanged();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      LocalDbService.upgradeLog.add('새 표 생성(스키마 18)');
      DbOptimizeState.notifyChanged();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      LocalDbService.upgradeRunning = false;
      DbOptimizeState.notifyChanged();
    }

    await tester.pumpWidget(
      StartupBootstrap(
        openDb: fakeOpen,
        child: const MaterialApp(home: Text('MAIN')),
      ),
    );
    await tester.pump();
    // DB 열기 전 첫 프레임부터 로딩이 보인다. 아직 본 화면은 아니다.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('MAIN'), findsNothing);
    expect(find.text('DB 최적화 중입니다…'), findsOneWidget);
    // 열기 중간: 단계 문구가 상태 변경마다 streaming 된다.
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.textContaining('백업 완료'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.textContaining('새 표 생성'), findsOneWidget);
    // 열기가 끝나면 본 화면으로 바뀐다(첫 화면 지연 없음).
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(find.text('MAIN'), findsOneWidget);
  });

  test('2a. 백업 복원·서버 DB 가져오기 실패 종료에서도 교체 훅이 불린다', () async {
    var calls = 0;
    LocalDbService.onDatabaseReplaced = () {
      calls++;
    };
    await expectLater(
      LocalDbService.replaceFromBackup('/nonexistent/sol_r2_backup.db'),
      throwsA(anything),
    );
    expect(calls, 1);
    await expectLater(
      LocalDbService.importFromServerDb('/nonexistent/sol_r2_server.db'),
      throwsA(anything),
    );
    expect(calls, 2);
  });

  test('2b. 복원 성공 뒤 Standalone 재판단으로 최적화가 돈다', () async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'solr2test',
    });
    final provider = ReportProvider();
    await provider.init();
    const id = '92000001';
    await seedReports([id]);
    await insertRaw(id, envelopeFor(id));
    // 새 DB 처럼 미완료 메타 + 주인 표시(복원 소유권 검사용).
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': '',
      'done': false,
      'total': 1,
      'stats': {},
    });
    final ownerOfDb = LocalDbService.currentKakaoId;
    LocalDbService.currentKakaoId = () async => 'kakao-solr2';
    try {
      await LocalDbService.setMeta(
        LocalDbService.kakaoMemberMetaKey,
        'kakao-solr2',
      );
      await LocalDbService.closeDb();
      final backupPath = '${tempDbDir.path}/sol_r2_backup.db';
      await LocalDbService.exportBackup(backupPath);

      var hookCalls = 0;
      LocalDbService.onDatabaseReplaced = () {
        hookCalls++;
        provider.reevaluateDbOptimize();
      };
      DbOptimize.captureForTest = fakeCapture();
      // 실제 복원 경로(성공).
      await LocalDbService.replaceFromBackup(backupPath);
      expect(hookCalls, 1);
      // 재판단으로 최적화가 돌아 done 이 된다(네트워크 없이 저장된 원본만으로).
      await waitForCondition(
        () async => (await DbOptimize.readMeta())?['done'] == true,
        what: 'restored db optimize done',
      );
    } finally {
      LocalDbService.currentKakaoId = ownerOfDb;
    }
  });

  test('2c. Client·데모·미설정에서는 재판단해도 시작하지 않는다', () async {
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': 'x',
      'done': true,
      'total': 1,
      'stats': {},
    });
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
    // 기본 provider = server 미설정 → 아무 것도 안 한다.
    ReportProvider().reevaluateDbOptimize();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(starts, 0);
    expect(await DbOptimize.peekManualSync(), isNotNull);
  });

  test('3a. 거절된 보류 실행은 보류를 유지한다(게이트 거절 실제 경로)', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    SyncEngine.localAccessAllowed = () async => false;
    final started = await SyncEngine.runDeferredManual();
    expect(started, isFalse);
    expect(await DbOptimize.peekManualSync(), isNotNull);
  });

  test('3b. 소유권 경쟁(busy) 보류 실행은 보류를 유지한다', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    const busyResult = SyncRunResult(
      done: 0,
      errors: 0,
      failed: true,
      busy: true,
      errorMessage: 'sync_busy',
    );
    final gate = Completer<SyncRunResult>();
    final holder = SyncOperationAdmission.run<SyncRunResult>(
      () => gate.future,
      busyResult,
    );
    try {
      final started = await SyncEngine.runDeferredManual();
      expect(started, isFalse);
      expect(await DbOptimize.peekManualSync(), isNotNull);
    } finally {
      gate.complete(busyResult);
      await holder;
    }
  });

  test('3c. 취소된 보류 실행은 보류를 유지한다', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    // 같은 소유권 구역에서 중지 요청 — 실제 취소 경로(_stopping)로 끝난다.
    final started = await SyncOperationAdmission.run<bool>(
      () => SyncEngine.runDeferredManual(),
      false,
      stopRequested: () => true,
    );
    expect(started, isFalse);
    expect(await DbOptimize.peekManualSync(), isNotNull);
  });

  test('3d. 동기화 종료 뒤 영속 보류가 시작된다', () async {
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
    // 게이트 거절로 끝나는 실제 동기화 — 종료 훅이 보류를 꺼내 시작한다.
    SyncEngine.localAccessAllowed = () async => false;
    await SyncEngine.start();
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNull);
  });

  test('3e. 최적화 진행 중 동기화가 끝나도 보류는 유지된다', () async {
    DbOptimizeState.update(
      state: 'running',
      stage: 'running',
      total: 1,
      done: 0,
    );
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
    await DbOptimize.notifySyncFinished();
    expect(starts, 0);
    expect(await DbOptimize.peekManualSync(), isNotNull);
  });

  // 4번(Opus 변경 규칙, 서버와 동일): started 표시를 쓰지 않는다. 실제로 시작이
  // 성공한 뒤에 보류 기록을 지우고, 지우기 실패는 진단 기록만 남긴다(드물게 다음에 한 번
  // 더 시작될 수 있음 — 요청 유실보다 낫다). 시작 실패·busy·거절·취소·앱 종료면 보류는
  // 남아 다음 훅·실행에서 시작한다(3a·3b·3c에서 실패 유지 확인).

  test('4a. 시작 성공 뒤 보류를 지운다', () async {
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
    await DbOptimize.runDeferredStarters();
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNull);
  });

  test('4b. 지우기 실패는 진단만 남기고 보류는 남아 다음에 다시 시작한다', () async {
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
    // 실제 삭제 경로의 실패를 주입한다(실DB는 그대로 둔다).
    DbOptimize.deleteMetaForTest = (_) async =>
        throw Exception('sol_r2_delete_failed');
    await DbOptimize.runDeferredStarters();
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNotNull);
    final job = DbOptimizeState.jobForStatus()!;
    expect(
      (job['log'] as List).any((line) => '$line'.contains('보류 삭제 실패')),
      isTrue,
    );
    // 다음 훅·실행에서 다시 시작한다(드물게 한 번 더 시작될 수 있음 — 유실보다 낫다).
    DbOptimize.deleteMetaForTest = null;
    await DbOptimize.runDeferredStarters();
    expect(starts, 2);
    expect(await DbOptimize.peekManualSync(), isNull);
  });

  test('4c. drain 보류도 성공 뒤에 지우고 실패하면 유지한다', () async {
    await DbOptimize.markDrainDeferred();
    var starts = 0;
    DbOptimize.drainStarter = () async {
      starts++;
      return true;
    };
    await DbOptimize.runDeferredStarters();
    expect(starts, 1);
    expect(await DbOptimize.isDrainDeferred(), isFalse);
    await DbOptimize.markDrainDeferred();
    DbOptimize.drainStarter = () async {
      starts++;
      return false;
    };
    await DbOptimize.runDeferredStarters();
    expect(starts, 2);
    expect(await DbOptimize.isDrainDeferred(), isTrue);
  });

  testWidgets('5a. 처음 마운트돼도 오류와 로그가 보인다', (tester) async {
    DbOptimizeState.update(
      state: 'error',
      stage: 'error',
      message: 'StateError',
    );
    DbOptimizeState.appendLog('오류로 멈춤(StateError)');
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MaintenanceStatusBar())),
    );
    await tester.pump();
    expect(find.textContaining('오류'), findsOneWidget);
    await tester.tap(find.byKey(const Key('maintenance-status-bar')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('maintenance-log-sheet')), findsOneWidget);
    expect(find.textContaining('오류로 멈춤'), findsOneWidget);
  });

  testWidgets('5b. 오류는 6초 뒤에도 유지된다', (tester) async {
    DbOptimizeState.update(
      state: 'error',
      stage: 'error',
      message: 'StateError',
    );
    DbOptimizeState.appendLog('오류로 멈춤(StateError)');
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MaintenanceStatusBar())),
    );
    await tester.pump();
    expect(find.textContaining('오류'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    expect(find.textContaining('오류'), findsOneWidget);
  });

  test('5c. 앱을 새로 열어도 마지막 오류가 복원되고 재시작 때 해제된다', () async {
    const id = '93000001';
    await seedReports([id]);
    await insertRaw(id, envelopeFor(id));
    DbOptimize.captureForTest = (_, _) async =>
        throw CaptureStoreUnavailable('community_store_unavailable');
    // 실제 오류 경로: 최적화 실행 → 작업 예외 → error + 영속.
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      wait: true,
    );
    expect(DbOptimizeState.state, 'error');
    expect(await LocalDbService.getMeta(DbOptimize.lastErrorKey), isNotNull);
    // 새 프로세스: 메모리만 비우고(DB 유지) 복원한다.
    DbOptimizeState.resetForTest();
    expect(DbOptimizeState.state, isNot('error'));
    expect(await DbOptimize.restorePersistedError(), isTrue);
    expect(DbOptimizeState.state, 'error');
    expect(DbOptimizeState.jobForStatus()!['log'], isNotEmpty);
    // 재시도 시작(실제 성공 경로)하면 해제된다.
    DbOptimize.captureForTest = fakeCapture();
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      wait: true,
    );
    expect(DbOptimizeState.state, 'completed');
    expect(await LocalDbService.getMeta(DbOptimize.lastErrorKey), isNull);
  });

  testWidgets('5d. 새로 연 앱의 표시줄에 복원된 오류가 보인다', (tester) async {
    // 실제 비동기(DB 열기)는 runAsync 로 돌린다 — 위젯 시험 FakeAsync zone 에서는
    // 정적 캐시 비동기 초기화가 영원히 대기한다(gate_passed_hooks_test.dart 앞 주석).
    await tester.runAsync(() async {
      DbOptimizeState.update(
        state: 'error',
        stage: 'error',
        message: 'StateError',
      );
      DbOptimizeState.appendLog('오류로 멈춤(StateError)');
      await DbOptimize.persistLastError('StateError');
      // 새 프로세스: 메모리만 비우고(DB 유지) 복원한다.
      DbOptimizeState.resetForTest();
      expect(await DbOptimize.restorePersistedError(), isTrue);
    });
    // 표시줄을 처음 마운트해도 복원된 오류와 로그가 보인다.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MaintenanceStatusBar())),
    );
    await tester.pump();
    expect(find.textContaining('오류'), findsOneWidget);
    await tester.tap(find.byKey(const Key('maintenance-status-bar')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('maintenance-log-sheet')), findsOneWidget);
    expect(find.textContaining('오류로 멈춤'), findsOneWidget);
  });
}
