// 중복차량 그룹핑(normalize_plate SQL 함수) 성능 — 합성 5만 건에서 목록 첫 쪽·전체 그룹 수
// 계산이 인덱스 없이도 허용 범위(1초 안팎)인지 측정한다. 수치는 호스트 전용 참고치이며
// 기기 SLA 를 정하지 않는다(sqlite_contention_test.dart 와 같은 규칙).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/large_data_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_dup_plate_perf_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test(
    '50k건(차량번호 10000종 × 5건, 전부 중복) — 전체 목록·첫 쪽·총 그룹 수가 budget 안',
    () async {
      final db = await LocalDbService.db;
      // large_data_fixture 의 차량번호는 '12가%04d'%(i%10000) — count=50000 이면
      // 10000 개 서로 다른 번호판이 각각 5건씩, 전부 중복(최악 쪽에 가까운 합성 데이터).
      await seedLargeDataFixture(db, 50000);

      final fullTimer = Stopwatch()..start();
      final full = await LocalDbService.getDuplicateVehicleReports();
      fullTimer.stop();
      expect(full.length, 50000);
      // ignore: avoid_print
      print(
        'plate-group budget: 50000-row getDuplicateVehicleReports='
        '${fullTimer.elapsedMilliseconds}ms',
      );
      expect(fullTimer.elapsedMilliseconds, lessThan(5000));

      final firstPageTimer = Stopwatch()..start();
      final firstPage = await LocalDbService.getReportPage(
        scope: 'duplicates',
        page: 0,
        pageSize: 50,
      );
      firstPageTimer.stop();
      expect(firstPage.total, 50000);
      expect(firstPage.reports.length, 50);
      // ignore: avoid_print
      print(
        'plate-group budget: 50000-row first page(total+rows, cold lookup)='
        '${firstPageTimer.elapsedMilliseconds}ms',
      );
      expect(firstPageTimer.elapsedMilliseconds, lessThan(5000));

      // 같은 조건의 다음 쪽은 lookup 캐시를 재사용한다(전체 테이블 재정규화 없음) — 훨씬 빨라야 한다.
      final nextPageTimer = Stopwatch()..start();
      final nextPage = await LocalDbService.getReportPage(
        scope: 'duplicates',
        page: 1,
        pageSize: 50,
      );
      nextPageTimer.stop();
      expect(nextPage.total, 50000);
      // ignore: avoid_print
      print(
        'plate-group budget: 50000-row second page(cached lookup)='
        '${nextPageTimer.elapsedMilliseconds}ms',
      );
      expect(nextPageTimer.elapsedMilliseconds, lessThan(firstPageTimer.elapsedMilliseconds));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
