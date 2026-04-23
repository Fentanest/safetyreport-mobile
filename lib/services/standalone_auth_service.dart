import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StandaloneAuthService {
  static const _safetyReportBase = 'https://www.safetyreport.go.kr';
  static const _tokenKey = 'standaloneToken';

  // 로그인: RSA 공개키 조회 → 비밀번호 암호화 → OAuth2 토큰 발급
  static Future<String> login(String username, String password) async {
    final keyRes = await http
        .get(Uri.parse('$_safetyReportBase/api/v1/common/rsa/getPublicKey'))
        .timeout(const Duration(seconds: 10));

    if (keyRes.statusCode != 200) {
      throw Exception('RSA 키 조회 실패 (${keyRes.statusCode})');
    }

    final keyData = jsonDecode(keyRes.body) as Map<String, dynamic>;
    final modulusHex = keyData['RSAModulus'] as String;
    final exponentHex = keyData['RSAExponent'] as String;
    final encryptedPw = _rsaEncryptHex(modulusHex, exponentHex, password);

    final tokenRes = await http
        .post(
          Uri.parse('$_safetyReportBase/oauth/token'),
          body: {
            'client_id': 'web',
            'grant_type': 'password',
            'loginType': '1',
            'username': username,
            'password': encryptedPw,
          },
        )
        .timeout(const Duration(seconds: 15));

    if (tokenRes.statusCode == 401) {
      throw Exception('아이디 또는 비밀번호가 올바르지 않습니다.');
    }
    if (tokenRes.statusCode != 200) {
      throw Exception('로그인 실패 (HTTP ${tokenRes.statusCode})');
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

  // PKCS1 v1.5 RSA 암호화 → hex 문자열 반환 (JSEncrypt와 동일)
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

  // 저장된 토큰으로 신고 목록 API 호출 테스트 (연결 검증용)
  static Future<int> fetchReportCount(String token) async {
    final today = DateTime.now();
    final todayStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final res = await http.get(
      Uri.parse(
        '$_safetyReportBase/api/v1/portal/mypage/mysafereport'
        '?startRowNum=1&endRowNum=1'
        '&C_FRM_DATE=2014-01-01&C_TO_DATE=$todayStr'
        '&state=&seachType=tit&C_RELATION2=1&searchKeyWord=',
      ),
      headers: {'Authorization': 'BEARER $token'},
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw Exception('API 접근 실패 (${res.statusCode}) — 토큰이 만료되었을 수 있습니다.');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['totalCnt'] as num?)?.toInt() ?? 0;
  }
}
