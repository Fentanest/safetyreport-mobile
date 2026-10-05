import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/client_report_scan.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/services/report_query.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'full Client date/detail search equals SQL beyond first 200 rows',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE reports(ID TEXT, 신고번호 TEXT, 신고일 TEXT, 처리내용 TEXT)',
      );
      final rows = <Report>[];
      for (var i = 0; i < 850; i++) {
        final row = {
          'ID': '$i',
          '신고번호': 'SPP-${(1000 - i).toString().padLeft(4, '0')}',
          '신고일': i < 220 ? '2026-08-01' : '2026-09-01 12:00:00',
          '처리내용': i.isEven ? '과태료 확인' : '경고',
        };
        await db.insert('reports', row);
        rows.add(Report.fromJson(row));
      }
      const filter = ReportFilter(
        reportDateStart: '2026-09-01',
        processContent: '과태료&확인',
      );
      final q = ReportQuery(filter, agencyExpression: '처리기관');
      final expected = await db.rawQuery(
        'SELECT ID FROM reports WHERE ${q.where} ORDER BY 신고번호 DESC, ID DESC',
        q.args,
      );
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      var reads = 0;
      Future<ReportPage> read(
        String category, {
        int offset = 0,
        int limit = 200,
        bool Function()? isCancelled,
      }) async {
        reads++;
        return (
          reports: rows.skip(offset).take(limit).toList(),
          total: rows.length,
        );
      }

      final result = await scanClientReports(
        read: read,
        categories: ['traffic'],
        matches: (r) => provider.matchesFilter(r, filter: filter),
        isCancelled: () => false,
        offset: 0,
      );
      expect(reads, 5);
      expect(result.total, expected.length);
      expect(result.reports.map((r) => r.id), expected.map((r) => r['ID']));
      expect(result.total, 315);
    },
  );

  test(
    'category merge has global order, exact count and bounded window',
    () async {
      Future<ReportPage> read(
        String category, {
        int offset = 0,
        int limit = 200,
        bool Function()? isCancelled,
      }) async {
        final shift = ['traffic', 'parking', 'other'].indexOf(category);
        final rows = List.generate(
          900,
          (i) => Report.fromJson({
            'ID': '$category-$i',
            '신고번호': (3000 - i * 3 - shift).toString().padLeft(4, '0'),
          }),
        );
        return (
          reports: rows.skip(offset).take(limit).toList(),
          total: rows.length,
        );
      }

      final result = await scanClientReports(
        read: read,
        categories: ['traffic', 'parking', 'other'],
        matches: (_) => true,
        isCancelled: () => false,
        offset: 200,
      );
      expect(result.total, 2700);
      expect(result.reports.length, 400);
      expect(result.reports.first.reportNumber, '2800');
      expect(result.reports.last.reportNumber, '2401');
    },
  );

  test('invalidated scan stops and never returns partial totals', () async {
    var cancelled = false;
    Future<ReportPage> read(
      String category, {
      int offset = 0,
      int limit = 200,
      bool Function()? isCancelled,
    }) async {
      cancelled = true;
      return (reports: <Report>[], total: 1000);
    }

    await expectLater(
      scanClientReports(
        read: read,
        categories: ['traffic'],
        matches: (_) => true,
        isCancelled: () => cancelled,
        offset: 0,
      ),
      throwsA(isA<QueryCancelled>()),
    );
  });
}
