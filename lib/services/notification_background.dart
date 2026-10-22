import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../community/update_requirement.dart';
import 'app_version.dart';
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
const _legacyUncertainPrefix = 'crawl_legacy_enqueue_uncertain.';

/// A separate FlutterEngine owns this entry point; there is no Activity/Provider.
Future<void> runNotificationBackground() async {
  await AppVersion.load(); // 필수 버전 판정·버전 헤더(CLIENT-RULES 6절)
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
    // 필수 버전 잠금(CLIENT-RULES 6절): 크롤·동기화를 하지 않는다(게이트가 막힌 때와 같게 끝낸다).
    if ((await UpdateRequirement.load(prefs)).locked) return;
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

/// `/crawl/notification` 이 없는(404) 서버로 한 번 확인되면 이 기간 동안은 baseUrl 당 다시 두드리지
/// 않고 바로 `/crawl/enqueue` 로 보낸다. 지나면 새 경로를 한 번 더 시도한다(그 사이 PC 서버가
/// 업데이트됐을 수 있다 — 2026-10 redroid 실측: 운영 PC 서버(3.1.3)에 새 경로가 없어 Doze 중에도
/// 3회 모두 404, 새 앱이 PC 서버보다 먼저 올라가면 자동 크롤링이 멈춤).
const _notificationFallbackRetryAfter = Duration(hours: 6);

bool _notificationPathKnownUnsupported(
  SharedPreferences prefs,
  String baseUrl,
) {
  if (prefs.getString(AppPrefsKeys.crawlNotificationUnsupportedBaseUrl) !=
      baseUrl) {
    return false;
  }
  final at = prefs.getInt(AppPrefsKeys.crawlNotificationUnsupportedAt);
  if (at == null) return false;
  final since = DateTime.fromMillisecondsSinceEpoch(at);
  return DateTime.now().difference(since) < _notificationFallbackRetryAfter;
}

Future<void> _markNotificationPathUnsupported(
  SharedPreferences prefs,
  String baseUrl,
) async {
  await prefs.setString(
    AppPrefsKeys.crawlNotificationUnsupportedBaseUrl,
    baseUrl,
  );
  await prefs.setInt(
    AppPrefsKeys.crawlNotificationUnsupportedAt,
    DateTime.now().millisecondsSinceEpoch,
  );
}

Future<void> _clearNotificationPathUnsupported(
  SharedPreferences prefs,
  String baseUrl,
) async {
  if (prefs.getString(AppPrefsKeys.crawlNotificationUnsupportedBaseUrl) !=
      baseUrl) {
    return;
  }
  await prefs.remove(AppPrefsKeys.crawlNotificationUnsupportedBaseUrl);
  await prefs.remove(AppPrefsKeys.crawlNotificationUnsupportedAt);
}

Set<String> _readLegacySentKeys(SharedPreferences prefs) =>
    (prefs.getStringList(AppPrefsKeys.crawlLegacyEnqueueSentKeys) ?? const [])
        .toSet();

Future<void> _markLegacyEnqueueSent(SharedPreferences prefs, String key) async {
  final keys = _readLegacySentKeys(prefs)..add(key);
  // 최근 200개만 — 끝없이 쌓이지 않는다. 오래된 키는 보통 이미 pending 에서도 지워졌다.
  final bounded = keys.length > 200
      ? keys.skip(keys.length - 200).toList()
      : keys.toList();
  if (!await prefs.setStringList(
    AppPrefsKeys.crawlLegacyEnqueueSentKeys,
    bounded,
  )) {
    throw StateError('legacy_enqueue_receipt_not_saved');
  }
}

Future<void> _clearLegacyEnqueueSent(
  SharedPreferences prefs,
  String key,
) async {
  final keys = _readLegacySentKeys(prefs);
  if (!keys.remove(key)) return;
  await prefs.setStringList(
    AppPrefsKeys.crawlLegacyEnqueueSentKeys,
    keys.toList(),
  );
}

/// 옛 경로(`/crawl/enqueue`, request_id 없음 — 재전송하면 서버가 다시 접수할 수 있다)로 보낸다.
/// 이미 이 [key] 로 성공했다는 표시가 있으면(성공 뒤 pending 제거가 기기 재시작 등으로 끝나지 못한
/// 경우) 다시 보내지 않고 바로 받아들인다 — 호출자가 pending 을 지운다(SQ-B14 중복 접수 억제).
Future<void> _sendLegacyEnqueue(
  SharedPreferences prefs, {
  required http.Client client,
  required String baseUrl,
  required String apiKey,
  required String key,
  required String number,
}) async {
  if (_readLegacySentKeys(prefs).contains(key)) return;
  // Persist before POST: no request_id exists on this endpoint. A crash, timeout
  // or non-200 response cannot prove that the server did not accept the request.
  final uncertainKey = '$_legacyUncertainPrefix$key';
  if (prefs.containsKey(uncertainKey)) {
    throw StateError('legacy_enqueue_uncertain');
  }
  if (!await prefs.setBool(uncertainKey, true)) {
    throw StateError('legacy_enqueue_intent_not_saved');
  }
  final response = await client
      .post(
        ServerContract.apiUri(baseUrl, ServerContract.crawlEnqueuePath),
        headers: {
          ...ServerContract.apiHeaders(apiKey),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'report_number': number}),
      )
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw StateError('legacy_enqueue_failed');
  }
  await _markLegacyEnqueueSent(prefs, key);
  await prefs.remove(uncertainKey);
}

