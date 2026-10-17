// 재파싱 공유 캡처 입력의 목록 값은 기존 행 (서버 REPARSE_CAPTURE_TITLE_COLUMNS 회귀).
//
// 일반 동기화 저장(`SyncEngine.captureAndSaveDetail`) 때 공유 payload 에 실린 목록 값
// (신고번호·신고명·신고일·별점 등 — 목록·만족도 조회에서 채움)은 재파싱 파서 출력에 없다.
// 재파싱이 파서 출력만으로 캡처 입력을 만들면 같은 원본도 payload 가 달라져 가짜
// `completed_observation` 이 나가고 공유 최신값(특히 별점)을 덮는다.
// 재파싱은 DB 쓰기 트랜잭션 안에서 읽은 기존 행 값으로 캡처 입력을 채워야 한다
// (DB 목록 열 자체는 갱신하지 않음).
//
// 실제 `capture` 경로·실제 journal 로만 확인한다(캡처 가짜 금지).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/capture_retry_store.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/standalone_parser.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _rid = '91000001';
const _rnum = 'SPP-2512-91000001';
const _rdate = '2025-12-30';
const _rating = 4;
const _ns = 'test-namespace';

/// 일반 동기화의 목록 API 한 항목. 별점·신고번호·신고명·신고일은 목록에서만 오고
/// 상세 `result` 에는 없다(만족도는 별도 API — 파서 출력에 없음).
Map<String, dynamic> _listItem() => {
  'C_NO': _rid,
  'C_NOW': 10,
  'STTEMNT_NO': _rnum,
  'C_A_TITLE': '(자동차·교통위반) 신호위반',
  'C_DATE': '$_rdate 23:40:00',
  'STSFDG_SCORE': _rating,
};

