import '../models/report.dart';
import 'performance_trace.dart';

typedef ReportPage = ({List<Report> reports, int total});
typedef ReportPageReader =
    Future<ReportPage> Function(
      String category, {
      int offset,
      int limit,
      bool Function()? isCancelled,
    });

/// Merge sorted category streams, count all matches, and retain just a window.
/// Older servers need no new API parameters. At most three source pages and
/// [windowSize] matching rows are held, regardless of the population size.
Future<ReportPage> scanClientReports({
  required ReportPageReader read,
  required List<String> categories,
  required bool Function(Report) matches,
  required bool Function() isCancelled,
  required int offset,
  int windowSize = 400,
}) async {
  final buffers = <List<Report>>[for (final _ in categories) <Report>[]];
  final positions = List.filled(categories.length, 0);
  final offsets = List.filled(categories.length, 0);
  final finished = List.filled(categories.length, false);
  final selected = <Report>[];
  var total = 0;
  while (true) {
    if (isCancelled()) throw const QueryCancelled();
    for (var i = 0; i < categories.length; i++) {
      if (positions[i] < buffers[i].length || finished[i]) continue;
      final page = await read(
        categories[i],
        offset: offsets[i],
        limit: 200,
        isCancelled: isCancelled,
      );
      if (isCancelled()) throw const QueryCancelled();
      buffers[i] = page.reports;
      positions[i] = 0;
      offsets[i] += page.reports.length;
      finished[i] = page.reports.isEmpty || offsets[i] >= page.total;
    }
    var best = -1;
    for (var i = 0; i < categories.length; i++) {
      if (positions[i] >= buffers[i].length) continue;
      if (best < 0) {
        best = i;
        continue;
      }
      final a = buffers[i][positions[i]], b = buffers[best][positions[best]];
      final order = a.reportNumber.compareTo(b.reportNumber);
      if (order > 0 || (order == 0 && a.id.compareTo(b.id) > 0)) best = i;
    }
    if (best < 0) break;
    final row = buffers[best][positions[best]++];
    if (!matches(row)) continue;
    if (total >= offset && selected.length < windowSize) selected.add(row);
    total++;
  }
  return (reports: selected, total: total);
}
