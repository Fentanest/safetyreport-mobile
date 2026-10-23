import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_sort.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/widgets/report_sort_button.dart';
import 'package:safetyreport/theme/app_theme.dart';

class _Client extends ReportProvider {
  @override
  List<Report> get duplicateReports => [
    for (final (plate, number, count) in [
      ('12가1111', '30', 3),
      ('12가1111', '20', 3),
      ('12가1111', '10', 3),
      ('12나2222', '09', 2),
      ('12나2222', '08', 2),
    ])
      Report.fromJson({
        'ID': number,
        '신고번호': number,
        '신고명': '신고 $number',
        '차량번호': plate,
        'total_count': count,
      }),
  ];
  @override
  List<Report> get filteredDuplicateReports => duplicateReports;
  @override
  Future<void> fetchDuplicateReports() async {}
  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (reports: <Report>[], total: 0);
}

void main() {
  for (final dark in [false, true]) {
    for (final large in [false, true]) {
      testWidgets(
        '360dp dark=$dark large=$large sheet order, direction and accessible label',
        (tester) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          var selected = ReportSort.defaults;
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.build(dark ? Brightness.dark : Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQueryData(
                  size: const Size(360, 800),
                  textScaler: TextScaler.linear(large ? 2 : 1),
                ),
                child: child!,
              ),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => Align(
                    alignment: Alignment.topRight,
                    child: ReportSortButton(
                      sort: selected,
                      onChanged: (v) => setState(() => selected = v),
                    ),
                  ),
                ),
              ),
            ),
          );
          final handle = tester.ensureSemantics();
          expect(find.bySemanticsLabel('정렬: 신고번호, 내림차순'), findsOneWidget);
          expect(
            tester
                .getSemantics(find.bySemanticsLabel('정렬: 신고번호, 내림차순'))
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
          await tester.tap(find.byKey(const Key('reportSortButton')));
          await tester.pumpAndSettle();
          final tiles = tester.widgetList<RadioListTile<ReportSortField>>(
            find.byType(RadioListTile<ReportSortField>),
          );
          expect(tiles.map((t) => t.value), ReportSortField.values.skip(1));
          await tester.ensureVisible(find.text('답변일'));
          await tester.tap(find.text('답변일'));
          await tester.pump();
          await tester.ensureVisible(find.text('오름차순'));
          await tester.tap(find.text('오름차순'));
          await tester.pump();
          await tester.ensureVisible(find.text('적용'));
          await tester.tap(find.text('적용'));
          await tester.pumpAndSettle();
          expect(
            selected,
            const ReportSort(
              field: ReportSortField.responseDate,
              ascending: true,
            ),
          );
          expect(find.text('답변일 ↑'), findsOneWidget);
          expect(find.bySemanticsLabel('정렬: 답변일, 오래된순'), findsOneWidget);
          expect(tester.takeException(), isNull);
          handle.dispose();
        },
      );
    }
  }
  testWidgets(
    'duplicate count first; screen persists and restores choice by mode and tab',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final p = _Client();
      addTearDown(p.dispose);
      Widget app() => ChangeNotifierProvider<ReportProvider>.value(
        value: p,
        child: const MaterialApp(home: ReportListScreen(initialTabIndex: 5)),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('신고번호 ↓'), findsOneWidget);
      await tester.tap(find.byKey(const Key('reportSortButton')));
      await tester.pumpAndSettle();
      final tiles = tester.widgetList<RadioListTile<ReportSortField>>(
        find.byType(RadioListTile<ReportSortField>),
      );
      expect(tiles.first.value, ReportSortField.duplicateCount);
      await tester.tap(find.text('중복횟수'));
      await tester.pump();
      await tester.ensureVisible(find.text('오름차순'));
      await tester.tap(find.text('오름차순'));
      await tester.pump();
      await tester.ensureVisible(find.text('적용'));
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(find.text('중복횟수 ↑'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('report_sort:server:5'), 'duplicateCount:asc');
      expect(prefs.getString('report_sort:standalone:5'), isNull);
      expect(prefs.getString('report_sort:server:0'), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('중복횟수 ↑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
