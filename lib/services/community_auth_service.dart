import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'app_prefs_keys.dart';
import 'community_auth_config.dart';
import 'community_auth_link.dart';
import 'community_auth_pkce.dart';

/// Standalone 커뮤니티 계정 화면 상태.
enum CommunityAccountPhase {
  /// 빌드 설정(`--dart-define`)이 없음 — 로그인 버튼 없음.
  unconfigured,
  disconnected,

  /// 로그인을 시작해 브라우저로 보냄. 복귀 링크를 기다리는 중.
  awaitingBrowser,

  /// 복귀 링크를 받아 코드 교환·계정 확인 중.
  exchanging,

  /// 교환은 끝났고 사용자가 "이 계정으로 연결" 을 눌러야 저장된다.
  confirmRequired,
  connected,

  /// refresh token 이 만료·철회됨 — 다시 로그인해야 한다.
  reauthRequired,
}

/// 저장된(연결된) 계정의 화면용 정보. 토큰·전역 사용자 UUID·이메일은 담지 않는다.
class CommunityAccountInfo {
  final String displayName;
  final DateTime? connectedAt;
  const CommunityAccountInfo({required this.displayName, this.connectedAt});
}

/// 교환 직후, 저장 전 확인할 계정.
class CommunityCandidate {
  final String displayName;
  final bool hasEmail;

  /// 이미 다른 계정이 연결되어 있고, 확인하면 그 연결을 바꾼다.
  final bool isDifferentAccount;
  const CommunityCandidate({
    required this.displayName,
    required this.hasEmail,
    required this.isDifferentAccount,
  });
}

class CommunityAuthState {
  final CommunityAccountPhase phase;
  final CommunityAccountInfo? account;
  final CommunityCandidate? candidate;

  /// 마지막 안내 문구(사용자용 한국어, 비밀값 없음). [noticeSerial] 이 바뀔 때 한 번 알린다.
  final String? notice;
  final int noticeSerial;

  const CommunityAuthState(
    this.phase, {
    this.account,
    this.candidate,
    this.notice,
    this.noticeSerial = 0,
  });
}

/// 복귀 링크 처리 결과(테스트·로그용).
enum CommunityLinkOutcome {
  notOurs,
  ignoredDuplicate,
  ignoredNoPending,
  ignoredExpired,
  cancelled,
  failed,
  confirmRequired,
}

enum CommunityStartOutcome { launched, unconfigured, launchFailed }

enum CommunityTokenStatus {
  ok,
  notConfigured,
  notConnected,
  reauthRequired,

  /// 네트워크·5xx 등으로 지금은 유효한 토큰을 못 얻음. 세션은 그대로 둔다.
  temporarilyUnavailable,
}

class CommunityTokenResult {
  final CommunityTokenStatus status;
  final String? accessToken;
  const CommunityTokenResult(this.status, [this.accessToken]);
}

class CommunityDisconnectResult {
  /// 이 기기에 저장된 세션이 있었는가.
  final bool hadSession;

  /// Supabase `logout?scope=local` 이 성공(204/200)으로 확인됐는가. false 여도 로컬 세션은 지웠다.
  final bool serverLogoutConfirmed;
  const CommunityDisconnectResult({
    required this.hadSession,
    required this.serverLogoutConfirmed,
  });
}

/// Standalone 모드의 커뮤니티 계정(Supabase Auth, 카카오) — 이 앱이 인증·세션의 주인이다.
///
/// - PKCE(S256) + 외부 브라우저(RFC 8252). 앱 WebView 에서 카카오 비밀번호를 받지 않는다.
/// - 복귀 링크: `com.fentanest.mysafetyreport://auth/callback` (MainActivity → MethodChannel
///   `com.fentanest.mysafetyreport/community_auth`, [CommunityAuthLinkChannel]).
/// - 세션·대기 로그인은 `flutter_secure_storage` 에만 저장한다(SharedPreferences·sqflite 금지).
/// - Supabase Auth REST 계약은 GoTrue v2.197.0 기준(safeauth protocol.md §6). supabase_flutter 는 쓰지 않는다.
///
/// 설계: `docs/architecture/community-account.md`.
class CommunityAuthService {
  static const sessionKey = AppPrefsKeys.communitySession;
  static const pendingLoginKey = AppPrefsKeys.communityPendingLogin;
  static const consumedCallbackKey = AppPrefsKeys.communityConsumedCallback;

