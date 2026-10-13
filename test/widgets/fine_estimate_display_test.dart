// row-estimate(2026-10-12): 신고 목록(카드)·상세 시트·엑셀 내보내기에서 금액 없는 "과태료" 행에
// 법정 최저 기준 추정을 보조 표기로 더하는 기능의 위젯/단위 시험.
//
// 대상 판정·계산은 lib/services/fine_estimate.dart 의 isEstimateTarget/estimate 를 그대로 쓴다
// (test/services/fine_estimate_test.dart 가 규칙표 자체를 검증). 여기서는 화면·내보내기가 그 결과를
// 올바르게, 확정 값과 섞지 않고, 34dp 최소 높이·접근성·넘침 없이 보이는지만 본다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/excel_export_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:safetyreport/widgets/report_list_card.dart';

import '../support/ui_harness.dart';

Report _report({
  required String fineInfo,
  String category = '',
  String entryValue = '',
  String carNumber = '12가3456',
  String name = '신고',
  String law = '',
}) => Report(
  id: 'f-1',
  reportNumber: 'SPP-1',
  name: name,
  date: '2026-10-01',
  responseDate: '2026-10-05',
  agency: '서울시청',
  manager: '홍길동',
  status: '수용',
  result: '수용',
  fineInfo: fineInfo,
  penaltyPoints: '',
  carNumber: carNumber,
  law: law,
  location: '서울',
  occurrenceDate: '2026-10-01',
  occurrenceTime: '10:00',
  reportContent: '',
  processContent: '',
  category: category,
  entryValue: entryValue,
);

// ── 대상(추정 표시) ───────────────────────────────────────────────────────
Report _wasteTarget() => _report(
  fineInfo: '과태료',
  category: 'other',
  entryValue: '생활불편 신고-쓰레기, 폐기물',
);

Report _parkingTarget() => _report(
  fineInfo: '과태료',
  category: 'parking',
  entryValue: '불법주정차신고-인도',
);

// ── 비대상(추정 표시 없음) ──────────────────────────────────────────────
Report _confirmedAmount() => _report(
  fineInfo: '과태료 40,000원',
  category: 'parking',
  entryValue: '불법주정차신고-인도',
);

Report _penalty() => _report(fineInfo: '범칙금 30,000원');

Report _warning() => _report(fineInfo: '경고');

Report _nonTargetCategory() => _report(
  fineInfo: '과태료',
  category: 'safety',
  entryValue: '안전신고-도로 파손',
);

Report _noFineInfo() => _report(fineInfo: '');

