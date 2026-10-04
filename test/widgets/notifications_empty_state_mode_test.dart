// SQ-U08: 알림 빈 상태 문구는 모드에 맞춘다(Client=크롤링, Standalone=동기화).
// 하위 탭 이름 "크롤링 현황"은 제품 불변 항목이므로 두 모드 모두 그대로다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/notifications_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ModeProvider extends ReportProvider {
  _ModeProvider(this._mode);
  final AppMode _mode;

  @override
  AppMode get appMode => _mode;
}

Future<void> _pump(WidgetTester tester, AppMode mode) async {
  final report = _ModeProvider(mode);
  final history = NotificationHistoryProvider();
  addTearDown(report.dispose);
  addTearDown(history.dispose);
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
        home: const NotificationsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Standalone empty crawl-status tab speaks of 동기화', (
    tester,
  ) async {
    await _pump(tester, AppMode.standalone);
    expect(find.text('크롤링 현황'), findsOneWidget);
    expect(find.text('동기화 알림이 없습니다.'), findsOneWidget);
    expect(find.text('크롤링 알림이 없습니다.'), findsNothing);
    expect(find.textContaining('크롤링 시작/완료'), findsNothing);
  });

  testWidgets('Client empty crawl-status tab keeps 크롤링 wording', (
    tester,
  ) async {
    await _pump(tester, AppMode.server);
    expect(find.text('크롤링 현황'), findsOneWidget);
    expect(find.text('크롤링 알림이 없습니다.'), findsOneWidget);
    expect(find.text('크롤링 시작/완료 알림이 여기에 기록됩니다.'), findsOneWidget);
  });
}
