import 'dart:developer';
import 'dart:io';

/// Opt-in diagnostics, no record contents, addresses, credentials or raw JSON.
/// RSS includes Dart + native allocations; it is not a Dart heap measurement.
class PerformanceTrace {
  static bool enabled = const bool.fromEnvironment('SR_PERF');
  static void Function(Map<String, Object?>)? observer;

  static void record(String stage, Stopwatch timer, {int? rows}) {
    if (!enabled && observer == null) return;
    final event = <String, Object?>{
      'stage': stage,
      'us': timer.elapsedMicroseconds,
      'rows': rows,
      'rss_bytes': ProcessInfo.currentRss,
      'peak_rss_bytes': ProcessInfo.maxRss,
    };
    observer?.call(event);
    if (enabled) log(event.toString(), name: 'sr.perf');
  }

  static T sync<T>(String stage, T Function() work) {
    final timer = Stopwatch()..start();
    try {
      return Timeline.timeSync('sr.$stage', work);
    } finally {
      record(stage, timer);
    }
  }

  static Future<List<Map<String, Object?>>> sql(
    String stage,
    Future<List<Map<String, Object?>>> Function() work,
  ) async {
    final timer = Stopwatch()..start();
    final task = TimelineTask()..start('sr.$stage');
    try {
      final rows = await work();
      record(stage, timer, rows: rows.length);
      return rows;
    } finally {
      task.finish();
    }
  }
}

class QueryCancelled implements Exception {
  const QueryCancelled();
}
