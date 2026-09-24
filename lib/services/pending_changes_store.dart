import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs_keys.dart';
import 'prefs_inbox.dart';

/// 대기 중인 변경(카드 시트용)의 read/append/clear 를 한 곳으로 모은다.
/// SyncEngine.emitChanges 와 Kotlin WsService 가 쌓아 두고 main.dart 가 읽어 카드 시트로 뿌린다.
/// 저장은 [PrefsInbox.pending] 수신함 키(예전 `pending_crawl_changes` 는 남은 값만 읽음).
class PendingChangesStore {
  PendingChangesStore._();

  /// 누적된 changes 를 읽고 비운다. main.dart 의 소비 흐름에서 사용.
  /// 예전 공유 키(업데이트 전에 남은 값) + 수신함 키를 오래된 순으로 합치고, 읽은 키만 지운다(M-29/M-31).
  static Future<List<Map<String, dynamic>>> readAndClear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final result = <Map<String, dynamic>>[];
    final legacy = prefs.getString(AppPrefsKeys.pendingCrawlChanges);
    if (legacy != null) {
      await prefs.remove(AppPrefsKeys.pendingCrawlChanges);
      try {
        final decoded = jsonDecode(legacy);
        if (decoded is List) {
          result.addAll(
            decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
          );
        }
      } catch (_) {}
    }
    final inbox = PrefsInbox.read(prefs, PrefsInbox.pending);
    for (final entry in inbox) {
      result.addAll(entry.items);
    }
    await PrefsInbox.remove(prefs, inbox.map((e) => e.key));
    return result;
  }

  /// 신규 changes 를 쌓는다. SyncEngine.emitChanges 에서 사용. 공유 키를 고쳐 쓰지 않고 새 키에 넣는다.
  static Future<void> append(List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await PrefsInbox.put(prefs, PrefsInbox.pending, changes);
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
