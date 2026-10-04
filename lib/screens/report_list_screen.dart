import '../models/app_mode.dart';
import '../widgets/local_paged_report_list.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:provider/provider.dart';
import '../providers/report_provider.dart';
import '../models/report.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import '../widgets/search_filter_sheet.dart';
import '../widgets/selection_action_bar.dart';
import '../widgets/selection_back_scope.dart';
import 'settings_screen.dart';
import '../widgets/sr_tab_bar.dart';
import '../widgets/status_badge.dart';
import '../theme/sr_colors.dart';
import '../server_palette.dart';

/// 통계·지도·상세 시트에서 조건으로 좁혀 여는 드릴다운 목록.
///
/// 앱 전체 공용 필터(`ReportProvider.filter`, 하단 신고내역 탭이 쓴다)를 바꾸지 않고
/// 이 화면만의 [filter] 로 연다. 닫아도 신고내역 탭은 그대로다(SQ-U02).
Future<void> pushReportDrillDown(
  NavigatorState navigator, {
  required ReportFilter filter,
  required String title,
  int initialTabIndex = 0,
}) => navigator.push(
  MaterialPageRoute<void>(
    builder: (_) => ReportListScreen(
      initialTabIndex: initialTabIndex,
      filter: filter,
      title: title,
    ),
  ),
);

class ReportListScreen extends StatefulWidget {
  final int initialTabIndex;

  /// null 이면 하단 탭의 신고내역: 공용 필터를 쓰고 검색 시트가 공용 필터를 바꾼다.
  /// 값이 있으면 드릴다운: 이 화면만의 조건이며 공용 필터를 건드리지 않는다.
  final ReportFilter? filter;

  /// 드릴다운 제목(예: "예시 교통 담당 기관 · 신고"). 조건을 바꾸면 기본 제목으로 돌아간다.
  final String? title;

  const ReportListScreen({
    super.key,
    this.initialTabIndex = 0,
    this.filter,
    this.title,
  });

  @override
  State<ReportListScreen> createState() => _ReportListScreenState();
}