  /// 대기 로그인 유효 시간. Supabase flow state 는 300초지만, 늦게 도착한 링크에
  /// "다시 시작" 안내를 하려고 조금 넉넉히 둔다(교환 자체는 Supabase 가 거부).
  static const pendingLoginTtl = Duration(minutes: 10);

  /// access token 이 이만큼 안에 만료되면 미리 갱신한다.
  static const refreshMargin = Duration(seconds: 60);

  static const _invalidGrantCodes = {
    'refresh_token_not_found',
    'refresh_token_already_used',
    'session_not_found',
    'session_expired',
  };

  static const _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static CommunityAuthService? _instance;
  static CommunityAuthService get instance =>
      _instance ??= CommunityAuthService();
  @visibleForTesting
  static set instance(CommunityAuthService value) => _instance = value;

  final CommunityAuthConfig config;
  final http.Client? _client;
  final FlutterSecureStorage _storage;
  final Future<bool> Function(Uri uri) _launcher;
  final DateTime Function() _now;
  final Random? _random;
  final Duration _timeout;

  final ValueNotifier<CommunityAuthState> state;

  CommunityAuthService({
    CommunityAuthConfig? config,
    http.Client? client,
    FlutterSecureStorage? storage,
    Future<bool> Function(Uri uri)? launcher,
    DateTime Function()? now,
    Random? random,
    Duration timeout = const Duration(seconds: 15),
  }) : config = config ?? CommunityAuthConfig.fromEnvironment,
       _client = client,
       _storage = storage ?? _defaultStorage,
       _launcher = launcher ?? _launchExternal,
       _now = now ?? DateTime.now,
       _random = random,
       _timeout = timeout,
       state = ValueNotifier(
         CommunityAuthState(
           (config ?? CommunityAuthConfig.fromEnvironment).isConfigured
               ? CommunityAccountPhase.disconnected
               : CommunityAccountPhase.unconfigured,
         ),
       );

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  _CandidateSession? _candidate;
  Future<CommunityLinkOutcome>? _linkInFlight;
  Future<CommunityTokenResult>? _tokenInFlight;
  int _noticeSerial = 0;

  // ── 상태 ──────────────────────────────────────────────────

  /// 저장소에서 상태를 다시 읽는다(앱 시작·설정 화면 진입).
  Future<void> load() async {
    if (_candidate != null) return; // 확인 대기 중이면 그대로 둔다.
    if (state.value.phase == CommunityAccountPhase.exchanging) return;
    final pending = await _readPending();
    final session = await _readSession();
    if (config.isConfigured &&
        pending != null &&
        !_isPendingExpired(pending) &&
        session?.isActive != true) {
      _emit(CommunityAccountPhase.awaitingBrowser, account: session?.info);
      return;
    }
    await _emitBase();
  }

  void _emit(
    CommunityAccountPhase phase, {
    CommunityAccountInfo? account,
    CommunityCandidate? candidate,
    String? notice,
  }) {
    if (notice != null) _noticeSerial++;
    state.value = CommunityAuthState(
      phase,
      account: account,
      candidate: candidate,
      notice: notice,
      noticeSerial: _noticeSerial,
    );
  }

  /// 저장된 세션 기준 기본 상태(연결됨/다시 로그인 필요/연결 안 됨/설정되지 않음).
  Future<void> _emitBase({String? notice}) async {
    if (!config.isConfigured) {
      _emit(CommunityAccountPhase.unconfigured, notice: notice);
      return;
    }
    final session = await _readSession();
    if (session == null) {
      _emit(CommunityAccountPhase.disconnected, notice: notice);
    } else if (session.reauthRequired) {
      _emit(
        CommunityAccountPhase.reauthRequired,
        account: session.info,
        notice: notice,
      );
    } else {
      _emit(
        CommunityAccountPhase.connected,
        account: session.info,
        notice: notice,
      );
    }
  }

  // ── 로그인 시작 ────────────────────────────────────────────

