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

class DbOptimize {
  DbOptimize._();

  /// 크롤과 같은 요청 간격(서버 0.3s).
  static Duration requestInterval = const Duration(milliseconds: 300);

  /// 일시 오류(envelope 단위) 재시도 횟수. 상세 API 안의 `_getWithRetry`(5회/1초)가
  /// 1차 전송 재시도를 맡고, 여기서는 envelope 단위 실패를 이 횟수만큼 다시 받는다(서버와 같음).
  static int fetchRetryAttempts = 3;

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
    requestInterval = const Duration(milliseconds: 300);
    fetchRetryAttempts = 3;
    waitInterval = const Duration(seconds: 5);
    loginRetryInterval = const Duration(seconds: 60);
    _afterFinishHooks.clear();
    LocalDbService.upgradeLog.clear();
    LocalDbService.upgradeRunning = false;
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

  static Future<bool> saveReparsed(
    Report report,
    String entryValue,
    String category, {
    RawDetailUpsert? rawDetail,
    String rawContent = '',
    Map<String, int>? tallyChanged,
    Map<String, int>? tallyEvents,
    Map<String, Map<String, int>>? tallySkipped,
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
        _tallySkipped(tallySkipped, 'save_failed');
        return false;
      }
      if (store == null) {
        DbOptimizeState.appendLog('${report.id} 저장 실패(community_store_unavailable)');
        _tallySkipped(tallySkipped, 'save_failed');
        return false;
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
      _tallySkipped(tallySkipped, 'save_failed');
      return false;
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
      _tallySkipped(tallySkipped, reason);
      DbOptimizeState.appendLog('${report.id} 건너뜀($reason)');
      return false;
    } catch (e) {
      DbOptimizeState.appendLog('${report.id} 저장 실패(${e.runtimeType})');
      _tallySkipped(tallySkipped, 'save_failed');
      return false;
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

  static void _tallySkipped(
    Map<String, Map<String, int>>? tallySkipped,
    String reason,
  ) {
    if (tallySkipped == null) return;
    for (final entry in tallySkipped.entries) {
      entry.value[reason] = (entry.value[reason] ?? 0) + 1;
    }
  }

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
    final cursor = '${meta['cursor'] ?? ''}';
    final stats = Map<String, dynamic>.from(meta['stats'] as Map? ?? {});
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

    var index = startIndex;
    var stopped = false;
    while (index < ids.length) {
      if ((isStopped ?? () => _stopRequested)() || LocalDbService.closeRequested) {
        stopped = true;
        break;
      }
      final turn = await waitForTurn(
        isSyncing: isSyncing,
        rebuildPending: rebuildPending,
        wait: wait,
        isStopped: isStopped,
      );
      if (!turn) {
        stopped = true;
        break;
      }
      final reportId = ids[index];
      final (envelope, rawState) = await storedResult(reportId);
      if (rawState == 'ok' && envelope != null) {
        final result = envelope['result'];
        if (result is! Map<String, dynamic>) {
          tally(skipped: 'result_not_object');
          DbOptimizeState.appendLog('$reportId 건너뜀(result 없음)');
        } else {
          final report = parseStoredResult(reportId, result);
          if (report == null) {
            tally(skipped: 'parse_failed');
          } else {
            final entry = entryValueFromDetail(const {}, result);
            final cat = categoryFromDetail(report, entry);
            final rawContent = normalizeRawPayloadText(rawContentOf(result));
            final changedTallies = <String, int>{};
            final eventTallies = <String, int>{};
            final skipTallies = <String, Map<String, int>>{
              's': {},
              'r': {},
            };
            try {
              final changed = await saveReparsed(
                report,
                entry,
                cat,
                rawContent: rawContent,
                tallyChanged: changedTallies,
                tallyEvents: eventTallies,
                tallySkipped: skipTallies,
              );
              final skippedReasons = {
                ...skipTallies['s']!.keys,
                ...skipTallies['r']!.keys,
              };
              if (skippedReasons.isEmpty) {
                // 저장 실패·건너뜀은 reused 로 세지 않는다(서버와 같음).
                tally(reused: true);
                if (changed) tally(changed: true);
                if ((eventTallies['events'] ?? 0) > 0) tally(event: true);
              } else {
                for (final reason in skippedReasons) {
                  tally(skipped: reason);
                }
              }
            } on CaptureStoreUnavailable {
              rethrow;
            }
            await ensureRawFile(reportId, envelope);
          }
        }
      } else {
        final fetched = await fetchEnvelope(
          reportId,
          fetchFn: fetchFn,
          interval: gap,
        );
        if (gap > Duration.zero && fetched.outcome == 'ok') {
          await Future<void>.delayed(gap);
        }
        if (fetched.outcome == 'auth') {
          DbOptimizeState.update(
            state: 'paused',
            stage: 'login_required',
            message: '로그인 뒤 이어서 합니다',
          );
          DbOptimizeState.appendLog('로그인 필요 — 로그인 뒤 이어서 합니다(${fetched.note})');
          await Future<void>.delayed(loginGap);
          if ((isStopped ?? () => _stopRequested)() ||
              LocalDbService.closeRequested) {
            stopped = true;
            break;
          }
          DbOptimizeState.update(state: 'running', stage: 'running', message: '');
          continue; // 같은 신고부터 다시
        }
        if (fetched.outcome != 'ok' || fetched.envelope == null) {
          final reason = fetched.outcome == 'permanent' ? 'not_found' : 'fetch_failed';
          tally(skipped: reason);
          final detail = fetched.note;
          DbOptimizeState.appendLog(
            '$reportId 건너뜀($reason${detail.isEmpty ? '' : ': $detail'})',
          );
        } else {
          final data = fetched.envelope!;
          final prepared = prepareRawDetail(data);
          final result = data['result'];
          if (result is! Map<String, dynamic>) {
            tally(skipped: 'result_not_object');
            DbOptimizeState.appendLog('$reportId 건너뜀(result 없음)');
          } else {
            final report = parseStoredResult(reportId, result);
            if (report == null) {
              tally(skipped: 'parse_failed');
            } else {
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
              final skipTallies = <String, Map<String, int>>{
                's': {},
                'r': {},
              };
              try {
                final changed = await saveReparsed(
                  report,
                  entry,
                  cat,
                  rawDetail: upsert,
                  rawContent: rawContent,
                  tallyChanged: changedTallies,
                  tallyEvents: eventTallies,
                  tallySkipped: skipTallies,
                );
                final skippedReasons = {
                  ...skipTallies['s']!.keys,
                  ...skipTallies['r']!.keys,
                };
                if (skippedReasons.isEmpty) {
                  // 저장 실패·건너뜀은 refetched 로 세지 않는다(서버와 같음).
                  tally(refetched: true);
                  if (changed) tally(changed: true);
                  if ((eventTallies['events'] ?? 0) > 0) tally(event: true);
                } else {
                  for (final reason in skippedReasons) {
                    tally(skipped: reason);
                  }
                }
              } on CaptureStoreUnavailable {
                rethrow;
              }
              try {
                await writeRawDetailFile(
                  reportId,
                  prepared.sanitized,
                  dir: rawFileDirForTest,
                );
              } catch (_) {}
            }
          }
        }
      }

      index += 1;
      doneCount = index;
      DbOptimizeState.update(done: doneCount);
      await writeMeta({
        'target': mobileParserVersion,
        'cursor': ids[index - 1],
        'done': false,
        'total': total,
        'stats': stats,
      });
    }

    final finished = index >= ids.length && !stopped;
    if (finished) {
      await writeMeta({
        'target': mobileParserVersion,
        'cursor': ids.isEmpty ? '' : ids.last,
        'done': true,
        'total': total,
        'stats': stats,
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
    return OptimizeRunResult(
      total: total,
      done: doneCount,
      finished: finished,
      stats: run,
    );
  }

  static Future<void> _afterFinish() async {
    for (final hook in List.of(_afterFinishHooks)) {
      try {
        await hook();
      } catch (_) {}
    }
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
        if (!await needsRun()) return;
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
        DbOptimizeState.update(
          state: 'error',
          stage: 'error',
          message: e.runtimeType.toString(),
        );
        DbOptimizeState.appendLog('오류로 멈춤(${e.runtimeType})');
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
