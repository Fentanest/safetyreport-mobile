import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'community_store.dart';
import 'capture/community_capture.dart' show sourceReportKeyPrefix;

/// One durable full-collection job per confirmed account/grant/dataset. Retries
/// use the same key and dataset: cancellation/crash never marks it completed.
class ConsentCatchup {
  ConsentCatchup(this.store);
  final CommunityStore store;
  static String jobKey(Map<String, Object?> ctx) =>
      'consent_catchup:${ctx['contributor_fingerprint']}:${ctx['consent_grant_id']}:${ctx['dataset_key']}';

  Future<void> schedule(Map<String, Object?> ctx) async {
    if (ctx['consent_grant_id'] == null ||
        ctx['dataset_key'] == null ||
        ctx['contributor_fingerprint'] == null) {
      return;
    }
    await store.transaction((tx) async {
      final key = jobKey(ctx);
      if (await store.meta(key, tx) == null) {
        await store.setMeta(
          key,
          jsonEncode({
            'phase': 'pending',
            'scheduled_at': isoUtc(DateTime.now()),
          }),
          tx,
        );
      }
    });
  }

  /// Refresh manifest once per attempt, never one request per report. New grant
  /// explicitly authorizes retrospective SAME-account observations. Other
  /// accounts and explicit contribution deletions are never silently copied.
  Future<bool> run({
    required Future<bool> Function() verify,
    required Future<bool> Function() manifest,
    required Future<bool> Function() collectAll,
  }) async {
    final ctx = await store.activeContext();
    if (ctx == null) return false;
    final key = jobKey(ctx);
    final raw = await store.meta(key);
    if (raw == null || (jsonDecode(raw) as Map)['phase'] == 'completed') {
      return false;
    }
    final owner = newUuidV4();
    if (!await store.acquireLease(
      'consent-catchup',
      owner,
      const Duration(minutes: 2),
    )) {
      return false;
    }
    final timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(
        store.renewLease('consent-catchup', owner, const Duration(minutes: 2)),
      );
    });
    try {
      if (!await verify() || !await _same(ctx) || !await manifest()) {
        return false;
      }
      await reshareMissing(ctx);
      if (!await _same(ctx) || !await collectAll() || !await _same(ctx)) {
        return false;
      }
      await store.setMeta(
        key,
        jsonEncode({
          'phase': 'completed',
          'completed_at': isoUtc(DateTime.now()),
        }),
      );
      return true;
    } finally {
      timer.cancel();
      await store.releaseLease('consent-catchup', owner);
    }
  }

  Future<bool> _same(Map<String, Object?> ctx) async {
    final current = await store.activeContext();
    return current != null &&
        [
          'contributor_fingerprint',
          'consent_grant_id',
          'dataset_key',
          'connection_id',
          'writer_epoch',
        ].every((k) => current[k] == ctx[k]);
  }

  Future<int> reshareMissing(Map<String, Object?> ctx) async {
    var made = 0;
    String after = '';
    while (true) {
      if (!await _same(ctx)) return made;
      // Bounded local batches, grouped across restored dataset copies.
      final rows = await store.db.rawQuery(
        '''
SELECT j.* FROM source_journal j JOIN (
 SELECT source_report_id, MAX(rowid) AS last_row FROM source_journal
 WHERE contributor_fingerprint=? AND dataset_key=? AND eligible=1
 AND personal_save_state='saved' AND source_report_id>? GROUP BY source_report_id
 ORDER BY source_report_id LIMIT 200
) r ON j.rowid=r.last_row ORDER BY j.source_report_id
''',
        [ctx['contributor_fingerprint'], ctx['dataset_key'], after],
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        after = row['source_report_id'] as String;
        if (!const [
          null,
          '',
          'consent_unknown',
          'consent_denied',
          'no_active_context',
        ].contains(row['blocked_reason'])) {
          continue;
        }
        final present = await store.db.rawQuery(
          'SELECT 1 FROM server_completed WHERE dataset_key=? AND key_prefix=? LIMIT 1',
          [ctx['dataset_key'], sourceReportKeyPrefix(after)],
        );
        final sameGrant =
            row['consent_grant_id'] == ctx['consent_grant_id'] &&
            row['connection_id'] == ctx['connection_id'];
        if (sameGrant &&
            row['blocked_reason'] == null &&
            (row['ack_status'] == null || present.isNotEmpty)) {
          continue;
        }
        if (sameGrant && row['ack_status'] != null && present.isEmpty) {
          // Manifest lists public facts, not all durable receipts. Absence is not authorization to bypass server
          // deletion fences with a new event id. Keep evidence for recovery UI.
          await store.setMeta(
            '${jobKey(ctx)}:reconciliation:$after',
            'receipt_not_in_public_manifest',
          );
          continue;
        }
        final marker = '${jobKey(ctx)}:reshare:$after:${row['payload_sha256']}';
        await store.transaction((tx) async {
          final current = await tx.query(
            'context',
            where: "id=1 AND state='active'",
          );
          if (current.isEmpty ||
              ![
                'contributor_fingerprint',
                'consent_grant_id',
                'dataset_key',
                'connection_id',
                'writer_epoch',
              ].every((k) => current.first[k] == ctx[k])) {
            return;
          }
          if (await store.meta(marker, tx) != null) return;
          final id = newUuidV4();
          final cloned = Map<String, Object?>.from(row)
            ..addAll({
              'event_id': id,
              'event_type': 'reshare',
              'capture_trigger': 'consent_catchup',
              'local_dataset_id': await store.meta('local_dataset_id', tx),
              'source_revision': await store.nextRevision(tx),
              'rebuild_run_id': null,
              for (final k in [
                'connection_id',
                'writer_epoch',
                'consent_grant_id',
              ])
                k: ctx[k],
              for (final k in [
                'ack_status',
                'receipt_id',
                'acked_at',
                'projection_status',
                'blocked_reason',
              ])
                k: null,
            });
          await tx.insert('source_journal', cloned);
          await tx.insert('outbox', {
            'event_id': id,
            'state': 'pending',
            'attempt_count': 0,
            'enqueued_trigger': 'consent_catchup',
            'enqueued_at': isoUtc(DateTime.now()),
          });
          await tx.insert('report_latest', {
            'local_dataset_id': cloned['local_dataset_id'],
            'source_report_id': after,
            'event_id': id,
            'payload_sha256': cloned['payload_sha256'],
            'eligible': 1,
            'source_generation':
                int.tryParse(
                  await store.meta('source_generation', tx) ?? '0',
                ) ??
                0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await store.setMeta(marker, id, tx);
          made++;
        });
      }
    }
    return made;
  }
}
