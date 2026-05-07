import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../models/duplicate_group.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/repositories/duplicate_repository.dart';
import '../widgets/duplicate_group_detail_sheet.dart';
import '../widgets/report_detail_sheet.dart';

class DuplicateManagementPanel extends StatefulWidget {
  const DuplicateManagementPanel({super.key});

  @override
  State<DuplicateManagementPanel> createState() => _DuplicateManagementPanelState();
}

class _DuplicateManagementPanelState extends State<DuplicateManagementPanel> {
  bool _loading = true;
  String? _error;
  String? _infoMessage;
  String _statusFilter = '';
  List<DuplicateGroup> _groups = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _infoMessage = null;
    });
    try {
      final provider = context.read<ReportProvider>();
      final repo = DuplicateRepository.fromProvider(provider);
      final groups = await repo.getGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        if (provider.appMode == AppMode.server && groups.isEmpty) {
          _infoMessage = '현재 표시할 중복 신고 그룹이 없습니다.';
        }
        _loading = false;
      });
    } on ApiFeatureUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _groups = const [];
        _infoMessage = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<DuplicateGroup> get _filteredGroups {
    if (_statusFilter.isEmpty) return _groups;
    return _groups.where((group) => group.status == _statusFilter).toList();
  }

  int _countByStatus(String? status) {
    if (status == null || status.isEmpty) return _groups.length;
    return _groups.where((group) => group.status == status).length;
  }

  Future<void> _saveGroup(
    DuplicateGroup group, {
    required String duplicateStatus,
    required String representativeMode,
    required String representativeId,
    required String note,
  }) async {
    final provider = context.read<ReportProvider>();
    final repo = DuplicateRepository.fromProvider(provider);
    await repo.updateGroup(
      group.groupId,
      duplicateStatus: duplicateStatus,
      representativeMode: representativeMode,
      representativeId: representativeId,
      note: note,
    );
    await provider.refreshAll();
    await _load();
  }

  Future<void> _openEditor(DuplicateGroup group) async {
    final noteCtrl = TextEditingController(text: group.note);
    var duplicateStatus = group.status;
    var representativeMode = group.representativeMode;
    var representativeId =
        group.representativeId.isNotEmpty
            ? group.representativeId
            : (group.representative?.reportId ?? '');
    var saving = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.82,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (_, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
                      group.representative?.report.name.isNotEmpty == true
                          ? group.representative!.report.name
                          : '중복 신고 그룹',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => showDuplicateGroupDetailSheet(sheetCtx, group),
                    child: const Text('상세 보기'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: duplicateStatus,
                decoration: const InputDecoration(
                  labelText: '중복 상태',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: DuplicateStatuses.reviewRequired,
                    child: Text('검토 필요'),
                  ),
                  DropdownMenuItem(
                    value: DuplicateStatuses.confirmedDuplicate,
                    child: Text('중복 확정'),
                  ),
                  DropdownMenuItem(
                    value: DuplicateStatuses.notDuplicate,
                    child: Text('중복 아님'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setSheetState(() => duplicateStatus = value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: representativeMode,
                decoration: const InputDecoration(
                  labelText: '대표건 선정',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: RepresentativeModes.auto,
                    child: Text('자동 선정'),
                  ),
                  DropdownMenuItem(
                    value: RepresentativeModes.manual,
                    child: Text('수동 고정'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setSheetState(() => representativeMode = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                  labelText: '비고',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              const Text(
                '대표 후보',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...group.members.map(
                (member) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: RadioListTile<String>(
                    value: member.reportId,
                    groupValue: representativeId,
                    onChanged: (value) {
                      if (value == null) return;
                      setSheetState(() {
                        representativeId = value;
                        representativeMode = RepresentativeModes.manual;
                      });
                    },
                    title: Text(
                      member.report.reportNumber.isNotEmpty
                          ? member.report.reportNumber
                          : member.reportId,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (member.report.name.isNotEmpty)
                          Text(
                            member.report.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(
                          '${member.entryValue.isNotEmpty ? member.entryValue : member.category} · ${member.report.statusWithFine}',
                        ),
                        if (member.report.agency.isNotEmpty)
                          Text(
                            member.report.agency,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                    secondary: IconButton(
                      icon: const Icon(Icons.open_in_new),
                      tooltip: '상세 보기',
                      onPressed: () => showReportDetailSheet(context, member.report),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: saving
                    ? null
                    : () async {
                        setSheetState(() => saving = true);
                        try {
                          await _saveGroup(
                            group,
                            duplicateStatus: duplicateStatus,
                            representativeMode: representativeMode,
                            representativeId: representativeId,
                            note: noteCtrl.text.trim(),
                          );
                          if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                        } catch (e) {
                          if (!sheetCtx.mounted) return;
                          ScaffoldMessenger.of(sheetCtx).showSnackBar(
                            SnackBar(content: Text('저장 실패: $e')),
                          );
                        } finally {
                          if (sheetCtx.mounted) {
                            setSheetState(() => saving = false);
                          }
                        }
                      },
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('저장'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
              onPressed: _load,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          const Text(
            '중복 신고',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _StatusCard(
                  label: '전체',
                  count: _countByStatus(null),
                  selected: _statusFilter.isEmpty,
                  onTap: () => setState(() => _statusFilter = ''),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatusCard(
                  label: '검토 필요',
                  count: _countByStatus(DuplicateStatuses.reviewRequired),
                  selected: _statusFilter == DuplicateStatuses.reviewRequired,
                  onTap: () => setState(
                    () => _statusFilter = DuplicateStatuses.reviewRequired,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _StatusCard(
                  label: '중복 확정',
                  count: _countByStatus(DuplicateStatuses.confirmedDuplicate),
                  selected: _statusFilter == DuplicateStatuses.confirmedDuplicate,
                  onTap: () => setState(
                    () => _statusFilter = DuplicateStatuses.confirmedDuplicate,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatusCard(
                  label: '중복 아님',
                  count: _countByStatus(DuplicateStatuses.notDuplicate),
                  selected: _statusFilter == DuplicateStatuses.notDuplicate,
                  onTap: () => setState(
                    () => _statusFilter = DuplicateStatuses.notDuplicate,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_filteredGroups.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  _infoMessage ?? '현재 조건에 맞는 중복 신고 그룹이 없습니다.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            )
          else
            ..._filteredGroups.map(
              (group) => _DuplicateGroupCard(
                group: group,
                onTap: () => _openEditor(group),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _StatusCard({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              Text(
                '$count건',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DuplicateGroupCard extends StatelessWidget {
  final DuplicateGroup group;
  final VoidCallback onTap;

  const _DuplicateGroupCard({required this.group, required this.onTap});

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
    final rep = group.representative;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        title: Text(
          rep?.report.name.isNotEmpty == true
              ? rep!.report.name
              : (rep?.report.reportNumber ?? '중복 신고 그룹'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rep != null)
                Text(
                  '대표 신고번호 ${rep.report.reportNumber} · ${rep.report.statusWithFine}',
                  style: const TextStyle(fontSize: 12),
                ),
              Text(
                '멤버 ${group.memberCount}건 · ${group.representativeModeLabel}',
                style: const TextStyle(fontSize: 12),
              ),
              if (rep?.report.agency.isNotEmpty == true)
                Text(
                  rep!.report.agency,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _statusColor(group.status).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _statusColor(group.status).withValues(alpha: 0.4)),
          ),
          child: Text(
            group.statusLabel,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _statusColor(group.status),
            ),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
