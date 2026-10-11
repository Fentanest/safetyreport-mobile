import 'dart:async';
import '../community/community_store.dart';
import 'package:sqflite/sqflite.dart';

class _SyncOwner {
  final leaseId = newUuidV4();
  bool lost = false;
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
