import 'package:safetyreport/models/report_filter.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_sort.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/report_sort_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  setUp(() async {
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('sort-252-');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await LocalDbService.closeDb();
    await dir.delete(recursive: true);
  });
  Future<void> seed(List<Map<String, Object?>> rows) async {
    final db = await LocalDbService.db;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('reports', {'category': 'traffic', '처리상태': '불수용', ...row});
    }
    await batch.commit(noResult: true);
  }

  final rows = <Map<String, Object?>>[
    {
      'ID': 'a',
      '신고번호': '30',
      '범칙금_과태료': '과태료: 20,000원',
      '별점': 3,
      '보완횟수': 2,
      '신고일': '2026-01-03',
      '발생일자': '2026-01-02',
      '답변일': '2026-01-01',
    },
    {
      'ID': 'b',
      '신고번호': '20',
      '범칙금_과태료': '범칙금: 10,000원',
      '별점': 1,
      '보완횟수': 0,
      '신고일': '2026-01-01',
      '발생일자': '2026-01-03',
      '답변일': '2026-01-02',
      '처리상태': '수용',
    },
    {
      'ID': 'c',
      '신고번호': '10',
      '범칙금_과태료': '과태료: 10,000원',
      '별점': 1,
      '보완횟수': 0,
      '신고일': '2026-01-01',
      '발생일자': '2026-01-03',
      '답변일': '2026-01-02',
    },
    {
      'ID': 'd',
      '신고번호': '40',
      '범칙금_과태료': null,
      '별점': null,
      '보완횟수': null,
      '신고일': null,
      '발생일자': '',
      '답변일': '-',
    },
    {
      'ID': 'e',
      '신고번호': null,
      '범칙금_과태료': '과태료: 30,000원',
      '별점': 5,
      '보완횟수': 3,
      '신고일': '2026-01-04',
      '발생일자': '2026-01-01',
      '답변일': '2026-01-03',
    },
  ];
  const orders = {
    ReportSortField.reportNumber: ['cbade', 'dabce'],
    ReportSortField.fine: ['bcaed', 'eabcd'],
    ReportSortField.rating: ['bcaed', 'eabcd'],
    ReportSortField.supplementCount: ['bcaed', 'eabcd'],
    ReportSortField.reportDate: ['bcaed', 'eabcd'],
    ReportSortField.occurrenceDate: ['eabcd', 'bcaed'],
    ReportSortField.responseDate: ['abced', 'ebcad'],
  };
  for (final field in orders.keys) {
    for (final asc in [true, false]) {
      test(
        'SQLite ${field.name} ascending=$asc, nulls last, stable ties across pages; Client parity',
        () async {
          await seed(rows);
          final sort = ReportSort(field: field, ascending: asc);
          final ids = <String>[];
          for (var page = 0; page < 3; page++) {
            final result = await LocalDbService.getReportPage(
              sort: sort,
              page: page,
              pageSize: 2,
            );
            expect(result.total, 5);
            ids.addAll(result.reports.map((r) => r.id));
          }
          final expected = orders[field]![asc ? 0 : 1];
          expect(ids.join(), expected);
          var reads = 0;
          final snapshot = await ClientSortedReports.build(
            read: (category, {offset = 0, limit = 200, isCancelled}) async {
              reads++;
              return (
                reports: rows
                    .skip(offset)
                    .take(2)
                    .map((r) => Report.fromJson(r))
                    .toList(),
                total: rows.length,
              );
            },
            categories: ['traffic'],
            matches: (_) => true,
            isCancelled: () => false,
          );
          try {
            expect(
              (await snapshot.page(
                sort,
                0,
                size: 5,
              )).reports.map((r) => r.id).join(),
              expected,
            );
            expect(reads, 3, reason: '정렬 전에 마지막 서버 페이지까지 읽어야 한다');
          } finally {
            await snapshot.close();
          }
        },
      );
    }
  }
  test(
    'default equals old order; filter and ID search combine with ordering; persisted value restores',
    () async {
      await seed(rows);
      expect(
        (await LocalDbService.getReportPage()).reports.map((r) => r.id).join(),
        'dabce',
      );
      const sort = ReportSort(
        field: ReportSortField.responseDate,
        ascending: true,
      );
      final filtered = await LocalDbService.getReportPage(
        sort: sort,
        filter: const ReportFilter(statuses: ['불수용']),
      );
      expect(filtered.reports.map((r) => r.id).join(), 'aced');
      final one = await LocalDbService.getReportPage(
        sort: sort,
        filter: const ReportFilter(id: 'a'),
      );
      expect(one.reports.single.id, 'a');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('report_sort:standalone:0', sort.stored);
      expect(
        ReportSort.restore(prefs.getString('report_sort:standalone:0')),
        sort,
      );
      expect(ReportSort.restore('duplicateCount:asc'), ReportSort.defaults);
      expect(ReportSort.restore(null), ReportSort.defaults);
    },
  );

  test('saved rating changes invalidate the sorted lookup', () async {
    await seed(rows);
    const sort = ReportSort(field: ReportSortField.rating);
    expect(
      (await LocalDbService.getReportPage(sort: sort)).reports.first.id,
      'e',
    );
    await LocalDbService.updateReportRatingByNumber(
      '30',
      pollStatus: '참여 완료',
      rating: 5,
    );
    expect(
      (await LocalDbService.getReportPage(sort: sort)).reports.first.id,
      'a',
    );
  });

  final groups = {
    '12가1111': [2, 5],
    '12나2222': [1, 3, null],
    '12다3333': [4, 4, 4],
    '12라4444': [null, null],
  };
  for (final field in ReportSortField.values) {
    for (final asc in [true, false]) {
      test(
        'group ${field.name} ascending=$asc: representatives, intact paging, internal order and empty groups',
        () async {
          final fixture = <Map<String, Object?>>[];
          var groupIndex = 0;
          for (final g in groups.entries) {
            for (var i = 0; i < g.value.length; i++) {
              final v = g.value[i];
              fixture.add({
                'ID': '${groupIndex}_$i',
                '차량번호': g.key,
                '신고번호': v == null ? null : 'N$v',
                '범칙금_과태료': v == null ? null : '과태료: ${v * 10000}원',
                '별점': v,
                '보완횟수': v,
                for (final col in ['신고일', '발생일자', '답변일'])
                  col: v == null ? null : '2026-01-0$v',
              });
            }
            groupIndex++;
          }
          await seed(fixture);
          final sort = ReportSort(field: field, ascending: asc);
          final expected = field == ReportSortField.duplicateCount
              ? (asc ? [0, 3, 2, 1] : [2, 1, 0, 3])
              : (asc ? [1, 0, 2, 3] : [0, 2, 1, 3]);
          final flattened = <String>[];
          for (var page = 0; page < 4; page++) {
            final result = await LocalDbService.getReportPage(
              scope: 'duplicates',
              groupPage: true,
              sort: sort,
              page: page,
              pageSize: 1,
            );
            expect(result.total, 4);
            final index = expected[page];
            expect(result.reports.map((r) => r.carNumber).toSet(), {
              groups.keys.elementAt(index),
            });
            expect(
              result.reports.length,
              groups.values.elementAt(index).length,
              reason: '묶음을 페이지 경계에서 나누지 않는다',
            );
            final desc = field == ReportSortField.duplicateCount || !asc;
            final within = switch (index) {
              0 => desc ? ['0_1', '0_0'] : ['0_0', '0_1'],
              1 => desc ? ['1_1', '1_0', '1_2'] : ['1_0', '1_1', '1_2'],
              2 => ['2_2', '2_1', '2_0'],
              _ => ['3_1', '3_0'],
            };
            expect(result.reports.map((r) => r.id), within);
            flattened.addAll(within);
          }
          if (field == ReportSortField.reportNumber && !asc) {
            final old = await LocalDbService.getReportPage(
              scope: 'duplicates',
              pageSize: 200,
            );
            expect(
              old.reports.map((r) => r.id),
              flattened,
              reason: '기본 묶음/카드 순서는 기존 쿼리와 같다',
            );
          }
          final client = sortDuplicateReports(
            fixture.map((r) => Report.fromJson(r)).toList(),
            sort,
          );
          expect(client.map((r) => r.id), flattened);
          if (field == ReportSortField.duplicateCount) {
            final all = fixture.map((r) => Report.fromJson(r)).toList();
            final filtered = sortDuplicateReports(
              all.where((r) => r.id.endsWith('_0')).toList(),
              sort,
              allReports: all,
            );
            expect(
              filtered.map((r) => r.id.split('_').first),
              expected.map((i) => '$i'),
              reason: '검색으로 카드가 숨겨져도 전체 차량 횟수와 기존 묶음 동률 순서를 유지한다',
            );
          }
        },
      );
    }
  }
}
