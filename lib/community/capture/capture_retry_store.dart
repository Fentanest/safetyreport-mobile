// capture 재시도 의도 파일 `<앱폴더>/community_capture_retry.json` (S-03).
//
// community.db 자체가 실패할 수 있으므로 별도 파일에 둔다.
// 상세를 받으면 capture 전에 의도를 기록 → capture → 개인 저장 → 성공이면 제거.
// 원자적 쓰기(임시 파일 → rename).
import 'dart:convert';
import 'dart:io';

import '../community_store.dart';
import 'community_capture.dart';

class CaptureRetryStore {
  /// 증분 선정에 항상 포함할 ID 집합.
  static Future<Set<String>> captureRetryIds(File file) async {
    try {
      if (!await file.exists()) return <String>{};
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => e['source_report_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> addIntent(
    File file,
    String sourceReportId,
    String reason, {
    DateTime? now,
  }) async {
    List<Map<String, Object?>> entries = [];
    try {
      if (await file.exists()) {
        final raw = await file.readAsString();
        entries = (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((e) => Map<String, Object?>.from(e))
            .toList();
      }
    } catch (_) {
      entries = [];
    }
    final at = isoUtc(now ?? DateTime.now());
    var found = false;
    for (final e in entries) {
      if (e['source_report_id'] == sourceReportId) {
        e['reason'] = reason;
        e['failed_at'] = at;
        e['attempts'] = ((e['attempts'] as int?) ?? 0) + 1;
        found = true;
      }
    }
    if (!found) {
      entries.add({
        'source_report_id': sourceReportId,
        'reason': reason,
        'failed_at': at,
        'attempts': 1,
      });
    }
    await _writeAtomic(file, entries);
  }

  static Future<void> removeIntent(File file, String sourceReportId) async {
    List<Map<String, Object?>> entries = [];
    try {
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      entries = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, Object?>.from(e))
          .toList();
    } catch (_) {
      return;
    }
    entries.removeWhere((e) => e['source_report_id'] == sourceReportId);
    await _writeAtomic(file, entries);
  }

  static Future<void> _writeAtomic(
      File file, List<Map<String, Object?>> entries) async {
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final tmp = File('${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsString(jsonEncode(entries), flush: true);
    await tmp.rename(file.path);
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
Future<void> recordCaptureIntent(File retryFile, String sourceReportId,
    {DateTime? now}) async {
  try {
    await CaptureRetryStore.addIntent(
        retryFile, sourceReportId, 'capture_pending',
        now: now);
  } catch (_) {
    throw CaptureStoreUnavailable(
        'community_capture_retry 기록 실패: $sourceReportId');
  }
}
