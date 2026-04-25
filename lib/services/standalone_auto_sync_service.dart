import 'package:shared_preferences/shared_preferences.dart';
import 'local_db_service.dart';
import 'standalone_api_service.dart';
import 'standalone_parser.dart';
import 'sync_engine.dart';

/// Standalone 모드 자동 동기화 드레인.
///
/// 알림 수신 시 Kotlin NotificationService 가:
///   - flutter.standalone_pending_reports 큐에 신고번호 append
///   - flutter.standalone_sync_pending = true
///   - 📬 heads-up 팝업 표시
///
/// [drainIfPending] 호출 시 처리 순서 (한 번의 drain 내):
///   1. 큐의 각 신고번호를 DB 에서 조회 (getReportByNumber)
///      - C_NO 이미 있음 → 해당 C_NO 로 상세 API 개별 호출 + upsert (빠름)
///      - C_NO 없음 → 미처리 리스트에 추가
///   2. 미처리 리스트 존재 + 이번 drain 에서 증분 아직 안 돌림 → SyncEngine.start() 1회
///      증분이 목록 API 전체를 순회하므로 미처리 번호가 목록에 있으면 자동으로 잡힘
///   3. 증분 이후 미처리 항목 다시 개별 시도
///   4. drain 도중 Kotlin 이 큐에 더 추가했으면 다음 iteration 에서 "개별 우선" 로직부터 재실행
///   5. 여전히 미발견인 항목은 retry 카운트 증가 (standalone_retry_<번호>, 최대 3회)
///      — 즉시 무한 재시도 방지, 다음 외부 트리거 대기
///
/// drain 종료 후 신규/처리변경된 신고가 있으면:
///   - flutter.pending_crawl_changes SharedPref 에 저장 → main.dart 가 카드 시트 표시
///   - flutter.notifications_history 에 추가 → 알림 탭 히스토리 누적
///   - 각 신고에 대해 개별 heads-up 알림 표시 (MainActivity.showNotification)
class StandaloneAutoSyncService {
  static const _pendingFlagKey = 'standalone_sync_pending';
  static const _pendingQueueKey = 'standalone_pending_reports';
  static const _retryPrefix = 'standalone_retry_';
  static const _maxRetry = 3;

  static bool _running = false;
  static bool get isRunning => _running;

  /// Pending 큐 read — Kotlin NotificationService.appendPendingReport 와 호환되는
  /// CSV 형식 (LIST_IDENTIFIER prefix 없는 일반 String).
  ///
  /// LIST_IDENTIFIER + JSON 형식은 LegacySharedPreferencesPlugin 이 Java
  /// deserialize 시도하다 StreamCorruptedException 발생 → getAll() 전체 실패.
  static List<String> readPendingQueue(SharedPreferences prefs) {
    final raw = prefs.getString(_pendingQueueKey) ?? '';
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  static Future<void> _writeQueue(
    SharedPreferences prefs,
    Iterable<String> queue,
  ) async {
    final dedup = <String>{...queue}.toList();
    await prefs.setString(_pendingQueueKey, dedup.join(','));
  }

  /// 개별 fetch 에서 발견한 처리변경. SyncEngine.emitChanges 로 emit 하기 전 임시 누적.
  /// (SyncEngine 의 자체 changes 는 SyncEngine.start() 가 종료 시 자동 emit.)
  static List<Map<String, dynamic>> _singleFetchChanges = [];

  static Future<void> drainIfPending() async {
    if (_running) return;
    _running = true;
    _singleFetchChanges = [];
    bool didAnyWork = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      bool didIncremental = false;

      while (true) {
        await prefs.reload();
        final queue = readPendingQueue(prefs);
        if (queue.isEmpty) {
          await prefs.setBool(_pendingFlagKey, false);
          break;
        }
        didAnyWork = true;

        // 큐 스냅샷 후 비움 (drain 도중 Kotlin 이 추가하는 건 다음 iteration 에서 잡힘)
        await _writeQueue(prefs, []);

        // 1. 개별 우선 처리
        final stillMissing = <String>[];
        for (final spp in queue) {
          final ok = await _tryFetchSingle(spp);
          if (ok) {
            await prefs.remove('$_retryPrefix$spp');
          } else {
            stillMissing.add(spp);
          }
        }

        if (stillMissing.isEmpty) continue; // 모두 개별 성공 → 다음 iteration

        // 2. 미발견 번호 존재 → 증분 sync (이번 drain 에서 1회만)
        // SyncEngine.start() 는 자체 _lastChanges 를 자동 emit 하므로 별도 누적 불필요.
        if (!didIncremental) {
          didIncremental = true;
          try {
            await SyncEngine.start(fullSync: false);
          } catch (_) {
            // 증분 실패 — 큐/플래그 복구 후 drain 종료
            await _requeueForce(prefs, stillMissing);
            break;
          }
          // 3. 증분 후 미발견 번호 다시 개별 시도 (이제 DB 에 있을 것)
          final afterIncremental = <String>[];
          for (final spp in stillMissing) {
            final ok = await _tryFetchSingle(spp);
            if (ok) {
              await prefs.remove('$_retryPrefix$spp');
            } else {
              afterIncremental.add(spp);
            }
          }
          if (afterIncremental.isNotEmpty) {
            await _requeueWithRetry(prefs, afterIncremental);
          }
        } else {
          // 이번 drain 에서 이미 증분 1회 돌렸는데도 못 찾음 → retry 큐에 남기고 종료
          await _requeueWithRetry(prefs, stillMissing);
          break;
        }
        // 4. loop 재진입 → drain 중 새로 추가된 번호 있으면 다시 개별 우선 처리
      }
      await prefs.setBool(_pendingFlagKey, false);

      // 개별 fetch 에서 모은 처리변경은 별도 emit
      if (_singleFetchChanges.isNotEmpty) {
        await SyncEngine.emitChanges(_singleFetchChanges);
      }
    } finally {
      _running = false;
      // CrawlScreen 의 'sync 진행 중' 인디케이터 해제 신호.
      // (개별 fetch 는 SyncEngine.start() 를 거치지 않으므로 done 이벤트가 자동 emit 되지 않음.)
      if (didAnyWork) SyncEngine.emitDone('동기화 완료 (개별 처리)');
    }
  }

