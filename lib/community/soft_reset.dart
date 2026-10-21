import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import '../services/community_auth_config.dart';
import '../services/community_auth_service.dart';
import '../services/db_optimize.dart';
import '../services/maintenance_service.dart';
import '../services/standalone_auth_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_operation_admission.dart';
import 'community_store.dart';
import 'consent_history.dart';
import 'gate/community_account_client.dart';
import 'raw_backfill_runtime.dart';
import 'upload/upload_controller.dart';
import 'upload_hooks.dart';

class CommunityReset {
  static const retryTask = 'communityConsentRevokeRetry';
  static const retryName = 'community-consent-revoke-retry';
  static Timer? _timer;
  static bool _attempting = false;
  static Future<Map<String, dynamic>?> pending(CommunityStore store) async {
    final value = await store.meta('revoke_pending');
    return value == null
        ? null
        : (jsonDecode(value) as Map).cast<String, dynamic>();
  }

  static Future<void> stopWork(CommunityStore store) async {
    await SyncOperationAdmission.cancelAll(store);
    SyncEngine.stop();
    DbOptimize.requestStop();
    MaintenanceService.stopForAccount();
    StandaloneAuthService.stopKeepAlive();
    RawBackfillRuntime.stop();
    CommunityUploadController.instance.stop();
    await store.deactivateContext('consent_revoked');
    await CommunityUploadHooks.cancelBackgroundJobsNow();
  }

  static Future<void> begin(
    CommunityStore store,
    String? grant, {
    CommunityAuthService? auth,
    CommunityAccountClient? client,
  }) async {
    final service = auth ?? CommunityAuthService.instance,
        account = await (auth ?? CommunityAuthService.instance)
            .sessionFingerprint();
    if (account == null) throw StateError('withdrawal_requires_session');
    await ConsentHistory(store).event(
      account,
      'consent_required',
      'local-revoke',
      grant: grant,
      localRevoke: true,
    );
    if (await pending(store) == null) {
      await store.setMeta(
        'revoke_pending',
        jsonEncode({
          'grant_id': grant,
          'account': account,
          'session_connected_at': await service.sessionConnectedAt(),
          'attempts': 0,
          'next_attempt_at': 0,
        }),
      );
    }
    await stopWork(store);
    resumePending(store, auth: service, client: client);
    await scheduleRetry(store: store);
  }

