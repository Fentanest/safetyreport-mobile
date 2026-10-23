import '../manifest_result.dart';
import '../../services/sqlite_connection.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../services/local_db_service.dart';
import '../../services/sync_engine.dart';
import '../../services/sync_operation_admission.dart';
import '../community_store.dart';
import '../upload_hooks.dart';
import '../capture/rebuild_helpers.dart';

/// 1회 초기화 크롤링 범위 키 (`contracts/community-ingest/rebuild.md`).
// 2026-10-11: 신고 분류 5분류·SSNPC 코드·차량번호(VHRNO)를 기존 신고에도 채우려고 한 번 더 다시 불러온다(앱 DB 17, 서버 스키마 6).
const String communityRebuildRequiredVersion = 'source-rebuild-2026-10-11.1';

/// 상태기계 상태 (`rebuild.md`).
abstract class RebuildStates {
  static const required = 'required';
  static const prerequisitesRequired = 'prerequisites_required';
  static const waitingRetry = 'waiting_retry';
  static const awaitingConfirmation = 'awaiting_confirmation';
  static const preparingBackup = 'preparing_backup';
  static const running = 'running';
  static const validating = 'validating';
  static const committing = 'committing';
  static const completed = 'completed';
  static const completedWithGaps = 'completed_with_gaps';
  static const paused = 'paused';
  static const failed = 'failed';

  static const terminalOk = {completed, completedWithGaps};
  static const inactiveTerminal = {completed, completedWithGaps, 'abandoned'};
}

/// 초기화 안내 기준 문구 (`rebuild.md`, 2026-10-11). Standalone 은 이 기기가, Client 는 연결된 서버가 다시 불러온다.
const String communityRebuildGuideText =
    '이번 업데이트로 신고 분류가 안전신문고 공식 분류 기준으로 바뀌었습니다. 교통위반·주정차위반에 더해 기타 신고가 '
    '안전신고·생활불편·기타로 나뉘고, 차량번호도 안전신문고에 등록된 값을 먼저 씁니다. '
    '바뀐 기준을 반영하기 위해 저장된 신고를 안전신문고에서 한 번 다시 불러옵니다. '
    '다시 불러오기는 앱을 쓰는 동안 백그라운드에서 진행되고, 진행 상황은 대시보드와 알림에서 볼 수 있습니다. '
    '앱을 닫았다가 다시 열면 이어서 진행합니다.';

const String communityRebuildClientGuideText =
    '이번 업데이트로 신고 분류가 안전신문고 공식 분류 기준으로 바뀌었습니다. 교통위반·주정차위반에 더해 기타 신고가 '
    '안전신고·생활불편·기타로 나뉩니다. 바뀐 기준을 반영하기 위해 연결된 서버가 저장된 신고를 안전신문고에서 한 번 다시 불러옵니다. '
    '서버에서 진행되므로 시작한 뒤에는 앱을 계속 쓰거나 닫아도 됩니다.';

/// 사용자 지정 문구(2026-10-11). Client·PC 는 서버가 다시 불러오므로 '서버 사양 개선',
/// Standalone 은 서버 없이 이 기기가 하므로 '앱 구조 개선'(2026-10-11 사용자 결정).
const String communityRebuildApologyText =
    '서버 사양 개선에 따른 추가적인 불가피한 조치입니다. 불편을 드려 죄송합니다.';
const String communityRebuildStandaloneApologyText =
    '앱 구조 개선에 따른 추가적인 불가피한 조치입니다. 불편을 드려 죄송합니다.';

const String communityRebuildPreservedText =
    '보존 항목: 관리자·공식 계정 설정, 커뮤니티 연결·동의, 앱 설정, 수정한 값·메모·감시목록·중복 판단, '
    '지오코딩 캐시, 업로드 대기 자료. 시작 전 자동 백업을 만듭니다.';

/// 이전 버전 DB 를 비운 기존 사용자 안내(2026-09-26 — 이번 릴리스는 이전 DB 를 새 구조로 옮기지 않는다). PC onboarding_rebuild.html 과 같은 뜻.
const String communityRebuildLegacyText =
    '이전 버전 DB 는 이번 업데이트에서 새 구조로 옮기지 않았습니다. 이전 DB 전체를 백업한 뒤 신고 자료를 비웠고, '
    '감시목록·지도 좌표 캐시는 그대로 두었습니다. 신고는 초기화 크롤링으로 안전신문고에서 다시 수집합니다. '
    '예전에 직접 수정한 값·중복 판단·메모는 옮겨지지 않으니 필요하면 다시 지정해 주세요. 이전 DB 는 이 버전에서 가져올 수 없습니다.';

/// 새 설치 판정에 쓰는 개인 DB 사실(신고 수, 이전 DB 를 비운 기록). 신고 수 null = 읽지 못함(새 설치로 보지 않음).
typedef PersonalDbFacts = ({int? reports, Map<String, Object?>? legacyReset});

/// 새 설치 기준선 표시(`rebuild_jobs.confirmed_at`). PC community_rebuild.FRESH_INSTALL_BASELINE 과 같다.
const String communityRebuildFreshInstallBaseline = 'fresh_install';

/// 초기화 필요·진행 중 전역 가드. 수동·자동 동기화 시작点에서 확인한다.
class CommunityRebuildGuard {
  CommunityRebuildGuard._();
  static bool active = false;
  static const String blockedMessage = SyncEngine.rebuildBlockedMessage;
}

