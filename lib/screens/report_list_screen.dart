import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/report_provider.dart';
import '../models/report.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import '../widgets/search_filter_sheet.dart';
import '../widgets/selection_action_bar.dart';
import 'settings_screen.dart';

class ReportListScreen extends StatefulWidget {
  final int initialTabIndex;

  const ReportListScreen({super.key, this.initialTabIndex = 0});

  @override
  State<ReportListScreen> createState() => _ReportListScreenState();
}

class _ReportListScreenState extends State<ReportListScreen>
    with TickerProviderStateMixin {
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;
  late TabController _tabController;
  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTabIndex < 0
          ? 0
          : widget.initialTabIndex > 3
          ? 3
          : widget.initialTabIndex,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ReportProvider>().fetchTrafficReports();
      context.read<ReportProvider>().fetchParkingReports();
      context.read<ReportProvider>().fetchOtherReports();
      context.read<ReportProvider>().fetchDuplicateReports();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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

  void _selectAllCurrentTab() {
    final provider = context.read<ReportProvider>();
    final List<Report> currentReports;
    switch (_tabController.index) {
      case 0:
        currentReports = provider.filteredTrafficReports;
        break;
      case 1:
        currentReports = provider.filteredParkingReports;
        break;
      case 2:
        currentReports = provider.filteredOtherReports;
        break;
      default:
        currentReports = [];
        break;
    }
    setState(() {
      for (final r in currentReports) {
        _selected.add(r.reportNumber);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final activeLabels = provider.filter.activeLabels;

    final allReports = [
      ...provider.filteredTrafficReports,
      ...provider.filteredParkingReports,
      ...provider.filteredOtherReports,
    ];
    final selectedReports = allReports
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
              actions: [
                TextButton(
                  onPressed: _selectAllCurrentTab,
                  child: Text(
                    '전체 선택',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            )
          : AppBar(
              title: const Text('신고 내역'),
              actions: [
                IconButton(
                  icon: Badge(
                    isLabelVisible: provider.hasFilter,
                    child: const Icon(Icons.filter_list),
                  ),
                  tooltip: '검색/필터',
                  onPressed: () => _showSearchPopup(context),
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  tooltip: '설정',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
              bottom: TabBar(
                controller: _tabController,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                indicatorWeight: 3,
                tabs: const [
                  Tab(text: '교통위반'),
                  Tab(text: '주정차'),
                  Tab(text: '기타위반'),
                  Tab(text: '중복차량'),
                ],
              ),
            ),
      body: Stack(
        children: [
          Column(
            children: [
              if (provider.hasFilter && activeLabels.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: Colors.blue.shade50,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: SingleChildScrollView(
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
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTab(
                      provider,
                      provider.filteredTrafficReports,
                      provider.fetchTrafficReports,
                    ),
                    _buildTab(
                      provider,
                      provider.filteredParkingReports,
                      provider.fetchParkingReports,
                    ),
                    _buildTab(
                      provider,
                      provider.filteredOtherReports,
                      provider.fetchOtherReports,
                    ),
                    _buildDuplicateTab(provider),
                  ],
                ),
              ),
            ],
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

  Widget _buildTab(
    ReportProvider provider,
    List<Report> reports,
    Future<void> Function() onRefresh,
  ) {
    if (provider.isLoading && reports.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (reports.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => RefreshIndicator(
          onRefresh: onRefresh,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (provider.errorMessage != null) ...[
                      Icon(
                        Icons.cloud_off_rounded,
                        size: 56,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '데이터를 불러오지 못했습니다.',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '아래로 당겨 다시 시도하거나\n설정에서 서버 상태를 확인하세요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('다시 시도'),
                        onPressed: onRefresh,
                      ),
                    ] else ...[
                      Icon(
                        Icons.inbox_rounded,
                        size: 56,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        provider.hasFilter ? '검색 결과가 없습니다.' : '신고 내역이 없습니다.',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(12, 10, 12, _selectionMode ? 100 : 20),
        itemCount: reports.length,
        itemBuilder: (context, index) => _buildReportCard(reports[index]),
      ),
    );
  }

  Widget _buildDuplicateTab(ReportProvider provider) {
    final reports = provider.filteredDuplicateReports;
    if (provider.isLoading && reports.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (reports.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => RefreshIndicator(
          onRefresh: provider.fetchDuplicateReports,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_copy, size: 56, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      '중복 신고 차량이 없습니다.',
                      style: TextStyle(color: Colors.grey, fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: provider.fetchDuplicateReports,
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(12, 10, 12, _selectionMode ? 100 : 20),
        itemCount: reports.length,
        itemBuilder: (context, index) => _buildDuplicateCard(reports[index]),
      ),
    );
  }

  Widget _buildDuplicateCard(Report report) {
    final isSelected = _selected.contains(report.reportNumber);
    final provider = context.read<ReportProvider>();
    final totalCount = report.totalCount > 0
        ? report.totalCount
        : report.validCount;
    final validCount = report.validCount;
    final excludeWithdraw = provider.excludeWithdraw;

    return ReportListCard(
      report: report,
      selectionMode: _selectionMode,
      isSelected: isSelected,
      onTap: _selectionMode
          ? () => _toggleSelect(report.reportNumber)
          : () => showReportDetailSheet(context, report),
      onLongPress: () {
        if (!_selectionMode) {
          setState(() => _selected.add(report.reportNumber));
        }
      },
      headerSuffix: totalCount > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.deepOrange.shade50,
                border: Border.all(color: Colors.deepOrange.shade200),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                excludeWithdraw && validCount != totalCount
                    ? '$validCount/$totalCount회'
                    : '$totalCount회',
                style: TextStyle(
                  color: Colors.deepOrange.shade700,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : null,
      metaItems: _buildMetaItems(report, includeLocation: true),
    );
  }

  void _showSearchPopup(BuildContext context) {
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

  Widget _buildReportCard(Report report) {
    final isSelected = _selected.contains(report.reportNumber);

    return ReportListCard(
      report: report,
      selectionMode: _selectionMode,
      isSelected: isSelected,
      onTap: _selectionMode
          ? () => _toggleSelect(report.reportNumber)
          : () => showReportDetailSheet(context, report),
      onLongPress: () {
        if (!_selectionMode) {
          setState(() => _selected.add(report.reportNumber));
        }
      },
      metaItems: _buildMetaItems(
        report,
        includeLocation: true,
        includeOccurrence: true,
      ),
    );
  }

  List<ReportCardMetaItem> _buildMetaItems(
    Report report, {
    required bool includeLocation,
    bool includeOccurrence = false,
  }) {
    return [
      ReportCardMetaItem(
        icon: Icons.calendar_today,
        text: report.date.isNotEmpty ? '신고: ${report.date}' : '',
      ),
      ReportCardMetaItem(
        icon: Icons.event_available,
        text: report.responseDate.isNotEmpty
            ? '답변: ${report.responseDate}'
            : '',
      ),
      ReportCardMetaItem(icon: Icons.business, text: report.agency),
      ReportCardMetaItem(icon: Icons.person_outline, text: report.manager),
      ReportCardMetaItem(
        icon: Icons.monetization_on_outlined,
        text: report.fineInfo,
      ),
      if (includeLocation)
        ReportCardMetaItem(
          icon: Icons.location_on_outlined,
          text: report.location,
        ),
      if (includeOccurrence)
        ReportCardMetaItem(
          icon: Icons.access_time,
          text: report.occurrenceDate.isEmpty
              ? ''
              : '발생: ${report.occurrenceDate}'
                    '${report.occurrenceTime.isNotEmpty ? ' ${report.occurrenceTime}' : ''}',
        ),
    ];
  }
}
