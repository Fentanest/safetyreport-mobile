import 'package:flutter/material.dart';

import '../models/report_map.dart';
import '../services/map_presentation.dart';
import '../theme/sr_colors.dart';

/// 지도 마커 색 구간(과태료율). 경계값은 예전 `_mapPointColorForFineRate` 와 같다.
enum MapFineRateBand {
  high('과태료율 60% 이상', Color(0xFF2E7D32)),
  mid('과태료율 50~60%', Color(0xFFF57C00)),
  low('과태료율 50% 미만', Color(0xFFC62828));

  const MapFineRateBand(this.label, this.color);

  /// 범례·스크린리더에 쓰는 짧은 설명.
  final String label;

  /// 마커 원 채움색. 지도 타일은 테마와 무관하게 늘 밝으므로 테마별로 바꾸지 않는다.
  final Color color;

  static MapFineRateBand of(double fineRate) {
    if (fineRate >= 60) return MapFineRateBand.high;
    if (fineRate >= 50) return MapFineRateBand.mid;
    return MapFineRateBand.low;
  }
}

/// 여러 지점을 묶은(클러스터) 원 채움색.
const Color kMapClusterColor = Color(0xFF0D47A1);

/// 마커 아래 라벨에 보일 이름. 시·군·구 이름이 있으면 그것을, 없으면 의미 있는 대체 문구를 돌려준다.
/// 일반 문구("지도 구역 집계 …", "영역 집계")는 보이지 않는다.
String mapMarkerRegionLabel(ReportMapPoint point) {
  final name = mapPointRegionName(point);
  if (name.isNotEmpty) return name;
  if (point.isCluster) return '${point.total}건 묶음';
  return '${point.total}건';
}

/// 지도 마커 라벨. 지도 타일이 늘 밝은 색이라 라벨도 테마와 상관없이 밝은 바탕·어두운 글자로 고정한다
/// (다크 테마의 밝은 글자색을 물려받으면 흰 바탕에 흰 글자가 된다 — SQ-U03).
class MapMarkerRegionPill extends StatelessWidget {
  const MapMarkerRegionPill({
    super.key,
    required this.label,
    this.maxWidth = 92,
  });

  final String label;
  final double maxWidth;

  /// 라이트 팔레트 고정: 지도 타일 위에 놓이므로 앱 테마를 따르지 않는다.
  static Color get background => SrColors.light.surface.withValues(alpha: 0.94);
  static Color get foreground => SrColors.light.textPrimary;
  static const double fontSize = 11;

  @override
  Widget build(BuildContext context) {
    // 마커 상자 높이가 고정이라 큰 글꼴에서 넘치지 않게 배율을 1.5배로 제한한다.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: SrColors.light.border),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: foreground,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

/// 마커 색 범례(접이식). 색만으로 구분하지 않도록 구간 문구를 함께 보인다.
class MapFineRateLegend extends StatefulWidget {
  const MapFineRateLegend({super.key, this.initiallyExpanded = false});

  final bool initiallyExpanded;

  @override
  State<MapFineRateLegend> createState() => _MapFineRateLegendState();
}

class _MapFineRateLegendState extends State<MapFineRateLegend> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    final textStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: sr.textPrimary,
      height: 1.2,
    );
    return Semantics(
      container: true,
      child: Material(
        color: sr.surface.withValues(alpha: 0.96),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: sr.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              button: true,
              expanded: _expanded,
              label: _expanded ? '마커 색 범례 접기' : '마커 색 범례 펼치기',
              excludeSemantics: true,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_expanded) ...[
                          for (final band in MapFineRateBand.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: _Swatch(color: band.color, size: 10),
                            ),
                          const SizedBox(width: 4),
                        ],
                        Text(_expanded ? '마커 색 범례' : '과태료율', style: textStyle),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: sr.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final band in MapFineRateBand.values)
                      _LegendRow(
                        color: band.color,
                        label: band.label,
                        style: textStyle,
                      ),
                    _LegendRow(
                      color: kMapClusterColor,
                      label: '여러 지점 묶음',
                      style: textStyle,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.style,
  });

  final Color color;
  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Swatch(color: color, size: 14),
          const SizedBox(width: 8),
          Text(label, style: style),
        ],
      ),
    );
  }
}

/// 마커와 같은 모양(흰 테두리 원). 테두리가 있어 어두운 범례 바탕에서도 색 칸 경계가 보인다.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: SrColors.light.surface, width: 1.5),
      ),
    );
  }
}

/// OpenStreetMap 출처 표기(SQ-U10, ODbL·OSMF 타일 정책의 필수 조건).
/// flutter_map 의 `SimpleAttributionWidget` 은 줄바꿈 없는 Row 라 좁은 폭·큰 글꼴에서 넘치므로,
/// 테마 색을 쓰고 두 줄까지 접히는 작은 표기를 직접 둔다. 누르면 [onTap](저작권 안내 페이지 열기).
class MapOsmAttribution extends StatelessWidget {
  const MapOsmAttribution({super.key, this.onTap});

  static const String text = '© OpenStreetMap contributors';

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    return Semantics(
      link: true,
      label: 'OpenStreetMap 저작권 안내 열기',
      excludeSemantics: true,
      child: Material(
        color: sr.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                color: sr.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
