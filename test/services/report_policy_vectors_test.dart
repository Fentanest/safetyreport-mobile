// EO R-01: 상태·처분 정책 — 서버 tests/test_report_policy_vectors.py 와 같은 파일
// contracts/report-policy-vectors.json(두 레포 바이트 동일)으로 순수 판정·SQL 조각이 같은 결과를 내는지 본다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/server_palette.dart';
import 'package:safetyreport/services/rating_service.dart';
import 'package:safetyreport/services/report_policy.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final doc =
      jsonDecode(
            File('contracts/report-policy-vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final statusCases = (doc['status_cases'] as List)
      .cast<Map<String, dynamic>>();
  final dispositionCases = (doc['disposition_cases'] as List)
      .cast<Map<String, dynamic>>();
  final filterRows = (doc['filter_rows'] as List).cast<Map<String, dynamic>>();
  final filterCases = (doc['filter_cases'] as List)
      .cast<Map<String, dynamic>>();

  test('집합·공백 문자가 계약과 같다', () {
    final sets = doc['sets'] as Map<String, dynamic>;
    expect(sets['completed'], ReportPolicy.completedOrder);
    expect(sets['processing'], ReportPolicy.processingOrder);
    expect(sets['reject'], ReportPolicy.rejectOrder);
    expect(ReportPolicy.completedOrder.toSet(), ReportPolicy.completedStatuses);
    expect(
      ReportPolicy.processingOrder.toSet(),
      ReportPolicy.processingStatuses,
    );
    expect((doc['trim_chars'] as String).codeUnits, ReportPolicy.trimCodes);
  });

  test('상태 벡터', () {
    for (final c in statusCases) {
      final s = c['status'];
      final reason = 'status=${jsonEncode(s)}';
      expect(ReportPolicy.displayStatus(s), c['display'], reason: reason);
      expect(ReportPolicy.breakdownStatus(s), c['breakdown'], reason: reason);
      expect(ReportPolicy.badgeKey(s), c['badge'], reason: reason);
      expect(ReportPolicy.isCompleted(s), c['completed'], reason: reason);
      expect(ReportPolicy.isProcessing(s), c['processing'], reason: reason);
      expect(ReportPolicy.isReject(s), c['reject'], reason: reason);
      expect(ReportPolicy.isWithdrawn(s), c['withdrawn'], reason: reason);
      expect(
        RatingService.canonicalStatusForTest(s as String? ?? ''),
        c['display'],
        reason: reason,
      );
    }
  });

  test('처분 벡터', () {
    for (final c in dispositionCases) {
      final row = Map<String, dynamic>.from(c['row'] as Map);
      final reason = jsonEncode(row);
      expect(ReportPolicy.tableDisposition(row), c['table'], reason: reason);
      expect(
        ReportPolicy.dashboardDisposition(row),
        c['dashboard'],
        reason: reason,
      );
      expect(
        ReportPolicy.trafficDashboard(row),
        c['traffic_dashboard'],
        reason: reason,
      );
      expect(
        ReportPolicy.penaltyEligible(row['category'], row['entry_value']),
        c['penalty_eligible'],
        reason: reason,
      );
      expect(
        ReportPolicy.partialUnknownMenu(row['category'], row['entry_value']),
        c['partial_unknown_menu'],
        reason: reason,
      );
    }
  });

  test('목록 필터 벡터(순수 판정)', () {
    for (final c in filterCases) {
      final name = c['name'] as String;
      final got = [
        for (final r in filterRows)
          c['kind'] == 'status'
              ? ReportPolicy.listStatusFilter(name, r['처리상태'])
              : ReportPolicy.listFineFilter(name, r['범칙금_과태료'], r['처리상태']),
      ];
      expect(got, c['matches'], reason: '${c['kind']} $name');
    }
  });

  group('SQL 조각', () {
    late Database db;
    setUpAll(() async {
      sqfliteFfiInit();
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'CREATE TABLE t (idx INTEGER, 처리상태 TEXT, 범칙금_과태료 TEXT, category TEXT, entry_value TEXT)',
      );
      for (var i = 0; i < filterRows.length; i++) {
        await db.insert('t', {
          'idx': i,
          '처리상태': filterRows[i]['처리상태'],
          '범칙금_과태료': filterRows[i]['범칙금_과태료'],
        });
      }
    });
    tearDownAll(() => db.close());

    Future<List<bool>> matches(String where) async {
      final hits = (await db.rawQuery(
        'SELECT idx FROM t WHERE $where',
      )).map((r) => r['idx']).toSet();
      return [for (var i = 0; i < filterRows.length; i++) hits.contains(i)];
    }

    test('목록 필터', () async {
      for (final c in filterCases) {
        final name = c['name'] as String;
        final where = c['kind'] == 'status'
            ? ReportPolicy.sqlListStatusFilter('처리상태', name)
            : ReportPolicy.sqlListFineFilter('범칙금_과태료', '처리상태', name)!;
        expect(
          await matches(where),
          c['matches'],
          reason: '${c['kind']} $name: $where',
        );
      }
    });

    test('취하 제외는 NULL 을 남기고 공백을 뗀다', () async {
      final expected = [
        for (final r in filterRows) !ReportPolicy.isWithdrawn(r['처리상태']),
      ];
      expect(await matches(ReportPolicy.sqlNotWithdrawn('처리상태')), expected);
    });

    test('sqlNorm 이 순수 norm 과 같다', () async {
      for (final c in statusCases) {
        final row = await db.rawQuery(
          'SELECT ${ReportPolicy.sqlNorm('?')} AS v',
          [c['status']],
        );
        expect(
          row.first['v'],
          ReportPolicy.norm(c['status']),
          reason: jsonEncode(c['status']),
        );
      }
    });
  });

  test('상태 색은 배지 판정을 따른다(답변완료만 모바일 완료색)', () {
    expect(serverStatusColor('수용'), serverAcceptColor);
    expect(serverStatusColor(' 진행중 '), serverProcessingColor);
    expect(serverStatusColor('기타'), serverRejectColor);
    expect(serverStatusColor('답변완료'), serverCompletedColor);
    expect(serverStatusColor('이송'), serverUnconfirmedColor);
  });
}
