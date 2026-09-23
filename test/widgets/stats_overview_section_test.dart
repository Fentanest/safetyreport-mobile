import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/stats_overview.dart';
import 'package:safetyreport/widgets/stats_overview_section.dart';

import '../support/ui_harness.dart';

OverviewSummary fixtureSummary({int months = 8}) {
  final reported = <MonthlyCount>[];
  final answered = <MonthlyCount>[];
  for (var i = 0; i < months; i++) {
    final y = 2025 + (i ~/ 12);
    final m = (i % 12) + 1;
    final key = '$y-${m.toString().padLeft(2, '0')}';
    reported.add(MonthlyCount(key, 40 + (i * 7) % 30));
    answered.add(MonthlyCount(key, 30 + (i * 5) % 25));
  }
  return OverviewSummary(
    total: 12345,
    completed: 11890,
    accept: 8000,
    partial: 1200,
    reject: 2690,
    supplement: 12,
    processing: 443,
    withdraw: 0,
    avgDays: 38.5,
    avgDaysCount: 11890,
    reversedDateCount: 3,
    undatedReportCount: 1,
    monthlyReported: reported,
    monthlyAnswered: answered,
  );
}

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in uiTextScales) {
      testWidgets('통계 요약: overflow 없음 (${brightness.name}, x$scale)', (
        tester,
      ) async {
        final errors = await pumpThemed(
          tester,
          StatsOverviewSection(
            summary: fixtureSummary(months: 30),
            categoryLabel: '교통위반',
            yearBasis: '답변일',
          ),
          brightness: brightness,
          textScale: scale,
          height: 1400,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
      });
    }
  }

  testWidgets('요약 카드 값과 기준 안내가 런타임 요약에서 나온다', (tester) async {
    await pumpThemed(
      tester,
      StatsOverviewSection(
        summary: fixtureSummary(),
        categoryLabel: '교통위반',
        yearBasis: '신고일',
      ),
      brightness: Brightness.light,
      height: 1400,
    );
    expect(find.text('교통위반 요약'), findsOneWidget);
    expect(find.text('12345건'), findsOneWidget);
    expect(find.text('38.5일'), findsOneWidget);
    expect(find.text('표본 11890건'), findsOneWidget);
    expect(find.text('보완요청 12건 별도'), findsOneWidget);
    expect(find.text('신고 (신고일 기준)'), findsOneWidget);
    expect(find.text('답변 (답변일 기준)'), findsOneWidget);
    expect(find.textContaining('연도 필터는 신고일 기준'), findsOneWidget);
    expect(find.textContaining('3건은 평균에서 제외'), findsOneWidget);
  });

  testWidgets('표본이 없으면 평균은 대시(—)로 표시', (tester) async {
    await pumpThemed(
      tester,
      const StatsOverviewSection(
        summary: OverviewSummary.empty,
        categoryLabel: '기타위반',
        yearBasis: '신고일',
      ),
      brightness: Brightness.dark,
    );
    expect(find.text('—'), findsOneWidget);
    expect(find.text('표시할 월별 데이터가 없습니다.'), findsOneWidget);
  });

  testWidgets('구서버 미지원 안내는 요약 대신 표시', (tester) async {
    await pumpThemed(
      tester,
      const StatsOverviewSection(
        summary: null,
        categoryLabel: '교통위반',
        yearBasis: '',
        notice: '서버가 통계 요약 API를 아직 지원하지 않습니다.',
      ),
      brightness: Brightness.light,
    );
    expect(find.textContaining('아직 지원하지 않습니다'), findsOneWidget);
    expect(find.text('교통위반 요약'), findsNothing);
  });
}
