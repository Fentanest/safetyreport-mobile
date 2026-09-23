import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_management_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/theme/sr_colors.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';

Report _report({String category = 'traffic'}) {
  return Report(
    id: '1234567890',
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
    category: category,
  );
}

class _RecordingReportProvider extends ReportProvider {
  _RecordingReportProvider({
    required this.categoryBeforeRefresh,
    this.categoryAfterRefresh,
  });

  final String? categoryBeforeRefresh;
  final String? categoryAfterRefresh;
  final List<String> fetchedCategories = [];
  bool refreshedAll = false;
  bool? forceRefreshValue;

  @override
  String? findCategory(Report report) {
    return refreshedAll ? categoryAfterRefresh : categoryBeforeRefresh;
  }

  @override
  Future<void> fetchCategoryReports(String category) async {
    fetchedCategories.add(category);
  }

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {
    refreshedAll = true;
    forceRefreshValue = forceRefresh;
  }
}

void main() {
  test('안전신문고 앱 URI에 최신 배포본의 openpage 파라미터를 포함한다', () {
    final uri = buildSafetyReportAppUri('1234567890');

    expect(uri.scheme, 'appsafetyreport');
    expect(uri.host, 'view');
    expect(uri.queryParameters, {
      'openpage': 'true',
      'c_no': '1234567890',
      'ext_path': 'M_MY_01_S0002.html',
      'mem_yn': 'Y',
    });
  });

  test('알림 상세에서 검색 진입 전 해당 카테고리를 새로 고친다', () async {
    final provider = _RecordingReportProvider(categoryBeforeRefresh: 'traffic');
    addTearDown(provider.dispose);

    final category = await provider.refreshCategoryForReport(_report());

    expect(category, 'traffic');
    expect(provider.fetchedCategories, ['traffic']);
    expect(provider.refreshedAll, isFalse);
  });

  test('카테고리가 없는 알림은 전체 목록을 강제 갱신해 다시 찾는다', () async {
    final provider = _RecordingReportProvider(
      categoryBeforeRefresh: null,
      categoryAfterRefresh: 'parking',
    );
    addTearDown(provider.dispose);

    final category = await provider.refreshCategoryForReport(
      _report(category: ''),
    );

    expect(category, 'parking');
    expect(provider.refreshedAll, isTrue);
    expect(provider.forceRefreshValue, isTrue);
  });

  // 원래 목적(선택/미선택 구분, 글자 가독성, 표시선 가시성)을 유지하면서 고정 색 대신
  // 실제 렌더된 색과 배경의 대비를 라이트/다크 모두 검사한다(docs/testing/ui-test-plan.md §3).
  for (final brightness in Brightness.values) {
    testWidgets('신고관리 상단 탭은 선택/미선택이 구분되고 대비 기준을 만족한다 (${brightness.name})', (
      tester,
    ) async {
      final provider = ReportProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.build(brightness),
            home: const ReportManagementScreen(),
          ),
        ),
      );
      await tester.pump();

      Color textColor(String label) => tester
          .renderObject<RenderParagraph>(find.text(label))
          .text
          .style!
          .color!;

      final theme = Theme.of(tester.element(find.byType(TabBar)));
      final appBarBackground = tester
          .widget<Material>(
            find
                .descendant(
                  of: find.byType(AppBar),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color!;
      final indicator = theme.tabBarTheme.indicator as BoxDecoration;
      final pill = Color.alphaBlend(indicator.color!, appBarBackground);

      final selected = textColor('별점');
      final unselected = textColor('감시 목록');

      expect(selected, isNot(equals(unselected)));
      expect(contrastRatio(selected, pill), greaterThanOrEqualTo(4.5));
      expect(
        contrastRatio(unselected, appBarBackground),
        greaterThanOrEqualTo(4.5),
      );
      // 선택 표시(알약)는 배경과 구분돼야 한다(비텍스트 3:1).
      expect(contrastRatio(pill, appBarBackground), greaterThanOrEqualTo(3.0));

      // 탭 이동: 누른 탭이 선택 색으로 바뀐다.
      await tester.tap(find.text('중복 신고'));
      // 탭 전환 애니메이션은 여러 프레임에 걸쳐 진행된다.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(textColor('중복 신고'), selected);
      expect(textColor('별점'), unselected);
    });
  }
}
