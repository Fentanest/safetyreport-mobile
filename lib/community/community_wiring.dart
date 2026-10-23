import 'manifest_result.dart';
import 'consent_catchup.dart';
import 'raw_backfill_runtime.dart';
import 'soft_reset.dart';
import '../services/maintenance_service.dart';
// T5(게이트·초기화) ↔ T6(capture·업로드) 연결 (통합, `contracts/community-ingest/interfaces.md`).
//
// main.dart 가 게이트를 만든 직후 한 번 호출한다. 병렬 작업 중 비어 있던 자리를 실제 구현으로 채우고,
// 연결이 없을 때 통과하던 경로(fail-open)를 막는다.
import 'dart:async';

import '../services/community_auth_config.dart';
import '../services/community_auth_service.dart';
import '../services/sync_engine.dart';
import 'capture/fine_estimate_resend.dart';
import 'capture/server_completed.dart' as completed;
import 'community_store.dart';
import 'gate/community_gate.dart';
import 'upload/community_ingest_client.dart';
import 'upload/community_schedule.dart' as schedule;
import 'upload/community_uploader.dart';
import 'upload/upload_controller.dart';
import 'upload/upload_defaults.dart';
import 'upload_hooks.dart';
import 'upload_pause.dart';
import 'update_requirement.dart';
import 'backfill_progress.dart';
import 'package:flutter/foundation.dart' show VoidCallback;

/// 포그라운드 uploader 용 게이트 어댑터: 새 작업은 60초 이내 재검증(plan §6.1).
class LiveGateCheck
    implements
        CommunityGateCheck,
        CommunityGenerationFence,
        CommunityScopeFence {
  @override
  Object get generation => gate.generation;
  @override
  String? get contributorFingerprint =>
      gate.canEnter ? gate.lastStatus?.fingerprint : null;
  LiveGateCheck(this.gate);
  final CommunityGate gate;

  @override
  Future<bool> requireFresh() async => (await gate.requireFresh()).canEnter;

  @override
  String? get blockedState => gate.canEnter ? null : gate.state.state;

  @override
  void invalidate(String reason) => gate.invalidate(reason);
}

class CommunityWiring {
  CommunityWiring._();

  static CommunityGate? gate;

  /// 포그라운드에서 쓸 게이트 확인. 게이트가 없으면(백그라운드 isolate) 캐시 판정.
  static CommunityGateCheck gateCheck() {
    final g = gate;
    return g == null ? schedule.CacheGateCheck() : LiveGateCheck(g);
  }

