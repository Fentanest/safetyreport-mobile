import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/agency_stats.dart';
import '../server_palette.dart';
import '../theme/sr_colors.dart';
import '../utils/format.dart';

/// 기관·담당자 행의 금액과 건수. 추정 건수는 금액 미확인 건수의 부분집합이다.
///
/// 확정(답변에 적힌 금액)은 과태료 색·굵게, 추정(규칙으로 계산한 법정 최저)은 보조 글자색·보통 굵기에
/// 점선 "추정" 배지를 붙여 한눈에 구분한다(SQ-U25). 둘을 더한 숫자는 어디에도 보이지 않는다.
/// 금액은 앱 공통 전체 쉼표 표기([formatWon])를 쓴다(SQ-U22).
class StatsFineBreakdown extends StatelessWidget {
  final AgencyStatRow row;

  const StatsFineBreakdown({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    final estimatedCount = row.estimatedFineCount ?? 0;
    final hasFine =
        row.fines > 0 || row.totalFineAmount > 0 || estimatedCount > 0;
    if (!hasFine) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final sr = context.sr;
    final fineColor = StatusTone.of(
      serverTrafficFineColor,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    ).foreground;
    final confirmedCount = (row.fines - row.fineAmountUnknown).clamp(
      0,
      row.fines,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '확정 ${formatWon(row.totalFineAmount)} (${formatCount(confirmedCount)})',
            softWrap: true,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: fineColor,
            ),
          ),
          if (row.fineAmountUnknown > 0)
            Text(
              '금액 미확인 ${formatCount(row.fineAmountUnknown)}',
              softWrap: true,
              style: TextStyle(fontSize: 11, color: sr.textSecondary),
            ),
          if (estimatedCount > 0)
            MergeSemantics(
              child: Row(
                key: const ValueKey('stats-fine-estimated'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EstimateBadge(),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      row.estimatedFineAmount == null
                          ? '금액 미지원 (${formatCount(estimatedCount)})'
                          : '${formatWon(row.estimatedFineAmount!)} (${formatCount(estimatedCount)})',
                      softWrap: true,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: sr.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 점선 테두리 "추정" 배지 — 확정 금액과 다른, 계산으로 낸 값임을 색이 아닌 모양으로도 알린다.
class EstimateBadge extends StatelessWidget {
  const EstimateBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    return CustomPaint(
      painter: _DashedRRectPainter(color: sr.textSecondary),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          '추정',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: sr.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;

  const _DashedRRectPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const dash = 3.0;
    const gap = 2.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.5),
      const Radius.circular(4),
    );
    final path = Path()..addRRect(rrect);
    for (final ui.PathMetric metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color;
}
