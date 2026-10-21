// DB 최적화 Opus 판정 7건 재현 시험 — 실제 경로, 실DB, skip·완화 없음.
//
// 서버 tests/test_db_optimize_review7.py 와 대응한다. 각 시험은 수정 전 코드에서
// 실패한다(확인 순서: lib/ 만 stash → 이 파일 실행 → 실패 → 복원).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/server_completed.dart'
    as completed;
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/db_optimize_state.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/services/photo_capture_time.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:safetyreport/services/server_connection_service.dart';
import 'package:safetyreport/services/sync_engine.dart';
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
  double? lat,
  double? lng,
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
    if (lat != null) 'C_A_W': '$lat',
    if (lng != null) 'C_A_E': '$lng',
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

/// 가짜 공유 캡처: payload 가 바뀐 신고만 completed_observation.
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

/// 실제 캡처 경로용 커뮤니티 저장소(임시 경로, 활성 문맥).
Future<CommunityStore> openTestStore() async {
  final dir = await Directory.systemTemp.createTemp('sr_dbopt_r7_community_');
  final store = await CommunityStore.open(
    path: '${dir.path}/community.db',
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

Future<void> closeTestStore(CommunityStore store) async {
  final path = store.path;
  try {
    await store.db.close();
  } catch (_) {}
  await CommunityStore.closeForTest(path);
  try {
    await Directory(File(path).parent.path).delete(recursive: true);
  } catch (_) {}
}

Future<int> journalCount(CommunityStore store) async {
  final rows = await store.db.rawQuery(
    'SELECT COUNT(*) AS n FROM source_journal',
  );
  return (rows.first['n'] as int?) ?? 0;
}

/// 실제 시작 경로용 최소 게이트 스텁.
class StubGate extends CommunityGate {
  StubGate() : super(configStatus: () => 'ok');

  @override
  GateState get state => GateState(state: 'ok', canEnter: false);

  @override
  bool get canEnter => false;

  @override
  bool get canBrowse => false;

  @override
  bool get isChecked => false;

  @override
  Future<GateState> refreshNow({bool silent = false}) async => state;

  @override
  void startPolling() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  late Directory tempRawDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDbDir = Directory.systemTemp.createTempSync('sr_dbopt_r7_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
    tempRawDir = Directory.systemTemp.createTempSync('sr_dbopt_r7_raw_');
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

  Future<OptimizeRunResult> runAll({
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    Function(String id)?
    fetchFn,
  }) => DbOptimize.processAll(
    fetchFn:
        fetchFn ??
        (_) async => throw Exception('상세 조회 실패 (x, 404)'),
    isSyncing: () => false,
    rebuildPending: () async => false,
  );

  test('1. 복원이 끼면 현재 신고를 끝내고 옛 커서 없이 멈춤', () async {
    final ids = ['90000001', '90000002', '90000003'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    final seen = <String, String>{};
    final events = <String>[];
    final base = fakeCapture(seen, events);
    var captures = 0;
    var generation = 0;
    // 실제 복원 경로의 순서: 교체 직전 community.db 데이터셋을 선회전한다.
    DbOptimize.datasetIdForTest = () async => 'ds-$generation';
    DbOptimize.captureForTest = (input, id) async {
      captures++;
      final out = await base(input, id);
      generation = 1;
      return out;
    };
    final result = await runAll();
    // 현재 신고(1건)는 끝내고 멈춘다. 복원 DB 에 옛 커서·done 을 쓰지 않는다.
    expect(captures, 1);
    expect(result.finished, isFalse);
    final meta = await DbOptimize.readMeta();
    if (meta != null) {
      expect(meta['done'], isNot(true));
      expect(meta['cursor'], isNot(ids.last));
    }
    // 상태를 정리해 isRunning 이 남지 않는다(동기화 무한 보류 금지).
    expect(DbOptimize.isRunning, isFalse);
    expect(DbOptimizeState.state, 'idle');
  });

  test('1b. 처리 중 closeDb 요청이면 상태를 정리해 isRunning 이 남지 않음', () async {
    final ids = ['90000001', '90000002', '90000003'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    final seen = <String, String>{};
    final events = <String>[];
    final base = fakeCapture(seen, events);
    var captures = 0;
    DbOptimize.captureForTest = (input, id) async {
      captures++;
      if (captures == 1) {
        // 실제 닫기 경로: 백그라운드 구역 밖(루트 zone 타이머)에서 닫기를 요청한다. 닫기는 백그라운드 작업이
        // 끝날 때까지 기다리고, 작업은 다음 신고 경계에서 멈춘다. 첫 신고 처리 중에 요청해 시작 시간(커뮤니티
        // DB 를 여는 시간)에 따라 결과가 갈리지 않게 한다(예전엔 시작 20ms 뒤 고정 타이머).
        Zone.root.run(() => unawaited(LocalDbService.closeDb()));
      }
      // 처리 시간을 벌 closed 요청이 실행 중에 끼어들게 한다.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return base(input, id);
    };
    final result = await LocalDbService.runBackgroundWork(runAll);
    // DB 닫기 요청으로 중단돼도 finished=false + 상태 정리.
    expect(captures, 1);
    expect(result.finished, isFalse);
    expect(DbOptimize.isRunning, isFalse);
    expect(DbOptimizeState.state, 'idle');
    await LocalDbService.closeDb();
  });

  test('2. 옛 target 이면 커서·통계를 버리고 처음부터', () async {
    final ids = ['90000001', '90000002', '90000003'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    await DbOptimize.writeMeta({
      'target': 'mobile-parser-1',
      'cursor': ids.last,
      'done': true,
      'total': ids.length,
      'stats': {'reused': 0, 'refetched': 0, 'changed': 0, 'events': 0, 'skipped': {}},
    });
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    final processed = <String>[];
    final base = DbOptimize.captureForTest!;
    DbOptimize.captureForTest = (input, id) async {
      processed.add(id);
      return base(input, id);
    };
    final result = await runAll();
    expect(processed, ids);
    expect(result.finished, isTrue);
    final meta = await DbOptimize.readMeta();
    expect(meta!['target'], mobileParserVersion);
    expect(meta['done'], isTrue);
  });

  test('3a. 일시 조회 실패는 같은 회차에 재시도하고 done', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    final target = ids.first;
    final calls = {for (final id in ids) id: 0};
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String id) async {
      calls[id] = calls[id]! + 1;
      if (id == target && calls[id]! <= 3) {
        return (
          result: <String, dynamic>{},
          envelope: <String, dynamic>{'error': 'HTTP 500'},
        );
      }
      // 새 활동 없음(진행·답변 없음) — 일반 저장 경로를 탄다(7-2 넘김이 아님).
      final envelope = envelopeFor(id, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map<String, dynamic>),
        envelope: envelope,
      );
    }

    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    final result = await runAll(fetchFn: fetch);
    expect(result.finished, isTrue);
    // envelope 3회 재시도 뒤 같은 회차에서 다시 시도했으므로 3회 초과 호출이다.
    expect(calls[target]!, greaterThan(3));
    expect((result.stats['skipped'] as Map).containsKey('fetch_failed'), isFalse);
    expect(
      (result.stats['skipped'] as Map).containsKey(DbOptimize.retryExceededReason),
      isFalse,
    );
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isTrue);
    expect(meta['attempts'] ?? {}, isEmpty);
  });

  test('3b. 3번째 일시 실패는 보류 목록에 남기고 done 아님·partial', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    final target = ids.first;
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetch(String id) async {
      if (id == target) {
        return (
          result: <String, dynamic>{},
          envelope: <String, dynamic>{'error': 'HTTP 500'},
        );
      }
      // 새 활동 없음(진행·답변 없음) — 일반 저장 경로를 탄다(7-2 넘김이 아님).
      final envelope = envelopeFor(id, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map<String, dynamic>),
        envelope: envelope,
      );
    }

    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    final result = await runAll(fetchFn: fetch);
    // 7-1: 일시 실패로 완료하지 않는다. 보류만 남으면 partial(실행 중 아님)이다.
    expect(result.finished, isFalse);
    expect(result.rest, 'partial');
    expect(DbOptimizeState.state, 'partial');
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isNot(true));
    expect((meta['holds'] as List), contains(target));
    expect(await LocalDbService.getDetailRaw(target), isNull);
    // 다음 실행에 보류만 다시 시도해 끝낸다.
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    fetchOk(String id) async {
      final envelope = envelopeFor(id, cNow: 0, answerDate: null);
      return (
        result: Map<String, dynamic>.from(envelope['result'] as Map<String, dynamic>),
        envelope: envelope,
      );
    }
    final second = await runAll(fetchFn: fetchOk);
    expect(second.finished, isTrue);
    expect((await DbOptimize.readMeta())!['done'], isTrue);
  });

  test('3c. 저장 실패는 재시도한다', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    final target = ids.first;
    final seen = <String, String>{};
    final events = <String>[];
    final base = fakeCapture(seen, events);
    var n = 0;
    DbOptimize.captureForTest = (input, id) async {
      if (id == target) {
        n++;
        if (n == 1) throw SaveTransient('boom');
      }
      return base(input, id);
    };
    final result = await runAll();
    expect(result.finished, isTrue);
    expect(n, 2);
    final meta = await DbOptimize.readMeta();
    expect(meta!['done'], isTrue);
  });

  test('4. 재파싱 공유 캡처는 deleted_by_user 관측을 되살리지 않는다', () async {
    final store = await openTestStore();
    DbOptimize.openStoreForTest = () async => store;
    DbOptimize.captureForTest = null; // 실제 캡처 경로
    DbOptimize.namespaceForTest = 'ns1';
    try {
      final ids = ['90000001', '90000002'];
      await seedReports(ids);
      for (final id in ids) {
        await insertRaw(id, envelopeFor(id));
      }
      final first = await runAll();
      expect(first.finished, isTrue);
      final before = await journalCount(store);
      expect(before, greaterThan(0));
      // 사용자가 공유 관측을 지운다(실제 삭제 경로).
      await completed.onContributionsDeleted(
        deletedAt: DateTime.now().toUtc(),
        store: store,
      );
      // 삭제 뒤 원본이 바뀌면(답변 변경) 재파싱 payload 가 달라지지만 되살리면 안 된다.
      final target = ids.first;
      final d = await LocalDbService.db;
      await d.delete('report_detail_raw', where: 'ID = ?', whereArgs: [target]);
      await insertRaw(
        target,
        envelopeFor(
          target,
          seed: '바뀜',
          status: '불수용',
          agency: '경기도 부천원미경찰서',
          amount: '처분이 불가합니다.',
          cNow: 14,
        ),
      );
      await DbOptimize.writeMeta({
        'target': mobileParserVersion,
        'cursor': '',
        'done': false,
        'total': ids.length,
        'stats': {},
      });
      final second = await runAll();
      expect(second.finished, isTrue);
      expect(await journalCount(store), before);
      expect(second.stats['events'] ?? 0, 0);
    } finally {
      await closeTestStore(store);
    }
  });

  test('5a. 보류한 수동 동기화 두 건은 하나로 합쳐 영속한다', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    final n = await DbOptimize.deferManualSync(
      fullSync: true,
      preserveDataset: false,
      backgroundWorker: false,
    );
    expect(n, 1);
    final peeked = await DbOptimize.peekManualSync();
    expect(peeked, isNotNull);
    expect(peeked!['fullSync'], isTrue);
    // 시작 전에는 실제 DB 에 남는다.
    final raw = await LocalDbService.getMeta(DbOptimize.deferredManualKey);
    expect(jsonDecode(raw!)['fullSync'], isTrue);
  });

  test('5b. 끝나면 정확히 한 번 시작하고 시작 성공 뒤에만 지운다', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
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
    await DbOptimize.runDeferredStarters();
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNull);
  });

  test('5c. 소유권 경쟁으로 시작하지 못하면 보류를 유지한다', () async {
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    DbOptimize.manualStarter = () async => false;
    await DbOptimize.runDeferredStarters();
    // 유실 금지: 시작하지 못했으면 지우지 않는다.
    expect(await DbOptimize.peekManualSync(), isNotNull);
  });

  test('5d. 재시작해도 done 뒤 보류 요청을 시작한다', () async {
    final ids = ['90000001'];
    await DbOptimize.deferManualSync(
      fullSync: false,
      preserveDataset: false,
      backgroundWorker: false,
    );
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': ids.first,
      'done': true,
      'total': ids.length,
      'stats': {},
    });
    var starts = 0;
    DbOptimize.manualStarter = () async {
      starts++;
      return true;
    };
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      wait: true,
    );
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNull);
  });

  test('6. 재파싱은 파서 좌표를 쓰고 사진 촬영 열은 손대지 않는다', () async {
    const id = '90000001';
    await seedReports([id]);
    await insertRaw(id, envelopeFor(id));
    final seen = <String, String>{};
    final events = <String>[];
    DbOptimize.captureForTest = fakeCapture(seen, events);
    // 사진 촬영 시각을 먼저 저장한다(재파싱이 덮으면 안 됨).
    const photo = PhotoCapture(
      first: '2026-09-20 10:00:00',
      last: '2026-09-20 10:00:05',
      count: 2,
    );
    expect(
      await LocalDbService.setPhotoCapture(id, photo, attachedPhotos: ''),
      isTrue,
    );
    // 공식 좌표가 있는 원본으로 교체한다.
    final d = await LocalDbService.db;
    await d.delete('report_detail_raw', where: 'ID = ?', whereArgs: [id]);
    await insertRaw(id, envelopeFor(id, lat: 37.5, lng: 127.0));
    await DbOptimize.writeMeta({
      'target': mobileParserVersion,
      'cursor': '',
      'done': false,
      'total': 1,
      'stats': {},
    });
    final result = await runAll();
    expect(result.finished, isTrue);
    final after =
        (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
    // 일반 저장과 같은 함수·같은 규칙으로 계산한 좌표가 반영된다.
    expect((after['위도'] as num).toDouble(), 37.5);
    expect((after['경도'] as num).toDouble(), 127.0);
    expect(after['지오코딩상태'], 'ok');
    // 사진 촬영 열은 읽지도 덮지도 않는다.
    expect(after['사진_첫촬영'], photo.first);
    expect(after['사진_끝촬영'], photo.last);
    expect(after['사진_촬영수'], photo.count);
  });

  test('7. 작업 예외면 error 로 보이고 동기화 보류를 푼다', () async {
    final ids = ['90000001', '90000002'];
    await seedReports(ids);
    for (final id in ids) {
      await insertRaw(id, envelopeFor(id));
    }
    DbOptimize.captureForTest = (_, _) async =>
        throw CaptureStoreUnavailable('community_store_unavailable');
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
    await DbOptimize.maybeStart(
      isSyncing: () => false,
      rebuildPending: () async => false,
      wait: true,
    );
    final job = DbOptimizeState.jobForStatus()!;
    expect(job['state'], 'error');
    // 크롤 보류 해제: 미뤄 둔 수동 동기화를 실행한다.
    expect(starts, 1);
    expect(await DbOptimize.peekManualSync(), isNull);
    // error 는 활성 작업이 아니다.
    final local = MaintenanceService.localJobs();
    final optimize = local.singleWhere((j) => j.key == 'db_optimize');
    expect(optimize.state, 'error');
    expect(optimize.active, isFalse);
  });

  testWidgets('7b. 표시줄은 error 를 작업 완료가 아닌 오류와 로그로 보인다', (
    tester,
  ) async {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));
    DbOptimizeState.update(state: 'running', stage: 'running', total: 2, done: 0);
    await tester.pumpWidget(host(const MaintenanceStatusBar()));
    await tester.pump();
    expect(find.byKey(const Key('maintenance-status-bar')), findsOneWidget);
    DbOptimizeState.update(
      state: 'error',
      stage: 'error',
      message: 'StateError',
    );
    DbOptimizeState.appendLog('오류로 멈춤(StateError)');
    await tester.pump();
    expect(find.textContaining('오류'), findsOneWidget);
    expect(find.text('작업 완료'), findsNothing);
    await tester.tap(find.byKey(const Key('maintenance-status-bar')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('maintenance-log-sheet')), findsOneWidget);
    expect(find.textContaining('오류로 멈춤'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('8a. init 때 실제 DB 를 열어 17→18 변환을 수행한다', () async {
    final path = await LocalDbService.getDbPath();
    await LocalDbService.closeDb();
    await deleteDatabase(path);
    // 현재 스키마로 만든 뒤 원본 표를 떼고 17로 되돌린다(실제 17 DB 와 같은 모양).
    await (await LocalDbService.db).close();
    await LocalDbService.closeDb();
    final back = await databaseFactoryFfi.openDatabase(path);
    await back.execute('DROP TABLE IF EXISTS report_detail_raw');
    await back.execute('PRAGMA user_version = 17');
    await back.close();
    LocalDbService.upgradeLog.clear();
    final provider = ReportProvider();
    await provider.init();
    expect(provider.isInitialized, isTrue);
    expect(await (await LocalDbService.db).getVersion(), 18);
    expect(
      LocalDbService.upgradeLog.any((line) => line.contains('새 표 생성(스키마 18)')),
      isTrue,
    );
  });

  testWidgets('8b. 시작 화면이 실제 시작 경로에서 업그레이드 표시를 보인다', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // init 을 부르지 않은 provider → 실제 시작 경로의 시작 화면.
    final provider = ReportProvider();
    final gate = StubGate();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider<CommunityGate>.value(value: gate),
          ChangeNotifierProvider(
            create: (_) => NotificationHistoryProvider(),
          ),
        ],
        child: SafetyReportApp(
          serverVersionCheck: (_, _) async => ServerConnectionResult.ok(
            normalizedUrl: 'http://test',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('DB 최적화 중입니다…'), findsNothing);
    // 실제 DB 열기가 남기는 것과 같은 상태 변경 → 다시 그려져 보인다.
    LocalDbService.upgradeRunning = true;
    LocalDbService.upgradeLog.add('업그레이드 전 백업 완료(before_v18_1.bak)');
    DbOptimizeState.notifyChanged();
    await tester.pump();
    expect(find.text('DB 최적화 중입니다…'), findsOneWidget);
    expect(find.textContaining('백업 완료'), findsOneWidget);
    // 단계 로그가 바뀌면 다시 그린다(실제 업그레이드 기록과 같은 경로).
    LocalDbService.upgradeLog.add('새 표 생성(스키마 18)');
    DbOptimizeState.notifyChanged();
    await tester.pump();
    expect(find.textContaining('새 표 생성'), findsOneWidget);
    LocalDbService.upgradeRunning = false;
    LocalDbService.upgradeLog.clear();
    DbOptimizeState.resetForTest();
    await tester.pumpWidget(const SizedBox());
  });
}