  /// 신고번호로 DB 조회 → C_NO 있으면 상세 API 개별 호출 + upsert. 성공/실패 반환.
  ///
  /// 사용자가 알림을 탭한 명시적 요청이므로 종결여부와 무관하게 항상 크롤링.
  /// 처리상태 변동 여부와 무관하게 변경 카드 표시 (사용자 피드백).
  /// CrawlScreen 가시성 위해 SyncEngine.emitLog 로 진행상황 출력.
  static Future<bool> _tryFetchSingle(String reportNumber) async {
    SyncEngine.emitLog('개별 동기화: $reportNumber 조회 중...');
    final existing = await LocalDbService.getReportByNumber(reportNumber);
    if (existing == null || existing.id.isEmpty) {
      SyncEngine.emitLog('개별 동기화: $reportNumber 미발견 (DB) → 증분 sync 로 fallback');
      return false;
    }
    final beforeStatus = existing.status;
    try {
      SyncEngine.emitLog('상세 API 호출 (ID=${existing.id})');
      final detail = await StandaloneApiService.fetchReportDetail(existing.id);
      final ev = entryValueFromDetail(<String, dynamic>{}, detail);
      final cat = categoryFromEntryValue(ev);
      final report = parseJsonToReport(<String, dynamic>{}, detail);
      final raw = (detail['C_A_CONTENTS'] ?? detail['C_A_BODY'] ?? '').toString();
      await LocalDbService.upsertReport(report, cat, ev, rawContent: raw);
      // 사용자가 명시적으로 알림 탭한 개별 건 → 처리상태 변동 여부와 무관하게 변경 카드 표시.
      // (변동 있으면 '처리변경' / 없으면 '개별확인' 으로 구분)
      final changeType = beforeStatus != report.status ? '처리변경' : '개별확인';
      _singleFetchChanges.add(SyncEngine.reportToChangeMap(report, changeType));
      SyncEngine.emitLog('완료: $reportNumber → $changeType (상태=${report.status})');
      return true;
    } catch (e) {
      SyncEngine.emitLog('실패: $reportNumber → $e');
      return false;
    }
  }

  /// retry 카운트 증가 후 큐에 다시 넣음. 한도 초과 시 포기.
  /// 플래그는 ON 하지 않음 → 즉시 무한 재시도 방지, 다음 외부 트리거 대기.
  static Future<void> _requeueWithRetry(
    SharedPreferences prefs,
    List<String> items,
  ) async {
    final toRequeue = <String>[];
    for (final n in items) {
      final attempts = prefs.getInt('$_retryPrefix$n') ?? 0;
      if (attempts >= _maxRetry) {
        await prefs.remove('$_retryPrefix$n');
        continue;
      }
      await prefs.setInt('$_retryPrefix$n', attempts + 1);
      toRequeue.add(n);
    }
    if (toRequeue.isNotEmpty) {
      await _writeQueue(prefs, [...readPendingQueue(prefs), ...toRequeue]);
    }
  }

  /// 증분 sync 자체가 실패한 경우: retry 카운트 건드리지 않고 큐/플래그 그대로 복구.
  static Future<void> _requeueForce(
    SharedPreferences prefs,
    List<String> items,
  ) async {
    if (items.isEmpty) return;
    await _writeQueue(prefs, [...readPendingQueue(prefs), ...items]);
    await prefs.setBool(_pendingFlagKey, true);
  }

  /// 수동 초기화 용도.
  static Future<void> clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendingFlagKey, false);
    await _writeQueue(prefs, []);
  }
}
