import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2026-09-24 제보: Standalone 에서 동기화하려는데 "토큰 만료"가 떴다.
/// 원인: 자동 재로그인의 모든 실패(네트워크·점검 포함)를 '토큰 만료'로 알렸고, 재로그인이 겹칠 수 있었다.
/// 실제 안전신문고 로그인은 호출하지 않는다(loginOverride).
void main() {
  late int loginCalls;

  setUp(() {
    loginCalls = 0;
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.standaloneUsername: 'tester',
    });
    StandaloneAuthService.passwordReaderOverride = () async => 'pw';
    StandaloneAuthService.transientRetryDelay = Duration.zero;
  });

  tearDown(() {
    StandaloneAuthService.loginOverride = null;
    StandaloneAuthService.passwordReaderOverride = null;
  });

  test('동시에 여러 곳에서 재로그인해도 로그인은 한 번만 한다', () async {
    final gate = Completer<void>();
    StandaloneAuthService.loginOverride = (u, p) async {
      loginCalls++;
      await gate.future;
      return 'token-1';
    };

    final a = StandaloneAuthService.relogin();
    final b = StandaloneAuthService.relogin();
    final c = StandaloneAuthService.refreshSessionIfNeeded(force: true);
    gate.complete();
    final results = await Future.wait([a, b]);
    await c;

    expect(loginCalls, 1);
    expect(results.map((r) => r.token), ['token-1', 'token-1']);
    final status = await StandaloneAuthService.lastReloginStatus();
    expect(status!.outcome, ReloginOutcome.success);
  });

  test('네트워크·점검 오류는 한 번 더 시도하고, 재로그인 안내가 아닌 일시 오류로 알린다', () async {
    StandaloneAuthService.loginOverride = (u, p) async {
      loginCalls++;
      throw const AuthTemporarilyUnavailableException('점검 중');
    };

    final r = await StandaloneAuthService.relogin();
    expect(loginCalls, 2);
    expect(r.outcome, ReloginOutcome.transient);
    expect(r.needsManualLogin, isFalse);
    await expectLater(
      StandaloneAuthService.ensureValidToken(),
      throwsA(isA<AuthTemporarilyUnavailableException>()),
    );
    final status = await StandaloneAuthService.lastReloginStatus();
    expect(status!.outcome, ReloginOutcome.transient);
    expect(status.needsManualLogin, isFalse);
  });

  test('비밀번호 거부는 재시도하지 않고 재로그인 안내(TokenExpiredException)', () async {
    StandaloneAuthService.loginOverride = (u, p) async {
      loginCalls++;
      throw const LoginRejectedException('아이디 또는 비밀번호가 올바르지 않습니다.');
    };

    final r = await StandaloneAuthService.relogin();
    expect(loginCalls, 1);
    expect(r.outcome, ReloginOutcome.rejected);
    expect(r.needsManualLogin, isTrue);
    await expectLater(
      StandaloneAuthService.ensureValidToken(),
      throwsA(
        isA<TokenExpiredException>().having(
          (e) => e.message,
          'message',
          contains('재로그인'),
        ),
      ),
    );
  });

  test('저장된 비밀번호가 없거나 보안 저장소를 못 읽으면 로그인 시도 없이 재로그인 안내', () async {
    StandaloneAuthService.loginOverride = (u, p) async {
      loginCalls++;
      return 'unused';
    };
    StandaloneAuthService.passwordReaderOverride = () async =>
        throw Exception('keystore');

    final r = await StandaloneAuthService.relogin();
    expect(loginCalls, 0);
    expect(r.outcome, ReloginOutcome.noCredentials);
    expect(await StandaloneAuthService.tryAutoRelogin(), isNull);
  });

  test('유효한 토큰이 있으면 로그인하지 않는다', () async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.standaloneUsername: 'tester',
      AppPrefsKeys.standaloneToken: 'cached',
      AppPrefsKeys.standaloneTokenExpiresAt: DateTime.now()
          .add(const Duration(minutes: 30))
          .millisecondsSinceEpoch,
    });
    StandaloneAuthService.loginOverride = (u, p) async {
      loginCalls++;
      return 'new';
    };

    expect(await StandaloneAuthService.ensureValidToken(), 'cached');
    await StandaloneAuthService.refreshSessionIfNeeded();
    expect(loginCalls, 0);
  });
}
