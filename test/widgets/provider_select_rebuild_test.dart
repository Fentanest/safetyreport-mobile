// SQ-P07: 화면이 쓰지 않는 Provider 값이 바뀌어도(다른 화면용 신호) 대시보드·신고내역 탭은 다시 그리지 않는다.
// debugOnRebuildDirtyWidget 으로 알림 뒤 다시 빌드된 위젯 종류를 센다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/dashboard_screen.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _QuietProvider extends ReportProvider {
  final DashboardStats _fixed = DashboardStats.fromJson({'total': 3});
  int pageReads = 0;

  @override
  DashboardStats? get stats => _fixed;

  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> fetchWatchlistNumbers() async {}

  @override
  Future<void> fetchDuplicateReports() async {}

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async {
    pageReads++;
    return (reports: <Report>[], total: 0);
  }
}

void main() {
  for (final screen in ['dashboard', 'reports']) {
    testWidgets('unrelated provider notifications do not rebuild $screen', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'server',
        AppPrefsKeys.baseUrl: 'https://fixture.test',
        AppPrefsKeys.apiKey: 'synthetic',
      });
      final provider = _QuietProvider();
      addTearDown(provider.dispose);
      await provider.init();
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            home: screen == 'dashboard'
                ? const DashboardScreen()
                : const ReportListScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final reads = provider.pageReads;

      const watched = {
        'DashboardScreen',
        'ReportListScreen',
        'LocalPagedReportList',
        'SyncStatusCard',
        'SyncActionButton',
        'ReloginRequiredBanner',
      };
      final rebuilt = <String>[];
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final name = element.widget.runtimeType.toString();
        if (watched.contains(name)) rebuilt.add(name);
      };
      try {
        // 파일 화면·전국 현황용 신호 — 이 화면들이 쓰는 값이 아니다.
        provider.bumpFilesRefresh();
        provider.bumpSunwiRefresh();
        await tester.pumpAndSettle();
        expect(rebuilt, isEmpty);
        expect(provider.pageReads, reads);

        // 쓰는 값이 바뀌면 다시 그린다(대시보드: 동기화 중, 신고내역: 검색 조건).
        if (screen == 'dashboard') {
          provider.setSyncing(true);
          await tester.pump();
          expect(rebuilt, containsAll(['SyncStatusCard', 'SyncActionButton']));
          provider.setSyncing(false);
        } else {
          provider.setFilter(const ReportFilter(name: '합성'));
          await tester.pump();
          expect(rebuilt, contains('ReportListScreen'));
        }
        await tester.pump(const Duration(seconds: 1));
      } finally {
        debugOnRebuildDirtyWidget = null;
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
