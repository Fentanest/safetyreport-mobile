// DB 최적화 작업: 상세 원본 기반 재파싱 (2026-10-17 명세 3절, 서버 services/db_optimize.py 와 같은 역할).
//
// 파서 버전이 오르면 Standalone 앱 실행 때 한 번, 신고 ID 순으로 훑는다. 원본 표에 행이 있고
// sha 가 맞으면 네트워크 없이 저장된 원본의 `result` 로 다시 파싱하고, 없으면 상세 API 로 다시 받아
// 원본 표·파일에 저장(`source='backfill'`)한 뒤 파싱한다. 저장은 `LocalDbService.reparseReport`
// (파서가 만드는 열만 갱신, 목록 열·사용자 override 유지, 바뀐 신고만 공유 `completed_observation`)이다.
//
// 취소 수단 없음. 앱 종료 뒤에는 메타 커서부터 이어서 한다. 크롤(수동 동기화·알림 동기화)과는
// `isRunning` 으로 순서를 맞춘다(최적화가 도는 동안 시작 요청은 대기열 뒤에 붙는다).
// 크롤링 상태 UI(크롤 창의 진행/중지 버튼, 크롤 run 상태)에는 넣지 않는다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../community/capture/community_capture.dart';
import '../community/capture/report_adapter.dart';
import '../community/community_store.dart';
import '../models/report.dart';
import 'app_storage_paths.dart';
import 'community_auth_config.dart';
import 'db_optimize_state.dart';
import 'duplicate_projection_service.dart';
import 'local_db_service.dart';
import 'raw_detail.dart';
import 'standalone_api_service.dart';
import 'standalone_auth_service.dart';
import 'standalone_parser.dart';

/// 최적화 한 번 훑기 결과(이번 실행분). 서버 process_all 반환과 같은 모양이다.
class OptimizeRunResult {
  const OptimizeRunResult({
    required this.total,
    required this.done,
    required this.finished,
    required this.stats,
  });

  final int total;
  final int done;
  final bool finished;
  final Map<String, dynamic> stats;
}

/// 일시 저장 실패 — 신고별 시도 횟수를 남기고 나중에 다시 시도하라는 신호(서버 _SaveTransient 와 같음).
class SaveTransient implements Exception {
  SaveTransient(this.note);
  final String note;
  @override
  String toString() => 'SaveTransient($note)';
}

class DbOptimize {
  DbOptimize._();

  /// 크롤과 같은 요청 간격(서버 0.3s).
  static Duration requestInterval = const Duration(milliseconds: 300);

  /// 일시 오류(envelope 단위) 재시도 횟수. 상세 API 안의 `_getWithRetry`(5회/1초)가
  /// 1차 전송 재시도를 맡고, 여기서는 envelope 단위 실패를 이 횟수만큼 다시 받는다(서버와 같음).
  static int fetchRetryAttempts = 3;

  /// 일시 실패(네트워크·저장 실패·토큰 갱신 중 예외)를 영구 건너뜀으로 바꾸기 전 신고별 시도 횟수
  /// (메타 attempts 에 누적, 서버 MAX_RETRY_ATTEMPTS 와 같음).
  static const int maxRetryAttempts = 3;

  /// 3회 일시 실패 뒤 건너뜀 사유(통계 skipped 키, 서버 RETRY_EXCEEDED_REASON 과 같음).
  static const String retryExceededReason = 'retry_exceeded';

  /// 보류한 수동 동기화 저장 키(`sync_meta`). 하나로 합쳐 실제로 시작될 때까지 남긴다
  /// (서버 DEFERRED_META_KEY 와 같은 자리 — 값은 합쳐진 1건의 요청 JSON).
  static const String deferredManualKey = 'detail_raw_optimize_deferred';

  /// 보류한 알림 drain 표시 키(`sync_meta`). 알림 대기열 자체는 기존 영속 큐가 맡고,
  /// 여기에는 "최적화 뒤 drain 1회" 표시만 남긴다.
  static const String deferredDrainKey = 'detail_raw_optimize_deferred_drain';

  /// 크롤 실행 중·초기화 대기 때 다음 확인까지 쉬는 시간.
  static Duration waitInterval = const Duration(seconds: 5);

  /// 로그인 필요 때 다음 확인까지 쉬는 시간(서버 60s).
  static Duration loginRetryInterval = const Duration(seconds: 60);

  static bool get isRunning => DbOptimizeState.isRunning;

  static Future<void>? _running;
  static bool _stopRequested = false;

  /// 끝나면 자동 시작할 대기 작업(수동 동기화·알림 동기화가 등록). 서버 `_after_finish` 와 같은 자리.
  /// import 순환을 피하려고 콜백으로 받는다(SyncEngine·StandaloneAutoSyncService 가 등록).
  static final List<Future<void> Function()> _afterFinishHooks = [];

  static void addAfterFinishHook(Future<void> Function() hook) {
    if (!_afterFinishHooks.contains(hook)) _afterFinishHooks.add(hook);
  }

  @visibleForTesting
  static void clearAfterFinishHooksForTest() => _afterFinishHooks.clear();

  /// 테스트 주입점. null 이면 실제 저장소·API·파일을 쓴다.
  @visibleForTesting
  static Future<CommunityStore?> Function()? openStoreForTest;

  @visibleForTesting
  static Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
  Function(String id)?
  fetchDetailForTest;

  @visibleForTesting
  static Future<CaptureResult?> Function(Map<String, Object?> adapterInput, String id)?
  captureForTest;

  @visibleForTesting
  static Directory? rawFileDirForTest;