/// 안내 확인 기록(`community.db` meta) 접두사. 범위 키마다 한 번 — 확인한 뒤에는 안내 없이 백그라운드로 이어서 진행한다.
const String communityRebuildGuideAckPrefix = 'rebuild_guide_ack:';

/// 실제 수집 엔진 자리. 기본값은 `SyncEngine.start(fullSync: true)` — T6 가
/// `start(fullSync:rebuildRunId:)` 시그니처를 제공하면 그 호출로 교체한다(REQUESTS.md).
class RebuildEngine {
  const RebuildEngine();

  void cancel() => SyncEngine.stop();

  /// rebuild 모드 전체 수집(T6): 목록 부재 행을 지우지 않고 rebuild_items 에 checkpoint 를 남긴다.
  /// 실패(목록 일부 실패·로그인 실패 포함)는 성공으로 보지 않는다(G12).
  Future<RebuildRunOutcome> run({required String runId}) async {
    final result = await SyncEngine.start(fullSync: true, rebuildRunId: runId);
    if (result.cancelled) {
      throw StateError('paused: ${result.errorMessage ?? 'sync_cancelled'}');
    }
    if (result.failed &&
        (!result.listComplete || result.cancelled || result.busy)) {
      throw StateError(result.errorMessage ?? 'rebuild_sync_failed');
    }
    final store = await CommunityStore.open();
    final permanent = await store.db.rawQuery(
      "SELECT source_report_id FROM rebuild_items WHERE run_id=? AND state='failed_permanent'",
      [runId],
    );
    final listed = await store.db.rawQuery(
      'SELECT list_complete FROM rebuild_jobs WHERE run_id=?',
      [runId],
    );
    final fetched = await store.db.rawQuery(
      "SELECT COUNT(*) n FROM rebuild_items WHERE run_id=? AND state='fetched'",
      [runId],
    );
    return RebuildRunOutcome(
      listComplete: listed.isNotEmpty && listed.first['list_complete'] == 1,
      fetched: fetched.single['n'] as int,
      permanentFailures: [
        for (final r in permanent) r['source_report_id'] as String,
      ],
      orphanCount: result.orphans,
      note: 'sync_engine_rebuild',
    );
  }
}

class RebuildRunOutcome {
  final bool listComplete;
  final int fetched;
  final List<String> permanentFailures;
  final int orphanCount;
  final String? note;
  const RebuildRunOutcome({
    required this.listComplete,
    required this.fetched,
    required this.permanentFailures,
    required this.orphanCount,
    this.note,
  });
}

class RebuildBackupResult {
  final bool ok;
  final String? ref;
  final String? check;
  final String? error;
  const RebuildBackupResult({
    required this.ok,
    this.ref,
    this.check,
    this.error,
  });
}

/// Standalone 로컬 초기화 job (`rebuild.md` 상태기계).
class CommunityRebuild extends ChangeNotifier {
  CommunityRebuild({
    required CommunityStore store,
    required Future<String> Function() localDatasetId,
    required Future<String?> Function() sourceNamespace,
    required Future<bool> Function() gateFresh,
    RebuildEngine engine = const RebuildEngine(),
    Future<RebuildBackupResult> Function(String runId)? backup,
    Future<ManifestResult> Function()? manifestCheck,
    Future<ManifestResult> Function()? gateCheck,
    Future<String> Function()? personalDbPath,
    Future<PersonalDbFacts> Function()? personalDbFacts,
    int Function()? scopeGeneration,
    Stopwatch? progressClock,
    this.stallTimeout = const Duration(minutes: 5),
    this.pollInterval = const Duration(seconds: 2),
  }) : _idle = progressClock ?? Stopwatch(),
       _scopeGeneration = scopeGeneration,
       _store = store,
       _personalDbFacts = personalDbFacts,
       _localDatasetId = localDatasetId,
       _sourceNamespace = sourceNamespace,
       _gateFresh = gateFresh,
       _engine = engine,
       _backupOverride = backup,
       _manifestCheck = manifestCheck ?? CommunityUploadHooks.checkManifest,
       _gateCheck = gateCheck,
       _personalDbPath = personalDbPath;

  final Duration stallTimeout;
  final Duration pollInterval;
  final int Function()? _scopeGeneration;
  final CommunityStore _store;
  final Future<String> Function() _localDatasetId;
  final Future<String?> Function() _sourceNamespace;
  final Future<bool> Function() _gateFresh;
  final RebuildEngine _engine;
  final Future<RebuildBackupResult> Function(String runId)? _backupOverride;
  final Future<ManifestResult> Function() _manifestCheck;
  final Future<ManifestResult> Function()? _gateCheck;
  final Future<String> Function()? _personalDbPath;
  final Future<PersonalDbFacts> Function()? _personalDbFacts;

  Map<String, Object?>? _legacyReset;

  /// 이전 버전 DB 를 비운 기록(안내 화면용). [required]·[load] 뒤에 채워진다.
  Map<String, Object?>? get legacyReset => _legacyReset;

