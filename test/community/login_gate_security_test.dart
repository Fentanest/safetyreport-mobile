import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/community/cloud_availability.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'fake_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final scenario in [
    'active',
    'consent_none',
    'suspended',
    'kakao_missing',
    'failure',
    'cancel',
    'back',
  ]) {
    test('existing account: $scenario remains verified during login', () async {
      final dir = await Directory.systemTemp.createTemp('gate-security-');
      final store = await CommunityStore.open(
        path: '${dir.path}/community.db',
        factory: databaseFactoryFfi,
      );
      final cfg = testAuthConfig();
      final secure = <String, String>{
        CommunityAuthService.sessionKey: jsonEncode({
          'v': 1,
          'access_token': 'fixture-old',
          'refresh_token': 'fixture-old-refresh',
          'expires_at':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'user_id': 'fixture-old-user',
          'display_name': 'fixture',
          'state': 'active',
          'kakao_id': '12345',
        }),
      };
      final old = secure[CommunityAuthService.sessionKey];
      FlutterSecureStorage.setMockInitialValues(secure);
      SharedPreferences.setMockInitialValues({});
      CloudAvailability.shared = CloudAvailability(store, cfg.supabaseUrl);
      final server = FakeAccountServer(
        status: () => statusJson(
          consentState: scenario == 'consent_none' ? 'none' : 'active',
          contributor: scenario == 'suspended' ? 'suspended' : 'active',
          kakao: scenario != 'kakao_missing',
        ),
      );
      var authRequests = 0;
      final auth = CommunityAuthService(
        config: cfg,
        client: MockClient((_) async {
          authRequests++;
          return http.Response('{}', 500);
        }),
        launcher: (_) async => true,
      );
      await auth.load();
      final gate = CommunityGate(
        config: cfg,
        auth: auth,
        store: store,
        accountClient: server.accountClient(),
        appMode: () => 'server',
      );
      try {
        await gate.refreshNow();
        final before = server.statusCalls;
        await auth.startLogin();
        gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await gate.refreshNow();
        expect(
          server.statusCalls,
          greaterThan(before),
          reason: 'existing account must still query server status',
        );
        expect(
          gate.canEnter,
          !['consent_none', 'suspended', 'kakao_missing'].contains(scenario),
        );
        expect(authRequests, 0);
        expect(secure[CommunityAuthService.sessionKey], old);
        if (scenario == 'failure') {
          expect(
            await auth.handleCallbackLink(
              'com.fentanest.mysafetyreport://auth/callback?error=server_error',
            ),
            CommunityLinkOutcome.failed,
          );
        }
        if (scenario == 'cancel') {
          expect(
            await auth.handleCallbackLink(
              'com.fentanest.mysafetyreport://auth/callback?error=access_denied',
            ),
            CommunityLinkOutcome.cancelled,
          );
        }
        if (scenario == 'back') {
          await auth.cancelPendingLogin();
          expect(
            await auth.handleCallbackLink(
              'com.fentanest.mysafetyreport://auth/callback?code=fixture-old-code',
            ),
            CommunityLinkOutcome.ignoredNoPending,
          );
        }
        await gate.refreshNow();
        gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await gate.refreshNow();
        expect(await CloudAvailability.shared!.coolingDown(), false);
        expect(secure[CommunityAuthService.sessionKey], old);
        expect(
          gate.canEnter,
          !['consent_none', 'suspended', 'kakao_missing'].contains(scenario),
        );
      } finally {
        gate.dispose();
        CloudAvailability.shared = null;
        await store.db.close();
        await dir.delete(recursive: true);
      }
    });
  }
  for (final action in ['failure', 'cancel', 'back']) {
    test(
      'new login $action + repeated resume stays closed without cooldown',
      () async {
        final dir = await Directory.systemTemp.createTemp('gate-new-exit-');
        final store = await CommunityStore.open(
          path: '${dir.path}/community.db',
          factory: databaseFactoryFfi,
        );
        final cfg = testAuthConfig();
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        CloudAvailability.shared = CloudAvailability(store, cfg.supabaseUrl);
        var calls = 0;
        final raw = MockClient((_) async {
          calls++;
          return http.Response('{}', 500);
        });
        final auth = CommunityAuthService(
          config: cfg,
          client: raw,
          launcher: (_) async => true,
        );
        final gate = CommunityGate(
          config: cfg,
          auth: auth,
          store: store,
          httpClient: raw,
          appMode: () => 'server',
        );
        try {
          await gate.refreshNow();
          await auth.startLogin();
          if (action == 'back') {
            await auth.cancelPendingLogin();
          } else {
            expect(
              await auth.handleCallbackLink(
                'com.fentanest.mysafetyreport://auth/callback?error=${action == 'cancel' ? 'access_denied' : 'server_error'}',
              ),
              action == 'cancel'
                  ? CommunityLinkOutcome.cancelled
                  : CommunityLinkOutcome.failed,
            );
          }
          for (var i = 0; i < 3; i++) {
            gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
            await gate.refreshNow();
          }
          expect(gate.canEnter, false);
          expect(gate.canBrowse, false);
          expect(await CloudAvailability.shared!.coolingDown(), false);
          expect(calls, 0);
          expect(
            await auth.handleCallbackLink(
              'com.fentanest.mysafetyreport://auth/callback?code=fixture-late-code',
            ),
            CommunityLinkOutcome.ignoredNoPending,
          );
        } finally {
          gate.dispose();
          CloudAvailability.shared = null;
          raw.close();
          await store.db.close();
          await dir.delete(recursive: true);
        }
      },
    );
  }
}
