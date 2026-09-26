import '../models/rating_lookup.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../community/capture/capture_retry_store.dart';
import '../community/capture/community_capture.dart';
import '../community/capture/list_refetch.dart';
import '../community/capture/rebuild_helpers.dart';
import '../community/capture/report_adapter.dart';
import '../community/community_store.dart';
import '../models/report.dart';
import 'app_prefs_keys.dart';
import 'community_auth_config.dart';
import 'duplicate_projection_service.dart';
import 'local_db_service.dart';
import 'maintenance_service.dart';
import 'pending_changes_store.dart';
import 'standalone_api_service.dart';
import 'review_prompt_service.dart';
import 'standalone_auth_service.dart';
import 'standalone_parser.dart';

/// 동기화 이벤트 타입
enum SyncEventType { log, progress, done, error }

/// 신고 변경 종류 — pending_crawl_changes / 알림 / 카드 시트 공통 식별자.
/// 모든 곳에서 magic string 대신 이 상수 참조 (오타 방지 + 일관성).
class ChangeType {
  /// 신규 신고 (DB 에 없던 ID)
  static const newReport = '신규';

  /// 처리상태 변경 (DB 에 있던 ID + 처리상태가 바뀜)
  static const statusChanged = '처리변경';

  /// 사용자가 알림 탭으로 명시적 요청한 개별 fetch — 처리상태 변동 없음
  /// (Standalone 모드 _tryFetchSingle 에서 사용)
  static const individualConfirm = '개별확인';

  /// 처리상태는 그대로이고 다른 내용(과태료·답변·보완 등)이 바뀜 — 서버 crawl_changes 의 '변경' 과 같은 값.
  static const contentChanged = '변경';
}

class SyncEvent {
  final SyncEventType type;
  final String message;
  final int current;
  final int total;
  SyncEvent({
    required this.type,
    this.message = '',
    this.current = 0,
    this.total = 0,
  });
}

/// 한 번의 동기화 실행 결과. T5 의 오케스트레이터가 rebuild 진행에 쓴다.
class SyncRunResult {
  const SyncRunResult({
    required this.done,
    required this.errors,
    this.orphans = 0,
    this.rebuildRunId,
    this.failed = false,
    this.errorMessage,
  });

  final int done;
  final int errors;

  /// rebuild 모드에서 목록에 없어 삭제하지 않고 남긴 행 수.
  final int orphans;
  final String? rebuildRunId;
  final bool failed;
  final String? errorMessage;
}

/// 동기화 엔진
/// 안전신문고 목록 API → 상세 API → 파싱 → 로컬 DB 저장
class SyncEngine {
  static bool _running = false;

  /// 끝날 때까지 true — [stop] 은 멈춤을 요청할 뿐이라 루프가 실제로 빠져나가야 false 가 된다(M-21: 예전엔 바로
  /// false 로 바꿔 돌던 작업 위에 새 동기화가 겹쳐 시작될 수 있었다).
  static bool get isRunning => _running;
  static bool _stopRequested = false;

  /// 사용자 중지 또는 DB 연결 닫기 요청(백업·복원·로그아웃 — M-25).
  static bool get _stopping => _stopRequested || LocalDbService.closeRequested;

  static final _controller = StreamController<SyncEvent>.broadcast();
  static Stream<SyncEvent> get events => _controller.stream;

  /// 마지막 sync 에서 발생한 신규/처리변경 신고 목록.
  /// 형식: {change_type, 신고번호, 신고명, 처리상태, 처리기관, 범칙금_과태료, ID, ...}
  /// fullSync 시에는 비움 (전체 재동기화는 변경 알림 의미 없음).
  static List<Map<String, dynamic>> _lastChanges = [];
  static List<Map<String, dynamic>> get lastChanges =>
      List.unmodifiable(_lastChanges);

  /// emitChanges 호출 시마다 신호 — ReportProvider 가 구독해서 카드 시트 트리거.
  static final _changesEmittedController = StreamController<void>.broadcast();
  static Stream<void> get changesEmitted => _changesEmittedController.stream;

  static const _methodChannel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  /// FGS ref counting — SyncEngine.start 와 drainIfPending 가 중첩 호출될 때
  /// (drain → SyncEngine.start) 한 번만 startSyncFgs / stopSyncFgs 호출되도록 관리.
  static int _fgsRefCount = 0;

  /// 동기화 작업 시작 시 호출 — 첫 호출 시 Foreground Service 가동 → 프로세스 보호.
  static Future<void> acquireFgs(String message) async {
    _fgsRefCount++;
    if (_fgsRefCount == 1) {
      try {
        await _methodChannel.invokeMethod('startSyncFgs', {'message': message});
      } catch (_) {
        // FGS 시작 실패 — 무시 (Android 12+ 백그라운드 제한 등)
      }
    }
  }

  /// 동기화 작업 종료 시 호출 — 마지막 호출 시 FGS 정지.
  static Future<void> releaseFgs() async {
    if (_fgsRefCount > 0) _fgsRefCount--;
    if (_fgsRefCount == 0) {
      try {
        await _methodChannel.invokeMethod('stopSyncFgs');
      } catch (_) {}
    }
  }

