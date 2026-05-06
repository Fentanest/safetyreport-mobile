import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs_keys.dart';

/// `pending_crawl_changes` SharedPreferences 키의 read/append/clear 를
/// 한 곳으로 모은다. 이 키는 SyncEngine.emitChanges 가 누적해 두고
/// main.dart 가 읽어 카드 시트로 뿌리는 통신 채널이다.
class PendingChangesStore {
  PendingChangesStore._();

  /// 누적된 changes 를 읽고 prefs 에서 비운다. main.dart 의 소비 흐름에서 사용.
  static Future<List<Map<String, dynamic>>> readAndClear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(AppPrefsKeys.pendingCrawlChanges);
    if (raw == null || raw.isEmpty) return const [];
    await prefs.remove(AppPrefsKeys.pendingCrawlChanges);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 신규 changes 를 기존 누적분 뒤에 append. SyncEngine.emitChanges 에서 사용.
  static Future<void> append(List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final existingRaw = prefs.getString(AppPrefsKeys.pendingCrawlChanges);
    List<dynamic> existing = const [];
    if (existingRaw != null && existingRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(existingRaw);
        if (decoded is List) existing = decoded;
      } catch (_) {}
    }
    await prefs.setString(
      AppPrefsKeys.pendingCrawlChanges,
      jsonEncode([...existing, ...changes]),
    );
  }
}

/// `foreground_event` 키 wrapper. WsService 가 백그라운드에서 적은 이벤트를
/// main.dart 가 foreground 복귀 시 한 번 읽고 비운다.
class ForegroundEventStore {
  ForegroundEventStore._();

  static Future<Map<String, dynamic>?> readAndClear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(AppPrefsKeys.foregroundEvent);
    if (raw == null) return null;
    await prefs.remove(AppPrefsKeys.foregroundEvent);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }
}
