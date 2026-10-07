// Isolated Android fixture. No production login, consent, or report APIs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/cloud_availability.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/widgets/cloud_delay_banner.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/app_theme_mode.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/cloud_unavailable_screen.dart';
import 'package:safetyreport/screens/community_onboarding_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/permission_service.dart';
import '../test/community/fake_account.dart';

class _Auth extends StubAuthService {
  final launched = <Uri>[];
  @override
  Future<CommunityStartOutcome> startLogin() => CommunityAuthService(
    config: testAuthConfig(),
    launcher: (uri) async {
      launched.add(uri);
      return true;
    },
  ).startLogin();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('cloud outage, direct Kakao retry and native notification stop', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      debugPrint('SR_CAPTURE:$name');
      final ack = File('${support.path}/$name.ack');
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!await ack.exists()) {
        if (DateTime.now().isAfter(deadline)) throw TimeoutException(name);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await ack.delete();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); // Only the offlineqa test application sandbox.
    await prefs.setString(AppPrefsKeys.appMode, 'standalone');
    await prefs.setString(AppPrefsKeys.standaloneUsername, 'fixture-account');
    setUpSecureStorage();
    LocalDbService.currentKakaoId = () async => '910001';
    final auth = _Auth()..setPhase(CommunityAccountPhase.connected);
    final server = FakeAccountServer()..statusFailures = 100;
    final provider = ReportProvider();
    await provider.init();
    final store = await CommunityStore.open(
      path: '${support.path}/fixture-community.db',
    );
    var cloudTime = DateTime.now();
    CloudAvailability.shared = CloudAvailability(
      store,
      testAuthConfig().supabaseUrl,
      now: () => cloudTime,
    );
    final gate = CommunityGate(
      store: store,
      config: testAuthConfig(),
      auth: auth,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => 'standalone',
      checkDataOwner: ownerOk,
      officialAccountId: () async => 'fixture-account',
    );
    await gate.refreshNow();
    expect(gate.canBrowse, isTrue);
    expect(gate.canEnter, isFalse);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider.value(value: gate),
          ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
        ],
        child: const SafetyReportApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MainNavigationScreen), findsOneWidget);
    expect(find.byType(CloudUnavailableScreen), findsNothing);
    expect(find.byType(CommunityOnboardingScreen), findsNothing);
    expect(find.byType(CloudDelayBanner), findsOneWidget);
    expect(find.textContaining('후 다시 확인'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '재시도'), findsNothing);
    await capture('01-cloud-offline-dashboard');
    await tester.tap(find.text('신고내역').last);
    await tester.pumpAndSettle();
    expect(find.byType(MainNavigationScreen), findsOneWidget);
    await capture('02-cloud-offline-reports');

    await provider.setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    await capture('07-cloud-offline-dark');

    // URL-only mock launcher: no external browser or production auth traffic.
    // Exercise the actual account-card retry and production PKCE URL builder.
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityOnboardingScreen(
          auth: auth,
          gate: gate,
          accountClient: server.accountClient(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await capture('03-connected-account-retry');
    await tester.tap(find.widgetWithText(OutlinedButton, '재시도').first);
    await tester.pumpAndSettle();
    expect(auth.launched, isEmpty);
    debugPrint('SR_ASSERT:browser-retry-honors-shared-cooldown');
    cloudTime = cloudTime.add(const Duration(seconds: 301));
    await tester.tap(find.widgetWithText(OutlinedButton, '재시도').first);
    await tester.pumpAndSettle();
    expect(auth.launched, hasLength(1));
    final uri = auth.launched.single;
    expect(uri.host, 'proj.supabase.test');
    expect(uri.path, '/auth/v1/authorize');
    expect(uri.queryParameters['provider'], 'kakao');
    expect(
      uri.queryParameters['redirect_to'],
      'com.fentanest.mysafetyreport://auth/callback',
    );
    expect(uri.queryParameters['code_challenge'], hasLength(43));
    expect(uri.queryParameters['code_challenge_method'], 's256');
    debugPrint('SR_ASSERT:direct-kakao-retry-authorize-path-and-PKCE-pass');
    await tester.pumpWidget(const SizedBox.shrink());
    gate.dispose();
    CloudAvailability.shared = null;
    provider.dispose();

    // A local HTTP fixture makes native WS reconnect quickly without production traffic.
    final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fixture.listen((request) async {
      if (request.uri.path.endsWith('/server/version')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'version': '3.0.0',
            'protocol_version': 3,
            'supported_client_protocols': [3],
          }),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    await prefs.setString(AppPrefsKeys.appMode, 'server');
    await prefs.setString(
      AppPrefsKeys.baseUrl,
      'http://127.0.0.1:${fixture.port}',
    );
    await prefs.setString(AppPrefsKeys.apiKey, 'fixture-only');
    await prefs.setString(
      CommunityGate.gateCacheKey,
      jsonEncode({
        'state': 'ok',
        'owner': 'fixture',
        'verified_at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    expect(await PermissionService.startWsService(), isTrue);
    await Future<void>.delayed(const Duration(seconds: 12));
    await capture('04-native-service-started');
    await prefs.setString(
      CommunityGate.gateCacheKey,
      jsonEncode({
        'state': 'ok',
        'owner': 'fixture',
        'verified_at': DateTime.now()
            .subtract(const Duration(minutes: 11))
            .millisecondsSinceEpoch,
      }),
    );
    await Future<void>.delayed(const Duration(seconds: 15));
    expect(await PermissionService.startWsService(), isFalse);
    await capture('05-expired-gate-service-stopped');
    await Future<void>.delayed(const Duration(seconds: 12));
    await capture('06-no-repeated-notification');
    await PermissionService.stopWsService();
    await fixture.close(force: true);
    await LocalDbService.closeDb();
    debugPrint('SR_ASSERT:OFFLINE_SCENARIOS_PASS');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
