// SQ-U07: 테마가 모든 바텀시트에 손잡이를 켜므로(showDragHandle) 시트가 손잡이를 또 그리지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/duplicate_group.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/duplicate_group_detail_sheet.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:safetyreport/widgets/search_filter_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Report _report() => Report(
  id: '1',
  reportNumber: 'SPP-2608-0000001',
  name: '테스트 신고',
  date: '2026-08-14',
  responseDate: '2026-08-14',
  agency: '테스트 기관',
  manager: '담당자',
  status: '수용',
  result: '답변완료',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '도로교통법',
  location: '서울',
  occurrenceDate: '2026-08-13',
  occurrenceTime: '12:00',
  reportContent: '신고 내용',
  processContent: '처리 내용',
  category: 'traffic',
);

/// 손잡이 모양(가로 28~44, 세로 4)으로 칠해진 상자 수.
int _handleCount(WidgetTester tester) {
  final sheet = find.byType(BottomSheet);
  expect(sheet, findsOneWidget);
  final painted = <RenderDecoratedBox>{};
  for (final element
      in find
          .descendant(of: sheet, matching: find.byType(DecoratedBox))
          .evaluate()) {
    final ro = element.renderObject;
    if (ro is! RenderDecoratedBox || !ro.hasSize) continue;
    final s = ro.size;
    if (s.height > 3.5 && s.height < 4.5 && s.width >= 28 && s.width <= 44) {
      painted.add(ro);
    }
  }
  return painted.length;
}

Future<BuildContext> _host(WidgetTester tester, Brightness brightness) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness),
      home: Builder(
        builder: (context) {
          ctx = context;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );
  return ctx;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    testWidgets(
      'report detail sheet draws exactly one drag handle (${brightness.name})',
      (tester) async {
        final ctx = await _host(tester, brightness);
        showReportDetailSheet(ctx, _report());
        await tester.pumpAndSettle();
        expect(_handleCount(tester), 1);
      },
    );
  }

  testWidgets('duplicate group detail sheet draws exactly one drag handle', (
    tester,
  ) async {
    final ctx = await _host(tester, Brightness.light);
    showDuplicateGroupDetailSheet(
      ctx,
      DuplicateGroup.fromJson({'group_id': 'g1', 'members': const []}),
    );
    await tester.pumpAndSettle();
    expect(_handleCount(tester), 1);
  });

  testWidgets(
    'search filter sheet: one drag handle, kept below the status bar',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3;
      tester.view.padding = const FakeViewPadding(top: 72); // 24dp 상태 표시줄
      addTearDown(tester.view.reset);
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      final ctx = await _host(tester, Brightness.dark);
      showSearchFilterSheet(ctx, provider: provider);
      await tester.pumpAndSettle();
      expect(_handleCount(tester), 1);
      expect(
        tester.getTopLeft(find.byType(BottomSheet)).dy,
        greaterThanOrEqualTo(24),
        reason: '전체 높이 시트의 손잡이가 상태 표시줄 밑으로 들어가지 않는다',
      );
    },
  );

  testWidgets('sheets take the corner radius from the theme', (tester) async {
    final ctx = await _host(tester, Brightness.light);
    showReportDetailSheet(ctx, _report());
    await tester.pumpAndSettle();
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.shape, isNull, reason: '시트마다 모서리를 따로 주지 않는다');
    final theme = Theme.of(tester.element(find.byType(BottomSheet)));
    expect(
      theme.bottomSheetTheme.shape,
      const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.sheetRadius),
        ),
      ),
    );
    expect(theme.bottomSheetTheme.showDragHandle, isTrue);
  });
}
