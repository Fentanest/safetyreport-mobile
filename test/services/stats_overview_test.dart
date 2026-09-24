import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/stats_overview.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 서버 `tests/test_report_stats_service.py::test_overview_summary_uses_valid_samples_and_splits_monthly_bases`
/// 와 같은 입력·기대값. 두 모드가 같은 정의로 집계하는지 확인한다(statistics-spec §4, S-02).
const _parityRows = <Map<String, dynamic>>[
  {'처리상태': '수용', '신고일': '2026-01-30', '답변일': '2026-02-02 10:00:00'},
  {'처리상태': '일부수용', '신고일': '2026-02-10', '답변일': '2026-02-20'},
  {'처리상태': '처리중', '신고일': '2026-02-11', '답변일': ''},
  {'처리상태': '보완요청', '신고일': '2026-02-12', '답변일': null},
  {'처리상태': '기타', '신고일': '2026-03-05', '답변일': '2026-03-01'},
  {'처리상태': '취하', '신고일': '잘못된날짜', '답변일': '2026-03-09'},
  {'처리상태': null, '신고일': null, '답변일': null},
];

Report _report({
  required String id,
  required String status,
  required String date,
  required String responseDate,
  String agency = '서울강서경찰서',
  String fine = '',
}) {
  return Report(
    id: id,
    reportNumber: 'SPP-$id',
    name: '테스트 신고 $id',
    date: date,
    responseDate: responseDate,
    agency: agency,
    manager: '',
    status: status,
    result: status,
    fineInfo: fine,
    penaltyPoints: '',
    carNumber: '',
    law: '도로교통법',
    location: '서울',
    occurrenceDate: date,
    occurrenceTime: '12:00',
    reportContent: '',
    processContent: '',
  );
}

