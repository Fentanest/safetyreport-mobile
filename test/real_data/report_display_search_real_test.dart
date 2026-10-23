import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, listEquals, setEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_filter.dart';
import 'package:safetyreport/models/report_sort.dart';
import 'package:safetyreport/services/client_report_scan.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/services/report_display_search.dart';
import 'package:safetyreport/services/report_filter_spec.dart';
import 'package:safetyreport/services/report_sort_store.dart';
import 'package:safetyreport/utils/report_display_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _sources = [
  (Platform.environment['SR_TEXT_MOBILE_DB'] ?? '', 'reports'),
  (Platform.environment['SR_TEXT_SERVER_DB'] ?? '', 'mysafety_report'),
];
const _fields = ['신고명', '신고내용', '처리내용', '별점사유'];
ReportFilter _filter(String field, String query) => switch (field) {
  '신고명' => ReportFilter(name: query),
  '신고내용' => ReportFilter(reportContent: query),
  '처리내용' => ReportFilter(processContent: query),
  _ => ReportFilter(ratingCause: query),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  for (final source in _sources) {
    test('실제 ${source.$2}: 원문·표시 검색 최종집합과 TEMP/Client 페이징', () async {
      if (source.$1.isEmpty || !File(source.$1).existsSync()) {
        markTestSkipped('읽기 전용 실제 DB가 필요합니다.');
        return;
      }
      final db = await databaseFactory.openDatabase(
        source.$1,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      addTearDown(db.close);
      final rows = await db.rawQuery(
        'SELECT * FROM "${source.$2}" ORDER BY 신고번호 DESC,ID DESC',
      );
      var checkedLines = 0;
      for (final row in rows) {
        final report = Report.fromJson(Map<String, dynamic>.from(row));
        for (final field in _fields) {
          final raw = row[field]?.toString() ?? '';
          for (final line in raw.split(RegExp(r'\r\n|\r|\n'))) {
            final shown = reportDisplayText(line);
            if (shown == line || !ReportDisplaySearch.needsDisplayMatch(shown)) {
              continue;
            }
            final search = ReportDisplaySearch(_filter(field, shown));
            expect(search.matchesValues(row), isTrue);
            expect(search.matchesReport(report), isTrue);
            checkedLines++;
          }
          if (field == '신고명') {
            final shown = reportTitlePreview(raw);
            final search = ReportDisplaySearch(_filter(field, shown));
            if (search.isActive) expect(search.matchesValues(row), isTrue);
          }
        }
      }
      expect(checkedLines, greaterThan(0));

      // 실제 값에 있던 따옴표 한 글자를 사용해 200건 경계를 넘는 결과도 검사한다.
      final shownBody = rows
          .map((r) => reportDisplayText(r['처리내용']?.toString() ?? ''))
          .firstWhere((s) => s.contains('"'));
      final query = shownBody.substring(
        shownBody.indexOf('"'),
        shownBody.indexOf('"') + 1,
      );
      final search = ReportDisplaySearch(ReportFilter(processContent: query));
      final expected = rows.where((row) {
        final raw = row['처리내용']?.toString() ?? '';
        return ReportFilterSpec.matchesText(raw, query) ||
            ReportFilterSpec.matchesText(reportDisplayText(raw), query);
      }).toList();
      var readRows = 0, maxPage = 0;
      final watch = Stopwatch()..start();
      final total = await rebuildDisplaySearchMatches(
        db,
        search,
        sourceTable: source.$2,
        isCancelled: () => false,
        onPage: (n) {
          readRows += n;
          if (n > maxPage) maxPage = n;
        },
      );
      watch.stop();
      final matched = await db.rawQuery(
        'SELECT id FROM temp.sr_display_search_match',
      );
      expect(total, expected.length);
      expect(readRows, rows.length);
      expect(maxPage, lessThanOrEqualTo(200));
      expect(
        setEquals(
          matched.map((r) => r['id']).toSet(),
          expected.map((r) => r['ID']).toSet(),
        ),
        isTrue,
      );
      final columns = await db.rawQuery(
        'PRAGMA temp.table_info(sr_display_search_match)',
      );
      expect(columns.map((r) => r['name']).toList(), ['id']);
      final pagedIds = <Object?>[];
      for (var offset = 0; offset < total; offset += 200) {
        final page = await db.rawQuery(
          'SELECT r.ID FROM "${source.$2}" r '
          'WHERE EXISTS(SELECT 1 FROM temp.sr_display_search_match m WHERE m.id=r.ID) '
          'ORDER BY r.신고번호 DESC,r.ID DESC LIMIT 200 OFFSET ?',
          [offset],
        );
        pagedIds.addAll(page.map((r) => r['ID']));
      }
      expect(
        listEquals(pagedIds, expected.map((r) => r['ID']).toList()),
        isTrue,
      );

      var cancel = false, cancellationPages = 0;
      await expectLater(
        rebuildDisplaySearchMatches(
          db,
          search,
          sourceTable: source.$2,
          isCancelled: () => cancel,
          onPage: (_) => cancel = ++cancellationPages == 2,
        ),
        throwsA(isA<QueryCancelled>()),
      );
      // 취소된 ID 표에 기대지 않고 다른 실제 질의를 처음부터 만든다.
      final nextText = rows
          .map((r) => reportDisplayText(r['처리내용']?.toString() ?? ''))
          .firstWhere((s) => s.contains("'"));
      final nextQuery = nextText.substring(
        nextText.indexOf("'"),
        nextText.indexOf("'") + 1,
      );
      final next = ReportDisplaySearch(ReportFilter(processContent: nextQuery));
      final nextCount = await rebuildDisplaySearchMatches(
        db,
        next,
        sourceTable: source.$2,
        isCancelled: () => false,
      );
      expect(nextCount, rows.where(next.matchesValues).length);
      final nextIds = await db.rawQuery(
        'SELECT id FROM temp.sr_display_search_match',
      );
      expect(
        setEquals(
          nextIds.map((r) => r['id']).toSet(),
          rows.where(next.matchesValues).map((r) => r['ID']).toSet(),
        ),
        isTrue,
      );

      Future<ReportPage> read(
        String category, {
        int offset = 0,
        int limit = 200,
        bool Function()? isCancelled,
      }) async {
        final page = await db.rawQuery(
          'SELECT * FROM "${source.$2}" WHERE category=? '
          'ORDER BY 신고번호 DESC,ID DESC LIMIT ? OFFSET ?',
          [category, limit, offset],
        );
        final count = await db.rawQuery(
          'SELECT COUNT(*) AS n FROM "${source.$2}" WHERE category=?',
          [category],
        );
        return (
          reports: page
              .map((r) => Report.fromJson(Map<String, dynamic>.from(r)))
              .toList(),
          total: count.single['n'] as int,
        );
      }

      final categories = (await db.rawQuery(
        'SELECT DISTINCT category FROM "${source.$2}" WHERE category IS NOT NULL',
      )).map((r) => r['category'] as String).toList();
      final scan = await scanClientReports(
        read: read,
        categories: categories,
        matches: search.matchesReport,
        isCancelled: () => false,
        offset: 0,
      );
      expect(scan.total, expected.length);
      expect(
        listEquals(
          scan.reports.map((r) => r.id).toList(),
          expected.take(400).map((r) => r['ID']).toList(),
        ),
        isTrue,
      );
      final snapshot = await ClientSortedReports.build(
        read: read,
        categories: categories,
        matches: search.matchesReport,
        isCancelled: () => false,
      );
      try {
        const sort = ReportSort(
          field: ReportSortField.reportDate,
          ascending: true,
        );
        final first = await snapshot.page(sort, 0);
        final expectedSorted = [...expected]
          ..sort((a, b) {
            final date = (a['신고일'] as String).compareTo(b['신고일'] as String);
            if (date != 0) return date;
            final number = (b['신고번호'] as String).compareTo(a['신고번호'] as String);
            return number != 0
                ? number
                : (b['ID'] as String).compareTo(a['ID'] as String);
          });
        expect(first.total, expected.length);
        expect(
          listEquals(
            first.reports.map((r) => r.id).toList(),
            expectedSorted.take(200).map((r) => r['ID']).toList(),
          ),
          isTrue,
        );
      } finally {
        await snapshot.close();
      }
      // 값/ID 없이 건수·페이지 상한·소요 시간만 남긴다.
      debugPrint(
        'REAL_DISPLAY_SEARCH ${source.$2} rows=${rows.length} checkedLines=$checkedLines matches=$total maxPage=$maxPage scanMs=${watch.elapsedMilliseconds}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
