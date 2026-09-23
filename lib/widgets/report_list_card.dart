import 'package:flutter/material.dart';

import '../models/report.dart';
import '../server_palette.dart';
import '../theme/sr_colors.dart';
import 'status_badge.dart';

class ReportCardMetaItem {
  final IconData icon;
  final String text;

  const ReportCardMetaItem({required this.icon, required this.text});
}

Color reportStatusColor(String status) {
  return serverStatusColor(status);
}

/// 신고 카드 공용 UI (`report_list`/`search`/`filtered_list`/지도 미변환 목록).
///
/// 표시 필드: 신고명, 처리상태, headerSuffix, 신고번호, 보완횟수/보완 요청자, 메타 행, 차량번호.
/// 긴 신고명·기관명·차량번호가 다른 정보를 밀어내지 않도록 모든 가로 요소가 줄어들 수 있다.
class ReportListCard extends StatelessWidget {
  final Report report;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final List<ReportCardMetaItem> metaItems;
  final Widget? headerSuffix;

  const ReportListCard({
    super.key,
    required this.report,
    required this.selectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.metaItems,
    this.headerSuffix,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sr = context.sr;
    final supplementRequester = report.supplementRequester.trim();
    final supplementTone = StatusTone.of(
      serverSupplementColor,
      brightness: theme.brightness,
      surface: scheme.surface,
    );
    final visibleMetaItems = metaItems
        .where((item) => item.text.trim().isNotEmpty)
        .toList(growable: false);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected ? scheme.primary : sr.border,
          width: isSelected ? 2 : 1,
        ),
      ),
      color: isSelected ? sr.brandSoft : scheme.surface,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 10, top: 1),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isSelected ? scheme.primary : sr.textSecondary,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            report.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                              height: 1.3,
                              color: sr.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: StatusBadge.status(report.status),
                        ),
                        if (headerSuffix != null) ...[
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 96),
                            child: headerSuffix!,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.tag, size: 13, color: sr.textSecondary),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            report.reportNumber,
                            style: TextStyle(
                              color: sr.textSecondary,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (report.supplementCount > 0) ...[
                          const SizedBox(width: 6),
                          StatusBadge(
                            label: '보완횟수:${report.supplementCount}회',
                            color: serverSupplementColor,
                            fontSize: 10,
                          ),
                        ],
                      ],
                    ),
                    if (report.supplementCount > 0 &&
                        supplementRequester.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.history_edu,
                            size: 12,
                            color: supplementTone.foreground,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '보완 요청자: $supplementRequester',
                              style: TextStyle(
                                color: supplementTone.foreground,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    Divider(height: 16, color: sr.border),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var i = 0;
                                i < visibleMetaItems.length;
                                i++
                              ) ...[
                                if (i > 0) const SizedBox(height: 3),
                                _MetaRow(
                                  icon: visibleMetaItems[i].icon,
                                  text: visibleMetaItems[i].text,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (report.carNumber.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          // 차량번호가 비정상적으로 길어도 행 너비의 40% 를 넘지 않는다.
                          Flexible(
                            flex: 2,
                            child: Align(
                              alignment: Alignment.bottomRight,
                              child: _CarNumberChip(
                                carNumber: report.carNumber,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    return Row(
      children: [
        Icon(icon, size: 12, color: sr.textSecondary),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: sr.textSecondary, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _CarNumberChip extends StatelessWidget {
  final String carNumber;

  const _CarNumberChip({required this.carNumber});

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: sr.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: sr.border),
      ),
      child: Text(
        carNumber,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          letterSpacing: 0.4,
          color: sr.textPrimary,
        ),
      ),
    );
  }
}
