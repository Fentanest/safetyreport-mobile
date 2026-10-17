// Sol R7 대조 검수(명세 7절) 재현 시험 — 실제 경로, 실DB, skip·완화 없음.
//
// Opus 판정 P1~P6 중 모바일 해당분을 실제 경로로 재현한다. 각 시험은 수정 전
// 코드에서 실패한다(확인 순서: lib/ 만 stash → 이 파일 실행 → 실패 → 복원).
//
// P1 메타 모양: sync_meta.detail_raw_optimize 는 서버·모바일 같은 키·같은 의미
//   (target·cursor·done·round·holds·attempts·next_retry_at·통계 키). 서버 형식의
//   partial 메타를 그대로 넣으면 holds 만 이어서 처리한다(같은 target 일 때).
// P2 실패: 신고별 일시 실패는 3번째 실패에서 holds 로. 전역 장애·로그인 문제는
//   지수 백오프(밑값 60초·최대 1시간)로 쉬고 동기화 성공 직후 깨움.
// P3 상태: holds 만 남고 한 바퀴가 끝나면 state='partial', 실행 중 작업 아님
//   (정비 active=false, 표시줄은 '보류 N건, 다음 재시도 …' 로 조용히).
// P4 배출: 완료·partial·outage·login_required·오류 어떤 경로로 끝나거나 쉬든
//   보류한 수동·단건 넘김 큐 요청을 배출한다.
// P5 신고번호 없는 행의 새 활동: 저장하지 않고(원본·파서 열·파일) 대기열에
//   넣지 않으며 '새 답변 — 다음 일반 크롤에서 처리(신고번호 없음)' 로그 뒤
//   처리 완료로 센다.
// P6 저장 직전 충돌: 처리 완료로 세지 않고 시도 횟수 증가 없이 holds 로 넘긴다
//   (기존 db_optimize_section7_test.dart 7-4 충돌 시험이 holds 키로 계속 확인).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/db_optimize_state.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/services/standalone_pending_queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> envelopeFor(
  String id, {
  int cNow = 10,
  String? answerDate = '2026-01-02',
  String status = '수용',
  String agency = '서울특별시 강서경찰서 교통과',
  String amount = '과태료 40,000원을 부과하였습니다.',
}) => {
  'resultCode': '0000',
  'result': {
    'C_NO': id,
    'C_NAME': '홍길동',
    'C_EMAIL': 'a@b.c',
    'C_PHONE': '01012345678',
    'C_PHONE2': '010-1234-5678',
    'C_ID': 'fixtureid1',
    'C_NOW': cNow,
    'C_A_CONTENTS':
        '본 신고는 안전신문고 앱의 자동차·교통위반 메뉴로 접수된 신고입니다\n'
        '* 차량번호 : 12가3456\n* 발생일자 : 2026-09-01\n* 발생시각 : 08:00\n신고합니다',
    'RN_ADRES': '서울특별시 강서구 마곡동 1',
    'STTEMNT_NO': 'SPP-2512-$id',
    'C_A_TITLE': '(자동차·교통위반) 신호위반',
    'C_DATE': '2025-12-30 23:40:00',
    if (answerDate != null)
      'answers': [
        {
          'C_MANAGER_TYPE_NM': status,
          'C_MANAGE_CONTENTS': amount,
          'C_MANAGE_ORG_NAME': agency,
          'C_MANAGE_MAN': '김담당',
          'C_DATE': answerDate,
        },
      ]
    else
      'answers': const [],
  },
};

