import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_prefs_keys.dart';
import 'review_prompt_service.dart';
import 'network_retry_config.dart';

/// 자동 재로그인으로 해결할 수 없는 인증 실패 — 사용자가 설정 > 재로그인을 해야 한다.
/// (저장된 로그인 정보 없음, 안전신문고가 아이디/비밀번호를 거부)
class TokenExpiredException implements Exception {
  final String message;
  const TokenExpiredException([
    this.message = '로그인이 만료되었습니다. 설정 > 재로그인에서 다시 로그인해 주세요.',
  ]);
  @override
  String toString() => message;
}

/// 안전신문고 로그인 서버에 잠시 닿지 못함(네트워크 끊김·점검·5xx·비정상 응답).
/// 재로그인 안내 대상이 아니다 — 잠시 후 다시 시도하면 된다.
class AuthTemporarilyUnavailableException implements Exception {
  final String message;
  const AuthTemporarilyUnavailableException(this.message);
  @override
  String toString() => message;
}

/// 안전신문고가 로그인을 거부함(HTTP 400/401: 아이디·비밀번호 불일치, 계정 잠김 등).
class LoginRejectedException implements Exception {
  final String message;
  const LoginRejectedException(this.message);
  @override
  String toString() => message;
}

enum ReloginOutcome { success, noCredentials, rejected, transient }

class ReloginResult {
  final ReloginOutcome outcome;
  final String? token;
  final String message;

  const ReloginResult(this.outcome, {this.token, this.message = ''});

  bool get needsManualLogin =>
      outcome == ReloginOutcome.noCredentials ||
      outcome == ReloginOutcome.rejected;
}

/// 설정·대시보드에 보여 줄 마지막 자동 로그인 결과.
class ReloginStatus {
  final DateTime at;
  final ReloginOutcome outcome;
  final String message;

  const ReloginStatus(this.at, this.outcome, this.message);

  bool get needsManualLogin =>
      outcome == ReloginOutcome.noCredentials ||
      outcome == ReloginOutcome.rejected;
}

class StandaloneAuthService {
  static const _base = 'https://www.safetyreport.go.kr';

  // SharedPreferences 키 — `AppPrefsKeys` alias (Kotlin 호환 이름)
  static const _tokenKey = AppPrefsKeys.standaloneToken;
  static const _expiresAtKey = AppPrefsKeys.standaloneTokenExpiresAt;

  // FlutterSecureStorage 키 (비밀번호 암호화 저장)
  static const _securePasswordKey = AppPrefsKeys.standalonePassword;
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static Timer? _keepAliveTimer;