  /// PKCE 대기 로그인을 **먼저** 보안 저장소에 저장한 뒤 외부 브라우저로 authorize 주소를 연다.
  Future<CommunityStartOutcome> startLogin() async {
    if (!config.isConfigured) {
      await _emitBase();
      return CommunityStartOutcome.unconfigured;
    }
    final verifier = CommunityPkce.generateVerifier(_random);
    final pending = _PendingLogin(
      attemptId: CommunityPkce.randomToken(16, _random),
      verifier: verifier,
      startedAt: _now(),
    );
    await _storage.write(key: pendingLoginKey, value: pending.encode());
    final url = buildAuthorizeUri(CommunityPkce.challengeFor(verifier));
    final session = await _readSession();
    _emit(CommunityAccountPhase.awaitingBrowser, account: session?.info);
    var launched = false;
    try {
      launched = await _launcher(url);
    } catch (_) {
      launched = false;
    }
    if (!launched) {
      await _storage.delete(key: pendingLoginKey);
      await _emitBase(notice: '브라우저를 열지 못했습니다. 다시 시도해 주세요.');
      return CommunityStartOutcome.launchFailed;
    }
    return CommunityStartOutcome.launched;
  }

  Uri buildAuthorizeUri(String challenge) => config.authUri('authorize', {
    'provider': 'kakao',
    'redirect_to': CommunityAuthConfig.redirectUri,
    'code_challenge': challenge,
    'code_challenge_method': 's256',
  });

  /// 브라우저에서 돌아오지 않은 로그인을 버린다.
  Future<void> cancelPendingLogin() async {
    await _storage.delete(key: pendingLoginKey);
    await _emitBase();
  }

  // ── 복귀 링크 ──────────────────────────────────────────────

  /// 복귀 링크 처리. 같은 링크가 두 번(onNewIntent + 콜드 스타트, 중복 전달) 와도 교환은 한 번만 한다.
  Future<CommunityLinkOutcome> handleCallbackLink(String link) {
    final cb = CommunityCallback.parse(link);
    if (cb.kind == CommunityCallbackKind.notOurs) {
      return Future.value(CommunityLinkOutcome.notOurs);
    }
    if (_linkInFlight != null) {
      return Future.value(CommunityLinkOutcome.ignoredDuplicate);
    }
    final future = _handleCallback(cb);
    _linkInFlight = future;
    return future.whenComplete(() => _linkInFlight = null);
  }

  Future<CommunityLinkOutcome> _handleCallback(CommunityCallback cb) async {
    final fingerprint = sha256
        .convert(utf8.encode('${cb.kind.name}|${cb.code ?? cb.errorCode}'))
        .toString();
    // 이미 소비한 링크는 대기 로그인이 새로 있어도 다시 쓰지 않는다(재전달·최근 앱 복원).
    if (await _storage.read(key: consumedCallbackKey) == fingerprint) {
      return CommunityLinkOutcome.ignoredDuplicate;
    }
    final pending = await _readPending();
    if (pending == null) {
      await _emitBase(notice: '진행 중인 로그인이 없습니다. 로그인을 다시 시작해 주세요.');
      return CommunityLinkOutcome.ignoredNoPending;
    }
    if (_isPendingExpired(pending)) {
      await _storage.delete(key: pendingLoginKey);
      await _emitBase(notice: '로그인 시간이 지났습니다. 로그인을 다시 시작해 주세요.');
      return CommunityLinkOutcome.ignoredExpired;
    }
    // 교환 전에 대기 로그인을 소비한다 — 이후 어떤 경로로 같은 링크가 와도 다시 교환하지 않는다.
    await _storage.write(key: consumedCallbackKey, value: fingerprint);
    await _storage.delete(key: pendingLoginKey);

    switch (cb.kind) {
      case CommunityCallbackKind.cancelled:
        await _emitBase(notice: '카카오 로그인을 취소했습니다.');
        return CommunityLinkOutcome.cancelled;
      case CommunityCallbackKind.error:
      case CommunityCallbackKind.notOurs:
        await _emitBase(notice: '카카오 로그인을 마치지 못했습니다. 로그인을 다시 시작해 주세요.');
        return CommunityLinkOutcome.failed;
      case CommunityCallbackKind.code:
        break;
    }

    final existing = await _readSession();
    _emit(CommunityAccountPhase.exchanging, account: existing?.info);

    final _Tokens tokens;
    try {
      final res = await _post(config.authUri('token', {'grant_type': 'pkce'}), {
        'auth_code': cb.code,
        'code_verifier': pending.verifier,
      });
      if (res.statusCode != 200) {
        final code = _errorCode(res);
        final expired =
            code == 'flow_state_expired' ||
            code == 'flow_state_not_found' ||
            code == 'bad_code_verifier';
        await _emitBase(
          notice: expired
              ? '로그인 확인 시간이 지났거나 이미 사용한 요청입니다. 로그인을 다시 시작해 주세요.'
              : '로그인을 마치지 못했습니다. 로그인을 다시 시작해 주세요.',
        );
        return CommunityLinkOutcome.failed;
      }
      tokens = _Tokens.parse(_body(res), _now());
    } catch (_) {
      // 네트워크 오류로 교환 결과를 모름 — 같은 코드를 다시 교환하지 않는다.
      await _emitBase(notice: '네트워크 오류로 로그인을 마치지 못했습니다. 로그인을 다시 시작해 주세요.');
      return CommunityLinkOutcome.failed;
    }

    final _User user;
    try {
      final res = await _get(config.authUri('user'), bearer: tokens.access);
      if (res.statusCode != 200) throw const FormatException('user');
      user = _User.parse(_body(res));
    } catch (_) {
      await _logoutLocal(tokens.access);
      await _emitBase(notice: '계정 정보를 확인하지 못했습니다. 로그인을 다시 시작해 주세요.');
      return CommunityLinkOutcome.failed;
    }

    _candidate = _CandidateSession(tokens, user);
    final different =
        existing != null &&
        existing.userId.isNotEmpty &&
        existing.userId != user.id;
    _emit(
      CommunityAccountPhase.confirmRequired,
      account: existing?.info,
      candidate: CommunityCandidate(
        displayName: user.displayName,
        hasEmail: user.hasEmail,
        isDifferentAccount: different,
      ),
    );
    return CommunityLinkOutcome.confirmRequired;
  }

