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
import 'sr_empty_state.dart';
import 'sr_page_padding.dart';
import 'status_badge.dart';
import '../utils/format.dart';

/// 페이지 목록이 받은 전체 모집단 건수. [exact] 가 false 면 Client 의 필터처럼
/// 현재 페이지 안에서만 걸러, 조건에 맞는 전체 건수를 알 수 없다는 뜻이다.
typedef PagedReportTotal = ({int total, bool exact});

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

  /// 조회가 끝날 때마다 전체 건수를 알린다(오류면 null). 앱바 건수 배지가 쓴다(SQ-U01).
  final ValueChanged<PagedReportTotal?>? onTotalChanged;
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
    this.onTotalChanged,
  });
  @override
  State<LocalPagedReportList> createState() => _LocalPagedReportListState();
}

class _LocalPagedReportListState extends State<LocalPagedReportList> {
  int _page = 0, _total = 0, _seq = 0;
  String? _datasetSettings;

  /// 숨은 탭(TickerMode 꺼짐)에서 자료가 바뀌면 표시만 해 두고, 다시 보일 때 한 번 읽는다(SQ-P02).
  bool _stale = false;
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

  /// build 에서 부른다(context.select 는 build 안에서만 쓸 수 있다).
  /// 이 목록이 쓰는 값만 구독한다(SQ-P07). 자료 변경은 dataRevision 으로만 본다 — 통계 탭 진입 신호는 보지 않는다(SQ-P02).
  /// 숨은 탭이면 표시만 해 두고, 다시 보일 때(TickerMode 켜짐) 한 번 읽는다.
  void _watchDataset(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled;
    final next = context.select<ReportProvider, String>(
      (p) =>
          '${p.datasetEpoch}:${p.dataRevision}:${p.excludeWithdraw}:${p.useRepresentativeRecords}',
    );
    if (_datasetSettings != null && _datasetSettings != next) {
      _seq++; // 이전 자료의 늦은 응답을 버린다.
      _reports = [];
      _page = 0;
      _stale = true;
    }
    _datasetSettings = next;
    if (_stale && visible) {
      _stale = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
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
          // 카드·선택 동작이 쓰는 열만 읽는다. 상세 시트는 열 때 한 건을 다시 읽는다(SQ-P06).
          compact: true,
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
      widget.onTotalChanged?.call((total: _total, exact: !_candidateCount));
    } catch (e) {
      if (!mounted || seq != _seq || epoch != p.datasetEpoch) return;
      setState(() {
        _loading = false;
        _reports = [];
        _error = '$e';
      });
      widget.onTotalChanged?.call(null);
    }
  }

  /// 빈 목록과 조회 오류를 구분한다. 오류는 오류 톤 + "다시 시도"(SQ-U21).
  Widget _buildEmptyOrError() {
    final error = _error;
    if (error != null) {
      return SrEmptyState.error(
        title: '목록을 불러오지 못했습니다',
        message: '아래로 당기거나 다시 시도를 누르세요.',
        detail: error,
        onRetry: _load,
      );
    }
    final filtered = !widget.filter.isEmpty || widget.predicate != null;
    return SrEmptyState(
      icon: filtered ? Icons.search_off_rounded : Icons.inbox_outlined,
      title: filtered ? '조건에 맞는 신고가 없습니다' : '해당하는 신고가 없습니다',
      message: filtered ? '검색 조건을 바꾸거나 초기화해 보세요.' : null,
    );
  }

  void _toggle(Report r) => setState(() {
    _selected.contains(r.reportNumber)
        ? _selected.remove(r.reportNumber)
        : _selected.add(r.reportNumber);
  });
  @override
  Widget build(BuildContext context) {
    _watchDataset(context);
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) => SelectionBackScope(
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
                    ? '전체 ${formatCount(_total)} · ${_page + 1} / ${((_total - 1) ~/ 200 + 1).clamp(1, 100000)} 페이지'
                    : '전체 대상 ${formatCount(_total)} · ${_page + 1}페이지에서 조건에 맞는 ${formatCount(_reports.length)}',
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
            child: !_loading && _reports.isEmpty
                ? _buildEmptyOrError()
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: srPagePadding(context, const EdgeInsets.all(12)),
                    itemCount: _reports.isEmpty ? 1 : _reports.length,
                    itemBuilder: (context, index) {
                      if (_reports.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('불러오는 중…'),
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
                                icon: const Icon(
                                  Icons.bookmark_remove_outlined,
                                ),
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
                          ReportCardMetaItem(
                            icon: Icons.business,
                            text: r.agency,
                          ),
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
