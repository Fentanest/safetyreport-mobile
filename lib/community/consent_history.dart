import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'community_store.dart';

/// Account-scoped status transitions in app secure storage, outside report DB
/// exports/backups. This is local history, never server authorization or a claim
/// of tamper-proof storage on a compromised device.
class ConsentHistory {
  ConsentHistory(this.store, {FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();
  final CommunityStore store;
  final FlutterSecureStorage storage;
  static String key(String account) => 'community_consent_history_v1:$account';
  Future<Map<String, Object?>?> latest(String account) async {
    final raw = await storage.read(key: key(account));
    if (raw == null) return null;
    return (jsonDecode(raw) as Map).cast<String, Object?>();
  }

  static final Map<String, Future<void>> _writes = {};
  Future<void> _write(String account, Future<void> Function() body) {
    final previous = _writes[account] ?? Future<void>.value();
    final operation = previous.then((_) async {
      final lease = 'consent-history:$account', owner = newUuidV4();
      var acquired = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        if (await store.acquireLease(
          lease,
          owner,
          const Duration(seconds: 30),
        )) {
          acquired = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!acquired) throw StateError('동의 이력 저장 중입니다.');
      try {
        await body();
      } finally {
        await store.releaseLease(lease, owner);
      }
    });
    _writes[account] = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> event(
    String account,
    String result,
    String source, {
    Map<String, Object?>? status,
    String? grant,
    bool localRevoke = false,
  }) async {
    if (result == 'unknown') return;
    await _write(account, () async {
      final previous = await latest(account) ?? <String, Object?>{};
      grant = status != null ? grant : grant ?? previous['grant_id'] as String?;
      final sticky =
          localRevoke ||
          (previous['local_revoke'] == true &&
              (grant == null || grant == previous['grant_id']));
      final contributor = status?['contributor'];
      // Consent and suspension are independent. Only an explicit server status
      // declaring this contributor active can clear a recorded suspension.
      final suspended =
          result == 'suspended' ||
          result == 'contributor_suspended' ||
          (previous['suspended'] == true &&
              !(contributor is Map && contributor['status'] == 'active'));
      final effective = suspended
          ? 'suspended'
          : (sticky && result == 'ok' ? 'consent_required' : result);
      final consent = status?['consent'];
      final consentState = localRevoke
          ? 'revoked'
          : (consent is Map ? consent['state'] : previous['consent_state']);
      final isConsentTransition =
          result == 'ok' &&
          grant != null &&
          !sticky &&
          !suspended &&
          (previous['accepted_explicitly'] == true ||
              (previous['consent_state'] != null &&
                  (previous['consent_state'] != 'active' ||
                      previous['grant_id'] != grant)));
      final catchupGrant = isConsentTransition
          ? grant
          : previous['catchup_grant'];
      if (previous['result'] == effective &&
          previous['grant_id'] == grant &&
          previous['local_revoke'] == sticky &&
          previous['consent_state'] == consentState &&
          previous['suspended'] == suspended &&
          previous['catchup_grant'] == catchupGrant) {
        return;
      }
      final records = (previous['transitions'] as List? ?? []).cast<Object?>();
      records.add({
        'state': effective,
        'consent_state': consentState,
        'source': source,
        'at': isoUtc(DateTime.now()),
        'grant_id': grant,
      });
      await storage.write(
        key: key(account),
        value: jsonEncode({
          ...previous,
          'result': effective,
          'consent_state': consentState,
          'grant_id': grant,
          'local_revoke': sticky,
          'suspended': suspended,
          'catchup_grant': catchupGrant,
          if (isConsentTransition) 'accepted_explicitly': false,
          'transitions': records,
          'status': ?status,
        }),
      );
    });
  }

  Future<void> acceptedExplicitly(String account) => _write(account, () async {
    final previous = await latest(account) ?? <String, Object?>{};
    previous['local_revoke'] = false;
    previous['accepted_explicitly'] = true;
    await storage.write(key: key(account), value: jsonEncode(previous));
  });

  Future<bool> needsCatchup(String account, String grant) async =>
      (await latest(account))?['catchup_grant'] == grant;

  Future<bool> uploadBlocked(String account, String? grant) async {
    final state = await latest(account);
    return state?['local_revoke'] == true &&
        (grant == null || state?['grant_id'] == grant);
  }

  /// Preserve original scope. The snapshot is for local capture only. Uploads
  /// require a fresh server check; a later confirmed grant may reshare SAME
  /// account/dataset records via the durable consent catch-up job.
  Future<void> pauseCapture(
    String account,
    String dataset, {
    bool consentDenied = false,
  }) async {
    final history = await latest(account);
    final ctx = await store.context();
    final same =
        ctx != null &&
        ctx['contributor_fingerprint'] == account &&
        ctx['dataset_key'] == dataset &&
        ctx['consent_grant_id'] != null;
    final lastAllows =
        history?['result'] == 'ok' ||
        (history == null &&
            same &&
            (ctx['state'] == 'active' ||
                ctx['inactive_reason'] == 'cloud_unavailable'));
    final transferable =
        same &&
        lastAllows &&
        !consentDenied &&
        !await uploadBlocked(account, ctx['consent_grant_id']?.toString());
    await store.setMeta(
      'offline_capture',
      jsonEncode({
        'account': account,
        'dataset_key': dataset,
        'local_dataset_id': await store.localDatasetId(),
        'context': transferable ? ctx : null,
        'blocked_reason': transferable
            ? null
            : (consentDenied ? 'consent_denied' : 'consent_unknown'),
      }),
    );
  }

  Future<void> clearCapture() async {
    await store.db.delete(
      'meta',
      where: 'key=?',
      whereArgs: ['offline_capture'],
    );
  }
}