  static void wire({
    required CommunityGate communityGate,
    required CommunityStore store,
  }) {
    gate = communityGate;
    unawaited(
      CommunityReset.pending(store).then((pending) {
        if (pending != null) {
          CommunityReset.resumePending(store);
          unawaited(CommunityReset.attempt(store));
        }
      }),
    );
    CommunityUploadHooks.refreshManifestResult = () => refreshManifest(store);
    CommunityUploadHooks.rebuildGateCheck = () async {
      final state = await communityGate.refreshNow(silent: true);
      return state.canEnter
          ? const ManifestResult(ManifestStatus.ok)
          : ManifestResult(
              ManifestResult.statusForCode(state.state),
              serverCode: state.state,
            );
    };
    CommunityUploadHooks.refreshServerCompleted = () async =>
        (await refreshManifest(store)).isOk;
    SyncEngine.ensureManifestFresh = () async =>
        (await refreshManifest(store)).isOk;
    // Standalone writer(데모 제외)로 게이트를 통과했을 때만 불린다(ReportProvider.onGatePassed).
    CommunityUploadHooks.registerBackgroundJobs = () async {
      MaintenanceService.resumeForAccount();
      await schedule.registerBackgroundJobs();
      await RawBackfillRuntime.start(
        store,
        () async => (await communityGate.requireFresh()).canEnter,
      );
      // 진행 보고(4-1) ① 앱 시작·게이트 통과 뒤 1회 + 사용자 조치 알림 판단(8절).
      unawaited(BackfillProgress.report(store, start: true));
      // 업로더의 배치별 진행 문구는 동기화 로그에 싣지 않는다 — 동기화가 10건 단위로 'N/M건 전송'을 따로 적는다.
      CommunityUploadController.instance.start(
        () => buildDefaultUploader(gate: gateCheck()),
      );
    };
    CommunityUploadHooks.cancelBackgroundJobs = () async {
      RawBackfillRuntime.stop();
      CommunityUploadController.instance.stop();
      await schedule.cancelBackgroundJobs();
    };
    CommunityUploadHooks.wakeUpload = CommunityUploadController.instance.wake;
    // 재개 시각이 지났는데 중지로 남았을 때 업로더가 한 번 부르는 status 확인(D4) = 조용한 게이트 갱신.
    UploadPause.statusProbe = () async {
      await communityGate.refreshNow(silent: true);
    };
    // 점검이 끝났거나(업로드 일시 중지 해제) 필수 버전 잠금이 풀리면 업로더·1회 전송을 곧바로 깨운다.
    _pauseListener ??= () {
      final paused = UploadPause.current.value != null;
      if (_wasPaused && !paused) _resume('maintenance_over');
      _wasPaused = paused;
    };
    _lockListener ??= () {
      final locked = UpdateRequirement.current.value.locked;
      if (_wasLocked && !locked) _resume('update_lock_released');
      _wasLocked = locked;
    };
    _wasPaused = UploadPause.current.value != null;
    _wasLocked = UpdateRequirement.current.value.locked;
    UploadPause.current.addListener(_pauseListener!);
    UpdateRequirement.current.addListener(_lockListener!);
    CommunityUploadHooks.uploadBeforeSync = () async {
      final uploader = await buildDefaultUploader(gate: gateCheck());
      final run = await uploader.requestCommunityUpload('recovery');
      final status = await uploader.uploadStatus();
      return (run: run, remaining: status.pending + status.authRequired);
    };
    CommunityUploadHooks.catchUp = (reason) async {
      final uploader = await buildDefaultUploader(gate: gateCheck());
      await schedule.catchUp(
        reason,
        store: store,
        runUpload: uploader.requestCommunityUpload,
      );
      await ConsentCatchup(store).run(
        verify: () async => (await communityGate.requireFresh()).canEnter,
        manifest: () async => (await refreshManifest(store)).isOk,
        collectAll: () async {
          final ctx = await store.activeContext();
          if (ctx == null) return false;
          final result = await SyncEngine.start(
            fullSync: true,
            preserveDataset: true,
            catchupKey: ConsentCatchup.jobKey(ctx),
          );
          return !result.failed && !result.busy && !result.cancelled;
        },
      );
      await RawBackfillRuntime.run(
        store: store,
        verify: () async => (await communityGate.requireFresh()).canEnter,
      );
      CommunityUploadController.instance.wake('recovery');
    };
    CommunityUploadHooks.resendFineEstimate = () =>
        resendFineEstimateIfNeeded(store: store);
    CommunityUploadHooks.onContributionsDeleted = () =>
        completed.applyPendingDeletion(store: store); // 남은 표시 없음 = true
    CommunityUploadHooks.beginDeletion = () =>
        completed.beginDeletion(store: store);
    CommunityUploadHooks.cancelDeletion = (id) =>
        completed.cancelDeletion(id, store: store);
    CommunityUploadHooks.confirmDeletion = () =>
        completed.confirmDeletion(store: store);
  }

  static VoidCallback? _pauseListener;
  static VoidCallback? _lockListener;
  static bool _wasPaused = false;
  static bool _wasLocked = false;

  static void _resume(String reason) {
    final g = gate;
    if (g == null || !g.isWriter) return;
    CommunityUploadController.instance.wake('recovery');
    RawBackfillRuntime.wake();
  }

