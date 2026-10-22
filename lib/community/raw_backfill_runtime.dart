import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';
import '../models/app_mode.dart';
import '../models/report.dart';
import '../services/app_prefs_keys.dart';
import '../services/attachment_policy.dart';
import '../services/db_optimize.dart';
import '../services/local_db_service.dart';
import '../services/photo_capture_time.dart';
import '../services/maintenance_service.dart';
import '../services/standalone_api_service.dart';
import '../services/standalone_auth_service.dart';
import '../services/standalone_auto_sync_service.dart';
import '../services/standalone_parser.dart';
import '../services/sync_engine.dart';
import '../services/sync_inventory.dart';
import '../services/sync_operation_admission.dart';
import 'backfill_errors.dart';
import 'backfill_progress.dart';
import 'backfill_store.dart';
import 'capture/capture_retry_store.dart';
import 'capture/community_capture.dart';
import 'capture/raw_capture_source.dart';
import 'capture/raw_ingest.dart';
import 'capture/report_adapter.dart';
import 'community_store.dart';
import 'raw_backfill.dart';
import 'raw_backfill_unstick.dart';
import 'update_requirement.dart';
import 'upload_hooks.dart';
import 'upload_pause.dart';

const _answered = ['수용', '일부수용', '불수용', '답변완료', '기타'];
const _manualLoginKey = rawLoginManualKey;

/// 보류만 남은 run 을 다음 보류 시각에 깨우는 1회 작업(WorkManager). 디스패처가 업로드 작업과 같은 경로로 처리한다.
const String rawBackfillWakeTaskName = 'community-raw-backfill-wake';
const String rawBackfillWakeUniqueName = 'community-raw-backfill-wake-v1';
const _loginPausesKey = 'raw_login_pauses';
const _scopeKeys = [
  'contributor_fingerprint',
  'dataset_key',
  'consent_grant_id',
  'connection_id',
  'writer_epoch',
];

/// Runs [RawBackfill] in short, resumable slices.
///
/// - The per-report state lives in `raw_backfill_items`; `meta.raw_backfill` only holds a summary.
/// - Nothing is scheduled once the run is `done`. A run with only holds wakes itself at the earliest
///   hold time (timer in the app, a one-off WorkManager job in the background); the timer is
///   re-planned after every slice from the marker, never left ticking.
/// - Upload pause (server maintenance) and the required-version lock stop the run entirely.
/// - `personal_sync` is taken only around the local personal-DB writes (see [RawBackfillRuntimeBackend.local]),
///   never across the official-site requests, so a user's sync is not told `sync_busy` for minutes.
class RawBackfillRuntime {
  static Timer? _timer;
  static bool _running = false;
  static int _generation = 0;
  static Future<bool> Function()? _verify;
  static CommunityStore? _store;

  /// Bumped whenever the marker changes; the progress card reloads on it instead of polling.
  static final changed = ValueNotifier<int>(0);

  /// How long one slice may run before yielding to the user's own work.
  @visibleForTesting
  static Duration foregroundSlice = const Duration(seconds: 20);
  @visibleForTesting
  static Duration backgroundSlice = const Duration(minutes: 4);

  static Future<void> start(
    CommunityStore store,
    Future<bool> Function() verify,
  ) async {
    _store = store;
    _verify = verify;
    await _unstick(store);
    if (!await _v2Ready(store)) {
      _cancelTimer();
      return;
    }
    unawaited(run(store: store, verify: verify).catchError((_) => null));
  }

  static void stop() {
    _generation++;
    _cancelTimer();
  }

  static void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 2-3: 새 버전 첫 실행에 한 번 멈춘 run 을 푼다(완료 표시가 있으면 아무것도 하지 않는다).
  static Future<void> _unstick(CommunityStore store) async {
    try {
      if (await unstickRawBackfill(store) != null) changed.value++;
    } catch (_) {}
  }

  /// 시험에서 WorkManager 대신 쓴다(보류 깨우기 1회 작업의 지연).
  @visibleForTesting
  static Future<void> Function(Duration delay)? scheduleWakeForTest;

