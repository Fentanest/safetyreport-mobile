import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/widgets/search_filter_sheet.dart';

void main() {
  for (final changeNames in [false, true]) {
    testWidgets('검색 시트는 이름을 유지할 때만 드릴다운 식별 조건을 유지 ($changeNames)', (tester) async {
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      const original = ReportFilter(agency: '(구)옛기관', agencyKey: 'src:9999993:옛기관',
          manager: '김민수', managerExact: true);
      ReportFilter? applied;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
        builder: (context) => TextButton(onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => SearchFilterSheet(provider: provider, initialFilter: original,
              onApply: (f) => applied = f),
        ), child: const Text('열기')),
      ))));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      if (changeNames) {
        for (final pair in [('처리기관', '다른기관'), ('담당자', '다른담당자')]) {
          final field = find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == pair.$1);
          await tester.ensureVisible(field);
          await tester.enterText(field, pair.$2);
        }
      }
      await tester.ensureVisible(find.text('검색 적용'));
      await tester.tap(find.text('검색 적용'));
      await tester.pumpAndSettle();
      expect(applied, isNotNull);
      expect(applied!.agencyKey, changeNames ? '' : original.agencyKey);
      expect(applied!.managerExact, !changeNames);
      expect(provider.filter, const ReportFilter());
    });
  }
}
