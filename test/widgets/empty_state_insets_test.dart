// SQ-U21: 목록 조회 오류가 빈 목록과 같은 문구로 보이고 재시도 버튼이 없었다 → 공용 SrEmptyState(오류 톤 + 다시 시도).
// SQ-U26: 가장자리까지 그리는 설정에서 push 화면 마지막 항목이 3버튼 내비 아래로, 가로 모드 본문이 컷아웃 아래로 들어갔다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/dashboard_screen.dart';
import 'package:safetyreport/screens/recent_answers_screen.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import 'package:safetyreport/widgets/sr_empty_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Report _report(int i) => Report(
  id: 'r$i',
  reportNumber: 'SPP-2609-000000$i',
  name: '최근 답변 신고 $i',
  date: '2026-09-2$i',
  responseDate: '2026-09-28',
  agency: '예시 기관',
  manager: '담당자',
  status: '수용',
  result: '',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '',
  location: '서울',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
);

/// Client 페이지 조회가 처음엔 실패하고 다음부터 빈 페이지를 돌려준다.
class _FlakyPageProvider extends ReportProvider {
  int reads = 0;
  bool fail = true;

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async {
    reads++;
    if (fail) throw Exception('네트워크 오류(합성)');
    return (reports: <Report>[], total: 0);
  }
}

class _RecentProvider extends ReportProvider {
  _RecentProvider({this.items = const [], this.error});
  List<Report> items;
  String? error;
  int refreshes = 0;

  @override
  List<Report> get recentAnswerReports => items;

  @override
  String? get errorMessage => error;

  @override
  Future<void> refreshSummaryAndRecentAnswers() async {
    refreshes++;
  }
}

class _DashProvider extends ReportProvider {
  final DashboardStats _fixed = DashboardStats.fromJson({'total': 3});

  @override
  DashboardStats? get stats => _fixed;

  @override
  bool get isLoading => false;

  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> refreshSummaryAndRecentAnswers() async {}

  @override
  List<Report> get recentAnswerReports => const [];
}

/// 3버튼 내비(아래 48) + 왼쪽 컷아웃(48)을 흉내 낸다.
void _fakeInsets(
  WidgetTester tester, {
  Size size = const Size(400, 800),
  double left = 48,
  double right = 0,
  double bottom = 48,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding(
    left: left,
    right: right,
    bottom: bottom,
  );
  tester.view.viewPadding = FakeViewPadding(
    left: left,
    right: right,
    bottom: bottom,
  );
  addTearDown(tester.view.reset);
}

Widget _app(ReportProvider provider, Widget home) =>
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(theme: AppTheme.light(), home: home),
    );

void main() {
  group('U21 shared empty/error state', () {
    testWidgets('paged list error is distinct from empty and retry reloads', (
      tester,
    ) async {
      final p = _FlakyPageProvider();
      addTearDown(p.dispose);
      await tester.pumpWidget(
        _app(
          p,
          const Scaffold(body: LocalPagedReportList(category: 'traffic')),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(p.reads, 1);
      expect(find.text('목록을 불러오지 못했습니다'), findsOneWidget);
      expect(find.textContaining('네트워크 오류(합성)'), findsOneWidget);
      expect(find.text('해당하는 신고가 없습니다'), findsNothing);
      expect(find.byKey(SrEmptyState.retryKey), findsOneWidget);

      p.fail = false;
      await tester.tap(find.byKey(SrEmptyState.retryKey));
      await tester.pump();
      await tester.pump();

      expect(p.reads, 2, reason: '다시 시도는 같은 페이지를 다시 읽는다');
      expect(find.text('목록을 불러오지 못했습니다'), findsNothing);
      expect(find.text('해당하는 신고가 없습니다'), findsOneWidget);
      expect(find.byKey(SrEmptyState.retryKey), findsNothing);
    });

    testWidgets('recent answers preview error shows retry that refreshes', (
      tester,
    ) async {
      final p = _RecentProvider(error: '서버 응답 없음(합성)');
      addTearDown(p.dispose);
      await tester.pumpWidget(_app(p, const RecentAnswersScreen()));
      await tester.pump();
      final initial = p.refreshes; // 진입 시 한 번 새로 고친다.

      expect(find.text('최근 답변을 불러오지 못했습니다'), findsOneWidget);
      await tester.tap(find.byKey(SrEmptyState.retryKey));
      await tester.pump();
      expect(p.refreshes, initial + 1);

      p.error = null;
      p.notifyListeners();
      await tester.pump();
      expect(find.text('최근 답변 미리보기가 없습니다'), findsOneWidget);
      expect(find.byKey(SrEmptyState.retryKey), findsNothing);
    });
  });

  group('U26 system bar insets', () {
    testWidgets('settings: last item clears the 3-button nav and the cutout', (
      tester,
    ) async {
      _fakeInsets(tester);
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'standalone',
        AppPrefsKeys.standaloneUsername: 'demo',
      });
      PackageInfo.setMockInitialValues(
        appName: 'safetyreport',
        packageName: 'x',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(perm, (_) async => false);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(perm, null),
      );
      final p = _DemoProvider();
      addTearDown(p.dispose);
      await tester.pumpWidget(_app(p, const SettingsScreen()));
      await tester.pump();

      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -30000),
      );
      await tester.pumpAndSettle();
      final last = tester.getRect(find.text('홈페이지 바로가기'));
      expect(last.bottom, lessThanOrEqualTo(800 - 48), reason: '내비 바 위');
      final firstCard = tester.getRect(find.byType(Card).last);
      expect(firstCard.left, greaterThanOrEqualTo(48), reason: '컷아웃 오른쪽');
    });

    testWidgets('recent answers: last card clears the nav bar', (tester) async {
      _fakeInsets(tester);
      final p = _RecentProvider(
        items: [for (var i = 0; i < 8; i++) _report(i)],
      );
      addTearDown(p.dispose);
      await tester.pumpWidget(_app(p, const RecentAnswersScreen()));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -10000));
      await tester.pumpAndSettle();
      final last = tester.getRect(find.text('최근 답변 신고 7'));
      expect(last.bottom, lessThanOrEqualTo(800 - 48));
      expect(
        tester.getRect(find.text('최근 답변 신고 7')).left,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('dashboard landscape body respects left/right insets', (
      tester,
    ) async {
      _fakeInsets(
        tester,
        size: const Size(900, 400),
        left: 48,
        right: 48,
        bottom: 0,
      );
      final p = _DashProvider();
      addTearDown(p.dispose);
      await tester.pumpWidget(_app(p, const DashboardScreen()));
      await tester.pump();
      final body = find.descendant(
        of: find.byType(SingleChildScrollView).first,
        matching: find.byType(Card),
      );
      expect(body, findsWidgets);
      for (final element in body.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.left, greaterThanOrEqualTo(48));
        expect(rect.right, lessThanOrEqualTo(900 - 48));
      }
    });
  });
}

class _DemoProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;

  @override
  bool get isStandaloneDemo => true;

  @override
  Future<void> refreshAll() async {}
}
