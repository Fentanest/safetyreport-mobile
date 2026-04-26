import 'package:shared_preferences/shared_preferences.dart';
import 'local_db_service.dart';
import 'standalone_api_service.dart';
import 'standalone_parser.dart';
import 'sync_engine.dart';

/// Standalone 모드 자동 동기화 드레인.
///
/// 알림 수신 시 Kotlin NotificationService 가:
///   - flutter.standalone_pending_reports 큐 (CSV) 에 신고번호 append
///   - 📬 heads-up 팝업 표시
///
/// [drainIfPending] 처리 정책 (앱 종료에 견고):
///   - 큐의 항목을 한 건씩 꺼내 처리하고, **성공/포기 결정이 난 후에만** 큐에서 제거
///     → 앱이 처리 도중 죽어도 미완료 항목은 큐에 남아 다음 launch 의 drain 에서 재처리됨.
///   - 각 항목 처리:
///       1. DB 에서 신고번호로 조회 → C_NO 있으면 상세 API 개별 호출 + upsert (개별 fetch)
///       2. DB 에 없으면 → **이번 drain 에서 1회만** 증분 sync (SyncEngine.start) fallback
///          증분 후 다시 개별 fetch 시도.
///       3. 증분 후에도 미발견 → 포기 (3회 retry 같은 무한 루프 안 함)
///   - 처리 도중 Kotlin 이 큐에 추가하는 신호도 다음 iteration 에서 자연스럽게 잡힘
///     (큐 read 시 prefs.reload 로 디스크 동기화).
///
/// 프로세스 보호: drain 시작 시 SyncForegroundService 가동 → activity destroy 되어도
/// 프로세스가 OS kill 후순위로 격상 (옵션 1 - swipe-away 방어).
///
/// drain 종료 후 신규/처리변경/개별확인된 신고는 SyncEngine.emitChanges 로:
///   - flutter.pending_crawl_changes SharedPref 에 누적 → main.dart 카드 시트
///   - 각 신고에 대해 개별 heads-up 알림 (MainActivity.showNotification)
class StandaloneAutoSyncService {
  static const _pendingQueueKey = 'standalone_pending_reports';

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

  /// 큐에서 한 항목만 안전하게 제거. (Kotlin 이 동시에 추가한 다른 항목은 보존)
  static Future<void> _removeFromQueue(
    SharedPreferences prefs,
    String item,
  ) async {
    await prefs.reload();
    final cur = readPendingQueue(prefs)..remove(item);
    await _writeQueue(prefs, cur);
  }

  /// 개별 fetch 에서 발견한 변경사항. SyncEngine.emitChanges 로 일괄 emit.
  /// (SyncEngine.start() 의 자체 _lastChanges 는 자동 emit 됨.)
  static List<Map<String, dynamic>> _singleFetchChanges = [];

  static Future<void> drainIfPending() async {
    if (_running) return;
    _running = true;
    _singleFetchChanges = [];
    bool didAnyWork = false;
    bool didIncremental = false;
    bool fgsAcquired = false;
    try {
      final prefs = await SharedPreferences.getInstance();

      while (true) {
        await prefs.reload();
        final queue = readPendingQueue(prefs);
        if (queue.isEmpty) break;

        // 첫 작업 직전에 FGS 가동 (큐가 비어 있으면 굳이 가동 안 함).
        if (!fgsAcquired) {
          await SyncEngine.acquireFgs('개별 동기화 진행 중...');
          fgsAcquired = true;
        }
        didAnyWork = true;

        // 큐 맨 앞 항목을 꺼내 처리 — 큐에서 제거는 성공/포기 결정 후에만!
        // (앱이 처리 도중 죽으면 항목이 큐에 남아 다음 drain 에서 재시도)
        final spp = queue.first;

        var ok = await _tryFetchSingle(spp);

        if (!ok && !didIncremental) {
          // DB 미발견 + 이번 drain 에서 증분 sync 아직 안 함 → 1회 fallback
          didIncremental = true;
          SyncEngine.emitLog('증분 sync 1회 fallback 시작');
          try {
            await SyncEngine.start(fullSync: false);
            // 증분 후 DB 에 들어왔을 가능성 → 한 번 더 개별 시도
            ok = await _tryFetchSingle(spp);
          } catch (e) {
            SyncEngine.emitLog('증분 sync 실패: $e');
            // 증분 자체 실패 → 항목 큐에 남기고 drain 종료 (네트워크 복구 후 재시도)
            break;
          }
        }

        if (ok) {
          SyncEngine.emitLog('큐 처리 완료: $spp');
        } else {
          // 1회 개별 + 증분 fallback 후에도 미발견 → 포기 (사용자 요청대로 3회 retry 안 함)
          SyncEngine.emitLog('처리 포기: $spp (개별/증분 모두 미발견)');
        }
        // 성공이든 포기든 큐에서 제거.
        await _removeFromQueue(prefs, spp);
        // 다음 iteration 으로 → drain 도중 Kotlin 이 추가한 항목까지 처리.
      }

      // 개별 fetch 변경사항 일괄 emit
      if (_singleFetchChanges.isNotEmpty) {
        await SyncEngine.emitChanges(_singleFetchChanges);
      }
    } finally {
      _running = false;
      // CrawlScreen 의 'sync 진행 중' 인디케이터 해제 신호.
      // (개별 fetch 는 SyncEngine.start() 를 거치지 않으므로 done 이벤트가 자동 emit 안 됨.)
      if (didAnyWork) SyncEngine.emitDone('동기화 완료 (개별 처리)');
      if (fgsAcquired) await SyncEngine.releaseFgs();
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
      SyncEngine.emitLog('개별 동기화: $reportNumber 미발견 (DB)');
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
      final changeType = beforeStatus != report.status
          ? ChangeType.statusChanged
          : ChangeType.individualConfirm;
      _singleFetchChanges.add(SyncEngine.reportToChangeMap(report, changeType));
      SyncEngine.emitLog('완료: $reportNumber → $changeType (상태=${report.status})');
      return true;
    } catch (e) {
      SyncEngine.emitLog('실패: $reportNumber → $e');
      return false;
    }
  }

  /// 수동 초기화 용도.
  static Future<void> clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await _writeQueue(prefs, []);
  }
}
