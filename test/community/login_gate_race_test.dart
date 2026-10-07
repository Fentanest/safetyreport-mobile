import 'dart:async';
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
import 'package:safetyreport/services/community_auth_config.dart';
import 'package:safetyreport/services/community_auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final mode in ['standalone', 'server']) {
    for (final initial in ['new', 'reauth']) {
      for (final point in [
        'awaitingBrowser',
        'exchanging',
        'confirmRequired',
      ]) {
        test(
          '$mode/$initial/$point healthy upstream + resumed must not create cooldown',
          () async {
            final dir = await Directory.systemTemp.createTemp('gate-race-');
            final store = await CommunityStore.open(
              path: '${dir.path}/community.db',
              factory: databaseFactoryFfi,
            );
            final secure = <String, String>{};
            if (initial == 'reauth') {
              secure[CommunityAuthService.sessionKey] = jsonEncode({
                'v': 1,
                'access_token': '',
                'refresh_token': '',
                'expires_at': 0,
                'user_id': 'fixture-old',
                'display_name': 'fixture',
                'state': 'reauth_required',
                'kakao_id': '12345',
              });
            }
            final previous = secure[CommunityAuthService.sessionKey];
            FlutterSecureStorage.setMockInitialValues(secure);
            SharedPreferences.setMockInitialValues({});
            const url = 'https://fixture.supabase.test';
            final config = CommunityAuthConfig.validate(
              url: url,
              key: 'sb_publishable_fixture',
            );
            final now = DateTime.fromMillisecondsSinceEpoch(
              DateTime.now().millisecondsSinceEpoch,
              isUtc: true,
            );
            CloudAvailability.shared = CloudAvailability(
              store,
              url,
              now: () => now,
            );
            final tokenStarted = Completer<void>();
            final releaseToken = Completer<void>();
            final calls = <String>[];
            final client = MockClient((r) async {
              calls.add(r.url.path);
              if (r.url.path.endsWith('/token')) {
                tokenStarted.complete();
                await releaseToken.future;
                return http.Response(
                  '{"access_token":"fixture","refresh_token":"fixture","expires_in":3600}',
                  200,
                );
              }
              if (r.url.path.endsWith('/user')) {
                return http.Response(
                  '{"id":"fixture-user","identities":[{"provider":"kakao","id":"12345"}]}',
                  200,
                );
              }
              return http.Response('', 204);
            });
            final auth = CommunityAuthService(
              config: config,
              client: client,
              launcher: (_) async => true,
            );
            final gate = CommunityGate(
              config: config,
              auth: auth,
              store: store,
              httpClient: client,
              appMode: () => mode,
            );
            try {
              await gate.refreshNow();
              expect(await CloudAvailability.shared!.coolingDown(), false);
              await auth.startLogin();
              Future<CommunityLinkOutcome>? callback;
              if (point != 'awaitingBrowser') {
                callback = auth.handleCallbackLink(
                  'com.fentanest.mysafetyreport://auth/callback?code=fixture-code',
                );
                await tokenStarted.future;
                if (point == 'confirmRequired') {
                  releaseToken.complete();
                  expect(await callback, CommunityLinkOutcome.confirmRequired);
                }
              }
              expect(auth.state.value.phase.name, point);
              gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
              await gate.refreshNow();
              expect(await CloudAvailability.shared!.coolingDown(), false);
              expect(await CloudAvailability.shared!.deadline(), null);
              expect(gate.canEnter, false);
              expect(
                gate.state.state,
                initial == 'new' ? 'kakao_required' : 'kakao_reauth_required',
              );
              gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
              await gate.refreshNow();
              expect(await CloudAvailability.shared!.coolingDown(), false);
              if (point == 'exchanging') {
                expect(calls, ['/auth/v1/token']);
                releaseToken.complete();
                expect(await callback, CommunityLinkOutcome.confirmRequired);
                expect(
                  auth.state.value.phase,
                  CommunityAccountPhase.confirmRequired,
                );
                expect(calls, ['/auth/v1/token', '/auth/v1/user']);
                expect(secure[CommunityAuthService.sessionKey], previous);
                expect(
                  await auth.handleCallbackLink(
                    'com.fentanest.mysafetyreport://auth/callback?code=fixture-code',
                  ),
                  CommunityLinkOutcome.ignoredDuplicate,
                );
                expect(calls, ['/auth/v1/token', '/auth/v1/user']);
              }
              debugPrint(
                'RACE $mode/$initial/$point upstreamRequests=${calls.length} allActualHTTP=200 cooldown=none userHTTP=${calls.where((p) => p.endsWith("/user")).length}',
              );
              await gate.refreshNow();
            } finally {
              gate.dispose();
              CloudAvailability.shared = null;
              client.close();
              await store.db.close();
              await dir.delete(recursive: true);
            }
          },
        );
      }
    }
  }
}
