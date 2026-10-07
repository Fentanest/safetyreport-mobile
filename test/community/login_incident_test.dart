import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/community/cloud_availability.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/community_auth_config.dart';
import 'package:safetyreport/services/community_auth_service.dart';

const url = 'https://fixture.supabase.test';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final existing in [false, true]) {
    for (final scenario in [
      'network',
      'timeout',
      '500',
      '503',
      '401',
      '403',
      '404',
      'missing_id',
      'bad_json',
      'bad_id_type',
      'missing_kakao',
      'ok',
      '401_logout503',
      'slow200',
      'background503',
    ]) {
      test('${existing ? "existing" : "new"}/$scenario', () async {
        final dir = await Directory.systemTemp.createTemp('login-fixture-');
        final store = await CommunityStore.open(
          path: '${dir.path}/community.db',
          factory: databaseFactoryFfi,
        );
        var now = DateTime.utc(2026, 10, 7);
        var launched = 0;
        var recovered = false;
        final secure = <String, String>{};
        if (existing) {
          secure[CommunityAuthService.sessionKey] = jsonEncode({
            'v': 1,
            'access_token': 'fixture-old',
            'refresh_token': 'fixture-old-refresh',
            'expires_at':
                now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
                1000,
            'user_id': 'fixture-user',
            'display_name': 'fixture',
            'has_email': false,
            'state': 'active',
            'kakao_id': '12345',
          });
        }
        final old = secure[CommunityAuthService.sessionKey];
        FlutterSecureStorage.setMockInitialValues(secure);
        SharedPreferences.setMockInitialValues({});
        CloudAvailability.shared = CloudAvailability(
          store,
          url,
          now: () => now,
        );
        final calls = <String>[];
        final client = MockClient((r) async {
          expect(r.url.origin, url);
          calls.add(r.url.path);
          if (r.url.path.endsWith('/token')) {
            if (scenario == 'background503' && !recovered) {
              final bg = CloudHttpClient(
                MockClient((_) async => http.Response('{}', 503)),
              );
              await bg.post(
                Uri.parse('$url/functions/v1/community-account/status'),
              );
              bg.close();
            }
            return http.Response(
              jsonEncode({
                'access_token': 'fixture-access',
                'refresh_token': 'fixture-refresh',
                'expires_in': 3600,
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/logout')) {
            return http.Response('', scenario == '401_logout503' ? 503 : 204);
          }
          if (r.url.path.endsWith('/user')) {
            if (recovered) {
              return http.Response(
                '{"id":"fixture-user","identities":[{"provider":"kakao","id":"12345"}]}',
                200,
              );
            }
            if (scenario == 'network') {
              throw http.ClientException('fixture disconnected');
            }
            if (scenario == 'timeout') {
              throw TimeoutException('fixture timeout');
            }
            if (scenario == 'slow200') {
              await Future<void>.delayed(const Duration(milliseconds: 80));
            }
            if (scenario == '401_logout503') return http.Response('{}', 401);
            final status = int.tryParse(scenario);
            if (status != null) return http.Response('{}', status);
            if (scenario == 'missing_id') return http.Response('{}', 200);
            if (scenario == 'bad_json') {
              return http.Response('<html>fixture</html>', 200);
            }
            if (scenario == 'bad_id_type') {
              return http.Response('{"id":7}', 200);
            }
            return http.Response(
              jsonEncode({
                'id': 'fixture-user',
                'identities': scenario == 'missing_kakao'
                    ? []
                    : [
                        {
                          'provider': 'kakao',
                          'id': '12345',
                          'identity_data': {'provider_id': '12345'},
                        },
                      ],
              }),
              200,
            );
          }
          fail('unexpected endpoint');
        });
        final svc = CommunityAuthService(
          config: CommunityAuthConfig.validate(
            url: url,
            key: 'sb_publishable_fixture',
          ),
          client: client,
          storage: const FlutterSecureStorage(),
          now: () => now,
          timeout: scenario == 'slow200'
              ? const Duration(milliseconds: 20)
              : const Duration(seconds: 1),
          launcher: (_) async {
            launched++;
            return true;
          },
        );
        try {
          expect(await svc.startLogin(), CommunityStartOutcome.launched);
          final firstPending = secure[CommunityAuthService.pendingLoginKey];
          final outcome = await svc.handleCallbackLink(
            'com.fentanest.mysafetyreport://auth/callback?code=fixture-code',
          );
          final success = ['ok', 'missing_kakao'].contains(scenario);
          expect(
            outcome,
            success
                ? CommunityLinkOutcome.confirmRequired
                : CommunityLinkOutcome.failed,
          );
          expect(
            secure.containsKey(CommunityAuthService.pendingLoginKey),
            false,
          );
          expect(
            secure.containsKey(CommunityAuthService.consumedCallbackKey),
            true,
          );
          expect(secure[CommunityAuthService.sessionKey], old);
          if (success) {
            expect(
              svc.state.value.phase,
              CommunityAccountPhase.confirmRequired,
            );
            expect(
              svc.state.value.candidate!.kakaoId,
              scenario == 'missing_kakao' ? null : '12345',
            );
          } else {
            expect(
              svc.state.value.notice,
              '계정 정보를 확인하지 못했습니다. 로그인을 다시 시작해 주세요.',
            );
            expect(
              svc.state.value.phase,
              existing
                  ? CommunityAccountPhase.connected
                  : CommunityAccountPhase.disconnected,
            );
          }
          final cooldown = [
            'network',
            'timeout',
            '500',
            '503',
            '401_logout503',
            'background503',
          ].contains(scenario);
          expect(await CloudAvailability.shared!.coolingDown(), cooldown);
          if (cooldown) {
            expect(
              await CloudAvailability.shared!.deadline(),
              now.add(const Duration(seconds: 300)),
            );
          }
          final before = calls.length;
          final retry = await svc.startLogin();
          expect(
            retry,
            cooldown
                ? CommunityStartOutcome.coolingDown
                : CommunityStartOutcome.launched,
          );
          expect(calls.length, before);
          expect(launched, cooldown ? 1 : 2);
          if (cooldown) {
            expect(
              svc.state.value.notice,
              '서버 연결이 지연되고 있습니다. 상단 안내의 재확인 시간까지 기다려 주세요.',
            );
            now = now.add(const Duration(seconds: 300));
            expect(await svc.startLogin(), CommunityStartOutcome.launched);
            expect(
              secure[CommunityAuthService.pendingLoginKey],
              isNot(firstPending),
            );
            final retryCount = calls.length;
            expect(
              await svc.handleCallbackLink(
                'com.fentanest.mysafetyreport://auth/callback?code=fixture-code',
              ),
              CommunityLinkOutcome.ignoredDuplicate,
            );
            expect(calls.length, retryCount);
            recovered = true;
            expect(
              await svc.handleCallbackLink(
                'com.fentanest.mysafetyreport://auth/callback?code=fixture-new-code',
              ),
              CommunityLinkOutcome.confirmRequired,
            );
            expect(await CloudAvailability.shared!.coolingDown(), false);
            expect(secure[CommunityAuthService.sessionKey], old);
          }
          if (scenario == 'slow200') {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          debugPrint(
            'RESULT ${existing ? "existing" : "new"}/$scenario outcome=${outcome.name} cooldown=$cooldown retry=${retry.name} networkCalls=${calls.length}',
          );
        } finally {
          CloudAvailability.shared = null;
          client.close();
          await store.db.close();
          await dir.delete(recursive: true);
        }
      });
    }
  }
  test('production timeouts: outer15s precedes transport32s cooldown', () async {
    final dir = await Directory.systemTemp.createTemp('login-timing-');
    final store = await CommunityStore.open(
      path: '${dir.path}/community.db',
      factory: databaseFactoryFfi,
    );
    final now = DateTime.utc(2026, 10, 7);
    FlutterSecureStorage.setMockInitialValues({});
    CloudAvailability.shared = CloudAvailability(store, url, now: () => now);
    final stalled = Completer<http.Response>();
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/token')) {
        return http.Response(
          '{"access_token":"fixture","refresh_token":"fixture","expires_in":3600}',
          200,
        );
      }
      if (r.url.path.endsWith('/user')) return stalled.future;
      return http.Response('', 204);
    });
    final svc = CommunityAuthService(
      config: CommunityAuthConfig.validate(
        url: url,
        key: 'sb_publishable_fixture',
      ),
      client: client,
      launcher: (_) async => true,
    );
    try {
      await svc.startLogin();
      final clock = Stopwatch()..start();
      expect(
        await svc.handleCallbackLink(
          'com.fentanest.mysafetyreport://auth/callback?code=fixture-stalled',
        ),
        CommunityLinkOutcome.failed,
      );
      expect(svc.state.value.notice, startsWith('계정 정보를 확인하지 못했습니다.'));
      expect(await CloudAvailability.shared!.coolingDown(), false);
      debugPrint(
        'TIMING outer timeout ${clock.elapsed.inSeconds}s: account message, cooldown=false',
      );
      await Future<void>.delayed(const Duration(seconds: 18));
      expect(await CloudAvailability.shared!.coolingDown(), true);
      expect(await svc.startLogin(), CommunityStartOutcome.coolingDown);
      debugPrint(
        'TIMING transport timeout ${clock.elapsed.inSeconds}s: cooldown=true, retry blocked',
      );
    } finally {
      stalled.complete(http.Response('{"id":"fixture-user"}', 200));
      CloudAvailability.shared = null;
      client.close();
      await store.db.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
