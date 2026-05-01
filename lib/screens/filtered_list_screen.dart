import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/report_provider.dart';
import '../models/report.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import '../widgets/selection_action_bar.dart';

/// 대시보드/통계 카드 탭 시 해당 조건에 맞는 신고만 보여주는 화면
class FilteredListScreen extends StatefulWidget {
  final String title;

  /// 'all', 'traffic', 'parking', 'other'
  final String category;
  final bool Function(Report) filter;

  const FilteredListScreen({
    super.key,
    required this.title,
    required this.category,
    required this.filter,
  });

  @override
  State<FilteredListScreen> createState() => _FilteredListScreenState();
}

class _FilteredListScreenState extends State<FilteredListScreen> {
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<ReportProvider>();
      if (p.trafficReports.isEmpty) p.fetchTrafficReports();
      if (p.parkingReports.isEmpty) p.fetchParkingReports();
      if (p.otherReports.isEmpty) p.fetchOtherReports();
    });
  }

  void _toggleSelect(String rn) => setState(() {
    _selected.contains(rn) ? _selected.remove(rn) : _selected.add(rn);
  });

  void _clearSelection() => setState(() => _selected.clear());

  List<Report> _getReports(ReportProvider provider) {
    final List<Report> base;
    if (widget.category == 'traffic') {
      base = provider.trafficReports;
    } else if (widget.category == 'parking') {
      base = provider.parkingReports;
    } else if (widget.category == 'other') {
      base = provider.otherReports;
    } else {
      base = [
        ...provider.trafficReports,
        ...provider.parkingReports,
        ...provider.otherReports,
      ];
    }
    return base.where(widget.filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final reports = _getReports(provider);
    final selectedReports = reports
        .where((r) => _selected.contains(r.reportNumber))
        .toList();

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              ),
              title: Text('${_selected.length}개 선택됨'),
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            )
          : AppBar(
              title: Text(widget.title),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Center(
                    child: Text(
                      '${reports.length}건',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
      body: Stack(
        children: [
          provider.isLoading && reports.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : reports.isEmpty
              ? const Center(
                  child: Text(
                    '해당하는 신고가 없습니다.',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    8,
                    12,
                    _selectionMode ? 100 : 20,
                  ),
                  itemCount: reports.length,
                  itemBuilder: (ctx, i) => _buildCard(reports[i]),
                ),
          if (_selectionMode)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SelectionActionBar(
                selectedReports: selectedReports,
                onCancel: _clearSelection,
                onActionDone: _clearSelection,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCard(Report r) {
    final isSelected = _selected.contains(r.reportNumber);

    return ReportListCard(
      report: r,
      selectionMode: _selectionMode,
      isSelected: isSelected,
      onTap: _selectionMode
          ? () => _toggleSelect(r.reportNumber)
          : () => showReportDetailSheet(context, r),
      onLongPress: () {
        if (!_selectionMode) {
          setState(() => _selected.add(r.reportNumber));
        }
      },
      metaItems: [
        ReportCardMetaItem(
          icon: Icons.calendar_today,
          text: r.date.isNotEmpty ? '신고: ${r.date}' : '',
        ),
        ReportCardMetaItem(
          icon: Icons.event_available,
          text: r.responseDate.isNotEmpty ? '답변: ${r.responseDate}' : '',
        ),
        ReportCardMetaItem(icon: Icons.business, text: r.agency),
        ReportCardMetaItem(icon: Icons.person_outline, text: r.manager),
        ReportCardMetaItem(
          icon: Icons.monetization_on_outlined,
          text: r.fineInfo,
        ),
      ],
    );
  }
}
