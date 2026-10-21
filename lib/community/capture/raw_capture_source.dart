import 'dart:convert';
import 'dart:typed_data';
import '../../services/local_db_service.dart';
import '../../services/raw_detail.dart' as stored;
import '../community_store.dart';
import 'raw_ingest.dart';

Future<Map<String, Object?>?> storedRawSnapshot(
  String id, {
  Map<String, Object?> fields = const {},
}) async {
  final raw = await LocalDbService.getDetailRaw(id);
  if (raw == null) return null;
  try {
    final bytes = stored.decompressAndVerifyRawDetail(
      Uint8List.fromList((raw['raw_zlib'] as List).cast<int>()),
      raw['raw_sha256'] as String,
    );
    if (bytes.length != raw['raw_size']) return null;
    final base = await LocalDbService.readReparseBase(id);
    return rawSnapshot(
      utf8.decode(bytes),
      raw['fetched_at'] as String,
      raw['source'] as String,
      {...?base, ...fields},
    );
  } catch (_) {
    return null;
  }
}

Future<Map<String, Object?>?> rawForAdapter(
  String id,
  Map<String, Object?> adapter,
) {
  final fields = <String, Object?>{
    ...?((adapter['_raw_fields'] as Map?)?.cast<String, Object?>()),
  };
  if (adapter['photo_first_capture'] != null) {
    fields['사진_첫촬영'] = adapter['photo_first_capture'];
  }
  if (adapter['photo_last_capture'] != null) {
    fields['사진_끝촬영'] = adapter['photo_last_capture'];
  }
  return storedRawSnapshot(id, fields: fields);
}

/// True when the cached central status says v2 is accepted. Local read only.
Future<bool> rawModeReady(CommunityStore? store) async {
  if (store == null) return false;
  try {
    final text = await store.meta('ingest_status');
    return text != null &&
        rawV2Ready((jsonDecode(text) as Map).cast<String, Object?>());
  } catch (_) {
    return false;
  }
}

/// Raw snapshot of a freshly saved body for the capture call — only in v2 mode, and never able to
/// fail the caller: on any error the capture simply has no raw (v1 path), the personal save goes on.
Future<Map<String, Object?>?> rawSnapshotIfReady(
  CommunityStore? store,
  stored.RawDetailUpsert? detail,
  Map<String, Object?> fields,
) async {
  if (detail == null || !await rawModeReady(store)) return null;
  try {
    return rawSnapshot(
      utf8.decode(
        stored.decompressAndVerifyRawDetail(detail.zlib, detail.sha256),
      ),
      detail.fetchedAt,
      detail.source,
      fields,
    );
  } catch (_) {
    return null;
  }
}
