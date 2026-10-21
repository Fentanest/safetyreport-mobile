import '../cloud_availability.dart';
import '../consent_history.dart';
import '../soft_reset.dart';
import '../client_notice.dart';
import '../client_server_consent.dart';
import '../consent_catchup.dart';
import '../../services/local_db_service.dart';
// 백그라운드 isolate 용 업로드 조립 (background_login_check.dart 에서 호출).
//
// 포그라운드 T5 gate(위젯 바인딩·화면 상태)에 의존하지 않는다. 게이트 캐시가 유효 기간(600초) 안의 성공이면 그대로 쓰고,
// 오래됐으면 [refreshGateHeadless] 로 중앙 상태를 제한적으로 다시 확인한다(설정·보안 저장소 세션·토큰 갱신·status 1회).
// 연결 등록·rebind·takeover 같은 쓰기는 하지 않는다 — 그런 조치가 필요하면 앱이 열릴 때 포그라운드 게이트가 한다.
import 'dart:convert';
import 'package:sqflite/sqflite.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/app_mode.dart';
import '../../services/app_prefs_keys.dart';
import '../../services/community_auth_config.dart';
import '../../services/community_server_link_service.dart';
import '../../services/community_auth_service.dart';
import '../ingest_status.dart';
import '../community_store.dart';
import '../gate/community_account_client.dart';
import '../client_server_policy.dart';
import '../gate/gate_policy.dart';
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

