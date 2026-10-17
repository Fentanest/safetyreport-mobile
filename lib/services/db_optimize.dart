// DB 최적화 작업: 상세 원본 기반 재파싱 (2026-10-17 명세 3절·7절, 서버 services/db_optimize.py 와 같은 역할).
//
// 파서 버전이 오르면 Standalone 앱 실행 때 한 번, 신고 ID 순으로 훑는다. 원본 표에 행이 있고
// sha 가 맞으면 네트워크 없이 저장된 원본의 `result` 로 다시 파싱하고, 없으면 상세 API 로 다시 받아
// 원본 표·파일에 저장(`source='backfill'`)한 뒤 파싱한다. 저장은 `LocalDbService.reparseReportWithCapture`
// (파서가 만드는 열만 갱신, 목록 열·사용자 override 유지, 바뀐 신고만 공유 `completed_observation` —
// 공유 캡처 입력의 목록 값·진행 상태·사진 촬영 값은 lease 안에서 읽은 기존 행 스냅샷으로 채움)이다.
//
// 실패 처리(7-1): 영구는 없음·삭제(404·410)만. 401·403·토큰 만료·로그인 화면은 auth 로 본다.
// 신고 하나가 일시 실패하면 시도 횟수를 쌓고 3번째 실패에서 보류 목록(`sync_meta` holds)에 남긴다.
// `done=true` 는 보류가 비었을 때만. 보류만 남으면 `partial`(실행 중 아님)이고 다음 기동·동기화 성공 뒤
// 보류만 다시 시도한다(회차마다 시도 초기화, 회차 사이 지수 백오프 최대 1시간).
// 연속 5건 일시 실패·로그인 문제는 신고별 횟수 없이 작업 전체를 쉰다(`outage`/`login_required`,
// 지수 백오프 밑값 60초·최대 1시간, 크롤/동기화 성공 직후 깨움).
// 새 답변이 온 신고(7-2)는 저장하지 않고 일반 크롤 대기 큐(영속)에 넣어 "새 답변 — 일반 크롤로 넘김" 을 남긴다.
// 신고번호가 없는 행의 새 활동은 대기열에도 넣지 않고 "새 답변 — 다음 일반 크롤에서 처리(신고번호 없음)" 뒤
// 처리 완료로 센다. 저장 직전 재확인에 걸리면(답변일·처리내용·상태 변경) 처리 완료로 세지 않고
// 시도 횟수 증가 없이 보류로 넘긴다. 어떤 경로로 끝나거나 쉬든(완료·partial·outage·login_required·오류)
// 보류한 수동·단건 넘김 큐 요청을 배출한다.
// 쉬는 동안(7-3)은 동기화를 막지 않는다 — 게이트(`blocksSync`)는 실제 처리 중에만 닫힌다.
// 엔진 간 배제(7-4): 처리 중 표시는 `sync_meta` 영속(갱신 시각·만료), 신고 1건 처리는 일반 동기화와
// 같은 영속 lease(`personal_sync`)를 잡고, 저장 직전 트랜잭션 안에서 답변일·처리내용·상태를 재확인한다.
//
// 취소 수단 없음. 앱 종료 뒤에는 메타 커서부터 이어서 한다. 크롤(수동 동기화·알림 동기화)과는
// `blocksSync` 로 순서를 맞춘다(실제로 처리하는 동안의 시작 요청만 대기열 뒤에 붙는다).
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
import 'standalone_pending_queue_store.dart';
import 'sync_operation_admission.dart';

/// 최적화 한 번 훑기 결과(이번 실행분). 서버 process_all 반환과 같은 모양이다.
class OptimizeRunResult {
  const OptimizeRunResult({
    required this.total,
    required this.done,
    required this.finished,
    required this.stats,
    this.rest,
  });

  final int total;
  final int done;
  final bool finished;
  final Map<String, dynamic> stats;

  /// 끝내지 못한 이유. null 이면 완료·정상 종료·외부 중지 중 하나다.
  /// 'outage'(전역 일시 장애 쉼) | 'login_required'(로그인 필요 쉼) | 'partial'(보류만 남음, 실행 중 아님).
  final String? rest;
}

/// 일시 저장 실패 — 신고별 시도 횟수를 남기고 나중에 다시 시도하라는 신호(서버 _SaveTransient 와 같음).
class SaveTransient implements Exception {
  SaveTransient(this.note);
  final String note;
  @override
  String toString() => 'SaveTransient($note)';
}

/// lease 대기 중 중지·DB 닫기 — 라운드를 멈추라는 내부 신호(오류 아님).
class _OptimizeStop implements Exception {}

class DbOptimize {
  DbOptimize._();

  /// 크롤과 같은 요청 간격(서버 0.3s).
  static Duration requestInterval = const Duration(milliseconds: 300);

  /// 일시 오류(envelope 단위) 재시도 횟수. 상세 API 안의 `_getWithRetry`(5회/1초)가
  /// 1차 전송 재시도를 맡고, 여기서는 envelope 단위 실패를 이 횟수만큼 다시 받는다(서버와 같음).
  static int fetchRetryAttempts = 3;

  /// 일시 실패(네트워크·저장 실패·토큰 갱신 중 예외)를 보류 목록으로 넘기기 전 신고별 시도 횟수
  /// (회차마다 초기화, 서버 MAX_RETRY_ATTEMPTS 와 같음). 3번째 실패에서
  /// 그 신고를 보류 목록에 남기고 이번 회차는 건너뛴다(명세 7-1).
  static const int maxRetryAttempts = 3;

  /// 보류 사유(통계 skipped 키, 서버 RETRY_EXCEEDED_REASON 과 같음).
  /// 영구 건너뜀이 아니라 다음 회차 재시도 대상이다.
  static const String retryExceededReason = 'retry_exceeded';

  /// 전역 장애로 쉬기 전 연속 일시 실패 건수(명세 7-1). 이 횟수만큼 연속으로
  /// 일시 실패하면 신고별 시도 횟수를 늘리지 않고(롤백) 작업 전체를 쉰다.
  static int outageThreshold = 5;

  /// 쉼 사이 재시도 간격 밑값(지수 백오프, 최대 [maxRestBackoff] 1시간, 명세 7-1).
  /// 로그인 쉼은 [loginRetryInterval], 전역 장애 쉼은 [outageRetryInterval],
  /// 보류 재시도 회차 사이는 [roundRetryInterval] 을 쓴다. 시험에서 좁힌다.
  static Duration outageRetryInterval = const Duration(seconds: 60);
  static Duration roundRetryInterval = const Duration(seconds: 60);
  static const Duration maxRestBackoff = Duration(hours: 1);

  /// 쉼 중 동기화 성공 wake· 중지 확인 주기.
  static Duration restPollInterval = const Duration(seconds: 1);

  /// 신고 1건 lease 대기 한계·확인 주기(명세 7-4). 다른 엔진이 lease 를 쥐면
  /// 이 한계까지 기다렸다가 일시 실패로 넘기고 다음 신고로 간다.
  static Duration leaseWaitTimeout = const Duration(seconds: 60);
  static Duration leaseWaitPollInterval = const Duration(seconds: 1);

  /// 처리 중 영속 표시(`sync_meta`) 유효 기간(명세 7-4). 매 신고 처리 때 갱신하므로
  /// 이 시간보다 오래된 표시는 죽은 작업으로 보고 무시한다.
  static Duration processingMarkerTtl = const Duration(seconds: 120);