  static void resumePending(
    CommunityStore store, {
    CommunityAuthService? auth,
    CommunityAccountClient? client,
  }) {
    _timer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(
        attempt(store, auth: auth, client: client).catchError((_) => false),
      ),
    );
  }

  static void pauseForegroundRetry() {
    _timer?.cancel();
    _timer = null;
  }

  /// Backoff (PC `community_reset.attempt` too): 60s doubling, at most 30 minutes.
  static int backoffSeconds(int attempts) =>
      (60 * (1 << (attempts - 1).clamp(0, 5))).clamp(60, 1800);

  /// Registers the background retry at the persisted backoff time. A worker must not replace the
  /// unique work it is running in ([fromWorker] appends the next run instead).
  static Future<void> scheduleRetry({
    CommunityStore? store,
    bool fromWorker = false,
    Duration? delay,
  }) async {
    var wait = delay ?? const Duration(minutes: 1);
    if (delay == null && store != null) {
      final item = await pending(store);
      final at = (item?['next_attempt_at'] as num? ?? 0).toDouble();
      final left = at - DateTime.now().millisecondsSinceEpoch / 1000;
      if (left > 60) wait = Duration(seconds: left.ceil());
    }
    try {
      await Workmanager().registerOneOffTask(
        retryName,
        retryTask,
        initialDelay: wait,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: fromWorker
            ? ExistingWorkPolicy.append
            : ExistingWorkPolicy.replace,
      );
    } catch (_) {}
  }

  static Future<bool> attempt(
    CommunityStore store, {
    CommunityAuthService? auth,
    CommunityAccountClient? client,
    bool force = false,
    bool fromWorker = false,
  }) async {
    if (_attempting) return false;
    final item = await pending(store);
    if (item == null) {
      _timer?.cancel();
      _timer = null;
      return true;
    }
    if (!force &&
        DateTime.now().millisecondsSinceEpoch / 1000 <
            (item['next_attempt_at'] as num? ?? 0)) {
      // Too early (the work was woken before its backoff ended): respect it and queue the right time.
      if (fromWorker) await scheduleRetry(store: store, fromWorker: true);
      return false;
    }
    final service = auth ?? CommunityAuthService.instance;
    final generation = await store.meta('work_generation') ?? '0';
    if (_attempting) return false;
    _attempting = true;
    Future<bool> stillPending() async {
      final latest = await pending(store);
      return latest != null &&
          latest['account'] == item['account'] &&
          await service.sessionFingerprint() == item['account'] &&
          (await store.meta('work_generation') ?? '0') == generation;
    }

    final owner = 'revoke:${newUuidV4()}';
    var acquired = false;
    try {
      acquired = await store.acquireLease(
        'revoke',
        owner,
        const Duration(minutes: 2),
      );
      if (!acquired) return false;
      if (await service.sessionFingerprint() != item['account']) return false;
      final token = await service.getAccessToken();
      if (token == null) throw StateError('withdrawal_session_required');
      final cfg = CommunityAuthConfig.fromEnvironment;
      final accountClient =
          client ??
          CommunityAccountClient(
            supabaseUrl: cfg.supabaseUrl,
            publishableKey: cfg.publishableKey,
          );
      var grant = item['grant_id'] as String?;
      if (grant == null) {
        final status = await accountClient.status(accessToken: token);
        if (!await stillPending()) {
          return false;
        }
        final consent = status.raw['consent'];
        if (consent is Map && ['none', 'revoked'].contains(consent['state'])) {
          await complete(
            store,
            auth: service,
            keepSession: await sessionIsFresh(item, service),
          );
          return true;
        }
        grant = status.consentGrantId;
        if (grant == null) throw StateError('withdrawal_confirmation_pending');
        item['grant_id'] = grant;
        await store.setMeta('revoke_pending', jsonEncode(item));
      }
      final result = await accountClient.revokeConsent(
        accessToken: token,
        grantId: grant,
      );
      if (!await stillPending()) {
        return false;
      }
      if (result.lineageActive != false) {
        throw StateError('withdrawal_confirmation_pending');
      }
      await complete(
        store,
        auth: service,
        keepSession: await sessionIsFresh(item, service),
      );
      return true;
    } catch (error) {
      if (!await stillPending()) {
        return false;
      }
      if (error is CommunityAccountError && error.code == 'stale_grant') {
        item['grant_id'] = null;
      }
      item['attempts'] = (item['attempts'] as num? ?? 0).toInt() + 1;
      item['next_attempt_at'] =
          DateTime.now().millisecondsSinceEpoch / 1000 +
          backoffSeconds(item['attempts'] as int);
      await store.setMeta('revoke_pending', jsonEncode(item));
      await scheduleRetry(store: store, fromWorker: fromWorker);
      return false;
    } finally {
      if (acquired) await store.releaseLease('revoke', owner);
      _attempting = false;
    }
  }

  /// True when the current session was established after the revoke was requested (a fresh
  /// login made while revoke_pending). Old pending records without the field are never fresh.
  static Future<bool> sessionIsFresh(
    Map<String, dynamic>? item,
    CommunityAuthService service,
  ) async {
    final then = item?['session_connected_at'] as String?;
    final now = await service.sessionConnectedAt();
    return then != null && now != null && then != now;
  }

  /// [keepSession]: the revoke finished on a login made after it was requested. Everything before
  /// the revoke is cleared, but that session stays and the app goes straight to the consent screen (G4).
  static Future<void> complete(
    CommunityStore store, {
    CommunityAuthService? auth,
    FlutterSecureStorage? storage,
    bool keepSession = false,
  }) async {
    await stopWork(store);
    // The reset consumes the G1 evidence: re-login on the same account reaches the consent
    // screen (G4) instead of resetting again.
    final service = auth ?? CommunityAuthService.instance;
    try {
      final account = await service.sessionFingerprint();
      if (account != null) await ConsentHistory(store).clearG1(account);
    } catch (_) {}
    await store.transaction((tx) async {
      await tx.rawUpdate(
        "UPDATE outbox SET state='blocked',last_error_code='consent_revoked',lease_owner=NULL,lease_until=NULL",
      );
      await tx.delete('context');
      await tx.delete('raw_backfill_items');
      await tx.delete(
        'meta',
        where:
            "key IN ('raw_backfill','raw_backfill_retry','offline_capture','ingest_status','revoke_pending','raw_contract_scope') OR key LIKE 'raw_receipt:%'",
      );
    });
    await (storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: false),
            ))
        .delete(key: 'community_connection_v1');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'community_gate_cache_v1',
      jsonEncode({
        'state': keepSession ? 'consent_required' : 'kakao_required',
        'owner': null,
        'verified_at': 0,
      }),
    );
    if (!keepSession) await service.disconnect();
    _timer?.cancel();
    _timer = null;
    try {
      await Workmanager().cancelByUniqueName(retryName);
    } catch (_) {}
  }
}
