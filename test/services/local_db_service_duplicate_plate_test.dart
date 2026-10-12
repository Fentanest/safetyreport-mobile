// 중복차량(Standalone) — 2026-10-12: 번호판을 정규화한 값으로 묶는다(PC get_duplicate_records 와
// 같은 결과). LocalDbService.getDuplicateVehicleReports/getReportPage(scope:'duplicates') 양쪽
// 모두 확인한다 — 둘 다 lib/services/local_db_service.dart 의 같은 SQL 개념을 쓴다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/plate_group_sql.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _resetDb() async {
  await LocalDbService.closeDb();
  final dbPath = await LocalDbService.getDbPath();
  await deleteDatabase(dbPath);
  for (final ext in ['-wal', '-shm']) {
    final sidecar = File('$dbPath$ext');
    if (sidecar.existsSync()) await sidecar.delete();
  }
}

Future<void> _insert(
  String id,
  String? reportNumber,
  String carNumber, {
  String status = '처리중',
}) async {
  final db = await LocalDbService.db;
  await db.insert('reports', {
    'ID': id,
    '신고번호': reportNumber,
    'category': 'traffic',
    '처리상태': status,
    '차량번호': carNumber,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(
      (tempDbDir = Directory.systemTemp.createTempSync(
        'sr_dup_plate_test_',
      )).path,
    );
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _resetDb();
  });
  tearDown(() async {
    await _resetDb();
  });

  /// 세 그룹을 심는다 — 그룹마다 표기가 달라도(군더더기·공백·하이픈·같은 미인식 원문) 정규화
  /// 키로 묶인다. 신고번호는 그룹별 MAX 가 서로 달라(C>B>A) 정렬도 같이 확인한다.
  /// - C(5건, 키 '99가1234'): '99가1234', '99가1234)', '99가-1234', '99가 1234', '99가1234'
  /// - B(2건, 키 '미인식'): 같은 미인식 원문 두 건 — 정규화 실패해도 원문이 같아 한 그룹
  /// - A(3건, 키 '177도7967'): '177도7967)' 와 '177도7967'(두 번) — 군더더기 ')' 차이만
  /// 그 외: '중앙선침범'(미인식, 한 건뿐) · '12가9999'(정상 인식, 한 건뿐) — 둘 다 1건이라 제외.
  Future<void> seedThreeGroups() async {
    await _insert('C1', 'C-001', '99가1234');
    await _insert('C2', 'C-002', '99가1234)');
    await _insert('C3', 'C-003', '99가-1234');
    await _insert('C4', 'C-004', '99가 1234');
    await _insert('C5', 'C-005', '99가1234');
    await _insert('B1', 'B-001', '미인식');
    await _insert('B2', 'B-002', '미인식');
    await _insert('A1', 'A-001', '177도7967)');
    await _insert('A2', 'A-002', '177도7967');
    await _insert('A3', 'A-003', '177도7967');
    await _insert('S1', 'S-001', '중앙선침범');
    await _insert('S2', 'S-002', '12가9999');
  }

  test('NULL 신고번호 중복군도 두 조회에서 보존한다', () async {
    await _insert('N1', null, '12가3456');
    await _insert('N2', null, '12가3456)');
    final page = await LocalDbService.getReportPage(scope: 'duplicates');
    expect(page.total, 2);
    expect(page.reports.map((r) => r.id).toSet(), {'N1', 'N2'});
    expect((await LocalDbService.getDuplicateVehicleReports()).length, 2);
  });

  test('중복차량 두 조회는 호출 isolate에 SQLite 연결을 열지 않는다', () async {
    await seedThreeGroups();
    await LocalDbService.getReportPage(scope: 'duplicates');
    expect(PlateGroupSql.openConnectionCountForTest, 0);
    await LocalDbService.getDuplicateVehicleReports();
    expect(PlateGroupSql.openConnectionCountForTest, 0);
  });

  const expectedOrder = [
    'C-005',
    'C-004',
    'C-003',
    'C-002',
    'C-001',
    'B-002',
    'B-001',
    'A-003',
    'A-002',
    'A-001',
  ];

  test(
    'getDuplicateVehicleReports: 표기가 달라도 정규화 키로 묶이고, 다른 미인식 값은 섞이지 않는다',
    () async {
      await seedThreeGroups();
      final reports = await LocalDbService.getDuplicateVehicleReports();

      expect(
        reports.map((r) => r.reportNumber).toList(),
        expectedOrder,
        reason: '그룹 최근신고번호 DESC → 그룹 내 신고번호 DESC',
      );
      // 한 건뿐인 차량(S1·S2)은 중복이 아니므로 결과에 없다.
      expect(reports.any((r) => r.reportNumber.startsWith('S-')), isFalse);

      final byReportNumber = {for (final r in reports) r.reportNumber: r};
      for (final num in ['C-001', 'C-002', 'C-003', 'C-004', 'C-005']) {
        expect(byReportNumber[num]!.totalCount, 5, reason: num);
        expect(byReportNumber[num]!.validCount, 5, reason: num);
      }
      for (final num in ['B-001', 'B-002']) {
        expect(byReportNumber[num]!.totalCount, 2, reason: num);
      }
      for (final num in ['A-001', 'A-002', 'A-003']) {
        expect(byReportNumber[num]!.totalCount, 3, reason: num);
      }

      // 원문 불변: 화면에 보이는 차량번호 열은 각 신고의 원문 그대로다.
      expect(byReportNumber['C-002']!.carNumber, '99가1234)');
      expect(byReportNumber['C-003']!.carNumber, '99가-1234');
      expect(byReportNumber['B-001']!.carNumber, '미인식');
    },
  );

  test(
    'getReportPage(scope: duplicates): 쪽 경계 없이 전체를 모으면 '
    'getDuplicateVehicleReports 와 같은 집합·순서',
    () async {
      await seedThreeGroups();
      const pageSize = 3;
      final collected = <Report>[];
      var page = 0;
      while (true) {
        final result = await LocalDbService.getReportPage(
          scope: 'duplicates',
          page: page,
          pageSize: pageSize,
        );
        expect(result.total, 10);
        collected.addAll(result.reports);
        if (result.reports.length < pageSize) break;
        page++;
        expect(page, lessThan(10), reason: '무한루프 방지');
      }
      expect(collected.length, 10, reason: '쪽 경계에서 누락·중복 없음');
      expect(collected.map((r) => r.reportNumber).toList(), expectedOrder);
    },
  );

  test('excludeWithdraw: 취하 뒤 1건만 남는 차량은 중복 목록에서 빠진다', () async {
    await _insert('W1', 'W-001', '88나1111', status: '취하');
    await _insert('W2', 'W-002', '88나1111');
    final all = await LocalDbService.getDuplicateVehicleReports();
    expect(all.map((r) => r.reportNumber), containsAll(['W-001', 'W-002']));

    final activeOnly = await LocalDbService.getDuplicateVehicleReports(
      excludeWithdraw: true,
    );
    expect(activeOnly.any((r) => r.reportNumber == 'W-001'), isFalse);
    expect(activeOnly.any((r) => r.reportNumber == 'W-002'), isFalse);
  });

  test(
    '일반 sqflite 연결에는 normalize_plate 가 없다 — 조용히 틀리지 않고 분명한 오류',
    () async {
      await _insert('E1', 'E-001', '12가3456');
      final db = await LocalDbService.db;
      await expectLater(
        db.rawQuery('SELECT normalize_plate(차량번호) FROM reports'),
        throwsA(
          predicate(
            (Object e) => e.toString().contains('no such function'),
          ),
        ),
      );
    },
  );
}