  /// 처리 중 영속 표시 키(`sync_meta`). 값은
  /// `{"updated_at": <epoch ms>, "report_id": "<처리 중 ID>"}`.
  /// 별도 엔진(알림 백그라운드)도 읽는다. 실제로 처리하는 동안만 남긴다.
  static const String processingKey = 'detail_raw_optimize_processing';

  /// 동기화 성공 wake 표시 키(`sync_meta`). 값은 epoch ms 문자열.
  /// 쉼 중 확인하면 백오프를 기다리지 않고 바로 다음 회차로 간다(명세 7-1·7-3).
  static const String wakeKey = 'detail_raw_optimize_wake';

  /// 보류한 수동 동기화 저장 키(`sync_meta`). 하나로 합쳐 실제로 시작될 때까지 남긴다
  /// (서버 DEFERRED_META_KEY 와 같은 자리 — 값은 합쳐진 1건의 요청 JSON).
  static const String deferredManualKey = 'detail_raw_optimize_deferred';

  /// 보류한 알림 drain 표시 키(`sync_meta`). 알림 대기열 자체는 기존 영속 큐가 맡고,
  /// 여기에는 "최적화 뒤 drain 1회" 표시만 남긴다.
  static const String deferredDrainKey = 'detail_raw_optimize_deferred_drain';

  /// 마지막 최적화 오류 스냅샷 키(`sync_meta`). 새 프로세스에서도 표시줄에 오류를
  /// 보이기 위해 `{at, message, log(최근 20줄)}` 를 남긴다. 재시도 시작·완료 때 지운다.
  static const String lastErrorKey = 'detail_raw_optimize_last_error';

  /// 테스트 주입점. null 이면 실제 `LocalDbService.deleteMeta` 를 쓴다.
  /// 보류 삭제 실패(진단 기록 분기)를 실제 경로로 재현할 때 쓴다.
  @visibleForTesting
  static Future<void> Function(String key)? deleteMetaForTest;

  /// 크롤 실행 중·초기화 대기 때 다음 확인까지 쉬는 시간.
  static Duration waitInterval = const Duration(seconds: 5);

  /// 로그인 필요 때 다음 확인까지 쉬는 시간 — 7-1 에서는 로그인 쉼(`login_required`)
  /// 재시도 간격의 밑값으로 쓴다(지수 백오프, 최대 1시간). 신고당 긴 대기는 두지 않는다.
  static Duration loginRetryInterval = const Duration(seconds: 60);

  /// 실제로 신고를 처리하는 동안만 true 인 동기화 게이트(명세 7-3).
  /// `login_required`·`outage`·`partial`·대기 상태에서는 false — 수동·알림 동기화를
  /// 바로 실행하고, 동기화 성공 뒤 최적화를 재판단한다.
  static bool get blocksSync =>
      DbOptimizeState.state == 'running' &&
      DbOptimizeState.stage == 'running';