  /// "이 계정으로 연결" — 이때만 세션을 저장한다(한 키에 한 번 쓰기).
  Future<bool> confirmCandidate() async {
    final c = _candidate;
    if (c == null) return false;
    _candidate = null;
    final old = await _readSession();
    final session = _StoredSession(
      accessToken: c.tokens.access,
      refreshToken: c.tokens.refresh,
      expiresAt: c.tokens.expiresAt,
      userId: c.user.id,
      displayName: c.user.displayName,
      hasEmail: c.user.hasEmail,
      connectedAt: _now(),
      reauthRequired: false,
    );
    await _storage.write(key: sessionKey, value: session.encode());
    if (old != null && old.accessToken.isNotEmpty) {
      // 바뀐 이전 세션은 이 기기에서만 로그아웃(best effort).
      unawaited(_logoutLocal(old.accessToken));
    }
    await _emitBase(notice: '커뮤니티 계정을 연결했습니다.');
    return true;
  }

  /// "취소" — 새 세션을 `logout?scope=local` 로 닫고 버린다. 기존 연결은 그대로.
  Future<void> cancelCandidate() async {
    final c = _candidate;
    _candidate = null;
    if (c != null) await _logoutLocal(c.tokens.access);
    final old = await _readSession();
    await _emitBase(
      notice: old == null ? '연결을 취소했습니다.' : '연결을 취소했습니다. 기존 연결은 그대로입니다.',
    );
  }

  // ── 세션 공급 ──────────────────────────────────────────────

  /// 유효한 access token. 60초 안에 만료되면 갱신한다(동시 호출은 갱신 한 번).
  ///
  /// 백그라운드 isolate 에서도 보안 저장소를 읽어 쓸 수 있다. 다만 세션이 있다고 해서
  /// 백그라운드 실행 권한이 생기지는 않는다(OS 스케줄링은 별개 — M09).
  Future<String?> getAccessToken() async =>
      (await getAccessTokenResult()).accessToken;

  Future<CommunityTokenResult> getAccessTokenResult() {
    return _tokenInFlight ??= _getTokenOnce().whenComplete(() {
      _tokenInFlight = null;
    });
  }

