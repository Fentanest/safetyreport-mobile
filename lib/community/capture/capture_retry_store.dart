// capture 재시도 의도 파일 `<앱폴더>/community_capture_retry.json` (S-03).
//
// community.db 자체가 실패할 수 있으므로 별도 파일에 둔다.
// 상세를 받으면 capture 전에 의도를 기록 → capture → 개인 저장 → 성공이면 제거.
// 원자적 쓰기(임시 파일 → rename).
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import '../community_store.dart';
import 'community_capture.dart';

class CaptureRetryStore {
  static Directory _events(File legacy) =>
      Directory('${legacy.path}.events-v1');

  static Future<List<Map<String, Object?>>> _legacy(File file) async {
    if (!await file.exists()) return [];
    final value = jsonDecode(await file.readAsString());
    if (value is! List ||
        value.any(
          (e) =>
              e is! Map ||
              e['source_report_id'] is! String ||
              (e['source_report_id'] as String).isEmpty,
        )) {
      throw const FormatException('capture retry journal is malformed');
    }
    return value.map((e) => Map<String, Object?>.from(e as Map)).toList();
  }

  static Future<List<Map<String, Object?>>> _records(File file) async {
    final folder = _events(file);
    if (!await folder.exists()) return [];
    final records = <Map<String, Object?>>[];
    await for (final entry in folder.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      Object? value;
      try {
        value = jsonDecode(await entry.readAsString());
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode == 2) continue;
        rethrow;
      }
      if (value is! Map ||
          value['format_version'] != 1 ||
          !['add', 'ack'].contains(value['kind']) ||
          value['source_report_id'] is! String ||
          (value['source_report_id'] as String).isEmpty ||
          value['event_id'] is! String) {
        throw const FormatException('capture retry event is malformed');
      }
      if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(value['event_id'] as String) ||
          !entry.path.endsWith('/${value['event_id']}.json')) {
        throw const FormatException('capture event identity malformed');
      }
      if (value['kind'] == 'ack' &&
          (value['observed'] is! List ||
              (value['observed'] as List).any((v) => v is! String))) {
        throw const FormatException('capture retry ACK is malformed');
      }
      records.add(Map<String, Object?>.from(value));
    }
    final owners = <String, String>{
      for (final row in records.where((r) => r['kind'] == 'add'))
        row['event_id'] as String: row['source_report_id'] as String,
      for (final row in await _legacy(file))
        _legacyKey(row): row['source_report_id'] as String,
    };
    for (final ack in records.where((r) => r['kind'] == 'ack')) {
      for (final id in (ack['observed'] as List).cast<String>()) {
        if (!(RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) ||
                RegExp(r'^legacy:[a-f0-9]{64}$').hasMatch(id)) ||
            (owners.containsKey(id) && owners[id] != ack['source_report_id'])) {
          throw const FormatException('capture ACK source mismatch');
        }
      }
    }
    return records;
  }

  static String _legacyKey(Map<String, Object?> row) =>
      'legacy:${sha256.convert(utf8.encode(jsonEncode(row)))}';

  /// Immutable add/ACK records avoid read-modify-write across isolates and
  /// processes. Linux advisory file locks alone do not serialize isolates.
  static Future<Set<String>> captureRetryIds(File file) async {
    final legacy = await _legacy(file);
    final records = await _records(file);
    final acknowledged = <String>{
      for (final r in records.where((r) => r['kind'] == 'ack'))
        ...(r['observed'] as List).cast<String>(),
    };
    return {
      for (final row in legacy)
        if (!acknowledged.contains(_legacyKey(row)))
          row['source_report_id'] as String,
      for (final row in records.where((r) => r['kind'] == 'add'))
        if (!acknowledged.contains(row['event_id']))
          row['source_report_id'] as String,
    };
  }

  static Future<void> addIntent(
    File file,
    String sourceReportId,
    String reason, {
    DateTime? now,
  }) async {
    if (sourceReportId.isEmpty) {
      throw const FormatException('empty capture source ID');
    }
    await _legacy(file);
    final records = await _records(
      file,
    ); // Corrupt obligations never become empty.
    await _retireAcknowledged(file, records);
    await _append(file, {
      'kind': 'add',
      'source_report_id': sourceReportId,
      'reason': reason,
      'failed_at': isoUtc(now ?? DateTime.now()),
    });
  }

  /// A newer intent published after this snapshot cannot be acknowledged.
  static Future<void> removeIntent(File file, String sourceReportId) async {
    final legacy = await _legacy(file);
    final records = await _records(file);
    final observed = [
      for (final row in legacy)
        if (row['source_report_id'] == sourceReportId) _legacyKey(row),
      for (final row in records)
        if (row['kind'] == 'add' && row['source_report_id'] == sourceReportId)
          row['event_id'] as String,
    ];
    if (observed.isNotEmpty) {
      final ack = await _append(file, {
        'kind': 'ack',
        'source_report_id': sourceReportId,
        'observed': observed,
      });
      await _retireAcknowledged(file, [ack]);
    }
  }

  static Future<void> _retireAcknowledged(
    File file,
    List<Map<String, Object?>> records,
  ) async {
    for (final ack in records.where((r) => r['kind'] == 'ack')) {
      final observed = (ack['observed'] as List).cast<String>();
      for (final id in observed.where((id) => !id.startsWith('legacy:'))) {
        if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
          throw const FormatException('invalid capture ACK identity');
        }
        final retired = File('${_events(file).path}/$id.json');
        try {
          final add = jsonDecode(await retired.readAsString());
          if (add is! Map ||
              add['kind'] != 'add' ||
              add['event_id'] != id ||
              add['source_report_id'] != ack['source_report_id']) {
            throw const FormatException('capture ACK source mismatch');
          }
          await retired.delete();
        } on FileSystemException catch (e) {
          if (e.osError?.errorCode != 2) rethrow;
        }
      }
      // A crash before this point leaves an ACK, so unfinished retirement can
      // resume. Legacy receipts remain while their immutable input is retained.
      if (!observed.any((id) => id.startsWith('legacy:'))) {
        final receipt = File('${_events(file).path}/${ack['event_id']}.json');
        try {
          await receipt.delete();
        } on FileSystemException catch (e) {
          if (e.osError?.errorCode != 2) rethrow;
        }
      }
    }
  }

  static Future<Map<String, Object?>> _append(
    File file,
    Map<String, Object?> data,
  ) async {
    final folder = _events(file);
    await folder.create(recursive: true);
    final id = newUuidV4();
    final target = File('${folder.path}/$id.json');
    final part = File('${target.path}.part');
    final record = <String, Object?>{
      'format_version': 1,
      'event_id': id,
      ...data,
    };
    await part.writeAsString(jsonEncode(record), flush: true);
    await part.rename(target.path);
    return record;
  }
}

/// 한 동기화 실행의 연속 capture 실패 집계. 3회 연속이면 수집을 멈춘다.
class CaptureTracker {
  int consecutiveFailures = 0;

  void recordSuccess() => consecutiveFailures = 0;

  /// true = 호출자가 동기화를 `community_store_unavailable` 로 멈춰야 한다.
  bool recordFailure() {
    consecutiveFailures++;
    return consecutiveFailures >= 3;
  }
}

/// capture 전에 의도를 기록한다. 기록 자체가 실패하면 그 건을 저장하지 않고
/// 호출자가 수집을 즉시 멈춰야 한다 ([CaptureStoreUnavailable] throw).
Future<void> recordCaptureIntent(
  File retryFile,
  String sourceReportId, {
  DateTime? now,
}) async {
  try {
    await CaptureRetryStore.addIntent(
      retryFile,
      sourceReportId,
      'capture_pending',
      now: now,
    );
  } catch (_) {
    throw CaptureStoreUnavailable(
      'community_capture_retry 기록 실패: $sourceReportId',
    );
  }
}
