import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/report.dart';
import '../models/app_mode.dart';
import '../services/rating_service.dart';
import '../providers/report_provider.dart';
import '../services/local_db_service.dart';
import 'report_detail_sheet.dart';
import 'report_list_card.dart';
import 'selection_action_bar.dart';
import 'selection_back_scope.dart';
import 'status_badge.dart';

/// Keeps one page of Report objects. The count belongs to the full SQL population.
/// An optional legacy predicate streams candidates; its label never claims that
/// the current page is a whole-population total.
class LocalPagedReportList extends StatefulWidget {
  final String category, scope;
  final String? missingAddress, metric, answerYear;
  final ReportFilter filter;
  final bool Function(Report)? predicate;
  final Future<void> Function(Report)? onRemove;
  final Widget Function(BuildContext, Report)? itemBuilder;
  const LocalPagedReportList({
    super.key,
    this.category = 'all',
    this.scope = '',
    this.missingAddress,
    this.answerYear,
    this.metric,
    this.filter = const ReportFilter(),
    this.predicate,
    this.onRemove,
    this.itemBuilder,
  });
  @override
  State<LocalPagedReportList> createState() => _LocalPagedReportListState();
}

class _LocalPagedReportListState extends State<LocalPagedReportList> {
  int _page = 0, _total = 0, _seq = 0;
  String? _datasetSettings;
  List<Report> _reports = [];
  bool _loading = true;
  String? _error;
  bool _candidateCount = false;
  final _selected = <String>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = context.watch<ReportProvider>();
    final next =
        '${p.datasetEpoch}:${p.statsRefreshNonce}:${p.excludeWithdraw}:${p.useRepresentativeRecords}';
    if (_datasetSettings != null && _datasetSettings != next) {
      _reports = [];
      _page = 0;
      _load();
    }
    _datasetSettings = next;
  }

  @override
  void didUpdateWidget(LocalPagedReportList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filter != widget.filter ||
        oldWidget.category != widget.category ||
        oldWidget.scope != widget.scope ||
        oldWidget.answerYear != widget.answerYear ||
        oldWidget.missingAddress != widget.missingAddress ||
        oldWidget.metric != widget.metric) {
      _page = 0;
      _selected.clear();
      _load();
    }
  }

  Future<void> _load() async {
    final seq = ++_seq;
    final p = context.read<ReportProvider>();
    final epoch = p.datasetEpoch;
    setState(() {
      _loading = true;
      _error = null;
      _selected.clear();
    });
    try {
      final ({List<Report> reports, int total}) result;
      if (p.appMode == AppMode.standalone) {
        result = await LocalDbService.getReportPage(
          category: widget.category,
          scope: widget.scope,
          metric: widget.metric,
          missingAddress: widget.missingAddress,
          answerYear: widget.answerYear,
          filter: widget.filter,
          page: _page,
          isCancelled: () => !mounted || seq != _seq || epoch != p.datasetEpoch,
          excludeWithdraw: p.excludeWithdraw,
          useRepresentativeRecords: p.useRepresentativeRecords,
        );
        _candidateCount = widget.predicate != null;
      } else {
        bool cancelled() => !mounted || seq != _seq || epoch != p.datasetEpoch;
        final categories = widget.category == 'all'
            ? ['traffic', 'parking', 'other']
            : [widget.category];
        var total = 0, offset = _page * 200;
        final reports = <Report>[];
        if (categories.length == 1) {
          if (!mounted || seq != _seq || epoch != p.datasetEpoch) return;
          final page = await p.readServerPage(
            categories.single,
            offset: offset,
            limit: 200,
            isCancelled: cancelled,
          );
          total = page.total;
          reports.addAll(page.reports);
        } else {
          for (final category in categories) {
            if (!mounted || seq != _seq || epoch != p.datasetEpoch) return;
            final first = await p.readServerPage(
              category,
              offset: 0,
              limit: 1,
              isCancelled: cancelled,
            );
            if (!mounted || seq != _seq || epoch != p.datasetEpoch) return;
            final size = first.total;
            total += size;
            if (offset >= size) {
              offset -= size;
              continue;
            }
            if (reports.length < 200) {
              final page = await p.readServerPage(
                category,
                offset: offset,
                limit: 200 - reports.length,
                isCancelled: cancelled,
              );
              reports.addAll(page.reports);
              offset = 0;
            }
          }
        }
        _candidateCount =
            !widget.filter.isEmpty ||
            widget.predicate != null ||
            widget.scope == 'rating';
        result = (
          reports: reports
              .where(
                (r) =>
                    p.matchesFilter(r, filter: widget.filter) &&
                    (widget.scope != 'rating' ||
                        RatingService.isListEligible(r)),
              )
              .toList(),
          total: total,
        );
      }
      if (!mounted || seq != _seq || epoch != p.datasetEpoch) return;
      setState(() {
        _reports = widget.predicate == null
            ? result.reports
            : result.reports.where(widget.predicate!).toList();
        _total = result.total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq || epoch != p.datasetEpoch) return;
      setState(() {
        _loading = false;
        _reports = [];
        _error = '$e';
      });
    }
  }

  void _toggle(Report r) => setState(() {
    _selected.contains(r.reportNumber)
        ? _selected.remove(r.reportNumber)
        : _selected.add(r.reportNumber);
  });
  @override
  Widget build(BuildContext context) => SelectionBackScope(
    selectionMode: _selected.isNotEmpty,
    onCancel: () => setState(_selected.clear),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                !_candidateCount
                    ? '전체 $_total건 · ${_page + 1} / ${((_total - 1) ~/ 200 + 1).clamp(1, 100000)} 페이지'
                    : '전체 대상 $_total건 · ${_page + 1}페이지에서 조건에 맞는 ${_reports.length}건',
              ),
              IconButton(
                tooltip: '이전 페이지',
                onPressed: _loading || _page == 0
                    ? null
                    : () {
                        _page--;
                        _load();
                      },
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: '다음 페이지',
                onPressed: _loading || (_page + 1) * 200 >= _total
                    ? null
                    : () {
                        _page++;
                        _load();
                      },
                icon: const Icon(Icons.chevron_right),
              ),
              if (_selected.isNotEmpty)
                TextButton(
                  onPressed: () => setState(
                    () => _selected.addAll(_reports.map((r) => r.reportNumber)),
                  ),
                  child: const Text('현재 페이지 일괄 선택'),
                ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              itemCount: _reports.isEmpty ? 1 : _reports.length,
              itemBuilder: (context, index) {
                if (_reports.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error ?? (_loading ? '불러오는 중…' : '해당하는 신고가 없습니다.'),
                    ),
                  );
                }
                final r = _reports[index];
                if (widget.itemBuilder != null) {
                  return widget.itemBuilder!(context, r);
                }
                return ReportListCard(
                  report: r,
                  selectionMode: _selected.isNotEmpty,
                  isSelected: _selected.contains(r.reportNumber),
                  onTap: () => _selected.isNotEmpty
                      ? _toggle(r)
                      : showReportDetailSheet(context, r),
                  onLongPress: () => _toggle(r),
                  headerSuffix: widget.onRemove != null
                      ? IconButton(
                          tooltip: '감시 목록에서 제거',
                          icon: const Icon(Icons.bookmark_remove_outlined),
                          onPressed: () async {
                            await widget.onRemove!(r);
                            if (mounted) _load();
                          },
                        )
                      : r.totalCount > 0
                      ? StatusBadge(
                          label: '${r.validCount}/${r.totalCount}회',
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  metaItems: [
                    ReportCardMetaItem(
                      icon: Icons.calendar_today,
                      text: r.date,
                    ),
                    ReportCardMetaItem(icon: Icons.business, text: r.agency),
                    ReportCardMetaItem(
                      icon: Icons.person_outline,
                      text: r.manager,
                    ),
                    ReportCardMetaItem(
                      icon: Icons.location_on_outlined,
                      text: r.location,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        if (_selected.isNotEmpty)
          SelectionActionBar(
            selectedReports: _reports
                .where((r) => _selected.contains(r.reportNumber))
                .toList(),
            onCancel: () => setState(_selected.clear),
            onActionDone: () {
              setState(_selected.clear);
              _load();
            },
          ),
      ],
    ),
  );
}
