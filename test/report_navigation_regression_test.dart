import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_management_screen.dart';
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

  testWidgets('신고관리 상단 탭은 선택/미선택 글자와 표시선이 밝게 보인다', (tester) async {
    final provider = ReportProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: const MaterialApp(home: ReportManagementScreen()),
      ),
    );
    await tester.pump();

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.labelColor, Colors.white);
    expect(tabBar.unselectedLabelColor, Colors.white70);
    expect(tabBar.indicatorColor, Colors.white);
    expect(tabBar.indicatorWeight, 3);
  });
}
