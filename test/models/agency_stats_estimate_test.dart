import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/agency_stats.dart';

// 서버 /api/v1/stats 행의 2026-09-24 추가 필드(분리 분류·추정 과태료) 파싱. 구서버 응답은 null 로 두어 기존 표시로 되돌아간다.
void main() {
  Map<String, dynamic> baseRow() => {
        'agency': 'A구청',
        'total': 4,
        'fines': 1,
        'fines_pct': 25.0,
        'warnings': 0,
        'warnings_pct': 0.0,
        'rejects': 0,
        'rejects_pct': 0.0,
        'unconfirmed': 3,
        'unconfirmed_pct': 75.0,
        'total_fine_amount': 0,
        'fine_amount_unknown': 1,
      };

  test('new server row parses split categories and estimates', () {
    final row = AgencyStatRow.fromJson({
      ...baseRow(),
      'disposition_unknown': 1,
      'disposition_unknown_pct': 25.0,
      'no_penalty': 1,
      'no_penalty_pct': 25.0,
      'unclassified': 1,
      'unclassified_pct': 25.0,
      'estimated_fine_amount': 50000,
      'estimated_fine_count': 1,
    });
    expect(row.dispositionUnknown, 1);
    expect(row.noPenalty, 1);
    expect(row.unclassified, 1);
    expect(row.estimatedFineAmount, 50000);
    expect(row.estimatedFineCount, 1);
    // 확정 금액은 추정과 섞이지 않는다
    expect(row.totalFineAmount, 0);
    expect(row.fineAmountUnknown, 1);
  });

  test('old server row keeps new fields null', () {
    final row = AgencyStatRow.fromJson(baseRow());
    expect(row.dispositionUnknown, isNull);
    expect(row.noPenalty, isNull);
    expect(row.unclassified, isNull);
    expect(row.estimatedFineAmount, isNull);
    expect(row.unconfirmed, 3);
  });
}