class _ReportListScreenState extends State<ReportListScreen>
    with TickerProviderStateMixin {
  /// 화면 단위 선택은 Client 중복차량 탭(메모리 목록)에만 쓴다.
  /// 분류 탭과 Standalone 중복차량 탭은 LocalPagedReportList 가 자기 페이지 선택을 가진다.
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;
  late TabController _tabController;

  /// 드릴다운의 현재 조건. 하단 탭(widget.filter == null)에서는 쓰지 않는다.
  ReportFilter? _localFilter;

  /// 탭별 전체 건수(LocalPagedReportList 가 조회 뒤 알린다). 조건이 바뀌면 비운다.
  final Map<int, PagedReportTotal?> _totals = {};
  ReportFilter? _totalsFilter;

  static final _countFormat = NumberFormat('#,##0');

  bool get _isDrillDown => widget.filter != null;

  ReportFilter _effectiveFilter(ReportProvider provider) =>
      _localFilter ?? provider.filter;

  @override
  void initState() {
    super.initState();
    _localFilter = widget.filter;
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTabIndex < 0
          ? 0
          : widget.initialTabIndex > 3
          ? 3
          : widget.initialTabIndex,
    );
    _tabController.addListener(_handleTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<ReportProvider>();
      if (provider.appMode == AppMode.standalone) return;
      if (_tabController.index == 3 && provider.duplicateReports.isEmpty) {
        provider.fetchDuplicateReports();
      }
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    final p = context.read<ReportProvider>();
    if (_tabController.index == 3 &&
        p.appMode == AppMode.server &&
        p.duplicateReports.isEmpty) {
      p.fetchDuplicateReports();
    }
    setState(() {
      // 화면 단위 선택은 Client 중복차량 탭의 것이다. 다른 탭으로 넘어가면 푼다.
      if (_tabController.index != 3) _selected.clear();
    });
  }

  void _onTabTotal(int tab, PagedReportTotal? total) {
    if (!mounted || _totals[tab] == total) return;
    setState(() => _totals[tab] = total);
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

  /// Client 중복차량 탭이 보여 주는 목록(서버가 준 전체 목록을 그대로 그린다).
  List<Report> _clientDuplicates(ReportProvider provider) =>
      provider.appMode == AppMode.standalone
      ? const <Report>[]
      : provider.filteredDuplicateReports;

  bool _canSelectAllCurrentTab(ReportProvider provider) {
    if (_tabController.index != 3) return false;
    return _clientDuplicates(
      provider,
    ).any((report) => !_selected.contains(report.reportNumber));
  }

  void _selectAllCurrentTab() {
    final provider = context.read<ReportProvider>();
    setState(() {
      for (final r in _clientDuplicates(provider)) {
        _selected.add(r.reportNumber);
      }
    });
  }

  /// 앱바 건수 배지 문구. 확정 건수를 모르면(조회 전·오류·Client 필터 후보) null.
  String? _countBadgeText(ReportProvider provider, bool hasFilter) {
    final tab = _tabController.index;
    if (tab == 3 && provider.appMode != AppMode.standalone) {
      // Client 중복차량 탭은 필터와 무관하게 서버의 중복 목록 전체를 보인다.
      return '${_countFormat.format(provider.filteredDuplicateReports.length)}건';
    }
    final total = _totals[tab];
    if (total == null || !total.exact) return null;
    final count = _countFormat.format(total.total);
    return hasFilter ? '검색 $count건' : '$count건';
  }

  void _showSearchPopup(BuildContext context) {
    final provider = context.read<ReportProvider>();
    if (!_isDrillDown) {
      showSearchFilterSheet(context, provider: provider);
      return;
    }
    showSearchFilterSheet(
      context,
      provider: provider,
      initialFilter: _localFilter ?? const ReportFilter(),
      onApply: (filter) {
        if (!mounted) return;
        setState(() => _localFilter = filter);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final filter = _effectiveFilter(provider);
    if (filter != _totalsFilter) {
      // 조건이 바뀌면 이전 조건의 건수를 보이지 않는다(새 조회가 다시 알린다).
      _totals.clear();
      _totalsFilter = filter;
    }
    final hasFilter = !filter.isEmpty;
    final activeLabels = filter.activeLabels;
    final countText = _countBadgeText(provider, hasFilter);
    final countFiltered = countText != null && countText.startsWith('검색 ');
    final scheme = Theme.of(context).colorScheme;
    final canSelectAllCurrentTab = _canSelectAllCurrentTab(provider);
    final selectedReports = _clientDuplicates(
      provider,
    ).where((r) => _selected.contains(r.reportNumber)).toList();
    final title = _isDrillDown && _localFilter == widget.filter
        ? (widget.title ?? '신고 내역')
        : '신고 내역';

    return SelectionBackScope(
      selectionMode: _selectionMode,
      onCancel: _clearSelection,
      child: Scaffold(
        appBar: _selectionMode
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '선택 취소',
                  onPressed: _clearSelection,
                ),
                title: Text('${_selected.length}개 선택됨'),
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                foregroundColor: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer,
                actions: [
                  TextButton(
                    onPressed: canSelectAllCurrentTab
                        ? _selectAllCurrentTab
                        : null,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onPrimaryContainer,
                    ),
                    child: const Text('일괄 선택'),
                  ),
                ],
              )
            : AppBar(
                title: Text(title),
                actions: [
                  if (countText != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: countFiltered
                                ? scheme.primaryContainer
                                : scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            countText,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: countFiltered
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    icon: Badge(
                      isLabelVisible: hasFilter,
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
                bottom: SrTabBar(
                  controller: _tabController,
                  textScaler: MediaQuery.textScalerOf(context),
                  labels: const ['교통위반', '주정차', '기타위반', '중복차량'],
                ),
              ),
        body: Stack(
          children: [
            Column(
              children: [
                if (hasFilter && activeLabels.isNotEmpty)
                  Container(
                    width: double.infinity,
                    color: context.sr.brandSoft,
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
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.surface,
                                  side: BorderSide(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
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
                  ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildTab(filter, 'traffic', 0),
                      _buildTab(filter, 'parking', 1),
                      _buildTab(filter, 'other', 2),
                      _buildDuplicateTab(provider, filter),
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
      ),
    );
  }

  Widget _buildTab(ReportFilter filter, String category, int tab) {
    return LocalPagedReportList(
      key: ValueKey('page-$category'),
      category: category,
      filter: filter,
      onTotalChanged: (total) => _onTabTotal(tab, total),
    );
  }

  Widget _buildDuplicateTab(ReportProvider provider, ReportFilter filter) {
    if (provider.appMode == AppMode.standalone) {
      return LocalPagedReportList(
        scope: 'duplicates',
        filter: filter,
        onTotalChanged: (total) => _onTabTotal(3, total),
      );
    }
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
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.content_copy,
                      size: 56,
                      color: context.sr.textDisabled,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '중복 신고 차량이 없습니다.',
                      style: TextStyle(
                        color: context.sr.textSecondary,
                        fontSize: 15,
                      ),
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
          ? StatusBadge(
              label: excludeWithdraw && validCount != totalCount
                  ? '$validCount/$totalCount회'
                  : '$totalCount회',
              color: serverSupplementColor,
            )
          : null,
      metaItems: _buildMetaItems(report, includeLocation: true),
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
