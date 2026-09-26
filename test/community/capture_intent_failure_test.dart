// Sol 4차 §20-5: capture 의도(retry) 파일을 쓰지 못하면 개인 DB 를 바꾸지 않는다.
// SyncEngine.captureAndSaveDetail 전체 경로를 실제 개인 DB(sqflite ffi)와 실제 community.db 로 실행한다.
// 양성 대조: 같은 입력에 쓸 수 있는 retry 파일을 주면 개인 DB·journal 에 저장된다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/capture_retry_store.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> _detail() {
  final cases = (jsonDecode(File('contracts/parser-vectors.json').readAsStringSync()) as Map)['cases'] as List;
  // 신호위반·별점 없음 → 사진·만족도 조회(네트워크) 경로에 들어가지 않는다.
  return Map<String, dynamic>.from((cases[1] as Map)['detail'] as Map);
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
    dir = Directory.systemTemp.createTempSync('sr_capture_intent_');
    await databaseFactory.setDatabasesPath(dir.path);
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    store = await CommunityStore.open(path: '${dir.path}/community.db', factory: databaseFactoryFfi);
    await store.setContext({
      'contributor_fingerprint': 'fp1',
      'connection_id': '11111111-1111-4111-8111-111111111111',
      'writer_epoch': 3,
      'dataset_key': 'ds1',
      'consent_grant_id': '22222222-2222-4222-8222-222222222222',
      'policy_version': '2026-09-26.1',
      'consent_text_sha256': 'abc',
      'source_app': 'safetyreport-mobile',
      'source_mode': 'standalone',
    });
  });
  tearDown(() async {
    await LocalDbService.closeDb();
    await CommunityStore.closeForTest(store.path);
    dir.deleteSync(recursive: true);
  });

  Future<SavedDetail> run(File retry, Map<String, dynamic> detail) => SyncEngine.captureAndSaveDetail(
        cNo: detail['C_NO'] as String,
        item: const {},
        detail: detail,
        trigger: 'realtime',
        tracker: CaptureTracker(),
        communityStore: store,
        retryFile: retry,
        projectNamespace: projectNamespace('https://example.supabase.co'),
        captureActive: true,
      );

  // capture 는 공유 대상 여부와 무관하게 모든 관측을 detail_status 에 기록한다(처리중은 journal 이벤트 없음).
  Future<int> capturedRows() async =>
      (await store.db.rawQuery('SELECT count(*) AS n FROM detail_status')).first['n'] as int;

  test('intent file cannot be written → CaptureStoreUnavailable, personal DB and community.db unchanged', () async {
    final detail = _detail();
    // 부모 경로가 일반 파일이라 retry 파일을 만들 수 없다.
    final blocker = File('${dir.path}/not-a-dir')..writeAsStringSync('x');
    final retry = File('${blocker.path}/community_capture_retry.json');
    await expectLater(run(retry, detail), throwsA(isA<CaptureStoreUnavailable>()));
    expect(await LocalDbService.getReport(detail['C_NO'] as String), isNull, reason: '개인 저장 보류');
    expect(await capturedRows(), 0, reason: 'capture 도 시작하지 않는다');
  });

  test('positive control: a writable intent file saves the same report and removes the intent', () async {
    final detail = _detail();
    final retry = File('${dir.path}/community_capture_retry.json');
    final saved = await run(retry, detail);
    expect(saved.saved.isNew, isTrue);
    expect(await LocalDbService.getReport(detail['C_NO'] as String), isNotNull);
    expect(await capturedRows(), 1);
    expect(await CaptureRetryStore.captureRetryIds(retry), isEmpty, reason: '저장 성공 뒤 의도 제거');
  });
}
