import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PKCE(RFC 7636) S256. verifier 는 이 기기 밖으로 나가지 않는다(Supabase `/token` 교환 때만 전송).
class CommunityPkce {
  CommunityPkce._();

  /// 32바이트 난수 → base64url(패딩 없음) 43자.
  static String generateVerifier([Random? random]) => randomToken(32, random);

  /// base64url(SHA-256(ascii(verifier))), 패딩 없음.
  static String challengeFor(String verifier) =>
      _b64NoPad(sha256.convert(ascii.encode(verifier)).bytes);

  static String randomToken(int bytes, [Random? random]) {
    final rng = random ?? Random.secure();
    return _b64NoPad(List<int>.generate(bytes, (_) => rng.nextInt(256)));
  }

  static String _b64NoPad(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