  @visibleForTesting
  static void resetForTest() {
    DbOptimizeState.resetForTest();
    _running = null;
    _stopRequested = false;
    openStoreForTest = null;
    fetchDetailForTest = null;
    captureForTest = null;
    rawFileDirForTest = null;
    namespaceForTest = null;
    datasetIdForTest = null;
    dbPathForTest = null;
    manualStarter = null;
    drainStarter = null;
    requestInterval = const Duration(milliseconds: 300);
    fetchRetryAttempts = 3;
    waitInterval = const Duration(seconds: 5);
    loginRetryInterval = const Duration(seconds: 60);
    _afterFinishHooks.clear();
    LocalDbService.upgradeLog.clear();
    LocalDbService.upgradeRunning = false;
  }

  // ── DB 정체 확인(복원·모드 전환·교체 감지, 서버 _capture_identity 와 같은 자리) ──

  /// 시험 주입점. null 이면 실제 저장소·DB 경로를 읽는다.
  @visibleForTesting
  static Future<String> Function()? datasetIdForTest;

  @visibleForTesting
  static Future<String> Function()? dbPathForTest;

  /// 시작 때 잡은 DB 정체(개인 DB 경로·커뮤니티 데이터셋). 매 신고 처리 때 비교해 다르면
  /// 복원·교체로 보고 현재 신고를 끝내고 멈춘다(서버와 같음).
  static Future<(String, String)> _captureIdentity() async {
    var path = '';
    var dataset = '';
    try {
      path = dbPathForTest != null
          ? await dbPathForTest!()
          : await LocalDbService.getDbPath();
    } catch (_) {}
    try {
      if (datasetIdForTest != null) {
        dataset = await datasetIdForTest!();
      } else {
        final store = openStoreForTest != null
            ? await openStoreForTest!()
            : await CommunityStore.open();
        dataset = await store?.localDatasetId() ?? '';
      }
    } catch (_) {}
    return (path, dataset);
  }

  static Future<bool> _identityChanged((String, String) start) async {
    try {
      return await _captureIdentity() != start;
    } catch (_) {
      return false; // 확인 실패하면 막지 않는다(서버 note_fallback 과 같은 자리)
    }
  }

  // ── 보류 요청 영속(수동 1건 합침 + drain 표시, 서버 defer_full_crawl 과 같은 자리) ──

  /// 끝나면 보류 요청을 실제로 시작하는 함수. import 순환을 피하려고 SyncEngine·
  /// StandaloneAutoSyncService 가 등록한다(지연 등록 + 게이트 통과 때 eager 등록).
  /// 반환: 실제로 시작했으면 true — false 면 보류를 유지한다(유실 금지).
  static Future<bool> Function()? manualStarter;
  static Future<bool> Function()? drainStarter;

  /// 보류한 수동 동기화를 하나로 합쳐 영속한다. 여러 건은 조건을 합쳐 1건으로 남긴다
  /// (전체동기화·데이터유지 OR, catchupKey 는 먼저 온 것, background 는 모두 background 일 때만).
  /// 실제로 시작될 때까지 DB 에 남는다(서버 defer_full_crawl 과 같은 자리).
  static Future<int> deferManualSync({
    required bool fullSync,
    required bool preserveDataset,
    String? catchupKey,
    required bool backgroundWorker,
  }) async {
    var entry = <String, dynamic>{
      'fullSync': fullSync,
      'preserveDataset': preserveDataset,
      'catchupKey': catchupKey,
      'backgroundWorker': backgroundWorker,
    };
    try {
      final raw = await LocalDbService.getMeta(deferredManualKey);
      if (raw != null && raw.isNotEmpty) {
        final old = jsonDecode(raw);
        if (old is Map) {
          entry = {
            'fullSync': (old['fullSync'] == true) || fullSync,
            'preserveDataset':
                (old['preserveDataset'] == true) || preserveDataset,
            'catchupKey': old['catchupKey'] ?? catchupKey,
            'backgroundWorker':
                (old['backgroundWorker'] != false) && backgroundWorker,
          };
        }
      }
    } catch (_) {
      // 합치기 실패하면 새 요청으로 덮는다.
    }
    try {
      await LocalDbService.setMeta(deferredManualKey, jsonEncode(entry));
    } catch (_) {}
    return 1;
  }

