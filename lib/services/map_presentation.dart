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
          // 표시용 이름만: 셀 안에서 신고가 가장 많은 시·군·구(여럿이면 "외"). 집계 값에는 영향이 없다.
          region: dominantMapRegionLabel(cell),
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

/// 지도 집계가 지역 이름 대신 넣는 일반 문구(서버 `report_stats_service`, 로컬 `local_statistics`, 위 셀 집계).
const Set<String> _genericMapLabels = {
  '지도 구역 집계 · 확대하여 주소 확인',
  '영역 집계',
  '이 영역의 신고',
};

bool isGenericMapLabel(String text) => _genericMapLabels.contains(text.trim());

const Set<String> _provinceAbbreviations = {
  '서울',
  '부산',
  '대구',
  '인천',
  '광주',
  '대전',
  '울산',
  '세종',
  '경기',
  '강원',
  '충북',
  '충남',
  '전북',
  '전남',
  '경북',
  '경남',
  '제주',
};
final RegExp _provincePattern = RegExp(r'(특별시|광역시|특별자치시|특별자치도|도)$');
final RegExp _sigunguPattern = RegExp(r'^[가-힣]+(시|군|구)$');

/// 주소·행정구역 문자열에서 시·군·구 이름을 뽑는다. 못 찾으면 빈 문자열.
/// 예: "서울특별시 강남구 테헤란로 1" → "강남구", "경기도 수원시 영통구 …" → "수원시 영통구",
/// "경기도 고양시 일산동구 …" → "일산동구"(마커 라벨 폭 때문에 6글자 넘으면 구만), "세종특별자치시 …" → "세종시".
/// 끝의 " 외"(여러 지역 묶음 표시)는 유지한다.
String mapRegionShortLabel(String text) {
  var source = text.trim();
  var suffix = '';
  if (source.endsWith(' 외')) {
    source = source.substring(0, source.length - 2).trim();
    suffix = ' 외';
  }
  final tokens = source
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return '';
  var i = 0;
  String? province;
  if (_provinceAbbreviations.contains(tokens.first) ||
      _provincePattern.hasMatch(tokens.first)) {
    province = tokens.first;
    i = 1;
  }
  final parts = <String>[];
  while (i < tokens.length &&
      parts.length < 2 &&
      _sigunguPattern.hasMatch(tokens[i])) {
    parts.add(tokens[i]);
    i++;
  }
  String label;
  if (parts.length == 2) {
    label = parts.join().length <= 6 ? parts.join(' ') : parts.last;
  } else if (parts.length == 1) {
    label = parts.single;
  } else if (province != null && province.endsWith('특별자치시')) {
    label = province.replaceFirst('특별자치시', '시');
  } else {
    return '';
  }
  return '$label$suffix';
}

/// 지점의 지역 이름(시·군·구 우선). 일반 문구는 건너뛰고, 시·군·구를 못 찾으면 원문을 쓴다. 없으면 빈 문자열.
String mapPointRegionName(ReportMapPoint point) {
  for (final raw in [point.region, point.address]) {
    final text = raw.trim();
    if (text.isEmpty || isGenericMapLabel(text)) continue;
    final short = mapRegionShortLabel(text);
    return short.isNotEmpty ? short : text;
  }
  return '';
}

/// 여러 지점 중 신고 수가 가장 많은 지역 이름. 지역이 둘 이상이면 끝에 " 외"를 붙인다. 없으면 빈 문자열.
String dominantMapRegionLabel(Iterable<ReportMapPoint> points) {
  final counts = <String, int>{};
  var memberIsGroup = false;
  for (final point in points) {
    var name = mapPointRegionName(point);
    if (name.endsWith(' 외')) {
      name = name.substring(0, name.length - 2);
      memberIsGroup = true;
    }
    if (name.isEmpty) continue;
    counts[name] = (counts[name] ?? 0) + point.total;
  }
  if (counts.isEmpty) return '';
  var top = counts.entries.first;
  for (final entry in counts.entries.skip(1)) {
    final byCount = entry.value.compareTo(top.value);
    if (byCount > 0 || (byCount == 0 && entry.key.compareTo(top.key) < 0)) {
      top = entry;
    }
  }
  return counts.length > 1 || memberIsGroup ? '${top.key} 외' : top.key;
}
