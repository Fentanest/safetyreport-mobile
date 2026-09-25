import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/community_auth_config.dart';
import 'package:safetyreport/services/community_auth_link.dart';
import 'package:safetyreport/services/community_auth_pkce.dart';

void main() {
  group('PKCE', () {
    test('RFC 7636 부록 B 벡터와 같은 S256 challenge', () {
      // 독립 계산값(RFC 7636 Appendix B).
      expect(
        CommunityPkce.challengeFor(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        ),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('verifier 는 43자 base64url(패딩 없음), 매번 다름', () {
      final pattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        final v = CommunityPkce.generateVerifier();
        expect(v, matches(pattern));
        expect(CommunityPkce.challengeFor(v), matches(pattern));
        seen.add(v);
      }
      expect(seen.length, 50);
    });

    test('32바이트 입력 — 고정 난수로 재현 가능', () {
      final a = CommunityPkce.generateVerifier(Random(7));
      final b = CommunityPkce.generateVerifier(Random(7));
      expect(a, b);
      final bytes = base64Url.decode(base64Url.normalize(a));
      expect(bytes.length, 32);
    });
  });

  group('복귀 링크 해석 (M10)', () {
    const ok = 'com.fentanest.mysafetyreport://auth/callback';

    test('정확한 scheme/host/path + code 1개 → code', () {
      final r = CommunityCallback.parse(
        '$ok?code=0b6b2b1e-6f1c-4b8e-9d56-1d5e2f3a4b5c',
      );
      expect(r.kind, CommunityCallbackKind.code);
      expect(r.code, '0b6b2b1e-6f1c-4b8e-9d56-1d5e2f3a4b5c');
    });

    test('다른 scheme/host/path 는 우리 링크가 아님', () {
      for (final link in [
        'appsafetyreport://auth/callback?code=abcdefgh1234',
        'com.fentanest.mysafetyreport://auth/callbackx?code=abcdefgh1234',
        'com.fentanest.mysafetyreport://auth/callback/extra?code=abcdefgh1234',
        'com.fentanest.mysafetyreport://evil/callback?code=abcdefgh1234',
        'com.fentanest.mysafetyreport://auth.evil/callback?code=abcdefgh1234',
        'https://safeauth.worklazy.net/callback.html?code=abcdefgh1234',
        'http://auth/callback?code=abcdefgh1234',
        'com.fentanest.mysafetyreportx://auth/callback?code=abcdefgh1234',
        'com.fentanest.mysafetyreport://user@auth/callback?code=abcdefgh1234',
        'com.fentanest.mysafetyreport://auth:99/callback?code=abcdefgh1234',
        '',
        'not a url',
      ]) {
        expect(
          CommunityCallback.parse(link).kind,
          CommunityCallbackKind.notOurs,
          reason: link,
        );
      }
    });

    test('access_denied(query) → 취소', () {
      final r = CommunityCallback.parse(
        '$ok?error=access_denied&error_description=user+cancelled',
      );
      expect(r.kind, CommunityCallbackKind.cancelled);
    });

    test('fragment 의 오류도 읽는다', () {
      final denied = CommunityCallback.parse(
        '$ok#error=server_error&error_code=access_denied&error_description=x',
      );
      expect(denied.kind, CommunityCallbackKind.cancelled);
      final other = CommunityCallback.parse(
        '$ok#error=server_error&error_code=unexpected_failure',
      );
      expect(other.kind, CommunityCallbackKind.error);
      expect(other.errorCode, 'unexpected_failure');
    });

    test('code 가 없거나 둘이거나 형식이 이상하면 오류', () {
      expect(CommunityCallback.parse(ok).kind, CommunityCallbackKind.error);
      expect(
        CommunityCallback.parse('$ok?code=aaaaaaaa1&code=bbbbbbbb2').kind,
        CommunityCallbackKind.error,
      );
      expect(
        CommunityCallback.parse('$ok?code=%3Cscript%3E').kind,
        CommunityCallbackKind.error,
      );
    });
  });

  group('빌드 설정', () {
    test('비었으면 설정되지 않음', () {
      expect(
        CommunityAuthConfig.validate(url: '', key: '').isConfigured,
        isFalse,
      );
      expect(
        CommunityAuthConfig.validate(
          url: 'https://x.supabase.co',
          key: '',
        ).isConfigured,
        isFalse,
      );
    });

    test('https 만, 끝 / 제거', () {
      final c = CommunityAuthConfig.validate(
        url: 'https://x.supabase.co/',
        key: 'sb_publishable_abc',
      );
      expect(c.isConfigured, isTrue);
      expect(c.supabaseUrl, 'https://x.supabase.co');
      expect(
        CommunityAuthConfig.validate(
          url: 'http://x.supabase.co',
          key: 'sb_publishable_abc',
        ).isConfigured,
        isFalse,
      );
    });

    test('loopback http 는 디버그 허용일 때만', () {
      for (final u in ['http://127.0.0.1:54321', 'http://10.0.2.2:54321']) {
        expect(
          CommunityAuthConfig.validate(url: u, key: 'k').isConfigured,
          isFalse,
        );
        expect(
          CommunityAuthConfig.validate(
            url: u,
            key: 'k',
            allowLoopbackHttp: true,
          ).isConfigured,
          isTrue,
        );
      }
      expect(
        CommunityAuthConfig.validate(
          url: 'http://192.168.0.2:54321',
          key: 'k',
          allowLoopbackHttp: true,
        ).isConfigured,
        isFalse,
      );
    });

    test('secret 키·service_role JWT 거부', () {
      expect(
        CommunityAuthConfig.validate(
          url: 'https://x.supabase.co',
          key: 'sb_secret_abc',
        ).isConfigured,
        isFalse,
      );
      String seg(Map<String, Object> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      final serviceRole =
          '${seg({'alg': 'HS256'})}.${seg({'role': 'service_role'})}.sig';
      final anon = '${seg({'alg': 'HS256'})}.${seg({'role': 'anon'})}.sig';
      expect(
        CommunityAuthConfig.validate(
          url: 'https://x.supabase.co',
          key: serviceRole,
        ).isConfigured,
        isFalse,
      );
      expect(
        CommunityAuthConfig.validate(
          url: 'https://x.supabase.co',
          key: anon,
        ).isConfigured,
        isTrue,
      );
    });
  });
}