  static Future<Map<String, dynamic>?> peekManualSync() async {
    try {
      final raw = await LocalDbService.getMeta(deferredManualKey);
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// 지우지 않고 읽는다(시작 성공 뒤에 지움, 서버 peek_deferred_fulls 와 같음).
  static Future<bool> hasDeferredManual() async =>
      await peekManualSync() != null;

  static Future<void> clearDeferredManual() async {
    try {
      await LocalDbService.deleteMeta(deferredManualKey);
    } catch (_) {}
  }

  static Future<void> markDrainDeferred() async {
    try {
      await LocalDbService.setMeta(deferredDrainKey, '1');
    } catch (_) {}
  }

  static Future<bool> isDrainDeferred() async {
    try {
      return await LocalDbService.getMeta(deferredDrainKey) == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearDrainDeferred() async {
    try {
      await LocalDbService.deleteMeta(deferredDrainKey);
    } catch (_) {}
  }

  // ── 메타 ───────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> readMeta() async {
    final raw = await LocalDbService.getMeta(DbOptimizeState.metaKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeMeta(Map<String, dynamic> payload) =>
      LocalDbService.setMeta(
        DbOptimizeState.metaKey,
        jsonEncode(payload),
      );

  /// `target != 현재 파서 버전` 이거나 `done` 이 아니면 시작/이어서 한다(서버와 같음).
  static Future<bool> needsRun() async {
    final meta = await readMeta();
    if (meta == null) return true;
    if (meta['target'] != mobileParserVersion) return true;
    return meta['done'] != true;
  }

  // ── 대기 사유 확인 ─────────────────────────────────────────────────────────

  /// 크롤이 끝날 때까지·초기화가 끝날 때까지 기다린다. 중단되면 false(서버와 같음).
  static Future<bool> waitForTurn({
    bool Function()? isSyncing,
    Future<bool> Function()? rebuildPending,
    Duration? wait,
    bool Function()? isStopped,
  }) async {
    final pause = wait ?? waitInterval;
    var first = true;
    while (true) {
      if ((isStopped ?? () => _stopRequested)()) return false;
      if (LocalDbService.closeRequested) return false;
      var pending = false;
      try {
        pending = await rebuildPending?.call() ?? false;
      } catch (_) {
        pending = true; // 확인 실패하면 막는다(fail-closed, 서버와 같음)
      }
      if (pending) {
        DbOptimizeState.update(
          state: 'paused',
          stage: 'waiting_rebuild',
          message: '초기화가 끝나면 이어서 합니다',
        );
        if (first) {
          DbOptimizeState.appendLog('초기화가 끝나면 시작합니다');
          first = false;
        }
      } else if ((isSyncing?.call() ?? false)) {
        DbOptimizeState.update(
          state: 'paused',
          stage: 'waiting_crawl',
          message: '크롤링이 끝나면 이어서 합니다',
        );
        if (first) {
          DbOptimizeState.appendLog('크롤링이 끝나면 시작합니다');
          first = false;
        }
      } else {
        return true;
      }
      await Future<void>.delayed(pause);
    }
  }

  // ── 신고 처리 ──────────────────────────────────────────────────────────────

  static Future<(Map<String, dynamic>?, String)> storedResult(
    String reportId,
  ) async {
    final row = await LocalDbService.getDetailRaw(reportId);
    if (row == null) return (null, 'missing');
    final blob = row['raw_zlib'];
    final sha = row['raw_sha256']?.toString() ?? '';
    if (blob is! Uint8List && blob is! List<int>) return (null, 'corrupt');
    try {
      final payload = decompressAndVerifyRawDetail(
        blob is Uint8List ? blob : Uint8List.fromList(List<int>.from(blob as List)),
        sha,
      );
      final envelope = jsonDecode(utf8.decode(payload));
      if (envelope is! Map<String, dynamic>) return (null, 'corrupt');
      return (envelope, 'ok');
    } catch (_) {
      return (null, 'corrupt');
    }
  }

  /// 상세 조회 실패 분류(서버 crawldetail_api.classify_fetch_error 와 같은 뜻).
  /// 모바일 상세 조회는 `상세 조회 실패 (<id>, 404)` 처럼 bare 코드를 던지므로
  /// `HTTP ` 접두사 없이 숫자 코드(401·419→auth, 403·404·410→permanent)도 본다.
  @visibleForTesting
  static String classifyFetchError(Object error) {
    if (error is TokenExpiredException) return 'auth';
    final text = error.toString();
    if (RegExp(r'\b40[19]\b').hasMatch(text) ||
        text.toLowerCase().contains('unauthorized')) {
      return 'auth';
    }
    if (RegExp(r'\b40[34]\b|\b410\b').hasMatch(text)) {
      return 'permanent';
    }
    return 'retryable';
  }

  static Future<({Map<String, dynamic>? envelope, String outcome, String note})>
  fetchEnvelope(
    String reportId, {
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    Function(String id)?
    fetchFn,
    int? attempts,
    Duration? interval,
  }) async {
    final fetch =
        fetchFn ?? fetchDetailForTest ?? StandaloneApiService.fetchReportDetail;
    var lastNote = '';
    for (var i = 0; i < (attempts ?? fetchRetryAttempts); i++) {
      try {
        final fetched = await fetch(reportId);
        final envelope = fetched.envelope;
        if (envelope.containsKey('result') && !envelope.containsKey('error')) {
          return (envelope: envelope, outcome: 'ok', note: '');
        }
        lastNote = '${envelope['error'] ?? 'No result key'}';
        final outcome = classifyFetchError(lastNote);
        if (outcome == 'retryable') {
          final gap = interval ?? requestInterval;
          if (gap > Duration.zero) {
            await Future<void>.delayed(gap);
          }
          continue;
        }
        return (envelope: null, outcome: outcome, note: lastNote);
      } catch (e) {
        lastNote = 'network: $e';
        final outcome = classifyFetchError(e);
        if (outcome == 'auth') return (envelope: null, outcome: 'auth', note: '$e');
        if (outcome == 'permanent') {
          return (envelope: null, outcome: 'permanent', note: '$e');
        }
        if (i + 1 < (attempts ?? fetchRetryAttempts)) {
          final gap = interval ?? requestInterval;
          if (gap > Duration.zero) await Future<void>.delayed(gap);
          continue;
        }
        return (envelope: null, outcome: 'retryable', note: lastNote);
      }
    }
    return (envelope: null, outcome: 'retryable', note: lastNote);
  }

  static Report? parseStoredResult(String reportId, Map<String, dynamic> result) {
    try {
      // 파서 입력은 지금처럼 `result` 이다. 목록 값은 상세에서 읽는다(재파싱은 목록 열을 쓰지 않음).
      return parseJsonToReport(const {}, result);
    } catch (e) {
      DbOptimizeState.appendLog('$reportId 건너뜀(parse_failed: ${e.runtimeType})');
      return null;
    }
  }

  /// 재파싱 1건 저장. [ReparseSkipped] 는 로그 뒤 그대로 던진다(영구 건너뜀 확정 —
  /// 호출자가 사유를 집계한다). 일시 실패(저장소 없음·캡처·저장 예외)는 [SaveTransient] 로
  /// 던진다(시도 횟수 누적·재시도). [CaptureStoreUnavailable] 은 그대로 던진다
  /// (작업 전체를 멈춘다, 서버와 같음). 반환: 바뀐 신고면 true.
  static Future<bool> saveReparsed(
    Report report,
    String entryValue,
    String category, {
    RawDetailUpsert? rawDetail,
    String rawContent = '',
    Map<String, int>? tallyChanged,
    Map<String, int>? tallyEvents,
    Future<CaptureResult?> Function(Map<String, Object?> adapterInput, String id)?
    captureFn,
    Future<CommunityStore?> Function()? openStore,
    String? projectNamespace,
    File? retryFile,
  }) async {
    final capture = captureFn ?? captureForTest;
    CommunityStore? store;
    if (capture == null) {
      try {
        store = openStore != null
            ? await openStore()
            : (openStoreForTest != null
                  ? await openStoreForTest!()
                  : await CommunityStore.open());
      } catch (e) {
        DbOptimizeState.appendLog('${report.id} 저장 실패(community_store_unavailable)');
        throw SaveTransient('community_store_unavailable: $e');
      }
      if (store == null) {
        DbOptimizeState.appendLog('${report.id} 저장 실패(community_store_unavailable)');
        throw SaveTransient('community_store_unavailable');
      }
    }
    CaptureResult? cap;
    try {
      final storedPhoto = await LocalDbService.getStoredPhotoCapture(report.id);
      final adapterInput = buildReportAdapterInput(
        report,
        entryValue,
        category: category,
        photoFirstCapture: storedPhoto.first,
        photoLastCapture: storedPhoto.last,
      );
      if (capture != null) {
        cap = await capture(adapterInput, report.id);
      } else {
        final ns =
            projectNamespace ?? namespaceForTest ?? _projectNamespace();
        cap = await captureReal(
          adapterInput,
          report.id,
          store: store,
          projectNamespace: ns,
        );
      }
    } on CaptureStoreUnavailable {
      rethrow;
    } catch (e) {
      DbOptimizeState.appendLog('${report.id} 저장 실패(${e.runtimeType})');
      throw SaveTransient('${e.runtimeType}: $e');
    }
    var changed = false;
    try {
      changed = await LocalDbService.reparseReport(
        report,
        category,
        entryValue,
        rawContent: rawContent,
        ssnpcCd: report.ssnpcCd,
        ssnpcType: report.ssnpcType,
        rawDetail: rawDetail,
      );
    } on ReparseSkipped catch (e) {
      final reason = e.reason.isEmpty ? 'skipped' : e.reason;
      DbOptimizeState.appendLog('${report.id} 건너뜀($reason)');
      rethrow;
    } catch (e) {
      DbOptimizeState.appendLog('${report.id} 저장 실패(${e.runtimeType})');
      throw SaveTransient('${e.runtimeType}: $e');
    }
    try {
      await markPersonalSave(cap?.eventId, true, store: store);
    } catch (_) {}
    if (changed && tallyChanged != null) {
      tallyChanged['changed'] = (tallyChanged['changed'] ?? 0) + 1;
    }
    // 바뀐 신고 중 실제로 새 journal 행이 생긴 것만 공유 재전송으로 센다(서버와 같음).
    if (cap?.eventId != null && tallyEvents != null) {
      tallyEvents['events'] = (tallyEvents['events'] ?? 0) + 1;
    }
    return changed;
  }

  static Future<CaptureResult?> captureReal(
    Map<String, Object?> adapterInput,
    String id, {
    required CommunityStore? store,
    required String projectNamespace,
  }) => capture(
    adapterInput,
    sourceReportId: id,
    trigger: DbOptimizeState.reparseTrigger,
    store: store,
    projectNamespace: projectNamespace,
  );

  static String _projectNamespace() {
    try {
      return projectNamespace(CommunityAuthConfig.fromEnvironment.supabaseUrl);
    } catch (_) {
      return 'unconfigured';
    }
  }

  static String? namespaceForTest;

  static Future<void> ensureRawFile(
    String reportId,
    Map<String, dynamic> sanitized, {
    Directory? dir,
  }) async {
    final targetDir =
        dir ?? rawFileDirForTest ?? AppStoragePaths.subDir('raw_details');
    final targetPath = rawFilePath(reportId, targetDir);
    if (targetPath == null) return;
    if (File(targetPath).existsSync()) return;
    try {
      await writeRawDetailFile(reportId, sanitized, dir: targetDir);
    } catch (_) {}
  }

  /// 신고 ID 순으로 전부 처리한다(동기 — 시험·백그라운드 작업이 함께 쓴다, 서버와 같음).
  ///
  /// 서버 process_all 과 같은 규칙: target 이 바뀌면 커서·통계·시도 횟수를 버리고 처음부터,
  /// 영구 실패(없음·삭제)·파싱 불가만 건너뛰고 일시 실패는 신고별 attempts 에 누적해 이번 회차 끝·
  /// 다음 실행에 재시도(3회면 retry_exceeded), done=true 는 전부 처리·영구·초과일 때만.
  /// 매 신고 처리 때 DB 정체를 확인해 복원·교체가 끼면 현재 신고를 끝내고 멈춘다
  /// (옛 ID 목록·커서·done 을 새 DB 에 쓰지 않음). closeDb 로 멈춰도 상태를 정리한다.
  static Future<OptimizeRunResult> processAll({
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    Function(String id)?
    fetchFn,
    bool Function()? isSyncing,
    Future<bool> Function()? rebuildPending,
    Duration? interval,
    Duration? wait,
    Duration? loginRetry,
    bool Function()? isStopped,
  }) async {
    final gap = interval ?? requestInterval;
    final loginGap = loginRetry ?? loginRetryInterval;
    final d = await LocalDbService.db;
    final idRows = await d.query('reports', columns: ['ID'], orderBy: 'ID');
    final ids = [for (final r in idRows) '${r['ID']}'];
    final total = ids.length;
    final meta = await readMeta() ?? {};
    // target 이 현재 파서 버전과 다르면 cursor·통계·시도 횟수를 버리고 처음부터.
    final String cursor;
    final Map<String, dynamic> stats;
    final Map<String, int> attempts;
    if (meta['target'] != mobileParserVersion) {
      cursor = '';
      stats = {};
      attempts = {};
    } else {
      cursor = '${meta['cursor'] ?? ''}';
      stats = Map<String, dynamic>.from(meta['stats'] as Map? ?? {});
      attempts = {};
      final rawAttempts = meta['attempts'];
      if (rawAttempts is Map) {
        for (final entry in rawAttempts.entries) {
          final count = int.tryParse('${entry.value}');
          if (count != null && count > 0) {
            attempts['${entry.key}'] = count;
          }
        }
      }
      // 복원된 DB 에 없는 ID 의 시도 기록은 버린다(다음 기동 판정을 막지 않게).
      attempts.removeWhere((id, _) => !ids.contains(id));
    }
    stats['reused'] ??= 0;
    stats['refetched'] ??= 0;
    stats['changed'] ??= 0;
    stats['events'] ??= 0;
    stats['skipped'] ??= <String, dynamic>{};
    final run = <String, dynamic>{
      'reused': 0,
      'refetched': 0,
      'changed': 0,
      'events': 0,
      'skipped': <String, dynamic>{},
    };
    // 시작 때 DB 정체(개인 DB 경로·커뮤니티 데이터셋)를 잡는다.
    final startIdentity = await _captureIdentity();

    void tally({
      bool reused = false,
      bool refetched = false,
      bool changed = false,
      bool event = false,
      String? skipped,
    }) {
      for (final target in [stats, run]) {
        if (reused) target['reused'] = (target['reused'] as int? ?? 0) + 1;
        if (refetched) target['refetched'] = (target['refetched'] as int? ?? 0) + 1;
        if (changed) target['changed'] = (target['changed'] as int? ?? 0) + 1;
        if (event) target['events'] = (target['events'] as int? ?? 0) + 1;
        if (skipped != null) {
          final missing = Map<String, dynamic>.from(target['skipped'] as Map? ?? {});
          missing[skipped] = (missing[skipped] as int? ?? 0) + 1;
          target['skipped'] = missing;
        }
      }
    }

    void recordTransient(String reportId, String note) {
      final count = (attempts[reportId] ?? 0) + 1;
      attempts[reportId] = count;
      if (count >= maxRetryAttempts) {
        tally(skipped: retryExceededReason);
        DbOptimizeState.appendLog(
          '$reportId 건너뜀($retryExceededReason${note.isEmpty ? '' : ': $note'})',
        );
      } else {
        DbOptimizeState.appendLog(
          '$reportId 일시 실패($note), 나중에 다시 시도합니다($count/$maxRetryAttempts)',
        );
      }
    }

    void recordResolved(String reportId) => attempts.remove(reportId);

    Future<void> writeProgress(String cursorId) => writeMeta({
      'target': mobileParserVersion,
      'cursor': cursorId,
      'done': false,
      'total': total,
      'stats': stats,
      'attempts': attempts,
    });

    /// null | 'stop'(중지 요청) | 'restore'(DB 교체 — 옛 커서를 새 DB 에 쓰지 않고 멈춤).
    Future<String?> stopReason() async {
      if ((isStopped ?? () => _stopRequested)()) return 'stop';
      if (LocalDbService.closeRequested) return 'restore';
      if (await _identityChanged(startIdentity)) return 'restore';
      return null;
    }

    /// 한 신고를 한 번 시도한다. 반환: 'resolved'(성공·영구 건너뜀) | 'deferred'(일시 실패,
    /// 나중에 다시) | 'login_wait'(대기 중 멈춤 — 바깥에서 끝낸다).
    Future<String> attemptReport(String reportId) async {
      final (envelope, rawState) = await storedResult(reportId);
      if (rawState == 'ok' && envelope != null) {
        final result = envelope['result'];
        if (result is! Map<String, dynamic>) {
          tally(skipped: 'result_not_object');
          DbOptimizeState.appendLog('$reportId 건너뜀(result 없음)');
          recordResolved(reportId);
          return 'resolved';
        }
        final report = parseStoredResult(reportId, result);
        if (report == null) {
          tally(skipped: 'parse_failed');
          recordResolved(reportId);
          return 'resolved';
        }
        final entry = entryValueFromDetail(const {}, result);
        final cat = categoryFromDetail(report, entry);
        final rawContent = normalizeRawPayloadText(rawContentOf(result));
        final changedTallies = <String, int>{};
        final eventTallies = <String, int>{};
        try {
          final changed = await saveReparsed(
            report,
            entry,
            cat,
            rawContent: rawContent,
            tallyChanged: changedTallies,
            tallyEvents: eventTallies,
          );
          // 저장 실패·영구 건너뜀은 예외로 나가므로 여기 오면 저장 시도 성공이다.
          tally(reused: true);
          if (changed) tally(changed: true);
          if ((eventTallies['events'] ?? 0) > 0) tally(event: true);
        } on ReparseSkipped catch (e) {
          final reason = e.reason.isEmpty ? 'skipped' : e.reason;
          tally(skipped: reason);
          recordResolved(reportId);
          return 'resolved';
        } on CaptureStoreUnavailable {
          rethrow;
        } on SaveTransient catch (e) {
          recordTransient(reportId, '저장 실패(${e.note})');
          return 'deferred';
        }
        recordResolved(reportId);
        await ensureRawFile(reportId, envelope);
        return 'resolved';
      }
      // 원본 없음·손상 → 다시 받기.
      var authTries = 0;
      var fetchNote = '';
      while (true) {
        final fetched = await fetchEnvelope(
          reportId,
          fetchFn: fetchFn,
          interval: gap,
        );
        if (gap > Duration.zero && fetched.outcome == 'ok') {
          await Future<void>.delayed(gap);
        }
        if (fetched.outcome == 'auth') {
          authTries++;
          fetchNote = fetched.note;
          if (authTries >= maxRetryAttempts) {
            recordTransient(
              reportId,
              '로그인 갱신 중 예외(${fetchNote.isEmpty ? 'auth' : fetchNote})',
            );
            return 'deferred';
          }
          DbOptimizeState.update(
            state: 'paused',
            stage: 'login_required',
            message: '로그인 뒤 이어서 합니다',
          );
          DbOptimizeState.appendLog(
            '로그인 필요 — 로그인 뒤 이어서 합니다(${fetched.note})',
          );
          await Future<void>.delayed(loginGap);
          if (await stopReason() != null) return 'login_wait';
          DbOptimizeState.update(state: 'running', stage: 'running', message: '');
          continue; // 같은 신고부터 다시
        }
        if (fetched.outcome == 'permanent') {
          tally(skipped: 'not_found');
          final detail = fetched.note.isEmpty ? fetchNote : fetched.note;
          DbOptimizeState.appendLog(
            '$reportId 건너뜀(not_found${detail.isEmpty ? '' : ': $detail'})',
          );
          recordResolved(reportId);
          return 'resolved';
        }
        if (fetched.outcome == 'retryable') {
          recordTransient(reportId, fetched.note.isEmpty ? 'fetch_failed' : fetched.note);
          return 'deferred';
        }
        if (fetched.outcome != 'ok' || fetched.envelope == null) {
          final note = fetched.note.isEmpty ? fetchNote : fetched.note;
          recordTransient(reportId, note.isEmpty ? fetched.outcome : note);
          return 'deferred';
        }
        final data = fetched.envelope!;
        final prepared = prepareRawDetail(data);
        final result = data['result'];
        if (result is! Map<String, dynamic>) {
          tally(skipped: 'result_not_object');
          DbOptimizeState.appendLog('$reportId 건너뜀(result 없음)');
          recordResolved(reportId);
          return 'resolved';
        }
        final report = parseStoredResult(reportId, result);
        if (report == null) {
          tally(skipped: 'parse_failed');
          recordResolved(reportId);
          return 'resolved';
        }
        final entry = entryValueFromDetail(const {}, result);
        final cat = categoryFromDetail(report, entry);
        final rawContent = normalizeRawPayloadText(rawContentOf(result));
        final upsert = RawDetailUpsert(
          zlib: compressRawDetail(prepared.canonical),
          sha256: prepared.sha256,
          size: prepared.canonical.length,
          fetchedAt: formatRawFetchedAt(DateTime.now()),
          source: DbOptimizeState.backfillSource,
        );
        final changedTallies = <String, int>{};
        final eventTallies = <String, int>{};
        try {
          final changed = await saveReparsed(
            report,
            entry,
            cat,
            rawDetail: upsert,
            rawContent: rawContent,
            tallyChanged: changedTallies,
            tallyEvents: eventTallies,
          );
          // 저장 실패·영구 건너뜀은 예외로 나가므로 여기 오면 저장 시도 성공이다.
          tally(refetched: true);
          if (changed) tally(changed: true);
          if ((eventTallies['events'] ?? 0) > 0) tally(event: true);
        } on ReparseSkipped catch (e) {
          final reason = e.reason.isEmpty ? 'skipped' : e.reason;
          tally(skipped: reason);
          recordResolved(reportId);
          return 'resolved';
        } on CaptureStoreUnavailable {
          rethrow;
        } on SaveTransient catch (e) {
          recordTransient(reportId, '저장 실패(${e.note})');
          return 'deferred';
        }
        recordResolved(reportId);
        try {
          await writeRawDetailFile(
            reportId,
            prepared.sanitized,
            dir: rawFileDirForTest,
          );
        } catch (_) {}
        return 'resolved';
      }
    }

    var startIndex = 0;
    if (cursor.isNotEmpty) {
      final at = ids.indexOf(cursor);
      startIndex = at >= 0 ? at + 1 : 0;
    }
    var doneCount = startIndex;
    DbOptimizeState.update(
      total: total,
      done: doneCount,
      state: 'running',
      stage: 'running',
      message: '',
    );

    // 이전 회차에서 커서는 넘겼지만 다시 시도하기로 한 신고(시도 3회 미만)는 이번 회차 끝 재시도 대상이다.
    final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final pendingRetry = <String>[
      for (final entry in attempts.entries)
        if (entry.value > 0 &&
            entry.value < maxRetryAttempts &&
            (order[entry.key] ?? startIndex) < startIndex)
          entry.key,
    ]..sort((a, b) => order[a]!.compareTo(order[b]!));

    var index = startIndex;
    String? stoppedReason; // null | 'stop' | 'restore'
    while (index < ids.length) {
      stoppedReason = await stopReason();
      if (stoppedReason != null) break;
      final turn = await waitForTurn(
        isSyncing: isSyncing,
        rebuildPending: rebuildPending,
        wait: wait,
        isStopped: isStopped,
      );
      if (!turn) {
        stoppedReason = await stopReason() ?? 'stop';
        break;
      }
      stoppedReason = await stopReason();
      if (stoppedReason != null) break;
      if (DbOptimizeState.stage == 'waiting_crawl' ||
          DbOptimizeState.stage == 'waiting_rebuild') {
        DbOptimizeState.update(state: 'running', stage: 'running', message: '');
      }
      final reportId = ids[index];
      final String outcome;
      try {
        outcome = await attemptReport(reportId);
      } on CaptureStoreUnavailable {
        rethrow;
      }
      if (outcome == 'login_wait') {
        stoppedReason = await stopReason() ?? 'stop';
        break;
      }
      if (outcome == 'deferred' && !pendingRetry.contains(reportId)) {
        pendingRetry.add(reportId);
      }
      // 매 신고 처리 때 DB 정체 확인 — 복원이 끼면 옛 커서를 복원 DB 에 쓰지 않고 멈춘다.
      stoppedReason = await stopReason();
      if (stoppedReason != null) break;

      index += 1;
      doneCount = index;
      DbOptimizeState.update(done: doneCount);
      if (await stopReason() == null) {
        await writeProgress(ids[index - 1]);
      }
    }

    // 이번 회차 끝 재시도: 일시 실패분 중 아직 3회 미만인 것만 같은 회차에서 다시 시도한다.
    var retryRound = 0;
    while (stoppedReason == null && pendingRetry.isNotEmpty) {
      retryRound++;
      if (retryRound > maxRetryAttempts) break;
      final current = [
        for (final id in pendingRetry)
          if ((attempts[id] ?? 0) < maxRetryAttempts) id,
      ];
      if (current.isEmpty) break;
      pendingRetry.clear();
      for (var i = 0; i < current.length; i++) {
        final reportId = current[i];
        stoppedReason = await stopReason();
        if (stoppedReason != null) {
          pendingRetry.addAll(
            current.sublist(i).where(
              (r) => (attempts[r] ?? 0) < maxRetryAttempts,
            ),
          );
          break;
        }
        final turn = await waitForTurn(
          isSyncing: isSyncing,
          rebuildPending: rebuildPending,
          wait: wait,
          isStopped: isStopped,
        );
        if (!turn) {
          stoppedReason = await stopReason() ?? 'stop';
          pendingRetry.addAll(current.sublist(i));
          break;
        }
        final String outcome;
        try {
          outcome = await attemptReport(reportId);
        } on CaptureStoreUnavailable {
          rethrow;
        }
        if (outcome == 'login_wait') {
          stoppedReason = await stopReason() ?? 'stop';
          pendingRetry.addAll(
            current.sublist(i).where(
              (r) => (attempts[r] ?? 0) < maxRetryAttempts,
            ),
          );
          break;
        }
        if (outcome == 'deferred' &&
            (attempts[reportId] ?? 0) < maxRetryAttempts &&
            !pendingRetry.contains(reportId)) {
          pendingRetry.add(reportId);
        }
        stoppedReason = await stopReason();
        if (stoppedReason != null) break;
        if (await stopReason() == null) {
          await writeProgress(index > 0 ? ids[index - 1] : '');
        }
      }
    }

    // 다음 기동 때 다시 시도할 일시 실패가 남아 있으면 done 이 아니다.
    final hasPending = attempts.values.any((v) => v < maxRetryAttempts);
    final finished =
        stoppedReason == null &&
        index >= ids.length &&
        pendingRetry.isEmpty &&
        !hasPending;
    if (stoppedReason == 'restore') {
      // 복원된 DB 에 옛 ID 목록·커서·done 을 쓰지 않는다 — 메타를 그대로 둔다.
      DbOptimizeState.appendLog('DB 복원으로 멈춤 — 복원된 DB에서 처음부터 다시 판단합니다');
      DbOptimizeState.update(
        state: 'idle',
        stage: '',
        message: 'DB 복원으로 멈춤 — 다음 기동 때 다시 판단합니다',
      );
      return OptimizeRunResult(
        total: total,
        done: doneCount,
        finished: false,
        stats: run,
      );
    }
    if (stoppedReason == 'stop') {
      // closeDb 로 멈춰도 상태를 정리한다 — isRunning 이 남으면 동기화가 무한 보류된다.
      DbOptimizeState.appendLog('중단됨 — 다음 실행 때 커서부터 이어서 합니다');
      DbOptimizeState.update(state: 'idle', stage: '', message: '중단됨');
      return OptimizeRunResult(
        total: total,
        done: doneCount,
        finished: false,
        stats: run,
      );
    }
    if (finished) {
      await writeMeta({
        'target': mobileParserVersion,
        'cursor': ids.isEmpty ? '' : ids.last,
        'done': true,
        'total': total,
        'stats': stats,
        'attempts': <String, int>{},
      });
      final changed = stats['changed'] as int? ?? 0;
      final events = stats['events'] as int? ?? 0;
      final skippedTotal = (stats['skipped'] as Map? ?? {}).values.fold<int>(
        0,
        (a, e) => a + ((e as num?)?.toInt() ?? 0),
      );
      DbOptimizeState.appendLog(
        '완료(재파싱 변경 $changed건, 공유 재전송 $events건'
        '${skippedTotal > 0 ? ', 건너뜀 $skippedTotal건' : ''})',
      );
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final finishedAt =
          '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
      DbOptimizeState.update(
        state: 'completed',
        stage: 'done',
        done: total,
        finishedAt: finishedAt,
        message: '재파싱 변경 $changed건${events > 0 ? ', 공유 재전송 $events건' : ''}',
      );
      if (changed > 0) {
        try {
          await DuplicateProjectionService.refreshDuplicateGroups(
            await LocalDbService.db,
          );
        } catch (_) {}
      }
      await _afterFinish();
    }
    if (!finished && stoppedReason == null) {
      // 방어: 일시 실패 잔여 등으로 끝나지 않았는데 정지 사유도 없으면 상태를 정리한다 —
      // isRunning 이 남으면 동기화가 무한 보류된다. 메타 attempts 는 그대로 두어 다음에 이어서 한다.
      DbOptimizeState.appendLog('일시 실패 잔여 — 다음 실행 때 이어서 합니다');
      DbOptimizeState.update(
        state: 'idle',
        stage: '',
        message: '다음 실행 때 이어서 합니다',
      );
    }
    return OptimizeRunResult(
      total: total,
      done: doneCount,
      finished: finished,
      stats: run,
    );
  }

  /// 끝나면 대기 작업·보류 요청을 이어서 시작한다(메모리 훅은 순서대로, 보류는 영속분 — 서버 _after_finish 와 같음).
  static Future<void> _afterFinish() async {
    for (final hook in List.of(_afterFinishHooks)) {
      try {
        await hook();
      } catch (_) {}
    }
    await runDeferredStarters();
  }

  /// 보류 요청 시작(수동 1건 합침 + drain 1회). 실제로 시작될 때만 보류를 지운다(유실 금지).
  static Future<void> runDeferredStarters() async {
    try {
      final starter = manualStarter;
      if (starter != null && await hasDeferredManual()) {
        if (await starter()) await clearDeferredManual();
      }
    } catch (_) {}
    try {
      final starter = drainStarter;
      if (starter != null && await isDrainDeferred()) {
        if (await starter()) await clearDrainDeferred();
      }
    } catch (_) {}
  }

  /// 작업 예외(error) 뒤: 동기화 보류를 풀어 대기 요청을 실행한다(서버 _after_error 와 같음).
  /// 최적화는 다음 기회에 다시 시도한다(메타는 done=false 그대로).
  static Future<void> _afterError() async {
    await runDeferredStarters();
  }

  // ── 시작/종료 ──────────────────────────────────────────────────────────────

  /// 스키마 업그레이드 뒤 Standalone 앱 실행 때 한 번. 할 일 없으면 null(서버와 같음).
  /// Client 모드는 부르지 않는다(서버가 한다).
  static Future<void>? maybeStart({
    bool Function()? isSyncing,
    Future<bool> Function()? rebuildPending,
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    Function(String id)?
    fetchFn,
    bool wait = false,
  }) {
    if (_running != null) return _running;
    return _maybeStartAsync(
      isSyncing: isSyncing,
      rebuildPending: rebuildPending,
      fetchFn: fetchFn,
      wait: wait,
    );
  }

  static Future<void>? _maybeStartAsync({
    bool Function()? isSyncing,
    Future<bool> Function()? rebuildPending,
    Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
    Function(String id)?
    fetchFn,
    bool wait = false,
  }) {
    final future = () async {
      try {
        if (!await needsRun()) {
          // 최적화는 done 이어도 미뤄 둔 보류 요청이 있으면 기동 경로에서 시작한다
          // (서버와 같음 — done=true 기록 직후 끝났어도 유실 없음).
          await runDeferredStarters();
          return;
        }
      } catch (_) {
        // DB 를 열지 못하는 환경에서는 조용히 건너뛴다(다음 실행에 다시 시도).
        // 게이트 통과 흐름을 깨지 않는다 — F18 회귀 방지.
        return;
      }
      _stopRequested = false;
      final d = await LocalDbService.db;
      final countRows = await d.query('reports', columns: ['ID']);
      DbOptimizeState.update(
        state: 'running',
        stage: 'starting',
        total: countRows.length,
        done: 0,
        message: '',
        finishedAt: '',
      );
      final meta = await readMeta() ?? {};
      DbOptimizeState.appendLog(
        'DB 최적화 시작(대상 ${countRows.length}건, 파서 $mobileParserVersion)'
        '${(meta['cursor'] as String?)?.isNotEmpty == true ? ', 커서 ${meta['cursor']}부터 이어서' : ''}',
      );
      try {
        await LocalDbService.runBackgroundWork(
          () => processAll(
            fetchFn: fetchFn,
            isSyncing: isSyncing,
            rebuildPending: rebuildPending,
          ),
        );
      } catch (e) {
        // 로그를 먼저 남기고 상태를 바꾼다 — 표시줄이 error 스냅샷에 로그를 함께 싣게.
        DbOptimizeState.appendLog('오류로 멈춤(${e.runtimeType})');
        DbOptimizeState.update(
          state: 'error',
          stage: 'error',
          message: e.runtimeType.toString(),
        );
        // 작업 예외(error) 뒤 동기화 보류를 풀어 대기 요청을 실행한다(서버 _after_error 와 같음).
        // 최적화는 다음 기회에 다시 시도한다. 표시줄은 error 를 '작업 완료'가 아닌 '오류'로 보인다.
        try {
          await _afterError();
        } catch (_) {}
      } finally {
        _running = null;
      }
    }();
    _running = future;
    if (wait) return future;
    unawaited(future.whenComplete(() {
      if (identical(_running, future)) _running = null;
    }));
    return future;
  }

  /// 앱 종료 때: 다음 신고 경계에서 멈춘다.
  static void requestStop() => _stopRequested = true;
}
