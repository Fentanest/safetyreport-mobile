import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../community/community_store.dart';
import '../community/upload/upload_background.dart';
import 'app_prefs_keys.dart';
import 'background_login_check.dart';
import 'bundled_sqlite.dart';
import 'client_compatibility.dart';
import 'prefs_inbox.dart';
import 'secure_storage_migration.dart';
import 'server_contract.dart';
import 'standalone_auth_service.dart';
import 'standalone_auto_sync_service.dart';
import 'sync_engine.dart';

const _channel = MethodChannel('com.fentanest.mysafetyreport/permissions');
const _enqueuePrefix = PrefsInbox.enqueue;

/// A separate FlutterEngine owns this entry point; there is no Activity/Provider.
Future<void> runNotificationBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  var success = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (!await SecureStorageMigration.isDone(prefs)) return;
    // BL-1: 화면 없는 알림 엔진도 main·WorkManager 와 같은 번들 SQLite 로 DB 를 연다(기기 SQLite 와 섞지 않음).
    await BundledSqlite.initialize();
    final initialScope = await _channel.invokeMethod<String>(
      'notificationWorkScope',
    );
    Future<void> checkScope() async {
      if (initialScope == null ||
          await _channel.invokeMethod<String>('notificationWorkScope') !=
              initialScope) {
        throw StateError('notification_scope_changed');
      }
    }

    final cache = jsonDecode(
      prefs.getString('community_gate_cache_v1') ?? '{}',
    );
    final owner = cache is Map ? cache['owner'] : null;
    if (owner is! String || owner.isEmpty) return;
    final standalone = prefs.getString(AppPrefsKeys.appMode) == 'standalone';
    if (standalone &&
        (prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false)) {
      return;
    }
    final store = await CommunityStore.open();
    final gate = await refreshGateHeadless(
      store,
      prefs: prefs,
      clientMode: !standalone,
      expectedOwner: owner,
      validateScope: checkScope,
      persistVerifiedCache: (value) => _channel.invokeMethod<void>(
        'notificationWorkCommitGateCache',
        {'cache': value},
      ),
    );
    if (gate != HeadlessGate.ok) return;
    await checkScope();
    if (standalone) {
      SyncEngine.rebuildBlocks = () => headlessRebuildRequired(store, prefs);
      if (await SyncEngine.rebuildBlocks!()) return;
      SyncEngine.localAccessAllowed = () async {
        await checkScope();
        return true;
      };
      await StandaloneAuthService.reloadStatus();
      await StandaloneAutoSyncService.drainIfPending(
        backgroundWorker: true,
        validateScope: checkScope,
      );
    } else {
      await ServerContract.loadProductVersion();
      final baseUrl = prefs.getString(AppPrefsKeys.baseUrl) ?? '';
      final apiKey = prefs.getString(AppPrefsKeys.apiKey) ?? '';
      await ClientCompatibility.ensure(baseUrl, apiKey);
      final client = http.Client();
      try {
        await drainClientNotifications(
          prefs,
          baseUrl: baseUrl,
          apiKey: apiKey,
          client: client,
          checkScope: checkScope,
        );
      } finally {
        client.close();
      }
    }
    await checkScope();
    success =
        await _channel.invokeMethod<bool>('notificationWorkPending') == false;
  } catch (_) {
    // Never include account, notification contents, URL or credentials in logs.
  } finally {
    await _channel.invokeMethod<void>('notificationWorkFinish', {
      'success': success,
    });
  }
}

/// Only the dedicated idempotent endpoint may receive retries. An old server's
/// 404 leaves the intent pending; it must never fall back to /crawl/enqueue.
Future<void> drainClientNotifications(
  SharedPreferences prefs, {
  required String baseUrl,
  required String apiKey,
  required http.Client client,
  required Future<void> Function() checkScope,
}) async {
  await prefs.reload();
  await PrefsInbox.synchronize(prefs, _enqueuePrefix);
  final keys =
      prefs
          .getKeys()
          .where(
            (key) =>
                key.startsWith('${_enqueuePrefix}native.notification.') &&
                PrefsInbox.isReadableKey(key, _enqueuePrefix),
          )
          .toList()
        ..sort();
  for (final key in keys.take(20)) {
    await checkScope();
    final number = prefs.getString(key)!;
    final response = await client
        .post(
          ServerContract.apiUri(baseUrl, ServerContract.crawlNotificationPath),
          headers: {
            ...ServerContract.apiHeaders(apiKey),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'report_number': number, 'request_id': key}),
        )
        .timeout(const Duration(seconds: 30));
    await checkScope();
    final Object? decoded = response.statusCode == 200
        ? jsonDecode(response.body)
        : null;
    if (decoded is! Map ||
        decoded['request_id'] != key ||
        decoded['status'] != 'accepted') {
      throw StateError('notification_enqueue_unconfirmed');
    }
    await PrefsInbox.remove(prefs, [key]);
  }
}
