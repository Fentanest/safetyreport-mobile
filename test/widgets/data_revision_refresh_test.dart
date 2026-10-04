// SQ-P02: 통계 탭 진입은 "데이터 변경"이 아니다. 데이터가 그대로면 탭을 오가도 목록·통계를 다시 조회하지 않는다.
// 실제 변경(dataRevision 증가)이 오면 보이는 화면은 한 번 다시 읽고, 숨은 탭은 다시 보일 때 한 번 읽는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/selfhost_client_fixture.dart';

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

/// 대시보드 요약·감시 목록은 이 시험의 대상이 아니다(요청 수를 섞지 않게 막는다).
class _ClientProvider extends ReportProvider {
  final DashboardStats _fixed = DashboardStats.fromJson({'total': 1});

  @override
  DashboardStats? get stats => _fixed;

  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> fetchWatchlistNumbers() async {}

  @override
  Future<void> fetchAppConfig() async {}
}

const _perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

void main() {
  setUp(() {
    resetSelfhostFixture();
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, (_) async => null);
  });

  tearDown(() {
    StatisticsScreen.clientStatsMaxAge = const Duration(seconds: 60);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_perm, null);
  });

  testWidgets(
    'tab switches without a data change issue no list or statistics requests',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'server',
        AppPrefsKeys.baseUrl: 'https://fixture.test',
        AppPrefsKeys.apiKey: 'synthetic',
      });
      final provider = _ClientProvider();
      await provider.init();
      final gate = _OpenGate();
      addTearDown(gate.dispose);

      var reportRequests = 0;
      var statsRequests = 0;
      Future<http.Response> handler(http.Request request) async {
        final path = request.url.path;
        if (path.startsWith('${ServerContract.apiPrefix}/reports/')) {
          reportRequests++;
          return http.Response(jsonEncode({'data': [], 'total': 3}), 200);
        }
        if (path == ServerContract.statsPath ||
            path == ServerContract.statsOverviewPath) {
          statsRequests++;
          return http.Response(jsonEncode({'data': <String, dynamic>{}}), 200);
        }
        if (path == ServerContract.sunwiPayloadPath) {
          return http.Response('{}', 404);
        }
        return http.Response(jsonEncode({'data': <String, dynamic>{}}), 200);
      }

      Future<void> settle() async {
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> tapTab(String label) async {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await settle();
      }

      await http.runWithClient(() async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<ReportProvider>.value(value: provider),
              ChangeNotifierProvider<CommunityGate>.value(value: gate),
              ChangeNotifierProvider(
                create: (_) => NotificationHistoryProvider(),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const MainNavigationScreen(),
            ),
          ),
        );
        await settle();

        await tapTab('신고내역');
        final listAfterFirstVisit = reportRequests;
        expect(listAfterFirstVisit, greaterThan(0));

        await tapTab('통계');
        final statsAfterFirstVisit = statsRequests;
        expect(statsAfterFirstVisit, greaterThan(0));
        // 숨은 신고내역 목록은 통계 탭 진입으로 다시 조회하지 않는다.
        expect(reportRequests, listAfterFirstVisit);

        await tapTab('신고내역');
        await tapTab('통계');
        await tapTab('대시보드');
        await tapTab('통계');
        expect(reportRequests, listAfterFirstVisit, reason: '목록 재조회 없음');
        expect(statsRequests, statsAfterFirstVisit, reason: '통계 HTTP 재요청 없음');

        // 실제 변경: 보이는 통계는 한 번 다시 읽고, 숨은 목록은 아직 읽지 않는다.
        provider.markDataChanged();
        await settle();
        expect(statsRequests, statsAfterFirstVisit * 2);
        expect(reportRequests, listAfterFirstVisit);

        // 숨은 목록은 다시 보일 때 한 번 읽는다. 그 뒤 탭을 오가도 더 읽지 않는다.
        await tapTab('신고내역');
        expect(reportRequests, listAfterFirstVisit * 2);
        await tapTab('통계');
        await tapTab('신고내역');
        expect(reportRequests, listAfterFirstVisit * 2);
        expect(statsRequests, statsAfterFirstVisit * 2);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }, () => selfhostMockClient(handler));
      provider.dispose();
    },
  );

  testWidgets(
    'Client statistics re-fetch on tab re-entry once older than the max age',
    (tester) async {
      // PC 쪽에서 변경 알림 없이 바뀐 자료를 놓치지 않는다. 기준 나이를 0으로 두면 재진입마다 다시 받는다.
      StatisticsScreen.clientStatsMaxAge = Duration.zero;
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'server',
        AppPrefsKeys.baseUrl: 'https://fixture.test',
        AppPrefsKeys.apiKey: 'synthetic',
      });
      final provider = _ClientProvider();
      await provider.init();
      final gate = _OpenGate();
      addTearDown(gate.dispose);

      var reportRequests = 0;
      var statsRequests = 0;
      Future<http.Response> handler(http.Request request) async {
        final path = request.url.path;
        if (path.startsWith('${ServerContract.apiPrefix}/reports/')) {
          reportRequests++;
          return http.Response(jsonEncode({'data': [], 'total': 3}), 200);
        }
        if (path == ServerContract.statsPath ||
            path == ServerContract.statsOverviewPath) {
          statsRequests++;
          return http.Response(jsonEncode({'data': <String, dynamic>{}}), 200);
        }
        if (path == ServerContract.sunwiPayloadPath) {
          return http.Response('{}', 404);
        }
        return http.Response(jsonEncode({'data': <String, dynamic>{}}), 200);
      }

      Future<void> settle() async {
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> tapTab(String label) async {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await settle();
      }

      await http.runWithClient(() async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<ReportProvider>.value(value: provider),
              ChangeNotifierProvider<CommunityGate>.value(value: gate),
              ChangeNotifierProvider(
                create: (_) => NotificationHistoryProvider(),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const MainNavigationScreen(),
            ),
          ),
        );
        await settle();

        await tapTab('신고내역');
        final listAfterFirstVisit = reportRequests;
        await tapTab('통계');
        final statsAfterFirstVisit = statsRequests;
        expect(statsAfterFirstVisit, greaterThan(0));

        await tapTab('대시보드');
        await tapTab('통계');
        expect(
          statsRequests,
          statsAfterFirstVisit * 2,
          reason: '오래된 Client 통계는 재진입 때 다시 받는다',
        );
        // 숨은 목록은 이 규칙과 무관하다.
        expect(reportRequests, listAfterFirstVisit);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }, () => selfhostMockClient(handler));
      provider.dispose();
    },
  );
}
