import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/utils/current_day.dart';
import 'package:safetyreport/widgets/report_list_card.dart';
import 'package:safetyreport/widgets/status_badge.dart';

import '../support/ui_harness.dart';

Widget _card(
  Report r, {
  bool selectionMode = false,
  bool selected = false,
  Widget? suffix,
  CurrentDay? currentDay,
  DateTime? durationToday,
}) {
  return ReportListCard(
    report: r,
    selectionMode: selectionMode,
    isSelected: selected,
    onTap: () {},
    onLongPress: () {},
    headerSuffix: suffix,
    currentDay: currentDay,
    durationToday: durationToday,
    metaItems: [
      ReportCardMetaItem(icon: Icons.calendar_today, text: '신고 ${r.date}'),
      ReportCardMetaItem(icon: Icons.place, text: r.location),
      ReportCardMetaItem(icon: Icons.business, text: r.agency),
    ],
  );
}

void main() {
  testWidgets('공유 날짜 신호로 자정에 경과일과 미래 날짜의 첫 표시를 갱신한다', (tester) async {
    var now = DateTime(2026, 10, 23, 23, 59, 58);
    final day = CurrentDay(now: () => now);
    addTearDown(day.dispose);
    await pumpThemed(
      tester,
      Column(
        children: [
          _card(
            longFieldReport().copyWith(date: '2026-10-01'),
            currentDay: day,
          ),
          _card(
            longFieldReport().copyWith(date: '2026-10-24'),
            currentDay: day,
          ),
        ],
      ),
      brightness: Brightness.light,
    );
    expect(find.text('경과 22일'), findsOneWidget);
    expect(find.text('경과 0일'), findsNothing);
    now = DateTime(2026, 10, 24);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('경과 23일'), findsOneWidget);
    expect(find.text('경과 0일'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('목록 재조회 없이 앱 복귀 때 경과일을 갱신한다', (tester) async {
    var now = DateTime(2026, 10, 23, 23, 59);
    final day = CurrentDay(now: () => now);
    addTearDown(day.dispose);
    await pumpThemed(
      tester,
      _card(longFieldReport().copyWith(date: '2026-10-01'), currentDay: day),
      brightness: Brightness.dark,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = DateTime(2026, 10, 26, 10);
    await tester.pump(const Duration(days: 3));
    expect(find.text('경과 22일'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('경과 25일'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('완료·날짜 결측/오류·취하·고정 기준일 카드는 날짜 신호를 구독하지 않는다', (tester) async {
    var clockReads = 0;
    final day = CurrentDay(
      now: () {
        clockReads++;
        return DateTime(2026, 10, 24);
      },
    );
    addTearDown(day.dispose);
    await pumpThemed(
      tester,
      Column(
        children: [
          _card(
            longFieldReport(status: '수용').copyWith(responseDate: '2026-10-01'),
            currentDay: day,
          ),
          _card(longFieldReport().copyWith(date: ''), currentDay: day),
          _card(
            longFieldReport().copyWith(date: '2026-02-30'),
            currentDay: day,
          ),
          _card(longFieldReport(status: '취하'), currentDay: day),
          _card(
            longFieldReport().copyWith(date: '2026-10-01'),
            currentDay: day,
            durationToday: DateTime(2026, 10, 23),
          ),
        ],
      ),
      brightness: Brightness.light,
    );
    expect(find.text('경과 22일'), findsOneWidget);
    await tester.pump(const Duration(days: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(clockReads, 0);
    expect(find.text('경과 22일'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('처리중 카드가 완료 상태로 바뀌면 날짜 구독을 해제한다', (tester) async {
    var now = DateTime(2026, 10, 23, 23, 59);
    var clockReads = 0;
    final day = CurrentDay(
      now: () {
        clockReads++;
        return now;
      },
    );
    addTearDown(day.dispose);
    final report = longFieldReport().copyWith(date: '2026-10-01');
    await pumpThemed(
      tester,
      _card(report, currentDay: day),
      brightness: Brightness.light,
    );
    expect(find.text('경과 22일'), findsOneWidget);
    await pumpThemed(
      tester,
      _card(
        report.copyWith(status: '수용', responseDate: '2026-10-16'),
        currentDay: day,
      ),
      brightness: Brightness.light,
    );
    expect(find.text('소요 15일'), findsOneWidget);
    final before = clockReads;
    now = DateTime(2026, 10, 24);
    await tester.pump(const Duration(minutes: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(clockReads, before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    for (final scale in uiTextScales) {
      testWidgets('소요일은 상태 배지 아래에 보인다 (${brightness.name}, x$scale)', (
        tester,
      ) async {
        final report = longFieldReport(
          status: '수용',
        ).copyWith(date: '2026-10-01', responseDate: '2026-10-16');
        final errors = await pumpThemed(
          tester,
          _card(report, selectionMode: true, suffix: const Text('12/15회')),
          brightness: brightness,
          textScale: scale,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
        final badge = find.widgetWithText(StatusBadge, '수용');
        final duration = find.text('소요 15일');
        expect(duration, findsOneWidget);
        expect(
          tester.getRect(duration).top,
          greaterThan(tester.getRect(badge).bottom),
        );
        expect(
          tester
              .renderObject<RenderParagraph>(
                find.descendant(of: duration, matching: find.byType(RichText)),
              )
              .didExceedMaxLines,
          isFalse,
        );
      });
    }
  }

  testWidgets('처리중은 경과일, 날짜 누락·취하는 기간 없이 표시한다', (tester) async {
    final today = DateTime.now();
    final date =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    await pumpThemed(
      tester,
      Column(
        children: [
          _card(longFieldReport().copyWith(date: date)),
          _card(longFieldReport(status: '수용')),
          _card(longFieldReport(status: '취하')),
        ],
      ),
      brightness: Brightness.light,
    );
    expect(find.text('경과 0일'), findsOneWidget);
    expect(find.textContaining('소요'), findsNothing);
    expect(find.textContaining('경과'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in uiTextScales) {
      testWidgets('긴 필드 카드: overflow 없음 (${brightness.name}, x$scale)', (
        tester,
      ) async {
        final errors = await pumpThemed(
          tester,
          Column(
            children: [
              _card(longFieldReport()),
              _card(
                longFieldReport(status: '일부수용'),
                selectionMode: true,
                selected: true,
              ),
              _card(longFieldReport(), suffix: const Text('12/15회')),
              _card(missingFieldReport()),
            ],
          ),
          brightness: brightness,
          textScale: scale,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
      });
    }

    testWidgets('카드 접근성 가이드라인 (${brightness.name})', (tester) async {
      final handle = tester.ensureSemantics();
      final errors = await pumpThemed(
        tester,
        _card(longFieldReport()),
        brightness: brightness,
      );
      expect(errors, isEmpty, reason: describeErrors(errors));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  }

  testWidgets('카드는 기존 표시 필드를 모두 보여 준다', (tester) async {
    final report = longFieldReport();
    await pumpThemed(tester, _card(report), brightness: Brightness.light);
    expect(find.text(report.name), findsOneWidget);
    expect(find.text(report.status), findsOneWidget);
    expect(find.text(report.reportNumber), findsOneWidget);
    expect(find.text('보완횟수:2회'), findsOneWidget);
    expect(find.textContaining('보완 요청자:'), findsOneWidget);
    expect(find.text(report.carNumber), findsOneWidget);
    expect(find.text(report.agency), findsOneWidget);
  });

  testWidgets('탭과 롱프레스 콜백이 그대로 전달된다', (tester) async {
    var taps = 0;
    var longPresses = 0;
    await pumpThemed(
      tester,
      ReportListCard(
        report: longFieldReport(),
        selectionMode: false,
        isSelected: false,
        onTap: () => taps++,
        onLongPress: () => longPresses++,
        metaItems: const [],
      ),
      brightness: Brightness.light,
    );
    await tester.tap(find.byType(ReportListCard));
    await tester.longPress(find.byType(ReportListCard));
    expect(taps, 1);
    expect(longPresses, 1);
  });

  // L-8: 보통 차량번호가 40% 칸에 갇혀 "서울31바584…" 로 잘리던 문제.
  group('차량번호 칩은 잘리지 않는다 (360dp)', () {
    Report withCar(String car) {
      final base = longFieldReport();
      return Report(
        id: base.id,
        reportNumber: base.reportNumber,
        name: base.name,
        date: base.date,
        responseDate: base.responseDate,
        agency: base.agency,
        manager: base.manager,
        status: base.status,
        result: base.result,
        fineInfo: base.fineInfo,
        penaltyPoints: base.penaltyPoints,
        carNumber: car,
        law: base.law,
        location: base.location,
        occurrenceDate: base.occurrenceDate,
        occurrenceTime: base.occurrenceTime,
        reportContent: base.reportContent,
        processContent: base.processContent,
      );
    }

    bool truncated(WidgetTester tester, String text) =>
        tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

    // 12자(한글·숫자) 까지는 1.0배에서 모두 보인다.
    const plates = ['123가4567', '서울31바5847', '경기12가34567', '서울특별시12가3456'];
    for (final plate in plates) {
      testWidgets('$plate 는 1.0배에서 전부 보인다', (tester) async {
        final errors = await pumpThemed(
          tester,
          _card(withCar(plate)),
          brightness: Brightness.light,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
        expect(truncated(tester, plate), isFalse);
      });
    }

    for (final scale in uiTextScales) {
      testWidgets('서울31바5847 는 x$scale 에서도 전부 보이고 넘치지 않는다', (tester) async {
        final errors = await pumpThemed(
          tester,
          _card(withCar('서울31바5847'), selectionMode: true, selected: true),
          brightness: Brightness.dark,
          textScale: scale,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
        expect(truncated(tester, '서울31바5847'), isFalse);
      });
    }

    testWidgets('짧은 번호는 메타 정보 오른쪽, 긴 번호는 메타 정보 아래에 둔다', (tester) async {
      await pumpThemed(
        tester,
        _card(withCar('123가4567')),
        brightness: Brightness.light,
      );
      final agency = tester.getRect(find.text(longFieldReport().agency));
      final shortChip = tester.getRect(find.text('123가4567'));
      expect(shortChip.left, greaterThan(agency.right));

      await pumpThemed(
        tester,
        _card(withCar('서울특별시12가3456')),
        brightness: Brightness.light,
        textScale: 2.0,
      );
      final agency2 = tester.getRect(find.text(longFieldReport().agency));
      final longChip = tester.getRect(find.text('서울특별시12가3456'));
      expect(longChip.top, greaterThanOrEqualTo(agency2.bottom));
    });
  });
}
