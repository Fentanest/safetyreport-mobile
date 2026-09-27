import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/stats_overview.dart';
import 'package:safetyreport/services/local_db_service.dart';

/// 통계 개편(2026-09-28): 서버 `tests/test_stats_overview_vectors.py` 와 같은 파일
/// `contracts/stats-overview-vectors.json`(두 레포 바이트 동일)로 요약·기관표 행 계산이 같은지 확인한다.
const _agencyKeys = [
  'agency',
  'total',
  'avg_days',
  'avg_days_count',
  'fines',
  'fine_amount_unknown',
  'total_fine_amount',
  'estimated_fine_amount',
  'estimated_fine_count',
  'in_progress',
  'disposition_unknown',
  'no_penalty',
  'unclassified',
];

void main() {
  final doc =
      jsonDecode(
            File('contracts/stats-overview-vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> rowsOf(Map<String, dynamic> c) =>
      (c['rows'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  for (final c in cases) {
    test('요약 벡터 ${c['name']}', () {
      final summary = jsonDecode(
        jsonEncode(LocalDbService.summarizeOverviewRows(rowsOf(c))),
      );
      expect(summary, equals(c['expected_overview']));
    });

    if ((c['rows'] as List).isEmpty) continue;
    test('기관표 행 벡터 ${c['name']}', () {
      final rows = rowsOf(c);
      final category = LocalDbService.buildStatsCategory(rows, rows, false);
      final agency =
          (category['by_agency'] as List)
              .cast<Map<String, dynamic>>()
              .map((r) => {for (final k in _agencyKeys) k: r[k]})
              .toList()
            ..sort(
              (a, b) =>
                  (a['agency'] as String).compareTo(b['agency'] as String),
            );
      expect(jsonDecode(jsonEncode(agency)), equals(c['expected_agency_rows']));
    });
  }

  test('모델이 새 필드를 읽고 구서버(필드 없음)는 null 로 구분한다', () {
    final c = cases.firstWhere((c) => c['name'] == 'traffic_mix');
    final s = OverviewSummary.fromJson(
      Map<String, dynamic>.from(c['expected_overview'] as Map),
    );
    expect(s.disposition!.overlap, 1);
    expect(s.fineAmount!.confirmedAmount, 100000);
    expect(s.fineAmount!.estimatedAmount, 50000);
    expect(s.reportTypes!.first.name, '신호위반');
    expect(s.monthlyAnsweredFine, isNotNull);
    final old = OverviewSummary.fromJson({'total': 3});
    expect(old.disposition, isNull);
    expect(old.fineAmount, isNull);
    expect(old.reportTypes, isNull);
    expect(old.monthlyAnsweredFine, isNull);
  });
}
