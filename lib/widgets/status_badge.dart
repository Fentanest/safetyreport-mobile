import 'package:flutter/material.dart';

import '../server_palette.dart';
import '../theme/sr_colors.dart';

/// 상태·처분 알약 배지. 색은 기준색을 [StatusTone] 으로 변환해 라이트/다크 모두 AA 대비를 맞춘다.
class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  final double fontSize;

  const StatusBadge({
    super.key,
    required this.label,
    required this.color,
    this.fontSize = 11,
  });

  /// 처리상태 문자열로 기준색을 고른다.
  factory StatusBadge.status(String status, {Key? key, double fontSize = 11}) =>
      StatusBadge(
        key: key,
        label: status,
        color: serverStatusColor(status),
        fontSize: fontSize,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = StatusTone.of(
      color,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.background,
        border: Border.all(color: tone.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: tone.foreground,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