  final String _leaseOwner = newUuidV4();
  Timer? _leaseHeartbeat;
  Timer? _progressTimer;
  Future<bool>? _operation;
  bool _leaseHeld = false;
  bool _leaseLost = false;
  bool _collecting = false;
  bool _disposed = false;
  bool _refreshing = false;
  int _viewRevision = 0;
  String? _cancelReason;
  int? _executionGeneration;
  Map<String, Object?>? _executionScope;
  final Stopwatch _idle;
  int? pendingUploads;
  bool _waitingForWorker = false;
  bool get waitingForWorker => _waitingForWorker;

  /// 이전 버전의 30분 잠금도 만료 뒤에 재개한다. 잠금이 없으면 실행기가 짧게 재확인한다.
  Future<DateTime?> workerLeaseExpiresAt() async {
    final rows = await _store.db.rawQuery(
      "SELECT MAX(until) AS expires FROM leases WHERE name IN ('rebuild','personal_sync')",
    );
    return DateTime.tryParse('${rows.single['expires']}');
  }

  bool get isExecuting => _operation != null;
  bool get stopping => isExecuting && _cancelReason != null;
  bool get countsKnown => job != null;
  DateTime? get lastProgressAt => DateTime.tryParse('${job?['updated_at']}');

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // A detached screen never disposes its running coordinator. Tests/callers
    // may dispose only after completion; retain ownership until work drains.
    if (!isExecuting) {
      _leaseHeartbeat?.cancel();
      _progressTimer?.cancel();
    }
    super.dispose();
  }

  Map<String, Object?>? _job;
  Map<String, Object?>? get job => _job;
  String get state => (_job?['state'] ?? RebuildStates.required) as String;
  bool get isBusy =>
      state == RebuildStates.running ||
      state == RebuildStates.preparingBackup ||
      state == RebuildStates.validating ||
      state == RebuildStates.committing;

  ManifestResult? get manifestFailure =>
      ManifestResult.fromJobError(job?['last_error']);
  bool get waitingForManifest => manifestFailure?.retryable == true;

  String? _notice;
  String? get notice =>
      _notice ??
      manifestFailure?.message ??
      switch (_job?['last_error']) {
        null => null,
        'interrupted' => '이전 초기화가 중단되었습니다. 저장된 자료부터 이어서 진행할 수 있습니다.',
        'user_paused' => '초기화를 일시정지했습니다. 수집한 자료는 보존됩니다.',
        'progress_timeout' => '일정 시간 진행이 없어 중단했습니다. 연결 상태를 확인한 뒤 이어서 진행해 주세요.',
        'gate_required' ||
        'gate_not_fresh' => '계정 또는 공유 연결을 확인하지 못했습니다. 연결 복구 후 이어서 진행해 주세요.',
        'rebuild_lease_lost' => '작업 소유권을 확인하지 못해 중단했습니다. 상태를 다시 확인해 주세요.',
        'backup_missing_or_invalid' =>
          '최초 백업을 확인하지 못해 중단했습니다. 기존 백업과 수집 자료는 유지됩니다.',
        _ => '초기화 작업을 완료하지 못했습니다. 수집한 자료를 유지한 채 다시 시도할 수 있습니다.',
      };

  String _guideKey(Map<String, Object?> s) =>
      '$communityRebuildGuideAckPrefix${s['required_version']}|'
      '${s['local_dataset_id']}|${s['source_account_namespace']}';

  /// 이 범위 키의 안내를 사용자가 이미 확인했는가(2026-10-11 — 안내는 한 번, 다시 불러오기는 백그라운드).
  /// 확인 기록이 없더라도 이미 job 이 있으면(예전 화면에서 시작) 확인한 것으로 본다.
  Future<bool> guideAcknowledged() async {
    final s = await _scope();
    if (await _store.meta(_guideKey(s)) != null) return true;
    final rows = await _store.db.rawQuery(
      'SELECT 1 FROM rebuild_jobs WHERE required_version=? AND local_dataset_id=? AND source_account_namespace=? LIMIT 1',
      [
        s['required_version'],
        s['local_dataset_id'],
        s['source_account_namespace'],
      ],
    );
    return rows.isNotEmpty;
  }

  /// 안내 확인을 기록한다. 개인 DB·job 은 바꾸지 않는다.
  Future<void> acknowledgeGuide() async {
    final s = await _scope();
    await _store.setMeta(_guideKey(s), isoUtc(DateTime.now()));
  }

  Future<Map<String, Object?>> _scope() async => {
    'required_version': communityRebuildRequiredVersion,
    'local_dataset_id': await _localDatasetId(),
    'source_account_namespace': await _sourceNamespace() ?? '',
  };

  /// 새 설치: 개인 DB 에 신고가 없고 이전 DB 를 비운 기록도 없다(2026-09-26 결정 — 처음 실행은 안내 없이 평소대로).
  /// 사실을 주지 않으면(테스트·주입 없음) 새 설치로 보지 않는다.
  Future<bool> _isFreshInstall() async {
    final facts = await _personalDbFacts?.call();
    if (facts == null) return false;
    _legacyReset = facts.legacyReset;
    return facts.reports == 0 && facts.legacyReset == null;
  }

  /// 새 설치: 다시 읽을 기존 신고가 없으니 이 범위 키를 완료로 적는다(빈 목록 완료와 같은 뜻). 첫 수집은 일반 동기화가 한다.
  Future<void> _recordFreshBaseline(Map<String, Object?> s) async {
    final now = isoUtc(DateTime.now());
    await _store.db.insert('rebuild_jobs', {
      'run_id': 'baseline-${DateTime.now().toUtc().millisecondsSinceEpoch}',
      'required_version': s['required_version'],
      'local_dataset_id': s['local_dataset_id'],
      'source_account_namespace': s['source_account_namespace'],
      'state': RebuildStates.completed,
      'phase': 'done',
      'confirmed_at': communityRebuildFreshInstallBaseline,
      'started_at': now,
      'updated_at': now,
      'completed_at': now,
      'list_complete': 1,
      'counts_json': jsonEncode({
        'baseline': communityRebuildFreshInstallBaseline,
      }),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// 초기화 필요 여부. 완료 행이 없으면 필요. 새 설치([_isFreshInstall])는 필요 없음 — 공식 계정이 있으면 그 자리에서
  /// 완료 기준선을 적어, 첫 동기화로 신고가 생긴 뒤에도 다시 필요해지지 않는다(PC community_rebuild.required 와 같은 규칙).
  Future<bool> required() async {
    final s = await _scope();
    final fresh = await _isFreshInstall();
    if ((s['source_account_namespace'] as String).isEmpty && fresh) {
      return false;
    }
    final rows = await _store.db.rawQuery(
      'SELECT state FROM rebuild_jobs WHERE required_version=? AND local_dataset_id=? AND source_account_namespace=?',
      [
        s['required_version'],
        s['local_dataset_id'],
        s['source_account_namespace'],
      ],
    );
    if (rows.any((r) => RebuildStates.terminalOk.contains(r['state']))) {
      return false;
    }
    final active = rows.any(
      (r) => !RebuildStates.inactiveTerminal.contains(r['state']),
    );
    if (!active &&
        fresh &&
        (s['source_account_namespace'] as String).isNotEmpty) {
      await _recordFreshBaseline(s);
      return false;
    }
    return true;
  }

  Future<void> load() async {
    final revision = ++_viewRevision;
    final facts = await _personalDbFacts?.call();
    if (facts != null) _legacyReset = facts.legacyReset;
    final s = isExecuting && _executionScope != null
        ? _executionScope!
        : await _scope();
    final rows = await _store.db.rawQuery(
      'SELECT * FROM rebuild_jobs WHERE required_version=? AND local_dataset_id=? AND source_account_namespace=? ORDER BY updated_at DESC LIMIT 1',
      [
        s['required_version'],
        s['local_dataset_id'],
        s['source_account_namespace'],
      ],
    );
    if (revision != _viewRevision) return;
    final previousAt = _job?['updated_at'];
    final previousCounts = _job?['counts_json'];
    _job = rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
    CommunityRebuildGuard.active =
        _job != null && !RebuildStates.terminalOk.contains(_job!['state']);
    await _readCounts();
    if (RebuildStates.terminalOk.contains(state)) {
      try {
        final pending = await _store.db.rawQuery(
          "SELECT COUNT(*) n FROM outbox o JOIN source_journal j ON j.event_id=o.event_id "
          "WHERE j.rebuild_run_id=? AND o.state IN ('pending','in_flight','retry_wait','auth_required')",
          [_job!['run_id']],
        );
        pendingUploads = pending.single['n'] as int;
      } catch (_) {
        pendingUploads = null;
      }
    }
    if (isExecuting &&
        (previousAt != _job?['updated_at'] ||
            previousCounts != _job?['counts_json'])) {
      _progress();
    }
    notifyListeners();
  }

  String _newRunId() =>
      'run-${DateTime.now().toUtc().millisecondsSinceEpoch}-${(_job == null ? 0 : 1)}';

  Future<void> _readCounts() async {
    final runId = _job?['run_id'];
    final revision = _viewRevision;
    if (runId == null) return;
    final rows = await _store.db.rawQuery(
      'SELECT state, COUNT(*) n FROM rebuild_items WHERE run_id=? GROUP BY state',
      [runId],
    );
    if (revision != _viewRevision || _job?['run_id'] != runId) return;
    final values = counts();
    for (final key in [
      'fetched',
      'failed_permanent',
      'failed_retryable',
      'pending',
    ]) {
      values[key] = 0;
    }
    for (final row in rows) {
      values['${row['state']}'] = row['n'] as int;
    }
    values['listed'] = rows.fold<int>(0, (sum, r) => sum + (r['n'] as int));
    _job = {..._job!, 'counts_json': jsonEncode(values)};
  }

  /// A durable running flag is not proof of a live worker. Never steal a live
  /// lease; old releases may retain it for up to 30 minutes after process death.
  Future<void> refresh() async {
    // Preparation/commit own the model. Poll only the collecting worker; an
    // overlapping read must not invalidate the row being created by start().
    if (_refreshing || (isExecuting && !_collecting)) return;
    _refreshing = true;
    try {
      await load();
      if (isExecuting || _job == null) return;
      _notice = null;
      final runId = _job!['run_id'];
      await _store.transaction((tx) async {
        final leases = await tx.rawQuery(
          "SELECT name FROM leases WHERE name IN ('rebuild','personal_sync') AND until>?",
          [isoUtc(DateTime.now())],
        );
        _waitingForWorker = leases.isNotEmpty;
        if (_waitingForWorker) return;
        // Preserve phase, checkpoint and counts. Completed transactions remain
        // completed; a validating job with explicit gaps still needs consent.
        await tx.rawUpdate(
          "UPDATE rebuild_jobs SET state='paused', last_error='interrupted' "
          "WHERE run_id=? AND state IN ('running','preparing_backup','awaiting_confirmation','committing')",
          [runId],
        );
      });
      await load();
    } catch (_) {
      _notice = '초기화 상태를 읽지 못했습니다. 상태를 다시 확인해 주세요.';
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _assertLease(DatabaseExecutor tx) async {
    if (!_leaseHeld) return;
    final rows = await tx.query(
      'leases',
      where: 'name=? AND owner=? AND until>?',
      whereArgs: ['rebuild', _leaseOwner, isoUtc(DateTime.now())],
    );
    if (rows.isEmpty) throw StateError('rebuild_lease_lost');
  }

  Future<void> _validateScope() async {
    if (_executionGeneration != _scopeGeneration?.call()) {
      throw StateError('rebuild_generation_changed');
    }
    final scope = await _scope();
    if (_executionGeneration != _scopeGeneration?.call() ||
        _executionScope?.entries.any((e) => scope[e.key] != e.value) == true) {
      throw StateError('rebuild_scope_changed');
    }
    await _assertLease(_store.db);
  }

  void _progress() {
    if (_cancelReason == null) _idle.reset();
  }

  Future<void> _save(Map<String, Object?> fields) async {
    final job = _job;
    if (job == null) return;
    _viewRevision++;
    final update = {...fields, 'updated_at': isoUtc(DateTime.now())};
    await _store.transaction((tx) async {
      await _assertLease(tx);
      // Update only owned fields: replacing a stale row erases engine checkpoints.
      await tx.update(
        'rebuild_jobs',
        update,
        where: 'run_id=?',
        whereArgs: [job['run_id']],
      );
    });
    _viewRevision++;
    _job = {...job, ...update};
    CommunityRebuildGuard.active = !RebuildStates.terminalOk.contains(state);
    _progress();
    notifyListeners();
  }

  Future<bool> start({required String confirmedBy}) =>
      _begin(confirmedBy: confirmedBy);

  Future<void> resume() async {
    await _begin(confirmedBy: 'resume');
  }

  Future<void> acceptGaps() async {
    await _begin(confirmedBy: 'user', acceptGaps: true);
  }

  Future<bool> _begin({required String confirmedBy, bool acceptGaps = false}) {
    if (_operation != null) return _operation!;
    _cancelReason = null;
    // Set the single-flight future before any callback or database await.
    // 백그라운드 작업으로 등록한다: 진행 중(백업·수집·반영 전 단계)에는 DB 백업·복원·서버 DB 가져오기·신고 지우기가
    // 기존 규칙(`DbBusyException`)으로 거절되고, 그런 파일 교체가 진행 중이면 끝날 때까지 시작하지 않는다(무결성 §3-1).
    final operation = Future<bool>.microtask(
      () => LocalDbService.runBackgroundWork(
        () => _execute(confirmedBy, acceptGaps),
      ),
    );
    _operation = operation;
    notifyListeners();
    return operation;
  }

  Future<bool> _execute(String confirmedBy, bool acceptGaps) async {
    _notice = null;
    _leaseLost = false;
    _waitingForWorker = false;
    _executionGeneration = _scopeGeneration?.call();
    _idle
      ..reset()
      ..start();
    _progressTimer = Timer.periodic(pollInterval, (_) {
      final limit = state == RebuildStates.preparingBackup
          ? const Duration(minutes: 15)
          : stallTimeout;
      if (_idle.elapsed >= limit && _cancelReason == null) {
        requestPause('progress_timeout');
      }
      unawaited(refresh());
    });
    var admitted = false;
    try {
      _executionScope = await _scope();
      return await SyncOperationAdmission.run(
        () async {
          admitted = true;
          if (!await _store.acquireLease(
            'rebuild',
            _leaseOwner,
            const Duration(minutes: 2),
          )) {
            _waitingForWorker = true;
            _notice = '다른 작업의 종료를 확인하고 있습니다. 잠시 후 상태를 다시 확인해 주세요.';
            return false;
          }
          _leaseHeld = true;
          _startLeaseHeartbeat();
          await load();
          if (RebuildStates.terminalOk.contains(state)) return true;
          await SyncOperationAdmission.checkOwnership();
          ManifestResult gateResult;
          try {
            final checkGate =
                _gateCheck ?? CommunityUploadHooks.rebuildGateCheck;
            gateResult =
                await (checkGate != null
                        ? checkGate()
                        : _gateFresh().then(
                            (ok) => ManifestResult(
                              ok ? ManifestStatus.ok : ManifestStatus.auth,
                            ),
                          ))
                    .timeout(const Duration(seconds: 45));
          } catch (_) {
            gateResult = const ManifestResult(ManifestStatus.network);
          }
          if (!gateResult.isOk) {
            await _saveManifestFailure(gateResult);
            return false;
          }
          await SyncOperationAdmission.checkOwnership();
          if (acceptGaps) {
            if (state != RebuildStates.validating) return false;
            await _commit(finishedWithGaps: true);
          } else {
            // A validated checkpoint resumes validation, without fetching or
            // replacing the initial backup. Gaps remain explicitly user-confirmed.
            final validateOnly =
                _job?['list_complete'] == 1 &&
                (state == RebuildStates.validating ||
                    state == RebuildStates.committing ||
                    const {
                      'validate',
                      'commit',
                      'committing',
                    }.contains(_job?['phase']));
            if (validateOnly) {
              await _finishCollected(await _storedOutcome());
            } else {
              ManifestResult manifestResult;
              try {
                manifestResult = await _manifestCheck().timeout(
                  const Duration(minutes: 2),
                );
              } catch (_) {
                manifestResult = const ManifestResult(ManifestStatus.network);
              }
              await SyncOperationAdmission.checkOwnership();
              if (!manifestResult.isOk) {
                await _saveManifestFailure(manifestResult);
                return false;
              }
              await SyncOperationAdmission.checkOwnership();
              if (_job == null || state == 'abandoned') await _insertRow();
              await _save({
                'state': RebuildStates.awaitingConfirmation,
                'confirmed_at': _job?['confirmed_at'] ?? isoUtc(DateTime.now()),
                'last_error': null,
              });
              await _runToCompletion();
            }
          }
          return RebuildStates.terminalOk.contains(state);
        },
        false,
        openStore: () async => _store,
        // 모드 전환 등이 DB 연결 닫기를 요청하면 다음 확인 지점에서 멈춘다(같은 run 은 다음 실행 때 이어서).
        stopRequested: () =>
            _cancelReason != null ||
            _leaseLost ||
            LocalDbService.closeRequested,
        validateScope: _validateScope,
        onProgress: _progress,
      );
    } catch (e) {
      if (_leaseHeld && _job != null) {
        try {
          await _ensureRow(
            state: RebuildStates.paused,
            error: _cancelReason ?? (_leaseLost ? 'rebuild_lease_lost' : '$e'),
          );
        } catch (_) {
          _notice = '작업 소유권 또는 저장소를 확인하지 못했습니다. 상태를 다시 확인해 주세요.';
        }
      } else {
        _notice = '초기화를 시작하지 못했습니다. 상태를 다시 확인해 주세요.';
      }
      return false;
    } finally {
      _progressTimer?.cancel();
      _leaseHeartbeat?.cancel();
      _idle.stop();
      if (_leaseHeld) {
        try {
          await _store.releaseLease('rebuild', _leaseOwner);
        } catch (_) {}
      }
      _leaseHeld = false;
      _operation = null;
      if (!admitted) {
        _waitingForWorker = true;
        _notice = '다른 동기화 작업의 종료를 확인하고 있습니다. 잠시 후 상태를 다시 확인해 주세요.';
      }
      if (_cancelReason != null && state == RebuildStates.paused) {
        _notice = null;
      }
      if (!RebuildStates.terminalOk.contains(state) &&
          _notice == null &&
          _job == null) {
        _notice = '다른 동기화 작업이 끝난 뒤 다시 시도해 주세요.';
      }
      notifyListeners();
    }
  }

  Future<void> _saveManifestFailure(ManifestResult result) async {
    await _ensureRow(
      state: result.retryable
          ? RebuildStates.waitingRetry
          : RebuildStates.prerequisitesRequired,
      error: result.jobError,
    );
    await _store.setMeta(
      'rebuild_manifest:${_job!['run_id']}',
      jsonEncode(result.diagnostics),
    );
  }

  /// Do not publish paused until the old future drains. Late responses cannot
  /// become a second writer, and the UI keeps saying "중단 확인 중" meanwhile.
  void requestPause([String reason = 'user_paused']) {
    if (!isExecuting || _cancelReason != null) return;
    _cancelReason = reason;
    _notice = reason == 'progress_timeout'
        ? '일정 시간 진행이 없어 중단을 요청했습니다. 현재 작업의 종료를 확인하고 있습니다.'
        : '중단을 요청했습니다. 현재 작업의 종료를 확인하고 있습니다.';
    if (_collecting) _engine.cancel();
    notifyListeners();
  }

  Future<void> pause(String reason) async {
    await _save({'state': RebuildStates.paused, 'last_error': reason});
  }

  void _startLeaseHeartbeat() {
    _leaseHeartbeat?.cancel();
    _leaseHeartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        if (await _store.renewLease(
          'rebuild',
          _leaseOwner,
          const Duration(minutes: 2),
        )) {
          return;
        }
      } catch (_) {}
      _leaseLost = true;
      requestPause('rebuild_lease_lost');
    });
  }

  Future<RebuildRunOutcome> _storedOutcome() async {
    final runId = _job!['run_id'];
    await _readCounts();
    final gaps = await _store.db.query(
      'rebuild_items',
      columns: ['source_report_id'],
      where: 'run_id=? AND state=?',
      whereArgs: [runId, 'failed_permanent'],
    );
    return RebuildRunOutcome(
      listComplete: _job?['list_complete'] == 1,
      fetched: counts()['fetched'] ?? 0,
      permanentFailures: [
        for (final row in gaps) row['source_report_id'] as String,
      ],
      orphanCount: counts()['orphan_preserved'] ?? 0,
    );
  }

  Future<void> _runToCompletion() async {
    final runId = _job!['run_id'] as String;
    // 백업.
    await _save({'state': RebuildStates.preparingBackup, 'phase': 'backup'});
    final backup = await _doBackup(runId);
    await SyncOperationAdmission.checkOwnership();
    if (!backup.ok) {
      await _save({
        'state': RebuildStates.failed,
        'last_error': backup.error ?? 'backup_failed',
      });
      _notice = '백업을 만들지 못해 시작하지 않았습니다. 저장 공간을 확인해 주세요.';
      notifyListeners();
      return;
    }
    await _save({'backup_ref': backup.ref, 'backup_check': backup.check});
    // 실행.
    await _save({
      'state': RebuildStates.running,
      'phase': 'collect',
      'list_complete': 0,
      'started_at': _job?['started_at'] ?? isoUtc(DateTime.now()),
    });
    late final RebuildRunOutcome outcome;
    try {
      _collecting = true;
      try {
        outcome = await _engine.run(runId: runId);
      } finally {
        _collecting = false;
        _viewRevision++; // Discard a polling read still in flight.
      }
      await SyncOperationAdmission.checkOwnership();
    } catch (e) {
      if (_cancelReason != null || _leaseLost) rethrow;
      final msg = '$e';
      if (msg.contains('paused') ||
          msg.contains('revoked') ||
          msg.contains('logout')) {
        await _save({'state': RebuildStates.paused, 'last_error': msg});
      } else {
        await _save({'state': RebuildStates.failed, 'last_error': msg});
      }
      notifyListeners();
      return;
    }
    await _finishCollected(outcome);
  }

  Future<void> _finishCollected(RebuildRunOutcome outcome) async {
    await SyncOperationAdmission.checkOwnership();
    final runId = _job!['run_id'] as String;
    if (!outcome.listComplete) {
      await _save({
        'state': RebuildStates.failed,
        'last_error': 'list_incomplete',
      });
      _notice = '전체 신고 확인에 실패했습니다. 다시 시도해 주세요.';
      notifyListeners();
      return;
    }
    final unfinished = await _store.db.rawQuery(
      "SELECT COUNT(*) AS n FROM rebuild_items WHERE run_id=? AND state NOT IN ('fetched','failed_permanent')",
      [runId],
    );
    if (unfinished.single['n'] != 0) {
      await _save({
        'state': RebuildStates.paused,
        'last_error': 'rebuild_items_pending',
      });
      _notice = '다시 시도할 신고가 남아 있습니다. 재개하면 이어서 수집합니다.';
      notifyListeners();
      return;
    }
    await _store.setMeta(
      'rebuild_offered_gaps:$runId',
      jsonEncode(outcome.permanentFailures.toList()..sort()),
    );
    await _save({
      'state': RebuildStates.validating,
      'phase': 'validate',
      'list_complete': 1,
      'counts_json': jsonEncode({
        'fetched': outcome.fetched,
        'orphan_preserved': outcome.orphanCount,
        'failed_permanent': outcome.permanentFailures.length,
      }),
    });
    if (outcome.permanentFailures.isNotEmpty) {
      _notice =
          '가져오지 못한 신고 ${outcome.permanentFailures.length}건이 있습니다. 확인 뒤 계속할 수 있습니다.';
      notifyListeners();
      return;
    }
    await _commit(finishedWithGaps: false);
  }

  Future<void> _commit({required bool finishedWithGaps}) async {
    final generation = _scopeGeneration?.call();
    await SyncOperationAdmission.checkOwnership();
    final runId = _job!['run_id'] as String;
    if (!await _gateFresh().timeout(const Duration(seconds: 45))) {
      await pause('gate_not_fresh');
      return;
    }
    final scope = await _scope();
    await SyncOperationAdmission.checkOwnership();
    try {
      await _store.transaction((tx) async {
        await SyncOperationAdmission.checkOwnership(executor: tx);
        if (generation != _scopeGeneration?.call()) {
          throw StateError('rebuild_generation_changed');
        }
        final rows = await tx.query(
          'rebuild_jobs',
          where: 'run_id=?',
          whereArgs: [runId],
        );
        if (rows.length != 1) throw StateError('rebuild_job_missing');
        final job = rows.single;
        if (job['list_complete'] != 1 ||
            job['state'] != RebuildStates.validating ||
            job['local_dataset_id'] != scope['local_dataset_id'] ||
            job['source_account_namespace'] !=
                scope['source_account_namespace'] ||
            await _store.meta('local_dataset_id', tx) !=
                scope['local_dataset_id']) {
          throw StateError('rebuild_scope_or_state_changed');
        }
        final lease = await tx.query(
          'leases',
          where: 'name=? AND owner=? AND until>?',
          whereArgs: ['rebuild', _leaseOwner, isoUtc(DateTime.now())],
        );
        if (lease.isEmpty) throw StateError('rebuild_lease_lost');
        final pending = await tx.rawQuery(
          "SELECT COUNT(*) n FROM rebuild_items WHERE run_id=? AND state NOT IN ('fetched','failed_permanent')",
          [runId],
        );
        if (pending.single['n'] != 0) throw StateError('rebuild_items_pending');
        final gaps = await tx.rawQuery(
          "SELECT source_report_id FROM rebuild_items WHERE run_id=? AND state='failed_permanent' ORDER BY source_report_id",
          [runId],
        );
        final ids = gaps.map((r) => r['source_report_id']).toList();
        final offered = jsonDecode(
          await _store.meta('rebuild_offered_gaps:$runId', tx) ?? '[]',
        );
        if ((!finishedWithGaps && ids.isNotEmpty) ||
            (finishedWithGaps &&
                (ids.isEmpty || jsonEncode(ids) != jsonEncode(offered)))) {
          throw StateError('rebuild_gaps_changed');
        }
        final dangling = await tx.rawQuery(
          "SELECT COUNT(*) n FROM rebuild_items i LEFT JOIN report_latest_staging s ON s.run_id=i.run_id AND s.source_report_id=i.source_report_id LEFT JOIN source_journal j ON j.event_id=s.event_id WHERE i.run_id=? AND i.state='fetched' AND ((s.source_report_id IS NOT NULL AND j.event_id IS NULL) OR (s.source_report_id IS NULL AND NOT EXISTS (SELECT 1 FROM detail_status ds WHERE ds.local_dataset_id=? AND ds.source_report_id=i.source_report_id)))",
          [runId, scope['local_dataset_id']],
        );
        if (dangling.single['n'] != 0) {
          throw StateError('rebuild_staging_incomplete');
        }
        if (generation != _scopeGeneration?.call()) {
          throw StateError('rebuild_generation_changed');
        }
        await mergeRebuildStaging(runId, store: _store, executor: tx);
        final now = isoUtc(DateTime.now());
        await tx.update(
          'rebuild_jobs',
          {
            'state': finishedWithGaps
                ? RebuildStates.completedWithGaps
                : RebuildStates.completed,
            'phase': 'done',
            'completed_at': now,
            'updated_at': now,
            if (finishedWithGaps) 'gaps_accepted_at': now,
          },
          where: 'run_id=?',
          whereArgs: [runId],
        );
      });
      await load();
      _notice = null;
    } catch (e) {
      await pause('$e');
      _notice = '수집 결과를 확정하지 못했습니다. 기존 자료는 유지됩니다. 재개해 주세요.';
    }
    notifyListeners();
  }

  Future<RebuildBackupResult> _doBackup(String runId) async {
    final original = _job?['backup_ref'] as String?;
    if (original != null && _job?['backup_check'] == 'ok') {
      if (_backupOverride != null || await _validBackup(original)) {
        return RebuildBackupResult(ok: true, ref: original, check: 'ok');
      }
      return const RebuildBackupResult(
        ok: false,
        error: 'backup_missing_or_invalid',
      );
    }
    final backupOverride = _backupOverride;
    if (backupOverride != null) {
      try {
        return await backupOverride(runId);
      } catch (e) {
        return RebuildBackupResult(ok: false, error: '$e');
      }
    }
    try {
      final personalPath = await _personalDbPath?.call();
      if (personalPath == null || personalPath.isEmpty) {
        return const RebuildBackupResult(ok: false, error: 'no_personal_db');
      }
      final dir = p.join(p.dirname(personalPath), 'backups');
      await Directory(dir).create(recursive: true);
      final dest = p.join(dir, 'pre-rebuild-$runId.db');
      // Recover a completed snapshot whose job update was interrupted. Never
      // overwrite it with an already partially rebuilt personal database.
      if (await File(dest).exists()) {
        return await _validBackup(dest)
            ? RebuildBackupResult(ok: true, ref: dest, check: 'ok')
            : const RebuildBackupResult(
                ok: false,
                error: 'backup_missing_or_invalid',
              );
      }
      final temporary = '$dest.${newUuidV4()}.tmp';
      try {
        await LocalDbService.copyDatabaseConsistent(personalPath, temporary);
        await SyncOperationAdmission.protectWrite(() async {
          if (await File(dest).exists()) {
            throw StateError('backup_already_exists');
          }
          await File(temporary).rename(dest);
        });
      } catch (e) {
        return RebuildBackupResult(ok: false, error: 'backup_failed: $e');
      }
      return RebuildBackupResult(ok: true, ref: dest, check: 'ok');
    } catch (e) {
      return RebuildBackupResult(ok: false, error: '$e');
    }
  }

  Future<bool> _validBackup(String path) async {
    if (!await File(path).exists()) return false;
    Database? copy;
    try {
      copy = await openAppDatabase(path, readOnly: true);
      final result = await copy.rawQuery('PRAGMA integrity_check');
      return result.length == 1 && result.single.values.single == 'ok';
    } catch (_) {
      return false;
    } finally {
      await copy?.close();
    }
  }

  Future<void> _insertRow() async {
    final s = await _scope();
    final runId = _newRunId();
    final row = {
      'run_id': runId,
      'required_version': s['required_version'],
      'local_dataset_id': s['local_dataset_id'],
      'source_account_namespace': s['source_account_namespace'],
      'state': RebuildStates.required,
      'updated_at': isoUtc(DateTime.now()),
      'list_complete': 0,
      'counts_json': '{}',
    };
    await _store.db.insert(
      'rebuild_jobs',
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await load();
  }

  Future<void> _ensureRow({required String state, String? error}) async {
    if (_job == null) {
      await _insertRow();
    }
    await _save({'state': state, 'last_error': ?error});
  }

  /// 진행 표시용 건수.
  Map<String, int> counts() {
    try {
      final json = jsonDecode((_job?['counts_json'] ?? '{}') as String) as Map;
      return json.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0));
    } catch (_) {
      return {};
    }
  }
}
