// L-3: 알림 카드 아래 메타 행(신고번호 + 시각)이 360dp·2.0배에서 넘치던 문제.
// 긴 신고번호와 "yyyy-MM-dd HH:mm:ss" 시각이 함께 있어도 넘치지 않고 둘 다 끝까지 보여야 한다.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/notification_item.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/notifications_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ui_harness.dart';

const _reportNumber = 'SPP-2609-2206517';
const _timestamp = '2026-10-04 12:34:56';

class _StandaloneProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;
}

/// 저장소를 읽지 않고 고정 목록을 돌려주는 기록. "신고 결과" 탭(1)에서 시작한다.
class _FixedHistory extends NotificationHistoryProvider {
  _FixedHistory(this._fixed);
  final List<NotificationItem> _fixed;

  @override
  List<NotificationItem> get items => _fixed;

  @override
  int get preferredTabIndex => 1;

  @override
  Future<void> load({bool notify = true}) async {}
}

Future<List<FlutterErrorDetails>> _pump(
  WidgetTester tester,
  double scale,
) async {
  const width = 360.0, height = 800.0;
  tester.view.physicalSize = const Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final report = _StandaloneProvider();
  final history = _FixedHistory([
    const NotificationItem(
      id: 'n1',
      kind: NotificationItemKind.report,
      title: '처리상태 변경',
      body: '신고 처리상태가 바뀌었습니다.',
      reportNumber: _reportNumber,
      timestamp: _timestamp,
      isRead: false,
      extraData: {'처리상태': '처리중', '범칙금_과태료': '과태료: 40,000원'},
    ),
  ]);
  addTearDown(report.dispose);
  addTearDown(history.dispose);

  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: report),
          ChangeNotifierProvider<NotificationHistoryProvider>.value(
            value: history,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(width, height),
              textScaler: TextScaler.linear(scale),
            ),
            child: const NotificationsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scale in uiTextScales) {
    testWidgets('알림 카드 메타 행: 넘치지 않고 신고번호·시각이 다 보인다 (360dp, x$scale)', (
      tester,
    ) async {
      final errors = await _pump(tester, scale);
      expect(errors, isEmpty, reason: describeErrors(errors));
      for (final value in [_reportNumber, _timestamp]) {
        final finder = find.text(value);
        expect(finder, findsOneWidget, reason: value);
        final paragraph = tester.renderObject<RenderParagraph>(finder);
        expect(paragraph.didExceedMaxLines, isFalse, reason: value);
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(0), reason: value);
        expect(rect.right, lessThanOrEqualTo(360), reason: value);
      }
    });
  }
}
