import '../models/app_mode.dart';
import '../widgets/local_paged_report_list.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/report.dart';
import '../providers/report_provider.dart';
import '../theme/sr_colors.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import '../widgets/search_filter_sheet.dart';
import '../widgets/selection_action_bar.dart';
import '../widgets/selection_back_scope.dart';
import '../widgets/sr_app_bar_actions.dart';
import '../widgets/sr_empty_state.dart';
import '../theme/sr_tokens.dart';

/// 별점 탭의 상세 검색(별점 상태 조건은 빼고 연다). 신고관리 앱바의 검색/필터 아이콘이 부른다(SQ-U16).
void openRatingFilterSheet(BuildContext context) {
  showSearchFilterSheet(
    context,
    provider: context.read<ReportProvider>(),
    ratingManagementMode: true,
  );
}

/// 별점 탭 조건 칩 줄. 별점 상태 조건은 이 탭에 적용되지 않으므로 보이지 않는다.
class _RatingFilterChips extends StatelessWidget {
  const _RatingFilterChips({required this.filter});

  final ReportFilter filter;

  @override
  Widget build(BuildContext context) => ActiveFilterChipBar(
    conditions: filter.withoutRatingStateFilters().activeConditions,
    onRemove: (field) {
      final provider = context.read<ReportProvider>();
      provider.setFilter(provider.filter.without(field));
    },
    // 상세 검색 시트의 "전체 초기화"와 같다.
    onClear: () => context.read<ReportProvider>().clearFilter(),
  );
}

class RatingManagementPanel extends StatefulWidget {
  const RatingManagementPanel({super.key});

  @override
  State<RatingManagementPanel> createState() => _RatingManagementPanelState();
}

class _RatingManagementPanelState extends State<RatingManagementPanel> {
  final Set<String> _selected = <String>{};

  bool get _selectionMode => _selected.isNotEmpty;

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

  @override
  Widget build(BuildContext context) {
    // 두 모드 모두 페이지 목록(LocalPagedReportList)을 쓴다. 조건·모드만 구독한다(SQ-P07).
    context.select<ReportProvider, Object>((p) => (p.filter, p.appMode));
    final provider = context.read<ReportProvider>();
    final effectiveFilter = provider.filter.withoutRatingStateFilters();
    if (provider.appMode == AppMode.standalone ||
        provider.appMode == AppMode.server) {
      return Column(
        children: [
          _RatingFilterChips(filter: provider.filter),
          Expanded(
            child: LocalPagedReportList(
              scope: 'rating',
              filter: effectiveFilter,
            ),
          ),
        ],
      );
    }
    final reports = provider.filteredRatingEligibleReports;
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

    return SelectionBackScope(
      selectionMode: _selectionMode,
      onCancel: _clearSelection,
      child: Stack(
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
              _RatingFilterChips(filter: provider.filter),
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
      ),
    );
  }

  Widget _buildBody(ReportProvider provider, List<Report> reports) {
    final hasApplicableFilter = !provider.filter
        .withoutRatingStateFilters()
        .isEmpty;
    if (provider.isLoading && reports.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (reports.isEmpty) {
      // 공용 빈/오류 상태(SQ-U21).
      return RefreshIndicator(
        onRefresh: _refreshReports,
        child: provider.errorMessage != null
            ? SrEmptyState.error(
                message: '아래로 당겨 다시 시도하거나\n서버/동기화 상태를 확인하세요.',
                onRetry: _refreshReports,
              )
            : SrEmptyState(
                icon: Icons.star_outline_rounded,
                title: hasApplicableFilter
                    ? '검색 결과가 없습니다.'
                    : '별점 가능한 신고가 없습니다.',
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

    // 분류색은 통계 화면과 같은 토큰(교통 파랑 / 주정차 주황 / 기타 초록, SQ-U23).
    final tone = context.toneOf(context.sr.category(category));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: tone.background,
        border: Border.all(color: tone.border),
        borderRadius: BorderRadius.circular(SrRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: tone.foreground,
          fontSize: SrFontSize.caption,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