  Future<CommunityTokenResult> _getTokenOnce() async {
    if (!config.isConfigured) {
      return const CommunityTokenResult(CommunityTokenStatus.notConfigured);
    }
    final s = await _readSession();
    if (s == null) {
      return const CommunityTokenResult(CommunityTokenStatus.notConnected);
    }
    if (s.reauthRequired) {
      return const CommunityTokenResult(CommunityTokenStatus.reauthRequired);
    }
    final now = _now();
    if (s.expiresAt.difference(now) > refreshMargin) {
      return CommunityTokenResult(CommunityTokenStatus.ok, s.accessToken);
    }
    final stillValid = s.expiresAt.isAfter(now);
    http.Response res;
    try {
      res = await _post(
        config.authUri('token', {'grant_type': 'refresh_token'}),
        {'refresh_token': s.refreshToken},
      );
    } catch (_) {
      return stillValid
          ? CommunityTokenResult(CommunityTokenStatus.ok, s.accessToken)
          : const CommunityTokenResult(
              CommunityTokenStatus.temporarilyUnavailable,
            );
    }
    if (res.statusCode == 200) {
      final _Tokens t;
      try {
        t = _Tokens.parse(_body(res), _now());
      } catch (_) {
        return const CommunityTokenResult(
          CommunityTokenStatus.temporarilyUnavailable,
        );
      }
      // 갱신하는 동안 세션이 바뀌었으면(연결 해제·교체·다른 isolate 의 갱신) 덮어쓰지 않는다.
      final current = await _readSession();
      if (current == null || current.refreshToken != s.refreshToken) {
        return _fromCurrent(current);
      }
      // 회전된 access+refresh 를 한 번에 저장.
      await _storage.write(
        key: sessionKey,
        value: s
            .copyWith(
              accessToken: t.access,
              refreshToken: t.refresh,
              expiresAt: t.expiresAt,
            )
            .encode(),
      );
      return CommunityTokenResult(CommunityTokenStatus.ok, t.access);
    }
    if (_isInvalidGrant(res)) {
      final current = await _readSession();
      if (current == null || current.refreshToken != s.refreshToken) {
        return _fromCurrent(current);
      }
      await _storage.write(
        key: sessionKey,
        value: s.markReauthRequired().encode(),
      );
      if (_candidate == null) {
        await _emitBase(notice: '커뮤니티 계정에 다시 로그인해야 합니다.');
      }
      return const CommunityTokenResult(CommunityTokenStatus.reauthRequired);
    }
    // 5xx·429·그 밖의 응답 — 세션은 유지.
    return stillValid
        ? CommunityTokenResult(CommunityTokenStatus.ok, s.accessToken)
        : const CommunityTokenResult(
            CommunityTokenStatus.temporarilyUnavailable,
          );
  }

  CommunityTokenResult _fromCurrent(_StoredSession? current) {
    if (current == null) {
      return const CommunityTokenResult(CommunityTokenStatus.notConnected);
    }
    if (current.reauthRequired) {
      return const CommunityTokenResult(CommunityTokenStatus.reauthRequired);
    }
    if (current.expiresAt.isAfter(_now())) {
      return CommunityTokenResult(CommunityTokenStatus.ok, current.accessToken);
    }
    return const CommunityTokenResult(
      CommunityTokenStatus.temporarilyUnavailable,
    );
  }

  bool _isInvalidGrant(http.Response res) {
    if (res.statusCode < 400 || res.statusCode >= 500) return false;
    if (res.statusCode == 429) return false;
    final code = _errorCode(res);
    if (_invalidGrantCodes.contains(code)) return true;
    return res.statusCode == 400 && code == 'invalid_grant';
  }

  // ── 연결 해제 / 초기화 ─────────────────────────────────────