  /// 보류만 남은 run 을 다음 보류 시각에 깨운다(앱이 닫혀 있어도). 같은 이름이면 새 시각으로 바꾼다.
  static Future<void> _scheduleHoldWake(Duration delay) async {
    final hook = scheduleWakeForTest;
    if (hook != null) {
      await hook(delay);
      return;
    }
    try {
      await Workmanager().registerOneOffTask(
        rawBackfillWakeUniqueName,
        rawBackfillWakeTaskName,
        initialDelay: delay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (_) {}
  }

  /// 중지가 풀렸거나(점검 끝) 잠금이 풀렸을 때 포그라운드 run 을 바로 깨운다.
  static void wake() {
    final store = _store, verify = _verify;
    if (store == null || verify == null) return;
    _cancelTimer();
    unawaited(run(store: store, verify: verify).catchError((_) => null));
  }

  static Future<bool> _v2Ready(CommunityStore store) async {
    try {
      final text = await store.meta('ingest_status');
      return text != null &&
          rawV2Ready((jsonDecode(text) as Map).cast<String, Object?>());
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> status([CommunityStore? store]) async {
    final s = store ?? _store ?? await CommunityStore.open();
    final text = await s.meta('raw_backfill');
    if (text == null) return null;
    try {
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Delay until the next slice, or null when nothing needs to run by itself.
  @visibleForTesting
  static Future<Duration?> nextDelay(
    CommunityStore store,
    Map<String, dynamic>? marker, {
    bool yielded = false,
    DateTime? now,
  }) async {
    if (marker == null) return null;
    switch (marker['state']) {
      case 'done':
        return null;
      case 'paused':
        // Maintenance waits for the status that says "resumed" (the gate refresh wakes the run); the
        // resume-time check is the WorkManager job of UploadPause. No timer of its own here.
        if (marker['reason'] == 'maintenance') return null;
        final at = (marker['next_attempt_at'] as num? ?? 0).toDouble();
        final left = at - (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
        return Duration(seconds: left.ceil().clamp(5, 3600));
      case 'waiting_optimize':
        return const Duration(seconds: 30);
      case 'holds':
        // Other work left: keep going. Only holds: wake at the earliest hold time (15 s floor, 24 h cap).
        final run = marker['run_id'] as String?;
        if (run == null) return null;
        final items = SqliteBackfillItems(store, () async {});
        final s = await items.summary(run);
        if (s['unfinished']! > s['holds']!) return const Duration(seconds: 15);
        final at = await items.nextHoldAt(run);
        if (at == null) return null;
        final left =
            at - (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
        return Duration(seconds: left.clamp(15, 24 * 3600));
      case 'uploading':
        // 업로드 단계는 업로더가 영수증을 받기를 기다릴 뿐이다 — 15초마다 대기 항목을 훑지 않는다.
        return yielded ? const Duration(seconds: 3) : const Duration(seconds: 60);
      default:
        return yielded
            ? const Duration(seconds: 3)
            : const Duration(seconds: 15);
    }
  }

  static Future<void> _plan(
    CommunityStore store,
    Map<String, dynamic>? marker, {
    bool yielded = false,
  }) async {
    _cancelTimer();
    final delay = await nextDelay(store, marker, yielded: yielded);
    if (delay == null) return;
    final verify = _verify;
    if (verify == null) return;
    _timer = Timer(
      delay,
      () =>
          unawaited(run(store: store, verify: verify).catchError((_) => null)),
    );
  }

  static Future<void> retry() async {
    final s = _store ?? await CommunityStore.open();
    await s.setMeta('raw_backfill_retry', 'true');
    await run(store: s, verify: _verify ?? () async => false);
  }

  /// Marker says "finished for this device state": same dataset and account, nothing asked for.
  static Future<bool> _alreadyDone(
    CommunityStore store,
    Map<String, dynamic>? marker,
  ) async {
    if (marker == null || marker['state'] != 'done') return false;
    if (await store.meta('raw_backfill_retry') == 'true') return false;
    if (await store.activeContext() == null) return true;
    // The run identity is the local database only.
    return marker['local_dataset_id'] == await store.localDatasetId();
  }

  static Future<Map<String, dynamic>?> run({
    required CommunityStore store,
    required Future<bool> Function() verify,
    bool background = false,
  }) async {
    if (_running) return null;
    await _unstick(store);
    // Cheap local checks first: no network, no lease, no fresh gate when there is nothing to do.
    if (!await _v2Ready(store)) return null;
    final before = await status(store);
    if (await _alreadyDone(store, before)) {
      await BackfillProgress.report(store, background: background);
      return before;
    }
    if (before != null &&
        before['state'] == 'paused' &&
        before['reason'] == 'official_login_required' &&
        await store.meta(_manualLoginKey) != null) {
      // 공식 로그인이 거부되어 멈춘 상태: 수동 로그인으로 결과가 바뀔 때까지 공식 API 를 부르지 않는다.
      ReloginStatus? login;
      try {
        login = await StandaloneAuthService.lastReloginStatus();
      } catch (_) {}
      if (login?.needsManualLogin == true) {
        if (!background) await _plan(store, before);
        return null;
      }
      await store.db.delete(
        'meta',
        where: 'key IN (?,?)',
        whereArgs: [_manualLoginKey, _loginPausesKey],
      );
      before['next_attempt_at'] = 0;
      await store.setMeta('raw_backfill', jsonEncode(before));
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (AppModeX.fromString(prefs.getString(AppPrefsKeys.appMode)) !=
            AppMode.standalone ||
        (prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false)) {
      return null;
    }
    // 필수 버전 잠금(6절): 1회 전송을 하지 않는다(marker 는 그대로 — 업데이트 뒤 이어 간다).
    if ((await UpdateRequirement.load(prefs)).locked) {
      await BackfillProgress.report(store, background: background);
      return null;
    }
    if (_running || !await verify() || _running) return null;
    _running = true;
    final generation = _generation, owner = 'raw-backfill:${newUuidV4()}';
    Timer? heartbeat;
    Map<String, dynamic>? outcome;
    var yielded = false;
    try {
      if (!await store.acquireLease(
        'raw_backfill',
        owner,
        const Duration(minutes: 2),
      )) {
        return null;
      }
      var leaseLost = false;
      heartbeat = Timer.periodic(const Duration(seconds: 20), (_) async {
        try {
          if (!await store.renewLease(
            'raw_backfill',
            owner,
            const Duration(minutes: 2),
          )) {
            leaseLost = true;
          }
        } catch (_) {
          leaseLost = true;
        }
      });
      final backend = RawBackfillRuntimeBackend(
        store,
        () => generation == _generation && !leaseLost,
        slice: background ? backgroundSlice : foregroundSlice,
        background: background,
      );
      await BackfillProgress.countRun(store, background: background);
      final retry = await store.meta('raw_backfill_retry') == 'true';
      await store.db.delete(
        'meta',
        where: 'key=?',
        whereArgs: ['raw_backfill_retry'],
      );
      outcome = await RawBackfill(
        load: () => status(store),
        save: (marker, scope) async {
          if (!await backend.current(scope)) throw BackfillCancelled();
          await store.setMeta('raw_backfill', jsonEncode(marker));
          changed.value++;
        },
        backend: backend,
        items: SqliteBackfillItems(store, backend.check),
        shouldYield: backend.yieldRequested,
        maintenance: () async {
          final pause = await UploadPause.read(store);
          return pause == null ? null : {'wake_at': pause.wakeAt};
        },
      ).run(budget: 1000, retryHolds: retry);
      yielded = backend.yieldRequested();
      if (outcome != null && outcome['reason'] != 'official_login_required') {
        await store.db.delete(
          'meta',
          where: 'key IN (?,?)',
          whereArgs: [_manualLoginKey, _loginPausesKey],
        );
      }
    } on BackfillCancelled {
      /* The persisted cursor resumes under the next valid scope. */
    } catch (_) {
      /* Never mark an interrupted run complete. */
    } finally {
      heartbeat?.cancel();
      await store.releaseLease('raw_backfill', owner);
      _running = false;
    }
    final latest = outcome ?? await status(store);
    if (generation == _generation && !background) {
      await _plan(store, latest, yielded: yielded);
    }
    if (latest?['state'] == 'holds') {
      try {
        final delay = await nextDelay(store, latest);
        if (delay != null) await _scheduleHoldWake(delay);
      } catch (_) {}
    }
    await BackfillProgress.report(store, background: background);
    return outcome;
  }
}

class _Slot<T> {
  _Slot(this.value);
  final T value;
}

/// Production adapter of [RawBackfill] (official site, personal DB, community store).
@visibleForTesting
class RawBackfillRuntimeBackend
    implements RawBackfillBackend, BatchedReceipts {
  /// Replaced in tests: the satisfaction lookup (official site).
  static Future<({int? score, String cause, bool confirmed, bool exists})>
  Function(String reportNumber)?
  satisfactionForTest;

  /// Replaced in tests: the first list request (total count).
  static Future<int> Function()? totalCountForTest;

  RawBackfillRuntimeBackend(
    this.store,
    this.allowed, {
    required Duration slice,
    this.background = false,
  }) : sliceEnd = DateTime.now().add(slice);
  final CommunityStore store;
  final bool Function() allowed;

  /// 슬라이스가 끝나면 항목 사이에서 양보한다([yieldRequested]). 항목·목록 요청 도중에는 끊지 않는다 —
  /// 중간에 끊으면 같은 목록·같은 항목을 처음부터 반복하며 공식 API 를 계속 부른다.
  final DateTime sliceEnd;

  /// 백그라운드 isolate 는 DB 최적화를 시작하지 않는다(기다리기만).
  final bool background;
  Map<String, dynamic>? activeScope;
  final _listItems = <String, Map<String, Object?>>{};

  bool yieldRequested() => DateTime.now().isAfter(sliceEnd);

  Future<void> check() async {
    if (activeScope == null || !await current(activeScope!)) {
      throw BackfillCancelled();
    }
  }

  Future<void> pause() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await check();
  }

  /// Local personal-DB writes run under a short `personal_sync` lease (and its ownership checks);
  /// network requests never do. A user sync in progress only delays this report: [BackfillPaused].
  Future<T> local<T>(Future<T> Function() body) async {
    final slot = await SyncOperationAdmission.run<_Slot<T>?>(
      () async => _Slot<T>(await body()),
      null,
      openStore: () async => store,
      stopRequested: () => !allowed(),
      validateScope: () async {
        if (activeScope != null && !await current(activeScope!)) {
          throw BackfillCancelled();
        }
      },
    );
    if (slot == null) throw BackfillPaused('sync_busy', retrySeconds: 60);
    return slot.value;
  }

  @override
  Future<Map<String, dynamic>?> scope() async {
    final ctx = await store.activeContext(),
        text = await store.meta('ingest_status');
    final status = text == null
        ? <String, Object?>{}
        : (jsonDecode(text) as Map).cast<String, Object?>();
    final consent = status['consent'];
    if (ctx == null ||
        !rawV2Ready(status) ||
        consent is! Map ||
        consent['grant_id'] != ctx['consent_grant_id']) {
      return null;
    }
    activeScope = {
      for (final k in _scopeKeys) k: ctx[k],
      'local_dataset_id': await store.localDatasetId(),
      'parser_target': mobileParserVersion,
    };
    return activeScope;
  }

  @override
  Future<bool> current(Map<String, dynamic> scope) async {
    if (!allowed() || LocalDbService.closeRequested) {
      return false;
    }
    final ctx = await store.activeContext();
    return ctx != null &&
        await store.localDatasetId() == scope['local_dataset_id'] &&
        _scopeKeys.every((k) => ctx[k] == scope[k]);
  }

  /// 일반 크롤·자동 동기화·사진 작업이 도는가. 시험에서 바꾼다.
  @visibleForTesting
  static bool Function() generalWorkRunning = () =>
      SyncEngine.isRunning ||
      StandaloneAutoSyncService.isRunning ||
      MaintenanceService.isRunning;

  /// 포그라운드에서 DB 최적화를 시작한다 — ReportProvider._startDbOptimizeIfNeeded 와 같은 인자(provider 의
  /// `_lastIsSyncing`/`_lastRebuildPending` 을 null 로 덮지 않는다). 시험에서 바꾼다.
  @visibleForTesting
  static void Function() optimizeStarter = () {
    unawaited(
      DbOptimize.maybeStart(
        isSyncing: () =>
            SyncEngine.isRunning || StandaloneAutoSyncService.isRunning,
        rebuildPending: () async => SyncEngine.rebuildBlocks != null
            ? await SyncEngine.rebuildBlocks!()
            : false,
      ),
    );
  };

  @override
  Future<bool> optimizationReady() async {
    // 일반 크롤·자동 동기화·사진 작업과 동시에 돌지 않는다(PC·계획 7-2).
    if (generalWorkRunning()) return false;
    if (DbOptimize.isRunning || DbOptimize.blocksSync) return false;
    // 보류만 남은 최적화(재시도 시각 대기)는 준비 완료로 본다.
    final holdsOnly = DbOptimize.holdsOnly(await DbOptimize.readMeta());
    if (!holdsOnly && await DbOptimize.needsRun()) {
      // 백그라운드 isolate 에서는 시작하지 않는다(포그라운드와 동시에 전체 최적화가 돌 수 있다).
      if (!background) optimizeStarter();
      return false;
    }
    return true;
  }

  /// 공식 로그인 거부(수동 로그인 필요)면 수동 로그인까지 멈추고, 그 외에는 5분부터 두 배씩(최대 1시간) 물러난다.
  Future<BackfillPaused> _loginPause() async {
    ReloginStatus? login;
    try {
      login = await StandaloneAuthService.lastReloginStatus();
    } catch (_) {}
    if (login?.needsManualLogin == true) {
      await store.setMeta(_manualLoginKey, '1');
      return BackfillPaused('official_login_required', retrySeconds: 3600);
    }
    final count =
        (int.tryParse(await store.meta(_loginPausesKey) ?? '0') ?? 0) + 1;
    await store.setMeta(_loginPausesKey, '$count');
    final seconds = math.min(3600, 300 * (1 << math.min(count - 1, 6)));
    return BackfillPaused('official_login_required', retrySeconds: seconds);
  }

  // ── A: list inventory ─────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> inventory() async {
    try {
      await check();
      final total =
          await (totalCountForTest ?? StandaloneApiService.fetchTotalCount)();
      await pause();
      final inventory = ListInventory(total);
      final ids = <String>[], eligible = <String>[];
      for (var start = 1; start <= total; start += 200) {
        await check();
        final end = (start + 199).clamp(1, total);
        final rows = inventory.addPage(
          await StandaloneApiService.fetchReportList(
            startRow: start,
            endRow: end,
          ),
          start,
          end,
        );
        for (final row in rows) {
          final id = row['C_NO'].toString();
          ids.add(id);
          if (_answered.contains(mapCNowStatus(row['C_NOW']))) {
            eligible.add(id);
          }
          // Only the keys the detail parser reads from a list row.
          _listItems[id] = {
            for (final k in [
              'C_NO',
              'C_A_TITLE',
              'C_DATE',
              'STSFDG_SCORE',
              'STTEMNT_NO',
              'C_NOW',
            ])
              if (row[k] != null) k: row[k],
          };
        }
        await pause();
      }
      await _rememberMissingListItems();
      return {
        'list_ok': inventory.listComplete,
        'ids': ids,
        'eligible_ids': eligible,
      };
    } catch (e) {
      if (e is BackfillCancelled || e is BackfillPaused) rethrow;
      // The first request (total count) is inside this guard too: a failure is retried with the
      // pause back-off, and a login problem pauses as "official login required".
      if (DbOptimize.classifyFetchError(e) == 'auth') {
        throw await _loginPause();
      }
      return {'list_ok': false, 'ids': <String>[], 'eligible_ids': <String>[]};
    }
  }

  /// List rows of reports that are not on the phone are kept (bounded, in the item database) so a
  /// restart can still build their detail record from the real list values.
  Future<void> _rememberMissingListItems() async {
    final local = (await localIds()).toSet();
    final scopeId = activeScope!['local_dataset_id'];
    await check();
    await store.transaction((tx) async {
      final batch = tx.batch();
      for (final e in _listItems.entries) {
        if (local.contains(e.key)) continue;
        batch.insert('raw_backfill_supplements', {
          'local_dataset_id': scopeId,
          'report_id': e.key,
          'kind': 'list',
          'status': jsonEncode(e.value),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<List<String>> localIds() async =>
      (await (await LocalDbService.db).query(
        'reports',
        columns: ['ID'],
      )).map((r) => r['ID'].toString()).toList();
  @override
  Future<List<String>> eligibleIds() async =>
      (await (await LocalDbService.db).query(
        'reports',
        columns: ['ID'],
        where: "처리상태 IN ('수용','일부수용','불수용','답변완료','기타')",
      )).map((r) => r['ID'].toString()).toList();

  // ── supplement markers ────────────────────────────────────────────────────

  Future<String?> _marker(String kind, String id) async {
    final rows = await store.db.query(
      'raw_backfill_supplements',
      columns: ['status'],
      where: 'local_dataset_id=? AND report_id=? AND kind=?',
      whereArgs: [activeScope!['local_dataset_id'], id, kind],
    );
    return rows.isEmpty ? null : rows.first['status'] as String?;
  }

  Future<void> _mark(String kind, String id, String status) async {
    await check();
    await store.db.insert('raw_backfill_supplements', {
      'local_dataset_id': activeScope!['local_dataset_id'],
      'report_id': id,
      'kind': kind,
      'status': status,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The list row for the detail parser: this run's inventory, the remembered row, the stored
  /// report (as the optimizer's re-parse does), or — last resort — only the id.
  Future<Map<String, dynamic>> _listItem(
    String id,
    Map<String, Object?>? row,
  ) async {
    final live = _listItems[id];
    if (live != null) return {...live, 'C_NO': id};
    if (row != null) {
      return {
        'C_NO': id,
        'C_A_TITLE': row['신고명'],
        'C_DATE': row['신고일'],
        'STTEMNT_NO': row['신고번호'],
        'STSFDG_SCORE': row['별점'],
      };
    }
    final kept = await _marker('list', id);
    if (kept != null) {
      try {
        return {
          ...(jsonDecode(kept) as Map).cast<String, dynamic>(),
          'C_NO': id,
        };
      } catch (_) {}
    }
    return {'C_NO': id};
  }

  // ── B/C: one report ───────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> prepare(String id) async {
    await check();
    final deleted = await store.db.rawQuery(
      "SELECT 1 FROM source_journal WHERE source_report_id=? AND dataset_key IS ? AND contributor_fingerprint IS ? AND blocked_reason IN ('deleted_by_user','deleted','blocked:deleted') LIMIT 1",
      [
        id,
        activeScope!['dataset_key'],
        activeScope!['contributor_fingerprint'],
      ],
    );
    if (deleted.isNotEmpty) throw BackfillBlocked('deleted');
    var row = await LocalDbService.readReparseBase(id);
    var filled = 0, unfilled = 0;
    String? photoUnavailable;
    final snapshot = row == null ? null : await storedRawSnapshot(id);
    if (row == null || snapshot == null) {
      // B: the report (or its raw body) is missing/damaged. One normal detail save creates the
      // single raw event of this report; enqueue() adopts it instead of issuing a second one.
      try {
        final fetched = await StandaloneApiService.fetchReportDetail(id);
        if (fetched.envelope['result'] is! Map) {
          // 상세 응답에 result 가 없다 — 공식 사이트의 일시 문제로 본다(신고 횟수에 넣지 않는다).
          throw BackfillTransient('no_result');
        }
        await pause();
        final session = await SyncEngine.openCommunitySession();
        final listItem = await _listItem(id, row);
        await local(
          () => SyncEngine.captureAndSaveDetail(
            cNo: id,
            item: listItem,
            detail: {...fetched.result, 'C_NO': id},
            envelope: fetched.envelope,
            rawSource: 'raw_backfill',
            trigger: 'raw_backfill',
            tracker: CaptureTracker(),
            communityStore: store,
            retryFile: session.retryFile,
            projectNamespace: session.projectNamespace,
            captureActive: true,
            isCancelled: () => !allowed(),
          ),
        );
        await check();
        filled++;
        row = await LocalDbService.readReparseBase(id);
      } catch (e) {
        if (e is BackfillCancelled || e is BackfillPaused) rethrow;
        final kind = DbOptimize.classifyFetchError(e);
        if (kind == 'auth') throw await _loginPause();
        if (kind == 'permanent') {
          return {'raw_unavailable': true, 'filled': 0, 'unfilled': 1};
        }
        rethrow;
      }
    }
    if (row == null) throw StateError('missing_report');
    if (!_answered.contains(row['처리상태'])) {
      return {'eligible': false, 'filled': filled, 'unfilled': 0};
    }

    // C: supplements. Whatever happens here is recorded as a marker and NEVER blocks the raw event:
    // a value that cannot be had stays empty and the raw body is still sent.
    if (row['만족도조사여부'] == '참여 완료' &&
        (row['별점'] == null || (row['별점사유'] ?? '') == '') &&
        await _marker('rating', id) == null) {
      var outcome = 'unavailable';
      try {
        final number = (row['신고번호'] ?? '').toString();
        final score =
            await (satisfactionForTest ??
                StandaloneApiService.fetchSatisfactionStatus)(number);
        await pause();
        if (score.confirmed) {
          final cause = score.cause.trim();
          if (score.score != null || cause.isNotEmpty) {
            await local(() async {
              await (await LocalDbService.db).update(
                'reports',
                {
                  if (score.score != null) '별점': score.score,
                  if (cause.isNotEmpty) '별점사유': cause,
                },
                where: 'ID=?',
                whereArgs: [id],
              );
              LocalDbService.invalidateCaches();
            });
            outcome = 'success';
            filled++;
          } else {
            outcome = 'none';
            unfilled++;
          }
          row = await LocalDbService.readReparseBase(id) ?? row;
        } else {
          unfilled++;
        }
      } catch (e) {
        if (e is BackfillCancelled) rethrow;
        if (e is BackfillPaused && e.reason == 'sync_busy') rethrow;
        unfilled++;
      }
      await _mark('rating', id, outcome);
    }
    final photoRow = row!;
    final photos = (photoRow['첨부사진'] ?? '').toString();
    if (photoUrls(photos).isNotEmpty &&
        photoRow['사진_촬영수'] == null &&
        await _marker('photo', id) == null) {
      var outcome = 'unavailable';
      if (attachmentsExpired((photoRow['신고일'] ?? '').toString())) {
        unfilled++;
        photoUnavailable = 'expired';
      } else {
        try {
          final photo = await collectPhotoCapture(
            photos,
            fetch: (url) async {
              await check();
              final value = await fetchCaptureTime(url);
              await pause();
              return value;
            },
          );
          if (photo == null) {
            unfilled++;
          } else {
            await local(
              () => LocalDbService.setPhotoCapture(
                id,
                photo,
                attachedPhotos: photos,
              ),
            );
            if (photo.count > 0) {
              outcome = 'success';
              filled++;
            } else {
              outcome = 'none';
              unfilled++;
              photoUnavailable = 'no_exif';
            }
          }
        } catch (e) {
          if (e is BackfillCancelled) rethrow;
          if (e is BackfillPaused && e.reason == 'sync_busy') rethrow;
          unfilled++;
        }
      }
      await _mark('photo', id, outcome);
    }
    await check();
    return {
      'eligible': true,
      'raw_unavailable': false,
      'filled': filled,
      'unfilled': unfilled,
      'photo_unavailable': photoUnavailable,
    };
  }

  @override
  Future<String?> enqueue(String id, String run) async {
    await check();
    final row = await LocalDbService.readReparseBase(id);
    if (row == null) throw StateError('missing_report');
    // A previous attempt (or the detail save of step B, which labels itself plain `raw_backfill`)
    // may already have issued this report's event: adopt it, never issue a second one.
    final prior = await store.db.query(
      'source_journal',
      columns: ['event_id', 'ack_status', 'capture_trigger'],
      where:
          "source_report_id=? AND capture_trigger IN ('raw_backfill', ?) AND raw_event_json IS NOT NULL AND consent_grant_id=? AND local_dataset_id=? AND connection_id=? AND writer_epoch=?",
      whereArgs: [
        id,
        'raw_backfill:$run',
        activeScope!['consent_grant_id'],
        activeScope!['local_dataset_id'],
        activeScope!['connection_id'],
        activeScope!['writer_epoch'],
      ],
      orderBy: 'source_revision DESC',
      limit: 1,
    );
    if (prior.isNotEmpty) {
      final previous = prior.first['event_id'] as String;
      final box = await store.db.query(
        'outbox',
        columns: ['state'],
        where: 'event_id=?',
        whereArgs: [previous],
      );
      if (await store.meta('raw_receipt:$previous') == 'stored' ||
          (prior.first['ack_status'] == null &&
              box.isNotEmpty &&
              [
                'pending',
                'retry_wait',
                'in_flight',
                'auth_required',
              ].contains(box.first['state']))) {
        if (prior.first['capture_trigger'] == 'raw_backfill') {
          await store.db.update(
            'source_journal',
            {'capture_trigger': 'raw_backfill:$run'},
            where: 'event_id=?',
            whereArgs: [previous],
          );
        }
        return previous;
      }
    }
    final report = Report.fromJson(row.cast<String, dynamic>());
    final input = buildReportAdapterInput(
      report,
      (row['entry_value'] ?? '').toString(),
      photoFirstCapture: row['사진_첫촬영'] as String?,
      photoLastCapture: row['사진_끝촬영'] as String?,
    );
    final snapshot = await storedRawSnapshot(id);
    final result = await local(
      () => capture(
        input,
        sourceReportId: id,
        trigger: 'raw_backfill',
        store: store,
        rawDetailSnapshot: snapshot,
        force: true,
        beforeWrite: (tx) =>
            SyncOperationAdmission.checkOwnership(executor: tx),
      ),
    );
    await check();
    if (result.eventId == null) {
      // No event for a report that cannot be shared (deleted by the user, not an answered
      // observation) is "not eligible", not a defect to retry.
      if (!result.eligible) throw BackfillBlocked('not_eligible');
      final gone = await store.db.rawQuery(
        "SELECT 1 FROM source_journal WHERE source_report_id=? AND blocked_reason='deleted_by_user' LIMIT 1",
        [id],
      );
      if (gone.isNotEmpty) throw BackfillBlocked('deleted');
      return null;
    }
    await store.db.update(
      'source_journal',
      {'capture_trigger': 'raw_backfill:$run'},
      where: 'event_id=?',
      whereArgs: [result.eventId],
    );
    await markPersonalSave(result.eventId, true, store: store);
    return result.eventId;
  }

  /// event_id -> 영수증 판정. [prefetchReceipts] 가 채우고 [receipt] 가 한 번 쓰고 비운다.
  final _receipts = <String, String>{};

  /// 업로드 단계의 대기 항목 영수증을 쿼리 3개(메타·저널·outbox)로 한꺼번에 읽는다 — 항목마다 3~4개를 돌리지 않는다.
  @override
  Future<void> prefetchReceipts(Iterable<String> events) async {
    _receipts.clear();
    final ids = events.toSet().toList();
    for (var i = 0; i < ids.length; i += 400) {
      await check();
      final part = ids.sublist(i, math.min(ids.length, i + 400));
      final marks = List.filled(part.length, '?').join(',');
      final stored = {
        for (final r in await store.db.query(
          'meta',
          columns: ['key'],
          where:
              'key IN (${List.filled(part.length, '?').join(',')}) AND value=?',
          whereArgs: [for (final e in part) 'raw_receipt:$e', 'stored'],
        ))
          (r['key'] as String).substring('raw_receipt:'.length),
      };
      final journal = {
        for (final r in await store.db.query(
          'source_journal',
          columns: ['event_id', 'ack_status'],
          where: 'event_id IN ($marks)',
          whereArgs: part,
        ))
          r['event_id'] as String: r['ack_status'] as String?,
      };
      final box = {
        for (final r in await store.db.query(
          'outbox',
          columns: ['event_id', 'state'],
          where: 'event_id IN ($marks)',
          whereArgs: part,
        ))
          r['event_id'] as String: r['state'] as String?,
      };
      for (final e in part) {
        _receipts[e] = _judgeReceipt(
          stored.contains(e),
          journal.containsKey(e),
          journal[e],
          box[e],
        );
      }
    }
  }

  static String _judgeReceipt(
    bool metaStored,
    bool inJournal,
    String? ack,
    String? boxState,
  ) {
    if (metaStored || (inJournal && ack == 'stored')) return 'stored';
    if (boxState == 'blocked' || boxState == 'dead_letter') return 'blocked';
    if (!inJournal || ack != null) return 'retry';
    return 'pending';
  }

  @override
  Future<String> receipt(String id, String event) async {
    await check();
    final prefetched = _receipts.remove(event);
    if (prefetched != null) return prefetched;
    if (await store.meta('raw_receipt:$event') == 'stored') return 'stored';
    final rows = await store.db.query(
      'source_journal',
      columns: ['ack_status'],
      where: 'event_id=?',
      whereArgs: [event],
    );
    final box = await store.db.query(
      'outbox',
      columns: ['state'],
      where: 'event_id=?',
      whereArgs: [event],
    );
    if (rows.isNotEmpty && rows.first['ack_status'] == 'stored') {
      return 'stored';
    }
    if (box.isNotEmpty &&
        ['blocked', 'dead_letter'].contains(box.first['state'])) {
      return 'blocked';
    }
    if (rows.isEmpty || rows.first['ack_status'] != null) return 'retry';
    return 'pending';
  }

  @override
  Future<void> wakeUpload() async {
    // 중지(점검)·필수 버전 잠금 중에는 깨우지 않는다(CLIENT-RULES 3절).
    if (UpdateRequirement.isLocked || await UploadPause.isPaused(store)) return;
    CommunityUploadHooks.wakeUploadNow('raw_backfill');
  }
}
