import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;

/// Standalone 커뮤니티 계정(Supabase Auth + 카카오) 빌드 설정.
///
/// 값은 공개값이며 빌드할 때 `--dart-define` 으로만 넣는다(코드·레포에 넣지 않는다).
/// - `COMMUNITY_SUPABASE_URL` — 예: `https://<project>.supabase.co`
/// - `COMMUNITY_SUPABASE_PUBLISHABLE_KEY` — `sb_publishable_...` 또는 anon 키
///
/// 둘 중 하나라도 비었거나 규칙에 어긋나면 "설정되지 않음" 으로 보고 로그인 버튼을 보이지 않는다.
/// 설계: `docs/architecture/community-account.md`.
class CommunityAuthConfig {
  /// Supabase Redirect URLs 에 정확히 이 값이 등록되어 있어야 한다.
  static const redirectUri = 'com.fentanest.mysafetyreport://auth/callback';
  static const redirectScheme = 'com.fentanest.mysafetyreport';
  static const redirectHost = 'auth';
  static const redirectPath = '/callback';

  static const _envUrl = String.fromEnvironment('COMMUNITY_SUPABASE_URL');
  static const _envKey = String.fromEnvironment(
    'COMMUNITY_SUPABASE_PUBLISHABLE_KEY',
  );

  /// 끝 `/` 를 뗀 Supabase 프로젝트 주소. 설정되지 않았으면 빈 문자열.
  final String supabaseUrl;
  final String publishableKey;

  /// 설정이 없거나 거부된 이유(설정 화면·로그용, 비밀값 없음). 정상이면 null.
  final String? problem;

  const CommunityAuthConfig._(
    this.supabaseUrl,
    this.publishableKey,
    this.problem,
  );

  bool get isConfigured => problem == null;

  /// 빌드 설정(`--dart-define`)에서 읽는다.
  static final CommunityAuthConfig fromEnvironment = validate(
    url: _envUrl,
    key: _envKey,
    allowLoopbackHttp: kDebugMode,
  );

  /// 설정값 검사. [allowLoopbackHttp] 는 디버그 빌드에서 로컬 Supabase(`http://127.0.0.1`,
  /// 에뮬레이터의 `http://10.0.2.2`)만 허용하기 위한 것이다.
  static CommunityAuthConfig validate({
    required String url,
    required String key,
    bool allowLoopbackHttp = false,
  }) {
    final rawUrl = url.trim();
    final rawKey = key.trim();
    if (rawUrl.isEmpty || rawKey.isEmpty) {
      return const CommunityAuthConfig._(
        '',
        '',
        '빌드 설정에 커뮤니티 서버 주소·공개 키가 없습니다.',
      );
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty) {
      return const CommunityAuthConfig._('', '', '커뮤니티 서버 주소 형식이 올바르지 않습니다.');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return const CommunityAuthConfig._(
        '',
        '',
        '커뮤니티 서버 주소에 허용되지 않는 부분이 있습니다.',
      );
    }
    final loopback = uri.host == '127.0.0.1' || uri.host == '10.0.2.2';
    final schemeOk =
        uri.scheme == 'https' ||
        (uri.scheme == 'http' && loopback && allowLoopbackHttp);
    if (!schemeOk) {
      return const CommunityAuthConfig._('', '', '커뮤니티 서버 주소는 https 여야 합니다.');
    }
    if (_isSecretKey(rawKey)) {
      return const CommunityAuthConfig._(
        '',
        '',
        '비밀 키(secret/service_role)는 앱에 넣을 수 없습니다.',
      );
    }
    final normalized = rawUrl.replaceFirst(RegExp(r'/+$'), '');
    return CommunityAuthConfig._(normalized, rawKey, null);
  }

  static bool _isSecretKey(String key) {
    if (key.startsWith('sb_secret_')) return true;
    // 옛 JWT 형식 키: payload 의 role 이 service_role 이면 거부.
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final json = jsonDecode(payload);
      return json is Map && json['role'] == 'service_role';
    } catch (_) {
      return false;
    }
  }

  Uri authUri(String path, [Map<String, String>? query]) => Uri.parse(
    '$supabaseUrl/auth/v1/$path',
  ).replace(queryParameters: query == null || query.isEmpty ? null : query);
}
