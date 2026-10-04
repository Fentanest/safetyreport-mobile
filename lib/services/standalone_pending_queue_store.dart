import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs_keys.dart';
import 'prefs_inbox.dart';

/// Standalone 알림 감지 큐의 read/append/remove 단일 소스.
///
/// 저장: Kotlin NotificationService 와 앱 모두 수신함 키 [PrefsInbox.queue] 에 항목마다 새 키로 넣는다
/// (같은 CSV 키를 둘이 읽고-고쳐-쓰면 동시에 쓸 때 한쪽이 사라짐 — G11-5, M-29/M-31 과 같은 원인).
/// 예전 CSV 키(`standalone_pending_reports`, LIST_PREFIX 없는 평범한 CSV)는 업데이트 전에 남은 값만 읽고 지운다.
class PendingReportClaim {
  const PendingReportClaim(this.reportNumber, this.keys, this.legacySnapshot);
  final String reportNumber;
  final List<String> keys;
  final String? legacySnapshot;
}

class StandalonePendingQueueStore {
  StandalonePendingQueueStore._();

  /// 큐(오래된 순, 중복 제거). 호출 전에 필요하면 `prefs.reload()` 를 한다.
  static List<String> read(SharedPreferences prefs) {
    final legacy =
        (prefs.getString(AppPrefsKeys.standalonePendingReports) ?? '')
            .split(',')
            .where((s) => s.isNotEmpty);
    final inbox = _inboxEntries(prefs).map((e) => e.value);
    return <String>{...legacy, ...inbox}.toList();
  }

  static PendingReportClaim? claim(SharedPreferences prefs) {
    final numbers = read(prefs);
    if (numbers.isEmpty) return null;
    final number = numbers.first;
    return PendingReportClaim(number, _inboxEntries(prefs).where((e) => e.value == number).map((e) => e.key).toList(), prefs.getString(AppPrefsKeys.standalonePendingReports));
  }

  /// ACK precisely the events read before work. A new event with the same number survives.
  static Future<void> acknowledge(SharedPreferences prefs, PendingReportClaim claim) async {
    await PrefsInbox.remove(prefs, claim.keys);
    await prefs.reload();
    final legacy = prefs.getString(AppPrefsKeys.standalonePendingReports);
    if (legacy == claim.legacySnapshot && legacy != null) {
      final remaining = legacy.split(',').where((s) => s.isNotEmpty && s != claim.reportNumber).join(',');
      if (remaining.isEmpty) { await prefs.remove(AppPrefsKeys.standalonePendingReports); }
      else { await prefs.setString(AppPrefsKeys.standalonePendingReports, remaining); }
    }
  }

  /// 신고번호들을 큐 끝에 넣는다(공유 키를 고쳐 쓰지 않음).
  static Future<void> append(Iterable<String> reportNumbers) async {
    final prefs = await SharedPreferences.getInstance();
    for (final n in reportNumbers) {
      final value = n.trim();
      if (value.isNotEmpty) {
        await PrefsInbox.putString(prefs, PrefsInbox.queue, value);
      }
    }
  }

  /// 처리 완료된 신고번호 한 건을 큐에서 뺀다. 그 값을 가진 키만 이름으로 지우므로
  /// 그 사이 Kotlin 이 넣은 다른 항목은 남는다.
  static Future<void> remove(SharedPreferences prefs, String item) async {
    // Compatibility caller: snapshot first, never enumerate matching keys after work.
    final claim = PendingReportClaim(item, _inboxEntries(prefs).where((e) => e.value == item).map((e) => e.key).toList(), prefs.getString(AppPrefsKeys.standalonePendingReports));
    await acknowledge(prefs, claim);
  }

  static List<({String key, String value})> _inboxEntries(
    SharedPreferences prefs,
  ) {
    final keys =
        prefs.getKeys().where((k) => k.startsWith(PrefsInbox.queue) && PrefsInbox.isReadableKey(k, PrefsInbox.queue)).toList()
          ..sort();
    return [
      for (final k in keys)
        if ((prefs.get(k) as String?)?.trim().isNotEmpty ?? false)
          (key: k, value: (prefs.get(k) as String).trim()),
    ];
  }
}
