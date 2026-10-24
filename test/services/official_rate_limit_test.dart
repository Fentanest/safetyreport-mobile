// 공식 사이트 요청 속도 제한(2026-10-24 실측: 상세를 간격 없이 보내면 18건 만에 429 `detail_rate_limited`).
// 429 는 같은 요청을 늘려 가며 기다렸다 다시 보내고, 다 쓰면 요청 제한 오류로 멈춘다. 합성 응답만 쓴다.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/official_session.dart';
import 'package:safetyreport/services/standalone_api_service.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _limited = '{"error":"request_limited","reason":"detail_rate_limited"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sleeps = <Duration>[];
  final notices = <String>[];

  setUp(() {
    StandaloneAuthService.invalidateOperations();
    StandaloneApiService.resetPacingForTest();
    sleeps.clear();
    notices.clear();
    StandaloneApiService.sleepForTest = (d) async => sleeps.add(d);
    StandaloneApiService.rateLimitNotice = notices.add;
    StandaloneApiService.abortWait = null;
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.standaloneUsername: 'tester',
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.secureStorageV10Migrated: true,
    });
    FlutterSecureStorage.setMockInitialValues({
      StandaloneAuthService.sessionStorageKey: OfficialSession(
        token: 'synthetic-token',
        username: 'tester',
        epoch: '',
        expiresAt: DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        cookies: const {'JSESSIONID': 'synthetic-session'},
      ).encode(),
    });
  });
  tearDown(() {
    StandaloneApiService.httpClientFactoryForTest = null;
    StandaloneApiService.sleepForTest = (_) async {};
    StandaloneApiService.rateLimitNotice = null;
    StandaloneApiService.abortWait = null;
  });

  test('429 waits and retries the same report instead of moving on', () async {
    final asked = <String>[];
    var calls = 0;
    StandaloneApiService.httpClientFactoryForTest = () =>
        MockClient((req) async {
          asked.add(req.url.path);
          return ++calls <= 2
              ? http.Response(_limited, 429)
              : http.Response('{"result":{"C_NO":"R1"}}', 200);
        });
    final fetched = await StandaloneApiService.fetchReportDetail('R1');
    expect(fetched.result['C_NO'], 'R1');
    expect(asked.toSet(), {'/api/v1/portal/mypage/mysafereport/R1'});
    expect(calls, 3);
    expect(
      sleeps,
      containsAllInOrder([
        const Duration(seconds: 120),
        const Duration(seconds: 180),
      ]),
    );
    expect(notices.every((n) => !n.contains('R1')), isTrue);
    expect(notices, hasLength(2));
  });

  test(
    'persistent 429 stops with a rate-limit error after the last wait',
    () async {
      var calls = 0;
      StandaloneApiService.httpClientFactoryForTest = () =>
          MockClient((req) async {
            calls++;
            return http.Response(_limited, 429);
          });
      await expectLater(
        StandaloneApiService.fetchReportDetail('R1'),
        throwsA(isA<OfficialRateLimitedException>()),
      );
      expect(calls, StandaloneApiService.rateLimitWaitSeconds.length + 1);
      expect(sleeps.where((d) => d >= const Duration(seconds: 120)), [
        for (final s in StandaloneApiService.rateLimitWaitSeconds)
          Duration(seconds: s),
      ]);
    },
  );

  test('a stop request ends the 429 wait right away', () async {
    var calls = 0;
    StandaloneApiService.httpClientFactoryForTest = () =>
        MockClient((req) async {
          calls++;
          return http.Response(_limited, 429);
        });
    StandaloneApiService.abortWait = () => true;
    await expectLater(
      StandaloneApiService.fetchReportDetail('R1'),
      throwsA(isA<OfficialRateLimitedException>()),
    );
    expect(calls, 1);
  });

  test('requests are spaced by the official interval', () async {
    StandaloneApiService.httpClientFactoryForTest = () =>
        MockClient((req) async => http.Response('{"result":{}}', 200));
    for (var i = 0; i < 3; i++) {
      await StandaloneApiService.fetchReportDetail('R$i');
    }
    // 첫 요청은 바로, 뒤 요청은 앞 요청들이 잡은 자리까지 기다린다(시험에서는 기다림이 바로 끝나 자리가 쌓인다).
    expect(sleeps, hasLength(2));
    for (var i = 0; i < sleeps.length; i++) {
      expect(sleeps[i], greaterThan(Duration.zero));
      expect(
        sleeps[i],
        lessThanOrEqualTo(
          StandaloneApiService.officialRequestInterval * (i + 1),
        ),
      );
    }
  });

  test(
    '429 doubles the request interval and steady success brings it back',
    () async {
      var calls = 0;
      StandaloneApiService.httpClientFactoryForTest = () =>
          MockClient((req) async {
            return ++calls == 1
                ? http.Response(_limited, 429)
                : http.Response('{"result":{}}', 200);
          });
      final base = StandaloneApiService.officialRequestInterval;
      await StandaloneApiService.fetchReportDetail('R1');
      expect(StandaloneApiService.currentRequestInterval, base * 2);
      for (var i = 0; i < 100; i++) {
        await StandaloneApiService.fetchReportDetail('R$i');
      }
      expect(StandaloneApiService.currentRequestInterval, base);
    },
  );
}
