// SQ-U20: 아이콘 버튼은 스크린리더 이름(tooltip)과 48dp 이상 터치 영역을 가진다.
// Flutter 접근성 지침(androidTapTargetGuideline·labeledTapTargetGuideline)을 몇 화면에 건다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/notifications_screen.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/screens/report_management_screen.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ClientProvider extends ReportProvider {
  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (reports: <Report>[], total: 0);

  @override
  Future<void> fetchCategoryReports(String category) async {}

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {}

  @override
  Future<void> fetchDuplicateReports() async {}
}

class _DemoProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;

  @override
  bool get isStandaloneDemo => true;

  @override
  Future<void> refreshAll() async {}
}

const _perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'safetyreport',
      packageName: 'x',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, (_) async => false);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, null);
  });

  Future<void> pump(
    WidgetTester tester,
    ReportProvider provider,
    Widget home, {
    Size size = const Size(412, 915),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: home),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> expectGuidelines(WidgetTester tester) async {
    final handle = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  }

  testWidgets('신고내역 with condition chips', (tester) async {
    final p = _ClientProvider();
    addTearDown(p.dispose);
    p.setFilter(const ReportFilter(agency: '예시 기관', carNumber: '12가3456'));
    await pump(tester, p, const ReportListScreen());
    await expectGuidelines(tester);
  });

  testWidgets('신고관리 (별점 + 데이터 수정)', (tester) async {
    final p = _ClientProvider();
    addTearDown(p.dispose);
    await pump(tester, p, const ReportManagementScreen());
    await expectGuidelines(tester);
    await tester.tap(find.text('데이터 수정'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await expectGuidelines(tester);
  });

  testWidgets('알림', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final p = _ClientProvider();
    addTearDown(p.dispose);
    await pump(tester, p, const NotificationsScreen());
    await expectGuidelines(tester);
  });

  testWidgets('설정 (Standalone demo)', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'demo',
    });
    final p = _DemoProvider();
    addTearDown(p.dispose);
    await pump(tester, p, const SettingsScreen(), size: const Size(412, 4000));
    await expectGuidelines(tester);
  });

  testWidgets('상세 시트 링크 줄(담당자·차량번호·위반장소)은 48dp 이상', (tester) async {
    tester.view.physicalSize = const Size(360, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final report = Report(
      id: 'tap',
      reportNumber: 'SPP-2610-0000001',
      name: '터치 영역 검수 신고',
      date: '2026-04-23',
      responseDate: '2026-04-24',
      agency: '예시 교통 담당 기관',
      manager: '담당자 가',
      status: '수용',
      result: '',
      fineInfo: '',
      penaltyPoints: '',
      carNumber: '12가3456',
      law: '도로교통법',
      location: '서울 예시구',
      occurrenceDate: '2026-04-23',
      occurrenceTime: '17:45',
      reportContent: '',
      processContent: '',
      category: 'traffic',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: ReportDetailSheet(report: report)),
      ),
    );
    await tester.pump();
    for (final value in ['담당자 가', '12가3456', '서울 예시구']) {
      final ink = find
          .ancestor(of: find.text(value), matching: find.byType(InkWell))
          .first;
      expect(
        tester.getSize(ink).height,
        greaterThanOrEqualTo(48),
        reason: '$value 줄',
      );
    }
  });
}
