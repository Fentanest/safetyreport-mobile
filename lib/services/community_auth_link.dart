import 'community_auth_config.dart';

/// 로그인 복귀 링크(`com.fentanest.mysafetyreport://auth/callback?...`) 해석 결과.
enum CommunityCallbackKind {
  /// 우리 링크가 아님(다른 scheme/host/path, 공식 앱 outbound 스킴 등) — 아무것도 하지 않는다.
  notOurs,

  /// 인가 코드 1개.
  code,

  /// 사용자가 카카오/Supabase 화면에서 취소(`access_denied`).
  cancelled,

  /// 그 밖의 오류(provider·Supabase 오류, 코드 형식 이상, 코드 없음).
  error,
}

class CommunityCallback {
  final CommunityCallbackKind kind;

  /// [CommunityCallbackKind.code] 일 때만.
  final String? code;

  /// 오류 코드(`error_code` 또는 `error`). 화면에는 그대로 보이지 않는다.
  final String? errorCode;

  const CommunityCallback._(this.kind, {this.code, this.errorCode});

  static const notOurs = CommunityCallback._(CommunityCallbackKind.notOurs);

  /// Supabase 현행 auth code 는 UUID 다. 중계 프로토콜과 같은 느슨한 문자 규칙을 쓴다.
  static final _codePattern = RegExp(r'^[A-Za-z0-9._~-]{8,512}$');

  /// scheme/host/path 가 정확히 같을 때만 해석한다. query 와 fragment 양쪽에서 오류를 찾는다.
  static CommunityCallback parse(String link) {
    if (link.length > 4096) return notOurs;
    final Uri uri;
    try {
      uri = Uri.parse(link);
    } catch (_) {
      return notOurs;
    }
    if (uri.scheme != CommunityAuthConfig.redirectScheme ||
        uri.host != CommunityAuthConfig.redirectHost ||
        uri.path != CommunityAuthConfig.redirectPath ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return notOurs;
    }
    final query = _split(uri.hasQuery ? uri.query : '');
    final frag = _split(uri.hasFragment ? uri.fragment : '');
    final error = _first(query, 'error') ?? _first(frag, 'error');
    if (error != null && error.isNotEmpty) {
      final errorCode =
          _first(query, 'error_code') ?? _first(frag, 'error_code') ?? '';
      if (error == 'access_denied' || errorCode == 'access_denied') {
        return const CommunityCallback._(
          CommunityCallbackKind.cancelled,
          errorCode: 'access_denied',
        );
      }
      return CommunityCallback._(
        CommunityCallbackKind.error,
        errorCode: errorCode.isNotEmpty ? errorCode : error,
      );
    }
    final codes = query['code'] ?? const <String>[];
    if (codes.length == 1 && _codePattern.hasMatch(codes.first)) {
      return CommunityCallback._(CommunityCallbackKind.code, code: codes.first);
    }
    return CommunityCallback._(
      CommunityCallbackKind.error,
      errorCode: codes.isEmpty ? 'missing_code' : 'invalid_code',
    );
  }

  /// 같은 이름이 여러 번 나오면(`code=a&code=b`) 모두 모은다 — 코드가 둘이면 거부하기 위해.
  static Map<String, List<String>> _split(String raw) {
    final out = <String, List<String>>{};
    for (final part in raw.split('&')) {
      if (part.isEmpty) continue;
      final i = part.indexOf('=');
      try {
        final k = Uri.decodeQueryComponent(i < 0 ? part : part.substring(0, i));
        final v = i < 0 ? '' : Uri.decodeQueryComponent(part.substring(i + 1));
        (out[k] ??= <String>[]).add(v);
      } catch (_) {
        // 잘못된 % 인코딩 조각은 버린다.
      }
    }
    return out;
  }

  static String? _first(Map<String, List<String>> m, String k) {
    final v = m[k];
    return v == null || v.isEmpty ? null : v.first;
  }
}