  // 서버가 Referer·X-Requested-With·User-Agent 없으면 연결을 차단함 (errno 104)
  static const _commonHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    'Referer': 'https://www.safetyreport.go.kr/',
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7',
    'Origin': 'https://www.safetyreport.go.kr',
  };

  // ── 로그인 (dart:io HttpClient → 쿠키 자동 관리) ──────────────

  /// RSA 공개키 조회 → 비밀번호 암호화(hex) → OAuth2 토큰 발급
  /// [saveCredentials] true이면 재로그인용 비밀번호를 secure storage에 저장
  static Future<String> login(
    String username,
    String password, {
    bool saveCredentials = true,
  }) async {
    final client = HttpClient();
    // 타임아웃 설정
    client.connectionTimeout = const Duration(seconds: 15);

    try {
      // ── Step 1: RSA 키 조회 (최대 3회 재시도) ──
      late HttpClientResponse keyRes;
      late String keyBody;
      for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
        try {
          final req = await client.getUrl(
            Uri.parse('$_base/api/v1/common/rsa/getPublicKey'),
          );
          _commonHeaders.forEach((k, v) => req.headers.set(k, v));
          keyRes = await req.close().timeout(const Duration(seconds: 15));
          keyBody = await keyRes.transform(utf8.decoder).join();
          break;
        } catch (e) {
          if (attempt == mobileMaxRetryAttempts) {
            throw AuthTemporarilyUnavailableException(
              '안전신문고에 연결하지 못했습니다. 네트워크를 확인하고 잠시 후 다시 시도해 주세요. ($e)',
            );
          }
          await Future.delayed(Duration(seconds: attempt));
        }
      }

      if (keyRes.statusCode != 200) {
        throw AuthTemporarilyUnavailableException(
          '안전신문고 로그인 서버 응답 오류(RSA 키 ${keyRes.statusCode}). 점검 중일 수 있으니 잠시 후 다시 시도해 주세요.',
        );
      }

      // JSESSIONID 쿠키 추출 — 서버가 RSA 키를 세션에 바인딩하므로 토큰 요청에 필수
      // dart:io HttpClient의 자동 쿠키 관리가 Flutter Android에서 불안정하므로 수동 처리
      String? jsessionId;
      for (final cookie in keyRes.cookies) {
        if (cookie.name == 'JSESSIONID') {
          jsessionId = cookie.value;
          break;
        }
      }

      // 점검 중에는 JSON 대신 HTML 안내 페이지가 200 으로 올 수 있다.
      final String modulusHex;
      final String exponentHex;
      try {
        final keyData = jsonDecode(keyBody) as Map<String, dynamic>;
        modulusHex = keyData['RSAModulus'] as String;
        exponentHex = keyData['RSAExponent'] as String;
      } catch (_) {
        throw const AuthTemporarilyUnavailableException(
          '안전신문고 로그인 서버가 예상과 다른 응답을 보냈습니다. 점검 중일 수 있으니 잠시 후 다시 시도해 주세요.',
        );
      }

      // ── Step 2: 비밀번호 RSA 암호화 ──
      final encryptedPw = _rsaEncryptHex(modulusHex, exponentHex, password);

      // ── Step 3: OAuth2 토큰 발급 (네트워크 일시 오류 시 최대 3회 재시도) ──
      final body = Uri(
        queryParameters: {
          'client_id': 'web',
          'grant_type': 'password',
          'loginType': '1',
          'username': username,
          'password': encryptedPw,
        },
      ).query;
      final bodyBytes = utf8.encode(body);

      late HttpClientResponse tokenRes;
      late String tokenBody;
      Object? tokenLastError;
      var tokenSuccess = false;
      for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
        try {
          final tokenReq = await client.postUrl(
            Uri.parse('$_base/oauth/token'),
          );
          _commonHeaders.forEach((k, v) => tokenReq.headers.set(k, v));
          tokenReq.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
            charset: 'utf-8',
          );
          if (jsessionId != null) {
            tokenReq.cookies.add(Cookie('JSESSIONID', jsessionId));
          }
          tokenReq.headers.contentLength = bodyBytes.length;
          tokenReq.write(body);
          tokenRes = await tokenReq.close().timeout(
            const Duration(seconds: 15),
          );
          tokenBody = await tokenRes.transform(utf8.decoder).join();
          tokenSuccess = true;
          break;
        } catch (e) {
          // errno 104 (connection reset), 110 (timeout) 등 일시 오류는 조용히 재시도.
          // 4xx/5xx 응답은 close() 가 throw 하지 않으므로 위 분기에서 처리됨.
          tokenLastError = e;
          if (attempt < mobileMaxRetryAttempts) {
            await Future.delayed(Duration(seconds: attempt));
          }
        }
      }
      if (!tokenSuccess) {
        throw AuthTemporarilyUnavailableException(
          '안전신문고 로그인 요청이 네트워크 오류로 실패했습니다(${mobileMaxRetryAttempts}회 재시도). 잠시 후 다시 시도해 주세요. ($tokenLastError)',
        );
      }

      if (tokenRes.statusCode == 401 || tokenRes.statusCode == 400) {
        // 서버가 반환하는 에러 메시지가 있으면 포함
        String detail = '아이디 또는 비밀번호가 올바르지 않습니다.';
        try {
          final errJson = jsonDecode(tokenBody) as Map<String, dynamic>;
          final desc = errJson['error_description'] as String?;
          if (desc != null && desc.isNotEmpty) detail = desc;
        } catch (_) {}
        // RSA 복호화 실패는 세션(JSESSIONID) 문제라 비밀번호 탓이 아니다 — 다시 시도하면 된다.
        if (detail.contains('RSA')) {
          throw AuthTemporarilyUnavailableException(
            '안전신문고 로그인 세션 오류($detail). 잠시 후 다시 시도해 주세요.',
          );
        }
        throw LoginRejectedException(detail);
      }
      if (tokenRes.statusCode != 200) {
        throw AuthTemporarilyUnavailableException(
          '안전신문고 로그인 서버 응답 오류(HTTP ${tokenRes.statusCode}). 점검 중일 수 있으니 잠시 후 다시 시도해 주세요.',
        );
      }

      String? token;
      Map<String, dynamic> tokenData;
      try {
        tokenData = jsonDecode(tokenBody) as Map<String, dynamic>;
        token = tokenData['access_token'] as String?;
      } catch (_) {
        throw const AuthTemporarilyUnavailableException(
          '안전신문고 로그인 응답을 읽지 못했습니다. 잠시 후 다시 시도해 주세요.',
        );
      }
      if (token == null || token.isEmpty) {
        throw const AuthTemporarilyUnavailableException(
          '안전신문고 로그인 응답에 토큰이 없습니다. 잠시 후 다시 시도해 주세요.',
        );
      }

      // 토큰 만료 시간 계산 (서버 응답 expires_in, 기본 3599초)
      final expiresIn = (tokenData['expires_in'] as num?)?.toInt() ?? 3599;
      final expiresAt = DateTime.now()
          .add(Duration(seconds: expiresIn))
          .millisecondsSinceEpoch;

      // 토큰 + 만료 시간 저장
      await saveToken(token, expiresAt: expiresAt);

      // 재로그인용 비밀번호 저장 (secure storage)
      if (saveCredentials) {
        await _secureStorage.write(key: _securePasswordKey, value: password);
        // 사용자가 직접 로그인에 성공하면 이전 실패 기록·경고는 해소된 것이다.
        await _recordResult(const ReloginResult(ReloginOutcome.success));
      }

      return token;
    } finally {
      client.close();
    }
  }

  // ── 토큰 저장/조회/삭제 ──────────────────────────────────────

  static Future<void> saveToken(String token, {int? expiresAt}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    if (expiresAt != null) {
      await prefs.setInt(_expiresAtKey, expiresAt);
    }
  }

  static Future<String?> getStoredToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<String> getPhoneNumber() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppPrefsKeys.standalonePhoneNumber) ?? '';
  }

  /// 토큰이 유효한지(존재하고, 만료되지 않았는지) 확인
  static Future<bool> isTokenValid() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    if (token == null || token.isEmpty) return false;

    final expiresAt = prefs.getInt(_expiresAtKey);
    if (expiresAt == null) return true; // 만료 정보 없으면 일단 유효하다고 판단

    // 만료 5분 전부터 무효로 판단 (여유 마진)
    final now = DateTime.now().millisecondsSinceEpoch;
    return now < (expiresAt - 5 * 60 * 1000);
  }

  /// 토큰 만료까지 남은 시간 (초). 만료됐으면 음수.
  static Future<int> tokenRemainingSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    final expiresAt = prefs.getInt(_expiresAtKey);
    if (expiresAt == null) return -1;
    return ((expiresAt - DateTime.now().millisecondsSinceEpoch) / 1000).round();
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_expiresAtKey);
    await prefs.remove(AppPrefsKeys.standaloneAuthLastAt);
    await prefs.remove(AppPrefsKeys.standaloneAuthLastOutcome);
    await prefs.remove(AppPrefsKeys.standaloneAuthLastMessage);
    status.value = null;
    await _secureStorage.delete(key: _securePasswordKey);
  }

  static void startKeepAlive({
    Duration interval = const Duration(minutes: 55),
  }) {
    if (_keepAliveTimer?.isActive ?? false) return;
    () async {
      await refreshSessionIfNeeded();
    }();
    _keepAliveTimer = Timer.periodic(interval, (_) async {
      await refreshSessionIfNeeded(force: true);
    });
  }

  static void stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  /// 토큰이 곧 만료되면 재로그인. 이미 진행 중인 재로그인이 있으면 그 결과를 기다린다
  /// (예전에는 진행 중이면 바로 돌아와, 뒤따르는 동기화가 만료된 토큰으로 시작하고 로그인이 겹쳤다).
  static Future<void> refreshSessionIfNeeded({bool force = false}) async {
    if (!force && await isTokenValid()) return;
    await relogin();
  }

  // ── 자동 재로그인 ──────────────────────────────────────────

  static Future<ReloginResult>? _reloginInFlight;

  @visibleForTesting
  static Future<String> Function(String username, String password)?
  loginOverride;

  @visibleForTesting
  static Future<String?> Function()? passwordReaderOverride;

  @visibleForTesting
  static Duration transientRetryDelay = const Duration(seconds: 5);

  /// 저장된 자격증명으로 재로그인. 동시에 여러 곳에서 불러도 로그인은 한 번만 한다.
  static Future<ReloginResult> relogin() {
    return _reloginInFlight ??= _reloginOnce().whenComplete(() {
      _reloginInFlight = null;
    });
  }

  static Future<ReloginResult> _reloginOnce() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(AppPrefsKeys.standaloneUsername) ?? '';
    String? password;
    try {
      password =
          await (passwordReaderOverride?.call() ??
              _secureStorage.read(key: _securePasswordKey));
    } catch (_) {
      password = null; // 보안 저장소를 읽지 못함 — 수동 로그인 필요
    }

    ReloginResult result;
    if (username.isEmpty || password == null || password.isEmpty) {
      result = const ReloginResult(
        ReloginOutcome.noCredentials,
        message: '저장된 로그인 정보가 없습니다. 설정 > 재로그인에서 다시 로그인해 주세요.',
      );
    } else {
      result = await _loginWithRetry(username, password);
    }
    await _recordResult(result);
    return result;
  }

  /// 일시 오류는 한 번 더 시도한다. login() 안에서 네트워크 오류는 이미 여러 번 재시도한다.
  static Future<ReloginResult> _loginWithRetry(
    String username,
    String password,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final token =
            await (loginOverride?.call(username, password) ??
                login(username, password, saveCredentials: false));
        return ReloginResult(ReloginOutcome.success, token: token);
      } on LoginRejectedException catch (e) {
        return ReloginResult(
          ReloginOutcome.rejected,
          message:
              '안전신문고가 로그인을 거부했습니다: ${e.message} 비밀번호를 바꾸셨다면 설정 > 재로그인에서 다시 로그인해 주세요.',
        );
      } catch (e) {
        lastError = e;
        if (attempt < 2) await Future.delayed(transientRetryDelay);
      }
    }
    return ReloginResult(
      ReloginOutcome.transient,
      message: lastError is AuthTemporarilyUnavailableException
          ? lastError.message
          : '안전신문고 로그인 중 오류가 났습니다. 잠시 후 다시 시도해 주세요. ($lastError)',
    );
  }

  /// 마지막 로그인 결과(대시보드 경고·설정 계정 카드가 구독). 백그라운드 점검이 남긴 결과는
  /// 다른 isolate 라 여기 바로 반영되지 않으므로 앱 시작·복귀 때 [reloadStatus] 로 다시 읽는다.
  static final ValueNotifier<ReloginStatus?> status = ValueNotifier(null);

  static Future<void> reloadStatus() async {
    status.value = await lastReloginStatus();
  }

  static Future<void> _recordResult(ReloginResult r) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    status.value = ReloginStatus(now, r.outcome, r.message);
    if (r.outcome != ReloginOutcome.success) {
      ReviewPromptService.markSessionError();
    }
    await prefs.setInt(
      AppPrefsKeys.standaloneAuthLastAt,
      now.millisecondsSinceEpoch,
    );
    await prefs.setString(
      AppPrefsKeys.standaloneAuthLastOutcome,
      r.outcome.name,
    );
    await prefs.setString(AppPrefsKeys.standaloneAuthLastMessage, r.message);
  }

  /// 마지막 자동/수동 로그인 결과. 기록이 없으면 null.
  static Future<ReloginStatus?> lastReloginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(AppPrefsKeys.standaloneAuthLastAt);
    final name = prefs.getString(AppPrefsKeys.standaloneAuthLastOutcome);
    if (at == null || name == null) return null;
    final outcome = ReloginOutcome.values.firstWhere(
      (o) => o.name == name,
      orElse: () => ReloginOutcome.transient,
    );
    return ReloginStatus(
      DateTime.fromMillisecondsSinceEpoch(at),
      outcome,
      prefs.getString(AppPrefsKeys.standaloneAuthLastMessage) ?? '',
    );
  }

  /// 호환용: 성공하면 새 토큰, 아니면 null. 실패 원인이 필요하면 [relogin] 을 쓴다.
  static Future<String?> tryAutoRelogin() async => (await relogin()).token;

  /// API 호출 전 토큰 유효성 확인 + 자동 갱신.
  /// 재로그인이 필요하면 [TokenExpiredException], 일시 오류면 [AuthTemporarilyUnavailableException].
  static Future<String> ensureValidToken() async {
    if (await isTokenValid()) {
      final token = await getStoredToken();
      if (token != null) return token;
    }
    return tokenFromRelogin(await relogin());
  }

  /// 재로그인 결과를 토큰 또는 알맞은 예외로 바꾼다.
  static String tokenFromRelogin(ReloginResult r) {
    switch (r.outcome) {
      case ReloginOutcome.success:
        return r.token!;
      case ReloginOutcome.transient:
        throw AuthTemporarilyUnavailableException(r.message);
      case ReloginOutcome.noCredentials:
      case ReloginOutcome.rejected:
        throw TokenExpiredException(r.message);
    }
  }

  // ── RSA 암호화 ─────────────────────────────────────────────

  // PKCS1 v1.5 RSA 암호화 → hex 문자열 (브라우저 JSEncrypt와 동일 포맷)
  static String _rsaEncryptHex(
    String modulusHex,
    String exponentHex,
    String plaintext,
  ) {
    final modulus = BigInt.parse(modulusHex, radix: 16);
    final exponent = BigInt.parse(exponentHex, radix: 16);
    final publicKey = RSAPublicKey(modulus, exponent);

    final cipher = PKCS1Encoding(RSAEngine())
      ..init(
        true,
        ParametersWithRandom(
          PublicKeyParameter<RSAPublicKey>(publicKey),
          _buildSecureRandom(),
        ),
      );

    final input = Uint8List.fromList(utf8.encode(plaintext));
    final encrypted = cipher.process(input);
    return encrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static SecureRandom _buildSecureRandom() {
    final sr = SecureRandom('Fortuna');
    final rng = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < seed.length; i++) {
      seed[i] = rng.nextInt(256);
    }
    sr.seed(KeyParameter(seed));
    return sr;
  }
}