void main() {
  group('ReportCardMetaItem.fine — 대상 판정', () {
    test('금액 없는 쓰레기·폐기물 과태료는 추정을 더한다', () {
      final item = ReportCardMetaItem.fine(_wasteTarget());
      expect(item.text, '과태료');
      expect(item.secondaryText, '추정 50,000원');
      expect(item.semanticsLabel, contains('추정 금액 50,000원'));
    });

    test('금액 없는 일반 주정차 과태료는 추정을 더한다', () {
      final item = ReportCardMetaItem.fine(_parkingTarget());
      expect(item.secondaryText, '추정 40,000원');
    });

    for (final (name, report) in [
      ('확정 금액이 있으면', _confirmedAmount()),
      ('범칙금이면', _penalty()),
      ('경고면', _warning()),
      ('분류 규칙이 없으면(비대상)', _nonTargetCategory()),
    ]) {
      test('$name 추정을 더하지 않는다', () {
        final item = ReportCardMetaItem.fine(report);
        expect(item.secondaryText, isNull);
        expect(item.text, report.fineInfo);
      });
    }
  });

  group('목록 카드 렌더', () {
    Widget card(Report report) => ReportListCard(
      report: report,
      selectionMode: false,
      isSelected: false,
      onTap: () {},
      onLongPress: () {},
      metaItems: [ReportCardMetaItem.fine(report)],
    );

    for (final brightness in Brightness.values) {
      for (final scale in uiTextScales) {
        testWidgets(
          '추정 대상 카드: 넘침 없음 (${brightness.name}, x$scale)',
          (tester) async {
            final errors = await pumpThemed(
              tester,
              Column(
                children: [card(_wasteTarget()), card(_parkingTarget())],
              ),
              brightness: brightness,
              textScale: scale,
            );
            expect(errors, isEmpty, reason: describeErrors(errors));
            expect(find.textContaining('추정 50,000원'), findsOneWidget);
            expect(find.textContaining('추정 40,000원'), findsOneWidget);
          },
        );

        testWidgets(
          '비대상 카드: 추정 표시 없음, 넘침 없음 (${brightness.name}, x$scale)',
          (tester) async {
            final errors = await pumpThemed(
              tester,
              Column(
                children: [
                  card(_confirmedAmount()),
                  card(_penalty()),
                  card(_warning()),
                  card(_nonTargetCategory()),
                ],
              ),
              brightness: brightness,
              textScale: scale,
            );
            expect(errors, isEmpty, reason: describeErrors(errors));
            expect(find.textContaining('추정'), findsNothing);
          },
        );
      }
    }

    testWidgets('과태료 정보가 없으면 금액 아이콘 줄이 보이지 않는다', (tester) async {
      await pumpThemed(
        tester,
        card(_noFineInfo()),
        brightness: Brightness.light,
      );
      expect(find.byIcon(Icons.monetization_on_outlined), findsNothing);
    });

    testWidgets('추정 보조 표기에 스크린리더 라벨이 있다', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        card(_wasteTarget()),
        brightness: Brightness.light,
      );
      expect(
        find.bySemanticsLabel(RegExp('추정 금액 50,000원')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('상세 시트 "과태료/범칙금" 줄', () {
    Future<List<FlutterErrorDetails>> pumpSheet(
      WidgetTester tester,
      Report report, {
      Brightness brightness = Brightness.light,
      double textScale = 1.0,
      double width = 360,
    }) async {
      tester.view.physicalSize = Size(width, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(body: ReportDetailSheet(report: report)),
          ),
        );
        await tester.pump();
      } finally {
        FlutterError.onError = previous;
      }
      return errors;
    }

    Finder row(String label) => find
        .ancestor(of: find.text(label), matching: find.byType(Container))
        .first;

    for (final brightness in Brightness.values) {
      for (final width in [360.0, 412.0]) {
        for (final scale in uiTextScales) {
          final caseName = '${brightness.name} · ${width}dp · $scale배';

          testWidgets('추정 대상: 확정값·추정·근거 세 줄, 넘침 없음 ($caseName)', (
            tester,
          ) async {
            final errors = await pumpSheet(
              tester,
              _wasteTarget(),
              brightness: brightness,
              width: width,
              textScale: scale,
            );
            expect(errors, isEmpty, reason: describeErrors(errors));
            expect(find.text('과태료'), findsOneWidget);
            expect(find.textContaining('추정 50,000원'), findsOneWidget);
            expect(find.textContaining('법정 최저 기준'), findsOneWidget);
            expect(find.textContaining('폐기물관리법'), findsOneWidget);
          });

          testWidgets('비대상(확정 금액): 추정·근거 없음, 넘침 없음 ($caseName)', (
            tester,
          ) async {
            final errors = await pumpSheet(
              tester,
              _confirmedAmount(),
              brightness: brightness,
              width: width,
              textScale: scale,
            );
            expect(errors, isEmpty, reason: describeErrors(errors));
            expect(find.text('과태료 40,000원'), findsOneWidget);
            expect(find.textContaining('추정'), findsNothing);
            expect(find.textContaining('법정 최저 기준'), findsNothing);
          });
        }
      }
    }

    testWidgets('추정 대상 줄은 늘어나고 다른 줄은 34dp 그대로다', (tester) async {
      await pumpSheet(tester, _wasteTarget());
      final fineRow = tester.getRect(row('과태료/범칙금'));
      final plateRow = tester.getRect(row('차량번호'));
      expect(fineRow.height, greaterThan(34));
      expect(plateRow.height, 34);
    });

    testWidgets('비대상 줄은 다른 줄과 같은 34dp다', (tester) async {
      await pumpSheet(tester, _confirmedAmount());
      final fineRow = tester.getRect(row('과태료/범칙금'));
      expect(fineRow.height, 34);
    });

    testWidgets('과태료 정보가 없으면 줄 자체가 없다', (tester) async {
      await pumpSheet(tester, _noFineInfo());
      expect(find.text('과태료/범칙금'), findsNothing);
    });

    testWidgets('추정 줄에 확정 값과 추정 금액·근거를 묶은 스크린리더 라벨이 있다', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSheet(tester, _wasteTarget());
      expect(
        find.bySemanticsLabel(
          RegExp('과태료, 추정 금액 50,000원, 법정 최저 기준 · 폐기물관리법'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  testWidgets('Client JSON의 위반법규로 목록 카드와 상세의 끼어들기 금액 보정', (tester) async {
    final report = Report.fromJson({
      'ID': 'fixture-fine-table',
      '신고명': '끼어들기 금지 위반',
      '처리상태': '수용',
      '차량번호': '63너1234',
      '위반법규': '도로교통법 제23조',
      '범칙금_과태료': '과태료: 40,0000원',
      'category': 'traffic',
    });
    expect(report.law, '도로교통법 제23조');
    final errors = await pumpThemed(
      tester,
      ReportListCard(
        report: report,
        selectionMode: false,
        isSelected: false,
        onTap: () {},
        onLongPress: () {},
        metaItems: [ReportCardMetaItem.fine(report)],
      ),
      brightness: Brightness.light,
    );
    expect(errors, isEmpty, reason: describeErrors(errors));
    expect(find.text('과태료: 40,000원'), findsOneWidget);
    expect(find.textContaining('추정'), findsNothing);
    tester.view.physicalSize = const Size(412, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: Scaffold(body: ReportDetailSheet(report: report)),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('과태료: 40,000원'), findsOneWidget);
    expect(find.textContaining('추정'), findsNothing);
    expect(report.fineInfo, '과태료: 40,0000원');
  });

  group('엑셀 내보내기 — 추정 금액/추정 근거 열', () {
    test('추정 대상이면 끝 두 열에 금액·근거가 들어간다', () {
      final values = excelExportRowValues(_wasteTarget());
      expect(values.length, 27);
      expect(values[25], '50000');
      expect(values[26], contains('폐기물관리법'));
      expect(values[26], contains('차종 무관'));
      // 확정 열(범칙금_과태료, 인덱스 8)은 원문 그대로 — 추정과 섞지 않는다.
      expect(values[8], '과태료');
    });

    test('비대상이면 끝 두 열이 비어 있다', () {
      for (final report in [
        _confirmedAmount(),
        _penalty(),
        _warning(),
        _nonTargetCategory(),
        _noFineInfo(),
      ]) {
        final values = excelExportRowValues(report);
        expect(values.length, 27);
        expect(values[25], '', reason: report.fineInfo);
        expect(values[26], '', reason: report.fineInfo);
      }
    });
  });
}
