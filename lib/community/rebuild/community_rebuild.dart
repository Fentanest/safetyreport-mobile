import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../services/sync_engine.dart';
import '../community_store.dart';
import '../upload_hooks.dart';
import '../capture/rebuild_helpers.dart';

/// 1회 초기화 크롤링 범위 키 (`contracts/community-ingest/rebuild.md`).
const String communityRebuildRequiredVersion = 'source-rebuild-2026-09-26.1';

/// 상태기계 상태 (`rebuild.md`).
abstract class RebuildStates {
  static const required = 'required';
  static const prerequisitesRequired = 'prerequisites_required';
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

/// 초기화 안내 기준 문구 (`rebuild.md`).
const String communityRebuildGuideText =
    '이번 업데이트에서는 신고 데이터 저장 구조가 변경되어 초기화 크롤링을 한 번 진행해야 합니다. '
    '확인을 누르면 안전신문고에서 신고 내역을 다시 수집하고 새 저장 구조를 구성합니다. '
    '신고내용 공유에는 이번에 수집한 사용자 수정 전 값이 사용됩니다.';

const String communityRebuildPreservedText =
    '보존 항목: 관리자·공식 계정 설정, 커뮤니티 연결·동의, 앱 설정, 수정한 값·메모·감시목록·중복 판단, '
    '지오코딩 캐시, 업로드 대기 자료. 시작 전 자동 백업을 만듭니다.';

/// 초기화 필요·진행 중 전역 가드. 수동·자동 동기화 시작点에서 확인한다.
class CommunityRebuildGuard {
  CommunityRebuildGuard._();
  static bool active = false;
  static const String blockedMessage = '초기화 크롤링이 필요합니다. 먼저 초기화 크롤링을 완료해 주세요.';
}

/// 실제 수집 엔진 자리. 기본값은 `SyncEngine.start(fullSync: true)` — T6 가
/// `start(fullSync:rebuildRunId:)` 시그니처를 제공하면 그 호출로 교체한다(REQUESTS.md).
class RebuildEngine {
  const RebuildEngine();

  /// rebuild 모드 전체 수집(T6): 목록 부재 행을 지우지 않고 rebuild_items 에 checkpoint 를 남긴다.
  /// 실패(목록 일부 실패·로그인 실패 포함)는 성공으로 보지 않는다(G12).
  Future<RebuildRunOutcome> run({required String runId}) async {
    final result = await SyncEngine.start(fullSync: true, rebuildRunId: runId);
    if (result.failed) {
      throw StateError(result.errorMessage ?? 'rebuild_sync_failed');
    }
    final store = await CommunityStore.open();
    final permanent = await store.db.rawQuery(
      "SELECT source_report_id FROM rebuild_items WHERE run_id=? AND state='failed_permanent'", [runId]);
    final listed = await store.db.rawQuery('SELECT list_complete FROM rebuild_jobs WHERE run_id=?', [runId]);
    return RebuildRunOutcome(
      listComplete: listed.isNotEmpty && listed.first['list_complete'] == 1,
      fetched: result.done,
      permanentFailures: [for (final r in permanent) r['source_report_id'] as String],
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
  const RebuildBackupResult({required this.ok, this.ref, this.check, this.error});
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
    Future<bool> Function()? manifestCheck,
    Future<String> Function()? personalDbPath,
  })  : _store = store,
        _localDatasetId = localDatasetId,
        _sourceNamespace = sourceNamespace,
        _gateFresh = gateFresh,
        _engine = engine,
        _backupOverride = backup,
        _manifestCheck = manifestCheck ?? CommunityUploadHooks.refreshServerCompletedNow,
        _personalDbPath = personalDbPath;

  final CommunityStore _store;
  final Future<String> Function() _localDatasetId;
  final Future<String?> Function() _sourceNamespace;
  final Future<bool> Function() _gateFresh;
  final RebuildEngine _engine;
  final Future<RebuildBackupResult> Function(String runId)? _backupOverride;
  final Future<bool> Function() _manifestCheck;
  final Future<String> Function()? _personalDbPath;

  Map<String, Object?>? _job;
  Map<String, Object?>? get job => _job;
  String get state => (_job?['state'] ?? RebuildStates.required) as String;
  bool get isBusy =>
      state == RebuildStates.running ||
      state == RebuildStates.preparingBackup ||
      state == RebuildStates.validating ||
      state == RebuildStates.committing;

