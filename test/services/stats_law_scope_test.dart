// 통계 법규 선택지 범위 — 서버 tests/test_stats_law_scope.py 와 같은 규칙(2026-09-25 계산 동등성 검사).
// available_laws 는 연도·취하 제외·대표건을 적용한 뒤, 법규 필터는 빼고 만든다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _r(String id, String law, String answered, {String status = '수용'}) =>
    Report(
      id: id,
      reportNumber: 'SPP-$id',
      name: '신호위반',
      date: answered,
      responseDate: answered,
      agency: '서울특별시 강서경찰서 교통과',
      manager: '담당',
      status: status,
      result: status,
      fineInfo: '',
      penaltyPoints: '',
      carNumber: '',
      law: law,
      location: '',
      occurrenceDate: '',
      occurrenceTime: '',
      reportContent: '',
      processContent: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_law_scope_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    const ev = '자동차·교통위반-신호위반';
    await LocalDbService.upsertReport(
      _r('1', '법A', '2025-03-01'),
      'traffic',
      ev,
    );
    await LocalDbService.upsertReport(
      _r('2', '법B', '2026-02-01'),
      'traffic',
      ev,
    );
    await LocalDbService.upsertReport(
      _r('3', '법C', '2026-02-02', status: '취하'),
      'traffic',
      ev,
    );
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  List<String> laws(Map<String, dynamic> stats) =>
      (stats['traffic']['available_laws'] as List).cast<String>();

  test('year and withdraw filters narrow the law choices', () async {
    expect(laws(await LocalDbService.computeStats()), ['법A', '법B', '법C']);
    expect(laws(await LocalDbService.computeStats(year: '2026')), ['법B', '법C']);
    expect(
      laws(
        await LocalDbService.computeStats(year: '2026', excludeWithdraw: true),
      ),
      ['법B'],
    );
  });

  test('law filter keeps the choices', () async {
    expect(laws(await LocalDbService.computeStats(law: '법A')), [
      '법A',
      '법B',
      '법C',
    ]);
  });
}