Future<UploadRunResult> uploadFromBackground(
  CommunityStore store,
  String trigger,
) async {
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
/// ok 는 포그라운드 게이트와 같은 판정([evaluateGate])을 따른다.
/// Standalone은 활성 writer·현재 세션·community.db context도 일치해야 한다.
/// Client는 폰의 세션·동의를 확인하며, PC의 수집 게이트는 PC가 따로 검사한다.
Future<HeadlessGate> refreshGateHeadless(
  CommunityStore store, {
  CommunityAuthConfig? config,
  CommunityTokenSource? tokens,
  CommunityAccountClient? client,
  FlutterSecureStorage? secureStorage,
  SharedPreferences? prefs,
  DateTime Function()? now,
  bool clientMode = false,
  Future<CommunityGateLinkResult> Function()? serverGate,
  String? expectedOwner,
  Future<void> Function()? validateScope,
  Future<void> Function(String cache)? persistVerifiedCache,
  Future<String?> Function()? sessionMember,
}) async {
  final workGeneration = await store.meta('work_generation') ?? '0';
  final localDataset = await store.localDatasetId();
  Future<void> guardTx(DatabaseExecutor tx) async {
    if ((await store.meta('work_generation', tx) ?? '0') != workGeneration ||
        await store.meta('revoke_pending', tx) != null ||
        await store.meta('local_dataset_id', tx) != localDataset) {
      throw StateError('headless_scope_changed');
    }
  }

  Future<void> guard() async {
    await validateScope?.call();
    await guardTx(store.db);
  }

  if (await CommunityReset.pending(store) != null) return HeadlessGate.blocked;
  final cfg = config ?? CommunityAuthConfig.fromEnvironment;
  final clock = now ?? DateTime.now;
  final p = prefs ?? await SharedPreferences.getInstance();
  Future<void> verified(String value) async {
    await guard();
    await store.transaction((tx) async {
      await guardTx(tx);
      if (persistVerifiedCache != null) {
        await persistVerifiedCache(value);
      } else {
        await p.setString('community_gate_cache_v1', value);
      }
    });
  }

  Future<HeadlessGate> block(
    String state, {
    bool record = true,
    String? owner,
  }) async {
    await guard();
    return _block(
      store,
      p,
      state,
      clock(),
      record: record,
      expectedWorkGeneration: workGeneration,
      owner: owner,
    );
  }

  if (!cfg.isConfigured) return HeadlessGate.needsForeground;
  if (tokens == null) {
    CloudAvailability.shared ??= CloudAvailability(
      store,
      cfg.supabaseUrl,
      now: clock,
    );
  }
  if (await CloudAvailability.shared?.coolingDown() ?? false) {
    return HeadlessGate.transient;
  }
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
      await guard();
      return block('kakao_required');
    case CommunityTokenStatus.reauthRequired:
      await guard();
      return block('kakao_reauth_required');
  }
  Map<String, Object?>? stored;
  try {
    final raw =
        await (secureStorage ??
                const FlutterSecureStorage(
                  aOptions: AndroidOptions(resetOnError: false),
                ))
            .read(key: 'community_connection_v1');
    final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
    stored = decoded is Map ? decoded.cast<String, Object?>() : null;
  } catch (_) {
    return HeadlessGate.transient;
  }
  final CommunityAccountStatus status;
  try {
    status =
        await (client ??
                CommunityAccountClient(
                  supabaseUrl: cfg.supabaseUrl,
                  publishableKey: cfg.publishableKey,
                ))
            .status(
              accessToken: token.accessToken!,
              connectionId: stored?['connection_id'] as String?,
            );
  } on CommunityAccountError catch (e) {
    if (e.serviceUnavailable) {
      if (e.code != 'cloud_cooldown' &&
          !(await CloudAvailability.shared?.coolingDown() ?? false)) {
        await CloudAvailability.shared?.failed(
          retryAfterSeconds: e.retryAfterSeconds,
        );
      }
      return HeadlessGate.transient;
    }
    if (e.isAuth) {
      await guard();
      return block('kakao_reauth_required');
    }
    if (e.httpStatus == 403) {
      await guard();
      return block(e.code == 'contributor_suspended' ? 'suspended' : e.code);
    }
    return HeadlessGate.transient;
  } catch (_) {
    return HeadlessGate.transient;
  }
  await guard();
  final next = evaluateGate(
    config: 'ok',
    session: 'valid',
    status: status.toGateInput(),
    ageSeconds: 0,
  );
  final account = status.fingerprint;
  if (account == null || (expectedOwner != null && account != expectedOwner)) {
    return HeadlessGate.needsForeground;
  }
  await store.transaction((tx) async {
    await guardTx(tx);
    await saveIngestStatus(store, status.raw, tx);
  });
  await guard();
  await ClientNotice.save(store, status.raw['client_notice']);
  final previous = await ConsentHistory(store).latest(account);
  final member = sessionMember != null
      ? await sessionMember()
      : (tokens == null
            ? await CommunityAuthService.instance.sessionKakaoId()
            : null);
  final last = previous?['last_g1'];
  final had = last is Map && member != null && last['member'] == member;
  // Same decision table as the foreground gate: suspension first, and a reset only
  // for a G1 this device saw (a reset consumes that evidence, so a later revoked/none
  // answer is a plain consent request).
  if (gatePolicy(gateVector(status.raw, had)) == 'soft_reset') {
    if (!clientMode && tokens == null) {
      await headlessSoftReset(store, account, status.consentGrantId);
    }
    return _block(
      store,
      p,
      clientMode ? 'server_consent_required' : 'kakao_required',
      clock(),
      record: false,
      owner: clientMode ? account : null,
    );
  }
  await ConsentHistory(store).event(
    account,
    next.state,
    'background-status',
    status: status.raw,
    grant: status.consentGrantId,
  );
  if (!next.canEnter) {
    await guard();
    return block(next.state, record: false);
  }
  if (await ConsentHistory(
    store,
  ).uploadBlocked(account, status.consentGrantId)) {
    await guard();
    return block('consent_required');
  }
  if (clientMode) {
    // Only an explicit PC refusal blocks. An unreachable PC keeps the previous behaviour.
    if (await ClientServerConsent.verify(p, fetch: serverGate) ==
        ServerConsentVerdict.refused) {
      return block('server_consent_required', owner: account);
    }
    // Client is a reader: never require/register a Standalone writer or personal DB.
    // The phone's own session/consent is still checked; the PC gates its crawl separately.
    if (status.hasOfficialAccount && !status.officialAccountValid) {
      return HeadlessGate.needsForeground;
    }
    if (tokens == null &&
        await CommunityAuthService.instance.sessionFingerprint() != account) {
      return HeadlessGate.needsForeground;
    }
    await guard();
    await verified(
      jsonEncode({
        'state': 'ok',
        'owner': account,
        'verified_at': clock().millisecondsSinceEpoch,
      }),
    );
    return HeadlessGate.ok;
  }
  final conn = status.connection;
  final ctx = await store.context();
  // Production validates current login and PERSONAL DB owner before restoring
  // an inactive writer. Injectable token sources are isolated test fixtures.
  if (tokens == null) {
    final auth = CommunityAuthService.instance;
    final member = await auth.sessionKakaoId();
    if (await auth.sessionFingerprint() != account ||
        member == null ||
        await LocalDbService.dbOwner() != member) {
      await guard();
      return block('db_owner_mismatch');
    }
  }
  final usable =
      conn != null &&
      conn['status'] == 'active' &&
      conn['bound_to_current_session'] == true &&
      ctx != null &&
      ctx['connection_id'] == stored?['connection_id'] &&
      ctx['contributor_fingerprint'] == status.fingerprint &&
      (!status.hasOfficialAccount ||
          status.officialDatasetKey == ctx['dataset_key']);
  if (!usable) return HeadlessGate.needsForeground;
  await guard();
  await store.transaction((tx) async {
    await guardTx(tx);
    final rows = await tx.query('context', where: 'id=1');
    if (rows.isEmpty ||
        contextFields.any((key) => rows.first[key] != ctx[key])) {
      throw StateError('headless_context_changed');
    }
    await store.setContext({
      for (final key in contextFields) key: ctx[key],
      'consent_grant_id': status.consentGrantId,
      'policy_version': status.consentPolicyVersion,
      'consent_text_sha256': status.grantConsentTextSha256,
    }, executor: tx);
  });
  if (member != null) {
    // Same dataset value as the foreground gate: derived from the LOCAL official id,
    // never the server's binding (and never null over a known value).
    final localId = (p.getString(AppPrefsKeys.standaloneUsername) ?? '').trim();
    await ConsentHistory(store).markG1(
      account,
      member,
      localId.isNotEmpty
          ? datasetKeyForOfficialId(localId)
          : ctx['dataset_key'] as String?,
      expectedWorkGeneration: workGeneration,
    );
  }
  await guard();
  await ConsentHistory(store).clearCapture();
  if (await ConsentHistory(
    store,
  ).needsCatchup(account, status.consentGrantId!)) {
    await ConsentCatchup(store).schedule((await store.activeContext())!);
  }
  await guard();
  await verified(
    jsonEncode({
      'state': 'ok',
      'owner': status.fingerprint,
      'verified_at': clock().millisecondsSinceEpoch,
    }),
  );
  return HeadlessGate.ok;
}

