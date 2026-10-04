import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../services/repositories/duplicate_repository.dart';

import '../models/duplicate_group.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/status_badge.dart';

import '../theme/sr_colors.dart';
import '../theme/sr_tokens.dart';

void showDuplicateGroupDetailSheet(BuildContext context, DuplicateGroup group) {
  final provider = Provider.of<ReportProvider?>(context, listen: false);
  final epoch = provider?.datasetEpoch;
  final repository = provider?.appMode == AppMode.standalone
      ? DuplicateRepository.fromProvider(provider!)
      : null;
  final loader = repository != null
      ? (int page) async {
          if (provider!.datasetEpoch != epoch) {
            throw StateError('자료/계정이 바뀌었습니다. 화면을 다시 열어 주세요.');
          }
          final members = await repository.getMembers(
            group.groupId,
            page: page,
          );
          if (provider.datasetEpoch != epoch) {
            throw StateError('자료/계정이 바뀌었습니다. 화면을 다시 열어 주세요.');
          }
          return members;
        }
      : null;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    // 전체 높이까지 끌어올려도 상태 표시줄 아래에서 멈춘다(SQ-U07).
    useSafeArea: true,
    builder: (_) => _DuplicateGroupDetailSheet(group: group, loadPage: loader),
  );
}

class _DuplicateGroupDetailSheet extends StatefulWidget {
  final DuplicateGroup group;
  final Future<List<DuplicateMember>> Function(int)? loadPage;
  const _DuplicateGroupDetailSheet({required this.group, this.loadPage});
  @override
  State<_DuplicateGroupDetailSheet> createState() =>
      _DuplicateGroupDetailSheetState();
}

class _DuplicateGroupDetailSheetState
    extends State<_DuplicateGroupDetailSheet> {
  DuplicateGroup get group => widget.group;
  late List<DuplicateMember> _members;
  int _page = 0;
  bool _loading = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _members = group.members;
    if (_members.isEmpty && widget.loadPage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(0));
    }
  }

  Future<void> _load(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.loadPage!(page);
      if (mounted) {
        setState(() {
          _members = rows;
          _page = page;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(BuildContext context, String value) {
    switch (value) {
      case DuplicateStatuses.confirmedDuplicate:
        return context.semantic(SrTone.success);
      case DuplicateStatuses.notDuplicate:
        return context.semantic(SrTone.neutral);
      default:
        return context.semantic(SrTone.warning);
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
        // 손잡이는 테마(showDragHandle)가 그린다(SQ-U07).
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: [
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
          ..._members.map(
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
                        style: const TextStyle(
                          fontSize: SrFontSize.caption,
                          height: 1.4,
                        ),
                      ),
                      Text(
                        '${member.entryValue.isNotEmpty ? member.entryValue : member.category} · ${member.report.statusWithFine}',
                        style: const TextStyle(
                          fontSize: SrFontSize.caption,
                          height: 1.4,
                        ),
                      ),
                      if (member.report.agency.isNotEmpty)
                        Text(
                          member.report.agency,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: SrFontSize.caption,
                            height: 1.4,
                          ),
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
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (widget.loadPage != null && group.memberCount > 50) ...[
            Text(
              '${_page * 50 + 1}–${_page * 50 + _members.length} / 전체 ${group.memberCount}건',
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: !_loading && _page > 0
                      ? () => _load(_page - 1)
                      : null,
                  child: const Text('이전 멤버'),
                ),
                TextButton(
                  onPressed: !_loading && (_page + 1) * 50 < group.memberCount
                      ? () => _load(_page + 1)
                      : null,
                  child: const Text('다음 멤버'),
                ),
              ],
            ),
          ],
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
