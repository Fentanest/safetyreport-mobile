import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/agency_stats.dart';
import 'package:safetyreport/widgets/stats_fine_breakdown.dart';

import '../support/ui_harness.dart';

AgencyStatRow _row({
  int fines = 3,
  int confirmed = 120000,
  int unknown = 2,
  int? estimated = 50000,
  int? estimateCount = 1,
}) => AgencyStatRow(
  agency: '서울경찰서',
  person: '',
  total: 3,
  fines: fines,
  finesPct: 100,
  warnings: 0,
  warningsPct: 0,
  rejects: 0,
  rejectsPct: 0,
  unconfirmed: 0,
  unconfirmedPct: 0,
  totalFineAmount: confirmed,
  fineAmountUnknown: unknown,
  estimatedFineAmount: estimated,
  estimatedFineCount: estimateCount,
);

void main() {
  testWidgets('좁은 화면에서도 확정·미확인·추정 금액과 각 건수가 모두 보인다', (tester) async {
    final errors = await pumpThemed(
      tester,
      StatsFineBreakdown(row: _row()),
      brightness: Brightness.light,
      width: 240,
      height: 300,
      textScale: 2,
    );
    expect(errors, isEmpty, reason: describeErrors(errors));
    expect(find.text('확정 12만원 (1건)'), findsOneWidget);
    expect(find.text('금액 미확인 2건'), findsOneWidget);
    expect(find.text('추정 5만원 (1건)'), findsOneWidget);
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    }
  });

  testWidgets('금액 미확인만 있으면 확정 0건을 표시한다', (tester) async {
    await pumpThemed(
      tester,
      StatsFineBreakdown(
        row: _row(
          fines: 2,
          confirmed: 0,
          unknown: 2,
          estimated: null,
          estimateCount: 0,
        ),
      ),
      brightness: Brightness.dark,
    );
    expect(find.text('확정 0원 (0건)'), findsOneWidget);
    expect(find.text('금액 미확인 2건'), findsOneWidget);
    expect(find.textContaining('추정'), findsNothing);
  });
}
