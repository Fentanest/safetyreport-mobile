// 상세 원본 저장 경로(2026-10-17 명세 1-2·1-3): upsertReport 와 같은 트랜잭션에서
// report_detail_raw upsert, 원본 파일 생성(신고자 키 제거), 삭제 경로 동반 삭제.
// capture 전체 경로는 실제 개인 DB(sqflite ffi)와 실제 community.db 로 실행한다.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/capture_retry_store.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report(String id) => Report(
  id: id,
  reportNumber: 'SPP-$id',
  name: '신호위반',
  date: '2026-09-01',
  responseDate: '',
  agency: '기관',
  manager: '담당',
  status: '처리중',
  result: '처리중',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '',
  location: '서울 강서구 1',
  occurrenceDate: '2026-09-01',
  occurrenceTime: '08:00',
  reportContent: '본문',
  processContent: '',
);

Map<String, dynamic> _detail() {
  final cases =
      (jsonDecode(File('contracts/parser-vectors.json').readAsStringSync())
              as Map)['cases']
          as List;
  // 신호위반·별점 없음 → 사진·만족도 조회(네트워크) 경로에 들어가지 않는다.
  return Map<String, dynamic>.from((cases[1] as Map)['detail'] as Map);
}

RawDetailUpsert _upsertOf(Map<String, dynamic> envelope, String source) {
  final prepared = prepareRawDetail(envelope);
  return RawDetailUpsert(
    zlib: compressRawDetail(prepared.canonical),
    sha256: prepared.sha256,
    size: prepared.canonical.length,
    fetchedAt: '2026-10-17T12:00:00.000Z',
    source: source,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CommunityStore store;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('sr_detail_raw_');
    await databaseFactory.setDatabasesPath(dir.path);
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    store = await CommunityStore.open(
      path: '${dir.path}/community.db',
      factory: databaseFactoryFfi,
    );
    await store.setContext({
      'contributor_fingerprint': 'fp1',
      'connection_id': '11111111-1111-4111-8111-111111111111',
      'writer_epoch': 3,
      'dataset_key': 'ds1',
      'consent_grant_id': '22222222-2222-4222-222222222222',
      'policy_version': '2026-09-28.1',
      'consent_text_sha256': 'abc',
      'source_app': 'safetyreport-mobile',
      'source_mode': 'standalone',
    });
    SyncEngine.openCommunityStoreForTest = () async => store;
    SyncEngine.retryFileForTest = File('${dir.path}/retry.json');
    SyncEngine.backfillForTest = () async => 0;
  });
  tearDown(() async {
    SyncEngine.openCommunityStoreForTest = null;
    SyncEngine.retryFileForTest = null;
    SyncEngine.backfillForTest = null;
    await LocalDbService.closeDb();
    await CommunityStore.closeForTest(store.path);
    dir.deleteSync(recursive: true);
  });

  test('upsertReport stores the detail row in the same transaction (upsert)', () async {
    final envelope = <String, dynamic>{
      'result': {'C_NO': 11, 'C_NAME': '홍길동', 'C_A_CONTENTS': '본문'},
      'resultCode': '0000',
    };
    await LocalDbService.upsertReport(
      _report('r-1'),
      'traffic',
      '자동차·교통위반-신호위반',
      rawDetail: _upsertOf(envelope, 'crawl'),
    );
    final db = await LocalDbService.db;
    final row =
        (await db.query(
          'report_detail_raw',
          where: 'ID = ?',
          whereArgs: ['r-1'],
        )).single;
    expect(row['raw_sha256'], prepareRawDetail(envelope).sha256);
    expect(row['source'], 'crawl');
    expect(
      decompressAndVerifyRawDetail(
        row['raw_zlib'] as Uint8List,
        row['raw_sha256'] as String,
      ),
      prepareRawDetail(envelope).canonical,
    );

    // 같은 ID 로 다시 받으면 덮어쓴다.
    await LocalDbService.upsertReport(
      _report('r-1'),
      'traffic',
      '자동차·교통위반-신호위반',
      rawDetail: _upsertOf(envelope, 'rebuild'),
    );
    final again =
        (await db.query(
          'report_detail_raw',
          where: 'ID = ?',
          whereArgs: ['r-1'],
        )).single;
    expect(again['source'], 'rebuild');

    // 원본 없이 저장하면 기존 원본 행을 건드리지 않는다.
    await LocalDbService.upsertReport(
      _report('r-1'),
      'traffic',
      '자동차·교통위반-신호위반',
    );
    expect(
      (await db.query(
        'report_detail_raw',
        where: 'ID = ?',
        whereArgs: ['r-1'],
      )).single['source'],
      'rebuild',
    );
  });

  test('captureAndSaveDetail saves the report, the detail row and the file', () async {
    final detail = _detail()..addAll({
      'C_NAME': '홍길동',
      'C_EMAIL': 'a@b.c',
      'C_PHONE': '01012345678',
      'C_PHONE2': '010-1234-5678',
      'C_ID': 'fixtureid1',
    });
    final cNo = detail['C_NO'].toString();
    final envelope = <String, dynamic>{'result': detail};
    final rawDir = Directory('${dir.path}/raw_details')..createSync();
    final saved = await SyncEngine.captureAndSaveDetail(
      cNo: cNo,
      item: const {},
      detail: detail,
      envelope: envelope,
      rawSource: 'crawl',
      rawFileDir: rawDir,
      trigger: 'realtime',
      tracker: CaptureTracker(),
      communityStore: store,
      retryFile: File('${dir.path}/community_capture_retry.json'),
      projectNamespace: projectNamespace('https://example.supabase.co'),
      captureActive: true,
    );
    expect(saved.saved.isNew, isTrue);

    // 원본 표: 같은 ID, sha 일치, BLOB 해제 대조 통과.
    final row = (await LocalDbService.getDetailRaw(cNo))!;
    expect(row['source'], 'crawl');
    expect(row['raw_sha256'], prepareRawDetail(envelope).sha256);
    expect(
      (row['fetched_at'] as String),
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')),
    );
    final raw = decompressAndVerifyRawDetail(
      row['raw_zlib'] as Uint8List,
      row['raw_sha256'] as String,
    );
    expect(raw.length, row['raw_size']);

    // 원본 파일: 신고자 키 5개가 빠진 들여쓰기 JSON.
    final file = File('${rawDir.path}/$cNo.json');
    expect(file.existsSync(), isTrue);
    final back = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final result = back['result'] as Map<String, dynamic>;
    for (final k in rawDetailReporterKeys) {
      expect(result.containsKey(k), isFalse, reason: k);
    }
  });

  test('removing reports removes their detail rows too', () async {
    final envelope = <String, dynamic>{
      'result': {'C_NO': 21, 'C_NAME': '홍길동'},
      'resultCode': '0000',
    };
    await LocalDbService.upsertReport(
      _report('keep'),
      'traffic',
      '자동차·교통위반-신호위반',
      rawDetail: _upsertOf(envelope, 'crawl'),
    );
    await LocalDbService.upsertReport(
      _report('stale'),
      'traffic',
      '자동차·교통위반-신호위반',
      rawDetail: _upsertOf(envelope, 'crawl'),
    );
    expect(await LocalDbService.removeReportsNotIn({'keep'}), 1);
    final db = await LocalDbService.db;
    expect(
      await db.query('report_detail_raw', where: 'ID = ?', whereArgs: ['keep']),
      hasLength(1),
    );
    expect(
      await db.query(
        'report_detail_raw',
        where: 'ID = ?',
        whereArgs: ['stale'],
      ),
      isEmpty,
    );
    await LocalDbService.clearAll();
    expect(await db.query('report_detail_raw'), isEmpty);
  });
}
