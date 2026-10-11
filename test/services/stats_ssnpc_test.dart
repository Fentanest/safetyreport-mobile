import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/services/local_db_service.dart';

/// Astra #4(2026-10-11): `computeStatsBundle()` 의 실제 SQL 경로가 SSNPC 코드(ssnpc_cd·ssnpc_type)
/// 를 들고 와야 `fine_estimate` 가 EP-03(소방차 전용구역) 같은 세부 규칙을 적용한다. 추정기 단위시험
/// (`fine_estimate_test.dart`)만으로는 `_statsColumns` 가 이 두 열을 빼먹는 회귀를 못 잡는다 —
/// 실제 GROUP BY·SELECT 파이프라인까지 통해서 확인한다.
void main() {
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_stats_ssnpc_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  setUp(() async {
    final db = await LocalDbService.db;
    await db.delete('reports');
  });

  Future<void> insertParkingReport(
    String id, {
    String? ssnpcCd,
    String? ssnpcType,
  }) async {
    final db = await LocalDbService.db;
    await db.insert('reports', {
      'ID': id,
      '신고번호': 'SPP-$id',
      'category': 'parking',
      '처리상태': '수용',
      '범칙금_과태료': '과태료', // 금액 없는 과태료 — fine_estimate 추정 대상(§4-1).
      '신고일': '2026-09-01',
      '답변일': '2026-09-10',
      '처리기관': '예시 시청 주차관리과',
      '담당자': '김담당',
      '차량번호': '12가3456', // 승용
      'entry_value': '',
      'ssnpc_cd': ssnpcCd,
      'ssnpc_type': ssnpcType,
    });
  }

  test('EP-03(소방차 전용구역)은 일반 주정차 4만원이 아니라 50만원으로 추정한다', () async {
    await insertParkingReport('sr-ssnpc-ep03', ssnpcCd: 'EP', ssnpcType: '03');

    final bundle = await LocalDbService.computeStatsBundle();
    final category = (bundle['stats'] as Map)['parking'] as Map;

    expect(category['estimated_fine_amount'], 500000);
    expect(category['estimated_fine_count'], 1);
  });

  test('코드만 다른 두 신고는 한 그룹으로 합쳐지지 않고 각자의 금액으로 추정된다', () async {
    // 두 행은 ssnpc_cd·ssnpc_type 만 다르고 나머지 열은 전부 같다. 통계 SELECT·GROUP BY 가 이
    // 두 열을 빼먹으면(Astra #4 전) 한 그룹(weight=2)으로 합쳐져 50만+4만=54만이 나올 수 없다 —
    // 둘 중 하나의 금액만 2배가 되거나(100만/8만) 코드가 사라져 추정이 아예 안 된다.
    await insertParkingReport('sr-ssnpc-a', ssnpcCd: 'EP', ssnpcType: '03'); // fire_lane 500,000
    await insertParkingReport('sr-ssnpc-b', ssnpcCd: 'EP', ssnpcType: '02'); // parking 40,000(승용)

    final bundle = await LocalDbService.computeStatsBundle();
    final category = (bundle['stats'] as Map)['parking'] as Map;

    expect(category['estimated_fine_amount'], 500000 + 40000);
    expect(category['estimated_fine_count'], 2);
  });
}
