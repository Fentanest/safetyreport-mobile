import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StandaloneAuthService {
  static const _base = 'https://www.safetyreport.go.kr';
  static const _tokenKey = 'standaloneToken';

  // 브라우저와 동일한 헤더 세트 (없으면 서버가 연결을 차단함)
  static const _commonHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    'Referer': 'https://www.safetyreport.go.kr/',
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': '*/*',
  };

  // 로그인: RSA 공개키 조회 → 비밀번호 암호화(hex) → OAuth2 토큰 발급
  static Future<String> login(String username, String password) async {
    final keyRes = await http
        .get(
          Uri.parse('$_base/api/v1/common/rsa/getPublicKey'),
          headers: _commonHeaders,
        )
        .timeout(const Duration(seconds: 15));

    if (keyRes.statusCode != 200) {
      throw Exception('RSA 키 조회 실패 (${keyRes.statusCode})');
    }

    final keyData = jsonDecode(keyRes.body) as Map<String, dynamic>;
    final modulusHex = keyData['RSAModulus'] as String;
    final exponentHex = keyData['RSAExponent'] as String;
    final encryptedPw = _rsaEncryptHex(modulusHex, exponentHex, password);

    final tokenRes = await http
        .post(
          Uri.parse('$_base/oauth/token'),
          headers: {
            ..._commonHeaders,
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          },
          body: 'client_id=web&grant_type=password&loginType=1'
              '&username=${Uri.encodeComponent(username)}'
              '&password=$encryptedPw',
        )
        .timeout(const Duration(seconds: 15));

    if (tokenRes.statusCode == 401 || tokenRes.statusCode == 400) {
      throw Exception('아이디 또는 비밀번호가 올바르지 않습니다.');
    }
    if (tokenRes.statusCode != 200) {
      final snippet = tokenRes.body.length > 200
          ? tokenRes.body.substring(0, 200)
          : tokenRes.body;
      throw Exception('로그인 실패 (HTTP ${tokenRes.statusCode})\n$snippet');
    }

    final tokenData = jsonDecode(tokenRes.body) as Map<String, dynamic>;
    final token = tokenData['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('토큰 응답 파싱 실패');
    }
    return token;
  }

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<String?> getStoredToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

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
