import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../community/capture/capture_retry_store.dart';
import '../community/capture/community_capture.dart';
import 'app_prefs_keys.dart';
import 'duplicate_projection_service.dart';
import 'local_db_service.dart';
import 'maintenance_service.dart';
import 'standalone_api_service.dart';
import 'standalone_auth_service.dart';
import 'standalone_pending_queue_store.dart';
import 'sync_engine.dart';
import 'prefs_inbox.dart';
import 'sync_operation_admission.dart';

/// 개별 fetch 결과 — drainIfPending 분기용.
enum _FetchResult {
  success, // 정상 처리 + 큐 제거
  notInDb, // DB에 없음 → 증분 fallback 1회
  networkError, // errno=104, timeout, 로그인 필요·안전신문고 연결 실패 → 큐 유지하고 drain 종료
}

/// Standalone 모드 자동 동기화 드레인.
///
/// 알림 수신 시 Kotlin NotificationService 가:
///   - flutter.standalone_pending_reports 큐 (CSV) 에 신고번호 append
///   - 📬 heads-up 팝업 표시
///
/// [drainIfPending] 처리 정책 (앱 종료에 견고):
///   - 큐의 항목을 한 건씩 꺼내 처리하고, **성공을 확인한 후에만** 큐에서 제거
///     → 앱이 처리 도중 죽어도 미완료 항목은 큐에 남아 다음 launch 의 drain 에서 재처리됨.
///   - 각 항목 처리:
///       1. DB 에서 신고번호로 조회 → C_NO 있으면 상세 API 개별 호출 + upsert (개별 fetch)
///       2. DB 에 없으면 → **이번 drain 에서 1회만** 증분 sync (SyncEngine.start) fallback
///          증분 후 다시 개별 fetch 시도.
///       3. 증분 후에도 미발견 → 의무를 유지하고 이번 drain 종료
///   - 처리 도중 Kotlin 이 큐에 추가하는 신호도 다음 iteration 에서 자연스럽게 잡힘
///     (큐 read 시 prefs.reload 로 디스크 동기화).
///
/// FGS는 프로세스 우선순위를 높인다. Activity 소유 FlutterEngine의 생존이나
/// 완료를 보장하지 않으며, 엔진 종료·취소 시 미완료 의도를 유지한다.
///
/// drain 종료 후 신규/처리변경/개별확인된 신고는 SyncEngine.emitChanges 로:
///   - flutter.pending_crawl_changes SharedPref 에 누적 → main.dart 카드 시트
///   - 20건 이하면 개별 heads-up, 21건 이상이면 총건수 알림 한 건 (MainActivity.showNotification)
class StandaloneAutoSyncService {
  static bool _running = false;
  static bool get isRunning => _running;

  /// Pending 큐 read — `StandalonePendingQueueStore.read` 의 호환 alias.
  /// 외부 호출자가 줄어들면 제거 예정.
  static List<String> readPendingQueue(SharedPreferences prefs) =>
      StandalonePendingQueueStore.read(prefs);

  /// 개별 fetch 에서 발견한 변경사항. SyncEngine.emitChanges 로 일괄 emit.
  /// (SyncEngine.start() 의 자체 _lastChanges 는 자동 emit 됨.)
  static List<Map<String, dynamic>> _singleFetchChanges = [];

  /// 공유 DB 연결을 쓰는 백그라운드 작업으로 등록한다 — 백업·복원이 도중에 연결을 닫지 않게(M-25).
  static Future<void> drainIfPending() async {
    try {
      await SyncOperationAdmission.run(
        () => LocalDbService.runBackgroundWork(_drainIfPending),
        null,
        openStore: SyncEngine.openCommunityStoreForTest,
      );
    } catch (_) {
      SyncEngine.emitLog('작업 소유권 저장소를 확인하지 못해 개별 동기화를 시작하지 않았습니다. 큐는 보존했습니다.');
    }
  }

