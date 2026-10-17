// Astra 교차 확인(배포 전) 모바일 결함 3건 재현 — 실제 경로, 실DB, skip·완화 없음.
//
// M3 커서 앞 일시 실패: `cursor=A, attempts={A:1}, holds=[]` 로 재개하면 A 를 다시
//   시도한다. 계속 실패하면 done 이 아니라 partial(보류 A)로 끝난다.
// M4 완료 배출: 정상 완료 때 대기 작업 훅이 돌 때는 처리 중 영속 표시가 이미 지워져
//   있다(넘김 큐 배출이 자기 표시에 막히지 않음).
// M5 재시도 시각: 보류가 남고 `next_retry_at` 이 아직이면 기동·가져오기 경로가 바로
//   돌지 않는다. 동기화 성공 wake(ignoreBackoff)는 바로 돈다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'db_optimize_sol_r7_test.dart' show envelopeFor, reportFor, resetDb, seedReports;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  late Directory tempRawDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDbDir = Directory.systemTemp.createTempSync('sr_dbopt_astra_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
    tempRawDir = Directory.systemTemp.createTempSync('sr_dbopt_astra_raw_');
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
    if (tempRawDir.existsSync()) tempRawDir.deleteSync(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetDb();
    DbOptimize.rawFileDirForTest = tempRawDir;
    DbOptimize.requestInterval = Duration.zero;
    DbOptimize.waitInterval = const Duration(milliseconds: 1);
    DbOptimize.loginRetryInterval = const Duration(milliseconds: 1);
    DbOptimize.outageRetryInterval = const Duration(milliseconds: 1);
    DbOptimize.roundRetryInterval = const Duration(milliseconds: 1);
    DbOptimize.restPollInterval = const Duration(milliseconds: 1);
    DbOptimize.leaseWaitTimeout = const Duration(milliseconds: 20);
    DbOptimize.leaseWaitPollInterval = const Duration(milliseconds: 1);
    DbOptimize.captureForTest = (input, rid) async => null;
  });
  tearDown(() async {
    DbOptimize.requestStop();
    await resetDb();
  });

  Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
  fetchOk(String rid) async {
    final envelope = envelopeFor(rid, cNow: 0, answerDate: null);
    return (
      result: Map<String, dynamic>.from(envelope['result'] as Map),
      envelope: envelope,
    );
  }

  Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
  fetchFail(String rid) async => (
    result: <String, dynamic>{},
    envelope: <String, dynamic>{'error': 'HTTP 503'},
  );

  Map<String, dynamic> midPassMeta(String cursor, Map<String, int> attempts) => {
    'target': 'mobile-parser-13',
    'cursor': cursor,
    'done': false,
    'total': 3,
    'stats': <String, dynamic>{},
    'attempts': attempts,
    'holds': <String>[],
    'round': 0,
  };

  test('M3 커서 앞 시도 횟수만 남은 신고를 재개 때 다시 시도한다', () async {
    const a = '95000001';
    const b = '95000002';
    const c = '95000003';
    await seedReports([reportFor(a), reportFor(b), reportFor(c)]);
    await DbOptimize.writeMeta(midPassMeta(a, {a: 1}));
    final fetched = <String>[];
    final result = await DbOptimize.processAll(
      fetchFn: (rid) async {
        fetched.add(rid);
        return fetchOk(rid);
      },
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(fetched, [a, b, c]);
    expect(result.finished, isTrue);
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('M3 커서 앞 일시 실패가 계속되면 done 이 아니라 보류로 남는다', () async {
    const a = '95000011';
    const b = '95000012';
    const c = '95000013';
    await seedReports([reportFor(a), reportFor(b), reportFor(c)]);
    await DbOptimize.writeMeta(midPassMeta(a, {a: 1}));
    final result = await DbOptimize.processAll(
      fetchFn: (rid) async => rid == a ? fetchFail(rid) : fetchOk(rid),
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(result.finished, isFalse);
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isFalse);
    expect(meta['holds'], [a]);
  });

  test('M4 정상 완료 때 대기 작업 훅 시점에 처리 중 표시가 지워져 있다', () async {
    const a = '95000021';
    await seedReports([reportFor(a)]);
    bool? processingAtHook;
    DbOptimize.addAfterFinishHook(() async {
      processingAtHook = await DbOptimize.isProcessingPersisted();
    });
    final result = await DbOptimize.processAll(
      fetchFn: fetchOk,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(result.finished, isTrue);
    expect(processingAtHook, isFalse);
  });

  test('M5 저장된 재시도 시각 전이면 기동 경로가 돌지 않고, 동기화 성공 wake 는 바로 돈다', () async {
    const held = '95000031';
    const other = '95000032';
    await seedReports([reportFor(held), reportFor(other)]);
    final due = DateTime.now().toUtc().add(const Duration(hours: 1));
    await DbOptimize.writeMeta({
      'target': 'pc-parser-13',
      'cursor': '',
      'done': false,
      'total': 2,
      'stats': <String, dynamic>{},
      'attempts': <String, dynamic>{},
      'holds': [held],
      'round': 3,
      'next_retry_at': DbOptimize.formatNextRetryAt(due),
    });
    final fetched = <String>[];
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    spy(String rid) async {
      fetched.add(rid);
      return fetchOk(rid);
    }
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      fetchFn: spy,
      wait: true,
    );
    expect(fetched, isEmpty);
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isFalse);
    expect(meta['holds'], [held]);
    expect(DbOptimize.pendingRetryAt(meta), isNotNull);

    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      fetchFn: spy,
      wait: true,
      ignoreBackoff: true,
    );
    expect(fetched, [held]);
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('M5 재시도 시각이 지났거나 보류가 없으면 막지 않는다', () {
    final past = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final future = DateTime.now().toUtc().add(const Duration(minutes: 1));
    Map<String, dynamic> meta(List<String> holds, DateTime at) => {
      'target': 'mobile-parser-13',
      'done': false,
      'holds': holds,
      'next_retry_at': DbOptimize.formatNextRetryAt(at),
    };
    expect(DbOptimize.pendingRetryAt(meta(['1'], past)), isNull);
    expect(DbOptimize.pendingRetryAt(meta(const [], future)), isNull);
    expect(DbOptimize.pendingRetryAt(meta(['1'], future)), isNotNull);
    // 다른 세대 메타는 처음부터 다시 하므로 막지 않는다.
    expect(
      DbOptimize.pendingRetryAt({...meta(['1'], future), 'target': 'mobile-parser-1'}),
      isNull,
    );
  });

  Future<void> writeHeldMeta(String held, DateTime due) => DbOptimize.writeMeta({
    'target': 'mobile-parser-13',
    'cursor': '',
    'done': false,
    'total': 1,
    'stats': <String, dynamic>{},
    'attempts': <String, dynamic>{},
    'holds': [held],
    'round': 1,
    'next_retry_at': DbOptimize.formatNextRetryAt(due),
  });

  test('M5 재시도 타이머는 시각이 되면 다시 판단해 보류를 처리한다', () async {
    const held = '95000041';
    await seedReports([reportFor(held)]);
    await writeHeldMeta(
      held,
      DateTime.now().toUtc().add(const Duration(milliseconds: 300)),
    );
    final fetched = <String>[];
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      fetchFn: (rid) async {
        fetched.add(rid);
        return fetchOk(rid);
      },
      wait: true,
    );
    expect(fetched, isEmpty);
    for (var i = 0; i < 100 && fetched.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(fetched, [held]);
    for (var i = 0; i < 100; i++) {
      if ((await DbOptimize.readMeta())?['done'] == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('Client 전환처럼 시작이 막히면 재시도 타이머·동기화 성공 재판단이 돌지 않는다', () async {
    const held = '95000051';
    await seedReports([reportFor(held)]);
    await writeHeldMeta(
      held,
      DateTime.now().toUtc().add(const Duration(milliseconds: 300)),
    );
    var allowed = true;
    DbOptimize.startAllowed = () => allowed;
    final fetched = <String>[];
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      fetchFn: (rid) async {
        fetched.add(rid);
        return fetchOk(rid);
      },
      wait: true,
    );
    allowed = false;
    await DbOptimize.notifySyncSucceeded();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(fetched, isEmpty);
    expect((await DbOptimize.readMeta())!['done'], isFalse);
  });

  test('재시도 시각 전이라도 동기화 성공 wake 는 바로 보류를 처리한다', () async {
    const held = '95000061';
    await seedReports([reportFor(held)]);
    await writeHeldMeta(
      held,
      DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final fetched = <String>[];
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    spy(String rid) async {
      fetched.add(rid);
      return fetchOk(rid);
    }
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      fetchFn: spy,
      wait: true,
    );
    expect(fetched, isEmpty);
    // 실제 wake 경로는 기억한 확인 함수로 maybeStart(ignoreBackoff) 를 부른다 —
    // 시험은 fetch 주입점으로 같은 경로를 탄다.
    DbOptimize.fetchDetailForTest = (rid) async => spy(rid);
    await DbOptimize.notifySyncSucceeded();
    for (var i = 0; i < 100 && fetched.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(fetched, [held]);
  });

  test('시작 준비 중 Client 로 전환되면 로컬 최적화를 시작하지 않는다', () async {
    const id = '95000071';
    await seedReports([reportFor(id)]);
    var allowed = true;
    DbOptimize.startAllowed = () => allowed;
    final fetched = <String>[];
    final started = DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      fetchFn: (rid) async {
        fetched.add(rid);
        return fetchOk(rid);
      },
      wait: true,
    );
    // maybeStart 는 needsRun 을 기다리는 중이다 — 그사이 모드 전환.
    allowed = false;
    DbOptimize.cancelScheduledRetry();
    await started;
    expect(fetched, isEmpty);
    expect((await DbOptimize.readMeta())?['done'], isNot(true));
  });
}
