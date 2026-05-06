import 'package:flutter/material.dart';

import '../models/duplicate_group.dart';
import '../widgets/report_detail_sheet.dart';

void showDuplicateGroupDetailSheet(
  BuildContext context,
  DuplicateGroup group,
) {
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

  Color _statusColor(String value) {
    switch (value) {
      case DuplicateStatuses.confirmedDuplicate:
        return Colors.green;
      case DuplicateStatuses.notDuplicate:
        return Colors.grey;
      default:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final representative = group.representative;
    final statusColor = _statusColor(group.status);
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
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Row(
            children: [
              const Icon(Icons.content_copy, color: Colors.indigo),
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
                    ? Colors.blueGrey
                    : Colors.blue,
              ),
              _metaChip('멤버', '${group.memberCount}건', Colors.deepOrange),
            ],
          ),
          const SizedBox(height: 14),
          if (representative != null) ...[
            _sectionTitle('대표 신고'),
            _detailRow('ID', representative.reportId),
            _detailRow('신고번호', representative.report.reportNumber),
            _detailRow('신고명', representative.report.name),
            _detailRow('처리상태', representative.report.status),
            _detailRow('처리기관', representative.report.agency),
            _detailRow('범칙금/과태료', representative.report.fineInfo),
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
                      ? Colors.indigo.shade100
                      : Colors.grey.shade200,
                  child: Icon(
                    member.isRepresentative ? Icons.star : Icons.copy,
                    size: 16,
                    color: member.isRepresentative
                        ? Colors.indigo
                        : Colors.grey.shade700,
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
                        '${member.entryValue.isNotEmpty ? member.entryValue : member.category} · ${member.report.status}',
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
                trailing: const Icon(Icons.chevron_right),
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

  Widget _detailRow(String label, String value) {
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
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _metaChip(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      '$label · $value',
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}
