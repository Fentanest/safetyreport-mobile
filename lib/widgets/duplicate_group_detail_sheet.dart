import 'package:flutter/material.dart';

import '../models/duplicate_group.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/status_badge.dart';

import '../theme/sr_colors.dart';

void showDuplicateGroupDetailSheet(BuildContext context, DuplicateGroup group) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _DuplicateGroupDetailSheet(group: group),
  );
}

class _DuplicateGroupDetailSheet extends StatelessWidget {
  final DuplicateGroup group;

  const _DuplicateGroupDetailSheet({required this.group});

  Color _statusColor(BuildContext context, String value) {
    switch (value) {
      case DuplicateStatuses.confirmedDuplicate:
        return Colors.green;
      case DuplicateStatuses.notDuplicate:
        return context.sr.textSecondary;
      default:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final representative = group.representative;
    final statusColor = _statusColor(context, group.status);
    final cs = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: context.sr.border,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Row(
            children: [
              Icon(Icons.content_copy, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  representative?.report.name.isNotEmpty == true
                      ? representative!.report.name
                      : '중복 신고 그룹',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metaChip('상태', group.statusLabel, statusColor),
              _metaChip(
                '대표건',
                group.representativeModeLabel,
                group.representativeMode == RepresentativeModes.manual
                    ? context.sr.textSecondary
                    : cs.primary,
              ),
              _metaChip('멤버', '${group.memberCount}건', cs.tertiary),
            ],
          ),
          const SizedBox(height: 14),
          if (representative != null) ...[
            _sectionTitle('대표 신고'),
            _detailRow(context, 'ID', representative.reportId),
            _detailRow(context, '신고번호', representative.report.reportNumber),
            _detailRow(context, '신고명', representative.report.name),
            _detailRow(context, '처리상태', representative.report.statusWithFine),
            _detailRow(context, '처리기관', representative.report.agency),
            const SizedBox(height: 10),
          ],
          _sectionTitle('멤버 목록'),
          const SizedBox(height: 6),
          ...group.members.map(
            (member) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                leading: CircleAvatar(
                  radius: 15,
                  backgroundColor: member.isRepresentative
                      ? cs.primaryContainer
                      : context.sr.surfaceAlt,
                  child: Icon(
                    member.isRepresentative ? Icons.star : Icons.copy,
                    size: 16,
                    color: member.isRepresentative
                        ? cs.onPrimaryContainer
                        : context.sr.textSecondary,
                  ),
                ),
                title: Text(
                  member.report.name.isNotEmpty
                      ? member.report.name
                      : member.reportNumber,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ID ${member.reportId} · 신고번호 ${member.reportNumber}',
                        style: const TextStyle(fontSize: 11, height: 1.4),
                      ),
                      Text(
                        '${member.entryValue.isNotEmpty ? member.entryValue : member.category} · ${member.report.statusWithFine}',
                        style: const TextStyle(fontSize: 11, height: 1.4),
                      ),
                      if (member.report.agency.isNotEmpty)
                        Text(
                          member.report.agency,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, height: 1.4),
                        ),
                    ],
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: context.sr.textSecondary,
                ),
                onTap: () => showReportDetailSheet(context, member.report),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
    ),
  );

  Widget _detailRow(BuildContext context, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _metaChip(String label, String value, Color color) =>
      StatusBadge(label: '$label · $value', color: color);
}
