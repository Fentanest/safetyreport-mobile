import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/duplicate_group.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/duplicate_group_detail_sheet.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';

import '../support/ui_harness.dart';

const _labels = [
  '신고번호',
  '내부 ID',
  '신고일',
  '답변일',
  '처리기관',
  '담당자',
  '과태료/범칙금',
  '벌점',
  '차량번호',
  '위반법규',
  '위반장소',
  '발생일자',
  '별점',
  '별점사유',
];

Report _report({bool longValues = false}) => Report.fromJson({
  'ID': 'id',
  '신고번호': 'SPP-1',
  '신고명': '간격 검수',
  '신고일': '10/12',
  '답변일': '10/13',
  '처리기관': longValues ? '첫째\n둘째\n셋째\n넷째' : '기관',
  '담당자': longValues ? '첫째\n둘째\n셋째\n넷째' : '담당',
  '범칙금_과태료': '4만원',
  '벌점': '10점',
  '차량번호': '12가3456',
  '위반법규': longValues ? '도로교통법에 따른 보행자 보호의무와 안전운전 의무 위반' : '법규',
  '위반장소': longValues ? '경기도 부천시 원미구 길주로 아주 긴 건물명 상가 앞 교차로' : '장소',
  '발생일자': '10/11',
  '별점': 3,
  '별점사유': '사유',
  'category': 'traffic',
});

Future<void> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  required double width,
  required double scale,
  required Report report,
  bool duplicate = false,
}) async {
  tester.view.physicalSize = Size(width, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final provider = ReportProvider();
  addTearDown(provider.dispose);
  final member = DuplicateMember.fromJson({
    'ID': report.id,
    '신고번호': report.reportNumber,
    '신고명': report.name,
    '처리상태': '수용',
    '처리기관': report.agency,
    'is_representative': true,
  });
  final group = DuplicateGroup(
    groupId: 'fixture',
    status: DuplicateStatuses.confirmedDuplicate,
    representativeMode: RepresentativeModes.auto,
    representativeId: report.id,
    memberCount: 0,
    note: '',
    members: const [],
    representative: member,
  );
  await tester.pumpWidget(
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.build(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: duplicate
              ? Builder(
                  builder: (context) => TextButton(
                    onPressed: () =>
                        showDuplicateGroupDetailSheet(context, group),
                    child: const Text('중복 상세 열기'),
                  ),
                )
              : ReportDetailSheet(report: report),
        ),
      ),
    ),
  );
  if (duplicate) await tester.tap(find.text('중복 상세 열기'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'overflow를 포함한 렌더 오류가 없어야 한다');
}

Finder _row(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Container)).first;

void _checkRows(WidgetTester tester, List<String> labels, {bool equal = true}) {
  final rects = labels.map((label) => tester.getRect(_row(label))).toList();
  for (var i = 0; i < labels.length; i++) {
    final row = rects[i];
    expect(row.height, greaterThanOrEqualTo(kMinInteractiveDimension));
    if (equal) expect(row.height, closeTo(rects.first.height, 0.01));
    if (i > 0) {
      expect(
        row.top,
        closeTo(rects[i - 1].bottom, 0.01),
        reason: '행 사이 추가 여백 없음',
      );
    }
    final content = find
        .descendant(of: _row(labels[i]), matching: find.byType(Row))
        .first;
    expect(
      tester.getRect(content).center.dy,
      closeTo(row.center.dy, 0.01),
      reason: '세로 가운데 배치',
    );
    for (final text
        in find
            .descendant(of: _row(labels[i]), matching: find.byType(Text))
            .evaluate()) {
      final textRect = tester.getRect(find.byWidget(text.widget));
      expect(row.contains(textRect.topLeft), isTrue);
      expect(textRect.right, lessThanOrEqualTo(row.right));
      expect(textRect.bottom, lessThanOrEqualTo(row.bottom));
      final widget = text.widget as Text;
      expect(widget.maxLines, anyOf(isNull, 1));
      if (widget.maxLines == 1) {
        // 라벨의 실제 글자 폭이 할당된 폭 안에 들어가야 한다(ellipsis 방지).
        final painter = TextPainter(
          text: TextSpan(
            text: widget.data,
            style: DefaultTextStyle.of(text).style.merge(widget.style),
          ),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(text),
        )..layout();
        expect(painter.width, lessThanOrEqualTo(textRect.width));
        painter.dispose();
      }
    }
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [360.0, 412.0]) {
      for (final scale in uiTextScales) {
        final caseName = '${brightness.name} · ${width}dp · $scale배';
        testWidgets('신고 정보 높이·간격·터치 영역: $caseName', (tester) async {
          final semantics = tester.ensureSemantics();
          await _pump(
            tester,
            brightness: brightness,
            width: width,
            scale: scale,
            report: _report(),
          );
          _checkRows(tester, _labels);
          if (scale == 1) {
            expect(tester.getSize(_row(_labels.first)).height, 48);
          }
          for (final label in ['담당자', '차량번호', '위반법규', '위반장소']) {
            final tap = find
                .ancestor(of: find.text(label), matching: find.byType(InkWell))
                .first;
            expect(tester.getRect(tap), tester.getRect(_row(label)));
            expect(tester.getSize(tap).height, greaterThanOrEqualTo(48));
          }
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          semantics.dispose();
        });
        testWidgets('긴 신고 값은 해당 행만 확장: $caseName', (tester) async {
          await _pump(
            tester,
            brightness: brightness,
            width: width,
            scale: scale,
            report: _report(longValues: true),
          );
          _checkRows(tester, _labels, equal: false);
          final normal = tester.getRect(_row('답변일'));
          final agency = tester.getRect(_row('처리기관'));
          final manager = tester.getRect(_row('담당자'));
          expect(agency.height, greaterThan(normal.height));
          expect(
            manager.height,
            closeTo(agency.height, 0.01),
            reason: '일반/링크 여러 줄의 내부 여백도 동일',
          );
          expect(tester.getRect(_row('벌점')).height, normal.height);
          for (final label in ['처리기관', '담당자']) {
            final values = find.descendant(
              of: _row(label),
              matching: find.text('첫째\n둘째\n셋째\n넷째'),
            );
            final value = tester.getRect(values);
            final row = tester.getRect(_row(label));
            expect(row.bottom - value.bottom, closeTo(2, 0.01));
          }
        });
        testWidgets('중복 상세 대표 신고 높이·간격: $caseName', (tester) async {
          await _pump(
            tester,
            brightness: brightness,
            width: width,
            scale: scale,
            report: _report(),
            duplicate: true,
          );
          _checkRows(tester, ['ID', '신고번호', '신고명', '처리상태', '처리기관']);
          expect(tester.getSize(_row('ID')).height, 48);
        });
        testWidgets('중복 상세 긴 값 행만 확장: $caseName', (tester) async {
          await _pump(
            tester,
            brightness: brightness,
            width: width,
            scale: scale,
            report: _report(longValues: true),
            duplicate: true,
          );
          _checkRows(tester, [
            'ID',
            '신고번호',
            '신고명',
            '처리상태',
            '처리기관',
          ], equal: false);
          expect(tester.getSize(_row('ID')).height, 48);
          expect(tester.getSize(_row('처리기관')).height, greaterThan(48));
        });
      }
    }
  }
}
