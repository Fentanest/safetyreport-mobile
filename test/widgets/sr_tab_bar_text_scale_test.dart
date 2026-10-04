// SQ-U04(하위 탭 막대): 360dp 폭에서 글자 1.0·1.3·2.0배일 때 하위 탭 이름이 잘리거나 넘치지 않는다.
// 탭 수·순서는 그대로이고, 다 들어가지 않으면 가로 스크롤 탭으로 바뀐다.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/notification_item.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/notifications_screen.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/screens/report_management_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ui_harness.dart';

class _Provider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (reports: <Report>[], total: 0);

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {}

  @override
  Future<void> fetchDuplicateReports() async {}

  @override
  Future<void> fetchWatchlistNumbers() async {}
}

/// 탭마다 읽지 않은 알림이 있어 배지가 붙은 상태(넘침이 처음 보인 조건).
class _History extends NotificationHistoryProvider {
  NotificationItem _item(String id, String kind) => NotificationItem(
    id: id,
    kind: kind,
    title: '알림 $id',
    body: '본문',
    reportNumber: '',
    timestamp: '2026-10-04 10:00',
    isRead: false,
  );

  @override
  List<NotificationItem> get items => [
    for (var i = 0; i < 12; i++) _item('c$i', NotificationItemKind.crawl),
    for (var i = 0; i < 3; i++) _item('r$i', NotificationItemKind.report),
    for (var i = 0; i < 128; i++) _item('s$i', NotificationItemKind.rating),
  ];

  @override
  Future<void> load({bool notify = true}) async {}
}

Future<List<FlutterErrorDetails>> _pump(
  WidgetTester tester,
  Widget screen,
  double scale,
) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final provider = _Provider();
  final history = _History();
  addTearDown(provider.dispose);
  addTearDown(history.dispose);
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider<NotificationHistoryProvider>.value(
            value: history,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: screen,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// 탭 막대 코드에서 난 오류만 고른다. 본문 넘침(목록 카드 등)은 다른 항목(SQ-U04 대시보드·U19 등)에서 다룬다.
List<FlutterErrorDetails> _tabBarErrors(List<FlutterErrorDetails> errors) =>
    errors.where((e) => e.toString().contains('sr_tab_bar.dart')).toList();

/// 탭 막대 안의 가로 Flex 가 자식보다 좁으면(= RIGHT OVERFLOWED) 실패.
void _expectNoFlexOverflow(WidgetTester tester, double scale) {
  final flexes = find.descendant(
    of: find.byType(TabBar),
    matching: find.byWidgetPredicate((w) => w is Flex),
  );
  for (final element in flexes.evaluate()) {
    final flex = element.renderObject! as RenderFlex;
    if (flex.direction != Axis.horizontal) continue;
    var extent = 0.0;
    var count = 0;
    flex.visitChildren((child) {
      extent += (child as RenderBox).size.width;
      count++;
    });
    extent += flex.spacing * (count > 1 ? count - 1 : 0);
    expect(
      extent,
      lessThanOrEqualTo(flex.size.width + 0.5),
      reason: '×$scale 에서 탭 안 Row 가 ${extent - flex.size.width}px 넘친다',
    );
  }
}

void _expectFullLabels(WidgetTester tester, List<String> labels, double scale) {
  final bar = find.byType(TabBar);
  expect(bar, findsOneWidget);
  _expectNoFlexOverflow(tester, scale);
  for (final label in labels) {
    final text = find.descendant(of: bar, matching: find.text(label));
    expect(text, findsOneWidget, reason: '탭 "$label" 이 있어야 한다');
    final paragraph = tester.renderObject<RenderParagraph>(text);
    final needed = paragraph.getMaxIntrinsicWidth(double.infinity);
    expect(
      paragraph.size.width,
      greaterThanOrEqualTo(needed - 0.5),
      reason: '×$scale 에서 "$label" 이 잘렸다',
    );
    expect(paragraph.didExceedMaxLines, isFalse);
  }
  // 탭 이름은 화면 폭보다 길지 않고 높이 안에 들어간다.
  final barRect = tester.getRect(bar);
  for (final label in labels) {
    final rect = tester.getRect(
      find.descendant(of: bar, matching: find.text(label)),
    );
    expect(rect.top, greaterThanOrEqualTo(barRect.top - 0.5));
    expect(rect.bottom, lessThanOrEqualTo(barRect.bottom + 0.5));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scale in uiTextScales) {
    testWidgets('신고관리 하위 탭 ×$scale', (tester) async {
      final errors = await _pump(tester, const ReportManagementScreen(), scale);
      expect(_tabBarErrors(errors), isEmpty, reason: describeErrors(errors));
      _expectFullLabels(tester, ['별점', '감시 목록', '중복 신고', '데이터 수정'], scale);
    });

    testWidgets('신고내역 하위 탭 ×$scale', (tester) async {
      final errors = await _pump(tester, const ReportListScreen(), scale);
      expect(_tabBarErrors(errors), isEmpty, reason: describeErrors(errors));
      _expectFullLabels(tester, ['교통위반', '주정차', '기타위반', '중복차량'], scale);
    });

    testWidgets('알림 하위 탭(읽지 않은 배지) ×$scale', (tester) async {
      final errors = await _pump(tester, const NotificationsScreen(), scale);
      expect(_tabBarErrors(errors), isEmpty, reason: describeErrors(errors));
      _expectFullLabels(tester, ['크롤링 현황', '신고 결과', '별점 주기'], scale);
    });
  }
}
