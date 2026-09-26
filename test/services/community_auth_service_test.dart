import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/community_auth_config.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _supabase = 'https://proj.supabase.test';
const _link = 'com.fentanest.mysafetyreport://auth/callback';
const _code = '0b6b2b1e-6f1c-4b8e-9d56-1d5e2f3a4b5c';

/// 가짜 Supabase Auth(GoTrue v2.197.0 모양). 실제 Supabase·카카오에는 닿지 않는다.
class _FakeAuth {
  final requests = <http.Request>[];
  var _serial = 0;
  String userId = 'user-a';
  String nickname = '테스터';
  DateTime Function() now;
  http.Response Function(http.Request req)? pkceOverride;
  http.Response Function(http.Request req)? refreshOverride;
  Completer<void>? refreshGate;
  bool throwOnRefresh = false;

  _FakeAuth(this.now);

  int count(String path, [String? grant]) => requests
      .where(
        (r) =>
            r.url.path == path &&
            (grant == null || r.url.queryParameters['grant_type'] == grant),
      )
      .length;

  http.Response _tokens() {
    _serial++;
    final exp = now().millisecondsSinceEpoch ~/ 1000 + 3600;
    return http.Response(
      jsonEncode({
        'access_token': 'acc-$_serial',
        'refresh_token': 'ref-$_serial',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': exp,
        'user': {'id': userId},
      }),
      200,
    );
  }