/// 상세 API `result`. 목록에서 오는 4개 키가 없다.
Map<String, dynamic> _detailResult({
  String seed = '',
  String status = '수용',
  String agency = '서울특별시 강서경찰서 교통과',
  String amount = '과태료 40,000원을 부과하였습니다.',
  int cNow = 10,
}) => {
  'C_NO': int.parse(_rid),
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
  'answers': [
    {
      'C_MANAGER_TYPE_NM': status,
      'C_MANAGE_CONTENTS': amount,
      'C_MANAGE_ORG_NAME': agency,
      'C_MANAGE_MAN': '김담당',
      'C_DATE': '2026-01-02',
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CommunityStore store;
  late Directory rawDir;
  late File retryFile;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('sr_reparse_capture_');
    await databaseFactory.setDatabasesPath(dir.path);
    DbOptimize.resetForTest();
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    store = await CommunityStore.open(
      path: '${dir.path}/community.db',
      factory: databaseFactoryFfi,
    );
    DbOptimize.openStoreForTest = () async => store;
    DbOptimize.namespaceForTest = _ns;
    rawDir = Directory('${dir.path}/raw_details')..createSync();
    retryFile = File('${dir.path}/community_capture_retry.json');
  });

  tearDown(() async {
    DbOptimize.resetForTest();
    await LocalDbService.closeDb();
    await CommunityStore.closeForTest(store.path);
    dir.deleteSync(recursive: true);
  });

  /// 일반 동기화 저장 경로로 1건을 저장한다(휴대폰 번호가 없어 만족도 추가 조회 없이
  /// 파서 값(목록 별점)을 그대로 둔다 — 네트워크 금지).
  Future<SavedDetail> saveCrawled(Map<String, dynamic> result) =>
      SyncEngine.captureAndSaveDetail(
        cNo: _rid,
        item: _listItem(),
        detail: result,
        envelope: {'resultCode': '0000', 'result': result},
        rawSource: 'crawl',
        rawFileDir: rawDir,
        trigger: 'realtime',
        tracker: CaptureTracker(),
        communityStore: store,
        retryFile: retryFile,
        projectNamespace: _ns,
        captureActive: true,
      );

  /// 재파싱 1건 — 최적화와 같은 입력(목록 없음)으로 파싱·저장한다.
  Future<bool> reparse(Map<String, dynamic> result) async {
    final report = DbOptimize.parseStoredResult(_rid, result);
    expect(report, isNotNull);
    final entry = entryValueFromDetail(const {}, result);
    final cat = categoryFromDetail(report!, entry);
    final rawContent = normalizeRawPayloadText(rawContentOf(result));
    return DbOptimize.saveReparsed(report, entry, cat, rawContent: rawContent);
  }

  /// 재파싱 1건 + 실제 journal 캡처. 어댑터 입력(공유 입력 직전)을 기록하면서도
  /// 실제 [DbOptimize.captureReal] 로 journal 에 쓴다(가짜 캡처 금지).
  Future<({bool changed, Map<String, Object?>? adapter})> reparseSee(
    Map<String, dynamic> result,
  ) async {
    final report = DbOptimize.parseStoredResult(_rid, result);
    expect(report, isNotNull);
    final entry = entryValueFromDetail(const {}, result);
    final cat = categoryFromDetail(report!, entry);
    final rawContent = normalizeRawPayloadText(rawContentOf(result));
    Map<String, Object?>? seen;
    final changed = await DbOptimize.saveReparsed(
      report,
      entry,
      cat,
      rawContent: rawContent,
      captureFn: (adapterInput, id) async {
        seen = Map<String, Object?>.from(adapterInput);
        return DbOptimize.captureReal(
          adapterInput,
          id,
          store: store,
          projectNamespace: _ns,
        );
      },
    );
    return (changed: changed, adapter: seen);
  }

  /// 목록에서만 오는 값을 파서 상세에도 실은 재파싱 입력.
  /// [score]/[sttemntNo]/[cTitle]/[cDate] 가 null 이면 파서에 없는 경우다.
  Map<String, dynamic> titledDetail({
    String seed = '',
    int? score,
    String? sttemntNo,
    String? cTitle,
    String? cDate,
    int cNow = 10,
  }) {
    final d = _detailResult(seed: seed, cNow: cNow);
    if (score != null) d['STSFDG_SCORE'] = score;
    if (sttemntNo != null) d['STTEMNT_NO'] = sttemntNo;
    if (cTitle != null) d['C_A_TITLE'] = cTitle;
    if (cDate != null) d['C_DATE'] = cDate;
    return d;
  }

  Future<List<Map<String, Object?>>> journals() async {
    final ds = await store.localDatasetId();
    return store.db.rawQuery(
      'SELECT payload_json, payload_sha256, report_number FROM source_journal '
      'WHERE local_dataset_id=? AND source_report_id=? ORDER BY source_revision',
      [ds, _rid],
    );
  }

  Future<Map<String, dynamic>> lastPayload() async {
    final rows = await journals();
    return jsonDecode(rows.last['payload_json'] as String)
        as Map<String, dynamic>;
  }

  Future<String?> detailStatusNow() async {
    final rows = await store.db.rawQuery(
      'SELECT c_now_label FROM detail_status WHERE source_report_id=?',
      [_rid],
    );
    return rows.isEmpty ? null : rows.first['c_now_label']?.toString();
  }

  Future<List<Map<String, Object?>>> journalStates() async {
    final ds = await store.localDatasetId();
    return store.db.rawQuery(
      'SELECT event_id, personal_save_state FROM source_journal '
      'WHERE local_dataset_id=? AND source_report_id=? ORDER BY source_revision',
      [ds, _rid],
    );
  }

  test('같은 원본 재파싱은 새 이벤트 없이 payload 동일', () async {
    await saveCrawled(_detailResult());
    // 일반 동기화 저장이 별점까지 journal 에 남겼다(전제).
    var rows = await journals();
    expect(rows.length, 1);
    final firstJson = rows[0]['payload_json'] as String;
    final firstSha = rows[0]['payload_sha256'] as String;
    final firstPayload = jsonDecode(firstJson) as Map<String, dynamic>;
    expect(firstPayload['rating'], _rating);
    expect(firstPayload['report_date'], _rdate);
    expect(rows[0]['report_number'], _rnum);
    final db = await LocalDbService.db;
    final row =
        (await db.query(
          'reports',
          where: 'ID = ?',
          whereArgs: [_rid],
        )).single;
    expect(row['별점'], _rating);
    expect(row['신고일'], _rdate);
    expect(row['신고번호'], _rnum);

    // 같은 원본으로 재파싱 → 바뀐 것 없음·새 이벤트 없음·payload 동일.
    final changed = await reparse(_detailResult());
    expect(changed, isFalse);
    rows = await journals();
    expect(rows.length, 1);
    expect(rows[0]['payload_json'], firstJson);
    expect(rows[0]['payload_sha256'], firstSha);
  });

  test('바뀐 원본 재파싱은 1건 이벤트에 기존 목록 값 유지', () async {
    await saveCrawled(_detailResult());
    expect((await journals()).length, 1);

    // 원본의 파서 결과가 실제로 바뀜(처분 불수용).
    final changedDetail = _detailResult(
      seed: '바뀜',
      status: '불수용',
      agency: '경기도 부천원미경찰서',
      amount: '처분이 불가합니다.',
      cNow: 14,
    );
    final changed = await reparse(changedDetail);
    expect(changed, isTrue);
    final rows = await journals();
    expect(rows.length, 2);
    final payload = jsonDecode(rows.last['payload_json'] as String) as Map<String, dynamic>;
    expect(payload['rating'], _rating);
    expect(payload['report_date'], _rdate);
    expect(rows.last['report_number'], _rnum);
    // DB 목록 열은 여전히 그대로다.
    final db = await LocalDbService.db;
    final row =
        (await db.query(
          'reports',
          where: 'ID = ?',
          whereArgs: [_rid],
        )).single;
    expect((row['별점'], row['신고일'], row['신고번호']), (_rating, _rdate, _rnum));
  });

  test('기존 별점 없으면 파서 점수 있어도 공유 rating NULL(서버와 같음)', () async {
    await saveCrawled(_detailResult());
    final db = await LocalDbService.db;
    await db.update(
      'reports',
      {'별점': null},
      where: 'ID = ?',
      whereArgs: [_rid],
    );
    // 파서 상세에는 점수 5가 있다 — 서버는 title_fields(기존 행)에만 있어 NULL 이다.
    final res = await reparseSee(titledDetail(seed: '별점', score: 5));
    expect(res.changed, isTrue);
    expect(res.adapter?['rating'], isNull);
    expect(await lastPayload(), containsPair('rating', null));
    // 다른 목록 값은 기존 행 그대로다.
    final rows = await journals();
    expect(rows.last['report_number'], _rnum);
  });

  test('기존 목록값 있으면 파서 값과 달라도 기존 값 유지(열별)', () async {
    await saveCrawled(_detailResult());
    final res = await reparseSee(
      titledDetail(
        seed: '다름',
        score: 5,
        sttemntNo: 'SPP-PARSER-9999',
        cTitle: '(자동차·교통위반) 파서제목',
        cDate: '2026-05-05 01:02:03',
        cNow: 14,
      ),
    );
    expect(res.changed, isTrue);
    final adapter = res.adapter!;
    expect(adapter['rating'], _rating);
    expect(adapter['report_number'], _rnum);
    expect(adapter['report_date'], _rdate);
    expect(adapter['report_name'], '신호위반');
    expect(adapter['progress_status'], '답변완료');
    // 목록 값은 기존 행으로 메워 payload 가 달라지지 않아 새 이벤트가 없다(서버와 같음).
    final rows = await journals();
    expect(rows.length, 1);
    final payload = await lastPayload();
    expect(payload['rating'], _rating);
    expect(payload['report_date'], _rdate);
    expect(rows.single['report_number'], _rnum);
    expect(await detailStatusNow(), '답변완료');
  });

  test('기존 목록값 비면 서버 규칙대로: 번호·신고일은 상세 폴백, 이름·별점은 기존', () async {
    await saveCrawled(_detailResult());
    final db = await LocalDbService.db;
    await db.update(
      'reports',
      {'신고명': '', '신고일': '', '신고번호': '', '상태': '', '별점': null},
      where: 'ID = ?',
      whereArgs: [_rid],
    );
    final res = await reparseSee(
      titledDetail(
        seed: '비어있음',
        score: 3,
        sttemntNo: 'SPP-PARSER-1',
        cTitle: '(자동차·교통위반) 파서제목',
        cDate: '2026-06-06 07:08:09',
        cNow: 14,
      ),
    );
    expect(res.changed, isTrue);
    final adapter = res.adapter!;
    // title_fields 에 없으면 detail 값으로 떨어진다(서버 build_adapter_input).
    expect(adapter['report_number'], 'SPP-PARSER-1');
    expect(adapter['report_date'], '2026-06-06');
    // 별점은 title_fields 에서만 읽어 기존이 비면 NULL, 신고명은 기존 행 그대로다.
    expect(adapter['report_name'], '');
    expect(adapter['rating'], isNull);
    // 진행 상태는 기존이 없으면 파서 값이다.
    expect(adapter['progress_status'], '불수용');
    final payload = await lastPayload();
    expect(payload['rating'], isNull);
    expect(payload['report_date'], '2026-06-06');
    final rows = await journals();
    expect(rows.last['report_number'], 'SPP-PARSER-1');
    expect(await detailStatusNow(), '불수용');

    // 파서에도 없으면 빈 값 그대로다(없는 값으로 메우지 않음).
    final res2 = await reparseSee(_detailResult(seed: '없음', cNow: 14));
    expect(res2.changed, isTrue);
    expect(res2.adapter?['report_number'], '');
    expect(res2.adapter?['report_name'], '');
    expect(res2.adapter?['rating'], isNull);
    expect(res2.adapter?['progress_status'], '불수용');
    final rows2 = await journals();
    expect(rows2.last['report_number'], isNull);
  });

  test('캡처 성공 뒤 개인 DB 쓰기 실패하면 failed 표시·재시도 정상', () async {
    await saveCrawled(_detailResult());
    final db = await LocalDbService.db;
    // 개인 DB UPDATE 를 실패시켜 캡처 뒤 저장이 롤백되게 한다(공유 DB 는 별개라 남음).
    await db.execute(
      "CREATE TRIGGER sr_reparse_fail BEFORE UPDATE ON reports "
      "BEGIN SELECT RAISE(ABORT, 'injected_personal_save_failure'); END;",
    );
    final changedDetail = _detailResult(
      seed: '실패주입',
      status: '불수용',
      agency: '경기도 부천원미경찰서',
      amount: '처분이 불가합니다.',
      cNow: 14,
    );
    await expectLater(reparse(changedDetail), throwsA(isA<SaveTransient>()));
    // 일반 저장 1건 + 재파싱 캡처 1건. 재파싱 이벤트가 failed 로 표시된다.
    var states = await journalStates();
    expect(states.length, 2);
    expect(states.last['personal_save_state'], 'failed');

    // 방해물을 치우면 같은 입력으로 재시도해 정상 저장된다. payload 가 같아 새
    // 이벤트는 없고(2건 유지), 실패 표시도 그대로 둔다.
    await db.execute('DROP TRIGGER sr_reparse_fail');
    expect(await reparse(changedDetail), isTrue);
    states = await journalStates();
    expect(states.length, 2);
    expect(states.last['personal_save_state'], 'failed');
    final row =
        (await db.query(
          'reports',
          where: 'ID = ?',
          whereArgs: [_rid],
        )).single;
    expect(row['처리상태'], '불수용');
    expect((row['신고내용'] as String).contains('실패주입'), isTrue);
  });
}
