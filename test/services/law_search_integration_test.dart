import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_filter.dart';
import 'package:safetyreport/services/law_values.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr-law-query-');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    final laws = [
      parseViolationLaw(
        '도로교통법 제32조, 제33조, 제34조 위반. 신고된 차량에 대해 과태료부과 처분을 하였습니다.',
      ),
      '도로교통법 제17조제4항\n자동차관리법 제10조',
      '도로교통법 제17조',
      '도로교통법 제170조',
      '도로교통법 제17조의2',
    ];
    for (var i = 0; i < laws.length; i++) {
      final report = Report.fromJson({
        'ID': '${i + 1}',
        '신고번호': 'SYN-${i + 1}',
        '신고명': '합성 법규 검색',
        '신고일': '2026-10-01',
        '답변일': '2026-10-02',
        '처리상태': '수용',
        '상태': '답변완료',
        '범칙금_과태료': '과태료: 40,000원',
        '위반법규': laws[i],
        '처리기관': '합성 기관',
        '담당자': '합성 담당',
        'ssnpc_cd': 'TV',
        'ssnpc_type': '09',
      });
      await LocalDbService.upsertReport(
        report,
        'traffic',
        '자동차·교통위반-기타 자동차 안전기준 위반',
      );
    }
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });
  test(
    'local count and paged list match each citation and hierarchy',
    () async {
      final cases = {
        '도로교통법 제33조': {'1'},
        '제34조': {'1'},
        '도로교통법 제17조': {'2', '3'},
        '도로교통법 제170조': {'4'},
        '도로교통법 제17조의2': {'5'},
        '도로교통법 제32조&도로교통법 제34조': {'1'},
        '도로교통법 제33조,자동차관리법 제10조': {'1', '2'},
      };
      for (final c in cases.entries) {
        final ids = <String>[];
        for (var page = 0; page < c.value.length; page++) {
          final result = await LocalDbService.getReportPage(
            category: 'traffic',
            filter: ReportFilter(law: c.key),
            page: page,
            pageSize: 1,
          );
          expect(result.total, c.value.length, reason: c.key);
          ids.addAll(result.reports.map((r) => r.id));
        }
        expect(ids.toSet(), c.value);
        expect(ids.length, ids.toSet().length);
      }
    },
  );
  test('choices are individual and stats money is unique', () async {
    final options = await LocalDbService.getFilterOptions();
    expect(options.laws, contains('도로교통법 제34조'));
    expect(options.laws.any((s) => s.contains('\n')), false);
    final stats = await LocalDbService.computeStats();
    expect(stats['traffic']['total_fine_amount'], 200000);
    final selected = await LocalDbService.computeStats(law: '도로교통법 제17조');
    expect(selected['traffic']['total_fine_amount'], 80000);
    expect(
      selected['traffic']['available_laws'],
      stats['traffic']['available_laws'],
    );
  });
  test(
    'BOM raw SQLite bytes and empty-law selection survive local paging',
    () async {
      final d = await LocalDbService.db;
      await d.update(
        'reports',
        {'위반법규': '\uFEFF도로교통법 제34조'},
        where: 'ID = ?',
        whereArgs: ['1'],
      );
      await d.update(
        'reports',
        {'위반법규': '\uFEFF'},
        where: 'ID = ?',
        whereArgs: ['2'],
      );
      final found = await LocalDbService.getReportPage(
        filter: const ReportFilter(law: '도로교통법 제34조'),
      );
      expect(found.reports.map((r) => r.id), ['1']);
      final empty = await LocalDbService.getReportPage(
        filter: const ReportFilter(law: '__없음__'),
      );
      expect(empty.reports.map((r) => r.id), ['2']);
    },
  );

  test('raw stored LF value and schema are preserved', () async {
    final db = await LocalDbService.db;
    final version = (await db.rawQuery(
      'PRAGMA user_version',
    )).single.values.single;
    final row = (await db.query(
      'reports',
      where: 'ID=?',
      whereArgs: ['1'],
    )).single;
    expect(readLaws(row['위반법규']), ['도로교통법 제32조', '도로교통법 제33조', '도로교통법 제34조']);
    await LocalDbService.getReportPage(filter: const ReportFilter(law: '제34조'));
    expect(
      (await db.rawQuery('PRAGMA user_version')).single.values.single,
      version,
    );
    expect(
      (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).any((r) => r['name'].toString().contains('law')),
      false,
    );
    await db.update(
      'reports',
      {'위반법규': '도로교통법 제23조'},
      where: 'ID=?',
      whereArgs: ['1'],
    );
    expect(
      (await LocalDbService.getReportPage(
        filter: const ReportFilter(law: '제34조'),
      )).total,
      0,
    );
  });
}
