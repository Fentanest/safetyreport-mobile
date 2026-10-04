import 'package:flutter/material.dart';

/// 앱바 하단 알약형 탭. 색·글자는 `AppTheme` 의 tabBarTheme 을 따른다.
/// 탭 수·순서·스와이프 동작은 호출부의 [TabController] 그대로다.
///
/// 큰 글자(SQ-U04): 높이는 [textScaler] 에 맞춰 늘고, 탭 이름이 같은 폭 칸에 다 들어가지 않으면
/// 가로 스크롤 탭(왼쪽 정렬)으로 바뀐다. 탭 이름은 한 줄로 끝까지 보인다.
class SrTabBar extends StatelessWidget implements PreferredSizeWidget {
  const SrTabBar({
    super.key,
    this.controller,
    required this.labels,
    this.badgeCounts,
    this.textScaler = TextScaler.noScaling,
  }) : assert(badgeCounts == null || badgeCounts.length == labels.length);

  final TabController? controller;

  /// 탭 이름(순서 = 탭 인덱스).
  final List<String> labels;

  /// 탭별 읽지 않은 수. 0 이하는 배지를 그리지 않는다.
  final List<int>? badgeCounts;

  /// 앱바가 높이를 미리 알아야 하므로 호출부가 `MediaQuery.textScalerOf(context)` 를 넘긴다.
  final TextScaler textScaler;

  static const double baseHeight = 48;
  static const double _labelFontSize = 13.5;
  static const double _badgeFontSize = 11;
  static const EdgeInsets _barPadding = EdgeInsets.fromLTRB(12, 0, 12, 0);

  /// 알약 아래 여백. 예전에는 막대 바깥 여백이라 탭을 누르는 영역이 42dp 였다.
  /// 이제 탭 안쪽(글자 여백·알약 여백)에 두어 보이는 모양은 같고 누르는 영역은 막대 높이(48dp 이상)다(SQ-U20).
  static const double _tabBottomGap = 6;
  static const double _indicatorWeight = 2;

  /// 글자 배율에 맞춘 탭 막대 높이. 1.0배는 기존 48 그대로다.
  static double heightFor(TextScaler scaler) {
    final extra = scaler.scale(_labelFontSize) - _labelFontSize;
    if (extra <= 0) return baseHeight;
    return (baseHeight + extra * 1.5).ceilToDouble();
  }

  @override
  Size get preferredSize => Size.fromHeight(heightFor(textScaler));

  int _badge(int index) {
    final counts = badgeCounts;
    if (counts == null || index >= counts.length) return 0;
    return counts[index];
  }

  double _textWidth(
    BuildContext context,
    String text,
    TextStyle style,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// 탭 하나가 이름을 자르지 않고 그리는 데 필요한 폭(좌우 여백 포함).
  double _neededWidth(
    BuildContext context,
    int index,
    TextStyle labelStyle,
    EdgeInsetsGeometry labelPadding,
    TextScaler scaler,
  ) {
    var width =
        _textWidth(context, labels[index], labelStyle, scaler) +
        labelPadding.horizontal;
    final badge = _badge(index);
    if (badge > 0) {
      width +=
          6 +
          12 +
          _textWidth(
            context,
            '$badge',
            const TextStyle(
              fontSize: _badgeFontSize,
              fontWeight: FontWeight.bold,
            ),
            scaler,
          );
    }
    // 반올림·글리프 여유.
    return width + 2;
  }

  Widget _badgeChip(BuildContext context, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.error,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: _badgeFontSize,
          color: scheme.onError,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Tab _tab(BuildContext context, int index, double? tabHeight) {
    final label = labels[index];
    final badge = _badge(index);
    if (badge <= 0) return Tab(text: label, height: tabHeight);
    return Tab(
      height: tabHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, maxLines: 1, softWrap: false),
          const SizedBox(width: 6),
          _badgeChip(context, badge),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = heightFor(textScaler);
    final scaled = height > baseHeight;
    final tabTheme = TabBarTheme.of(context);
    final labelStyle =
        tabTheme.labelStyle ??
        Theme.of(context).textTheme.titleSmall ??
        const TextStyle(fontSize: _labelFontSize);
    final labelPadding =
        tabTheme.labelPadding ?? const EdgeInsets.symmetric(horizontal: 16);
    final scaler = MediaQuery.textScalerOf(context);
    // 1.0배는 기존 탭(높이 기본값) 그대로. 커지면 막대 높이에 맞춰 탭 높이를 준다.
    final tabHeight = scaled
        ? height - _barPadding.vertical - _tabBottomGap - _indicatorWeight
        : null;

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth - _barPadding.horizontal;
          final perTab = available / labels.length;
          var fits = true;
          for (var i = 0; i < labels.length; i++) {
            if (_neededWidth(context, i, labelStyle, labelPadding, scaler) >
                perTab) {
              fits = false;
              break;
            }
          }
          return TabBar(
            controller: controller,
            tabs: [
              for (var i = 0; i < labels.length; i++)
                _tab(context, i, tabHeight),
            ],
            isScrollable: !fits,
            tabAlignment: fits ? null : TabAlignment.start,
            padding: _barPadding,
            labelPadding: labelPadding.add(
              const EdgeInsets.only(bottom: _tabBottomGap),
            ),
            indicatorPadding: const EdgeInsets.fromLTRB(
              0,
              4,
              0,
              4 + _tabBottomGap,
            ),
          );
        },
      ),
    );
  }
}
