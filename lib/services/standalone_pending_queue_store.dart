import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs_keys.dart';

/// Standalone 알림 감지 큐 (`standalone_pending_reports`) 의 read/write/append/remove
/// 단일 소스.
///
/// 큐 형식은 LIST_PREFIX 없는 평범한 CSV (Kotlin NotificationService 와 호환).
/// 자세한 배경은 CLAUDE.md 의 "SharedPreferences 큐 형식 함정" 절 참고.
class StandalonePendingQueueStore {
  StandalonePendingQueueStore._();

  static List<String> read(SharedPreferences prefs) {
    final raw = prefs.getString(AppPrefsKeys.standalonePendingReports) ?? '';
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  static Future<void> _write(
    SharedPreferences prefs,
    Iterable<String> queue,
  ) async {
    final dedup = <String>{...queue}.toList();
    await prefs.setString(
      AppPrefsKeys.standalonePendingReports,
      dedup.join(','),
    );
  }

  /// 신고번호들을 큐 끝에 append (중복 제거).
  static Future<void> append(Iterable<String> reportNumbers) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = read(prefs);
    await _write(prefs, [...existing, ...reportNumbers]);
  }

  /// 처리 완료된 신고번호 한 건만 큐에서 제거. (drain 이 한 번에 한 건씩 처리하면서
  /// Kotlin 이 동시에 append 하는 다른 항목을 보존하려고 reload 후 차분 적용한다.)
  static Future<void> remove(SharedPreferences prefs, String item) async {
    await prefs.reload();
    final cur = read(prefs)..remove(item);
    await _write(prefs, cur);
  }
}
