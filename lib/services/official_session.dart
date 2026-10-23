import 'dart:convert';
import 'dart:io';

/// 공식 사이트 토큰과 서버 세션을 한 저장 단위로 묶는다. 로그에 출력하지 않는다.
class OfficialSession {
  const OfficialSession({
    required this.token,
    required this.username,
    required this.epoch,
    required this.cookies,
    this.expiresAt,
  });
  final String token;
  final String username;
  final String epoch;
  final int? expiresAt;
  final Map<String, String> cookies;
  bool get ready =>
      token.isNotEmpty && (cookies['JSESSIONID']?.isNotEmpty ?? false);
  String get cookieHeader => [
    for (final name in cookieNames)
      if (cookies[name]?.isNotEmpty ?? false) '$name=${cookies[name]}',
  ].join('; ');
  static const cookieNames = ['JSESSIONID', 'WMONID'];

  static Map<String, String> mergeCookies(
    Map<String, String> previous,
    Iterable<Cookie> updates,
  ) {
    final result = Map<String, String>.of(previous);
    for (final c in updates) {
      if (!cookieNames.contains(c.name)) continue;
      if (c.value.isEmpty ||
          (c.maxAge != null && c.maxAge! <= 0) ||
          (c.maxAge == null &&
              c.expires != null &&
              !c.expires!.isAfter(DateTime.now()))) {
        result.remove(c.name);
      } else {
        result[c.name] = c.value;
      }
    }
    return result;
  }

  static Iterable<Cookie> parseSetCookie(String? raw) sync* {
    if (raw == null) return;
    // package:http 는 여러 Set-Cookie를 합친다. Expires의 날짜 쉼표는 분리하지 않는다.
    for (final part in raw.split(
      RegExp(r',(?=\s*[A-Za-z0-9_!#$%&*+.^`|~-]+=)'),
    )) {
      try {
        yield Cookie.fromSetCookieValue(part.trim());
      } on FormatException {
        /* 잘못된 쿠키는 사용하지 않는다. */
      }
    }
  }

  String encode() => jsonEncode({
    'token': token,
    'username': username,
    'epoch': epoch,
    'expires_at': expiresAt,
    'cookies': cookies,
  });
  static OfficialSession? decode(String? raw) {
    try {
      final m = jsonDecode(raw!) as Map;
      final cookies = (m['cookies'] as Map).cast<String, String>();
      return OfficialSession(
        token: m['token'] as String,
        username: m['username'] as String,
        epoch: m['epoch'] as String,
        expiresAt: m['expires_at'] as int?,
        cookies: {
          for (final name in cookieNames)
            if (cookies[name] != null) name: cookies[name]!,
        },
      );
    } catch (_) {
      return null;
    }
  }
}