  late final client = MockClient((req) async {
    requests.add(req);
    expect(req.url.origin, _supabase, reason: 'Supabase 외 주소 호출 금지');
    expect(req.headers['apikey'], 'sb_publishable_test');
    switch (req.url.path) {
      case '/auth/v1/token':
        final grant = req.url.queryParameters['grant_type'];
        if (grant == 'pkce') {
          if (pkceOverride != null) return pkceOverride!(req);
          return _tokens();
        }
        if (grant == 'refresh_token') {
          if (refreshGate != null) await refreshGate!.future;
          if (throwOnRefresh) throw http.ClientException('offline');
          if (refreshOverride != null) return refreshOverride!(req);
          return _tokens();
        }
        return http.Response('{}', 400);
      case '/auth/v1/user':
        // 헤더에 charset 이 없어도 UTF-8 로 읽어야 한다(한글 닉네임).
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'id': userId,
              'email': 'hidden@example.test',
              'user_metadata': {'nickname': nickname},
            }),
          ),
          200,
        );
      case '/auth/v1/logout':
        return http.Response('', 204);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> secure;
  late DateTime now;
  late _FakeAuth fake;
  late List<Uri> launched;
  late CommunityAuthService svc;
  final config = CommunityAuthConfig.validate(
    url: _supabase,
    key: 'sb_publishable_test',
  );

  CommunityAuthService build({CommunityAuthConfig? cfg}) =>
      CommunityAuthService(
        config: cfg ?? config,
        client: fake.client,
        storage: const FlutterSecureStorage(),
        launcher: (u) async {
          // 브라우저를 열기 전에 대기 로그인이 이미 저장되어 있어야 한다.
          expect(
            secure.containsKey(CommunityAuthService.pendingLoginKey),
            isTrue,
          );
          launched.add(u);
          return true;
        },
        now: () => now,
      );

  void seedSession({
    String userId = 'user-a',
    String name = '기존계정',
    required DateTime expiresAt,
    String access = 'acc-old',
    String refresh = 'ref-old',
  }) {
    secure[CommunityAuthService.sessionKey] = jsonEncode({
      'v': 1,
      'access_token': access,
      'refresh_token': refresh,
      'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
      'user_id': userId,
      'display_name': name,
      'has_email': false,
      'connected_at': '2026-09-20T01:00:00Z',
      'state': 'active',
    });
  }

  Map<String, dynamic>? stored() {
    final raw = secure[CommunityAuthService.sessionKey];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  setUp(() {
    secure = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(secure);
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 9, 25, 10);
    fake = _FakeAuth(() => now);
    launched = [];
    svc = build();
  });

  group('로그인 시작', () {
    test('대기 로그인을 먼저 저장하고 authorize 주소를 외부 브라우저로 연다', () async {
      final r = await svc.startLogin();
      expect(r, CommunityStartOutcome.launched);
      expect(launched, hasLength(1));
      final url = launched.single;
      expect(url.toString(), startsWith('$_supabase/auth/v1/authorize?'));
      expect(
        url.toString(),
        contains(
          'redirect_to=com.fentanest.mysafetyreport%3A%2F%2Fauth%2Fcallback',
        ),
      );
      expect(url.queryParameters['provider'], 'kakao');
      expect(url.queryParameters['code_challenge_method'], 's256');
      expect(url.queryParameters['code_challenge'], hasLength(43));
      final pending =
          jsonDecode(secure[CommunityAuthService.pendingLoginKey]!) as Map;
      expect(pending['verifier'], hasLength(43));
      // verifier 는 URL 에 없다.
      expect(url.toString(), isNot(contains(pending['verifier'] as String)));
      expect(svc.state.value.phase, CommunityAccountPhase.awaitingBrowser);
      expect(fake.requests, isEmpty);
    });

    test('설정되지 않은 빌드는 브라우저를 열지 않는다', () async {
      svc = build(
        cfg: CommunityAuthConfig.validate(url: '', key: ''),
      );
      expect(await svc.startLogin(), CommunityStartOutcome.unconfigured);
      expect(launched, isEmpty);
      expect(svc.state.value.phase, CommunityAccountPhase.unconfigured);
    });

    test('브라우저를 못 열면 대기 로그인을 지운다', () async {
      svc = CommunityAuthService(
        config: config,
        client: fake.client,
        storage: const FlutterSecureStorage(),
        launcher: (_) async => false,
        now: () => now,
      );
      expect(await svc.startLogin(), CommunityStartOutcome.launchFailed);
      expect(secure.containsKey(CommunityAuthService.pendingLoginKey), isFalse);
    });
  });

  group('복귀 링크', () {
    test('대기 로그인이 없으면 무시하고 교환하지 않는다', () async {
      final r = await svc.handleCallbackLink('$_link?code=$_code');
      expect(r, CommunityLinkOutcome.ignoredNoPending);
      expect(fake.requests, isEmpty);
      expect(svc.state.value.notice, contains('다시 시작'));
    });

    test('우리 링크가 아니면 아무것도 하지 않는다', () async {
      await svc.startLogin();
      final r = await svc.handleCallbackLink(
        'appsafetyreport://auth/callback?code=$_code',
      );
      expect(r, CommunityLinkOutcome.notOurs);
      expect(fake.requests, isEmpty);
      expect(secure.containsKey(CommunityAuthService.pendingLoginKey), isTrue);
    });

    test('10분 지난 대기 로그인은 무시하고 지운다', () async {
      await svc.startLogin();
      now = now.add(const Duration(minutes: 11));
      final r = await svc.handleCallbackLink('$_link?code=$_code');
      expect(r, CommunityLinkOutcome.ignoredExpired);
      expect(fake.requests, isEmpty);
      expect(secure.containsKey(CommunityAuthService.pendingLoginKey), isFalse);
    });

    test('중복 링크(동시·연속·새 로그인 뒤 재전달)에도 교환은 한 번 (M02)', () async {
      await svc.startLogin();
      final results = await Future.wait([
        svc.handleCallbackLink('$_link?code=$_code'),
        svc.handleCallbackLink('$_link?code=$_code'),
      ]);
      expect(results, contains(CommunityLinkOutcome.confirmRequired));
      expect(results, contains(CommunityLinkOutcome.ignoredDuplicate));
      expect(fake.count('/auth/v1/token', 'pkce'), 1);

      // 같은 링크가 나중에 다시 와도(콜드 스타트 재전달) 교환하지 않는다.
      expect(
        await svc.handleCallbackLink('$_link?code=$_code'),
        CommunityLinkOutcome.ignoredDuplicate,
      );
      // 사용자가 새 로그인을 시작한 뒤 옛 링크가 와도 새 대기 로그인을 소비하지 않는다.
      await svc.cancelCandidate();
      await svc.startLogin();
      expect(
        await svc.handleCallbackLink('$_link?code=$_code'),
        CommunityLinkOutcome.ignoredDuplicate,
      );
      expect(secure.containsKey(CommunityAuthService.pendingLoginKey), isTrue);
      expect(fake.count('/auth/v1/token', 'pkce'), 1);
    });

    test('verifier 를 교환에 쓰고, 확인 전에는 저장하지 않는다', () async {
      await svc.startLogin();
      final verifier =
          (jsonDecode(secure[CommunityAuthService.pendingLoginKey]!)
                  as Map)['verifier']
              as String;
      final r = await svc.handleCallbackLink('$_link?code=$_code');
      expect(r, CommunityLinkOutcome.confirmRequired);
      final pkce = fake.requests.firstWhere(
        (q) => q.url.queryParameters['grant_type'] == 'pkce',
      );
      expect(jsonDecode(pkce.body), {
        'auth_code': _code,
        'code_verifier': verifier,
      });
      expect(fake.count('/auth/v1/user'), 1);
      final userReq = fake.requests.firstWhere(
        (q) => q.url.path == '/auth/v1/user',
      );
      expect(userReq.headers['Authorization'], 'Bearer acc-1');
      expect(secure.containsKey(CommunityAuthService.pendingLoginKey), isFalse);
      expect(stored(), isNull);
      final st = svc.state.value;
      expect(st.phase, CommunityAccountPhase.confirmRequired);
      expect(st.candidate!.displayName, '테스터');
      expect(st.candidate!.isDifferentAccount, isFalse);
    });

    test('확인하면 보안 저장소에만 저장, SharedPreferences 에 토큰 없음 (M08)', () async {
      await svc.startLogin();
      await svc.handleCallbackLink('$_link?code=$_code');
      expect(await svc.confirmCandidate(), isTrue);
      final s = stored()!;
      expect(s['access_token'], 'acc-1');
      expect(s['refresh_token'], 'ref-1');
      expect(s['display_name'], '테스터');
      expect(svc.state.value.phase, CommunityAccountPhase.connected);
      expect(svc.state.value.account!.displayName, '테스터');

      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        final v = '${prefs.get(k)}';
        expect(v, isNot(contains('acc-1')), reason: k);
        expect(v, isNot(contains('ref-1')), reason: k);
      }
      // 확인은 한 번만.
      expect(await svc.confirmCandidate(), isFalse);
    });

    test('취소하면 새 세션을 logout?scope=local 로 닫고 저장하지 않는다', () async {
      await svc.startLogin();
      await svc.handleCallbackLink('$_link?code=$_code');
      await svc.cancelCandidate();
      final logout = fake.requests.singleWhere(
        (q) => q.url.path == '/auth/v1/logout',
      );
      expect(logout.url.queryParameters['scope'], 'local');
      expect(logout.headers['Authorization'], 'Bearer acc-1');
      expect(stored(), isNull);
      expect(svc.state.value.phase, CommunityAccountPhase.disconnected);
    });

    test('다른 계정이면 교체 경고, 확인하면 옛 세션만 local 로그아웃', () async {
      seedSession(
        userId: 'user-old',
        expiresAt: now.add(const Duration(hours: 1)),
      );
      await svc.load();
      expect(svc.state.value.phase, CommunityAccountPhase.connected);
      await svc.startLogin();
      await svc.handleCallbackLink('$_link?code=$_code');
      final st = svc.state.value;
      expect(st.candidate!.isDifferentAccount, isTrue);
      expect(st.account!.displayName, '기존계정');
      // 확인 전에는 옛 연결이 그대로다.
      expect(stored()!['user_id'], 'user-old');
      await svc.confirmCandidate();
      await pumpEventQueue();
      expect(stored()!['user_id'], 'user-a');
      final logout = fake.requests.singleWhere(
        (q) => q.url.path == '/auth/v1/logout',
      );
      expect(logout.url.queryParameters['scope'], 'local');
      expect(logout.headers['Authorization'], 'Bearer acc-old');
    });

    test('access_denied → 취소, 교환 없음, 대기 로그인 삭제', () async {
      await svc.startLogin();
      final r = await svc.handleCallbackLink(
        '$_link?error=access_denied&error_description=cancel',
      );
      expect(r, CommunityLinkOutcome.cancelled);
      expect(fake.requests, isEmpty);
      expect(secure.containsKey(CommunityAuthService.pendingLoginKey), isFalse);
    });

    test('교환 거부(bad_code_verifier) → 실패, 세션 없음, 재교환 없음', () async {
      fake.pkceOverride = (_) => http.Response(
        jsonEncode({
          'code': 400,
          'error_code': 'bad_code_verifier',
          'msg': 'code challenge does not match previously saved code verifier',
        }),
        400,
      );
      await svc.startLogin();
      final r = await svc.handleCallbackLink('$_link?code=$_code');
      expect(r, CommunityLinkOutcome.failed);
      expect(stored(), isNull);
      expect(svc.state.value.notice, contains('다시 시작'));
      expect(
        await svc.handleCallbackLink('$_link?code=$_code'),
        CommunityLinkOutcome.ignoredDuplicate,
      );
      expect(fake.count('/auth/v1/token', 'pkce'), 1);
    });
  });

  group('세션 공급', () {
    test('만료가 멀면 갱신하지 않는다', () async {
      seedSession(expiresAt: now.add(const Duration(minutes: 30)));
      expect(await svc.getAccessToken(), 'acc-old');
      expect(fake.requests, isEmpty);
    });

    test('동시 두 호출 → 갱신 한 번, 회전된 access+refresh 함께 저장', () async {
      seedSession(expiresAt: now.add(const Duration(seconds: 30)));
      fake.refreshGate = Completer<void>();
      final a = svc.getAccessToken();
      final b = svc.getAccessToken();
      await pumpEventQueue();
      fake.refreshGate!.complete();
      expect(await a, 'acc-1');
      expect(await b, 'acc-1');
      expect(fake.count('/auth/v1/token', 'refresh_token'), 1);
      final req = fake.requests.single;
      expect(jsonDecode(req.body), {'refresh_token': 'ref-old'});
      expect(stored()!['access_token'], 'acc-1');
      expect(stored()!['refresh_token'], 'ref-1');
    });

    for (final code in [
      'refresh_token_not_found',
      'refresh_token_already_used',
      'session_not_found',
      'session_expired',
    ]) {
      test('$code → 다시 로그인 필요, 토큰 삭제', () async {
        seedSession(expiresAt: now.subtract(const Duration(minutes: 1)));
        fake.refreshOverride = (_) => http.Response(
          jsonEncode({'code': 400, 'error_code': code, 'msg': 'x'}),
          400,
        );
        final r = await svc.getAccessTokenResult();
        expect(r.status, CommunityTokenStatus.reauthRequired);
        expect(r.accessToken, isNull);
        expect(stored()!['state'], 'reauth_required');
        expect(stored()!['refresh_token'], '');
        expect(stored()!['display_name'], '기존계정');
        expect(svc.state.value.phase, CommunityAccountPhase.reauthRequired);
      });
    }

    test('네트워크 오류: 아직 유효하면 기존 토큰, 만료면 일시 오류 — 세션 유지', () async {
      fake.throwOnRefresh = true;
      seedSession(expiresAt: now.add(const Duration(seconds: 30)));
      expect(await svc.getAccessToken(), 'acc-old');
      seedSession(expiresAt: now.subtract(const Duration(seconds: 1)));
      final r = await svc.getAccessTokenResult();
      expect(r.status, CommunityTokenStatus.temporarilyUnavailable);
      expect(stored()!['refresh_token'], 'ref-old');
      expect(stored()!['state'], 'active');
    });

    test('5xx 는 다시 로그인 필요로 바꾸지 않는다', () async {
      seedSession(expiresAt: now.subtract(const Duration(seconds: 1)));
      fake.refreshOverride = (_) => http.Response('{"code":500}', 503);
      final r = await svc.getAccessTokenResult();
      expect(r.status, CommunityTokenStatus.temporarilyUnavailable);
      expect(stored()!['state'], 'active');
    });

    test('연결 안 됨이면 토큰 없음', () async {
      final r = await svc.getAccessTokenResult();
      expect(r.status, CommunityTokenStatus.notConnected);
      expect(fake.requests, isEmpty);
    });
  });

  group('연결 해제 / 모드 분리', () {
    test('disconnect 는 logout?scope=local 후 로컬 세션 삭제', () async {
      seedSession(expiresAt: now.add(const Duration(hours: 1)));
      final r = await svc.disconnect();
      expect(r.hadSession, isTrue);
      expect(r.serverLogoutConfirmed, isTrue);
      final logout = fake.requests.single;
      expect(logout.url.path, '/auth/v1/logout');
      expect(logout.method, 'POST');
      expect(logout.url.queryParameters['scope'], 'local');
      expect(logout.headers['Authorization'], 'Bearer acc-old');
      expect(stored(), isNull);
      expect(svc.state.value.phase, CommunityAccountPhase.disconnected);
    });

    test('서버 로그아웃 실패여도 로컬은 지우고 미확인으로 알린다', () async {
      seedSession(expiresAt: now.add(const Duration(hours: 1)));
      final offline = CommunityAuthService(
        config: config,
        client: MockClient((_) async => throw http.ClientException('off')),
        storage: const FlutterSecureStorage(),
        now: () => now,
      );
      final r = await offline.disconnect();
      expect(r.serverLogoutConfirmed, isFalse);
      expect(stored(), isNull);
    });

    test(
      'ReportProvider.resetConfig 가 Standalone 커뮤니티 세션·대기 로그인을 지운다 (M05)',
      () async {
        const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(perm, (_) async => true);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(perm, null),
        );
        BackgroundLoginCheck.schedulingEnabled = false;
        addTearDown(() => BackgroundLoginCheck.schedulingEnabled = true);
        SharedPreferences.setMockInitialValues({
          AppPrefsKeys.appMode: 'standalone',
        });
        seedSession(expiresAt: now.add(const Duration(hours: 1)));
        secure[CommunityAuthService.pendingLoginKey] = '{"v":1}';
        secure[AppPrefsKeys.standalonePassword] = 'pw';
        CommunityAuthService.instance = svc;

        await ReportProvider().resetConfig();
        await pumpEventQueue();

        expect(secure.containsKey(CommunityAuthService.sessionKey), isFalse);
        expect(
          secure.containsKey(CommunityAuthService.pendingLoginKey),
          isFalse,
        );
        // 기존 동작 유지: 안전신문고 비밀번호도 지운다(StandaloneAuthService.clearToken).
        expect(secure.containsKey(AppPrefsKeys.standalonePassword), isFalse);
        // 세션은 다른 곳으로 옮겨지지 않는다.
        final prefs = await SharedPreferences.getInstance();
        for (final k in prefs.getKeys()) {
          expect('${prefs.get(k)}', isNot(contains('acc-old')));
        }
        expect(svc.state.value.phase, CommunityAccountPhase.disconnected);
      },
    );
  });
}