  static Future<void> _drainIfPending() async {
    if (_running || SyncEngine.isRunning) return;
    SyncEngine.beginOperation();
    _running = true;
    _singleFetchChanges = [];
    bool didAnyWork = false;
    bool didIncremental = false;
    bool fgsAcquired = false;
    bool preflightDone = false;
    try {
      final prefs = await SharedPreferences.getInstance();

      while (true) {
        if (SyncEngine.stopRequested) break; // 큐는 그대로 — 다음 drain 에서 이어 감
        await prefs.reload();
        await PrefsInbox.synchronize(prefs, PrefsInbox.queue);
        final claim = StandalonePendingQueueStore.claim(prefs);
        if (claim == null) break;

        // 첫 작업 직전에 FGS 가동 (큐가 비어 있으면 굳이 가동 안 함).
        if (!fgsAcquired) {
          await SyncEngine.acquireFgs('개별 동기화 진행 중...');
          fgsAcquired = true;
        }
        if (SyncEngine.stopRequested) break;
        didAnyWork = true;

        if (!preflightDone) {
          try {
            await SyncEngine.flushPendingUploadBeforeSync();
            preflightDone = true;
          } catch (e) {
            SyncEngine.emitLog('이전 공유 자료 업로드가 남아 개별 동기화를 시작하지 않았습니다: $e');
            break; // 큐는 남겨 두고 다음 실행에서 다시 확인한다.
          }
        }

        // 큐 맨 앞 항목을 꺼내 처리 — 큐에서 제거는 성공 확인 후에만!
        // (앱이 처리 도중 죽으면 항목이 큐에 남아 다음 drain 에서 재시도)
        final spp = claim.reportNumber;

        var result = await _tryFetchSingle(spp);

        // 네트워크 일시 오류 → 큐 유지하고 drain 종료 (네트워크 복구 후 다음 launch 재시도)
        // C_NO 가 DB 에 있는데도 errno=104 등으로 실패한 경우 증분 fallback 으로 빠지면 안 됨.
        if (result == _FetchResult.networkError) {
          SyncEngine.emitLog('네트워크 오류로 drain 중단 (큐 보존): $spp');
          break;
        }

        if (result == _FetchResult.notInDb && !didIncremental) {
          // DB 미발견 + 이번 drain 에서 증분 sync 아직 안 함 → 1회 fallback
          didIncremental = true;
          SyncEngine.emitLog('증분 sync 1회 fallback 시작');
          try {
            final sync = await SyncEngine.start(fullSync: false);
            if (sync.failed ||
                sync.busy ||
                sync.cancelled ||
                !sync.listComplete) {
              SyncEngine.emitLog('증분 동기화 미완료 — 큐를 유지합니다.');
              break;
            }
            // 증분 후 DB 에 들어왔을 가능성 → 한 번 더 개별 시도
            result = await _tryFetchSingle(spp);
            // 증분 후 재시도에서도 네트워크 오류면 큐 유지하고 종료
            if (result == _FetchResult.networkError) {
              SyncEngine.emitLog('증분 후 재시도에서 네트워크 오류 (큐 보존): $spp');
              break;
            }
          } catch (e) {
            SyncEngine.emitLog('증분 sync 실패: $e');
            break;
          }
        }

        if (result != _FetchResult.success) {
          SyncEngine.emitLog('다시 확인할 신고를 큐에 유지합니다.');
          break;
        }
        if (SyncEngine.stopRequested) break;
        await StandalonePendingQueueStore.acknowledge(prefs, claim);
        // 다음 iteration 으로 → drain 도중 Kotlin 이 추가한 항목까지 처리.
      }

      // 큐 지정 크롤링 끝의 촬영 시각 재시도(서버 _process_and_save_results 와 같음).
      // 증분 fallback 을 탔으면 그 동기화 끝에서 이미 했다.
      if (preflightDone &&
          didAnyWork &&
          !didIncremental &&
          !LocalDbService.closeRequested) {
        final filled = await MaintenanceService.backfillMissing();
        if (filled > 0) SyncEngine.emitLog('[photo] 촬영 시각 재시도로 $filled건 채움');
      }

      if (preflightDone) await SyncEngine.uploadCapturedAfterSync();

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

  /// 신고번호로 DB 조회 → C_NO 있으면 상세 API 개별 호출 + upsert.
  ///
  /// 반환:
  ///   - success      : 정상 처리 (큐 제거)
  ///   - notInDb      : C_NO 모름 → 증분 fallback 트리거
  ///   - networkError : errno=104 / timeout 등 일시 오류 (큐 유지, drain 종료)
  ///   - 임시·불명 실패: 큐 보존
  ///
  /// 사용자가 알림을 탭한 명시적 요청이므로 종결여부와 무관하게 항상 크롤링.
  /// 처리상태 변동 여부와 무관하게 변경 카드 표시 (사용자 피드백).
  static Future<_FetchResult> _tryFetchSingle(String reportNumber) async {
    SyncEngine.emitLog('개별 동기화: $reportNumber 조회 중...');
    final existing = await LocalDbService.getReportByNumber(reportNumber);
    if (existing == null || existing.id.isEmpty) {
      SyncEngine.emitLog('개별 동기화: $reportNumber 미발견 (DB)');
      return _FetchResult.notInDb;
    }
    final beforeStatus = existing.status;
    try {
      SyncEngine.emitLog('상세 API 호출 (ID=${existing.id})');
      final detail = await StandaloneApiService.fetchReportDetail(existing.id);
      // 증분·rebuild 와 같은 함수로 capture+저장한다. 재로그인 재시도 경로가
      // 같은 건을 두 번 불러도 두 번째는 동일 내용이라 이벤트가 생기지 않는다.
      final community = await SyncEngine.openCommunitySession();
      var captureActive = false;
      if (community.store != null) {
        captureActive = await SyncEngine.communityCaptureReady(
          community.store!,
        );
      }
      if (SyncEngine.stopRequested) return _FetchResult.networkError;
      SavedDetail saved;
      try {
        saved = await SyncEngine.captureAndSaveDetail(
          cNo: existing.id,
          item: <String, dynamic>{},
          detail: detail,
          trigger: 'realtime',
          tracker: CaptureTracker(),
          communityStore: community.store,
          retryFile: community.retryFile,
          projectNamespace: community.projectNamespace,
          captureActive: captureActive,
          isCancelled: () => SyncEngine.stopRequested,
        );
      } on CaptureStoreUnavailable catch (e) {
        SyncEngine.emitLog('커뮤니티 저장소 실패로 drain 중단 (큐 보존): $reportNumber → $e');
        return _FetchResult.networkError;
      } on DetailFailed catch (e) {
        SyncEngine.emitLog('실패: $reportNumber → $e');
        return _FetchResult.networkError;
      }
      final report = saved.report;
      final duplicateRefresh =
          await DuplicateProjectionService.refreshDuplicateGroups(
            await LocalDbService.db,
            trackChanges: true,
          );
      final changeType = beforeStatus != report.status
          ? ChangeType.statusChanged
          : ChangeType.individualConfirm;
      _singleFetchChanges.add(SyncEngine.reportToChangeMap(report, changeType));
      _singleFetchChanges.addAll(
        (duplicateRefresh['changes'] as List? ?? const [])
            .whereType<Map<String, dynamic>>(),
      );
      SyncEngine.emitLog(
        '완료: $reportNumber → $changeType (상태=${report.status})',
      );
      return _FetchResult.success;
    } on TokenExpiredException catch (e) {
      // 재로그인이 필요한 상태 — 큐를 지우면 이 신고를 영영 놓친다. 큐를 보존하고 멈춘다.
      SyncEngine.emitLog('로그인 필요로 drain 중단 (큐 보존): $reportNumber → $e');
      return _FetchResult.networkError;
    } on AuthTemporarilyUnavailableException catch (e) {
      SyncEngine.emitLog('안전신문고 연결 실패로 drain 중단 (큐 보존): $reportNumber → $e');
      return _FetchResult.networkError;
    } on SocketException catch (e) {
      SyncEngine.emitLog('네트워크 오류 (Socket): $reportNumber → $e');
      return _FetchResult.networkError;
    } on TimeoutException catch (e) {
      SyncEngine.emitLog('네트워크 오류 (Timeout): $reportNumber → $e');
      return _FetchResult.networkError;
    } on http.ClientException catch (e) {
      SyncEngine.emitLog('네트워크 오류 (HTTP Client): $reportNumber → $e');
      return _FetchResult.networkError;
    } catch (e) {
      // _getWithRetry가 실패한 경우 throw Exception('네트워크 오류 (3회 재시도 실패): ...')
      // 으로 일반 Exception을 던지므로 메시지로도 판별
      final msg = e.toString();
      if (msg.contains('네트워크') ||
          msg.contains('errno') ||
          msg.contains('reset') ||
          msg.contains('timed out')) {
        SyncEngine.emitLog('네트워크 오류 (일반): $reportNumber → $e');
        return _FetchResult.networkError;
      }
      SyncEngine.emitLog('실패: $reportNumber → $e');
      return _FetchResult.networkError;
    }
  }

  /// 수동 초기화 용도.
  static Future<void> clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppPrefsKeys.standalonePendingReports);
  }
}
