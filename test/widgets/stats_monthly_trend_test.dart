// SQ-U09: 월별 처리 추이 세로축 맨 위 눈금 숫자가 차트 위 경계에 걸쳐 절반이 잘리던 문제와 축 글자 10 크기.
// SQ-U24(당월): '이번 달(집계 중)' 막대가 옅은 색(대비 약 1.9:1)만으로 구분되던 문제 — 빗금 무늬로 구분하고 범례도 같게.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/stats_overview.dart';
import 'package:safetyreport/widgets/stats_overview_section.dart';

import '../support/ui_harness.dart';

/// 2025-06 ~ 2025-09 답변 건수 2,1,4,3 — 최대 4, 눈금 간격 1, 차트 최대 5(맨 위 눈금).
OverviewSummary _small() => const OverviewSummary(
  total: 10,
  completed: 10,
  accept: 6,
  partial: 1,
  reject: 3,
  supplement: 0,
  processing: 0,
  withdraw: 0,
  avgDays: 2,
  avgDaysCount: 10,
  reversedDateCount: 0,
  undatedReportCount: 0,
  monthlyReported: [],
  monthlyAnswered: [
    MonthlyCount('2025-06', 2),
    MonthlyCount('2025-07', 1),
    MonthlyCount('2025-08', 4),
    MonthlyCount('2025-09', 3),
  ],
  monthlyAnsweredFine: [
    MonthlyCount('2025-06', 1),
    MonthlyCount('2025-07', 1),
    MonthlyCount('2025-08', 2),
    MonthlyCount('2025-09', 1),
  ],
);

Future<List<FlutterErrorDetails>> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) => pumpThemed(
  tester,
  StatsOverviewSection(
    summary: _small(),
    categoryLabel: '교통위반',
    yearBasis: '답변일',
    now: DateTime(2025, 9, 15),
  ),
  brightness: brightness,
  textScale: textScale,
  height: 1400,
);

void main() {
  testWidgets('세로축 맨 위(차트 최대) 눈금 숫자는 그리지 않고, 그 아래 눈금은 그린다', (tester) async {
    final errors = await _pump(tester);
    expect(errors, isEmpty, reason: describeErrors(errors));
    final chart = find.byType(BarChart);
    expect(tester.widget<BarChart>(chart).data.maxY, 5);
    Finder axis(String text) =>
        find.descendant(of: chart, matching: find.text(text));
    expect(axis('5'), findsNothing, reason: '맨 위 눈금은 위 경계에서 잘린다');
    expect(axis('4'), findsOneWidget);
    expect(axis('0'), findsOneWidget);
  });

  testWidgets('축 글자는 11 이상이다', (tester) async {
    await _pump(tester);
    final texts = tester.widgetList<Text>(
      find.descendant(of: find.byType(BarChart), matching: find.byType(Text)),
    );
    expect(texts, isNotEmpty);
    for (final t in texts) {
      expect(t.style?.fontSize, greaterThanOrEqualTo(11), reason: t.data);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('이번 달 막대는 빗금 무늬로, 지난 달 막대는 단색으로 그린다 (${brightness.name})', (
      tester,
    ) async {
      await _pump(tester, brightness: brightness);
      final data = tester.widget<BarChart>(find.byType(BarChart)).data;
      final groups = data.barGroups;
      expect(groups, hasLength(4));
      // 마지막 달(2025-09)이 이번 달.
      final current = groups.last.barRods.first;
      expect(current.gradient, isA<StatsHatchGradient>());
      for (final g in groups.take(3)) {
        expect(g.barRods.first.gradient, isNull);
        expect(g.barRods.first.color!.a, 1.0);
      }
      // 빗금 줄은 지난 달 막대와 같은 진한 색이다(옅은 색만으로 구분하지 않는다).
      final hatch = current.gradient! as StatsHatchGradient;
      expect(hatch.color, groups.first.barRods.first.color);

      // 범례도 같은 빗금으로 그린다.
      final legend = find.byKey(const ValueKey('stats-trend-legend-current'));
      expect(
        find.descendant(of: legend, matching: find.text('이번 달(집계 중)')),
        findsOneWidget,
      );
      final swatch = tester.widget<Container>(
        find.descendant(of: legend, matching: find.byType(Container)).first,
      );
      final deco = swatch.decoration! as BoxDecoration;
      expect(deco.gradient, hatch);
    });
  }

  test('빗금 무늬는 값이 같으면 같다고 판단한다(차트가 매 빌드마다 다시 애니메이션하지 않게)', () {
    final a = StatsHatchGradient(color: const Color(0xFF60A5FA));
    final b = StatsHatchGradient(color: const Color(0xFF60A5FA));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      Gradient.lerp(null, a, 0.5),
      isA<StatsHatchGradient>(),
      reason: '애니메이션 보간이 빗금을 유지한다',
    );
  });

  for (final scale in uiTextScales) {
    testWidgets('작은 값 차트도 글꼴 $scale배에서 넘치지 않는다', (tester) async {
      final errors = await _pump(tester, textScale: scale);
      expect(errors, isEmpty, reason: describeErrors(errors));
    });
  }
}
