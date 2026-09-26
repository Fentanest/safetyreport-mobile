// T5(게이트·초기화) ↔ T6(capture·업로드) 연결 (통합, `contracts/community-ingest/interfaces.md`).
//
// main.dart 가 게이트를 만든 직후 한 번 호출한다. 병렬 작업 중 비어 있던 자리를 실제 구현으로 채우고,
// 연결이 없을 때 통과하던 경로(fail-open)를 막는다.
import 'dart:async';

import '../services/community_auth_config.dart';
import '../services/community_auth_service.dart';
import '../services/sync_engine.dart';
import 'capture/server_completed.dart' as completed;
import 'community_store.dart';
import 'gate/community_gate.dart';
import 'upload/community_ingest_client.dart';
import 'upload/community_schedule.dart' as schedule;
import 'upload/community_uploader.dart';
import 'upload/upload_defaults.dart';
import 'upload_hooks.dart';

/// 포그라운드 uploader 용 게이트 어댑터: 새 작업은 60초 이내 재검증(plan §6.1).
class LiveGateCheck implements CommunityGateCheck {
  LiveGateCheck(this.gate);
  final CommunityGate gate;

  @override
  Future<bool> requireFresh() async => (await gate.requireFresh()).canEnter;

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

  static void wire({required CommunityGate communityGate, required CommunityStore store}) {
    gate = communityGate;
    CommunityUploadHooks.refreshServerCompleted = () => refreshManifest(store);
    SyncEngine.ensureManifestFresh = () => refreshManifest(store);
    CommunityUploadHooks.registerBackgroundJobs = schedule.registerBackgroundJobs;
    CommunityUploadHooks.catchUp = (reason) async {
      final uploader = await buildDefaultUploader(gate: gateCheck());
      await schedule.catchUp(reason, store: store, runUpload: uploader.requestCommunityUpload);
    };
    CommunityUploadHooks.onContributionsDeleted =
        () => completed.onContributionsDeleted(deletedAt: DateTime.now(), store: store);
  }

  /// manifest 전 페이지 → server_completed 교체. 받는 동안 upload lease 를 잡아 자기 업로드로 세대가 바뀌지 않게 한다.
  /// context·토큰·lease 가 없거나 형식이 틀리면 false(수집·초기화 시작 금지).
  static Future<bool> refreshManifest(CommunityStore store,
      {CommunityIngestClient? client, Future<String?> Function()? token}) async {
    final ctx = await store.activeContext();
    final datasetKey = ctx?['dataset_key'] as String?;
    final connectionId = ctx?['connection_id'] as String?;
    final epoch = int.tryParse('${ctx?['writer_epoch']}');
    if (datasetKey == null || connectionId == null || epoch == null) return false;
    final access = await (token ?? CommunityAuthService.instance.getAccessToken)();
    if (access == null || access.isEmpty) return false;
    final config = CommunityAuthConfig.fromEnvironment;
    final c = client ??
        CommunityIngestClient(supabaseUrl: config.supabaseUrl, publishableKey: config.publishableKey);
    const owner = 'manifest';
    if (!await store.acquireLease('upload', owner, const Duration(minutes: 5))) return false;
    try {
      return await completed.refreshServerCompleted(
        datasetKey: datasetKey,
        writerEpoch: epoch,
        store: store,
        fetchPage: (after, limit) async {
          final page = await c.fetchManifestPage(access, connectionId, after: after, limit: limit);
          return page == null ? null : completed.ManifestPage.fromJson(page);
        },
      );
    } finally {
      await store.releaseLease('upload', owner);
    }
  }
}
