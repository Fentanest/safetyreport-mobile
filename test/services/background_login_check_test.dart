import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 하루 1회 백그라운드 로그인 점검. 실제 안전신문고 로그인은 호출하지 않는다(loginOverride).
void main() {
  late int loginCalls;

  Future<void> setPrefs(Map<String, Object> extra) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'tester',
      ...extra,
    });
  }

  setUp(() async {
    loginCalls = 0;
    await setPrefs({});
    StandaloneAuthService.passwordReaderOverride = () async => 'pw';
    StandaloneAuthService.transientRetryDelay = Duration.zero;
  });

  tearDown(() {
    StandaloneAuthService.loginOverride = null;
    StandaloneAuthService.passwordReaderOverride = null;
  });

  void loginThrows(Object error) {
    StandaloneAuthService.loginOverride = (u, p) async {
      loginCalls++;
      throw error;
    };
  }

  Future<String?> alert() async => (await SharedPreferences.getInstance())
      .getString(AppPrefsKeys.standaloneAuthAlert);

  test('비밀번호가 거부되면 재로그인 알림을 요청하고, 72시간 안에는 다시 알리지 않는다', () async {
    loginThrows(const LoginRejectedException('비밀번호 불일치'));
    final t0 = DateTime(2026, 9, 24, 3);

    expect(await BackgroundLoginCheck.run(now: t0), isTrue);
    expect(await alert(), startsWith('${t0.millisecondsSinceEpoch}|'));
    expect(await alert(), contains('비밀번호 불일치'));

    expect(
      await BackgroundLoginCheck.run(now: t0.add(const Duration(hours: 24))),
      isFalse,
    );
    expect(
      await BackgroundLoginCheck.run(now: t0.add(const Duration(hours: 73))),
      isTrue,
    );
  });

  test('네트워크·점검 오류는 알리지 않는다(다음 날 다시)', () async {
    loginThrows(const AuthTemporarilyUnavailableException('점검 중'));
    expect(await BackgroundLoginCheck.run(), isFalse);
    expect(await alert(), isNull);
    expect(loginCalls, 2);
  });

  test('로그인 성공이면 알리지 않는다', () async {
    StandaloneAuthService.loginOverride = (u, p) async {
      loginCalls++;
      return 'token';
    };
    expect(await BackgroundLoginCheck.run(), isFalse);
    expect(loginCalls, 1);
    expect(await alert(), isNull);
  });

  test('Client 모드·데모·살아 있는 토큰이면 로그인하지 않는다', () async {
    loginThrows(const LoginRejectedException('x'));

    await setPrefs({AppPrefsKeys.appMode: 'server'});
    expect(await BackgroundLoginCheck.run(), isFalse);

    await setPrefs({AppPrefsKeys.standaloneDemoMode: true});
    expect(await BackgroundLoginCheck.run(), isFalse);

    await setPrefs({
      AppPrefsKeys.standaloneToken: 't',
      AppPrefsKeys.standaloneTokenExpiresAt: DateTime.now()
          .add(const Duration(minutes: 30))
          .millisecondsSinceEpoch,
    });
    expect(await BackgroundLoginCheck.run(), isFalse);

    expect(loginCalls, 0);
  });
}
