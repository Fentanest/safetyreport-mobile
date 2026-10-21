import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'capture/raw_ingest.dart';
import 'community_store.dart';

/// Stores the capability part of a status answer (`meta.ingest_status`).
///
/// When the server stops accepting v2 (`ingest.contracts` loses 2) the app is back on v1 from here:
/// the transport cooldown that v2 503 answers (`service_unavailable`) caused is lifted so v1 rows
/// are not held behind it.
Future<void> saveIngestStatus(
  CommunityStore store,
  Map<String, Object?> raw, [
  DatabaseExecutor? tx,
]) async {
  final before = await store.meta('ingest_status', tx);
  var wasReady = false;
  try {
    wasReady =
        before != null &&
        rawV2Ready((jsonDecode(before) as Map).cast<String, Object?>());
  } catch (_) {}
  final cached = cachedIngestStatus(raw);
  await store.setMeta('ingest_status', jsonEncode(cached), tx);
  if (wasReady && !rawV2Ready(cached)) {
    await (tx ?? store.db).delete(
      'upload_control',
      where: 'last_error_code=?',
      whereArgs: ['service_unavailable'],
    );
  }
}
