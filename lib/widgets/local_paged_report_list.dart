import '../models/report_sort.dart';
import '../services/report_sort_store.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/report.dart';
import '../models/app_mode.dart';
import '../services/rating_service.dart';
import '../services/client_report_scan.dart';
import '../services/performance_trace.dart';
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

/// 페이지 목록이 받은 전체 모집단 건수. [exact] 가 false 면 로컬 legacy predicate로
/// 현재 페이지를 추가 필터링해 조건에 맞는 전체 건수를 알 수 없다는 뜻이다.
typedef PagedReportTotal = ({int total, bool exact});

/// Keeps at most three pages, including a prefetched next page. Duplicate pages
/// contain whole vehicle groups (20 per page), so a large group is never split.
/// An optional legacy predicate streams candidates; its label never claims that
/// the current page is a whole-population total.
class LocalPagedReportList extends StatefulWidget {
  final String category, scope;
  final String? missingAddress, metric, answerYear;
  final ReportFilter filter;
  final ReportSort sort;
  final bool groupPage;
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
    this.sort = ReportSort.defaults,
    this.groupPage = false,
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
  final _scrollController = ScrollController();
  int get _pageSize => widget.groupPage ? 20 : 200;
  ClientSortedReports? _clientSnapshot;
  Future<ClientSortedReports>? _buildingSnapshot;
  @override
  void dispose() {
    _generation++;
    _scrollController.dispose();
    final snapshot = _clientSnapshot;
    if (snapshot != null) unawaited(snapshot.close());
    super.dispose();
  }

  String? _datasetSettings;

  /// 숨은 탭(TickerMode 꺼짐)에서 자료가 바뀌면 표시만 해 두고, 다시 보일 때 한 번 읽는다(SQ-P02).
  /// 필터 변경으로 숨은 동안 미룬 전체 스캔도 같은 표시로 둔다(2026-10-17 명세 5절).
  bool _stale = false;

  /// 보이지 않는 동안 바뀐 검색 조건으로 미룬 다시 읽기. 보일 때 한 번 실행한다.
  bool _pendingFilter = false;
  List<Report> _reports = [];
  bool _loading = true;
  String? _error;
  bool _candidateCount = false;
  final _selected = <String>{};
  int _generation = 0;
  // Per visible list: current/previous/next. Normal pages hold at most 600 reports;
  // duplicate pages retain complete groups.
  final _pages = <int, ReportPage>{};
  final _pending = <int, Future<ReportPage>>{};

  void _invalidate({bool preserveSnapshot = false}) {
    if (!preserveSnapshot) {
      final snapshot = _clientSnapshot;
      _clientSnapshot = null;
      if (snapshot != null) unawaited(snapshot.close());
    }
    _buildingSnapshot = null;
    _generation++;
    _pages.clear();
    _pending.clear();
  }

  void _remember(int page, ReportPage result) {
    _pages.remove(page);
    _pages[page] = result;
    while (_pages.length > 3) {
      _pages.remove(_pages.keys.first);
    }
  }

