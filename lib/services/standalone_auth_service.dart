import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 토큰 만료 예외 — StandaloneApiService에서 자동 재로그인 트리거에 사용
class TokenExpiredException implements Exception {
  final String message;
  const TokenExpiredException([this.message = '토큰이 만료되었습니다.']);
  @override
  String toString() => message;
}

class StandaloneAuthService {
  static const _base = 'https://www.safetyreport.go.kr';

  // SharedPreferences 키
  static const _tokenKey = 'standaloneToken';
  static const _expiresAtKey = 'standaloneTokenExpiresAt';

  // FlutterSecureStorage 키 (비밀번호 암호화 저장)
  static const _securePasswordKey = 'standalone_password';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static Timer? _keepAliveTimer;
  static bool _keepAliveInFlight = false;

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
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final req = await client.getUrl(
            Uri.parse('$_base/api/v1/common/rsa/getPublicKey'),
          );
          _commonHeaders.forEach((k, v) => req.headers.set(k, v));
          keyRes = await req.close().timeout(const Duration(seconds: 15));
          keyBody = await keyRes.transform(utf8.decoder).join();
          break;
        } catch (e) {
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(seconds: attempt));
        }
      }

      if (keyRes.statusCode != 200) {
        throw Exception('RSA 키 조회 실패 (${keyRes.statusCode})');
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

      final keyData = jsonDecode(keyBody) as Map<String, dynamic>;
      final modulusHex = keyData['RSAModulus'] as String;
      final exponentHex = keyData['RSAExponent'] as String;

      // ── Step 2: 비밀번호 RSA 암호화 ──
      final encryptedPw = _rsaEncryptHex(modulusHex, exponentHex, password);

      // ── Step 3: OAuth2 토큰 발급 (네트워크 일시 오류 시 최대 3회 재시도) ──
      final body = Uri(queryParameters: {
        'client_id': 'web',
        'grant_type': 'password',
        'loginType': '1',
        'username': username,
        'password': encryptedPw,
      }).query;
      final bodyBytes = utf8.encode(body);

      late HttpClientResponse tokenRes;
      late String tokenBody;
      Object? tokenLastError;
      var tokenSuccess = false;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final tokenReq = await client.postUrl(Uri.parse('$_base/oauth/token'));
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
          tokenRes = await tokenReq.close().timeout(const Duration(seconds: 15));
          tokenBody = await tokenRes.transform(utf8.decoder).join();
          tokenSuccess = true;
          break;
        } catch (e) {
          // errno 104 (connection reset), 110 (timeout) 등 일시 오류는 조용히 재시도.
          // 4xx/5xx 응답은 close() 가 throw 하지 않으므로 위 분기에서 처리됨.
          tokenLastError = e;
          if (attempt < 3) await Future.delayed(Duration(seconds: attempt));
        }
      }
      if (!tokenSuccess) {
        throw Exception('토큰 요청 네트워크 오류 (3회 재시도 실패): $tokenLastError');
      }

      if (tokenRes.statusCode == 401 || tokenRes.statusCode == 400) {
        // 서버가 반환하는 에러 메시지가 있으면 포함
        String detail = '아이디 또는 비밀번호가 올바르지 않습니다.';
        try {
          final errJson = jsonDecode(tokenBody) as Map<String, dynamic>;
          final desc = errJson['error_description'] as String?;
          if (desc != null && desc.isNotEmpty) detail = desc;
        } catch (_) {}
        throw Exception(detail);
      }
      if (tokenRes.statusCode != 200) {
        final snippet =
            tokenBody.length > 200 ? tokenBody.substring(0, 200) : tokenBody;
        throw Exception('로그인 실패 (HTTP ${tokenRes.statusCode})\n$snippet');
      }

      final tokenData = jsonDecode(tokenBody) as Map<String, dynamic>;
      final token = tokenData['access_token'] as String?;
      if (token == null || token.isEmpty) throw Exception('토큰 응답 파싱 실패');

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
    await _secureStorage.delete(key: _securePasswordKey);
  }

  static void startKeepAlive({Duration interval = const Duration(minutes: 55)}) {
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

  static Future<void> refreshSessionIfNeeded({bool force = false}) async {
    if (_keepAliveInFlight) return;
    if (!force && await isTokenValid()) return;
    _keepAliveInFlight = true;
    try {
      await tryAutoRelogin();
    } finally {
      _keepAliveInFlight = false;
    }
  }

  // ── 자동 재로그인 ──────────────────────────────────────────

  /// 저장된 자격증명으로 자동 재로그인 시도.
  /// 성공하면 새 토큰 반환, 자격증명 없으면 null 반환.
  static Future<String?> tryAutoRelogin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('standaloneUsername');
    final password = await _secureStorage.read(key: _securePasswordKey);

    if (username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      return null; // 저장된 자격증명 없음 — 수동 재로그인 필요
    }

    try {
      return await login(username, password, saveCredentials: false);
    } catch (_) {
      return null; // 비밀번호 변경 등 — 수동 재로그인 필요
    }
  }

  /// API 호출 전 토큰 유효성 확인 + 자동 갱신.
  /// 유효한 토큰을 반환하거나, 갱신 실패 시 TokenExpiredException 발생.
  static Future<String> ensureValidToken() async {
    // 1) 토큰이 아직 유효한지 확인
    if (await isTokenValid()) {
      final token = await getStoredToken();
      if (token != null) return token;
    }

    // 2) 만료됨 → 자동 재로그인 시도
    final newToken = await tryAutoRelogin();
    if (newToken != null) return newToken;

    // 3) 재로그인 실패 → 수동 재로그인 필요
    throw const TokenExpiredException();
  }

  // ── RSA 암호화 ─────────────────────────────────────────────

  // PKCS1 v1.5 RSA 암호화 → hex 문자열 (브라우저 JSEncrypt와 동일 포맷)
  static String _rsaEncryptHex(
      String modulusHex, String exponentHex, String plaintext) {
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
