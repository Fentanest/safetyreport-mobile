import 'package:shared_preferences/shared_preferences.dart';
import 'local_db_service.dart';
import 'sync_engine.dart';

/// Standalone 모드 자동 동기화 드레인.
///
/// Kotlin NotificationService 가 카톡/안전신문고 알림에서 신고번호를 감지하면
/// SharedPreferences 에 다음 3가지를 기록:
///   - flutter.standalone_sync_pending = true (플래그)
///   - flutter.standalone_pending_reports = [SPP-XXXX, ...] (감지된 신고번호 큐)
///   - flutter.standalone_last_detected_at = 타임스탬프
///
/// 앱 실행 / foreground 복귀 시 [drainIfPending] 호출:
///   1. 플래그 확인
///   2. SyncEngine 증분 sync 실행
///   3. 큐의 신고번호들이 DB 에 실제로 들어왔는지 검증
///   4. 미발견 항목은 재시도 카운트 증가, 최대 도달 시 포기
///   5. 처리 중 새 알림이 들어와 플래그 재설정되면 loop 으로 자동 흡수
class StandaloneAutoSyncService {
  static const _pendingFlagKey = 'standalone_sync_pending';
  static const _pendingQueueKey = 'standalone_pending_reports';
  static const _retryPrefix = 'standalone_retry_';
  static const _maxRetry = 3;

  static bool _running = false;
  static bool get isRunning => _running;

  /// 플래그 확인 → SyncEngine 트리거. 이미 실행 중이면 skip.
  static Future<void> drainIfPending() async {
    if (_running) return;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      while (true) {
        final pending = prefs.getBool(_pendingFlagKey) ?? false;
        if (!pending) break;

        // 큐 스냅샷 읽기 → 플래그/큐 모두 비움 (이후 Kotlin 이 추가하는 건 다음 iteration)
        final detected = prefs.getStringList(_pendingQueueKey) ?? [];
        await prefs.setBool(_pendingFlagKey, false);
        await prefs.setStringList(_pendingQueueKey, []);

        try {
          await SyncEngine.start(fullSync: false);
        } catch (_) {
          // sync 자체 실패 → 플래그/큐 복구 → 다음 기회에 재시도
          await prefs.setBool(_pendingFlagKey, true);
          final cur = prefs.getStringList(_pendingQueueKey) ?? [];
          await prefs.setStringList(_pendingQueueKey, {...cur, ...detected}.toList());
          break;
        }

        // 검증: 감지된 신고번호가 실제로 DB 에 들어왔는지 확인
        if (detected.isNotEmpty) {
          await _verifyAndRetry(prefs, detected);
        }
      }
    } finally {
      _running = false;
    }
  }

  /// 감지된 신고번호 중 DB 에 없는 것들을 재시도 큐로 되돌린다.
  /// 재시도 카운트가 [_maxRetry] 이상이면 포기.
  static Future<void> _verifyAndRetry(
    SharedPreferences prefs,
    List<String> detected,
  ) async {
    final reports = await LocalDbService.getAllReports();
    final existingNumbers = reports.map((r) => r.reportNumber).toSet();

    final missing = detected.where((n) => !existingNumbers.contains(n)).toList();
    if (missing.isEmpty) {
      // 모두 sync 에서 잡힘 — 재시도 카운터 리셋
      for (final n in detected) {
        await prefs.remove('$_retryPrefix$n');
      }
      return;
    }

    final toRequeue = <String>[];
    for (final n in missing) {
      final attempts = prefs.getInt('$_retryPrefix$n') ?? 0;
      if (attempts >= _maxRetry) {
        // 포기
        await prefs.remove('$_retryPrefix$n');
        continue;
      }
      await prefs.setInt('$_retryPrefix$n', attempts + 1);
      toRequeue.add(n);
    }

    if (toRequeue.isNotEmpty) {
      // 현재 큐(드레인 도중 새로 추가됐을 수 있음)에 병합
      final cur = prefs.getStringList(_pendingQueueKey) ?? [];
      await prefs.setStringList(_pendingQueueKey, {...cur, ...toRequeue}.toList());
      // 플래그는 ON 하지 않음 — 즉시 무한 재시도 방지.
      // 다음 외부 트리거(새 알림 수신 시 Kotlin 이 플래그 ON / foreground 복귀) 시 재처리.
    }
  }

  /// 수동 초기화 용도.
  static Future<void> clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendingFlagKey, false);
    await prefs.setStringList(_pendingQueueKey, []);
  }
}
