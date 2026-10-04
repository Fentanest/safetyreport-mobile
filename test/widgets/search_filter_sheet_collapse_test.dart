// SQ-U27: 상세 검색 시트가 입력칸 14개 이상을 한 번에 나열하고, "신고번호"와 "ID"가 같은 # 아이콘이었다.
// 주요 4칸(차량번호·신고번호·처리상태·처리기관)만 펼치고 나머지는 "조건 더 보기"에 접는다.
// 접힌 칸에 값이 있으면 처음부터 펼친다. 모든 조건과 지역 조건 API(initialFilter/onApply, SQ-U02)는 그대로다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/widgets/search_filter_sheet.dart';

void main() {
  Future<void> openSheet(
    WidgetTester tester,
    ReportProvider provider, {
    ReportFilter? initialFilter,
    ValueChanged<ReportFilter>? onApply,
  }) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSearchFilterSheet(
                context,
                provider: provider,
                initialFilter: initialFilter,
                onApply: onApply,
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  final more = find.byKey(const ValueKey('search-filter-more'));

  List<String> labels(WidgetTester tester) => tester
      .widgetList<TextField>(find.byType(TextField))
      .map((f) => f.decoration?.labelText)
      .whereType<String>()
      .toList();

  testWidgets('collapsed by default: only the 4 main fields', (tester) async {
    final p = ReportProvider();
    addTearDown(p.dispose);
    await openSheet(tester, p);
    expect(labels(tester), ['차량번호', '신고번호', '처리기관']);
    expect(find.text('처리상태'), findsOneWidget);
    for (final hidden in ['ID', '담당자', '신고명', '위반장소', '별점', '신고일']) {
      expect(find.text(hidden), findsNothing, reason: '$hidden 은 접혀 있다');
    }
    expect(find.text('조건 더 보기'), findsOneWidget);

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(
      labels(tester),
      containsAll(<String>[
        'ID',
        '담당자',
        '과태료/범칙금',
        '신고명',
        '위반장소',
        '신고내용',
        '처리내용',
        '보완횟수',
        '별점사유',
      ]),
    );
    for (final shown in ['별점', '위반법규', '만족도 조사 여부', '신고일', '발생일', '답변일']) {
      expect(find.text(shown), findsWidgets, reason: shown);
    }
    expect(find.text('조건 접기'), findsOneWidget);
  });

  testWidgets('ID has its own icon, distinct from 신고번호', (tester) async {
    final p = ReportProvider();
    addTearDown(p.dispose);
    await openSheet(tester, p);
    await tester.tap(more);
    await tester.pumpAndSettle();
    IconData? iconOf(String label) {
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, label),
      );
      return (field.decoration!.prefixIcon! as Icon).icon;
    }

    expect(iconOf('신고번호'), Icons.tag);
    expect(iconOf('ID'), isNot(iconOf('신고번호')));
  });

  testWidgets('auto-expanded when a hidden field already has a value', (
    tester,
  ) async {
    final p = ReportProvider();
    addTearDown(p.dispose);
    p.setFilter(const ReportFilter(manager: '담당자 가'));
    await openSheet(tester, p);
    expect(find.widgetWithText(TextField, '담당자'), findsOneWidget);
    expect(find.text('담당자 가'), findsOneWidget);
    expect(find.text('조건 접기'), findsOneWidget);
  });

  testWidgets('a date range alone also auto-expands (local initialFilter)', (
    tester,
  ) async {
    final p = ReportProvider();
    addTearDown(p.dispose);
    await openSheet(
      tester,
      p,
      initialFilter: const ReportFilter(reportDateStart: '2026-01-01'),
      onApply: (_) {},
    );
    expect(find.text('2026-01-01'), findsOneWidget);
  });

  testWidgets('collapsing keeps hidden values; apply returns every field via '
      'onApply without touching the shared filter', (tester) async {
    final p = ReportProvider();
    addTearDown(p.dispose);
    ReportFilter? applied;
    await openSheet(
      tester,
      p,
      initialFilter: const ReportFilter(carNumber: '12가3456'),
      onApply: (f) => applied = f,
    );
    expect(find.text('조건 더 보기'), findsOneWidget, reason: '주요 칸만 값이 있다');
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'ID'), '900001');
    await tester.enterText(find.widgetWithText(TextField, '위반장소'), '서울');
    await tester.tap(more); // 접기
    await tester.pumpAndSettle();
    expect(find.text('조건 더 보기 (적용 중)'), findsOneWidget);

    await tester.tap(find.text('검색 적용'));
    await tester.pumpAndSettle();
    expect(
      applied,
      const ReportFilter(carNumber: '12가3456', id: '900001', location: '서울'),
    );
    expect(p.filter, const ReportFilter(), reason: '공용 필터는 그대로');
  });
}
