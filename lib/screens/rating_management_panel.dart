import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/report.dart';
import '../providers/report_provider.dart';
import '../theme/app_theme.dart';
import '../theme/sr_colors.dart';
import '../theme/sr_colors.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import '../widgets/search_filter_sheet.dart';
import '../widgets/selection_action_bar.dart';

class RatingManagementPanel extends StatefulWidget {
  const RatingManagementPanel({super.key});

  @override
  State<RatingManagementPanel> createState() => _RatingManagementPanelState();
}

class _RatingManagementPanelState extends State<RatingManagementPanel> {
  final Set<String> _selected = <String>{};

  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ReportProvider>().ensureCategoryReportsLoaded();
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

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  void _selectAllCurrentList(List<Report> reports) {
    setState(() {
      for (final report in reports) {
        _selected.add(report.reportNumber);
      }
    });
  }

  Future<void> _refreshReports() {
    return context.read<ReportProvider>().ensureCategoryReportsLoaded(
      forceRefresh: true,
    );
  }

  void _showSearchPopup(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SearchFilterSheet(
        provider: context.read<ReportProvider>(),
        ratingManagementMode: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final effectiveFilter = provider.filter.withoutRatingStateFilters();
    final reports = provider.filteredRatingEligibleReports;
    final activeLabels = effectiveFilter.activeLabels;
    final hasApplicableFilter = !effectiveFilter.isEmpty;
    final canSelectAllReports = reports.any(
      (report) => !_selected.contains(report.reportNumber),
    );
    final selectedReports = provider.ratingEligibleReports
        .where((report) => _selected.contains(report.reportNumber))
        .toList(growable: false);
    final eligibleNumbers = provider.ratingEligibleReports
        .map((report) => report.reportNumber)
        .toSet();
    final staleSelections = _selected.where(
      (reportNumber) => !eligibleNumbers.contains(reportNumber),
    );
    if (staleSelections.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final currentEligibleNumbers = context
            .read<ReportProvider>()
            .ratingEligibleReports
            .map((report) => report.reportNumber)
            .toSet();
        setState(() {
          _selected.removeWhere(
            (reportNumber) => !currentEligibleNumbers.contains(reportNumber),
          );
        });
      });
    }

    final theme = Theme.of(context);
    final primaryTone = StatusTone.of(
      theme.colorScheme.primary,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );

    return Stack(
      children: [
        Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(bottom: BorderSide(color: context.sr.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '별점 가능 신고',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              hasApplicableFilter
                                  ? '검색 ${reports.length}건'
                                  : '${reports.length}건',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: hasApplicableFilter
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '참여 가능 상태의 신고건만 표시됩니다.',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_selectionMode)
                        TextButton(
                          onPressed: canSelectAllReports
                              ? () => _selectAllCurrentList(reports)
                              : null,
                          child: const Text('일괄 선택'),
                        ),
                      IconButton(
                        icon: Badge(
                          isLabelVisible: hasApplicableFilter,
                          child: const Icon(Icons.filter_list),
                        ),
                        tooltip: '검색/필터',
                        onPressed: () => _showSearchPopup(context),
                      ),
                    ],
                  ),
                  if (_selectionMode) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          '${selectedReports.length}건 선택됨',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _clearSelection,
                          child: const Text('선택 해제'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (hasApplicableFilter && activeLabels.isNotEmpty)
              Container(
                width: double.infinity,
                color: primaryTone.background,
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
                                style: TextStyle(
                                  fontSize: 11,
                                  color: primaryTone.foreground,
                                ),
                              ),
                              backgroundColor: theme.colorScheme.surface,
                              side: BorderSide(color: primaryTone.border),
                              padding: EdgeInsets.zero,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ),
            Expanded(child: _buildBody(provider, reports)),
          ],
        ),
        if (_selectionMode)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SelectionActionBar(
              selectedReports: selectedReports,
              onCancel: _clearSelection,
              onActionDone: _clearSelection,
            ),
          ),
      ],
    );
  }

  Widget _buildBody(ReportProvider provider, List<Report> reports) {
    final theme = Theme.of(context);
    final hasApplicableFilter = !provider.filter
        .withoutRatingStateFilters()
        .isEmpty;
    if (provider.isLoading && reports.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (reports.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => RefreshIndicator(
          onRefresh: _refreshReports,
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
                        color: context.sr.textDisabled,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '데이터를 불러오지 못했습니다.',
                        style: TextStyle(
                          color: context.sr.textSecondary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '아래로 당겨 다시 시도하거나\n서버/동기화 상태를 확인하세요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.sr.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('다시 시도'),
                        onPressed: _refreshReports,
                      ),
                    ] else ...[
                      Icon(
                        Icons.star_outline_rounded,
                        size: 56,
                        color: context.sr.textDisabled,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        hasApplicableFilter
                            ? '검색 결과가 없습니다.'
                            : '별점 가능한 신고가 없습니다.',
                        style: TextStyle(
                          color: context.sr.textSecondary,
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
      onRefresh: _refreshReports,
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(12, 10, 12, _selectionMode ? 100 : 20),
        itemCount: reports.length,
        itemBuilder: (context, index) => _buildReportCard(reports[index]),
      ),
    );
  }

  Widget _buildReportCard(Report report) {
    final provider = context.read<ReportProvider>();
    final isSelected = _selected.contains(report.reportNumber);
    final category = provider.findCategory(report) ?? report.category.trim();

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
      headerSuffix: _buildCategoryChip(context, category),
      metaItems: [
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
        ReportCardMetaItem(
          icon: Icons.star_outline_rounded,
          text: report.pollStatus,
        ),
        ReportCardMetaItem(icon: Icons.business, text: report.agency),
        ReportCardMetaItem(icon: Icons.person_outline, text: report.manager),
        ReportCardMetaItem(
          icon: Icons.monetization_on_outlined,
          text: report.fineInfo,
        ),
        ReportCardMetaItem(
          icon: Icons.location_on_outlined,
          text: report.location,
        ),
      ],
    );
  }

  Widget? _buildCategoryChip(BuildContext context, String category) {
    final label = switch (category) {
      'traffic' => '교통',
      'parking' => '주정차',
      'other' => '기타',
      _ => '',
    };
    if (label.isEmpty) return null;

    final baseColor = switch (category) {
      'traffic' => Colors.blue,
      'parking' => Colors.teal,
      'other' => Colors.deepPurple,
      _ => Colors.grey,
    };

    final theme = Theme.of(context);
    final tone = StatusTone.of(
      baseColor,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: tone.background,
        border: Border.all(color: tone.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: tone.foreground,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
