import 'dart:async';
import '../community/community_store.dart';
import 'package:sqflite/sqflite.dart';

class _SyncOwner {
  final leaseId = newUuidV4();
  bool lost = false;
  String generation = '0';
  Map<String, Object?>? context;
  CommunityStore? store;
  bool Function()? stopRequested;
  Future<void> Function()? validateScope;
  void Function()? onProgress;
}

/// Manual sync and inbox drain share an owner. A drain may call its fallback
/// inside the same zone without acquiring its own admission twice.
class SyncOperationAdmission {
  static final _ownerKey = Object();
  static _SyncOwner? _owner;
  static bool get cancelled {
    final owner = Zone.current[_ownerKey] as _SyncOwner?;
    return owner != null && (owner.lost || owner.stopRequested?.call() == true);
  }

  static void reportProgress() =>
      (Zone.current[_ownerKey] as _SyncOwner?)?.onProgress?.call();

  /// Check after external awaits, and inside a transaction before publication.
  static Future<void> checkOwnership({DatabaseExecutor? executor}) async {
    final owner = Zone.current[_ownerKey] as _SyncOwner?;
    if (owner == null) return;
    if (cancelled) throw StateError('sync_cancelled');
    if (executor == null) await owner.validateScope?.call();
    if (owner.context != null) {
      final ctx = await (executor ?? owner.store!.db).query(
        'context',
        where: "id=1 AND state='active'",
      );
      // 게이트의 일시 비활성화(poll 의 503·쿨다운)는 동기화를 끊지 않는다 — 그 처리는 capture 의 offline 경로에 맡긴다.
      // 식별 필드가 다를 때와 work_generation 변경만 실패로 본다.
      if (ctx.isNotEmpty &&
          ![
            'contributor_fingerprint',
            'connection_id',
            'writer_epoch',
            'consent_grant_id',
            'dataset_key',
          ].every((k) => ctx.first[k] == owner.context![k])) {
        owner.lost = true;
        throw StateError('sync_context_changed');
      }
    }
    final gen = await owner.store!.meta('work_generation', executor);
    if ((gen ?? '0') != owner.generation) {
      owner.lost = true;
      throw StateError('sync_generation_changed');
    }
    final rows = await (executor ?? owner.store!.db).query(
      'leases',
      where: 'name=? AND owner=? AND until>?',
      whereArgs: ['personal_sync', owner.leaseId, isoUtc(DateTime.now())],
    );
    if (rows.isEmpty || cancelled) {
      owner.lost = true;
      throw StateError('sync_ownership_lost');
    }
  }

  /// Keep the admission lease locked while publishing to the separate personal DB.
  /// A different isolate cannot acquire ownership between the check and write.
  static Future<T> protectWrite<T>(Future<T> Function() body) async {
    final owner = Zone.current[_ownerKey] as _SyncOwner?;
    if (owner == null) return body();
    await owner.validateScope?.call();
    return owner.store!.transaction((tx) async {
      await checkOwnership(executor: tx);
      return body();
    });
  }

  static Future<void> cancelAll(CommunityStore store) async {
    _owner?.lost = true;
    await store.transaction((tx) async {
      final gen =
          int.tryParse(await store.meta('work_generation', tx) ?? '0') ?? 0;
      await store.setMeta('work_generation', '${gen + 1}', tx);
    });
  }

  static Future<T> run<T>(
    Future<T> Function() body,
    T busy, {
    Future<CommunityStore> Function()? openStore,
    bool Function()? stopRequested,
    Future<void> Function()? validateScope,
    void Function()? onProgress,
  }) async {
    if (_owner != null) {
      if (identical(Zone.current[_ownerKey], _owner)) return body();
      return busy;
    }
    final owner = _SyncOwner()
      ..stopRequested = stopRequested
      ..validateScope = validateScope
      ..onProgress = onProgress;
    _owner = owner;
    CommunityStore? store;
    Timer? heartbeat;
    try {
      store = await (openStore?.call() ?? CommunityStore.open());
      owner.store = store;
      owner.generation = await store.meta('work_generation') ?? '0';
      owner.context = await store.activeContext();
      if (!await store.acquireLease(
        'personal_sync',
        owner.leaseId,
        const Duration(minutes: 10),
      )) {
        return busy;
      }
      final ownedStore = store;
      heartbeat = Timer.periodic(const Duration(minutes: 1), (_) async {
        try {
          if (!await ownedStore.renewLease(
            'personal_sync',
            owner.leaseId,
            const Duration(minutes: 10),
          )) {
            owner.lost = true;
          }
        } catch (_) {
          owner.lost = true;
        }
      });
      return await runZoned(body, zoneValues: {_ownerKey: owner});
    } finally {
      heartbeat?.cancel();
      try {
        if (store != null) {
          await store.releaseLease('personal_sync', owner.leaseId);
        }
      } finally {
        if (identical(_owner, owner)) _owner = null;
      }
    }
  }
}
