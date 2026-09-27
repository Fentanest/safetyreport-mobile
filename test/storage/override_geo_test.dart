// 개인 주소 수정은 공식 신고 원본 좌표를 바꾸지 않는다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report() => Report(
  id: 'g-1',
  reportNumber: 'SPP-2609-0000500',
  name: '불법주정차',
  date: '2026-09-01',
  responseDate: '2026-09-10',
  agency: '강서구청',
  manager: '담당',
  status: '수용',
  result: '수용',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '',
  location: '서울특별시 강서구 마곡동 1',
  latitude: 37.56,
  longitude: 126.83,
  occurrenceDate: '2026-09-01',
  occurrenceTime: '08:00',
  reportContent: '본문',
  processContent: '처리',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_override_geo_test_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  test('edited address and old Kakao cache cannot move official coordinates', () async {
    await LocalDbService.upsertReport(
      _report(), 'parking', '불법주정차신고-기타 불법주정차',
    );
    final d = await LocalDbService.db;
    await d.insert('geocode_cache', {
      '주소정규화': '서울특별시 중구 세종대로 110',
      '위도': 37.5663,
      '경도': 126.9779,
      '상태': 'ok',
      'source': 'kakao',
    });
    await LocalDbService.updateEditableRecord('g-1', {
      '위반장소': '서울특별시 중구 세종대로 110',
    });
    final shown = (await d.query(
      LocalDbService.effectiveReportsView,
      where: 'ID = ?',
      whereArgs: ['g-1'],
    )).single;
    expect(shown['위반장소'], '서울특별시 중구 세종대로 110');
    expect((shown['위도'], shown['경도'], shown['지오코딩상태']),
        (37.56, 126.83, 'ok'));
    final original = (await d.query('reports', where: 'ID = ?', whereArgs: ['g-1'])).single;
    expect(original['위반장소'], '서울특별시 강서구 마곡동 1');
  });
}
