// 배포 전 검토 7절(2026-10-17 명세 7-1~7-4) 재현 시험 — 실제 경로, 실DB, skip·완화 없음.
//
// 7-1 실패 처리: 401·403·토큰 만료·로그인 화면은 auth, 404 등 명확한 없음만 영구.
//   신고별 일시 실패 3회 초과 → 보류 목록·done 아님·partial·재실행 재시도.
//   연속 5건 일시 실패·로그인 문제 → 신고별 횟수 없이 전체 쉼(outage/login_required),
//   지수 백오프 + 동기화 성공 직후 재개. 요청 간격 유지, 신고당 긴 대기 없음.
// 7-2 새 답변: 재조회 판정이 참이면 저장하지 않고 일반 크롤 대기 큐(영속)에 넣는다.
// 7-3 쉬는 최적화는 동기화를 막지 않는다(실제 처리 중에만 게이트).
// 7-4 엔진 간 배제: 영속 처리 중 표시·같은 lease·저장 직전 재확인.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/db_optimize_state.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/services/standalone_auto_sync_service.dart';
import 'package:safetyreport/services/standalone_parser.dart';
import 'package:safetyreport/services/standalone_pending_queue_store.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:safetyreport/widgets/maintenance_status_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// answers 가 없으면 파싱한 답변일은 '' 이다(진행 중 행과 새 활동 없음).
Map<String, dynamic> envelopeFor(
  String id, {
  String seed = '',
  int cNow = 10,
  String? answerDate = '2026-01-02',
  String status = '수용',
  String agency = '서울특별시 강서경찰서 교통과',
  String amount = '과태료 40,000원을 부과하였습니다.',
}) => {
  'resultCode': '0000',
  'result': {
    'C_NO': id,
    'C_NAME': '홍길동$seed',
    'C_EMAIL': 'a@b.c',
    'C_PHONE': '01012345678',
    'C_PHONE2': '010-1234-5678',
    'C_ID': 'fixtureid1',
    'C_NOW': cNow,
    'C_A_CONTENTS':
        '본 신고는 안전신문고 앱의 자동차·교통위반 메뉴로 접수된 신고입니다\n'
        '* 차량번호 : 12가3456\n* 발생일자 : 2026-09-01\n* 발생시각 : 08:00\n신고합니다$seed',
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
fakeCapture(Map<String, String> seen, List<String> events) =>
    (adapterInput, id) async {
      final sha = sha256Hex(utf8.encode(jsonEncode(adapterInput)));
      if (seen[id] == sha) {
        return const CaptureResult(
          eventId: null,
          eventType: null,
          eligible: true,
          payloadSha256: '',
          sourceRevision: null,
        );
      }
      seen[id] = sha;
      events.add(id);
      return CaptureResult(
        eventId: 'event-$id-${events.length}',
        eventType: 'completed_observation',
        eligible: true,
        payloadSha256: sha,
        sourceRevision: events.length,
      );
    };

Future<CommunityStore> openTestStore(Directory dir, String name) async {
  final store = await CommunityStore.open(
    path: '${dir.path}/$name.db',
    factory: databaseFactoryFfi,
  );
  await store.setContext({
    'contributor_fingerprint': 'fp1',
    'connection_id': '11111111-1111-4111-8111-111111111111',
    'writer_epoch': 1,
    'dataset_key': 'ds1',
    'consent_grant_id': '22222222-2222-4222-8222-222222222222',
    'policy_version': '2026-09-28.1',
    'consent_text_sha256': 'abc',
    'source_app': 'safetyreport-mobile',
    'source_mode': 'standalone',
  });
  await store.setMeta('project_namespace', 'ns1');
  return store;
}

Future<List<String>> readQueue() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return StandalonePendingQueueStore.read(prefs);
}

Future<void> waitForDone({Duration limit = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    final meta = await DbOptimize.readMeta();
    if (meta != null &&
        meta['target'] == mobileParserVersion &&
        meta['done'] == true) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('done 이 되지 않았다');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  late Directory tempRawDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDbDir = Directory.systemTemp.createTempSync('sr_dbopt_s7_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
    tempRawDir = Directory.systemTemp.createTempSync('sr_dbopt_s7_raw_');
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
    fetchFn:
        fetchFn ?? (_) async => throw Exception('상세 조회 실패 (x, 404)'),
    isSyncing: () => false,
    rebuildPending: () async => false,
  );

  test('7-2 계약 벡터: 새 활동 판정은 서버와 바이트 동일한 계약과 같다', () async {
    final file = File('contracts/reparse-new-activity-vectors.json');
    expect(file.existsSync(), isTrue);
    final contract =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    // 진행 단계 표가 계약과 같다.
    final table = cNowStatusTable();
    final contractTable = contract['c_now_status'] as Map<String, dynamic>;
    expect(
      {for (final e in table.entries) '${e.key}': e.value},
      {for (final e in contractTable.entries) e.key: '${e.value}'},
    );
    // fallback 규칙: 양수는 숫자 문자열·그 밖은 진행.
    expect(mapCNowStatus(0), '진행');
    expect(mapCNowStatus('10'), '답변완료');
    expect(mapCNowStatus(16), '16');
    expect(mapCNowStatus(null), '진행');
    // 모든 벡터 케이스.
    for (final c in (contract['cases'] as List).cast<Map<String, dynamic>>()) {
      expect(
        hasReparseNewActivity(
          storedStatus: '${c['stored_status'] ?? ''}',
          storedAnswerDate: c['stored_answer_date'],
          detailCNow: c['detail_c_now'],
          parsedAnswerDate: c['parsed_answer_date'],
        ),
        c['new_activity'] == true,
        reason: '벡터 ${c['name']}',
      );
    }
  });

  test('7-1 실패 분류: 401·403·토큰 만료·로그인 화면은 auth, 404·410만 영구', () {
    expect(
      DbOptimize.classifyFetchError(Exception('상세 조회 실패 (x, 401)')),
      'auth',
    );
    expect(
      DbOptimize.classifyFetchError(Exception('상세 조회 실패 (x, 403)')),
      'auth',
    );
    expect(
      DbOptimize.classifyFetchError(const TokenExpiredException('만료')),
      'auth',
    );
    expect(DbOptimize.classifyFetchError(Exception('HTTP 401')), 'auth');
    expect(
      DbOptimize.classifyFetchError(Exception('로그인 화면이 돌아옴')),
      'auth',
    );
    expect(
      DbOptimize.classifyFetchError(Exception('상세 조회 실패 (x, 404)')),
      'permanent',
    );
    expect(DbOptimize.classifyFetchError(Exception('HTTP 410 Gone')), 'permanent');
    expect(DbOptimize.classifyFetchError(Exception('HTTP 500')), 'retryable');
    expect(
      DbOptimize.classifyFetchError(Exception('네트워크 오류 (3회 재시도 실패)')),
      'retryable',
    );
  });

  test('7-1 503 반복 → done 아님·partial·보류, 재실행에 재시도', () async {
    const id = '93000001';
    await seedReports([id]);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    var calls = 0;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String rid) async {
      calls++;
      return (
        result: <String, dynamic>{},
        envelope: <String, dynamic>{'error': 'HTTP 503'},
      );
    }
    final result = await runAll(fetchFn: fetch);
    // 3번째 실패에서 보류로 넘어간다(같은 회차, 서버와 같음).
    expect(calls, greaterThan(3));
    expect(result.finished, isFalse);
    expect(result.rest, 'partial');
    expect(DbOptimizeState.state, 'partial');
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isNot(true));
    expect((meta['holds'] as List), contains(id));
    // 원본 없이 완료하지 않는다.
    expect(await LocalDbService.getDetailRaw(id), isNull);
    // 재실행하면 보류만 다시 시도해 끝낸다(새 활동 없는 응답).
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchOk(String rid) async {
      final envelope = envelopeFor(rid, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map),
        envelope: envelope,
      );
    }
    final second = await runAll(fetchFn: fetchOk);
    expect(second.finished, isTrue);
    expect((await DbOptimize.readMeta())!['done'], isTrue);
    expect(await LocalDbService.getDetailRaw(id), isNotNull);
  });

  test('7-1 연속 5건 일시 실패 → outage 쉼·신고별 횟수 증가 없음', () async {
    final ids = ['93000011', '93000012', '93000013', '93000014', '93000015', '93000016'];
    await seedReports(ids);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    var calls = 0;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String rid) async {
      calls++;
      return (
        result: <String, dynamic>{},
        envelope: <String, dynamic>{'error': 'HTTP 503'},
      );
    }
    final result = await runAll(fetchFn: fetch);
    // 5번째 연속 실패에서 전체가 쉰다(6번째 신고는 건드리지 않음).
    expect(calls, 5 * 3);
    expect(result.finished, isFalse);
    expect(result.rest, 'outage');
    expect(DbOptimizeState.stage, 'outage');
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isNot(true));
    // 신고별 시도 횟수는 늘리지 않는다(롤백) — 보류에는 시도 횟수 없이 남는다.
    // 쉬면 남은 꼬리까지 보류에 넣어(서버 _park_partial 과 같은 자리) 다음 회차는
    // 보류(손댄 5건 + 아직 안 본 1건)만 다시 시도한다.
    expect(meta['attempts'] ?? {}, isEmpty);
    expect((meta['holds'] as List).length, 6);
    // 다음 회차는 처음부터 다시 시도한다(성공 응답이면 끝까지 간다).
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchOk(String rid) async {
      final envelope = envelopeFor(rid, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map),
        envelope: envelope,
      );
    }
    final second = await runAll(fetchFn: fetchOk);
    expect(second.finished, isTrue);
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('7-1 토큰 만료 → login_required 쉼·게이트 열림·동기화 성공 뒤 재개', () async {
    final ids = ['93000021', '93000022'];
    await seedReports(ids);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    var expired = true;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String rid) async {
      if (expired) throw const TokenExpiredException('만료');
      final envelope = envelopeFor(rid, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map),
        envelope: envelope,
      );
    }
    DbOptimize.fetchDetailForTest = fetch;
    final result = await runAll(fetchFn: fetch);
    expect(result.finished, isFalse);
    expect(result.rest, 'login_required');
    expect(DbOptimizeState.stage, 'login_required');
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isNot(true));
    // 신고별 시도 횟수는 늘리지 않는다.
    expect(meta['attempts'] ?? {}, isEmpty);
    // 쉬는 동안 동기화 게이트는 열린다 — 실제 처리 중이 아니다.
    expect(DbOptimize.blocksSync, isFalse);
    expect(await DbOptimize.isProcessingPersisted(), isFalse);
    // 알림 동기화(빈 큐)는 바로 실행된다.
    expect(await StandaloneAutoSyncService.drainIfPending(), isTrue);
    // 로그인(동기화 성공) 뒤 재개 — drain 성공이 wake 을 남겼으므로 재판단하면 끝난다.
    expired = false;
    await DbOptimize.notifySyncSucceeded();
    await waitForDone();
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('7-2 진행 신고에 새 답변 재조회 → 저장 안 함·대기 큐 등록·처리 완료', () async {
    const id = '93000031';
    const number = 'SPP-2512-$id';
    await seedReports([id]);
    var captures = 0;
    DbOptimize.captureForTest = (input, rid) async {
      captures++;
      return null;
    };
    // 저장된 행은 진행·답변 없음. 다시 받은 상세는 답변완료 + 답변일 있음.
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
    expect((result.stats['forwarded'] as int? ?? 0), 1);
    // 저장하지 않는다(원본 표·파서 열·파일 모두).
    expect(await LocalDbService.getDetailRaw(id), isNull);
    final d = await LocalDbService.db;
    final row =
        (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
    expect(row['상태'], '진행');
    expect(row['답변일'], '');
    expect(
      File('${tempRawDir.path}/$id.json').existsSync(),
      isFalse,
    );
    expect(captures, 0);
    // 일반 크롤 대기 큐(영속)에 넣고 로그를 남긴다. 보류가 아니라 처리 완료다.
    expect(await readQueue(), contains(number));
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isTrue);
    expect((meta['holds'] as List? ?? const []), isEmpty);
    final logText = (DbOptimizeState.jobForStatus()!['log'] as List).join('\n');
    expect(logText, contains('새 답변 — 일반 크롤로 넘김'));
  });

  test('7-2 새 활동 없음 → 정상 저장(원본 채움·대기 큐에 없음)', () async {
    const id = '93000032';
    const number = 'SPP-2512-$id';
    await seedReports([id]);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String rid) async {
      final envelope = envelopeFor(rid, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map),
        envelope: envelope,
      );
    }
    final result = await runAll(fetchFn: fetch);
    expect(result.finished, isTrue);
    expect((result.stats['forwarded'] as int? ?? 0), 0);
    expect((await LocalDbService.getDetailRaw(id))!['source'], 'backfill');
    expect(await readQueue(), isNot(contains(number)));
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('7-4 다른 엔진이 lease 를 쥐면 기다렸다가 건드리지 않고 보류', () async {
    const id = '93000041';
    await seedReports([id]);
    await insertRaw(id, envelopeFor(id, cNow: 0, answerDate: null));
    final dir = await Directory.systemTemp.createTemp('sr_dbopt_s7_lease_');
    final store = await openTestStore(dir, 'community');
    DbOptimize.openStoreForTest = () async => store;
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    // 별도 엔진 흉내: 다른 소유자가 lease 를 쥔다.
    expect(
      await store.acquireLease(
        'personal_sync',
        'other-engine',
        const Duration(minutes: 10),
      ),
      isTrue,
    );
    try {
      final result = await runAll();
      // lease 대기 초과 → 일시 실패로 보류(partial), 덮지 않는다.
      expect(result.finished, isFalse);
      final meta = await DbOptimize.readMeta();
      expect(meta!['done'], isNot(true));
      expect((meta['holds'] as List), contains(id));
      final d = await LocalDbService.db;
      final row =
          (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
      expect(row['상태'], '진행');
      // lease 를 놓으면 다음 회차에 끝낸다.
      await store.releaseLease('personal_sync', 'other-engine');
      final second = await runAll();
      expect(second.finished, isTrue);
      expect((await DbOptimize.readMeta())!['done'], isTrue);
    } finally {
      try {
        await store.db.close();
      } catch (_) {}
      await CommunityStore.closeForTest(store.path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('7-4 저장 직전 다른 엔진이 저장했으면 덮지 않고 다음 회차로(시도 증가 없음)', () async {
    const id = '93000051';
    await seedReports([id]);
    final oldEnvelope = envelopeFor(id, cNow: 0, answerDate: null);
    await insertRaw(id, oldEnvelope);
    final dir = await Directory.systemTemp.createTemp('sr_dbopt_s7_conflict_');
    final store = await openTestStore(dir, 'community');
    DbOptimize.openStoreForTest = () async => store;
    final seen = <String, String>{};
    final events = <String>[];
    final base = fakeCapture(seen, events);
    // 알림 동기화 흉내: 최적화가 읽은 뒤 행+원본을 최신 답변으로 저장한다.
    var mutate = true;
    DbOptimize.captureForTest = (input, rid) async {
      if (mutate && rid == id) {
        final d = await LocalDbService.db;
        await d.update(
          'reports',
          {'상태': '답변완료', '답변일': '2026-10-16', '처리내용': '새 답변입니다'},
          where: 'ID = ?',
          whereArgs: [id],
        );
        await d.delete(
          'report_detail_raw',
          where: 'ID = ?',
          whereArgs: [id],
        );
        await insertRaw(id, envelopeFor(id, seed: '새답변'));
      }
      return base(input, rid);
    };
    try {
      final result = await runAll();
      expect(result.finished, isFalse);
      expect(result.rest, 'partial');
      // 시도 횟수는 늘지 않고 보류에만 남는다.
      final meta = await DbOptimize.readMeta();
      expect(meta!['done'], isNot(true));
      expect((meta['holds'] as List), contains(id));
      expect(meta['attempts'] ?? {}, isEmpty);
      // 최신 답변을 덮지 않았다.
      final d = await LocalDbService.db;
      final row =
          (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
      expect(row['상태'], '답변완료');
      expect(row['답변일'], '2026-10-16');
      expect(row['처리내용'], '새 답변입니다');
      // 다음 회차에는 최신 원본으로 파싱해 조용히 끝낸다.
      mutate = false;
      final second = await runAll();
      expect(second.finished, isTrue);
      expect((await DbOptimize.readMeta())!['done'], isTrue);
      final row2 =
          (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
      expect(row2['상태'], '답변완료');
    } finally {
      try {
        await store.db.close();
      } catch (_) {}
      await CommunityStore.closeForTest(store.path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('7-3 쉬는 동안 게이트는 열리고 실제 처리 중에만 닫힌다', () {
    DbOptimizeState.update(state: 'idle', stage: '');
    expect(DbOptimize.blocksSync, isFalse);
    DbOptimizeState.update(state: 'running', stage: 'running');
    expect(DbOptimize.blocksSync, isTrue);
    // 대기(크롤·초기화·로그인·장애·보류)에서는 바로 실행한다.
    for (final stage in [
      'waiting_crawl',
      'waiting_rebuild',
      'login_required',
      'outage',
      'partial',
    ]) {
      DbOptimizeState.update(
        state: stage == 'partial' ? 'partial' : 'paused',
        stage: stage,
      );
      expect(DbOptimize.blocksSync, isFalse, reason: stage);
    }
    DbOptimizeState.update(state: 'completed', stage: 'done');
    expect(DbOptimize.blocksSync, isFalse);
    DbOptimizeState.update(state: 'error', stage: 'error');
    expect(DbOptimize.blocksSync, isFalse);
  });

  test('7-1 백오프는 지수·최대 1시간', () {
    expect(
      DbOptimize.restBackoff('login_required', 1),
      const Duration(milliseconds: 1),
    );
    expect(
      DbOptimize.restBackoff('login_required', 2),
      const Duration(milliseconds: 2),
    );
    expect(
      DbOptimize.restBackoff('outage', 3),
      const Duration(milliseconds: 4),
    );
    DbOptimize.roundRetryInterval = const Duration(minutes: 40);
    expect(
      DbOptimize.restBackoff('partial', 2),
      const Duration(minutes: 60),
    );
    expect(
      DbOptimize.restBackoff('partial', 10),
      const Duration(hours: 1),
    );
  });

  testWidgets('7-1·표시 partial 은 실행 중이 아닌 대기로 보인다', (tester) async {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));
    await tester.pumpWidget(host(const MaintenanceStatusBar()));
    await tester.pump();
    expect(find.byKey(const Key('maintenance-status-bar')), findsNothing);
    DbOptimizeState.update(
      state: 'partial',
      stage: 'partial',
      total: 4,
      done: 3,
      message: '보류 1건 — 다음에 다시 시도합니다',
    );
    DbOptimizeState.appendLog('보류 1건 남음 — 다음 실행·동기화 성공 뒤 보류만 다시 시도합니다');
    await tester.pump();
    expect(find.byKey(const Key('maintenance-status-bar')), findsOneWidget);
    expect(find.textContaining('보류'), findsWidgets);
    expect(find.text('작업 완료'), findsNothing);
    await tester.tap(find.byKey(const Key('maintenance-status-bar')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('maintenance-log-sheet')), findsOneWidget);
    expect(find.textContaining('보류'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
