import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/stats_overview.dart';
import 'package:safetyreport/widgets/stats_overview_section.dart';

import '../support/ui_harness.dart';

OverviewSummary fixtureSummary({int months = 8, bool withExtras = true}) {
  final reported = <MonthlyCount>[];
  final answered = <MonthlyCount>[];
  final fine = <MonthlyCount>[];
  for (var i = 0; i < months; i++) {
    final y = 2025 + (i ~/ 12);
    final m = (i % 12) + 1;
    final key = '$y-${m.toString().padLeft(2, '0')}';
    reported.add(MonthlyCount(key, 40 + (i * 7) % 30));
    answered.add(MonthlyCount(key, 30 + (i * 5) % 25));
    fine.add(MonthlyCount(key, 10 + (i * 3) % 9));
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
    monthlyAnsweredFine: withExtras ? fine : null,
    disposition: withExtras
        ? const OverviewDisposition(
            fines: 4321,
            warnings: 2100,
            rejects: 2690,
            unconfirmed: 2779,
            inProgress: 455,
            dispositionUnknown: 120,
            noPenalty: 2000,
            unclassified: 659,
            overlap: 0,
          )
        : null,
    fineAmount: withExtras
        ? const OverviewFineAmount(
            confirmedAmount: 123456780,
            confirmedCount: 3000,
            unknownCount: 1321,
            estimatedAmount: 56500000,
            estimatedCount: 1130,
          )
        : null,
    reportTypes: withExtras
        ? [
            for (var i = 0; i < 9; i++)
              ReportTypeCount(
                i == 0 ? '어린이보호구역 내 불법주정차 및 보행자 보호의무 위반(장문 유형명 확인용)' : '유형 $i',
                1000 - i * 90,
              ),
          ]
        : null,
  );
}

