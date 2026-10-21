import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'capture/canonical_json.dart';
import 'community_store.dart';

/// Central update notice (`client_notice`) and the 426 `client_upgrade_required` flag.
///
/// - A notice applies to this app only when `min_version.mobile` is set and the running
///   version is lower (an unreadable app version counts as lower).
/// - `current` holds the applicable notice only. `info`/`warning` are shown as a banner,
///   `required` as a dialog (see ClientNoticeHost). Shown-history is persisted per notice hash.
/// - The status `client_notice` key is the authority: `null` removes the stored notice and the
///   426 flag; a notice this app already satisfies also lifts the flag. A successful ACK lifts it.
class ClientNotice {
  static final current = ValueNotifier<Map<String, Object?>?>(null);
  static const fallback = <String, Object?>{
    'level': 'required',
    'message': '앱을 최신 버전으로 업데이트해 주세요.',
    'min_version': {'pc': null, 'mobile': null},
    'url': {
      'pc': null,
      'mobile':
          'https://play.google.com/store/apps/details?id=com.fentanest.mysafetyreport',
    },
    'deadline': null,
  };

  /// Replaced in tests. Returns null when the version cannot be read.
  @visibleForTesting
  static Future<String?> Function() versionProvider = _packageVersion;
  static Future<String?> _packageVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
  }

  static const _flagKey = 'client_upgrade_required';
  static const _shownKey = 'client_notice_shown';

  static bool valid(Object? v) {
    if (v is! Map ||
        !['info', 'warning', 'required'].contains(v['level']) ||
        v['message'] is! String ||
        (v['message'] as String).isEmpty ||
        (v['message'] as String).length > 1000) {
      return false;
    }
    for (final group in ['min_version', 'url']) {
      if (v[group] is! Map) return false;
      for (final client in ['pc', 'mobile']) {
        final value = (v[group] as Map)[client];
        if (value != null && (value is! String || value.isEmpty)) return false;
        if (group == 'url' && value is String) {
          final uri = Uri.tryParse(value);
          if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
            return false;
          }
        }
      }
    }
    return v['deadline'] == null || v['deadline'] is String;
  }

  /// Numeric dotted comparison ("2.10.0" > "2.5.0"); build suffixes (`+178`, `-rc`) are ignored.
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => [
      for (final p in v.split(RegExp(r'[+\-]')).first.split('.'))
        int.tryParse(p.trim()) ?? 0,
    ];
    final x = parts(a), y = parts(b);
    for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
      final l = i < x.length ? x[i] : 0, r = i < y.length ? y[i] : 0;
      if (l != r) return l < r ? -1 : 1;
    }
    return 0;
  }

  /// True when this app (version [app]) must see [notice].
  static bool applies(Map<String, Object?> notice, String? app) {
    final min = (notice['min_version'] as Map?)?['mobile'];
    if (min is! String || min.isEmpty) return false;
    return app == null || compareVersions(app, min) < 0;
  }

  static String hash(Map<String, Object?> notice) =>
      sha256.convert(utf8.encode(canonicalJson(notice))).toString();

  static Future<void> load(CommunityStore store) async {
    final raw = await store.meta('client_notice');
    Object? value;
    try {
      value = raw == null ? null : jsonDecode(raw);
    } catch (_) {}
    final app = await versionProvider();
    var flag = await store.meta(_flagKey);
    // A flag raised by an older build is lifted once the app version changed.
    if (flag != null && flag != 'true' && app != null && flag != app) {
      await _clearFlag(store);
      flag = null;
    }
    final notice = valid(value) ? (value as Map).cast<String, Object?>() : null;
    final applicable = notice != null && applies(notice, app) ? notice : null;
    current.value = flag != null
        ? {...(notice ?? fallback), 'level': 'required'}
        : applicable;
  }

  /// Persist a notice (`value`) from status or ACK. [authoritative] means the response carried
  /// the `client_notice` key, so `null` removes the stored notice. Never erases it otherwise.
  static Future<void> save(
    CommunityStore store,
    Object? value, {
    bool authoritative = true,
    bool clearUpgrade = false,
  }) async {
    final app = await versionProvider();
    final lift =
        clearUpgrade ||
        (authoritative && value == null) ||
        (valid(value) && !applies((value as Map).cast<String, Object?>(), app));
    await store.transaction((tx) async {
      if (authoritative && value == null) {
        await tx.delete('meta', where: 'key=?', whereArgs: ['client_notice']);
      } else if (valid(value)) {
        await store.setMeta('client_notice', jsonEncode(value), tx);
      }
      if (lift) await tx.delete('meta', where: 'key=?', whereArgs: [_flagKey]);
    });
    if (lift) await _releaseRows(store);
    await load(store);
  }

  /// HTTP 426: remember that this version was refused. The stored notice is untouched.
  static Future<void> markUpgradeRequired(CommunityStore store) async {
    await store.setMeta(_flagKey, await versionProvider() ?? 'true');
    await load(store);
  }

  static Future<void> _clearFlag(CommunityStore store) async {
    await store.db.delete('meta', where: 'key=?', whereArgs: [_flagKey]);
    await _releaseRows(store);
  }

  /// Rows blocked by an earlier 426 are sendable again once the flag is lifted.
  static Future<void> _releaseRows(CommunityStore store) async {
    await store.transaction((tx) async {
      await tx.rawUpdate(
        "UPDATE source_journal SET blocked_reason=NULL WHERE blocked_reason='blocked:client_upgrade_required'",
      );
      await tx.rawUpdate(
        "UPDATE outbox SET state='pending', last_error_code=NULL, next_retry_at=NULL, lease_owner=NULL, lease_until=NULL "
        "WHERE state IN ('blocked','retry_wait') AND last_error_code='client_upgrade_required'",
      );
    });
  }

  /// Was this exact notice already shown within [within]? History survives restarts.
  static Future<bool> shownRecently(
    CommunityStore store,
    Map<String, Object?> notice, {
    DateTime? now,
    Duration within = const Duration(hours: 24),
  }) async {
    final history = await _history(store);
    final at = history[hash(notice)];
    return at is int &&
        (now ?? DateTime.now()).millisecondsSinceEpoch - at <
            within.inMilliseconds;
  }

  static Future<void> markShown(
    CommunityStore store,
    Map<String, Object?> notice, {
    DateTime? now,
  }) async {
    final history = await _history(store);
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    history[hash(notice)] = t;
    history.removeWhere((_, v) => v is int && t - v > 30 * 24 * 3600 * 1000);
    await store.setMeta(_shownKey, jsonEncode(history));
  }

  static Future<Map<String, Object?>> _history(CommunityStore store) async {
    try {
      final raw = await store.meta(_shownKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } catch (_) {
      return {};
    }
  }
}
