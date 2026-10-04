import 'dart:async';
import '../community/community_store.dart';

class _SyncOwner {
  final leaseId = newUuidV4();
  bool lost = false;
}

/// Manual sync and inbox drain share an owner. A drain may call its fallback
/// inside the same zone without acquiring its own admission twice.
class SyncOperationAdmission {
  static final _ownerKey = Object();
  static _SyncOwner? _owner;
  static bool get cancelled => (Zone.current[_ownerKey] as _SyncOwner?)?.lost ?? false;

  static Future<T> run<T>(Future<T> Function() body, T busy, {Future<CommunityStore> Function()? openStore}) async {
    if (_owner != null) {
      if (identical(Zone.current[_ownerKey], _owner)) return body();
      return busy;
    }
    final owner = _SyncOwner();
    _owner = owner;
    CommunityStore? store;
    Timer? heartbeat;
    try {
      store = await (openStore?.call() ?? CommunityStore.open());
      if (!await store.acquireLease('personal_sync', owner.leaseId, const Duration(minutes: 10))) return busy;
      final ownedStore = store;
      heartbeat = Timer.periodic(const Duration(minutes: 1), (_) async {
        try { if (!await ownedStore.renewLease('personal_sync', owner.leaseId, const Duration(minutes: 10))) owner.lost = true; }
        catch (_) { owner.lost = true; }
      });
      return await runZoned(body, zoneValues: {_ownerKey: owner});
    } finally {
      heartbeat?.cancel();
      try { if (store != null) await store.releaseLease('personal_sync', owner.leaseId); }
      finally { if (identical(_owner, owner)) _owner = null; }
    }
  }
}