void main() {
  // L-9: "123,456,780원"·"11,890건" 이 줄바꿈되어 단위만 다음 줄에 남던 문제.
  for (final scale in uiTextScales) {
    testWidgets('요약 값은 숫자와 단위가 한 줄에 있다 (360dp, x$scale)', (
      tester,
    ) async {
      final errors = await pumpThemed(
        tester,
        StatsOverviewSection(
          summary: fixtureSummary(),
          categoryLabel: '교통위반',
          yearBasis: '답변일',
          now: DateTime(2025, 8, 20),
        ),
        brightness: Brightness.light,
        textScale: scale,
        height: 2600,
      );
      expect(errors, isEmpty, reason: describeErrors(errors));
      for (final value in [
        '123,456,780원',
        '12,345건',
        '11,890건',
        '4,321건',
        '2,100건',
        '38.5일',
      ]) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(value),
        );
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: value.length),
        );
        final tops = boxes.map((b) => b.top.round()).toSet();
        expect(tops, hasLength(1), reason: '$value 가 여러 줄로 나뉨');
        expect(paragraph.didExceedMaxLines, isFalse, reason: value);
        // 값이 타일 안에 다 보인다(잘리거나 타일 밖으로 나가지 않음).
        final tile = tester.getRect(
          find
              .ancestor(of: find.text(value), matching: find.byType(SizedBox))
              .first,
        );
        final rect = tester.getRect(find.text(value));
        expect(rect.right, lessThanOrEqualTo(tile.right + 0.5), reason: value);
      }
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in uiTextScales) {
      for (final width in [360.0, 430.0]) {
        testWidgets(
          '통계 요약: overflow 없음 (${brightness.name}, x$scale, ${width.toInt()}dp)',
          (tester) async {
            final errors = await pumpThemed(
              tester,
              StatsOverviewSection(
                summary: fixtureSummary(months: 30),
                categoryLabel: '교통위반',
                yearBasis: '답변일',
                chartsExpanded: true,
                onChartsExpandedChanged: (_) {},
                now: DateTime(2027, 6, 15),
              ),
              brightness: brightness,
              textScale: scale,
              width: width,
              height: 2600,
            );
            expect(errors, isEmpty, reason: describeErrors(errors));
          },
        );
      }
    }
  }

  testWidgets('요약 카드 6개는 런타임 요약 값을 쓰고 확정·추정 금액을 따로 보인다', (tester) async {
    await pumpThemed(
      tester,
      StatsOverviewSection(
        summary: fixtureSummary(),
        categoryLabel: '교통위반',
        yearBasis: '답변일',
        now: DateTime(2025, 8, 20),
      ),
      brightness: Brightness.light,
      height: 1600,
    );
    expect(find.text('12,345건'), findsOneWidget);
    expect(find.text('11,890건'), findsOneWidget);
    expect(find.text('4,321건'), findsOneWidget); // 과태료 건수
    expect(find.text('2,100건'), findsOneWidget); // 경고·범칙금
    expect(find.text('38.5일'), findsOneWidget);
    expect(find.text('123,456,780원'), findsOneWidget); // 확정은 합치지 않은 원문 금액 합
    expect(
      find.textContaining('추정(법정 최저) 56,500,000원 · 1,130건'),
      findsOneWidget,
    );
    expect(find.textContaining('완료 신고 유효 표본 11,890건'), findsOneWidget);
    expect(find.textContaining('처리 중 443건 · 보완요청 12건'), findsOneWidget);
    expect(find.text('처리(답변) 건수'), findsOneWidget);
    expect(find.text('그중 과태료'), findsOneWidget);
    expect(find.text('이번 달(집계 중)'), findsOneWidget);
    expect(find.textContaining('연도 필터는 답변일 기준'), findsOneWidget);
    // 차트는 접힌 상태가 기본
    expect(find.text('처분 분포'), findsNothing);
  });

  testWidgets('펼치면 처분 분포(여섯 항목)와 위반 유형 상위 6개 + 전체 보기가 나온다', (tester) async {
    await pumpThemed(
      tester,
      StatsOverviewSection(
        summary: fixtureSummary(),
        categoryLabel: '교통위반',
        yearBasis: '답변일',
        chartsExpanded: true,
        onChartsExpandedChanged: (_) {},
        now: DateTime(2025, 8, 20),
      ),
      brightness: Brightness.dark,
      height: 2400,
    );
    // 처리중(답변 전)은 분포에서 빼고 답변된 신고를 분모로 한다(2026-09-28)
    expect(find.text('답변된 신고 11,890건 기준'), findsOneWidget);
    expect(
      find.textContaining('처리 중(답변 전) 455건은 처분이 없어 뺐습니다'),
      findsOneWidget,
    );
    for (final label in [
      '과태료',
      '경고/범칙금',
      '불수용/기타',
      '과태료 미확인',
      '처분 대상 아님',
      '기타·미분류',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('유형 5'), findsOneWidget);
    expect(find.text('유형 6'), findsNothing);
    await tester.tap(find.textContaining('전체 9개 유형 보기'));
    await tester.pump();
    expect(find.text('유형 8'), findsOneWidget);
  });

  testWidgets('구서버(추가 필드 없음)는 0 으로 바꾸지 않고 미지원으로 표시', (tester) async {
    await pumpThemed(
      tester,
      StatsOverviewSection(
        summary: fixtureSummary(withExtras: false),
        categoryLabel: '교통위반',
        yearBasis: '답변일',
        chartsExpanded: true,
        onChartsExpandedChanged: (_) {},
      ),
      brightness: Brightness.light,
      height: 2000,
    );
    expect(find.text('미지원'), findsNWidgets(3)); // 과태료·경고/범칙금·확정 과태료
    expect(find.textContaining('처분 분포를 제공하지 않습니다'), findsWidgets);
    expect(find.text('그중 과태료'), findsNothing);
  });

  testWidgets('표본이 없으면 평균은 대시(—), 답변 없는 기간은 안내', (tester) async {
    await pumpThemed(
      tester,
      const StatsOverviewSection(
        summary: OverviewSummary.empty,
        categoryLabel: '기타위반',
        yearBasis: '답변일',
      ),
      brightness: Brightness.dark,
    );
    expect(find.text('—'), findsOneWidget);
    expect(find.text('선택한 조건에 답변일이 있는 신고가 없습니다.'), findsOneWidget);
  });

  testWidgets('요약만 실패하면 안내와 다시 시도 버튼을 보인다', (tester) async {
    var retried = 0;
    await pumpThemed(
      tester,
      StatsOverviewSection(
        summary: null,
        categoryLabel: '교통위반',
        yearBasis: '',
        notice: '서버가 통계 요약 API를 아직 지원하지 않습니다.',
        onRetry: () => retried++,
      ),
      brightness: Brightness.light,
    );
    expect(find.textContaining('아직 지원하지 않습니다'), findsOneWidget);
    await tester.tap(find.text('다시 시도'));
    expect(retried, 1);
  });

  testWidgets('연도를 고르면 미래 달을 0건으로 그리지 않는다(이번 달까지만)', (tester) async {
    final s = OverviewSummary.fromJson({
      'total': 3,
      'monthly_answered': [
        {'month': '2026-01', 'count': 2},
        {'month': '2026-03', 'count': 1},
      ],
      'monthly_answered_fine': [],
    });
    await pumpThemed(
      tester,
      StatsOverviewSection(
        summary: s,
        categoryLabel: '교통위반',
        yearBasis: '답변일',
        year: '2026',
        now: DateTime(2026, 4, 10),
      ),
      brightness: Brightness.light,
      height: 1400,
    );
    expect(find.text('4월'), findsOneWidget); // 이번 달(집계 중)
    expect(find.text('5월'), findsNothing);
    expect(find.textContaining('이번 달은 집계 중'), findsOneWidget);
  });
}
