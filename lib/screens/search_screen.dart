import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/report_provider.dart';
import '../models/report.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import '../widgets/search_filter_sheet.dart';
import '../widgets/selection_action_bar.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<ReportProvider>();
      if (provider.trafficReports.isEmpty &&
          provider.parkingReports.isEmpty &&
          provider.otherReports.isEmpty) {
        provider.fetchTrafficReports();
        provider.fetchParkingReports();
        provider.fetchOtherReports();
      }
    });
  }

  void _toggleSelect(String reportNumber) {
    setState(() {
      if (_selected.contains(reportNumber)) {
        _selected.remove(reportNumber);
      } else {
        _selected.add(reportNumber);
      }
    });
  }

  void _clearSelection() => setState(() => _selected.clear());

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

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final allFiltered = [
      ...provider.filteredTrafficReports,
      ...provider.filteredParkingReports,
      ...provider.filteredOtherReports,
    ];
    final hasFilter = provider.hasFilter;
    final labels = provider.filter.activeLabels;
    final selectedReports = allFiltered
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
              title: const Text('검색'),
              actions: [
                if (hasFilter)
                  TextButton(
                    onPressed: provider.clearFilter,
                    child: const Text(
                      '초기화',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                IconButton(
                  icon: Badge(
                    isLabelVisible: hasFilter,
                    child: const Icon(Icons.tune),
                  ),
                  tooltip: '검색 조건',
                  onPressed: _openSearchPopup,
                ),
              ],
            ),
      body: Stack(
        children: [
          Column(
            children: [
              // 활성 필터 요약 바
              if (hasFilter && labels.isNotEmpty)
                Container(
                  color: Colors.blue.shade50,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: labels
                          .map(
                            (l) => Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Chip(
                                label: Text(
                                  l,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                backgroundColor: Colors.blue.shade100,
                                padding: EdgeInsets.zero,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              // 결과 헤더
              if (hasFilter)
                Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.format_list_bulleted, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        '검색 결과: ${allFiltered.length}건',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: provider.isLoading && allFiltered.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : !hasFilter
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search,
                              size: 72,
                              color: Colors.grey.shade300,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              '검색 조건을 설정하세요.',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              icon: const Icon(Icons.tune),
                              label: const Text('검색 조건 설정'),
                              onPressed: _openSearchPopup,
                            ),
                          ],
                        ),
                      )
                    : allFiltered.isEmpty
                    ? const Center(child: Text('검색 결과가 없습니다.'))
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          8,
                          12,
                          _selectionMode ? 100 : 20,
                        ),
                        itemCount: allFiltered.length,
                        itemBuilder: (context, index) =>
                            _buildReportCard(allFiltered[index]),
                      ),
              ),
            ],
          ),
          // 선택 액션 바
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
      floatingActionButton: !hasFilter && !_selectionMode
          ? FloatingActionButton.extended(
              onPressed: _openSearchPopup,
              icon: const Icon(Icons.search),
              label: const Text('검색'),
            )
          : null,
    );
  }

  Widget _buildReportCard(Report r) {
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
        ReportCardMetaItem(icon: Icons.calendar_today, text: r.date),
        ReportCardMetaItem(icon: Icons.business, text: r.agency),
        ReportCardMetaItem(
          icon: Icons.monetization_on_outlined,
          text: r.fineInfo,
        ),
      ],
    );
  }
}