  String? _notice;
  String? get notice => _notice;

  Future<Map<String, Object?>> _scope() async => {
        'required_version': communityRebuildRequiredVersion,
        'local_dataset_id': await _localDatasetId(),
        'source_account_namespace': await _sourceNamespace() ?? '',
      };

  /// 초기화 필요 여부. 완료 행이 없으면 필요.
  Future<bool> required() async {
    final s = await _scope();
    final rows = await _store.db.rawQuery(
      'SELECT state FROM rebuild_jobs WHERE required_version=? AND local_dataset_id=? AND source_account_namespace=?',
      [s['required_version'], s['local_dataset_id'], s['source_account_namespace']],
    );
    if (rows.isEmpty) return true;
    return rows.every((r) => !RebuildStates.terminalOk.contains(r['state']));
  }

  Future<void> load() async {
    final s = await _scope();
    final rows = await _store.db.rawQuery(
      'SELECT * FROM rebuild_jobs WHERE required_version=? AND local_dataset_id=? AND source_account_namespace=? ORDER BY updated_at DESC LIMIT 1',
      [s['required_version'], s['local_dataset_id'], s['source_account_namespace']],
    );
    _job = rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
    CommunityRebuildGuard.active = _job != null && !RebuildStates.terminalOk.contains(_job!['state']);
    notifyListeners();
  }

  String _newRunId() =>
      'run-${DateTime.now().toUtc().millisecondsSinceEpoch}-${(_job == null ? 0 : 1)}';

  Future<void> _save(Map<String, Object?> fields) async {
    final job = _job;
    if (job == null) return;
    final row = Map<String, Object?>.from(job)..addAll(fields);
    row['updated_at'] = isoUtc(DateTime.now());
    await _store.db.insert('rebuild_jobs', row, conflictAlgorithm: ConflictAlgorithm.replace);
    _job = row;
    CommunityRebuildGuard.active = !RebuildStates.terminalOk.contains(row['state']);
    notifyListeners();
  }

  /// 확인 — 초기화 크롤링 시작. 같은 run 이 있으면 재개한다.
  Future<bool> start({required String confirmedBy}) async {
    await load();
    if (_job != null &&
        !RebuildStates.terminalOk.contains(_job!['state']) &&
        _job!['state'] != RebuildStates.required &&
        _job!['state'] != RebuildStates.prerequisitesRequired &&
        _job!['state'] != RebuildStates.awaitingConfirmation &&
        _job!['state'] != RebuildStates.failed &&
        _job!['state'] != RebuildStates.paused) {
      return true;
    }
    final gateOk = await _gateFresh();
    if (!gateOk) {
      await _ensureRow(state: RebuildStates.prerequisitesRequired, error: 'gate_required');
      _notice = '카카오 인증과 신고내용 공유 동의가 필요합니다.';
      notifyListeners();
      return false;
    }
    final manifestOk = await _manifestCheck();
    if (!manifestOk) {
      await _ensureRow(
        state: RebuildStates.prerequisitesRequired,
        error: 'manifest_unavailable',
      );
      _notice = '중앙 공유 목록을 확인하지 못했습니다. 다시 시도해 주세요.';
      notifyListeners();
      return false;
    }
    final leaseOk = await _store.acquireLease('rebuild', 'mobile', const Duration(minutes: 30));
    if (!leaseOk) {
      await load();
      return true;
    }
    try {
      if (_job == null ||
          RebuildStates.terminalOk.contains(_job!['state']) ||
          _job!['state'] == 'abandoned') {
        await _insertRow();
      }
      await _save({
        'state': RebuildStates.awaitingConfirmation,
        'confirmed_at': isoUtc(DateTime.now()),
      });
      await _runToCompletion();
      return state == RebuildStates.completed || state == RebuildStates.completedWithGaps;
    } finally {
      await _store.releaseLease('rebuild', 'mobile');
    }
  }