  Future<void> _refresh() async {
    _invalidate();
    await _load();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// build 에서 부른다(context.select 는 build 안에서만 쓸 수 있다).
  /// 이 목록이 쓰는 값만 구독한다(SQ-P07). 자료 변경은 dataRevision 으로만 본다 — 통계 탭 진입 신호는 보지 않는다(SQ-P02).
  /// 숨은 탭이면 표시만 해 두고, 다시 보일 때(TickerMode 켜짐) 한 번 읽는다.
  /// 미룬 필터 스캔(_pendingFilter)도 여기서 보일 때 한 번 실행한다(2026-10-17 명세 5절).
  void _watchDataset(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled;
    final next = context.select<ReportProvider, String>(
      (p) =>
          '${p.datasetEpoch}:${p.dataRevision}:${p.excludeWithdraw}:${p.useRepresentativeRecords}',
    );
    if (_datasetSettings != null && _datasetSettings != next) {
      _invalidate();
      _seq++; // 이전 자료의 늦은 응답을 버린다.
      _reports = [];
      _page = 0;
      _stale = true;
      if (!visible && _loading) {
        // 숨은 동안 스캔 중이던 표시는 끈다. 버려진 스캔이 _loading 을 남기지 않게 하고,
        // 보일 때 새로 읽는다(2026-10-17 명세 5절).
        _loading = false;
      }
    }
    _datasetSettings = next;
    if ((_stale || _pendingFilter) && visible) {
      _stale = false;
      _pendingFilter = false;
      _invalidate();
      _page = 0;
      _selected.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  @override
  void didUpdateWidget(LocalPagedReportList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sort != widget.sort ||
        oldWidget.groupPage != widget.groupPage ||
        oldWidget.filter != widget.filter ||
        oldWidget.category != widget.category ||
        oldWidget.scope != widget.scope ||
        oldWidget.answerYear != widget.answerYear ||
        oldWidget.missingAddress != widget.missingAddress ||
        oldWidget.metric != widget.metric ||
        oldWidget.predicate != widget.predicate) {
      _invalidate(
        preserveSnapshot:
            oldWidget.filter == widget.filter &&
            oldWidget.category == widget.category &&
            oldWidget.scope == widget.scope &&
            oldWidget.predicate == widget.predicate &&
            oldWidget.metric == widget.metric &&
            oldWidget.answerYear == widget.answerYear,
      );
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      _page = 0;
      _selected.clear();
      final visible = TickerMode.valuesOf(context).enabled;
      if (!visible) {
        // 보이지 않는 동안은 전체 스캔을 시작하지 않고 미룬다. 보일 때 _watchDataset 이 한 번 실행한다.
        _pendingFilter = true;
        if (_loading) {
          setState(() => _loading = false);
        }
        return;
      }
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
      final result = _pages[_page] ?? await _readPage(_page);
      _candidateCount =
          p.appMode == AppMode.standalone && widget.predicate != null;
      if (!mounted || seq != _seq) return;
      if (epoch != p.datasetEpoch) {
        // 스캔 중 자료 세대가 바뀌어 결과를 버릴 때도 표시는 정상으로 돌린다.
        // 새 읽기가 이미 시작됐으면(seq 가 다르면 위에서 반환) 그 읽기가 표시를 맡는다.
        setState(() => _loading = false);
        _stale = true;
        return;
      }
      setState(() {
        _reports = widget.predicate == null || p.appMode == AppMode.server
            ? result.reports
            : result.reports.where(widget.predicate!).toList();
        _total = result.total;
        _loading = false;
      });
      widget.onTotalChanged?.call((total: _total, exact: !_candidateCount));
      if ((_page + 1) * _pageSize < _total) {
        // A speculative failure must not hide the current page; navigation retries.
        unawaited(
          _readPage(_page + 1).then<void>((_) {}, onError: (Object _) {}),
        );
      }
    } catch (e) {
      if (!mounted || seq != _seq) return;
      if (epoch != p.datasetEpoch) {
        // 버려진 스캔의 오류 표시는 남기지 않고 로딩만 푼다. 보일 때 다시 읽는다.
        if (_loading) {
          setState(() => _loading = false);
        }
        _stale = true;
        return;
      }
      setState(() {
        _loading = false;
        _reports = [];
        _error = '$e';
      });
      widget.onTotalChanged?.call(null);
    }
  }

  Future<ReportPage> _readPage(int page) {
    final cached = _pages[page];
    if (cached != null) return Future.value(cached);
    return _pending[page] ??= _readPageOwned(page);
  }

  Future<ReportPage> _readPageOwned(int page) async {
    final p = context.read<ReportProvider>();
    final generation = _generation,
        epoch = p.datasetEpoch,
        revision = p.dataRevision;
    final query = widget;
    bool cancelled() =>
        !mounted ||
        generation != _generation ||
        epoch != p.datasetEpoch ||
        revision != p.dataRevision;
    try {
      final ReportPage result;
      if (p.appMode == AppMode.standalone) {
        result = await LocalDbService.getReportPage(
          compact: true,
          sort: query.sort,
          groupPage: query.groupPage,
          pageSize: _pageSize,
          category: query.category,
          scope: query.scope,
          metric: query.metric,
          missingAddress: query.missingAddress,
          answerYear: query.answerYear,
          filter: query.filter,
          page: page,
          isCancelled: cancelled,
          excludeWithdraw: p.excludeWithdraw,
          useRepresentativeRecords: p.useRepresentativeRecords,
        );
      } else if (query.sort != ReportSort.defaults) {
        final snapshot =
            _clientSnapshot ??
            await (_buildingSnapshot ??= ClientSortedReports.build(
              read: p.readServerPage,
              categories: query.category == 'all'
                  ? const ['traffic', 'parking', 'safety', 'living', 'other']
                  : [query.category],
              matches: (r) =>
                  p.matchesFilter(r, filter: query.filter) &&
                  (query.predicate?.call(r) ?? true),
              isCancelled: cancelled,
            ));
        if (cancelled()) {
          if (!identical(snapshot, _clientSnapshot)) await snapshot.close();
          throw const QueryCancelled();
        }
        _clientSnapshot = snapshot;
        result = await snapshot.page(query.sort, page);
      } else if (query.category != 'all' &&
          query.filter.isEmpty &&
          query.predicate == null &&
          query.scope.isEmpty) {
        result = await p.readServerPage(
          query.category,
          offset: page * 200,
          limit: 200,
          isCancelled: cancelled,
        );
      } else if (query.predicate == null &&
          query.scope.isEmpty &&
          query.metric == null &&
          query.answerYear == null &&
          query.missingAddress == null &&
          await p.supportsServerSearch(isCancelled: cancelled)) {
        result = await p.readServerSearchPage(
          query.category,
          offset: page * 200,
          limit: 200,
          filter: query.filter,
          isCancelled: cancelled,
        );
      } else {
        // Arbitrary Dart predicates (FilteredListScreen dashboard drilldowns)
        // and rating scope retain the exact, cancellable legacy scan.
        final window = await scanClientReports(
          read: p.readServerPage,
          // 2026-10-11 5분류('기타'→안전신고·생활불편·기타). Client 서버가 아직 구버전이면
          // readServerPage 가 던지는 오류를 이 위젯 _error 로만 보인다(앱 전체는 깨지지 않는다).
          categories: query.category == 'all'
              ? const ['traffic', 'parking', 'safety', 'living', 'other']
              : [query.category],
          matches: (r) =>
              p.matchesFilter(r, filter: query.filter) &&
              (query.scope != 'rating' || RatingService.isListEligible(r)) &&
              (query.predicate?.call(r) ?? true),
          isCancelled: cancelled,
          offset: page * 200,
        );
        if (cancelled()) throw const QueryCancelled();
        if (window.reports.length > 200) {
          _remember(page + 1, (
            reports: window.reports.skip(200).toList(),
            total: window.total,
          ));
        }
        result = (
          reports: window.reports.take(200).toList(),
          total: window.total,
        );
      }
      if (cancelled()) throw const QueryCancelled();
      _remember(page, result);
      return result;
    } finally {
      if (generation == _generation) _pending.remove(page);
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
        onRetry: _refresh,
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
                    ? '${widget.groupPage ? '전체 $_total개 차량 묶음' : '전체 ${formatCount(_total)}'} · ${_page + 1} / ${((_total - 1) ~/ _pageSize + 1).clamp(1, 100000)} 페이지'
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
                onPressed: _loading || (_page + 1) * _pageSize >= _total
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
            onRefresh: _refresh,
            child: !_loading && _reports.isEmpty
                ? _buildEmptyOrError()
                : ListView.builder(
                    controller: _scrollController,
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
                                  if (mounted) _refresh();
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
                          // 다른 목록 카드와 같이 과태료(금액 미확인이면 추정 보조 표기) — redroid 실기기 확인 2026-10-12
                          ReportCardMetaItem.fine(r),
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
              _refresh();
            },
          ),
      ],
    ),
  );
}
