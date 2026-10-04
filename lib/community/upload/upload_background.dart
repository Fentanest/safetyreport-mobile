// 백그라운드 isolate 용 업로드 조립 (background_login_check.dart 에서 호출).
//
// 포그라운드 T5 gate(위젯 바인딩·화면 상태)에 의존하지 않는다. 게이트 캐시가 유효 기간(600초) 안의 성공이면 그대로 쓰고,
// 오래됐으면 [refreshGateHeadless] 로 중앙 상태를 제한적으로 다시 확인한다(설정·보안 저장소 세션·토큰 갱신·status 1회).
// 연결 등록·rebind·takeover 같은 쓰기는 하지 않는다 — 그런 조치가 필요하면 앱이 열릴 때 포그라운드 게이트가 한다.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/app_mode.dart';
import '../../services/community_auth_config.dart';
import '../../services/community_auth_service.dart';
import '../community_store.dart';
import '../gate/community_account_client.dart';
import '../gate/gate_state.dart';
import 'community_schedule.dart';
import 'community_uploader.dart';

Future<CommunityStore?> openCommunityStoreForBackground() async {
  try {
    return await CommunityStore.open();
  } catch (_) {
    return null;
  }
}

class _BackgroundTokens implements CommunityTokenSource {
  @override
  Future<CommunityTokenResult> getAccessTokenResult({String? rejected}) =>
      CommunityAuthService.instance.getAccessTokenResult(rejected: rejected);
}

Future<UploadRunResult> uploadFromBackground(CommunityStore store, String trigger) async {
  final config = CommunityAuthConfig.fromEnvironment;
  var version = '';
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  final gate = CacheGateCheck();
  final uploader = CommunityUploader(
    gate: gate,
    tokens: _BackgroundTokens(),
    appMode: () async => AppMode.standalone,
    supabaseUrl: config.supabaseUrl,
    publishableKey: config.publishableKey,
    clientVersion: version,
    openStore: () async => store,
  );
  try {
    return await uploader.requestCommunityUpload(trigger);
  } finally {
    await gate.flush(); // 403 무효화 기록을 끝낸 뒤 작업을 마친다(다음 작업·앱이 오래된 ok 캐시를 믿지 않게)
  }
}

/// 재시도 시각이 된 대기 행(또는 cooldown 끝)이 있는가 — 주기 작업의 복구 실행 판단.
Future<bool> recoveryDue(CommunityStore store, {DateTime? now}) async {
  final config = CommunityAuthConfig.fromEnvironment;
  final uploader = CommunityUploader(
    gate: CacheGateCheck(),
    tokens: _BackgroundTokens(),
    appMode: () async => AppMode.standalone,
    supabaseUrl: config.supabaseUrl,
    publishableKey: config.publishableKey,
    clientVersion: '',
    openStore: () async => store,
  );
  final due = await uploader.nextDueAt();
  return due != null && !due.isAfter((now ?? DateTime.now()).toUtc());
}

/// 헤드리스 게이트 재확인 결과.
enum HeadlessGate {
  /// 캐시를 갱신했다 — 업로드해도 된다.
  ok,

  /// 네트워크·5xx·잠금 대기 등 일시 장애 — 상태를 바꾸지 않고 끝낸다(다음 기회).
  transient,

  /// 명시적 거절(로그인 필요·동의 없음·정지) — 캐시에 기록하고 context 를 끈다. 업로드하지 않는다.
  blocked,

  /// 연결 등록·rebind 등 포그라운드 조치가 필요하다 — 아무 것도 바꾸지 않고 끝낸다.
  needsForeground,
}

/// 게이트 캐시가 오래됐을 때 백그라운드에서 중앙 상태를 한 번 다시 확인한다.
/// ok 는 포그라운드 게이트와 같은 판정([evaluateGate]) + 저장 연결이 활성·현재 세션에 묶임 + community.db context 와 일치일 때만.
Future<HeadlessGate> refreshGateHeadless(
  CommunityStore store, {
  CommunityAuthConfig? config,
  CommunityTokenSource? tokens,
  CommunityAccountClient? client,
  FlutterSecureStorage? secureStorage,
  SharedPreferences? prefs,
  DateTime Function()? now,
}) async {
  final cfg = config ?? CommunityAuthConfig.fromEnvironment;
  final clock = now ?? DateTime.now;
  final p = prefs ?? await SharedPreferences.getInstance();
  if (!cfg.isConfigured) return HeadlessGate.needsForeground;
  final CommunityTokenResult token;
  try {
    token = await (tokens ?? _BackgroundTokens()).getAccessTokenResult();
  } catch (_) {
    return HeadlessGate.transient;
  }
  switch (token.status) {
    case CommunityTokenStatus.ok:
      break;
    case CommunityTokenStatus.temporarilyUnavailable:
      return HeadlessGate.transient;
    case CommunityTokenStatus.notConfigured:
      return HeadlessGate.needsForeground;
    case CommunityTokenStatus.notConnected:
      return _block(store, p, 'kakao_required', clock());
    case CommunityTokenStatus.reauthRequired:
      return _block(store, p, 'kakao_reauth_required', clock());
  }
  Map<String, Object?>? stored;
  try {
    final raw = await (secureStorage ?? const FlutterSecureStorage()).read(key: 'community_connection_v1');
    final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
    stored = decoded is Map ? decoded.cast<String, Object?>() : null;
  } catch (_) {
    return HeadlessGate.transient;
  }
  final CommunityAccountStatus status;
  try {
    status = await (client ??
            CommunityAccountClient(supabaseUrl: cfg.supabaseUrl, publishableKey: cfg.publishableKey))
        .status(accessToken: token.accessToken!, connectionId: stored?['connection_id'] as String?);
  } on CommunityAccountError catch (e) {
    if (e.isAuth) return _block(store, p, 'kakao_reauth_required', clock());
    if (e.httpStatus == 403) return _block(store, p, e.code, clock());
    return HeadlessGate.transient;
  } catch (_) {
    return HeadlessGate.transient;
  }
  final next = evaluateGate(
    config: 'ok',
    session: 'valid',
    status: status.toGateInput(),
    ageSeconds: 0,
  );
  if (!next.canEnter) return _block(store, p, next.state, clock());
  final conn = status.connection;
  final ctx = await store.activeContext();
  final usable = conn != null &&
      conn['status'] == 'active' &&
      conn['bound_to_current_session'] == true &&
      ctx != null &&
      ctx['connection_id'] == stored?['connection_id'] &&
      ctx['contributor_fingerprint'] == status.fingerprint &&
      ctx['consent_grant_id'] == status.consentGrantId &&
      ctx['policy_version'] == status.consentPolicyVersion &&
      ctx['consent_text_sha256'] == status.grantConsentTextSha256;
  if (!usable) return HeadlessGate.needsForeground;
  await p.setString('community_gate_cache_v1',
      jsonEncode({'state': 'ok', 'owner': status.fingerprint, 'verified_at': clock().millisecondsSinceEpoch}));
  return HeadlessGate.ok;
}

Future<HeadlessGate> _block(CommunityStore store, SharedPreferences prefs, String state, DateTime at) async {
  await prefs.setString('community_gate_cache_v1', jsonEncode({'state': state, 'verified_at': at.millisecondsSinceEpoch}));
  await store.deactivateContext('gate:$state');
  return HeadlessGate.blocked;
}