/// 알림 의도 하나를 보낸다. 새 경로(`/crawl/notification`, request_id 로 재시도 안전)를 먼저 쓰고,
/// 그 경로가 없는(404) 구서버로 확인되면 옛 경로(`/crawl/enqueue`)로 대신 보낸다. 404 가 아닌 다른
/// 실패(인증·타임아웃·잘못된 ACK 등)는 구서버 신호로 보지 않고 그대로 던져 재시도에 맡긴다.
Future<void> _sendClientNotification(
  SharedPreferences prefs, {
  required http.Client client,
  required String baseUrl,
  required String apiKey,
  required String key,
  required String number,
}) async {
  // Check before even trying the new endpoint after its capability cache expires.
  if (_readLegacySentKeys(prefs).contains(key)) return;
  if (prefs.containsKey('$_legacyUncertainPrefix$key')) {
    throw StateError('legacy_enqueue_uncertain');
  }
  if (_notificationPathKnownUnsupported(prefs, baseUrl)) {
    await _sendLegacyEnqueue(
      prefs,
      client: client,
      baseUrl: baseUrl,
      apiKey: apiKey,
      key: key,
      number: number,
    );
    return;
  }

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

  if (response.statusCode == 200) {
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map ||
        decoded['request_id'] != key ||
        decoded['status'] != 'accepted') {
      throw StateError('notification_enqueue_unconfirmed');
    }
    // 새 경로가 실제로 동작했다 — 이전에 이 서버를 구서버로 기억해 뒀다면(예: 그사이 업데이트됨) 지운다.
    await _clearNotificationPathUnsupported(prefs, baseUrl);
    return;
  }

  if (response.statusCode != 404) {
    throw StateError('notification_enqueue_unconfirmed');
  }
  // 404: 이 경로가 없는 구서버다. 기억해 두고(일정 시간 뒤 새 경로 재시도) 옛 경로로 대신 보낸다.
  await _markNotificationPathUnsupported(prefs, baseUrl);
  await _sendLegacyEnqueue(
    prefs,
    client: client,
    baseUrl: baseUrl,
    apiKey: apiKey,
    key: key,
    number: number,
  );
}

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
  // Keep uncertain receipts for manual reconciliation, without starving newer
  // notifications behind them. Confirmed receipts still take the normal ACK path.
  final sent = _readLegacySentKeys(prefs);
  final uncertain = keys
      .where(
        (key) =>
            prefs.containsKey('$_legacyUncertainPrefix$key') &&
            !sent.contains(key),
      )
      .toSet();
  for (final key in keys.where((key) => !uncertain.contains(key)).take(20)) {
    await checkScope();
    final number = prefs.getString(key)!;
    try {
      await _sendClientNotification(
        prefs,
        client: client,
        baseUrl: baseUrl,
        apiKey: apiKey,
        key: key,
        number: number,
      );
    } catch (_) {
      // A failed legacy POST has no safe automatic retry. Keep its obligation
      // and intent marker, and continue with other actionable notifications.
      if (prefs.containsKey('$_legacyUncertainPrefix$key') &&
          !_readLegacySentKeys(prefs).contains(key)) {
        await checkScope();
        continue;
      }
      rethrow;
    }
    await checkScope();
    await PrefsInbox.remove(prefs, [key]);
    await _clearLegacyEnqueueSent(prefs, key);
    await prefs.remove('$_legacyUncertainPrefix$key');
  }
}