  /// manifest 전 페이지 → server_completed 교체. 받는 동안 upload lease 를 잡아 자기 업로드로 세대가 바뀌지 않게 한다.
  /// 원인을 보존한다. 잠금을 기다리며 다른 작업을 막지 않고 실행기가 재시도한다.
  static Future<ManifestResult> refreshManifest(
    CommunityStore store, {
    CommunityIngestClient? client,
    Future<String?> Function()? token,
  }) async {
    final ctx = await store.activeContext();
    final datasetKey = ctx?['dataset_key'] as String?;
    final connectionId = ctx?['connection_id'] as String?;
    final epoch = int.tryParse('${ctx?['writer_epoch']}');
    if (datasetKey == null || connectionId == null || epoch == null) {
      return const ManifestResult(ManifestStatus.noContext);
    }
    // 업로드 일시 중지(서버 점검) 중에는 manifest 도 요청하지 않는다(서버가 503 으로 끝낸다).
    if (await UploadPause.isPaused(store)) {
      return const ManifestResult(ManifestStatus.paused);
    }
    final access =
        await (token ?? CommunityAuthService.instance.getAccessToken)();
    if (access == null || access.isEmpty) {
      return const ManifestResult(ManifestStatus.noToken);
    }
    final config = CommunityAuthConfig.fromEnvironment;
    final c =
        client ??
        CommunityIngestClient(
          supabaseUrl: config.supabaseUrl,
          publishableKey: config.publishableKey,
        );
    final owner = 'manifest:${newUuidV4()}';
    if (!await store.acquireLease(
      'upload',
      owner,
      const Duration(minutes: 5),
    )) {
      if (client == null) c.close();
      return const ManifestResult(ManifestStatus.busyUploadLease);
    }
    var last = const ManifestResult(ManifestStatus.invalidResponse);
    try {
      final ok = await completed.refreshServerCompleted(
        datasetKey: datasetKey,
        writerEpoch: epoch,
        store: store,
        commitAllowed: (tx) async {
          final current = await tx.query(
            'context',
            where: 'id=1 AND state=?',
            whereArgs: ['active'],
          );
          if (current.isEmpty ||
              ![
                'connection_id',
                'writer_epoch',
                'dataset_key',
                'contributor_fingerprint',
                'consent_grant_id',
              ].every((k) => current.first[k] == ctx![k])) {
            last = last.withStatus(ManifestStatus.noContext);
            return false;
          }
          final lease = await tx.query(
            'leases',
            where: 'name=? AND owner=? AND until>?',
            whereArgs: ['upload', owner, isoUtc(DateTime.now())],
          );
          if (lease.length != 1) {
            last = last.withStatus(ManifestStatus.busyUploadLease);
            return false;
          }
          return true;
        },
        fetchPage: (after, limit) async {
          if (!await store.renewLease(
            'upload',
            owner,
            const Duration(minutes: 5),
          )) {
            last = last.withStatus(ManifestStatus.busyUploadLease);
            return null;
          }
          if (!await _sameContext(store, ctx!)) {
            last = last.withStatus(ManifestStatus.noContext);
            return null;
          }
          last = await c.fetchManifestPage(
            access,
            connectionId,
            after: after,
            limit: limit,
            onMaintenance: (error) =>
                UploadPause.applyMaintenance(store, error),
          );
          return last.isOk ? completed.ManifestPage.fromJson(last.page!) : null;
        },
      );
      return ok
          ? last
          : last.isOk
          ? last.withStatus(ManifestStatus.invalidResponse)
          : last;
    } finally {
      if (client == null) c.close();
      await store.releaseLease('upload', owner);
    }
  }

  static Future<bool> _sameContext(
    CommunityStore store,
    Map<String, Object?> expected,
  ) async {
    final current = await store.activeContext();
    return current != null &&
        [
          'connection_id',
          'writer_epoch',
          'dataset_key',
          'contributor_fingerprint',
          'consent_grant_id',
        ].every((k) => current[k] == expected[k]);
  }
}