  /// 별도 엔진(알림 백그라운드)이 보는 처리 중 영속 표시가 살아 있으면 true.
  static Future<bool> isProcessingPersisted() async {
    try {
      final raw = await LocalDbService.getMeta(processingKey);
      if (raw == null || raw.isEmpty) return false;
      final data = jsonDecode(raw);
      if (data is! Map) return false;
      final at = int.tryParse('${data['updated_at'] ?? ''}');
      if (at == null) return false;
      return DateTime.now().millisecondsSinceEpoch - at <
          processingMarkerTtl.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// 처리 중 영속 표시를 갱신한다(매 신고 처리 때). 실패하면 무시한다.
  static Future<void> touchProcessingMarker(String reportId) async {
    try {
      await LocalDbService.setMeta(
        processingKey,
        jsonEncode({
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'report_id': reportId,
        }),
      );
    } catch (_) {}
  }

  /// 처리 중 영속 표시를 지운다(쉼·완료·중지 때). 실패하면 무시한다(만료로 사라짐).
  static Future<void> clearProcessingMarker() async {
    try {
      await LocalDbService.deleteMeta(processingKey);
    } catch (_) {}
  }

  static bool get isRunning => DbOptimizeState.isRunning;

  static Future<void>? _running;
  static bool _stopRequested = false;

  /// 동기화 종료 훅 재진입 방지. 보류 재시도 starter 가 다시 동기화를 일으키고 그
  /// 종료 훅이 또 보류를 보려 하면(무한 재귀) 그냥 둔다 — 바깥 훅이 이미 처리 중이다.
  static bool _notifyingSyncFinished = false;

  /// 보류 실행 재진입 방지. `_afterFinish`·`_afterError`·종료 훅이 직접 부른 바깥 실행이
  /// 끝나기 전, starter 가 일으킨 동기화·drain 의 종료 훅이 또 실행을 부르면(보류가 아직
  /// 지워지지 않아 중복 시작됨) 그냥 둔다 — 바깥 실행이 지우기까지 맡는다.

  static bool _dispatchingDeferred = false;

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
    _notifyingSyncFinished = false;
    _dispatchingDeferred = false;
    _syncSuccessWake = false;
    _restArmed = false;
    _lastIsSyncing = null;
    _lastRebuildPending = null;
    openStoreForTest = null;
    fetchDetailForTest = null;
    captureForTest = null;
    deleteMetaForTest = null;
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
    outageThreshold = 5;
    outageRetryInterval = const Duration(seconds: 60);
    roundRetryInterval = const Duration(seconds: 60);
    restPollInterval = const Duration(seconds: 1);
    leaseWaitTimeout = const Duration(seconds: 60);
    leaseWaitPollInterval = const Duration(seconds: 1);
    processingMarkerTtl = const Duration(seconds: 120);
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
  /// target 비교는 [sameTarget] 세대 비교다 — 서버(`pc-parser-13`) 메타를 가져와도
  /// 같은 세대면 처음부터 훑지 않고 보류만 이어서 처리한다.
  static Future<bool> needsRun() async {
    final meta = await readMeta();
    if (meta == null) return true;
    if (!sameTarget(meta['target'], mobileParserVersion)) return true;
    return meta['done'] != true;
  }

  /// target 세대 정규화. 서버·모바일 접두사(`pc-`·`mobile-`)만 떼고 비교한다 —
  /// 한쪽에서 만든 partial 메타를 다른 쪽이 가져오면 holds 만 이어서 처리한다
  /// (같은 target 세대일 때, 서버와 같은 규칙).
  static String canonicalTarget(Object? target) =>
      '$target'.replaceFirst(RegExp(r'^(pc|mobile)-'), '');

  /// 같은 target 세대면 true.
  static bool sameTarget(Object? a, Object? b) =>
      canonicalTarget(a) == canonicalTarget(b);

  /// `next_retry_at` 읽기 — UTC ISO8601 문자열(정본, 서버와 같은 형식).
  /// 고치기 전 서버가 쓰던 epoch 초 숫자(문자열 숫자 포함)도 다음 재시도 시각으로
  /// 받아 하위호환한다. 없거나 0 이하면 null.
  static DateTime? parseNextRetryAt(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final seconds = value.toDouble();
      if (seconds <= 0) return null;
      final ms = seconds < 1e12 ? (seconds * 1000).round() : seconds.round();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    final text = '$value'.trim();
    if (text.isEmpty) return null;
    final asNumber = double.tryParse(text);
    if (asNumber != null) return parseNextRetryAt(asNumber);
    try {
      return DateTime.parse(text).toUtc();
    } catch (_) {
      return null;
    }
  }

  /// `next_retry_at` 쓰기 — UTC ISO8601 문자열(서버와 같은 형식). 없으면 키를 생략한다.
  static String formatNextRetryAt(DateTime moment) =>
      moment.toUtc().toIso8601String();

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
  /// `HTTP ` 접두사 없이 숫자 코드를 본다. 401·403·419·토큰 만료·로그인 화면 응답은
  /// 로그인 문제(auth)다(명세 7-1). 영구는 그 신고가 없음·삭제됨이 분명한 응답
  /// (404·410)만이다. 나머지는 일시 실패다.
  @visibleForTesting
  static String classifyFetchError(Object error) {
    if (error is TokenExpiredException) return 'auth';
    final text = error.toString();
    final lower = text.toLowerCase();
    if (RegExp(r'\b40[13]\b|\b419\b').hasMatch(text) ||
        lower.contains('unauthorized') ||
        lower.contains('login') ||
        text.contains('로그인')) {
      return 'auth';
    }
    if (RegExp(r'\b404\b|\b410\b').hasMatch(text)) {
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
  /// 호출자가 사유를 집계한다). [ReparseConflict] 는 그대로 던진다(다른 엔진이 그사이
  /// 저장함 — 덮지 않고 다음 회차로 넘기며 시도 횟수는 늘리지 않는다, 명세 7-4).
  /// 일시 실패(저장소 없음·캡처·저장 예외·lease 대기 초과)는 [SaveTransient] 로
  /// 던진다(시도 횟수 누적·재시도). [CaptureStoreUnavailable] 은 그대로 던진다
  /// (작업 전체를 멈춘다, 서버와 같음). 반환: 바뀐 신고면 true.
  ///
  /// 신고 1건 처리는 일반 동기화와 같은 영속 lease(`personal_sync`)를 잡고 한다
  /// (명세 7-4). 다른 엔진이 lease 를 쥐면 [leaseWaitTimeout] 까지 기다렸다가
  /// 일시 실패로 넘긴다. 캡처(커뮤니티 쓰기)는 개인 DB 트랜잭션 밖에서 먼저 하고
  /// 개인 DB 쓰기는 뒤 트랜잭션에서 한다 — 일반 저장과 같은 잠금 순서다.
  /// [preRead] 는 lease 전에 읽은 기준 행(없으면 여기서 읽는다). lease 안에서 다시
  /// 읽은 행의 답변일·처리내용·상태가 기준과 다르면 저장하지 않는다.
  ///
  /// 공유 캡처 입력의 목록 값(상태·신고번호·신고명·신고일·만족도조사여부·별점·별점사유 —
  /// 일반 동기화가 목록·만족도에서 채우는 열 전부)과 진행 상태·사진 촬영 값은
  /// lease 안에서 읽은 기존 행 스냅샷으로 채운다(서버 REPARSE_CAPTURE_TITLE_COLUMNS 와 같은 규칙).
  /// DB 목록 열은 갱신하지 않는다.
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
    Map<String, Object?>? preRead,
  }) async {
    final capture = captureFn ?? captureForTest;
    CommunityStore? store;
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
    final leaseStore = store;
    final base = preRead != null
        ? Map<String, Object?>.from(preRead)
        : await LocalDbService.readReparseBase(report.id);
    if (base == null) {
      DbOptimizeState.appendLog('${report.id} 건너뜀(no_report)');
      throw ReparseSkipped('no_report');
    }
    CaptureResult? cap;
    var changed = false;
    // 공유는 확정됐는데 개인 DB 쓰기가 아직인 이벤트. 뒤 UPDATE·원본 저장이 실패해
    // 롤백되면 이 이벤트의 personal_save_state 를 failed 로 표시한다(서버·일반 동기화와 같음).
    CaptureResult? capturedBeforePersonalSave;
    try {
      final leaseDeadline = DateTime.now().add(leaseWaitTimeout);
      while (true) {
        if (_stopRequested || LocalDbService.closeRequested) {
          throw _OptimizeStop();
        }
        final outcome = await SyncOperationAdmission.run(
          () async {
            // lease 안에서: 재확인 → 캡처(커뮤니티 쓰기) → 개인 DB 저장(트랜잭션).
            final now = await LocalDbService.readReparseBase(report.id);
            if (now == null) throw ReparseSkipped('no_report');
            for (final key in const ['답변일', '처리내용', '상태']) {
              if ('${now[key] ?? ''}' != '${base[key] ?? ''}') {
                throw ReparseConflict('row_changed:$key');
              }
            }
            final saved = await LocalDbService.reparseReportWithCapture(
              report,
              category,
              entryValue,
              rawContent: rawContent,
              ssnpcCd: report.ssnpcCd,
              ssnpcType: report.ssnpcType,
              rawDetail: rawDetail,
              baseRow: now,
              capture: (captureReport, photoFirst, photoLast) async {
                final adapterInput = buildReportAdapterInput(
                  captureReport,
                  entryValue,
                  category: category,
                  photoFirstCapture: photoFirst,
                  photoLastCapture: photoLast,
                );
                CaptureResult? inner;
                if (capture != null) {
                  inner = await capture(adapterInput, report.id);
                } else {
                  final ns =
                      projectNamespace ?? namespaceForTest ?? _projectNamespace();
                  inner = await captureReal(
                    adapterInput,
                    report.id,
                    store: leaseStore,
                    projectNamespace: ns,
                  );
                }
                capturedBeforePersonalSave = inner;
                return inner;
              },
            );
            changed = saved.changed;
            cap = saved.cap;
            return (ran: true, changed: changed);
          },
          (ran: false, changed: false),
          openStore: () async => leaseStore,
          stopRequested: () =>
              _stopRequested || LocalDbService.closeRequested,
        );
        if (outcome.ran) break;
        if (!DateTime.now().isBefore(leaseDeadline)) {
          DbOptimizeState.appendLog(
            '${report.id} 저장 대기(다른 엔진이 처리 중, 다음에 다시 시도합니다)',
          );
          throw SaveTransient('lease_busy');
        }
        final poll = leaseWaitPollInterval;
        if (poll > Duration.zero) {
          await Future<void>.delayed(poll);
        }
      }
    } on ReparseSkipped catch (e) {
      final reason = e.reason.isEmpty ? 'skipped' : e.reason;
      DbOptimizeState.appendLog('${report.id} 건너뜀($reason)');
      rethrow;
    } on ReparseConflict {
      rethrow;
    } on CaptureStoreUnavailable {
      rethrow;
    } on _OptimizeStop {
      rethrow;
    } catch (e) {
      DbOptimizeState.appendLog('${report.id} 저장 실패(${e.runtimeType})');
      try {
        await markPersonalSave(
          capturedBeforePersonalSave?.eventId,
          false,
          store: store,
        );
      } catch (_) {}
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
  /// 서버 process_all 과 같은 규칙: target 세대가 바뀌면 커서·통계·시도 횟수를 버리고 처음부터,
  /// 영구 실패(없음·삭제)·파싱 불가만 건너뛰고 일시 실패는 신고별 attempts 에 누적해 3번째 실패에서
  /// 보류(`holds`)로 넘기며, done=true 는 보류가 비었을 때만 기록한다. 보류만 남고 한 바퀴를
  /// 끝내면 `partial`(실행 중 아님, round+1·다음 재시도 시각 기록)로 쉬고, 다음 실행에는
  /// 보류만 다시 시도한다(서버와 같은 키·같은 모양).
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
    bool Function()? isStopped,
  }) async {
    final gap = interval ?? requestInterval;
    final d = await LocalDbService.db;
    final idRows = await d.query('reports', columns: ['ID'], orderBy: 'ID');
    final ids = [for (final r in idRows) '${r['ID']}'];
    final total = ids.length;
    final meta = await readMeta() ?? {};
    // target 세대(서버·모바일 접두사 무시)가 다르면 커서·통계·보류를 버리고 처음부터.
    final bool targetChanged = !sameTarget(meta['target'], mobileParserVersion);
    final String cursor = targetChanged ? '' : '${meta['cursor'] ?? ''}';
    // 보류 목록(다음 회차에 다시 시도할 신고, 명세 7-1, 서버와 같은 키 `holds`).
    // 고치기 전 모바일이 쓰던 `pending` 키도 읽는다. 복원된 DB 에 없는 ID 는 버린다.
    final holds = <String>{};
    if (!targetChanged) {
      for (final raw in [meta['holds'], meta['pending']]) {
        if (raw is List) {
          for (final e in raw) {
            final id = '$e';
            if (ids.contains(id)) holds.add(id);
          }
        }
      }
    }
    final Map<String, dynamic> stats;
    // round 는 0에서 시작해 보류로 한 바퀴를 끝낼 때마다 +1(서버와 같음).
    final int round;
    if (targetChanged) {
      stats = {};
      round = 0;
    } else {
      stats = Map<String, dynamic>.from(meta['stats'] as Map? ?? {});
      final rawRound = meta['round'];
      round = rawRound is int
          ? rawRound
          : int.tryParse('$rawRound') ?? 0;
    }
    // 시도 횟수는 회차마다 초기화한다(명세 7-1). 커서가 남은 채 중단된 같은 회차를
    // 이어서 할 때만 메타의 시도 횟수를 살린다(보류만 남은 partial 다음 회차는 초기화).
    final attempts = <String, int>{};
    // 보류만 남은 채 끝난 회차 다음에는 보류 목록만 다시 시도한다(서버와 같음).
    final bool holdsOnly =
        !targetChanged && cursor.isEmpty && holds.isNotEmpty;
    if (!targetChanged && cursor.isNotEmpty) {
      final rawAttempts = meta['attempts'];
      if (rawAttempts is Map) {
        for (final entry in rawAttempts.entries) {
          final count = int.tryParse('${entry.value}') ?? 0;
          if (count > 0) attempts['${entry.key}'] = count;
        }
      }
    }
    // 이번 회차에 새로 보류로 넘긴 신고(전역 장애 롤백 때만 뺀다).
    final newlyPending = <String>{};
    stats['reused'] ??= 0;
    stats['refetched'] ??= 0;
    stats['changed'] ??= 0;
    stats['events'] ??= 0;
    stats['forwarded'] ??= 0;
    stats['skipped'] ??= <String, dynamic>{};
    final run = <String, dynamic>{
      'reused': 0,
      'refetched': 0,
      'changed': 0,
      'events': 0,
      'forwarded': 0,
      'skipped': <String, dynamic>{},
    };
    // 시작 때 DB 정체(개인 DB 경로·커뮤니티 데이터셋)를 잡는다.
    final startIdentity = await _captureIdentity();

    void tally({
      bool reused = false,
      bool refetched = false,
      bool changed = false,
      bool event = false,
      bool forwarded = false,
      String? skipped,
    }) {
      for (final target in [stats, run]) {
        if (reused) target['reused'] = (target['reused'] as int? ?? 0) + 1;
        if (refetched) target['refetched'] = (target['refetched'] as int? ?? 0) + 1;
        if (changed) target['changed'] = (target['changed'] as int? ?? 0) + 1;
        if (event) target['events'] = (target['events'] as int? ?? 0) + 1;
        if (forwarded) {
          target['forwarded'] = (target['forwarded'] as int? ?? 0) + 1;
        }
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
        // 3번째 실패에서 보류 목록에 남기고 이번 회차는 건너뛴다(명세 7-1, 서버와 같음).
        // 이미 보류 목록에 있으면(이전 회차분) 그대로 둔다.
        if (holds.add(reportId)) {
          newlyPending.add(reportId);
          tally(skipped: retryExceededReason);
        }
        DbOptimizeState.appendLog(
          '$reportId 보류(일시 실패 계속, 다음 회차에 다시 시도합니다'
          '${note.isEmpty ? '' : ': $note'})',
        );
      } else {
        DbOptimizeState.appendLog(
          '$reportId 일시 실패($note), 나중에 다시 시도합니다($count/$maxRetryAttempts)',
        );
      }
    }

    void recordResolved(String reportId) {
      attempts.remove(reportId);
      holds.remove(reportId);
      newlyPending.remove(reportId);
    }

    /// 다른 엔진이 그사이 저장해 덮지 않고 다음 회차로 넘긴다(시도 횟수 증가 없음, 명세 7-4).
    /// 처리 완료로 세지 않는다 — 보류에 남겨 다음 회차에 다시 시도한다.
    void carryNext(String reportId, String note) {
      holds.add(reportId);
      DbOptimizeState.appendLog(
        '$reportId 다음 회차에 다시 시도합니다($note)',
      );
    }

    Future<void> writeProgress(String cursorId) => writeMeta({
      'target': mobileParserVersion,
      'cursor': cursorId,
      'done': false,
      'total': total,
      'stats': stats,
      'attempts': attempts,
      'holds': holds.toList()..sort(),
      'round': round,
    });

    /// null | 'stop'(중지 요청) | 'restore'(DB 교체 — 옛 커서를 새 DB 에 쓰지 않고 멈춤).
    Future<String?> stopReason() async {
      if ((isStopped ?? () => _stopRequested)()) return 'stop';
      if (LocalDbService.closeRequested) return 'restore';
      if (await _identityChanged(startIdentity)) return 'restore';
      return null;
    }

    /// 한 신고를 한 번 시도한다. 반환: 'resolved'(성공·영구 건너뜀·새 답변 넘김) |
    /// 'deferred'(일시 실패, 시도 횟수 누적) | 'carried'(다른 엔진이 먼저 저장 —
    /// 시도 횟수 없이 다음 회차) | 'auth'(로그인 문제 — 작업 전체를 쉰다).
    /// [CaptureStoreUnavailable]·[_OptimizeStop] 은 그대로 던진다.
    Future<String> attemptReport(String reportId) async {
      // 기준 행(목록 상태·답변일·처리내용·신고번호) — 새 활동 판정·대기 큐 등록용.
      final base = await LocalDbService.readReparseBase(reportId);
      if (base == null) {
        tally(skipped: 'no_report');
        DbOptimizeState.appendLog('$reportId 건너뜀(no_report)');
        recordResolved(reportId);
        return 'resolved';
      }
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
            preRead: base,
          );
          // 저장 실패·영구 건너뜀·재확인 불일치는 예외로 나가므로 여기 오면 저장 시도 성공이다.
          tally(reused: true);
          if (changed) tally(changed: true);
          if ((eventTallies['events'] ?? 0) > 0) tally(event: true);
        } on ReparseSkipped catch (e) {
          final reason = e.reason.isEmpty ? 'skipped' : e.reason;
          tally(skipped: reason);
          recordResolved(reportId);
          return 'resolved';
        } on ReparseConflict catch (e) {
          carryNext(reportId, e.reason);
          return 'carried';
        } on CaptureStoreUnavailable {
          rethrow;
        } on _OptimizeStop {
          rethrow;
        } on SaveTransient catch (e) {
          recordTransient(reportId, '저장 실패(${e.note})');
          return 'deferred';
        }
        recordResolved(reportId);
        await ensureRawFile(reportId, envelope);
        return 'resolved';
      }
      // 원본 없음·손상 → 다시 받기(네트워크).
      final fetched = await fetchEnvelope(
        reportId,
        fetchFn: fetchFn,
        interval: gap,
      );
      // 실패해도 요청 간격은 지킨다(명세 7-1).
      if (gap > Duration.zero) {
        await Future<void>.delayed(gap);
      }
      if (fetched.outcome == 'auth') {
        // 로그인 문제면 신고별 시도 횟수를 늘리지 않고 작업 전체를 쉰다(명세 7-1).
        // 신고당 긴 대기는 두지 않는다.
        _restArmed = true;
        DbOptimizeState.update(
          state: 'paused',
          stage: 'login_required',
          message: '로그인 뒤 이어서 합니다',
        );
        DbOptimizeState.appendLog(
          '로그인 필요 — 쉽니다(신고별 시도 없이 다음 회차·동기화 성공 뒤 이어서 시도합니다'
          '${fetched.note.isEmpty ? '' : ': ${fetched.note}'})',
        );
        return 'auth';
      }
      if (fetched.outcome == 'permanent') {
        tally(skipped: 'not_found');
        DbOptimizeState.appendLog(
          '$reportId 건너뜀(not_found${fetched.note.isEmpty ? '' : ': ${fetched.note}'})',
        );
        recordResolved(reportId);
        return 'resolved';
      }
      if (fetched.outcome == 'retryable') {
        recordTransient(reportId, fetched.note.isEmpty ? 'fetch_failed' : fetched.note);
        return 'deferred';
      }
      if (fetched.outcome != 'ok' || fetched.envelope == null) {
        recordTransient(
          reportId,
          fetched.note.isEmpty ? fetched.outcome : fetched.note,
        );
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
      // 새 답변이 온 신고는 저장하지 않고 일반 크롤 대기 큐(영속)에 넘긴다(명세 7-2).
      // 저장된 원본으로 재파싱하는 경로(네트워크 없음)는 해당하지 않는다.
      if (hasReparseNewActivity(
        storedStatus: '${base['상태'] ?? ''}',
        storedAnswerDate: base['답변일'],
        detailCNow: result['C_NOW'],
        parsedAnswerDate: report.responseDate,
      )) {
        final number = '${base['신고번호'] ?? ''}';
        if (number.isEmpty) {
          // 신고번호 없는 행의 새 활동은 저장하지 않고(원본·파서 열·파일)
          // 대기열에도 넣지 않는다. 다음 일반 크롤에서 처리하도록 두고
          // 처리 완료로 센다(명세 P5).
          DbOptimizeState.appendLog('$reportId 새 답변 — 다음 일반 크롤에서 처리(신고번호 없음)');
          recordResolved(reportId);
          return 'resolved';
        }
        try {
          await StandalonePendingQueueStore.append([number]);
        } catch (e) {
          recordTransient(reportId, '대기 큐 등록 실패($e)');
          return 'deferred';
        }
        await markDrainDeferred();
        tally(forwarded: true);
        DbOptimizeState.appendLog('$reportId 새 답변 — 일반 크롤로 넘김');
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
          preRead: base,
        );
        // 저장 실패·영구 건너뜀·재확인 불일치는 예외로 나가므로 여기 오면 저장 시도 성공이다.
        tally(refetched: true);
        if (changed) tally(changed: true);
        if ((eventTallies['events'] ?? 0) > 0) tally(event: true);
      } on ReparseSkipped catch (e) {
        final reason = e.reason.isEmpty ? 'skipped' : e.reason;
        tally(skipped: reason);
        recordResolved(reportId);
        return 'resolved';
      } on ReparseConflict catch (e) {
        carryNext(reportId, e.reason);
        return 'carried';
      } on CaptureStoreUnavailable {
        rethrow;
      } on _OptimizeStop {
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

    // 작업 목록: 보류만 남은 회차 다음에는 보류만 다시 시도하고(명세 7-1),
    // 쉼으로 중간에 끊겼으면 커서 꼬리와 보류 합집합을 이어서 한다(ID 순).
    final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    var startIndex = 0;
    if (cursor.isNotEmpty) {
      final at = ids.indexOf(cursor);
      startIndex = at >= 0 ? at + 1 : 0;
    }
    final List<String> sweep;
    {
      if (holdsOnly) {
        sweep = holds.where(order.containsKey).toList()
          ..sort((a, b) => order[a]!.compareTo(order[b]!));
      } else {
        final tail = ids.sublist(startIndex);
        final workSet = <String>{...tail};
        for (final id in holds) {
          if (order.containsKey(id)) workSet.add(id);
        }
        sweep = workSet.toList()
          ..sort((a, b) => order[a]!.compareTo(order[b]!));
      }
    }
    var doneCount = holdsOnly ? 0 : startIndex;
    var lastCursor = cursor;
    DbOptimizeState.update(
      total: total,
      done: doneCount,
      state: 'running',
      stage: 'running',
      message: '',
    );

    // 같은 회차 재시도분(시도 1~2회). 보류로 넘어간 신고·다음 회차분은 제외한다.
    bool retryable(String id) {
      final c = attempts[id] ?? 0;
      return c >= 1 && c < maxRetryAttempts;
    }

    final pendingRetry = <String>[];
    // 연속 일시 실패 추적(전역 장애 판정용, 명세 7-1).
    var consecutiveTransient = 0;
    final streak = <String>[];

    /// 성공·다음 회차분은 연속 실패를 끊는다(다음 회차분은 다른 엔진의 저장이라 실패가 아니다).
    void breakStreak() {
      consecutiveTransient = 0;
      streak.clear();
    }

    /// 일시 실패 1건을 센다. 전역 장애(연속 [outageThreshold] 건)가 되면 true —
    /// 이 연속 실패들의 신고별 시도 횟수는 롤백한다(늘리지 않음, 명세 7-1).
    /// 롤백된 신고 ID 목록(`streak`)은 그대로 두고 [abortRest] 가 보류에 넣는다.
    bool noteDeferredTurn(String reportId) {
      consecutiveTransient++;
      streak.add(reportId);
      if (consecutiveTransient < outageThreshold) return false;
      for (final id in streak) {
        final c = (attempts[id] ?? 1) - 1;
        if (c <= 0) {
          attempts.remove(id);
        } else {
          attempts[id] = c;
        }
        if (newlyPending.remove(id)) holds.remove(id);
      }
      return true;
    }

    /// 쉼으로 끝낸다. 훑다 만 신고(재시도분·시도분)에 `tail`(아직 손대지 않은
    /// 꼬리 — 호출자가 넘긴다)을 더해 모두 보류에 넣고 다음 회차에 다시 시도한다.
    /// 전역 장애로 롤백된 연속 실패분도 시도 횟수 없이 보류에 넣어 빠뜨리지 않는다.
    /// 메타·표시를 남기고 `rest` 로 돌아간다.
    ///
    /// `partial`(한 바퀴 끝·보류만 남음)이든 `outage`·`login_required`(같은 회차를
    /// 이어서 함)든 메타 모양은 같다(서버 `_park_partial` 과 같은 자리): 커서를
    /// 비우고 시도 횟수를 버린 뒤 round+1·다음 재시도 시각(UTC ISO8601)을 기록해
    /// 다음 실행이 보류만 다시 시도한다. 상태·백오프 밑값만 rest 종류대로 둔다.
    /// 어떤 경로로 쉬든 보류한 수동·단건 넘김 큐 요청을 배출한다(명세 P4) —
    /// 상태를 먼저 바꿔 게이트를 연 뒤 배출한다.
    String retryText(DateTime retryAt) {
      final local = retryAt.toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      return '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)}';
    }

    Future<OptimizeRunResult> abortRest(
      String rest,
      String stage,
      String message,
      String log, {
      String? currentId,
      Iterable<String> tail = const [],
    }) async {
      _restArmed = true;
      holds.addAll(pendingRetry);
      holds.addAll(attempts.keys);
      if (currentId != null) holds.add(currentId);
      if (rest == 'outage') holds.addAll(streak);
      holds.addAll(tail);
      streak.clear();
      consecutiveTransient = 0;
      final sortedHolds = holds.toList()..sort();
      final newRound = round + 1;
      // 다음 재시도 시각 힌트: partial 은 새 바퀴 번호로, outage·login 은 첫 백오프로.
      final delay = rest == 'partial'
          ? restBackoff('partial', newRound)
          : restBackoff(rest, 1);
      final retryAt = DateTime.now().toUtc().add(delay);
      await writeMeta({
        'target': mobileParserVersion,
        'cursor': '',
        'done': false,
        'total': total,
        'stats': stats,
        'attempts': <String, int>{},
        'holds': sortedHolds,
        'round': newRound,
        'next_retry_at': formatNextRetryAt(retryAt),
      });
      await clearProcessingMarker();
      if (rest == 'partial') {
        // 보류만 남음(실행 중 아님) — 표시줄은 보류 건수와 다음 재시도 시각만 조용히 보인다.
        final text = retryText(retryAt);
        DbOptimizeState.update(
          state: 'partial',
          stage: stage,
          message: '보류 ${sortedHolds.length}건, 다음 재시도 $text',
        );
        DbOptimizeState.appendLog(
          '보류 ${sortedHolds.length}건 남음 — 다음 실행·동기화 성공 뒤 보류만 다시 시도합니다(다음 재시도 $text)',
        );
      } else {
        DbOptimizeState.update(
          state: 'paused',
          stage: stage,
          message: message,
        );
        DbOptimizeState.appendLog(log);
      }
      await runDeferredStarters();
      return OptimizeRunResult(
        total: total,
        done: doneCount,
        finished: false,
        stats: run,
        rest: rest,
      );
    }

    try {
      String? stoppedReason; // null | 'stop' | 'restore'
      String? restAbort; // null | 'outage' | 'login_required'
      var index = 0;
      while (index < sweep.length) {
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
        final reportId = sweep[index];
        await touchProcessingMarker(reportId);
        final String outcome;
        try {
          outcome = await attemptReport(reportId);
        } on CaptureStoreUnavailable {
          rethrow;
        } on _OptimizeStop {
          stoppedReason = 'stop';
          break;
        }
        if (outcome == 'auth') {
          restAbort = 'login_required';
          return await abortRest(
            'login_required',
            'login_required',
            '로그인 뒤 이어서 합니다',
            '로그인 필요 — 쉽니다(신고별 시도 없이 다음 회차·동기화 성공 뒤 이어서 시도합니다)',
            currentId: reportId,
            tail: sweep.sublist(index + 1),
          );
        }
        if (outcome == 'deferred') {
          if (noteDeferredTurn(reportId)) {
            restAbort = 'outage';
            return await abortRest(
              'outage',
              'outage',
              '일시 장애 — 잠시 뒤 다시 시도합니다',
              '일시 장애가 계속돼 쉽니다(신고별 시도 횟수 없이 다음 회차·동기화 성공 뒤 다시 시도합니다)',
              tail: sweep.sublist(index),
            );
          }
          if (retryable(reportId) && !pendingRetry.contains(reportId)) {
            pendingRetry.add(reportId);
          }
        } else {
          breakStreak();
        }
        // 매 신고 처리 때 DB 정체 확인 — 복원이 끼면 옛 커서를 복원 DB 에 쓰지 않고 멈춘다.
        stoppedReason = await stopReason();
        if (stoppedReason != null) break;

        index += 1;
        doneCount += 1;
        lastCursor = reportId;
        DbOptimizeState.update(done: doneCount);
        if (await stopReason() == null) {
          await writeProgress(lastCursor);
        }
      }

      // 이번 회차 끝 재시도: 일시 실패분 중 아직 3회 미만인 것만 같은 회차에서 다시 시도한다.
      while (stoppedReason == null && restAbort == null && pendingRetry.isNotEmpty) {
        final current = [
          for (final id in pendingRetry)
            if (retryable(id)) id,
        ];
        if (current.isEmpty) break;
        pendingRetry.clear();
        for (var i = 0; i < current.length; i++) {
          final reportId = current[i];
          stoppedReason = await stopReason();
          if (stoppedReason != null) {
            pendingRetry.addAll(current.sublist(i).where(retryable));
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
          await touchProcessingMarker(reportId);
          final String outcome;
          try {
            outcome = await attemptReport(reportId);
          } on CaptureStoreUnavailable {
            rethrow;
          } on _OptimizeStop {
            stoppedReason = 'stop';
            pendingRetry.addAll(current.sublist(i).where(retryable));
            break;
          }
          if (outcome == 'auth') {
            restAbort = 'login_required';
            pendingRetry.addAll(current.sublist(i + 1).where(retryable));
            return await abortRest(
              'login_required',
              'login_required',
              '로그인 뒤 이어서 합니다',
              '로그인 필요 — 쉽니다(신고별 시도 없이 다음 회차·동기화 성공 뒤 이어서 시도합니다)',
              currentId: reportId,
              tail: current.sublist(i + 1),
            );
          }
          if (outcome == 'deferred') {
            if (noteDeferredTurn(reportId)) {
              restAbort = 'outage';
              pendingRetry.addAll(current.sublist(i + 1).where(retryable));
              return await abortRest(
                'outage',
                'outage',
                '일시 장애 — 잠시 뒤 다시 시도합니다',
                '일시 장애가 계속돼 쉽니다(신고별 시도 횟수 없이 다음 회차·동기화 성공 뒤 다시 시도합니다)',
                tail: current.sublist(i + 1),
              );
            }
            if (retryable(reportId) && !pendingRetry.contains(reportId)) {
              pendingRetry.add(reportId);
            }
          } else {
            breakStreak();
          }
          stoppedReason = await stopReason();
          if (stoppedReason != null) {
            pendingRetry.addAll(current.sublist(i + 1).where(retryable));
            break;
          }
          if (await stopReason() == null) {
            await writeProgress(lastCursor);
          }
        }
      }

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
        // closeDb 로 멈춰도 상태를 정리한다 — blocksSync 이 남으면 동기화가 무한 보류된다.
        // 훑다 만 신고는 보류에 넣어(쓸 수 있으면) 다음에 이어서 한다.
        holds.addAll(pendingRetry);
        holds.addAll(attempts.keys);
        try {
          await writeProgress(lastCursor);
        } catch (_) {}
        DbOptimizeState.appendLog('중단됨 — 다음 실행 때 이어서 합니다');
        DbOptimizeState.update(state: 'idle', stage: '', message: '중단됨');
        return OptimizeRunResult(
          total: total,
          done: doneCount,
          finished: false,
          stats: run,
        );
      }
      if (holds.isEmpty) {
        await writeMeta({
          'target': mobileParserVersion,
          'cursor': ids.isEmpty ? '' : ids.last,
          'done': true,
          'total': total,
          'stats': stats,
          'attempts': <String, int>{},
          'holds': <String>[],
          // 한 바퀴를 끝낼 때마다 round +1 — 서버 db_optimize 완료 메타와 같은 모양(Opus P1).
          'round': round + 1,
        });
        await clearLastError();
        _restArmed = false;
        final changed = stats['changed'] as int? ?? 0;
        final events = stats['events'] as int? ?? 0;
        final forwarded = stats['forwarded'] as int? ?? 0;
        final skippedTotal = (stats['skipped'] as Map? ?? {}).values.fold<int>(
          0,
          (a, e) => a + ((e as num?)?.toInt() ?? 0),
        );
        DbOptimizeState.appendLog(
          '완료(재파싱 변경 $changed건, 공유 재전송 $events건'
          '${forwarded > 0 ? ', 일반 크롤로 넘김 $forwarded건' : ''}'
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
        return OptimizeRunResult(
          total: total,
          done: doneCount,
          finished: true,
          stats: run,
        );
      }
      // 보류 목록만 남으면 partial(실행 중 아님) — 다음 기동·동기화 성공 뒤 보류만 다시 시도한다.
      return await abortRest('partial', 'partial', '', '');
    } finally {
      await clearProcessingMarker();
    }
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

  /// 보류 요청 시작(수동 1건 합침 + drain 1회). 실제로 시작된 뒤에만 보류를 지운다
  /// (유실 금지, 서버와 같은 규칙 — started 표시는 쓰지 않는다).
  /// 지우기 실패는 진단 기록만 남긴다. 드물게 다음 훅·실행에서 한 번 더 시작될 수 있으나
  /// 요청 유실보다 낫다. 시작 실패·busy·거절·취소면 보류는 그대로 남아 다음에 시작한다.
  static Future<void> runDeferredStarters() async {
    // 재진입이면 그냥 둔다. 바깥 실행이 starter 완료 뒤 보류 지우기까지 맡는다.
    // (_afterFinish·_afterError 직접 호출 + starter 가 일으킨 동기화·drain 종료 훅의
    // 중첩 호출이 같은 보류를 두 번 시작하지 않게 — 유실이 아닌 중복 방지가 목적.)
    if (_dispatchingDeferred) return;
    _dispatchingDeferred = true;
    try {
      try {
        final starter = manualStarter;
        if (starter != null && await hasDeferredManual()) {
          if (await starter()) {
            await _clearDeferredLogged(deferredManualKey);
          }
        }
      } catch (_) {}
      try {
        final starter = drainStarter;
        if (starter != null && await isDrainDeferred()) {
          if (await starter()) {
            await _clearDeferredLogged(deferredDrainKey);
          }
        }
      } catch (_) {}
    } finally {
      _dispatchingDeferred = false;
    }
  }

  /// 시작 성공 뒤 보류 기록을 지운다. 실패하면 진단 기록만 남긴다(다음에 한 번 더
  /// 시작될 수 있음 — 요청 유실보다 낫다, 서버와 같음).
  static Future<void> _clearDeferredLogged(String key) async {
    try {
      final deleter = deleteMetaForTest;
      if (deleter != null) {
        await deleter(key);
      } else {
        await LocalDbService.deleteMeta(key);
      }
    } catch (e) {
      DbOptimizeState.appendLog('보류 삭제 실패(다음에 다시 시작할 수 있음: ${e.runtimeType})');
    }
  }

  /// 쉼 사이 재시도 간격: 밑값의 2의 거듭제곱, 최대 1시간(명세 7-1).
  /// [restRounds] 는 이번 구동에서 쉼으로 끝난 회차 수(1부터).
  static Duration restBackoff(String rest, int restRounds) {
    final base = switch (rest) {
      'login_required' => loginRetryInterval,
      'outage' => outageRetryInterval,
      _ => roundRetryInterval,
    };
    var delay = base;
    for (var i = 1; i < restRounds; i++) {
      if (delay >= maxRestBackoff) break;
      delay *= 2;
      if (delay > maxRestBackoff) {
        delay = maxRestBackoff;
        break;
      }
    }
    return delay;
  }

  /// 동기화 성공 wake(메모리 + 영속). 쉬는 최적화는 백오프를 기다리지 않고
  /// 바로 다음 회차로 간다(명세 7-1·7-3). 직접 라운드를 돌린 뒤 쉼으로 끝난
  /// 상태(`_restArmed`)에서 구동 중인 작업이 없으면 재판단을 시작한다.
  static bool _syncSuccessWake = false;

  /// processAll 이 쉼(`outage`·`login_required`·`partial`)으로 끝난 상태.
  /// 다음 동기화 성공 때 구동 중인 작업이 없으면 재판단을 시작한다.
  static bool _restArmed = false;

  /// 재판단 시작 때 같이 쓸 최근 확인 함수(킥 경로용).
  static bool Function()? _lastIsSyncing;
  static Future<bool> Function()? _lastRebuildPending;

  static Future<void> notifySyncSucceeded() async {
    _syncSuccessWake = true;
    try {
      await LocalDbService.setMeta(
        wakeKey,
        '${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (_) {}
    try {
      await runDeferredStarters();
    } catch (_) {}
    if (_running == null && _restArmed) {
      _restArmed = false;
      var need = false;
      try {
        need = await needsRun();
      } catch (_) {}
      if (need) {
        unawaited(
          maybeStart(
                isSyncing: _lastIsSyncing,
                rebuildPending: _lastRebuildPending,
              ) ??
              Future<void>.value(),
        );
      }
    }
  }

  /// 쉼: [delay] 가 끝나거나 동기화 성공 wake 때 'wake'·'timeout' 으로 깬다.
  /// 중지·DB 닫기·DB 교체면 'stop' 으로 멈춘다.
  static Future<String> _sleepRest(
    Duration delay,
    (String, String) startIdentity,
  ) async {
    final sleepStart = DateTime.now().millisecondsSinceEpoch;
    final deadline = DateTime.now().add(delay);
    while (DateTime.now().isBefore(deadline)) {
      if (_stopRequested || LocalDbService.closeRequested) return 'stop';
      try {
        if (await _identityChanged(startIdentity)) return 'stop';
      } catch (_) {}
      if (_syncSuccessWake) {
        _syncSuccessWake = false;
        return 'wake';
      }
      try {
        final raw = await LocalDbService.getMeta(wakeKey);
        final at = int.tryParse(raw ?? '');
        if (at != null && at > sleepStart) return 'wake';
      } catch (_) {}
      final step = restPollInterval;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(remaining < step ? remaining : step);
    }
    return 'timeout';
  }

  static String _restLogLabel(String rest) => switch (rest) {
    'login_required' => '로그인 필요로 쉽니다',
    'outage' => '일시 장애가 계속돼 쉽니다',
    _ => '보류만 남아 쉽니다',
  };

  /// 모든 동기화 종료 경로(SyncEngine.start·drain 끝)에서 부른다. 영속 보류 요청이
  /// 남아 있으면 시작한다. 최적화가 실제로 처리 중이면 계속 보류한다(쉬는 동안은
  /// 보류를 풀어 동기화를 바로 실행한다 — starter 가 다시 defer 하므로 여기서 그냥
  /// 두는 것과 같지만 로그·메타를 다시 쓰지 않게 먼저 둔다).
  static Future<void> notifySyncFinished() async {
    if (_notifyingSyncFinished) return;
    if (blocksSync) return;
    _notifyingSyncFinished = true;
    try {
      await runDeferredStarters();
    } catch (_) {
    } finally {
      _notifyingSyncFinished = false;
    }
  }

  /// 마지막 최적화 오류를 영속한다(새 프로세스의 표시줄 복원용).
  static Future<void> persistLastError(String message) async {
    List<String> logs = const [];
    try {
      final job = DbOptimizeState.jobForStatus();
      final raw = job?['log'] as List? ?? const [];
      logs = [for (final line in raw) '$line'];
    } catch (_) {}
    try {
      await LocalDbService.setMeta(
        lastErrorKey,
        jsonEncode({
          'at': DateTime.now().toUtc().toIso8601String(),
          'message': message,
          'log': logs.length > 20 ? logs.sublist(logs.length - 20) : logs,
        }),
      );
    } catch (_) {}
  }

  static Future<void> clearLastError() async {
    try {
      await LocalDbService.deleteMeta(lastErrorKey);
    } catch (_) {}
  }

  /// DB 교체(백업 복원·서버 DB 가져오기) 완료 뒤 표시 재동기화 — 새 DB 기준.
  /// 메모리의 오류·로그를 지우고, 새 DB 가 done 이면 오류 없음, done 이 아니고
  /// 오류 기록([lastErrorKey])이 있으면 그것만 복원한다. 다른 DB 의 오류가
  /// 남지 않게. 새 DB 를 읽지 못하면 메모리를 유지한다.
  static Future<void> resyncDisplayAfterDatabaseReplaced() async {
    Map<String, dynamic>? meta;
    try {
      meta = await readMeta();
      // 오류 기록까지 읽혀야 새 DB 기준이 확정된다 — 하나라도 실패하면 유지.
      await LocalDbService.getMeta(lastErrorKey);
    } catch (_) {
      return;
    }
    DbOptimizeState.clearDisplay();
    try {
      final done =
          meta != null &&
          sameTarget(meta['target'], mobileParserVersion) &&
          meta['done'] == true;
      if (done) {
        // done DB 에 낡은 오류 기록이 남아 있으면 지운다 — 다음 시작 때
        // 복원되지 않게(완료 때 [clearLastError] 와 같은 정리).
        await clearLastError();
        return;
      }
      await restorePersistedError();
    } catch (_) {}
  }

  /// 영속된 마지막 최적화 오류를 메모리 상태로 복원한다. 복원했으면 true.
  /// 이미 error 상태거나 남긴 오류가 없으면 아무 것도 하지 않고 false.
  static Future<bool> restorePersistedError() async {
    try {
      if (DbOptimizeState.state == 'error') return false;
      final raw = await LocalDbService.getMeta(lastErrorKey);
      if (raw == null || raw.isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final message = '${decoded['message'] ?? ''}';
      final logs = [
        for (final line in (decoded['log'] as List? ?? const [])) '$line',
      ];
      if (message.isEmpty && logs.isEmpty) return false;
      DbOptimizeState.restoreErrorSnapshot(message: message, logs: logs);
      return true;
    } catch (_) {
      return false;
    }
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
      final bool need;
      try {
        need = await needsRun();
      } catch (_) {
        // DB 를 열지 못하는 환경에서는 조용히 건너뛴다(다음 실행에 다시 시도).
        // 게이트 통과 흐름을 깨지 않는다 — F18 회귀 방지.
        return;
      }
      // DB 교체 뒤 표시 재동기화(새 DB 기준 — Sol R3). needsRun 이 DB 를 방금
      // 읽었으므로 여기서 읽는다: 교체 훅에서 닫힌 DB 를 바로 열면 되돌리기
      // 위젯 시험이 끝나지 않는 것을 확인했다. done 이면 오류 없음, 오류
      // 기록이 있으면 그것만 복원한다(다른 DB 의 오류가 남지 않게).
      try {
        await resyncDisplayAfterDatabaseReplaced();
      } catch (_) {}
      if (!need) {
        _restArmed = false;
        // 최적화는 done 이어도 미뤄 둔 보류 요청이 있으면 기동 경로에서 시작한다
        // (서버와 같음 — done=true 기록 직후 끝났어도 유실 없음).
        await runDeferredStarters();
        return;
      }
      _stopRequested = false;
      _restArmed = false;
      _lastIsSyncing = isSyncing;
      _lastRebuildPending = rebuildPending;
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
      // 재시도 시작: 남았던 마지막 오류 표시를 해제한다(표시줄 복원용 영속분 포함).
      await clearLastError();
      final meta = await readMeta() ?? {};
      DbOptimizeState.appendLog(
        'DB 최적화 시작(대상 ${countRows.length}건, 파서 $mobileParserVersion)'
        '${(meta['cursor'] as String?)?.isNotEmpty == true ? ', 커서 ${meta['cursor']}부터 이어서' : ''}'
        '${((meta['holds'] ?? meta['pending']) as List?)?.isNotEmpty == true ? ', 보류 ${((meta['holds'] ?? meta['pending']) as List).length}건부터 다시 시도' : ''}',
      );
      // 시작 때 DB 정체를 잡는다(쉼 중 교체 감지용).
      final driverIdentity = await _captureIdentity();
      try {
        var restRounds = 0;
        while (true) {
          OptimizeRunResult result;
          try {
            result = await LocalDbService.runBackgroundWork(
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
            // 새 프로세스에서도 표시줄에 보이도록 마지막 오류를 영속한다.
            await persistLastError(e.runtimeType.toString());
            // 작업 예외(error) 뒤 동기화 보류를 풀어 대기 요청을 실행한다(서버 _after_error 와 같음).
            // 최적화는 다음 기회에 다시 시도한다. 표시줄은 error 를 '작업 완료'가 아닌 '오류'로 보인다.
            try {
              await _afterError();
            } catch (_) {}
            break;
          }
          // 완료·외부 중지는 processAll 이 상태·메타를 정리했다.
          if (result.finished || result.rest == null) break;
          // 쉼: 지수 백오프 뒤 다음 회차로 가고, 동기화 성공 wake 면 바로 간다(명세 7-1).
          restRounds++;
          final backoff = restBackoff(result.rest!, restRounds);
          final backoffText = backoff.inSeconds >= 60
              ? '${backoff.inMinutes}분'
              : '${backoff.inSeconds}초';
          DbOptimizeState.appendLog(
            '${_restLogLabel(result.rest!)} — $backoffText 뒤 다시 시도합니다'
            '(동기화 성공 뒤에는 바로)',
          );
          final reason = await _sleepRest(backoff, driverIdentity);
          if (reason == 'stop') {
            DbOptimizeState.appendLog('중단됨 — 다음 실행 때 이어서 합니다');
            DbOptimizeState.update(state: 'idle', stage: '', message: '중단됨');
            break;
          }
        }
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