  /// `logout?scope=local`(best effort) 후 로컬 세션 삭제. scope 를 빼면 global(모든 기기) 이므로 항상 local.
  Future<CommunityDisconnectResult> disconnect() async {
    final inflight = _tokenInFlight;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
    }
    final candidate = _candidate;
    _candidate = null;
    if (candidate != null) unawaited(_logoutLocal(candidate.tokens.access));
    final s = await _readSession();
    var confirmed = false;
    if (s != null && !s.reauthRequired && s.accessToken.isNotEmpty) {
      var access = s.accessToken;
      if (!s.expiresAt.isAfter(_now())) {
        final t = await getAccessTokenResult();
        access = t.accessToken ?? '';
      }
      if (access.isNotEmpty) confirmed = await _logoutLocal(access);
    }
    await _storage.delete(key: sessionKey);
    await _emitBase(
      notice: s == null
          ? null
          : confirmed
          ? '커뮤니티 계정 연결을 해제했습니다.'
          : '이 기기의 연결은 해제했습니다. 서버 로그아웃은 확인하지 못했습니다.',
    );
    return CommunityDisconnectResult(
      hadSession: s != null,
      serverLogoutConfirmed: confirmed,
    );
  }

  /// 실행 모드 변경(`ReportProvider.resetConfig`) — Standalone 커뮤니티 세션·대기 로그인을 지운다.
  /// 서버 로그아웃은 기다리지 않는다(best effort). 토큰을 다른 곳으로 옮기지 않는다.
  Future<void> clearForModeChange() async {
    final candidate = _candidate;
    _candidate = null;
    final s = await _readSession();
    await _storage.delete(key: sessionKey);
    await _storage.delete(key: pendingLoginKey);
    await _storage.delete(key: consumedCallbackKey);
    if (candidate != null) unawaited(_logoutLocal(candidate.tokens.access));
    if (s != null && s.accessToken.isNotEmpty) {
      unawaited(_logoutLocal(s.accessToken));
    }
    await _emitBase();
  }

  Future<bool> _logoutLocal(String accessToken) async {
    if (!config.isConfigured || accessToken.isEmpty) return false;
    try {
      final res = await _post(
        config.authUri('logout', {'scope': 'local'}),
        null,
        bearer: accessToken,
      );
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── 저장소 ────────────────────────────────────────────────

  bool _isPendingExpired(_PendingLogin p) {
    final age = _now().difference(p.startedAt);
    return age.isNegative || age > pendingLoginTtl;
  }

  Future<_PendingLogin?> _readPending() async {
    final raw = await _safeRead(pendingLoginKey);
    if (raw == null) return null;
    final p = _PendingLogin.decode(raw);
    if (p == null) await _storage.delete(key: pendingLoginKey);
    return p;
  }

  Future<_StoredSession?> _readSession() async {
    final raw = await _safeRead(sessionKey);
    return raw == null ? null : _StoredSession.decode(raw);
  }

  Future<String?> _safeRead(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  // ── HTTP ─────────────────────────────────────────────────

  Map<String, String> _headers({String? bearer, bool json = false}) => {
    'apikey': config.publishableKey,
    'Accept': 'application/json',
    if (json) 'Content-Type': 'application/json',
    if (bearer != null) 'Authorization': 'Bearer $bearer',
  };

  Future<http.Response> _post(
    Uri uri,
    Map<String, Object?>? body, {
    String? bearer,
  }) => _withClient(
    (c) => c.post(
      uri,
      headers: _headers(bearer: bearer, json: true),
      body: jsonEncode(body ?? const <String, Object?>{}),
    ),
  );

  Future<http.Response> _get(Uri uri, {String? bearer}) =>
      _withClient((c) => c.get(uri, headers: _headers(bearer: bearer)));

  Future<http.Response> _withClient(
    Future<http.Response> Function(http.Client c) send,
  ) async {
    final client = _client ?? http.Client();
    try {
      return await send(client).timeout(_timeout);
    } finally {
      if (_client == null) client.close();
    }
  }

  /// JSON 은 UTF-8 로 읽는다(Content-Type 에 charset 이 없어도).
  static String _body(http.Response res) =>
      utf8.decode(res.bodyBytes, allowMalformed: true);

  static String _errorCode(http.Response res) {
    try {
      final j = jsonDecode(_body(res));
      if (j is! Map) return '';
      final ec = j['error_code'];
      if (ec is String && ec.isNotEmpty) return ec;
      final c = j['code'];
      if (c is String && c.isNotEmpty) return c;
      final e = j['error'];
      if (e is String) return e;
    } catch (_) {}
    return '';
  }
}

class _PendingLogin {
  final String attemptId;
  final String verifier;
  final DateTime startedAt;
  const _PendingLogin({
    required this.attemptId,
    required this.verifier,
    required this.startedAt,
  });

  String encode() => jsonEncode({
    'v': 1,
    'attempt_id': attemptId,
    'verifier': verifier,
    'started_at': startedAt.millisecondsSinceEpoch,
  });

  static _PendingLogin? decode(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final verifier = j['verifier'] as String? ?? '';
      if (verifier.length < 43) return null;
      return _PendingLogin(
        attemptId: j['attempt_id'] as String? ?? '',
        verifier: verifier,
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['started_at'] as num).toInt(),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

class _Tokens {
  final String access;
  final String refresh;
  final DateTime expiresAt;
  const _Tokens(this.access, this.refresh, this.expiresAt);

  static _Tokens parse(String body, DateTime now) {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final access = j['access_token'] as String? ?? '';
    final refresh = j['refresh_token'] as String? ?? '';
    if (access.isEmpty || refresh.isEmpty) {
      throw const FormatException('token response');
    }
    final at = j['expires_at'];
    final inSec = j['expires_in'];
    final DateTime expiresAt;
    if (at is num) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000);
    } else if (inSec is num) {
      expiresAt = now.add(Duration(seconds: inSec.toInt()));
    } else {
      expiresAt = now.add(const Duration(minutes: 5));
    }
    return _Tokens(access, refresh, expiresAt);
  }
}

class _User {
  final String id;
  final String displayName;
  final bool hasEmail;
  const _User(this.id, this.displayName, this.hasEmail);

  static _User parse(String body) {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final id = j['id'] as String? ?? '';
    if (id.isEmpty) throw const FormatException('user id');
    final meta = j['user_metadata'];
    String name = '';
    if (meta is Map) {
      for (final k in const [
        'nickname',
        'name',
        'full_name',
        'preferred_username',
        'user_name',
      ]) {
        final v = meta[k];
        if (v is String && v.trim().isNotEmpty) {
          name = v.trim();
          break;
        }
      }
    }
    name = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '');
    if (name.runes.length > 40) {
      name = String.fromCharCodes(name.runes.take(40));
    }
    final email = j['email'];
    return _User(
      id,
      name.isEmpty ? '카카오 사용자' : name,
      email is String && email.isNotEmpty,
    );
  }
}

class _CandidateSession {
  final _Tokens tokens;
  final _User user;
  const _CandidateSession(this.tokens, this.user);
}

class _StoredSession {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String userId;
  final String displayName;
  final bool hasEmail;
  final DateTime? connectedAt;
  final bool reauthRequired;

  const _StoredSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.userId,
    required this.displayName,
    required this.hasEmail,
    required this.connectedAt,
    required this.reauthRequired,
  });

  bool get isActive => !reauthRequired && refreshToken.isNotEmpty;

  CommunityAccountInfo get info =>
      CommunityAccountInfo(displayName: displayName, connectedAt: connectedAt);

  _StoredSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) => _StoredSession(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    userId: userId,
    displayName: displayName,
    hasEmail: hasEmail,
    connectedAt: connectedAt,
    reauthRequired: reauthRequired,
  );

  /// 토큰은 지우고 화면용 계정 정보만 남긴다.
  _StoredSession markReauthRequired() => _StoredSession(
    accessToken: '',
    refreshToken: '',
    expiresAt: DateTime.fromMillisecondsSinceEpoch(0),
    userId: userId,
    displayName: displayName,
    hasEmail: hasEmail,
    connectedAt: connectedAt,
    reauthRequired: true,
  );

  String encode() => jsonEncode({
    'v': 1,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'user_id': userId,
    'display_name': displayName,
    'has_email': hasEmail,
    'connected_at': connectedAt?.toUtc().toIso8601String(),
    'state': reauthRequired ? 'reauth_required' : 'active',
  });

  static _StoredSession? decode(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final connected = j['connected_at'] as String?;
      return _StoredSession(
        accessToken: j['access_token'] as String? ?? '',
        refreshToken: j['refresh_token'] as String? ?? '',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          ((j['expires_at'] as num?) ?? 0).toInt() * 1000,
        ),
        userId: j['user_id'] as String? ?? '',
        displayName: j['display_name'] as String? ?? '카카오 사용자',
        hasEmail: j['has_email'] as bool? ?? false,
        connectedAt: connected == null
            ? null
            : DateTime.tryParse(connected)?.toLocal(),
        reauthRequired:
            j['state'] == 'reauth_required' ||
            (j['refresh_token'] as String? ?? '').isEmpty,
      );
    } catch (_) {
      return null;
    }
  }
}
