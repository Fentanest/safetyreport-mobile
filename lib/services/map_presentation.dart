import '../models/report_map.dart';

/// Presentation-only spatial aggregation. Population metadata always comes from
/// the complete server aggregate, never from this visible subset.
List<ReportMapPoint> visibleMapCells(
  List<ReportMapPoint> points,
  List<double>? bounds,
) {
  final box = bounds ?? const [-90.0, -180.0, 90.0, 180.0];
  final cells = <String, List<ReportMapPoint>>{};
  for (final p in points) {
    if (!p.hasValidCoordinates ||
        p.lat < box[0] ||
        p.lat >= box[2] ||
        p.lng < box[1] ||
        p.lng >= box[3]) {
      continue;
    }
    final y = ((p.lat - box[0]) / (box[2] - box[0]) * 32).floor();
    final x = ((p.lng - box[1]) / (box[3] - box[1]) * 32).floor();
    cells.putIfAbsent('$y:$x', () => []).add(p);
  }
  List<ReportMapBreakdownItem> breakdown(
    List<ReportMapPoint> cell,
    List<ReportMapBreakdownItem> Function(ReportMapPoint) select,
    int total,
  ) {
    final counts = <String, int>{};
    for (final p in cell) {
      for (final item in select(p)) {
        counts.update(
          item.label,
          (n) => n + item.count,
          ifAbsent: () => item.count,
        );
      }
    }
    return [
      for (final e in counts.entries)
        ReportMapBreakdownItem(
          label: e.key,
          count: e.value,
          pct: total == 0 ? 0 : e.value * 100 / total,
        ),
    ];
  }

  return [
    for (final cell in cells.values)
      (() {
        if (cell.length == 1) return cell.single;
        final total = cell.fold<int>(0, (n, p) => n + p.total);
        final agency = <String, int>{};
        for (final p in cell) {
          for (final a in p.agencyBreakdown) {
            agency.update(a.name, (n) => n + a.count, ifAbsent: () => a.count);
          }
        }
        return ReportMapPoint(
          isCluster: true,
          lat: cell.fold<double>(0, (n, p) => n + p.lat * p.total) / total,
          lng: cell.fold<double>(0, (n, p) => n + p.lng * p.total) / total,
          address: '지도 구역 집계 · 확대하여 주소 확인',
          region: '',
          total: total,
          statusBreakdown: breakdown(cell, (p) => p.statusBreakdown, total),
          dispositionBreakdown: breakdown(
            cell,
            (p) => p.dispositionBreakdown,
            total,
          ),
          categoryBreakdown: breakdown(cell, (p) => p.categoryBreakdown, total),
          agencyBreakdown: [
            for (final e in agency.entries)
              ReportMapAgencyItem(
                name: e.key,
                count: e.value,
                pct: total == 0 ? 0 : e.value * 100 / total,
              ),
          ],
        );
      })(),
  ];
}