  Future<void> resume() async {
    await load();
    if (_job == null || RebuildStates.terminalOk.contains(_job!['state'])) return;
    final gateOk = await _gateFresh();
    if (!gateOk) {
      await _save({}..['state'] = RebuildStates.paused);
      _notice = '카카오 인증과 신고내용 공유 동의가 필요합니다.';
      notifyListeners();
      return;
    }
    final leaseOk = await _store.acquireLease('rebuild', 'mobile', const Duration(minutes: 30));
    if (!leaseOk) return;
    try {
      await _runToCompletion(resumed: true);
    } finally {
      await _store.releaseLease('rebuild', 'mobile');
    }
  }

  Future<void> pause(String reason) async {
    await _save({'state': RebuildStates.paused, 'last_error': reason});
  }

  /// 영구 누락 N건을 사용자가 수락 → completed_with_gaps.
  Future<void> acceptGaps() async {
    await _save({
      'state': RebuildStates.committing,
      'gaps_accepted_at': isoUtc(DateTime.now()),
    });
    await _commit(finishedWithGaps: true);
  }

  Future<void> _runToCompletion({bool resumed = false}) async {
    final runId = _job!['run_id'] as String;
    // 백업.
    await _save({'state': RebuildStates.preparingBackup, 'phase': 'backup'});
    final backup = await _doBackup(runId);
    if (!backup.ok) {
      await _save({
        'state': RebuildStates.failed,
        'last_error': backup.error ?? 'backup_failed',
      });
      _notice = '백업을 만들지 못해 시작하지 않았습니다. 저장 공간을 확인해 주세요.';
      notifyListeners();
      return;
    }
    await _save({
      'backup_ref': backup.ref,
      'backup_check': backup.check,
    });
    // 실행.
    await _save({'state': RebuildStates.running, 'phase': 'collect', 'started_at': isoUtc(DateTime.now())});
    late final RebuildRunOutcome outcome;
    try {
      outcome = await _engine.run(runId: runId);
    } catch (e) {
      final msg = '$e';
      if (msg.contains('paused') || msg.contains('revoked') || msg.contains('logout')) {
        await _save({'state': RebuildStates.paused, 'last_error': msg});
      } else {
        await _save({'state': RebuildStates.failed, 'last_error': msg});
      }
      notifyListeners();
      return;
    }
    if (!outcome.listComplete) {
      await _save({'state': RebuildStates.failed, 'last_error': 'list_incomplete'});
      _notice = '전체 신고 확인에 실패했습니다. 다시 시도해 주세요.';
      notifyListeners();
      return;
    }
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
      _notice = '가져오지 못한 신고 ${outcome.permanentFailures.length}건이 있습니다. 확인 뒤 계속할 수 있습니다.';
      notifyListeners();
      return;
    }
    await _commit(finishedWithGaps: false);
  }

  Future<void> _commit({required bool finishedWithGaps}) async {
    await _save({'state': RebuildStates.committing, 'phase': 'commit'});
    // T6 병합 함수 하나로(PC 와 같은 규칙): staging → report_latest upsert, 삭제 없음, source_generation 증가.
    await mergeRebuildStaging(_job!['run_id'] as String, store: _store);
    await _save({
      'state': finishedWithGaps ? RebuildStates.completedWithGaps : RebuildStates.completed,
      'phase': 'done',
      'completed_at': isoUtc(DateTime.now()),
    });
    _notice = null;
    notifyListeners();
  }

  Future<RebuildBackupResult> _doBackup(String runId) async {
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
      final db = await openDatabase(personalPath, singleInstance: false);
      try {
        final escaped = dest.replaceAll("'", "''");
        await db.rawQuery("VACUUM INTO '$escaped'");
        final check = await db.rawQuery('PRAGMA integrity_check');
        final ok = check.isNotEmpty && (check.first.values.first as String) == 'ok';
        if (!ok) {
          try {
            await File(dest).delete();
          } catch (_) {}
          return const RebuildBackupResult(ok: false, error: 'integrity_check_failed');
        }
        return RebuildBackupResult(ok: true, ref: dest, check: 'ok');
      } finally {
        await db.close();
      }
    } catch (e) {
      return RebuildBackupResult(ok: false, error: '$e');
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
    await _store.db.insert('rebuild_jobs', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    await load();
  }

  Future<void> _ensureRow({required String state, String? error}) async {
    if (_job == null) {
      await _insertRow();
    }
    await _save({'state': state, if (error != null) 'last_error': error});
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
