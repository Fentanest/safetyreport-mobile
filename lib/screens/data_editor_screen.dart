import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/editor_schema.dart';
import '../models/report.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/repositories/editor_repository.dart';
import '../widgets/search_filter_sheet.dart';

class DataEditorPanel extends StatefulWidget {
  const DataEditorPanel({super.key});

  @override
  State<DataEditorPanel> createState() => _DataEditorPanelState();
}

class _DataEditorPanelState extends State<DataEditorPanel> {
  static const _categories = <String>['traffic', 'parking', 'other'];
  String _selectedCategory = _categories.first;
  bool _preparing = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() {
      _preparing = true;
      _loadError = null;
    });
    try {
      await context.read<ReportProvider>().ensureCategoryReportsLoaded(
        forceRefresh: forceRefresh,
      );
    } catch (e) {
      _loadError = e.toString();
    } finally {
      if (mounted) {
        setState(() => _preparing = false);
      }
    }
  }

  void _openSearchPopup() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) =>
          SearchFilterSheet(provider: context.read<ReportProvider>()),
    );
  }

  String _categoryLabel(String category) {
    switch (category) {
      case 'parking':
        return '주정차';
      case 'other':
        return '기타위반';
      default:
        return '교통위반';
    }
  }

  List<Report> _reportsForCategory(ReportProvider provider) {
    final source = switch (_selectedCategory) {
      'parking' => provider.filteredParkingReports,
      'other' => provider.filteredOtherReports,
      _ => provider.filteredTrafficReports,
    };
    final items = List<Report>.from(source);
    items.sort((left, right) {
      final reportNumberCompare = right.reportNumber.compareTo(
        left.reportNumber,
      );
      if (reportNumberCompare != 0) return reportNumberCompare;
      return right.id.compareTo(left.id);
    });
    return items;
  }

  Future<void> _openEditor(Report report) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _EditableRecordSheet(report: report, category: _selectedCategory),
    );
    if (saved != true || !mounted) return;
    await context.read<ReportProvider>().refreshAll();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('수정 내용이 저장되었습니다.')));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final reports = _reportsForCategory(provider);
    final activeLabels = provider.filter.activeLabels;

    if (_preparing && reports.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && reports.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(_loadError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _prepare(forceRefresh: true),
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _prepare(forceRefresh: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '데이터 수정',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '신고번호 역순으로 정렬되며, 신고내역과 같은 상세검색을 그대로 사용할 수 있습니다.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _openSearchPopup,
                tooltip: '상세검색',
                icon: Badge(
                  isLabelVisible: provider.hasFilter,
                  child: const Icon(Icons.filter_list),
                ),
              ),
            ],
          ),
          if (provider.hasFilter && activeLabels.isNotEmpty) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: activeLabels
                    .map(
                      (label) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Chip(
                          label: Text(
                            label,
                            style: const TextStyle(fontSize: 11),
                          ),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _categories
                  .map(
                    (category) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_categoryLabel(category)),
                        selected: _selectedCategory == category,
                        onSelected: (_) {
                          setState(() => _selectedCategory = category);
                        },
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 12),
          if (reports.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  provider.hasFilter
                      ? '현재 검색 조건에 맞는 신고가 없습니다.'
                      : '수정 가능한 신고가 없습니다.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            )
          else
            ...reports.map(
              (report) => _EditableReportCard(
                report: report,
                categoryLabel: _categoryLabel(_selectedCategory),
                onTap: report.id.isEmpty ? null : () => _openEditor(report),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditableReportCard extends StatelessWidget {
  final Report report;
  final String categoryLabel;
  final VoidCallback? onTap;

  const _EditableReportCard({
    required this.report,
    required this.categoryLabel,
    required this.onTap,
  });

  Color _statusColor(String status) {
    if (status == '일부수용') return const Color(0xFF43A047);
    if (status.contains('수용') && !status.contains('불')) return Colors.green;
    if (status.contains('불수용')) return Colors.red;
    if (status.contains('처리') || status.contains('진행')) return Colors.orange;
    if (status == '취하') return Colors.brown;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(report.status);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      report.name.isEmpty ? '(제목 없음)' : report.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      report.status.isEmpty ? '처리상태 없음' : report.status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _InfoPill(label: categoryLabel),
                  _InfoPill(label: '신고번호 ${report.reportNumber}'),
                  _InfoPill(label: 'ID ${report.id}'),
                  if (report.date.isNotEmpty)
                    _InfoPill(label: '신고일 ${report.date}'),
                ],
              ),
              const SizedBox(height: 8),
              if (report.carNumber.isNotEmpty)
                Text(
                  '차량번호: ${report.carNumber}',
                  style: const TextStyle(fontSize: 12),
                ),
              if (report.agency.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '처리기관: ${report.agency}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ),
              if (report.manager.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '담당자: ${report.manager}',
                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final String label;

  const _InfoPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _EditableRecordSheet extends StatefulWidget {
  final Report report;
  final String category;

  const _EditableRecordSheet({required this.report, required this.category});

  @override
  State<_EditableRecordSheet> createState() => _EditableRecordSheetState();
}

class _EditableRecordSheetState extends State<_EditableRecordSheet> {
  final Map<String, TextEditingController> _controllers = {};
  late final EditorRepository _repository;
  EditorSchema _schema = EditorSchema.fallback();
  Map<String, dynamic>? _record;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  static const _statusOptions = <String>[
    '',
    '처리중',
    '보완요청',
    '수용',
    '일부수용',
    '불수용',
    '기타',
    '답변완료',
    '취하',
    '이송',
  ];
  static const _finishOptions = <String>['', 'Y', 'N'];
  static const _multilineFields = <String>{'신고내용', '처리내용', '첨부사진', '첨부파일'};
  static const _dateFields = <String>{'답변일', '발생일자'};

  @override
  void initState() {
    super.initState();
    _repository = EditorRepository.fromProvider(context.read<ReportProvider>());
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final schema = await _repository.getSchema();
      final record = await _repository.getRecord(
        widget.category,
        widget.report.id,
      );
      if (record == null) {
        throw Exception('수정할 신고 데이터를 찾을 수 없습니다.');
      }
      for (final controller in _controllers.values) {
        controller.dispose();
      }
      _controllers.clear();
      for (final field in schema.detailFields) {
        _controllers[field] = TextEditingController(
          text: record[field]?.toString() ?? '',
        );
      }
      if (!mounted) return;
      setState(() {
        _schema = schema;
        _record = record;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiFeatureUnavailableException ? e.message : e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickDate(String field) async {
    final controller = _controllers[field];
    if (controller == null) return;
    final now = DateTime.now();
    final current = DateTime.tryParse(controller.text.trim()) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    controller.text =
        '${picked.year}-${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final values = <String, dynamic>{
        for (final field in _schema.detailFields)
          field: _controllers[field]?.text.trim() ?? '',
      };
      final updated = await _repository.saveRecord(
        widget.category,
        widget.report.id,
        values,
      );
      if (!updated) {
        throw Exception('저장 대상이 존재하지 않습니다.');
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('저장 실패: $e')));
      setState(() => _saving = false);
    }
  }

  Widget _buildReadOnlySummary() {
    final record = _record!;
    final titleFields = _schema.titleFields;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6E9EF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('신고 기본 정보', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoPill(
                label: 'ID ${record['ID']?.toString() ?? widget.report.id}',
              ),
              for (final field in titleFields)
                if ((record[field]?.toString().trim() ?? '').isNotEmpty)
                  _InfoPill(label: '$field ${record[field].toString().trim()}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildField(String field) {
    final controller = _controllers[field]!;
    if (field == '처리상태') {
      return _buildDropdownField(field, controller, _statusOptions);
    }
    if (field == '종결여부') {
      return _buildDropdownField(field, controller, _finishOptions);
    }

    final isMultiline = _multilineFields.contains(field);
    final isDate = _dateFields.contains(field);
    final keyboardType = field == '발생시각'
        ? TextInputType.datetime
        : TextInputType.text;

    return TextField(
      controller: controller,
      readOnly: isDate,
      minLines: isMultiline ? 3 : 1,
      maxLines: isMultiline ? 5 : 1,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: field,
        helperText: field == '범칙금_과태료' ? _schema.fineInfoExample : null,
        suffixIcon: isDate
            ? IconButton(
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                onPressed: () => _pickDate(field),
              )
            : null,
      ),
    );
  }

  Widget _buildDropdownField(
    String field,
    TextEditingController controller,
    List<String> options,
  ) {
    final current = options.contains(controller.text) ? controller.text : '';
    return DropdownButtonFormField<String>(
      initialValue: current,
      decoration: InputDecoration(labelText: field),
      items: options
          .map(
            (option) => DropdownMenuItem<String>(
              value: option,
              child: Text(option.isEmpty ? '(없음)' : option),
            ),
          )
          .toList(),
      onChanged: (value) {
        controller.text = value ?? '';
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.9,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 48,
                        color: Colors.red,
                      ),
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('다시 시도'),
                      ),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.report.reportNumber.isEmpty
                          ? '데이터 수정'
                          : '데이터 수정 · ${widget.report.reportNumber}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '서버 페이지와 같은 순서로 수정 항목을 보여줍니다. 저장 시 즉시 DB에 반영됩니다.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView(
                        children: [
                          _buildReadOnlySummary(),
                          const SizedBox(height: 12),
                          ..._schema.detailFields.map(
                            (field) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _buildField(field),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
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
}
