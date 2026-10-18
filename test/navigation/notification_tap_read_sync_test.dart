// 2026-10-18 사용자 보고:
// 1) 신고 A 푸시를 눌러 앱에 들어오면 A 가 아니라 마지막 변경 건(하단 알림의 "상세 보기")이나 변경 결과 시트가 떴다.
// 2) 하단 남색 알림(SnackBar)·시스템 푸시·알림 기록의 읽음이 따로 놀아 하나씩 다 눌러야 사라졌다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/navigation/native_call_router.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _OpenGate extends CommunityGate {
  _OpenGate() : super(configStatus: () => 'ok');

  @override
  bool get canEnter => true;

  @override
  bool get isChecked => true;

  @override
  Future<GateState> refreshNow({bool silent = false}) async => state;

  @override
  void startPolling() {}
}

class _QuietProvider extends ReportProvider {
  final DashboardStats _fixed = DashboardStats.fromJson({'total': 1});

  @override
  DashboardStats? get stats => _fixed;

  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> fetchWatchlistNumbers() async {}

  @override
  Future<void> checkAutoSyncOnResume() async {}
}

const _perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

Map<String, dynamic> _change(String number, {int syncedAt = 1000}) => {
  'notification_kind': 'report',
  'change_type': '처리변경',
  'ID': 'id-$number',
  '신고번호': number,
  '신고명': '신고 $number',
  '처리상태': '수용',
  '처리기관': '기관',
  '범칙금_과태료': '',
  'synced_at': syncedAt,
};

void main() {
  late List<MethodCall> permCalls;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    permCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, (call) async {
          permCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, null);
    StandaloneAuthService.stopKeepAlive();
    NativeCallRouter.instance.resetForTest();
  });

  Future<void> settle(WidgetTester tester, {int steps = 6}) async {
    await tester.pump();
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<NotificationHistoryProvider> pumpMain(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
    });
    final provider = _QuietProvider();
    await provider.init();
    final gate = _OpenGate();
    addTearDown(gate.dispose);
    final history = NotificationHistoryProvider();
    NativeCallRouter.instance.resetForTest();
    NativeCallRouter.instance.install();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider<CommunityGate>.value(value: gate),
          ChangeNotifierProvider<NotificationHistoryProvider>.value(
            value: history,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const MainNavigationScreen(),
        ),
      ),
    );
    await settle(tester);
    return history;
  }

  /// WsService 가 백그라운드에서 적는 것과 같은 상태: 대기 변경 묶음 + 마지막 푸시 하나(foreground_event).
  Future<void> queueBackgroundChanges(
    List<Map<String, dynamic>> changes,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppPrefsKeys.pendingCrawlChanges,
      jsonEncode(changes),
    );
    final last = changes.last;
    await prefs.setString(
      AppPrefsKeys.foregroundEvent,
      jsonEncode({
        'title': '🔄 처리 변경 — ${last['신고명']}',
        'body': '신고번호: ${last['신고번호']}',
        'type': 'crawl_changes',
        'payload_json': jsonEncode(last),
      }),
    );
  }

  Future<void> tapPush(Map<String, dynamic> payload) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _perm.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('navigateToTab', {
              'tab': 4,
              'event_type': 'crawl_changes',
              'payload_json': jsonEncode(payload),
            }),
          ),
          (_) {},
        );
  }

  void resume(WidgetTester tester) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  List<String> openedDetails(WidgetTester tester) => tester
      .widgetList<ReportDetailSheet>(find.byType(ReportDetailSheet))
      .map((w) => w.report.reportNumber)
      .toList();

  List<List<String>> cancelledReports() => permCalls
      .where((c) => c.method == 'cancelChangeNotifications')
      .map(
        (c) => ((c.arguments as Map)['report_numbers'] as List).cast<String>(),
      )
      .toList();

  for (final order in ['tap-then-resume', 'resume-then-tap']) {
    testWidgets('tapping push A opens A only ($order)', (tester) async {
      await pumpMain(tester);
      final a = _change('R-A', syncedAt: 1000);
      final b = _change('R-B', syncedAt: 2000); // 마지막 변경(예전 하단 알림이 가리키던 건)
      await queueBackgroundChanges([a, b]);

      if (order == 'tap-then-resume') {
        await tapPush(a);
        resume(tester);
      } else {
        resume(tester);
        await tester.pump(const Duration(milliseconds: 100));
        await tapPush(a);
      }
      await settle(tester, steps: 8);

      expect(openedDetails(tester), ['R-A'], reason: '누른 알림의 신고만 연다');
      expect(
        find.textContaining('변경 결과'),
        findsNothing,
        reason: '결과 시트가 덮지 않는다',
      );
      expect(find.byType(SnackBar), findsNothing, reason: '마지막 변경 하단 알림 없음');
      expect(
        cancelledReports().any((r) => r.contains('R-A')),
        isTrue,
        reason: 'A 의 시스템 푸시를 지운다',
      );
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('resume without a tap still shows the changes sheet once and no '
      'duplicate snack for the same changes', (tester) async {
    await pumpMain(tester);
    await queueBackgroundChanges([_change('R-A'), _change('R-B')]);
    resume(tester);
    await settle(tester, steps: 8);
    expect(find.textContaining('변경 결과 2건'), findsOneWidget);
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: '시트에 있는 변경을 하단 알림으로 또 띄우지 않는다',
    );
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('bottom notice closes when its report is read elsewhere and '
      'never piles up', (tester) async {
    final history = await pumpMain(tester);
    final c = _change('R-C');
    await history.addFromServerResults([c]); // 기록에는 이미 있음(대기 변경 없음)
    final prefs = await SharedPreferences.getInstance();
    Future<void> writeEvent() => prefs.setString(
      AppPrefsKeys.foregroundEvent,
      jsonEncode({
        'title': '🔄 처리 변경 — 신고 R-C',
        'body': '신고번호: R-C',
        'type': 'crawl_changes',
        'payload_json': jsonEncode(c),
      }),
    );

    await writeEvent();
    resume(tester);
    await settle(tester, steps: 3);
    expect(find.byType(SnackBar), findsOneWidget);

    // 알림 기록(다른 경로)에서 읽으면 하단 알림도 닫히고 푸시도 지운다.
    permCalls.clear();
    await history.markReportRead('R-C');
    await settle(tester, steps: 3);
    expect(find.byType(SnackBar), findsNothing);
    expect(cancelledReports().any((r) => r.contains('R-C')), isTrue);

    // 읽지 않은 다른 건은 버튼이 있어도 4초 뒤 스스로 닫히고, 복귀를 반복해도 쌓이지 않는다.
    final d = _change('R-D');
    await history.addFromServerResults([d]);
    for (var i = 0; i < 3; i++) {
      await prefs.setString(
        AppPrefsKeys.foregroundEvent,
        jsonEncode({
          'title': '🔄 처리 변경 — 신고 R-D',
          'type': 'crawl_changes',
          'payload_json': jsonEncode(d),
        }),
      );
      resume(tester);
      await settle(tester, steps: 3);
    }
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, isFalse);
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(SnackBar), findsNothing, reason: '자동으로 닫힌다');
    await tester.pump(const Duration(seconds: 6));
  });
}