Future<void> _resetDb() async {
  await LocalDbService.closeDb();
  final dbPath = await LocalDbService.getDbPath();
  await deleteDatabase(dbPath);
  for (final ext in ['-wal', '-shm']) {
    final sidecar = File('$dbPath$ext');
    if (sidecar.existsSync()) await sidecar.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('summarizeOverviewRows (서버와 같은 정의)', () {
    test('평균 처리일은 유효 표본만, 월별 신고/답변은 각자 날짜 기준', () {
      final s = LocalDbService.summarizeOverviewRows(_parityRows);

      expect(s['total'], 7);
      expect(s['completed'], 3);
      expect(s['accept'], 1);
      expect(s['partial'], 1);
      expect(s['reject'], 1);
      expect(s['processing'], 1);
      expect(s['supplement'], 1);
      expect(s['withdraw'], 1);
      expect(s['avg_days_count'], 2); // 3일, 10일
      expect(s['avg_days'], 6.5);
      expect(s['reversed_date_count'], 1);
      expect(s['undated_report_count'], 2);
      expect(s['monthly_reported'], [
        {'month': '2026-01', 'count': 1},
        {'month': '2026-02', 'count': 3},
        {'month': '2026-03', 'count': 1},
      ]);
      expect(s['monthly_answered'], [
        {'month': '2026-02', 'count': 2},
        {'month': '2026-03', 'count': 2},
      ]);
    });

    test('빈 입력은 평균 없음(null)과 표본 0', () {
      final s = LocalDbService.summarizeOverviewRows(const []);
      expect(s['total'], 0);
      expect(s['avg_days'], isNull);
      expect(s['avg_days_count'], 0);
      expect(s['monthly_reported'], isEmpty);
    });

    test('존재하지 않는 날짜(2월 30일)는 날짜 없음으로 처리', () {
      final s = LocalDbService.summarizeOverviewRows(const [
        {'처리상태': '수용', '신고일': '2026-02-30', '답변일': '2026-03-02'},
      ]);
      expect(s['undated_report_count'], 1);
      expect(s['avg_days_count'], 0);
    });

    test('모델 파싱이 요약 필드를 그대로 보존', () {
      final summary = OverviewSummary.fromJson(
        LocalDbService.summarizeOverviewRows(_parityRows),
      );
      expect(summary.avgDays, 6.5);
      expect(summary.avgDaysCount, 2);
      expect(summary.monthlyAnswered.map((e) => e.month), [
        '2026-02',
        '2026-03',
      ]);
    });
  });

  group('computeStatsOverview (로컬 DB)', () {
    late Directory tempDbDir;
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // flutter test 는 파일별로 병렬 실행된다. DB 를 쓰는 테스트 파일마다 전용 경로를 써야
      // standalone_reports.db 를 서로 덮어쓰지 않는다(2026-09-24 Gemini 검수 R1 에서 재현).
      await databaseFactory.setDatabasesPath(
        (tempDbDir = Directory.systemTemp.createTempSync('sr_db_test_')).path,
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

    tearDown(_resetDb);

    test(
      '기관표: S-01 음수 제외·소수 1자리, S-03 처리상태 NULL 유지, S-05 금액 미확인, S-08 답변일 연도',
      () async {
        Future<void> add(
          String id,
          String status,
          String date,
          String resp, {
          String fine = '',
        }) async {
          await LocalDbService.upsertReport(
            _report(
              id: id,
              status: status,
              date: date,
              responseDate: resp,
              fine: fine,
            ),
            'traffic',
            '자동차·교통위반',
          );
        }

        await add('a', '수용', '2026-01-01', '2026-01-02', fine: '과태료: 40,000원');
        await add('b', '수용', '2026-01-01', '2026-01-03', fine: '과태료');
        await add('c', '수용', '2026-01-10', '2026-01-05'); // 날짜 역전
        await add('d', '취하', '2026-01-01', '2026-01-02');
        final db = await LocalDbService.db;
        await db.update(
          'reports',
          {'처리상태': null},
          where: 'ID = ?',
          whereArgs: ['c'],
        );

        final raw = await LocalDbService.computeStats(excludeWithdraw: true);
        final row = (raw['traffic']['by_agency'] as List).single as Map;
        expect(row['total'], 3); // d(취하) 제외, c(처리상태 NULL) 유지
        expect(row['avg_days'], 1.5); // 1일, 2일 — 역전 c 제외
        expect(row['total_fine_amount'], 40000);
        expect(row['fine_amount_unknown'], 1);
        expect(raw['available_years'], ['2026']);
      },
    );

    test('카테고리별 합이 전체와 같고, 취하 제외·연도(답변일, S-08) 필터를 따른다', () async {
      await LocalDbService.upsertReport(
        _report(
          id: 't1',
          status: '수용',
          date: '2026-01-10',
          responseDate: '2026-01-20',
        ),
        'traffic',
        '자동차·교통위반',
      );
      await LocalDbService.upsertReport(
        _report(
          id: 't2',
          status: '처리중',
          date: '2026-02-01',
          responseDate: '',
          agency: '',
        ),
        'traffic',
        '자동차·교통위반',
      );
      await LocalDbService.upsertReport(
        _report(
          id: 'p1',
          status: '취하',
          date: '2026-02-03',
          responseDate: '2026-02-04',
        ),
        'parking',
        '불법 주정차',
      );
      await LocalDbService.upsertReport(
        _report(
          id: 'o1',
          status: '불수용',
          date: '2025-12-30',
          responseDate: '2026-01-05',
        ),
        'other',
        '기타',
      );

      final all = StatsOverview.fromJson(
        await LocalDbService.computeStatsOverview(excludeWithdraw: true),
      );
      expect(all.yearBasis, '답변일');
      expect(all.all.total, 3); // 취하 1건 제외
      expect(
        all.traffic.total + all.parking.total + all.other.total,
        all.all.total,
      );
      expect(all.all.withdraw, 0);
      // 처리기관이 비어 있는 미답변 신고도 총 신고에는 포함된다(기관표와 다름).
      expect(all.traffic.total, 2);
      expect(all.all.avgDaysCount, 2); // t1 10일, o1 6일
      expect(all.all.avgDays, 8.0);

      final withWithdraw = StatsOverview.fromJson(
        await LocalDbService.computeStatsOverview(excludeWithdraw: false),
      );
      expect(withWithdraw.all.total, 4);
      expect(withWithdraw.parking.withdraw, 1);

      // S-08: 연도는 답변일 기준 — 2025-12-30 에 신고해 2026-01-05 에 답변된 o1 은 2026 에 속한다.
      final y2025 = StatsOverview.fromJson(
        await LocalDbService.computeStatsOverview(year: '2025'),
      );
      expect(y2025.all.total, 0);

      final y2026 = StatsOverview.fromJson(
        await LocalDbService.computeStatsOverview(year: '2026'),
      );
      expect(y2026.all.total, 3); // t1, p1, o1 (미답변 t2 제외)
      expect(y2026.other.total, 1);
      // 월별 신고는 신고일 기준이라 o1 은 2025-12 에 찍힌다.
      expect(y2026.all.monthlyReported.first.month, '2025-12');
    });
  });
}
