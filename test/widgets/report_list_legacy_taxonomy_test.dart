// Astra #5(2026-10-11): 새 앱이 구서버(3분류, report_taxonomy 를 모름)에 연결하면 안전신고·생활불편
// 탭이 `/reports/safety|living` 을 요청해 400 오류를 내면 안 된다 — 짧은 안내 문구로 대체하고,
// 기타 탭은 평소대로(접힌 목록) 조회한다. 신서버(5분류)는 그대로 네 분류 모두 조회한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';

/// 구서버: 안전신고·생활불편을 요청하면 실제 서버처럼 예외(400 Invalid category)를 던진다.
/// 테스트가 실패 없이 통과하면 그 요청이 실제로 없었다는 뜻이다.
class _LegacyServerProvider extends ReportProvider {
  final List<String> requested = [];

  @override
  AppMode get appMode => AppMode.server;

  @override
  bool get supportsFiveCategories => false;

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async {
    requested.add(category);
    if (category == 'safety' || category == 'living') {
      throw Exception('페이지 조회 실패: 400'); // 구서버라면 실제로 이렇게 실패한다.
    }
    return (reports: const <Report>[], total: 0);
  }

  @override
  Future<void> fetchDuplicateReports() async {}
}

/// 신서버(5분류): 안전신고·생활불편도 평소대로 조회된다.
class _FiveCategoryServerProvider extends ReportProvider {
  final List<String> requested = [];

  @override
  AppMode get appMode => AppMode.server;

  @override
  bool get supportsFiveCategories => true;

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async {
    requested.add(category);
    return (reports: const <Report>[], total: 0);
  }

  @override
  Future<void> fetchDuplicateReports() async {}
}

Future<void> _pump(WidgetTester tester, ReportProvider provider) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.build(Brightness.light),
        home: const ReportListScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    '구서버: 안전신고·생활불편 탭은 안내 문구, 기타 탭은 평소대로 조회하고 400 을 내지 않는다',
    (tester) async {
      final provider = _LegacyServerProvider();
      await _pump(tester, provider);

      await tester.tap(find.text('안전신고').first);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('서버를 업데이트하면 안전신고·생활불편을 따로 볼 수 있습니다'),
        findsOneWidget,
      );

      await tester.tap(find.text('생활불편').first);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('서버를 업데이트하면 안전신고·생활불편을 따로 볼 수 있습니다'),
        findsOneWidget,
      );

      // 기타 탭은 평소대로(구서버에서는 이미 안전신고·생활불편이 접혀 있는 분류).
      await tester.tap(find.text('기타').first);
      await tester.pumpAndSettle();
      expect(provider.requested, contains('other'));

      expect(provider.requested, isNot(contains('safety')));
      expect(provider.requested, isNot(contains('living')));
    },
  );

  testWidgets('신서버(5분류): 안전신고·생활불편 탭도 평소대로 조회한다', (tester) async {
    final provider = _FiveCategoryServerProvider();
    await _pump(tester, provider);

    await tester.tap(find.text('안전신고').first);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('서버를 업데이트하면'),
      findsNothing,
    );
    expect(provider.requested, contains('safety'));

    await tester.tap(find.text('생활불편').first);
    await tester.pumpAndSettle();
    expect(provider.requested, contains('living'));
  });
}
