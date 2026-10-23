import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/official_session.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/services/standalone_api_service.dart';
import 'package:safetyreport/services/background_login_check.dart';

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, String body, this.cookies)
    : super(Stream.value(utf8.encode(body)));
  @override
  final int statusCode;
  @override
  final List<Cookie> cookies;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.uri, this.reply);
  @override
  final Uri uri;
  final _Response Function(_Request) reply;
  @override
  final _Headers headers = _Headers();
  @override
  final List<Cookie> cookies = [];
  final body = StringBuffer();
  @override
  void write(Object? value) => body.write(value);
  @override
  Future<HttpClientResponse> close() async => reply(this);
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Client implements HttpClient {
  _Client(this.reply);
  final _Response Function(_Request) reply;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async => _Request(uri, reply);
  @override
  Future<HttpClientRequest> postUrl(Uri uri) async => _Request(uri, reply);
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = FlutterSecureStorage();
  var logins = 0;
  var expiresIn = 3600;
  final logs = <String>[];
  late DebugPrintCallback originalPrint;
  setUp(() {
    logs.clear();
    originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    StandaloneAuthService.invalidateOperations();
    StandaloneAuthService.loginOverride = null;
    StandaloneAuthService.passwordReaderOverride = null;
    StandaloneAuthService.transientRetryDelay = Duration.zero;
    FlutterSecureStorage.setMockInitialValues({
      AppPrefsKeys.standalonePassword: 'password-secret',
    });
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.standaloneUsername: 'tester',
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.secureStorageV10Migrated: true,
    });
    logins = 0;
    expiresIn = 3600;
    StandaloneAuthService.httpClientFactoryForTest = () => _Client((req) {
      if (req.uri.path.endsWith('getPublicKey')) {
        return _Response(
          200,
          jsonEncode({
            'RSAModulus': List.filled(128, 'c7').join(),
            'RSAExponent': '10001',
          }),
          [
            Cookie('JSESSIONID', 'rsa-secret'),
            Cookie('WMONID', 'monitor-secret'),
          ],
        );
      }
      expect(req.uri.path, '/oauth/token');
      expect(
        req.cookies.map((c) => '${c.name}=${c.value}'),
        containsAll(['JSESSIONID=rsa-secret', 'WMONID=monitor-secret']),
      );
      expect(req.body.toString(), isNot(contains('password-secret')));
      logins++;
      return _Response(
        200,
        jsonEncode({
          'access_token': 'token-secret-$logins',
          'expires_in': expiresIn,
        }),
        [Cookie('JSESSIONID', 'session-secret-$logins')],
      );
    });
  });
  tearDown(() {
    debugPrint = originalPrint;
    StandaloneAuthService.httpClientFactoryForTest = null;
    StandaloneApiService.httpClientFactoryForTest = null;
  });

  test(
    'real login path stores RSA and rotated token cookies with token in secure bundle',
    () async {
      await StandaloneAuthService.login('tester', 'password-secret');
      final session = await StandaloneAuthService.storedSession();
      expect(session!.token, 'token-secret-1');
      await StandaloneAuthService.clearOtherAccountSession('tester');
      expect(await StandaloneAuthService.getStoredToken(), 'token-secret-1');
      expect(
        session.cookieHeader,
        'JSESSIONID=session-secret-1; WMONID=monitor-secret',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppPrefsKeys.standaloneToken), isNull);
      expect(
        await secure.read(key: StandaloneAuthService.sessionStorageKey),
        contains('session-secret-1'),
      );
      await StandaloneAuthService.clearToken();
      expect(
        await secure.read(key: StandaloneAuthService.sessionStorageKey),
        isNull,
      );
      expect(await secure.read(key: AppPrefsKeys.standalonePassword), isNull);
      expect(await StandaloneAuthService.getStoredToken(), isNull);
    },
  );

  test(
    'legacy token without cookies logs in BEFORE first list request; list/detail/photo send matching cookies',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppPrefsKeys.standaloneToken, 'legacy-token');
      await prefs.setString(AppPrefsKeys.standaloneTokenUsername, 'tester');
      var calls = 0;
      StandaloneApiService.httpClientFactoryForTest = () => MockClient((
        req,
      ) async {
        calls++;
        expect(logins, 1);
        expect(req.headers['Authorization'], 'BEARER token-secret-1');
        expect(req.headers['Cookie'], contains('JSESSIONID=session-secret-1'));
        expect(req.headers['Cookie'], contains('WMONID=monitor-secret'));
        return http.Response('{"result":{},"totalCnt":0}', 200);
      });
      await StandaloneApiService.fetchReportList();
      await StandaloneApiService.fetchReportDetail('synthetic');
      await StandaloneApiService.fetchOfficialAttachment(
        Uri.parse('https://www.safetyreport.go.kr/fileDown/synthetic'),
      );
      expect(calls, 3);
    },
  );

  test(
    'response cookie rotation and deletion are persisted; stale old response cannot undo new login',
    () async {
      await StandaloneAuthService.login('tester', 'password-secret');
      final old = await StandaloneAuthService.storedSession();
      var calls = 0;
      StandaloneApiService.httpClientFactoryForTest = () => MockClient((
        req,
      ) async {
        calls++;
        expect(
          req.headers['Cookie'],
          contains(
            'JSESSIONID=${calls == 1 ? 'session-secret-1' : 'rotated-secret'}',
          ),
        );
        return http.Response(
          '{"result":{}}',
          200,
          headers: {
            'set-cookie':
                'JSESSIONID=rotated-secret; Path=/; Expires=Wed, 09 Jun 2099 10:18:14 GMT, WMONID=; Max-Age=0',
          },
        );
      });
      await StandaloneApiService.fetchReportDetail('x');
      await StandaloneApiService.fetchReportDetail('x');
      expect(
        (await StandaloneAuthService.storedSession())!.cookies.containsKey(
          'WMONID',
        ),
        isFalse,
      );
      await StandaloneAuthService.login('tester', 'password-secret');
      await StandaloneAuthService.updateResponseCookies(
        old!,
        'JSESSIONID=late',
      );
      expect(
        (await StandaloneAuthService.storedSession())!.cookies['JSESSIONID'],
        'session-secret-2',
      );
    },
  );

  for (final success in [true, false]) {
    test('401 forces fresh token and cookie; retry success=$success', () async {
      await StandaloneAuthService.login('tester', 'password-secret');
      var calls = 0;
      StandaloneApiService.httpClientFactoryForTest = () =>
          MockClient((req) async {
            calls++;
            expect(req.headers['Authorization'], 'BEARER token-secret-$calls');
            expect(
              req.headers['Cookie'],
              contains('JSESSIONID=session-secret-$calls'),
            );
            return http.Response(
              success && calls == 2 ? '{"result":{}}' : 'secret reflected body',
              success && calls == 2 ? 200 : 401,
            );
          });
      if (success) {
        await StandaloneApiService.fetchReportList();
      } else {
        await expectLater(
          StandaloneApiService.fetchReportList(),
          throwsA(
            isA<OfficialSessionRejectedException>()
                .having((e) => e.code, 'code', 'official_session_rejected')
                .having(
                  (e) => e.toString(),
                  'message',
                  isNot(contains('secret')),
                ),
          ),
        );
      }
      expect(calls, 2);
      expect(logins, 2);
      final output = logs.join('\n');
      expect(output, contains('status=401'));
      expect(output, contains('retry=1'));
      expect(output, isNot(contains('secret')));
      if (!success) expect(output, contains('official_session_rejected'));
    });
  }

  test('a short new session still relogs only once after 401', () async {
    expiresIn = 60;
    var calls = 0;
    StandaloneApiService.httpClientFactoryForTest = () =>
        MockClient((req) async {
          calls++;
          expect(req.headers['Authorization'], 'BEARER token-secret-$calls');
          return http.Response(
            calls == 1 ? '{}' : '{"result":{}}',
            calls == 1 ? 401 : 200,
          );
        });
    await StandaloneApiService.fetchReportList();
    expect(logins, 2);
    expect(calls, 2);
  });

  test(
    'retry transport error cannot echo credentials into logs or UI',
    () async {
      await StandaloneAuthService.login('tester', 'password-secret');
      var calls = 0;
      StandaloneApiService.httpClientFactoryForTest = () =>
          MockClient((req) async {
            if (++calls == 1) return http.Response('token-secret', 401);
            throw http.ClientException(
              'token-secret session-secret password-secret',
            );
          });
      await expectLater(
        StandaloneApiService.fetchReportList(),
        throwsA(
          isA<AuthTemporarilyUnavailableException>().having(
            (e) => e.message,
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
      expect(logs.join(), isNot(contains('secret')));
    },
  );

  test(
    'background login check upgrades legacy session using the same secure store',
    () async {
      expect(await BackgroundLoginCheck.run(), isFalse);
      expect(logins, 1);
      expect((await StandaloneAuthService.storedSession())!.ready, isTrue);
      expect(await BackgroundLoginCheck.run(), isFalse);
      expect(logins, 1);
    },
  );

  test(
    'account change/logout fences old response cookies; foreign URL never receives credentials',
    () async {
      await StandaloneAuthService.login('tester', 'password-secret');
      final old = (await StandaloneAuthService.storedSession())!;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppPrefsKeys.standaloneUsername, 'other');
      expect(await StandaloneAuthService.storedSession(), isNull);
      await StandaloneAuthService.updateResponseCookies(old, 'JSESSIONID=late');
      await StandaloneAuthService.clearOtherAccountSession('other');
      expect(
        await secure.read(key: StandaloneAuthService.sessionStorageKey),
        isNull,
      );
      await StandaloneAuthService.clearToken();
      await StandaloneAuthService.updateResponseCookies(old, 'JSESSIONID=late');
      expect(
        await secure.read(key: StandaloneAuthService.sessionStorageKey),
        isNull,
      );
      await expectLater(
        StandaloneApiService.fetchOfficialAttachment(
          Uri.parse('https://safetyreport.go.kr.evil.test/photo'),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'background relogin cannot recreate a cleared session after mode switch',
    () async {
      await StandaloneAuthService.login('tester', 'password-secret');
      await StandaloneAuthService.clearToken();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppPrefsKeys.appMode, 'server');
      await secure.write(
        key: AppPrefsKeys.standalonePassword,
        value: 'password-secret',
      );
      final result = await StandaloneAuthService.relogin();
      expect(result.outcome, ReloginOutcome.transient);
      expect(logins, 1);
      expect(
        await secure.read(key: StandaloneAuthService.sessionStorageKey),
        isNull,
      );
      await expectLater(
        StandaloneAuthService.saveToken(
          'late',
          username: 'tester',
          requireCurrentUsername: true,
          cookies: {'JSESSIONID': 'late'},
        ),
        throwsA(isA<AuthTemporarilyUnavailableException>()),
      );
    },
  );

  test(
    'cookie parser keeps only official session cookies and handles Expires commas',
    () {
      final cookies = OfficialSession.mergeCookies(
        {},
        OfficialSession.parseSetCookie(
          'JSESSIONID=one; Expires=Wed, 09 Jun 2099 10:18:14 GMT, WMONID=two, unrelated=three',
        ),
      );
      expect(cookies, {'JSESSIONID': 'one', 'WMONID': 'two'});
    },
  );

  test('login rejection keeps the official site notice (e.g. locked account)', () async {
    StandaloneAuthService.httpClientFactoryForTest = () => _Client((req) {
      if (req.uri.path.endsWith('getPublicKey')) {
        return _Response(
          200,
          jsonEncode({
            'RSAModulus': List.filled(128, 'c7').join(),
            'RSAExponent': '10001',
          }),
          [Cookie('JSESSIONID', 'rsa-secret')],
        );
      }
      return _Response(
        400,
        jsonEncode({'error_description': '비밀번호 5회 오류로 계정이 잠겼습니다.'}),
        const [],
      );
    });
    await expectLater(
      StandaloneAuthService.login('tester', 'password-secret'),
      throwsA(
        isA<LoginRejectedException>().having(
          (e) => e.message,
          'message',
          '비밀번호 5회 오류로 계정이 잠겼습니다.',
        ),
      ),
    );
  });
}