  static void _emit(SyncEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  static void _log(String msg) =>
      _emit(SyncEvent(type: SyncEventType.log, message: msg));

  /// 외부에서 sync 로그 emit (StandaloneAutoSyncService 개별 fetch 등).
  /// CrawlScreen 이 SyncEngine.events 를 구독하므로 동일 채널로 표시됨.
  static void emitLog(String msg) => _log(msg);

  /// 외부에서 sync 종료 신호 emit. CrawlScreen 이 받으면 _setRunning(false) 실행.
  /// drainIfPending 처럼 SyncEngine.start() 를 직접 호출하지 않는 흐름에서 사용.
  static void emitDone(String msg) {
    _emit(SyncEvent(type: SyncEventType.done, message: msg));
  }

  /// 테스트·T5 주입점. null 이면 실제 community.db·앱 폴더를 쓴다.
  static Future<CommunityStore> Function()? openCommunityStoreForTest;
  static File? retryFileForTest;

  /// 중앙 manifest 신선도 확보 (T5 가 refreshServerCompleted 로 연결).
  /// null 이면 scope 검사를 건너뛴다(연결 전 — REQUESTS.md).
  static Future<bool> Function()? ensureManifestFresh;

  /// 초기화 크롤링이 필요하거나 진행 중이면 true — 그때는 일반(증분·전체) 동기화를 시작하지 않는다
  /// (PC community_gate.crawl_block 의 409 COMMUNITY_REBUILD_REQUIRED 와 같음). main 이 standalone 판정으로 설치한다.
  /// 확인이 실패하면 막는다(fail-closed). 초기화 run 자신(rebuildRunId)은 막지 않는다.
  static Future<bool> Function()? rebuildBlocks;

  static const rebuildBlockedMessage = '초기화 크롤링이 필요합니다. 먼저 초기화 크롤링을 완료해 주세요.';

  static Future<SyncRunResult> start(
      {bool fullSync = false, String? rebuildRunId}) async {
    if (_running) {
      return const SyncRunResult(done: 0, errors: 0);
    }
    _running = true;
    final blocks = rebuildBlocks;
    if (rebuildRunId == null && blocks != null) {
      bool blocked;
      try {
        blocked = await blocks();
      } catch (_) {
        blocked = true;
      }
      if (blocked) {
        _running = false;
        _log('[community] $rebuildBlockedMessage');
        _emit(SyncEvent(type: SyncEventType.error, message: rebuildBlockedMessage));
        return const SyncRunResult(
            done: 0, errors: 0, failed: true, errorMessage: rebuildBlockedMessage);
      }
    }
    _stopRequested = false;
    _lastChanges = [];
    await acquireFgs(fullSync ? '전체 재동기화 진행 중...' : '증분 동기화 진행 중...');
    try {
      return await LocalDbService.runBackgroundWork(
          () => _run(fullSync: fullSync, rebuildRunId: rebuildRunId));
    } catch (e) {
      ReviewPromptService.markSessionError();
      _emit(SyncEvent(type: SyncEventType.error, message: e.toString()));
      return SyncRunResult(
          done: 0, errors: 0, rebuildRunId: rebuildRunId,
          failed: true, errorMessage: e.toString());
    } finally {
      _running = false;
      await releaseFgs();
    }
  }

  static Future<SyncRunResult> _run(
      {bool fullSync = false, String? rebuildRunId}) async {
    _log('동기화 시작...');

    // 전체 건수 파악
    _log('신고 건수 확인 중...');
    int totalCount;
    try {
      totalCount = await StandaloneApiService.fetchTotalCount();
    } on TokenExpiredException {
      rethrow; // 메시지가 그대로 사용자에게 가야 한다(재로그인 안내)
    } on AuthTemporarilyUnavailableException {
      rethrow; // 네트워크·점검 — '토큰 만료'로 보이지 않게 그대로 전달
    } catch (e) {
      throw Exception('목록 조회 실패: $e');
    }
    _log('총 $totalCount건 발견');
    final isRebuild = rebuildRunId != null;
    final trigger = isRebuild ? 'rebuild' : 'realtime';

    // 커뮤니티 capture 준비. 준비가 안 되면 개인 상세도 저장하지 않는다(Sol 통합 검토 H-01):
    // 개인 DB 가 먼저 앞서 나가면 다음 증분이 그 신고를 다시 읽는다는 보장이 없어 공유 사본이 영구 누락된다.
    final community = await openCommunitySession();
    final captureTracker = CaptureTracker();
    var communityReady = true;
    if (community.store != null) {
      communityReady = await _ensureCommunityScope(
          store: community.store!, isRebuild: isRebuild);
    }
    if (community.store == null || !communityReady) {
      final reason = community.store == null ? 'community_store_unavailable' : 'manifest_unavailable';
      _log('[community] $reason — 공유 사본을 만들 수 없어 이번 수집을 시작하지 않습니다(개인 DB 변경 없음). 다음 실행에서 다시 시도합니다.');
      throw Exception('$reason: 커뮤니티 공유 준비가 되지 않아 수집을 멈췄습니다. 네트워크를 확인한 뒤 다시 시도해 주세요.');
    }
    final captureActive = community.store != null && communityReady;

    if (totalCount == 0) {
      _log('신고 내역이 없습니다.');
      if (isRebuild) {
        // 정상 인증의 빈 목록(총 0건)도 목록 탐색 완료 → completed (rebuild.md). 예전엔 여기서 돌아가 list_complete 가
        // 안 적혀 0건 계정이 초기화를 끝낼 수 없었다. PC start.py 와 같은 규칙.
        await markRebuildListComplete(community.store!, rebuildRunId);
      }
      await _saveSyncTime();
      _emit(SyncEvent(type: SyncEventType.done, total: 0));
      return SyncRunResult(done: 0, errors: 0, rebuildRunId: rebuildRunId);
    }

    // 기존 DB 상태 스냅샷: ID → {처리상태, 종결여부}
    // 서버 _get_new_and_incomplete_ids 로직 동일:
    //   신규 OR (종결여부='N' AND title.상태 ≠ detail.처리상태)
    final existingStatus = <String, Map<String, String>>{};
    if (!fullSync || isRebuild) {
      // 사이트 원본 상태만(사용자 수정값 제외) — 사용자가 종결여부를 고쳐도 재조회는 사이트 기준으로 계속된다.
      final states = await LocalDbService.getSyncStates();
      for (final entry in states.entries) {
        if (entry.key.isEmpty) continue;
        existingStatus[entry.key] = {
          '처리상태': entry.value.status,
          '종결여부': entry.value.finished,
          '보완_미응답': entry.value.supplementOpen == 'Y' ? 'Y' : 'N',
        };
      }
      _log('기존 저장 ${existingStatus.length}건, 신규/변경 확인 시작');
    } else {
      // 먼저 지우지 않는다(M-1): 모든 신고를 다시 받아 제자리 갱신하고, 사용자 데이터(수정값·감시목록·중복 판단·지오코딩 캐시)는 둔다.
      _log('전체 재동기화 모드 (모든 신고를 다시 받음, 사용자 데이터 유지)');
    }

    // 목록 페이지 순회 (200건씩)
    final allItems = <Map<String, dynamic>>[];
    var listPageErrors = 0;
    int start = 1;
    const pageSize = 200;

    while (start <= totalCount) {
      if (_stopping) {
        listPageErrors++; // 목록을 다 받지 못함 → 정리·동기화 시각 기록 안 함
        _log('중지 요청 — 목록 조회를 멈춤');
        break;
      }
      final end = (start + pageSize - 1).clamp(1, totalCount);
      _log('목록 $start~$end건 조회 중...');
      try {
        final data = await StandaloneApiService.fetchReportList(
          startRow: start,
          endRow: end,
        );
        final list = (data['result'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        allItems.addAll(list);
      } on TokenExpiredException {
        rethrow;
      } on AuthTemporarilyUnavailableException {
        rethrow;
      } catch (e) {
        listPageErrors++;
        _log('[오류] 목록 조회 실패: $e');
      }
      start += pageSize;
    }

    // 목록 값 갱신(서버 title_to_sql 과 같음): 상세를 다시 받지 않는 종결 신고의 상태·만족도도 사이트와 맞춘다.
    if (allItems.isNotEmpty && !_stopping) {
      final refreshed = await LocalDbService.updateTitlesFromList(allItems);
      if (refreshed > 0) _log('목록 값 갱신: $refreshed건');
    }

    // 신규/증분 대상 필터.
    // 증분은 vectors/list_refetch.json 규칙 그대로:
    // 신규 ∨ 종결여부≠Y ∨ 보완_미응답=Y ∨ capture 재시도 ∨
    // (detail_status 없음 ∧ (영구 실패 아님 ∨ 목록 라벨이 실패 당시와 다름)) ∨
    // (detail_status 있음 ∧ 목록 C_NOW 라벨 ≠ detail_status 라벨).
    // 비교 기준은 community.db 의 detail_status 라벨(개인 DB 상태 열 아님).
    final List<Map<String, dynamic>> toSync;
    // rebuild 재개용 item 상태 (run_id → {state, last_list_label}).
    var rebuildStates = <String, Map<String, String>>{};
    if (isRebuild) {
      // 목록 전 페이지 성공일 때만 ID 를 rebuild_items(pending) 로 등록한다.
      // 부분 실패 → 예외(0건 성공 금지), T5 오케스트레이터가 알림.
      if (listPageErrors > 0 || _stopping) {
        throw Exception(
            '초기화 목록 수집 실패: $listPageErrors페이지 오류 — items 를 등록하지 않았습니다.');
      }
      final store = community.store;
      if (store == null) {
        throw Exception('community_store_unavailable: rebuild items 를 쓸 수 없습니다.');
      }
      final ids = allItems
          .map((i) => i['C_NO']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      await registerRebuildItems(store, rebuildRunId, ids);
      // 전 페이지 성공(빈 목록 0건 포함)만 list_complete — PC start.py 와 같은 규칙.
      await markRebuildListComplete(store, rebuildRunId);
      final rows = await store.db.rawQuery(
        'SELECT source_report_id, state, last_list_label FROM rebuild_items WHERE run_id=?',
        [rebuildRunId],
      );
      rebuildStates = {
        for (final r in rows)
          (r['source_report_id'] as String): {
            'state': (r['state'] as String?) ?? 'pending',
            'last_list_label': (r['last_list_label'] as String?) ?? '',
          },
      };
      toSync = filterRebuildTodo(allItems, rebuildStates);
      _log('초기화 수집 대상: ${toSync.length}건 (fetched ${ids.length - toSync.length}건 건너뜀)');
    } else if (fullSync) {
      toSync = allItems;
    } else {
      final detailLabels = community.store == null
          ? <String, String>{}
          : await _detailStatusLabels(community.store!);
      final permanentFails = community.store == null
          ? <String, String>{}
          : await _permanentFailLabels(community.store!);
      final retryIds =
          await CaptureRetryStore.captureRetryIds(community.retryFile);
      toSync = allItems.where((item) {
        final cNo = item['C_NO']?.toString() ?? '';
        final snap = existingStatus[cNo];
        final listLabel = _listLabel(item);
        if (snap == null) return true; // 신규
        return shouldRefetchListItem(
          inPersonalDetail: true,
          listLabel: listLabel,
          detailStatusLabel: detailLabels[cNo],
          closed: snap['종결여부'],
          supplementOpen: snap['보완_미응답'],
          rebuildFailedPermanent: permanentFails.containsKey(cNo),
          failedListLabel: permanentFails[cNo],
          inCaptureRetry: retryIds.contains(cNo),
        );
      }).toList();
    }

    _log('상세 조회 대상: ${toSync.length}건');

    int done = 0;
    int errors = 0;
    final cStore = community.store;

    for (final item in toSync) {
      if (_stopping) {
        _log('중지 요청 — 상세 조회를 멈춤 ($done/${toSync.length}건 저장됨)');
        break;
      }
      final cNo = item['C_NO']?.toString() ?? '';
      if (cNo.isEmpty) continue;

      _emit(
        SyncEvent(
          type: SyncEventType.progress,
          message: '상세 조회 중... ($cNo)',
          current: done,
          total: toSync.length,
        ),
      );

      try {
        final detail = await StandaloneApiService.fetchReportDetail(cNo);
        final saved = await captureAndSaveDetail(
          cNo: cNo,
          item: item,
          detail: detail,
          trigger: trigger,
          rebuildRunId: rebuildRunId,
          tracker: captureTracker,
          communityStore: community.store,
          retryFile: community.retryFile,
          projectNamespace: community.projectNamespace,
          captureActive: captureActive,
        );
        if (isRebuild && cStore != null) {
          await _markRebuildItem(
              cStore, rebuildRunId, cNo, 'fetched', null);
        }
        if (!fullSync && !isRebuild) {
          _trackChange(existingStatus[cNo], saved.report, saved.saved);
        }
        done++;

        if (done % 10 == 0) {
          _log('$done/${toSync.length}건 완료');
        }
      } on TokenExpiredException {
        // API 계층이 이미 자동 재로그인을 해 봤고 실패했다(비밀번호 거부·로그인 정보 없음) — 동기화를 멈추고 안내.
        rethrow;
      } on AuthTemporarilyUnavailableException {
        // 네트워크·점검 — 남은 건도 같은 이유로 실패하므로 멈춘다. '토큰 만료'로 안내하지 않는다.
        rethrow;
      } on CaptureStoreUnavailable catch (e) {
        // 한 실행에서 연속 3회 capture 실패 → 공식 사이트 반복 호출 방지, 수집 중단.
        _log('[community] 저장소 연속 실패로 동기화를 멈춥니다: $e');
        rethrow;
      } catch (e) {
        errors++;
        _log('[오류] $cNo: $e');
        if (isRebuild && cStore != null) {
          await _markRebuildItemFailed(
              cStore, rebuildRunId, cNo, _listLabel(item), e);
        }
      }

      // API 과부하 방지: 100ms 딜레이
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (!_stopping) {
      // 종결돼 다시 받지 않는 주정차 신고의 촬영 시각 재시도(서버 크롤링 끝 backfill_missing 과 같음)
      final filled = await MaintenanceService.backfillMissing();
      if (filled > 0) _log('[photo] 촬영 시각 재시도로 $filled건 채움');
    }

    // 사이트 목록에서 사라진 신고 정리는 중복군 재계산보다 먼저(지운 신고를 가리키는 중복 멤버가 남지 않게).
    // 정리 조건은 전체 재동기화이고 목록을 빠짐없이 받았을 때만(M-1, M-20).
    // rebuild 모드에서는 목록 부재 행을 삭제하지 않는다(orphan 수만 결과에).
    var orphans = 0;
    if (isRebuild) {
      final listIds = allItems
          .map((i) => i['C_NO']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      orphans = countRebuildOrphans(existingStatus.keys.toSet(), listIds);
      if (orphans > 0) _log('목록에 없는 기존 신고 $orphans건 유지 (rebuild 삭제 금지)');
    } else if (fullSync &&
        !_stopping &&
        listPageErrors == 0 &&
        allItems.isNotEmpty) {
      final removed = await LocalDbService.removeReportsNotIn(
        allItems
            .map((i) => i['C_NO']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet(),
      );
      if (removed > 0) _log('사이트 목록에 없는 신고 $removed건 정리');
    }

    final duplicateRefresh =
        await DuplicateProjectionService.refreshDuplicateGroups(
          await LocalDbService.db,
          trackChanges: !fullSync,
        );
    if (!fullSync) {
      final duplicateChanges =
          (duplicateRefresh['changes'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
      if (duplicateChanges.isNotEmpty) {
        _lastChanges = [..._lastChanges, ...duplicateChanges];
      }
    }

    // 목록 페이지가 하나라도 실패하면 마지막 동기화 시각을 성공으로 남기지 않는다(M-20).
    if (_stopping) {
      _log('[주의] 중지됨 — 마지막 동기화 시각을 갱신하지 않음');
    } else if (listPageErrors == 0) {
      await _saveSyncTime();
    } else {
      _log('[주의] 목록 $listPageErrors페이지 실패 — 마지막 동기화 시각을 갱신하지 않음');
    }

    if (_lastChanges.isNotEmpty && !isRebuild) {
      // 신고 변경은 서버와 같은 순서로, 중복군 변경은 그 뒤에
      final reportChanges = _lastChanges
          .where((c) => c['notification_kind'] == 'report')
          .toList();
      final others = _lastChanges
          .where((c) => c['notification_kind'] != 'report')
          .toList();
      _sortReportChanges(reportChanges);
      _lastChanges = [...reportChanges, ...others];
      await emitChanges(_lastChanges);
    }

    final msg =
        '${_stopping ? '동기화 중지' : '동기화 완료'}: $done건 저장${errors > 0 ? ', $errors건 오류' : ''}';
    _log(msg);
    _emit(
      SyncEvent(
        type: SyncEventType.done,
        message: msg,
        current: done,
        total: toSync.length,
      ),
    );
    return SyncRunResult(
      done: done,
      errors: errors,
      orphans: orphans,
      rebuildRunId: rebuildRunId,
    );
  }

  /// rebuild item 등록 (목록 전 페이지 성공일 때만 호출한다).
  static Future<void> registerRebuildItems(
      CommunityStore store, String runId, Set<String> ids) async {
    for (final id in ids) {
      await store.db.insert('rebuild_items', {
        'run_id': runId,
        'source_report_id': id,
        'state': 'pending',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  /// 목록 전 페이지 성공(빈 목록 0건 포함) 표시 — 이것이 있어야 초기화가 validating 으로 넘어간다.
  static Future<void> markRebuildListComplete(CommunityStore store, String runId) async {
    await store.db.rawUpdate('UPDATE rebuild_jobs SET list_complete=1 WHERE run_id=?', [runId]);
  }

  /// rebuild 수집 대상: fetched 는 건너뛴다(재개).
  static List<Map<String, dynamic>> filterRebuildTodo(
    List<Map<String, dynamic>> allItems,
    Map<String, Map<String, String>> states,
  ) =>
      allItems.where((item) {
        final cNo = item['C_NO']?.toString() ?? '';
        final state = states[cNo]?['state'];
        return state == null ||
            state == 'pending' ||
            state == 'failed_retryable';
      }).toList();

  /// rebuild orphan 수 (목록 부재 행 — 삭제하지 않는다).
  static int countRebuildOrphans(
          Set<String> personalIds, Set<String> listIds) =>
      personalIds.where((id) => !listIds.contains(id)).length;

  /// 커뮤니티 저장소·재시도 파일·네임스페이스를 연다. 실패해도 throw 하지 않는다.
  static Future<
      ({CommunityStore? store, File retryFile, String projectNamespace})>
  openCommunitySession() async {
    final File retryFile;
    if (retryFileForTest != null) {
      retryFile = retryFileForTest!;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      retryFile = File(p.join(dir.path, 'community_capture_retry.json'));
    }
    var ns = 'unconfigured';
    try {
      ns = projectNamespace(CommunityAuthConfig.fromEnvironment.supabaseUrl);
    } catch (_) {}
    CommunityStore? store;
    try {
      store = openCommunityStoreForTest != null
          ? await openCommunityStoreForTest!()
          : await CommunityStore.open();
    } catch (e) {
      _log('[community] 저장소 열기 실패: $e');
    }
    return (store: store, retryFile: retryFile, projectNamespace: ns);
  }

  /// manifest scope 검사. context 가 없으면(journal-only) true.
  /// scope 가 다르면 [ensureManifestFresh](T5 연결)로 새로 받는다.
  static Future<bool> communityCaptureReady(CommunityStore store) =>
      _ensureCommunityScope(store: store, isRebuild: false);

  static Future<bool> _ensureCommunityScope(
      {required CommunityStore store, required bool isRebuild}) async {
    Map<String, Object?>? context;
    try {
      context = await store.activeContext();
    } catch (_) {
      return false;
    }
    if (context == null) return true;
    String? scope;
    try {
      scope = await store.meta('manifest_scope');
    } catch (_) {
      return false;
    }
    final current = '${context['dataset_key']}:${context['writer_epoch']}';
    if (scope == current) return true;
    // 연결(CommunityWiring)이 없으면 신선도를 확인할 수 없다 → 수집하지 않는다(fail-closed).
    if (ensureManifestFresh == null) return false;
    try {
      return await ensureManifestFresh!();
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, String>> _detailStatusLabels(
      CommunityStore store) async {
    try {
      final ds = await store.localDatasetId();
      final rows = await store.db.rawQuery(
        'SELECT source_report_id, c_now_label FROM detail_status WHERE local_dataset_id=?',
        [ds],
      );
      return {
        for (final r in rows)
          (r['source_report_id'] as String):
              (r['c_now_label'] as String? ?? ''),
      };
    } catch (_) {
      return {};
    }
  }

  /// 마지막 rebuild run 의 영구 실패 item → 실패 당시 목록 라벨.
  static Future<Map<String, String>> _permanentFailLabels(
      CommunityStore store) async {
    try {
      final ds = await store.localDatasetId();
      final jobs = await store.db.rawQuery(
        'SELECT run_id FROM rebuild_jobs WHERE local_dataset_id=? ORDER BY updated_at DESC LIMIT 1',
        [ds],
      );
      if (jobs.isEmpty) return {};
      final items = await store.db.rawQuery(
        "SELECT source_report_id, last_list_label FROM rebuild_items WHERE run_id=? AND state='failed_permanent'",
        [jobs.first['run_id']],
      );
      return {
        for (final r in items)
          (r['source_report_id'] as String):
              (r['last_list_label'] as String? ?? ''),
      };
    } catch (_) {
      return {};
    }
  }

  /// 목록 item 의 C_NOW 라벨 (detail_status 비교용).
  static String listLabelForTest(Map<String, dynamic> item) =>
      _listLabel(item);

  static String _listLabel(Map<String, dynamic> item) {
    try {
      return titleFieldsFromListItem(item)['상태'] ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 상세 1건: parse 직후·_augmentRatingCause 전에 capture →
  /// 개인 저장 → markPersonalSave. 단건·증분·rebuild 가 같은 함수를 쓴다.
  ///
  /// capture 가 실패하면 그 신고의 upsert 를 하지 않는다([DetailFailed] throw,
  /// 호출자는 오류로 집계하고 계속한다). 한 실행에서 연속 3회 실패하면
  /// [CaptureStoreUnavailable] 을 던져 동기화를 멈춘다.
  static Future<SavedDetail> captureAndSaveDetail({
    required String cNo,
    required Map<String, dynamic> item,
    required Map<String, dynamic> detail,
    required String trigger,
    String? rebuildRunId,
    required CaptureTracker tracker,
    required CommunityStore? communityStore,
    required File retryFile,
    required String projectNamespace,
    required bool captureActive,
  }) async {
    if (!captureActive || communityStore == null) {
      // 공유 사본(journal) 없이 개인 저장을 하지 않는다 — 큐·재조회 대상은 그대로 남는다(H-01).
      throw CaptureStoreUnavailable('community_capture_unavailable: $cNo');
    }
    var report = parseJsonToReport(item, detail);
    final ev = entryValueFromDetail(item, detail);
    final cat = categoryFromEntryValue(ev);
    // 본문 원문(서버와 같은 정규화) — 중복 해시·변경 판정이 서버와 같아진다
    final raw = normalizeRawPayloadText(rawContentOf(detail));

    CaptureResult? cap;
    {
      // 좌표는 그 시점 캐시 조회 — 비어 있으면 null(이후 location_supplement).
      final geo =
          await fetchOfficialGeocode(await LocalDbService.db, report.location);
      final adapterInput = buildReportAdapterInput(report, ev, geo);
      // capture 전에 의도를 기록한다. 기록 실패 → 즉시 중단.
      await recordCaptureIntent(retryFile, cNo);
      try {
        cap = await capture(adapterInput,
            sourceReportId: cNo,
            trigger: trigger,
            rebuildRunId: rebuildRunId,
            store: communityStore,
            projectNamespace: projectNamespace);
      } catch (_) {
        if (tracker.recordFailure()) {
          throw CaptureStoreUnavailable(
              'community_store_unavailable: $cNo (연속 ${tracker.consecutiveFailures}회 실패)');
        }
        throw DetailFailed('community_capture_failed: $cNo');
      }
    }

    // 별점이 있는 신고 한정으로 사유 추가 fetch (인증 불필요 별도 API)
    final augmented = await _augmentRatingCause(report);
    report = augmented.report;
    // 주정차 사진 촬영 시각(서버 상세 저장과 같은 시점·규칙)
    final photo = await MaintenanceService.prefetchForSave(
      report.id,
      cat,
      ev,
      report.attachedPhotos,
    );

    ({bool isNew, bool changed, int syncedAt}) saved;
    try {
      saved = await LocalDbService.upsertReport(
        report,
        cat,
        ev,
        rawContent: raw,
        ratingLookup: augmented.lookup,
        photoCapture: photo,
      );
    } catch (e) {
      // 개인 저장 실패: 재조회 의도(retry)는 남겨 다음 실행이 이 신고를 다시 읽게 한다.
      await markPersonalSave(cap.eventId, false, store: communityStore);
      rethrow;
    }
    await markPersonalSave(cap.eventId, true, store: communityStore);
    try {
      await CaptureRetryStore.removeIntent(retryFile, cNo);
    } catch (_) {}
    tracker.recordSuccess();
    return SavedDetail(
        report: report,
        entryValue: ev,
        category: cat,
        saved: saved,
        capture: cap);
  }

  static Future<void> _markRebuildItem(CommunityStore store, String runId,
      String cNo, String state, String? error) async {
    try {
      await store.db.rawUpdate(
        'UPDATE rebuild_items SET state=?, attempts=attempts+1, last_error=? WHERE run_id=? AND source_report_id=?',
        [state, error, runId, cNo],
      );
    } catch (_) {}
  }

  static Future<void> _markRebuildItemFailed(CommunityStore store,
      String runId, String cNo, String listLabel, Object error) async {
    try {
      var state = classifyDetailError(error);
      final rows = await store.db.rawQuery(
        'SELECT attempts FROM rebuild_items WHERE run_id=? AND source_report_id=?',
        [runId, cNo],
      );
      final attempts =
          (rows.isEmpty ? 0 : (rows.first['attempts'] as int? ?? 0)) + 1;
      if (state == 'failed_retryable') {
        state = nextItemStateAfterFailure(attempts);
      }
      await store.db.rawUpdate(
        'UPDATE rebuild_items SET state=?, attempts=?, last_error=?, '
        "last_list_label=CASE WHEN ?='failed_permanent' THEN ? ELSE last_list_label END "
        'WHERE run_id=? AND source_report_id=?',
        [state, attempts, '$error', state, listLabel, runId, cNo],
      );
    } catch (_) {}
  }

  /// 신규/처리변경 신고 emit:
  ///   1. flutter.pending_crawl_changes SharedPref 에 누적 (main.dart 카드 시트 트리거)
  ///   2. 각 신고에 대한 개별 heads-up 알림 (MainActivity.showNotification)
  ///   3. changesEmitted Stream 신호 → ReportProvider 가 nonce 갱신
  static Future<void> emitChanges(List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;

    // 기존 pending 데이터에 누적 (main.dart 가 처리 전이면 함께 노출)
    await PendingChangesStore.append(changes);

    for (final r in changes) {
      final notificationKind = r['notification_kind']?.toString() ?? 'report';
      if (notificationKind == 'duplicate') {
        final title = r['title']?.toString() ?? '🧩 중복 신고 변경';
        final body = r['body']?.toString() ?? '';
        try {
          await _methodChannel.invokeMethod('showNotification', {
            'title': title,
            'body': body,
            'nav_tab': 4,
            'nav_subtab': 1,
            'event_type': 'crawl_changes',
            'payload_json': jsonEncode(r),
          });
        } catch (_) {}
        continue;
      }

      final changeType = r['change_type']?.toString() ?? '';
      final name = (r['신고명'] ?? '신고').toString();
      final reportNo = (r['신고번호'] ?? '').toString();
      final status = (r['처리상태'] ?? '').toString();
      final agency = (r['처리기관'] ?? '').toString();
      final fine = (r['범칙금_과태료'] ?? '').toString();

      final lines = <String>[];
      if (reportNo.isNotEmpty) lines.add('신고번호: $reportNo');
      if (status.isNotEmpty) lines.add('처리상태: $status');
      if (agency.isNotEmpty) lines.add('처리기관: $agency');
      if (fine.isNotEmpty && fine != 'null' && fine != '미확인') {
        lines.add('범칙금/과태료: $fine');
      }
      final title = switch (changeType) {
        ChangeType.newReport => '🆕 신규 신고 — $name',
        ChangeType.individualConfirm => '✅ 개별 동기화 — $name',
        _ => '🔄 처리 변경 — $name',
      };
      try {
        await _methodChannel.invokeMethod('showNotification', {
          'title': title,
          'body': lines.join('\n'),
          'nav_tab': 4,
          'nav_subtab': 1,
          'event_type': 'crawl_changes',
          'payload_json': jsonEncode(r),
        });
      } catch (_) {
        // MainActivity 미준비 등 — 무시
      }
    }

    if (!_changesEmittedController.isClosed) {
      _changesEmittedController.add(null);
    }
  }

  /// 서버 reports_repo 와 같은 기준: 새 신고면 '신규', 저장으로 바뀌었으면(추적 열·category·entry_value·원문) 변경.
  /// 처리상태까지 바뀌었으면 '처리변경', 그 밖의 변경(과태료·답변 내용 등)은 서버와 같은 '변경'.
  static void _trackChange(
    Map<String, String>? snap,
    Report r,
    ({bool isNew, bool changed, int syncedAt}) saved,
  ) {
    if (snap == null || saved.isNew) {
      _lastChanges.add(
        reportToChangeMap(r, ChangeType.newReport, syncedAt: saved.syncedAt),
      );
    } else if (saved.changed) {
      _lastChanges.add(
        reportToChangeMap(
          r,
          snap['처리상태'] != r.status
              ? ChangeType.statusChanged
              : ChangeType.contentChanged,
          syncedAt: saved.syncedAt,
        ),
      );
    }
  }

  /// 서버 crawl_state_store._report_change_sort_key 와 같은 순서: synced_at 있는 것 먼저(최신순), 없으면 답변일, 그다음 신고번호.
  static void _sortReportChanges(List<Map<String, dynamic>> changes) {
    int keyRank(Map<String, dynamic> c) =>
        (int.tryParse('${c['synced_at'] ?? ''}') ?? -1) >= 0 ? 1 : 0;
    changes.sort((a, b) {
      final ra = keyRank(a), rb = keyRank(b);
      if (ra != rb) return rb.compareTo(ra);
      final pa = ra == 1 ? (int.tryParse('${a['synced_at']}') ?? 0) : 0;
      final pb = rb == 1 ? (int.tryParse('${b['synced_at']}') ?? 0) : 0;
      if (pa != pb) return pb.compareTo(pa);
      if (ra == 0) {
        final da = '${a['답변일'] ?? ''}', db = '${b['답변일'] ?? ''}';
        if (da != db) return db.compareTo(da);
      }
      return '${b['신고번호'] ?? ''}'.compareTo('${a['신고번호'] ?? ''}');
    });
  }

  /// Report 객체를 Report.fromJson 키 형식의 Map 으로 변환 + change_type 부여.
  /// pending_crawl_changes / notification history / bottom sheet 에서 공통 사용.
  static Map<String, dynamic> reportToChangeMap(
    Report r,
    String changeType, {
    int? syncedAt,
  }) {
    // 서버 crawl_state_store.save_crawl_changes 와 같은 보완 판정·필드
    final supplementOpen = r.supplementOpen;
    final changeReason = (supplementOpen || r.status.trim() == '보완요청')
        ? 'supplement'
        : 'report';
    return {
      'notification_kind': 'report',
      'change_type': changeType,
      'change_reason': changeReason,
      'supplement_open': supplementOpen,
      'supplement_count': r.supplementCount,
      '보완횟수': r.supplementCount,
      '보완_미응답': supplementOpen ? 'Y' : 'N',
      '보완_요청자': r.supplementRequester,
      '보완_요청일시': r.supplementRequestedAt,
      '보완_완료일시': r.supplementCompletedAt,
      '보완_요청_내용': r.supplementRequest,
      '보완_신고자_의견': r.supplementOpinion,
      'ID': r.id,
      '신고번호': r.reportNumber,
      '신고명': r.name,
      '신고일': r.date,
      '답변일': r.responseDate,
      '처리기관': r.agency,
      '담당자': r.manager,
      '처리상태': r.status,
      '범칙금_과태료': r.fineInfo,
      '벌점': r.penaltyPoints,
      '차량번호': r.carNumber,
      '위반법규': r.law,
      '위반장소': r.location,
      '발생일자': r.occurrenceDate,
      '발생시각': r.occurrenceTime,
      '신고내용': r.reportContent,
      '처리내용': r.processContent,
      '첨부사진': r.attachedPhotos,
      '첨부파일': r.attachedFiles,
      '지도': r.mapImage,
      '만족도조사여부': r.pollStatus,
      '종결여부': r.processingFinish,
      'category': r.category,
      'synced_at': syncedAt ?? r.syncedAt,
    };
  }

  /// 별점이 부여된 신고에 한해 별점사유를 추가 fetch.
  /// 안전신문고 만족도 조회는 로그인 ID가 아니라 휴대폰번호가 필요하다.
  /// fetch 실패해도 별점 자체는 보존, ratingCause만 빈 채로 남김.
  /// (auto_sync_service에서도 호출 → public)
  static Future<({Report report, RatingLookup lookup})> augmentRatingCause(
    Report report,
  ) => _augmentRatingCause(report);

  static Future<({Report report, RatingLookup lookup})> _augmentRatingCause(
    Report report,
  ) async {
    if (report.rating == null || report.rating! <= 0) {
      return (report: report, lookup: RatingLookup.notTried);
    }
    final prefs = await SharedPreferences.getInstance();
    final phone = (prefs.getString(AppPrefsKeys.standalonePhoneNumber) ?? '')
        .replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.isEmpty) return (report: report, lookup: RatingLookup.failed);
    final result = await StandaloneApiService.fetchSatisfaction(
      report.reportNumber,
      phone,
    );
    if (result.score == null) {
      return (
        report: report,
        lookup: result.confirmed
            ? RatingLookup.confirmedNone
            : RatingLookup.failed,
      );
    }
    return (
      report: report.copyWith(
        rating: result.score! > 0 ? result.score : report.rating,
        ratingCause: result.cause,
      ),
      lookup: RatingLookup.found,
    );
  }

  static Future<void> _saveSyncTime() async {
    // 원천은 DB 의 last_sync 하나(M-19: 아무도 안 읽던 설정 사본은 없앰).
    await LocalDbService.setMeta('last_sync', DateTime.now().toIso8601String());
  }

  static Future<String?> getLastSyncTime() async {
    return LocalDbService.getMeta('last_sync');
  }

  /// 멈춤을 요청한다. 진행 중인 요청 하나가 끝나면 루프가 빠져나가고, 그때 [isRunning] 이 false 가 된다.
  static void stop() {
    if (_running) _stopRequested = true;
  }
}

/// 상세 1건의 저장 결과 (capture+개인 저장 — 단건·증분·rebuild 공용).
class SavedDetail {
  SavedDetail({
    required this.report,
    required this.entryValue,
    required this.category,
    required this.saved,
    this.capture,
  });

  final Report report;
  final String entryValue;
  final String category;
  final ({bool isNew, bool changed, int syncedAt}) saved;
  final CaptureResult? capture;
}

/// 건너뛴 상세 (오류 집계 후 계속). 인증 오류·CaptureStoreUnavailable 은 그대로 던진다.
class DetailFailed implements Exception {
  DetailFailed(this.message);
  final String message;
  @override
  String toString() => message;
}
