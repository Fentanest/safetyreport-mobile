import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../models/report.dart';
import '../models/report_sort.dart';
import 'client_report_scan.dart';
import 'sqlite_connection.dart';
import 'performance_trace.dart';

Future<void> createReportSortTable(
  DatabaseExecutor d,
  String table, {
  bool temporary = false,
  bool payload = false,
}) => d.execute(
  'CREATE ${temporary ? 'TEMP' : ''} TABLE IF NOT EXISTS $table('
  'sort_id TEXT PRIMARY KEY,report_no TEXT,fine INTEGER,rating INTEGER,supplement INTEGER,'
  'report_date TEXT,occurrence_date TEXT,response_date TEXT${payload ? ', payload TEXT NOT NULL' : ''})',
);
Future<void> indexReportSortTable(
  DatabaseExecutor d,
  String table, {
  bool temporary = false,
}) async {
  for (final field in ReportSortField.values.where(
    (f) => f != ReportSortField.duplicateCount,
  )) {
    final col = field.column;
    await d.execute(
      'CREATE INDEX IF NOT EXISTS ${temporary ? 'temp.' : ''}${table}_$col '
      'ON $table(($col IS NULL), $col,report_no DESC,sort_id DESC)',
    );
  }
}

/// 서버 API 계약을 바꾸지 않고 모든 페이지를 받아 SQLite에서 정렬한다.
/// 쿼리별 임시 DB이며 한 번에 서버 한 페이지의 Report만 보유한다.
class ClientSortedReports {
  ClientSortedReports._(this.db);
  final Database db;
  static Future<ClientSortedReports> build({
    required ReportPageReader read,
    required List<String> categories,
    required bool Function(Report) matches,
    required bool Function() isCancelled,
  }) async {
    final db = await openAppDatabase(
      inMemoryDatabasePath,
      singleInstance: false,
    );
    try {
      await createReportSortTable(db, 'sorted_reports', payload: true);
      for (final category in categories) {
        var offset = 0;
        while (true) {
          if (isCancelled()) throw const QueryCancelled();
          final page = await read(
            category,
            offset: offset,
            limit: 200,
            isCancelled: isCancelled,
          );
          if (isCancelled()) throw const QueryCancelled();
          final batch = db.batch();
          for (final report in page.reports.where(matches)) {
            final row = reportCardRow(report);
            batch.insert('sorted_reports', {
              ...reportSortValues(row),
              'payload': jsonEncode(row),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await batch.commit(noResult: true);
          offset += page.reports.length;
          if (page.reports.isEmpty || offset >= page.total) break;
        }
      }
      await indexReportSortTable(db, 'sorted_reports');
      return ClientSortedReports._(db);
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<ReportPage> page(ReportSort sort, int page, {int size = 200}) async {
    final total = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM sorted_reports'),
    )!;
    final rows = await db.rawQuery(
      'SELECT payload FROM sorted_reports '
      'ORDER BY ${sort.orderBy(sort.field.column, fallback: 'report_no DESC,sort_id DESC')} LIMIT ? OFFSET ?',
      [size, page * size],
    );
    return (
      reports: rows
          .map((r) => Report.fromJson(jsonDecode(r['payload'] as String)))
          .toList(),
      total: total,
    );
  }

  Future<void> close() => db.close();
}
