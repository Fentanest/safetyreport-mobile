import 'package:shared_preferences/shared_preferences.dart';
import 'sync_engine.dart';

/// Standalone 모드 자동 동기화 드레인.
///
/// Kotlin NotificationService 가 카톡/안전신문고 알림에서 신고번호를 감지하면
/// SharedPreferences `standalone_sync_pending=true` 로 설정 + 로컬 알림 표시.
///
/// 앱 실행 시 / foreground 복귀 시 [drainIfPending] 호출 →
/// 플래그 있으면 SyncEngine 증분 sync 실행.
/// sync 진행 중 새 알림이 와서 플래그가 다시 true 가 되면 loop 으로 자동 재처리.
class StandaloneAutoSyncService {
  static const _pendingKey = 'standalone_sync_pending';
  static bool _running = false;

  /// 실행 중 여부. UI 에서 progress 표시용.
  static bool get isRunning => _running;

  /// 플래그 확인 → SyncEngine 트리거 (증분). 이미 실행 중이면 skip.
  /// 내부 loop 으로 처리 중 새로 설정된 플래그도 흡수.
  static Future<void> drainIfPending() async {
    if (_running) return;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      while (true) {
        final pending = prefs.getBool(_pendingKey) ?? false;
        if (!pending) break;
        // 플래그 먼저 해제 → 이후 Kotlin 이 다시 설정하는 건 다음 iteration 에서 잡힘
        await prefs.setBool(_pendingKey, false);

        try {
          await SyncEngine.start(fullSync: false);
        } catch (_) {
          // sync 실패 시 플래그 복구 → 다음 기회에 재시도
          await prefs.setBool(_pendingKey, true);
          break;
        }
      }
    } finally {
      _running = false;
    }
  }

  /// 수동 sync 이후 호출하면 pending 플래그를 정리할 수 있음.
  static Future<void> clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendingKey, false);
  }
}
