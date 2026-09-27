import 'package:flutter/material.dart';

import '../models/agency_stats.dart';
import '../server_palette.dart';
import '../theme/sr_colors.dart';

/// 기관·담당자 행의 금액과 건수. 추정 건수는 금액 미확인 건수의 부분집합이다.
class StatsFineBreakdown extends StatelessWidget {
  final AgencyStatRow row;

  const StatsFineBreakdown({super.key, required this.row});

  String _formatFine(int amount) {
    if (amount >= 10000) {
      final man = amount ~/ 10000;
      final rest = amount % 10000;
      if (rest == 0) return '$man만원';
      return '$man만 ${_comma(rest)}원';
    }
    return '${_comma(amount)}원';
  }

  String _comma(int value) => value.toString().replaceAllMapped(
    RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]},',
  );

  @override
  Widget build(BuildContext context) {
    final estimatedCount = row.estimatedFineCount ?? 0;
    final hasFine =
        row.fines > 0 || row.totalFineAmount > 0 || estimatedCount > 0;
    if (!hasFine) return const SizedBox.shrink();

    final theme = Theme.of(context);
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
        children: [
          Text(
            '확정 ${_formatFine(row.totalFineAmount)} ($confirmedCount건)',
            softWrap: true,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: fineColor,
            ),
          ),
          if (row.fineAmountUnknown > 0)
            Text(
              '금액 미확인 ${row.fineAmountUnknown}건',
              softWrap: true,
              style: TextStyle(fontSize: 11, color: context.sr.textSecondary),
            ),
          if (estimatedCount > 0)
            Text(
              row.estimatedFineAmount == null
                  ? '추정 금액 미지원 ($estimatedCount건)'
                  : '추정 ${_formatFine(row.estimatedFineAmount!)} ($estimatedCount건)',
              softWrap: true,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: fineColor,
              ),
            ),
        ],
      ),
    );
  }
}
