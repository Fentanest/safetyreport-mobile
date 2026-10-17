// DB 최적화 작업(상세 원본 기반 재파싱, 2026-10-17 명세 3절) — 서버 tests/test_db_optimize.py 와 대응.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/db_optimize_state.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/services/standalone_auto_sync_service.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/maintenance_status_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> envelopeFor(
  String id, {
  String seed = '',
  String status = '수용',
  String agency = '서울특별시 강서경찰서 교통과',
  String amount = '과태료 40,000원을 부과하였습니다.',
  int cNow = 10,
  String? answerDate = '2026-01-02',
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

/// 가짜 공유 캡처: payload 가 바뀐 신고만 completed_observation(source_revision 증가).
/// [events] 에 새 이벤트가 난 ID 를 모은다.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  late Directory tempRawDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDbDir = Directory.systemTemp.createTempSync('sr_dboptimize_test_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
    tempRawDir = Directory.systemTemp.createTempSync('sr_dboptimize_raw_');
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
  });
  tearDown(() async {
    await resetDb();
  });

  test('파서 버전은 mobile-parser-13', () {
    expect(mobileParserVersion, 'mobile-parser-13');
  });

  test('원본 있음 → 네트워크 없이 재파싱, 커서 이어하기', () async {
    final ids = ['90000001', '90000002', '90000003'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    var networkUsed = false;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    boom(String id) async {
      networkUsed = true;
      throw StateError('네트워크를 쓰면 안 됨');
    }

    // 커서부터 이어서: 첫 신고는 이미 끝난 것으로 기록한다.
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': ids.first,
      'done': false,
      'total': ids.length,
      'stats': {},
    });
    final saved = <String>[];
    final result = await DbOptimize.processAll(
      fetchFn: boom,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(result.finished, isTrue);
    expect(networkUsed, isFalse);
    expect(result.stats['reused'], 2);
    expect(result.stats['refetched'] ?? 0, 0);
    expect(saved, isEmpty); // 직접 추적 대신 메타 커서로 확인
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isTrue);
    expect(meta['cursor'], ids.last);
    expect(meta['target'], mobileParserVersion);
  });

  test('원본 없음 → 가짜 응답 재수신·저장·파일', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    final calls = <String>[];
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String id) async {
      calls.add(id);
      // 새 활동 없음(진행·답변 없음) — 일반 저장 경로를 탄다(7-2 넘김이 아님).
      final envelope = envelopeFor(id, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(
          envelope['result'] as Map<String, dynamic>,
        ),
        envelope: envelope,
      );
    }
    final result = await DbOptimize.processAll(
      fetchFn: fetch,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(result.finished, isTrue);
    expect(result.stats['refetched'], ids.length);
    expect(calls.toSet(), ids.toSet());
    for (final id in ids) {
      final row = await LocalDbService.getDetailRaw(id);
      expect(row, isNotNull);
      expect(row!['source'], 'backfill');
      final payload = decompressAndVerifyRawDetail(
        row['raw_zlib'] as Uint8List,
        row['raw_sha256'] as String,
      );
      expect(payload, prepareRawDetail(envelopeFor(id, cNow: 0, answerDate: null)).canonical);
      final file = File('${tempRawDir.path}/$id.json');
      expect(file.existsSync(), isTrue);
      final stored =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final key in rawDetailReporterKeys) {
        expect((stored['result'] as Map).containsKey(key), isFalse);
      }
    }
  });

  test('손상된 원본은 다시 받는다', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    final d = await LocalDbService.db;
    await d.update('report_detail_raw', {
      'raw_zlib': Uint8List.fromList([0, 1, 2, 3]),
    }, where: 'ID = ?', whereArgs: [ids.first]);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    final fetched = <String>[];
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String id) async {
      fetched.add(id);
      // 새 활동 없음(진행·답변 없음) — 일반 저장 경로를 탄다(7-2 넘김이 아님).
      final envelope = envelopeFor(id, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(
          envelope['result'] as Map<String, dynamic>,
        ),
        envelope: envelope,
      );
    }
    final result = await DbOptimize.processAll(
      fetchFn: fetch,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(fetched, [ids.first]);
    expect(result.stats['refetched'], 1);
  });

  test('로그인 필요하면 전체가 쉬고 이어서 한다(신고당 대기 없음)', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    var attempts = 0;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String id) async {
      attempts++;
      // 7-1: 로그인 문제는 신고별 시도 없이 작업 전체를 쉰다. 첫 호출 뒤에는
      // 로그인된 것으로 보고(신고당 대기는 없다) 바로 쉼으로 끝난다.
      if (attempts <= 1) throw const TokenExpiredException('만료');
      // 새 활동 없음(진행·답변 없음) — 일반 저장 경로를 탄다(7-2 넘김이 아님).
      final envelope = envelopeFor(id, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(
          envelope['result'] as Map<String, dynamic>,
        ),
        envelope: envelope,
      );
    }
    final first = await DbOptimize.processAll(
      fetchFn: fetch,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(first.finished, isFalse);
    expect(first.rest, 'login_required');
    expect(attempts, 1);
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isNot(true));
    expect(meta['attempts'] ?? {}, isEmpty);
    // 쉬는 동안 동기화 게이트는 열린다.
    expect(DbOptimize.blocksSync, isFalse);
    // 로그인 뒤(동기화 성공) 이어서 하면 끝난다.
    final second = await DbOptimize.processAll(
      fetchFn: fetch,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(second.finished, isTrue);
    expect(second.stats['refetched'], ids.length);
    final logText = (DbOptimizeState.jobForStatus()!['log'] as List).join('\n');
    expect(logText, contains('로그인 필요'));
    expect(logText, contains('이어서'));
    expect(DbOptimizeState.jobForStatus()!['stage'], 'done');
  });

  test('받을 수 없는 신고는 사유 남기고 건너뜀', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String id) async {
      if (id == ids.first) throw Exception('상세 조회 실패 ($id, 404)');
      // 새 활동 없음(진행·답변 없음) — 일반 저장 경로를 탄다(7-2 넘김이 아님).
      final envelope = envelopeFor(id, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(
          envelope['result'] as Map<String, dynamic>,
        ),
        envelope: envelope,
      );
    }
    final result = await DbOptimize.processAll(
      fetchFn: fetch,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(result.finished, isTrue);
    expect((result.stats['skipped'] as Map)['not_found'], 1);
    expect(result.stats['refetched'], ids.length - 1);
    final logText = (DbOptimizeState.jobForStatus()!['log'] as List).join('\n');
    expect(logText, contains('${ids.first} 건너뜀(not_found'));
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('파서 열만 바뀌고 목록 열·override 는 유지', () async {
    const id = '90000001';
    await seedReports([id]);
    await insertRaw(id, envelopeFor(id));
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    // 목록 값 변조 — 재파싱이 덮으면 안 됨.
    final d = await LocalDbService.db;
    await d.update('reports', {'상태': '진행'}, where: 'ID = ?', whereArgs: [id]);
    await d.insert('report_override', {
      'ID': id,
      'column_name': '처리기관',
      'value': '사용자 수정 기관',
      'updated_at': 1,
    });
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String rid) async {
      // 원본 표에 행이 있으므로 쓰이지 않는다.
      throw StateError('unreachable');
    }
    // 원본 답변을 불수용으로 바꾼다(파서 열은 바뀐다).
    await d.delete('report_detail_raw', where: 'ID = ?', whereArgs: [id]);
    await insertRaw(
      id,
      envelopeFor(id, status: '불수용', agency: '새 처리기관', amount: '처분이 불가합니다.', cNow: 14),
    );
    final result = await DbOptimize.processAll(
      fetchFn: fetch,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(result.finished, isTrue);
    final after =
        (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
    final effective =
        (await d.query(
          LocalDbService.effectiveReportsView,
          where: 'ID = ?',
          whereArgs: [id],
        )).single;
    expect(after['처리상태'], '불수용');
    expect(after['처리기관'], '새 처리기관');
    expect(effective['처리상태'], '불수용');
    expect(after['상태'], '진행');
    expect(effective['처리기관'], '사용자 수정 기관');
  });

  test('바뀐 신고만 공유 이벤트, 같은 내용 다시 훑으면 이벤트 없음', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    boom(String id) async => throw StateError('네트워크를 쓰면 안 됨');
    final first = await DbOptimize.processAll(
      fetchFn: boom,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(first.stats['changed'], greaterThan(0));
    final firstEvents = List<String>.from(events);
    expect(firstEvents.toSet(), ids.toSet());
    // 커서를 지우고 처음부터 다시 훑어도 같은 원본이면 이벤트 없음.
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': '',
      'done': false,
      'total': ids.length,
      'stats': {},
    });
    events.clear();
    final second = await DbOptimize.processAll(
      fetchFn: boom,
      isSyncing: () => false,
      rebuildPending: () async => false,
    );
    expect(second.stats['reused'], ids.length);
    expect(events, isEmpty);
    expect(second.stats['events'] ?? 0, 0);
    expect(second.stats['changed'] ?? 0, 0);
  });

  test('done 이면 maybeStart 는 아무 것도 안 함', () async {
    await seedReports(['90000001']);
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': '90000001',
      'done': true,
      'total': 1,
      'stats': {},
    });
    final before = await DbOptimize.readMeta();
    final logBefore =
        (DbOptimizeState.jobForStatus()?['log'] as List? ?? []).length;
    expect(await DbOptimize.needsRun(), isFalse);
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      wait: true,
    );
    expect(DbOptimize.isRunning, isFalse);
    expect(await DbOptimize.readMeta(), before);
    expect(
      (DbOptimizeState.jobForStatus()?['log'] as List? ?? []).length,
      logBefore,
    );
  });

  test('크롤 끝·초기화 끝을 기다렸다가 시작', () async {
    var n = 0;
    final ok = await DbOptimize.waitForTurn(
      isSyncing: () => ++n <= 2,
      rebuildPending: () async => false,
      wait: Duration.zero,
    );
    expect(ok, isTrue);
    expect(n, greaterThanOrEqualTo(3));
  });

  test('최적화 중 수동 동기화는 하나로 합쳐 영속·끝나면 한 번 시작', () async {
    DbOptimizeState.update(state: 'running', stage: 'running', total: 2, done: 0);
    final messages = <String>[];
    final sub = SyncEngine.events.listen((e) {
      if (e.type == SyncEventType.log) messages.add(e.message);
    });
    final first = await SyncEngine.start(fullSync: false);
    expect(first.busy, isTrue);
    expect(first.errorMessage, 'db_optimize_running');
    expect(messages, contains(DbOptimizeState.deferLogLine));
    // 두 번째 요청(전체)은 합쳐진다 — DB 에는 1건만 남는다(서버와 같음).
    final second = await SyncEngine.start(fullSync: true);
    expect(second.busy, isTrue);
    final peeked = await DbOptimize.peekManualSync();
    expect(peeked, isNotNull);
    expect(peeked!['fullSync'], isTrue);
    final raw = await LocalDbService.getMeta(DbOptimize.deferredManualKey);
    expect(jsonDecode(raw!)['fullSync'], isTrue);
    // 끝나면 정확히 한 번 시작하고 시작 성공 뒤에만 지운다.
    var starts = 0;
    DbOptimize.manualStarter = () async {
      starts++;
      return true;
    };
    await DbOptimize.runDeferredStarters();
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNull);
    // 소유권 경쟁으로 시작하지 못하면 유실 없이 유지한다.
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    DbOptimize.manualStarter = () async => false;
    await DbOptimize.runDeferredStarters();
    expect(await DbOptimize.peekManualSync(), isNotNull);
    DbOptimize.manualStarter = null;
    await sub.cancel();
  });

  test('최적화 중 알림 동기화는 바로 시작하지 않고 표시만 영속', () async {
    DbOptimizeState.update(state: 'running', stage: 'running', total: 1, done: 0);
    // 큐를 비워 둬도 defer 판단이 먼저다 — 로그 한 줄과 함께 표시만 남기고 그냥 돌아온다.
    // 알림 대기열 자체는 기존 영속 큐가 맡는다.
    final started = await StandaloneAutoSyncService.drainIfPending();
    expect(started, isFalse);
    expect(DbOptimize.isRunning, isTrue);
    expect(await DbOptimize.isDrainDeferred(), isTrue);
    await DbOptimize.clearDrainDeferred();
  });

  test('상태 표시는 label·done/total·stage·log 50줄, Client 는 추가 필드를 읽고 없으면 호환', () {
    DbOptimizeState.update(state: 'running', stage: 'running', total: 24, done: 7);
    DbOptimizeState.appendLog('원본 채우기 7/24');
    final jobs = MaintenanceService.localJobs();
    final job = jobs.singleWhere((j) => j.key == 'db_optimize');
    expect(job.label, 'DB 최적화 중입니다…');
    expect((job.done, job.total, job.stage), (7, 24, 'running'));
    expect(job.log.length, lessThanOrEqualTo(50));
    expect(job.log.single.split(' ').first.contains('-'), isTrue);
    final fromServer = MaintenanceService.jobsFromServer({
      'active': true,
      'jobs': [
        {
          'key': 'db_optimize',
          'label': 'DB 최적화 중입니다…',
          'state': 'running',
          'total': 24,
          'done': 7,
          'stage': 'running',
          'message': '',
          'log': ['2026-10-17 12:00:00 원본 채우기 7/24'],
          'finished_at': '',
        },
      ],
    });
    expect(fromServer.single.stage, 'running');
    expect(fromServer.single.log.single, contains('원본 채우기'));
    // 예전 서버(추가 필드 없음)도 예전처럼 보인다.
    final legacy = MaintenanceService.jobsFromServer({
      'active': true,
      'jobs': [
        {
          'key': 'photo_capture_time',
          'label': '주정차 사진 촬영 시각 읽기',
          'state': 'running',
          'total': 10,
          'done': 3,
        },
      ],
    });
    expect(legacy.single.stage, '');
    expect(legacy.single.log, isEmpty);
  });

  group('MaintenanceStatusBar', () {
    Widget host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(bottomNavigationBar: child),
    );

    testWidgets('최적화 표시줄·탭하면 로그 시트', (tester) async {
      await tester.pumpWidget(host(const MaintenanceStatusBar()));
      await tester.pump();
      expect(find.byKey(const Key('maintenance-status-bar')), findsNothing);
      DbOptimizeState.update(
        state: 'running',
        stage: 'running',
        total: 10,
        done: 3,
      );
      DbOptimizeState.appendLog('원본 채우기 3/10');
      await tester.pump();
      expect(find.byKey(const Key('maintenance-status-bar')), findsOneWidget);
      expect(find.textContaining('3/10'), findsOneWidget);
      await tester.tap(find.byKey(const Key('maintenance-status-bar')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('maintenance-log-sheet')), findsOneWidget);
      expect(find.textContaining('원본 채우기'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    // 시작 화면 업그레이드 표시는 test/services/db_optimize_review7_test.dart 에서
    // 실제 시작 경로(SafetyReportApp + ReportProvider.init 의 DB 열기)로 검증한다.
  });
}
