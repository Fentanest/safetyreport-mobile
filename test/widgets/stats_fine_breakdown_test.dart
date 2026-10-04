import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/agency_stats.dart';
import 'package:safetyreport/theme/sr_colors.dart';
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
    // SQ-U22: 금액은 앱 공통 전체 쉼표 표기(이전 "12만원"·"5만원").
    expect(find.text('확정 120,000원 (1건)'), findsOneWidget);
    expect(find.text('금액 미확인 2건'), findsOneWidget);
    expect(find.text('50,000원 (1건)'), findsOneWidget);
    expect(find.byType(EstimateBadge), findsOneWidget);
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

  for (final brightness in Brightness.values) {
    testWidgets(
      '추정은 보조 글자색·보통 굵기·점선 추정 배지로 확정과 구분하고 합치지 않는다 (${brightness.name})',
      (tester) async {
        final errors = await pumpThemed(
          tester,
          StatsFineBreakdown(row: _row()),
          brightness: brightness,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
        final context = tester.element(find.byType(StatsFineBreakdown));
        final sr = context.sr;
        final confirmed = tester.widget<Text>(find.text('확정 120,000원 (1건)'));
        final estimated = tester.widget<Text>(find.text('50,000원 (1건)'));
        expect(confirmed.style!.fontWeight, FontWeight.w600);
        expect(estimated.style!.fontWeight, FontWeight.w400);
        expect(estimated.style!.color, sr.textSecondary);
        expect(confirmed.style!.color, isNot(estimated.style!.color));
        // 배지는 추정 금액 바로 앞에 붙는다.
        final badge = find.descendant(
          of: find.byKey(const ValueKey('stats-fine-estimated')),
          matching: find.byType(EstimateBadge),
        );
        expect(badge, findsOneWidget);
        expect(
          tester.getTopRight(badge).dx,
          lessThanOrEqualTo(tester.getTopLeft(find.text('50,000원 (1건)')).dx),
        );
        // 확정 + 추정 합(170,000원)은 어디에도 없다.
        expect(find.textContaining('170,000'), findsNothing);
      },
    );
  }

  testWidgets('추정 금액을 모르면 배지와 함께 "금액 미지원"을 보인다', (tester) async {
    await pumpThemed(
      tester,
      StatsFineBreakdown(row: _row(estimated: null, estimateCount: 2)),
      brightness: Brightness.light,
    );
    expect(find.text('금액 미지원 (2건)'), findsOneWidget);
    expect(find.byType(EstimateBadge), findsOneWidget);
  });
}