Report reportFor(String id, {String? number}) => Report(
  id: id,
  reportNumber: number ?? 'SPP-2512-$id',
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
  DbOptimize.openStoreForTest = null;
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

Future<void> seedReports(List<Report> reports) async {
  for (final report in reports) {
    await LocalDbService.upsertReport(
      report,
      'traffic',
      '자동차·교통위반-신호위반',
    );
  }
}

Future<List<String>> readQueue() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return StandalonePendingQueueStore.read(prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  late Directory tempRawDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDbDir = Directory.systemTemp.createTempSync('sr_dbopt_solr7_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
    tempRawDir = Directory.systemTemp.createTempSync('sr_dbopt_solr7_raw_');
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
    DbOptimize.processingMarkerTtl = const Duration(seconds: 120);
  });
  tearDown(() async {
    await resetDb();
  });

  Future<OptimizeRunResult> runAll({
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    Function(String id)?
    fetchFn,
  }) => DbOptimize.processAll(
    fetchFn: fetchFn ?? (_) async => throw Exception('상세 조회 실패 (x, 404)'),
    isSyncing: () => false,
    rebuildPending: () async => false,
  );

  Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
  fetchOk(String rid) async {
    final envelope = envelopeFor(rid, cNow: 0, answerDate: null);
    return (
      result: Map<String, dynamic>.from(envelope['result'] as Map),
      envelope: envelope,
    );
  }

  test('P1 partial 메타 모양: holds·round·next_retry_at(ISO8601)', () async {
    const id = '94000001';
    await seedReports([reportFor(id)]);
    DbOptimize.captureForTest = (input, rid) async => null;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchFail(String rid) async => (
      result: <String, dynamic>{},
      envelope: <String, dynamic>{'error': 'HTTP 503'},
    );
    final result = await runAll(fetchFn: fetchFail);
    expect(result.finished, isFalse);
    expect(result.rest, 'partial');
    final meta = await DbOptimize.readMeta();
    // 서버와 같은 키·같은 의미: pending 이 아니라 holds.
    expect(meta!.containsKey('pending'), isFalse);
    expect((meta['holds'] as List), contains(id));
    // round 는 0에서 시작해 한 바퀴 끝날 때마다 +1 → 첫 partial 은 1.
    expect(meta['round'], 1);
    // 이번 회차 시도 횟수는 다음 회차로 넘기지 않는다.
    expect(meta['attempts'] ?? {}, isEmpty);
    // 다음 재시도 시각은 UTC ISO8601 문자열.
    final nextRetry = meta['next_retry_at'];
    expect(nextRetry, isA<String>());
    expect(
      () => DateTime.parse(nextRetry as String).toUtc().isAfter(
        DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
      returnsNormally,
    );
    expect(
      DateTime.parse(nextRetry as String).toUtc().isAfter(
        DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
      isTrue,
    );
    // 한 바퀴 끝·보류 남음 → state='partial', 실행 중 작업 아님(P3).
    expect(DbOptimizeState.state, 'partial');
    expect(DbOptimize.isRunning, isFalse);
    final jobs = MaintenanceService.localJobs();
    final job = jobs.singleWhere((j) => j.key == 'db_optimize');
    expect(job.active, isFalse);
    expect(job.message, contains('다음 재시도'));
  });

  test('P1 완료 메타: round 0·보류 없음·next_retry_at 생략', () async {
    const id = '94000002';
    await seedReports([reportFor(id)]);
    DbOptimize.captureForTest = (input, rid) async => null;
    final result = await runAll(fetchFn: fetchOk);
    expect(result.finished, isTrue);
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isTrue);
    expect((meta['holds'] as List? ?? const []), isEmpty);
    expect(meta['round'], 0);
    expect(meta.containsKey('next_retry_at'), isFalse);
    expect(meta.containsKey('pending'), isFalse);
  });

  test('P1 서버 형식 partial 메타를 그대로 넣으면 holds 만 이어서 처리', () async {
    const held = '94000011';
    const other = '94000012';
    await seedReports([reportFor(held), reportFor(other)]);
    DbOptimize.captureForTest = (input, rid) async => null;
    // 상대 레포(서버) 형식의 partial 메타 픽스처 — 서버 키 이름 그대로.
    await DbOptimize.writeMeta({
      'target': 'pc-parser-13',
      'cursor': '',
      'done': false,
      'total': 2,
      'stats': {
        'reused': 0,
        'refetched': 0,
        'changed': 0,
        'events': 0,
        'forwarded': 0,
        'skipped': <String, dynamic>{},
      },
      'attempts': <String, dynamic>{},
      'holds': [held],
      'round': 2,
      'next_retry_at': '2026-10-17T00:00:00.000Z',
    });
    // 같은 target 세대이므로 다시 시작하지 않고 보류만 본다.
    expect(await DbOptimize.needsRun(), isTrue);
    final fetched = <String>[];
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchSpy(String rid) async {
      fetched.add(rid);
      return fetchOk(rid);
    }
    final result = await runAll(fetchFn: fetchSpy);
    expect(result.finished, isTrue);
    expect(fetched, [held]);
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('P1 옛 숫자 next_retry_at·pending 키도 읽는다(하위호환)', () async {
    const held = '94000013';
    const other = '94000014';
    await seedReports([reportFor(held), reportFor(other)]);
    DbOptimize.captureForTest = (input, rid) async => null;
    await DbOptimize.writeMeta({
      'target': 'pc-parser-13',
      'cursor': '',
      'done': false,
      'total': 2,
      'stats': <String, dynamic>{},
      'attempts': <String, dynamic>{},
      // 고치기 전 양쪽이 쓰던 모양: 모바일 pending 키·서버 숫자 시각.
      'pending': [held],
      'round': 1,
      'next_retry_at': 1760000000.0,
    });
    final fetched = <String>[];
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchSpy(String rid) async {
      fetched.add(rid);
      return fetchOk(rid);
    }
    final result = await runAll(fetchFn: fetchSpy);
    expect(result.finished, isTrue);
    expect(fetched, [held]);
  });

  test('P1 next_retry_at 읽기·쓰기: ISO8601 정본·옛 숫자 하위호환', () {
    expect(DbOptimize.parseNextRetryAt(null), isNull);
    expect(DbOptimize.parseNextRetryAt(0), isNull);
    expect(DbOptimize.parseNextRetryAt(''), isNull);
    final iso = '2026-10-17T00:00:00.000Z';
    expect(
      DbOptimize.parseNextRetryAt(iso),
      DateTime.parse(iso).toUtc(),
    );
    // 고치기 전 서버가 쓰던 epoch 초 숫자(숫자 문자열 포함).
    expect(
      DbOptimize.parseNextRetryAt(1760000000.0),
      DateTime.fromMillisecondsSinceEpoch(1760000000000, isUtc: true),
    );
    expect(
      DbOptimize.parseNextRetryAt('1760000000'),
      DateTime.fromMillisecondsSinceEpoch(1760000000000, isUtc: true),
    );
    // 쓰기는 UTC ISO8601.
    final written = DbOptimize.formatNextRetryAt(
      DateTime.utc(2026, 10, 17, 0, 0, 0),
    );
    expect(DateTime.parse(written).toUtc(), DateTime.utc(2026, 10, 17));
    // target 세대 비교: 접두사가 달라도 같은 세대면 같다.
    expect(DbOptimize.sameTarget('pc-parser-13', 'mobile-parser-13'), isTrue);
    expect(DbOptimize.sameTarget('mobile-parser-1', 'mobile-parser-13'), isFalse);
  });

  test('P2 신고별 일시 실패는 3번째 실패에서 holds 로(시도 3회)', () async {
    const id = '94000021';
    await seedReports([reportFor(id)]);
    DbOptimize.captureForTest = (input, rid) async => null;
    var calls = 0;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchFail(String rid) async {
      calls++;
      return (
        result: <String, dynamic>{},
        envelope: <String, dynamic>{'error': 'HTTP 503'},
      );
    }
    final result = await runAll(fetchFn: fetchFail);
    expect(result.finished, isFalse);
    expect(result.rest, 'partial');
    // 같은 회차 3번 시도(envelope 재시도 3회씩 → 호출 9회) 뒤 보류. 4번째는 없다.
    expect(calls, 9);
    final meta = await DbOptimize.readMeta();
    expect((meta!['holds'] as List), contains(id));
  });

  test('P4 쉬는 경로(partial)에서도 보류한 수동·단건 넘김 요청을 배출한다', () async {
    const id = '94000031';
    await seedReports([reportFor(id)]);
    DbOptimize.captureForTest = (input, rid) async => null;
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    await DbOptimize.markDrainDeferred();
    var manualStarts = 0;
    var drainStarts = 0;
    DbOptimize.manualStarter = () async {
      manualStarts++;
      return true;
    };
    DbOptimize.drainStarter = () async {
      drainStarts++;
      return true;
    };
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchFail(String rid) async => (
      result: <String, dynamic>{},
      envelope: <String, dynamic>{'error': 'HTTP 503'},
    );
    final result = await runAll(fetchFn: fetchFail);
    expect(result.rest, 'partial');
    expect(manualStarts, 1);
    expect(drainStarts, 1);
    expect(await DbOptimize.hasDeferredManual(), isFalse);
    expect(await DbOptimize.isDrainDeferred(), isFalse);
  });

  test('P4 쉬는 경로(outage)에서도 보류한 요청을 배출한다', () async {
    final ids = ['94000041', '94000042', '94000043', '94000044', '94000045'];
    await seedReports([for (final id in ids) reportFor(id)]);
    DbOptimize.captureForTest = (input, rid) async => null;
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    var manualStarts = 0;
    DbOptimize.manualStarter = () async {
      manualStarts++;
      return true;
    };
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchFail(String rid) async => (
      result: <String, dynamic>{},
      envelope: <String, dynamic>{'error': 'HTTP 503'},
    );
    final result = await runAll(fetchFn: fetchFail);
    expect(result.rest, 'outage');
    expect(manualStarts, 1);
    expect(await DbOptimize.hasDeferredManual(), isFalse);
  });

  test('P5 신고번호 없는 행의 새 활동은 저장·대기열 없이 처리 완료로 센다', () async {
    const id = '94000051';
    await seedReports([reportFor(id, number: '')]);
    var captures = 0;
    DbOptimize.captureForTest = (input, rid) async {
      captures++;
      return null;
    };
    // 저장된 행(진행·답변 없음)보다 새 상세(답변완료·답변일 있음).
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String rid) async {
      final envelope = envelopeFor(rid);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map),
        envelope: envelope,
      );
    }
    final result = await runAll(fetchFn: fetch);
    expect(result.finished, isTrue);
    expect((result.stats['forwarded'] as int? ?? 0), 0);
    // 저장하지 않는다(원본 표·파서 열·파일 모두).
    expect(await LocalDbService.getDetailRaw(id), isNull);
    final d = await LocalDbService.db;
    final row =
        (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
    expect(row['상태'], '진행');
    expect(row['답변일'], '');
    expect(File('${tempRawDir.path}/$id.json').existsSync(), isFalse);
    expect(captures, 0);
    // 대기열에 넣지 않고 처리 완료로 센다.
    expect(await readQueue(), isNot(contains(id)));
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isTrue);
    expect((meta['holds'] as List? ?? const []), isEmpty);
    final logText = (DbOptimizeState.jobForStatus()!['log'] as List).join('\n');
    expect(logText, contains('새 답변 — 다음 일반 크롤에서 처리(신고번호 없음)'));
  });

  test('P2·P3 로그인·전역 장애 쉼은 지수 백오프(밑값 60초·최대 1시간)', () {
    final realLogin = DbOptimize.loginRetryInterval;
    final realOutage = DbOptimize.outageRetryInterval;
    final realRound = DbOptimize.roundRetryInterval;
    try {
      DbOptimize.loginRetryInterval = const Duration(seconds: 60);
      DbOptimize.outageRetryInterval = const Duration(seconds: 60);
      DbOptimize.roundRetryInterval = const Duration(seconds: 60);
      expect(DbOptimize.restBackoff('login_required', 1), const Duration(seconds: 60));
      expect(DbOptimize.restBackoff('login_required', 2), const Duration(minutes: 2));
      expect(DbOptimize.restBackoff('outage', 3), const Duration(minutes: 4));
      expect(DbOptimize.restBackoff('partial', 10), const Duration(hours: 1));
    } finally {
      DbOptimize.loginRetryInterval = realLogin;
      DbOptimize.outageRetryInterval = realOutage;
      DbOptimize.roundRetryInterval = realRound;
    }
  });
}
