// 사용자가 고친 주소의 좌표 (저장 계층 재설계 R6, 서버 S-4 와 같은 규칙).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/local_geocode_service.dart';
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
  occurrenceDate: '2026-09-01',
  occurrenceTime: '08:00',
  reportContent: '본문',
  processContent: '처리',
);

Future<Map<String, Object?>> _shown() async =>
    (await (await LocalDbService.db).query(
      LocalDbService.effectiveReportsView,
      where: 'ID = ?',
      whereArgs: ['g-1'],
    )).single;

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

  test(
    'an edited address takes coordinates from the cache, the site row keeps its own',
    () async {
      await LocalDbService.upsertReport(
        _report(),
        'parking',
        '불법주정차신고-기타 불법주정차',
      );
      final d = await LocalDbService.db;
      await d.update(
        'reports',
        {'위도': 37.56, '경도': 126.83, '지오코딩상태': 'ok', '주소정규화': '서울특별시 강서구 마곡동 1'},
        where: 'ID = ?',
        whereArgs: ['g-1'],
      );
      final pendingBefore = await LocalGeocodeService.countPendingReports();

      await LocalDbService.updateEditableRecord('g-1', {
        '위반장소': '  서울특별시 중구   세종대로 110 ',
      });
      var shown = await _shown();
      expect(
        (shown['주소정규화'], shown['위도'], shown['지오코딩상태']),
        ('서울특별시 중구 세종대로 110', null, 'pending'),
      );
      expect(
        await LocalGeocodeService.countPendingReports(),
        pendingBefore + 1,
      );

      await d.insert('geocode_cache', {
        '주소정규화': '서울특별시 중구 세종대로 110',
        '행정구역': '서울특별시 중구',
        '위도': 37.5663,
        '경도': 126.9779,
        '상태': 'ok',
        'source': 'kakao',
      });
      shown = await _shown();
      expect(
        (shown['위도'], shown['경도'], shown['행정구역'], shown['지오코딩상태']),
        (37.5663, 126.9779, '서울특별시 중구', 'ok'),
      );
      expect(await LocalGeocodeService.countPendingReports(), pendingBefore);
      final site = (await d.query(
        'reports',
        where: 'ID = ?',
        whereArgs: ['g-1'],
      )).single;
      expect((site['위도'], site['위반장소']), (37.56, '서울특별시 강서구 마곡동 1'));

      // 되돌리면 원본 좌표로
      await LocalDbService.updateEditableRecord('g-1', {
        '위반장소': '서울특별시 강서구 마곡동 1',
      });
      expect((await _shown())['위도'], 37.56);
    },
  );
}
