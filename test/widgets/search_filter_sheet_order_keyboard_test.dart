import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/widgets/search_filter_sheet.dart';

void main() {
  Future<void> openSheet(WidgetTester tester, ReportProvider provider) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SearchFilterSheet(provider: provider),
              ),
              child: const Text('상세 검색 열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('상세 검색 열기'));
    await tester.pumpAndSettle();
  }

  // SQ-U27(2026-10-04): 주요 4칸(차량번호·신고번호·처리상태·처리기관)만 펼치고 나머지는 "조건 더 보기"에 접는다.
  // 펼친 뒤의 추가 조건은 통계표 공통 열 순서(담당자 → 과태료 → 별점)를 그대로 따른다.
  testWidgets('주요 4칸 다음 "조건 더 보기" 안에 ID·통계표 공통 항목이 나온다', (tester) async {
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await openSheet(tester, provider);
    List<String> labels() => tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.decoration?.labelText)
        .whereType<String>()
        .toList();
    expect(labels(), ['차량번호', '신고번호', '처리기관']);
    expect(
      tester.getTopLeft(find.text('신고번호')).dy,
      lessThan(tester.getTopLeft(find.text('처리상태')).dy),
    );
    expect(
      tester.getTopLeft(find.text('처리상태')).dy,
      lessThan(tester.getTopLeft(find.text('처리기관')).dy),
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('search-filter-more')),
    );
    await tester.tap(find.byKey(const ValueKey('search-filter-more')));
    await tester.pumpAndSettle();
    expect(labels().take(6).toList(), [
      '차량번호',
      '신고번호',
      '처리기관',
      'ID',
      '담당자',
      '과태료/범칙금',
    ]);
    expect(
      tester.getTopLeft(find.text('처리상태')).dy,
      lessThan(tester.getTopLeft(find.text('별점')).dy),
    );
    expect(
      tester.getTopLeft(find.text('별점')).dy,
      lessThan(tester.getTopLeft(find.widgetWithText(TextField, '신고명')).dy),
    );
  });

  testWidgets('체크 항목을 탭한 뒤 Enter를 누르면 선택값으로 검색을 적용한다', (tester) async {
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await openSheet(tester, provider);
    final statusField = find
        .ancestor(of: find.text('처리상태'), matching: find.byType(InkWell))
        .first;
    await tester.ensureVisible(statusField);
    await tester.tap(statusField);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('수용'));
    await tester.tap(find.text('수용'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(provider.filter.statuses, ['수용']);
    expect(find.byType(SearchFilterSheet), findsNothing);
  });

  testWidgets('키보드로 체크 항목에 초점을 맞춰 Enter를 누르면 선택 후 검색한다', (tester) async {
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await openSheet(tester, provider);
    final statusField = find
        .ancestor(of: find.text('처리상태'), matching: find.byType(InkWell))
        .first;
    await tester.ensureVisible(statusField);
    await tester.tap(statusField);
    await tester.pumpAndSettle();
    final option = find.text('수용');
    await tester.ensureVisible(option);
    Focus.of(tester.element(option)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(provider.filter.statuses, ['수용']);
    expect(find.byType(SearchFilterSheet), findsNothing);
  });

  testWidgets('ID 입력 뒤 검색 키로 적용된다', (tester) async {
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await openSheet(tester, provider);
    await tester.ensureVisible(
      find.byKey(const ValueKey('search-filter-more')),
    );
    await tester.tap(find.byKey(const ValueKey('search-filter-more')));
    await tester.pumpAndSettle();
    final idField = find.widgetWithText(TextField, 'ID');
    await tester.ensureVisible(idField);
    await tester.enterText(idField, '90000011');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(provider.filter.id, '90000011');
    expect(find.byType(SearchFilterSheet), findsNothing);
  });
}