/// 헤드리스 소프트 리셋: 포그라운드 softReset 과 같게 원격 철회 이력(remote-reset, localRevoke)을 남긴 뒤 리셋을 마친다.
/// 이력이 있어야 같은 계정으로 다시 로그인했을 때 G1 로 또 리셋되지 않고 동의 화면(G4)으로 간다.
Future<void> headlessSoftReset(
  CommunityStore store,
  String account,
  String? grant, {
  CommunityAuthService? auth,
}) async {
  await ConsentHistory(store).event(
    account,
    'consent_required',
    'remote-reset',
    grant: grant,
    localRevoke: true,
  );
  await CommunityReset.complete(store, auth: auth);
}

Future<HeadlessGate> _block(
  CommunityStore store,
  SharedPreferences prefs,
  String state,
  DateTime at, {
  bool record = true,
  String? expectedWorkGeneration,
  String? owner,
}) async {
  Future<void> check(DatabaseExecutor tx) async {
    if (expectedWorkGeneration != null &&
        (await store.meta('work_generation', tx) ?? '0') !=
            expectedWorkGeneration) {
      throw StateError('headless_scope_changed');
    }
  }

  await check(store.db);
  final ctx = await store.context();
  final account = ctx?['contributor_fingerprint'] as String?;
  if (record && account != null) {
    await ConsentHistory(store).event(
      account,
      state,
      'background-denial',
      grant: ctx?['consent_grant_id'] as String?,
    );
  }
  if (state == 'consent_required' &&
      account != null &&
      ctx?['dataset_key'] is String) {
    await ConsentHistory(
      store,
    ).pauseCapture(account, ctx!['dataset_key'] as String, consentDenied: true);
  } else {
    await ConsentHistory(store).clearCapture();
  }
  await store.transaction((tx) async {
    await check(tx);
    await prefs.setString(
      'community_gate_cache_v1',
      // A Client lock keeps the owner so the notification worker can resume once the PC allows it.
      jsonEncode({
        'state': state,
        'owner': ?owner,
        'verified_at': at.millisecondsSinceEpoch,
      }),
    );
    await store.deactivateContext('gate:$state', executor: tx);
  });
  return HeadlessGate.blocked;
}
