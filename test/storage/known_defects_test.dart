// 저장 계층의 알려진 결함을 '현재 동작'으로 고정한다 (저장 계층 재설계 R0, 서버 레포 docs/plans/storage-refactor-plan.md §2-2).
// 각 테스트는 지금의 잘못된 동작을 확인한다. 해당 단계(R3 등)에서 고치면 실패한다 — 그때 기대값을 올바른 동작으로 뒤집고
// 이름의 'currently' 를 떼어 회귀 테스트로 바꾼다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report({
  String id = 'k-1',
  String reportNumber = 'SPP-2609-0000100',
  String processContent = '사이트 처리내용',
  String pollStatus = '참여 가능',
  int? rating,
  String ratingCause = '',
}) =>
    Report(
      id: id,
      reportNumber: reportNumber,
      name: '신호위반',
      date: '2026-09-01',
      responseDate: '2026-09-10',
      agency: '서울특별시 강서경찰서 교통과',
      manager: '김담당',
      status: '수용',
      result: '수용',
      fineInfo: '과태료',
      penaltyPoints: '',
      carNumber: '12가3456',
      law: '도로교통법 제5조',
      location: '서울특별시 강서구 마곡동 1',
      occurrenceDate: '2026-09-01',
      occurrenceTime: '08:00',
      reportContent: '신고 내용',
      processContent: processContent,
      pollStatus: pollStatus,
      rating: rating,
      ratingCause: ratingCause,
    );

Future<Map<String, Object?>> _row(String id) async =>
    (await (await LocalDbService.db).query('reports', where: 'ID = ?', whereArgs: [id])).single;

Future<void> _reset() async {
  await LocalDbService.closeDb();
  final path = await LocalDbService.getDbPath();
  await deleteDatabase(path);
  for (final ext in ['-wal', '-shm']) {
    final f = File('$path$ext');
    if (f.existsSync()) await f.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_known_defects_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _reset();
  });
  tearDownAll(() async {
    await _reset();
    dir.deleteSync(recursive: true);
  });

  const entry = '자동차·교통위반-신호위반';

  test('M-2/M-3 (R3, 결정 D-2): currently a refetch without satisfaction data wipes stored rating and cause', () async {
    await LocalDbService.upsertReport(_report(pollStatus: '참여 완료', rating: 2, ratingCause: '답변이 늦음'), 'traffic', entry);
    // 재조회에서 만족도 조회가 실패하면 파서는 별점 null, 사유 '' 를 만든다.
    await LocalDbService.upsertReport(_report(pollStatus: '참여 가능'), 'traffic', entry);
    final row = await _row('k-1');
    expect(row['별점'], isNull);
    expect(row['별점사유'], '');
    expect(row['만족도조사여부'], '참여 가능');
  });

  test('M-12 (R3, 결정 D-1): currently a refetch reverts a manual edit', () async {
    await LocalDbService.upsertReport(_report(), 'traffic', entry);
    await LocalDbService.updateEditableRecord('k-1', {'처리내용': '내가 고친 처리내용'});
    expect((await _row('k-1'))['처리내용'], '내가 고친 처리내용');
    await LocalDbService.upsertReport(_report(), 'traffic', entry);
    expect((await _row('k-1'))['처리내용'], '사이트 처리내용');
  });

  test('M-1 (R3, 결정 D-6): currently clearAll (used by full resync) drops watchlist and geocode cache', () async {
    await LocalDbService.upsertReport(_report(), 'traffic', entry);
    await LocalDbService.setWatchlistNumbers({'SPP-2609-0000100'});
    final d = await LocalDbService.db;
    await d.insert('geocode_cache', {'주소정규화': '서울특별시 강서구 마곡동 1', '상태': 'ok', 'source': 'kakao', '위도': 37.5, '경도': 126.8});
    await LocalDbService.clearAll();
    expect(await LocalDbService.getWatchlistNumbers(), isEmpty);
    expect(await (await LocalDbService.db).query('geocode_cache'), isEmpty);
  });

  test('M-24 (R3, 결정 D-7): currently the demo seed replaces the real reports', () async {
    await LocalDbService.upsertReport(_report(), 'traffic', entry);
    await LocalDbService.seedPlayReviewDemo();
    final ids = (await (await LocalDbService.db).query('reports', columns: ['ID'])).map((r) => r['ID']).toSet();
    expect(ids.contains('k-1'), isFalse);
    expect(ids, isNotEmpty);
  });
}
