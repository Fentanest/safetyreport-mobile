import '../services/performance_trace.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/agency_stats.dart';
import '../models/app_mode.dart';
import '../models/stats_overview.dart';
import '../providers/report_provider.dart';
import '../server_palette.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import 'report_map_screen.dart';
import 'report_list_screen.dart';
import 'settings_screen.dart';
import 'sunwi_screen.dart';
import '../theme/sr_colors.dart';
import '../widgets/stats_overview_section.dart';
import '../widgets/stats_fine_breakdown.dart';

/// 통계 화면(2026-09-28 개편).
/// 위에서부터: 공통 조건(연도·분류·법규) → 요약(2열 카드·월별 처리 추이·펼치는 차트, 접기 가능)
/// → 신고 지도 열기 → 상세 통계(여섯 보기·검색·정렬·기관/담당자 카드) → 전국 안전신고 현황.
/// 여섯 보기는 상세 영역의 집계 단위·기관 범위만 바꾼다(요약 수치는 그대로).
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

enum _SortKey { total, fines, confirmedFine, avgDays, rating, name }

class _StatisticsScreenState extends State<StatisticsScreen> {
  AgencyStats? _stats;
  bool _loading = true;
  String? _error;

  /// 요약 카드 + 월별 추이. 기관표와 독립적으로 불러와서 실패해도 표는 그대로 보인다.
  StatsOverview? _overview;
  String? _overviewNotice;
  bool _overviewLoading = false;

  String _year = 'all'; // 'all' | '2026' | '2025' | ...
  String _cat = 'traffic'; // traffic | parking | other
  String _type =
      'agency'; // agency | person | police-agency | police-person | other-agency | other-person
  String? _law; // null = 전체, '__없음__' = 법규 없음, 그 외 = 특정 법규

  bool _summaryExpanded = true;
  bool _chartsExpanded = false;
  String _search = '';
  _SortKey _sort = _SortKey.total;
  final _searchController = TextEditingController();
  final _detailKey = GlobalKey();

  /// 조건을 빠르게 바꿀 때 늦게 온 이전 응답이 최신 화면을 덮지 않게 요청 번호를 비교한다.
  int _loadSeq = 0;
  int _lastRefreshNonce = 0;
  bool? _wasActive;
  String? _datasetScope;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _loadSeq++;
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    final p = context.watch<ReportProvider>();
    final scope =
        '${p.datasetEpoch}:${p.excludeWithdraw}:${p.useRepresentativeRecords}';
    var reload = _wasActive == false && active && _loading;
    if (_datasetScope != null && _datasetScope != scope) {
      reload = true;
      _stats = null;
      _overview = null;
      _loading = true;
    }
    _datasetScope = scope;
    _wasActive = active;
    final nonce = p.statsRefreshNonce;
    if (nonce != _lastRefreshNonce) {
      _lastRefreshNonce = nonce;
      reload = reload || nonce != 0;
    }
    if (reload) {
      _loadSeq++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
      // 새 조건의 요약이 오기 전까지 이전 조건의 요약 수치를 보이지 않는다(불러오는 중 안내).
      _overview = null;
      _overviewNotice = null;
    });
    final p = context.read<ReportProvider>();
    final epoch = p.datasetEpoch;
    final year = _year == 'all' ? null : _year;
    final law = _law;
    try {
      AgencyStats stats;
      StatsOverview? localOverview;
      if (p.appMode == AppMode.standalone) {
        final raw = await LocalDbService.computeStatsBundle(
          isCancelled: () =>
              !mounted ||
              seq != _loadSeq ||
              epoch != p.datasetEpoch ||
              !TickerMode.valuesOf(context).enabled,
          year: year,
          law: law,
          excludeWithdraw: p.excludeWithdraw,
          useRepresentativeRecords: p.useRepresentativeRecords,
        );
        stats = AgencyStats.fromJson(raw['stats']);
        localOverview = StatsOverview.fromJson(raw['overview']);
      } else {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        stats = await api.getStats(year: year, law: law);
      }
      if (!mounted || seq != _loadSeq || epoch != p.datasetEpoch) return;
      setState(() {
        _stats = stats;
        if (localOverview != null) _overview = localOverview;
        _loading = false;
      });
    } on QueryCancelled {
      return;
    } catch (e) {
      if (!mounted || seq != _loadSeq || epoch != p.datasetEpoch) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      return;
    }
    if (p.appMode == AppMode.server) {
      await _loadOverview(p, year, law, seq, epoch);
    }
  }

  Future<void> _loadOverview(
    ReportProvider p,
    String? year,
    String? law,
    int seq,
    int epoch,
  ) async {
    if (mounted) setState(() => _overviewLoading = true);
    StatsOverview? overview;
    String? notice;
    try {
      if (p.appMode == AppMode.standalone) {
        // sqflite 단일 연결: 기관표 집계가 끝난 뒤 순차 실행한다.
        overview = StatsOverview.fromJson(
          await LocalDbService.computeStatsOverview(
            year: year,
            law: law,
            excludeWithdraw: p.excludeWithdraw,
            useRepresentativeRecords: p.useRepresentativeRecords,
          ),
        );
      } else {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        overview = await api.getStatsOverview(year: year, law: law);
      }
    } on ApiFeatureUnavailableException catch (e) {
      notice = e.message;
    } catch (e) {
      notice = '요약을 불러오지 못했습니다: $e';
    }
    if (!mounted || seq != _loadSeq || epoch != p.datasetEpoch) return;
    setState(() {
      _overview = overview;
      _overviewNotice = notice;
      _overviewLoading = false;
    });
  }

  void _retryOverview() {
    final p = context.read<ReportProvider>();
    _loadOverview(
      p,
      _year == 'all' ? null : _year,
      _law,
      _loadSeq,
      p.datasetEpoch,
    );
  }

  static const _catLabels = {
    'traffic': '교통위반',
    'parking': '주정차위반',
    'other': '기타위반',
  };

  static const _typeLabels = {
    'agency': '기관별',
    'person': '담당자별',
    'police-agency': '경찰 기관',
    'police-person': '경찰 담당자',
    'other-agency': '비경찰 기관',
    'other-person': '비경찰 담당자',
  };

  CategoryStats get _currentCat {
    if (_stats == null) {
      return const CategoryStats(
        byAgency: [],
        byPerson: [],
        policeByAgency: [],
        policeByPerson: [],
        otherByAgency: [],
        otherByPerson: [],
      );
    }
    return _cat == 'traffic'
        ? _stats!.traffic
        : _cat == 'parking'
        ? _stats!.parking
        : _stats!.other;
  }

  List<AgencyStatRow> get _typeRows {
    final group = _currentCat;
    return switch (_type) {
      'agency' => group.byAgency,
      'person' => group.byPerson,
      'police-agency' => group.policeByAgency,
      'police-person' => group.policeByPerson,
      'other-agency' => group.otherByAgency,
      'other-person' => group.otherByPerson,
      _ => group.byAgency,
    };
  }

  List<AgencyStatRow>? _viewSource;
  Object? _viewKey;
  List<AgencyStatRow> _viewRows = const [];

  /// 검색(기관명·담당자명)과 정렬을 적용한 전체 목록. 미리보기로 자르지 않는다.
  List<AgencyStatRow> get _visibleRows {
    final q = _search.trim().toLowerCase();
    final source = _typeRows;
    final key = (_type, _cat, q, _sort);
    if (identical(source, _viewSource) && key == _viewKey) return _viewRows;
    final timer = Stopwatch()..start();
    final rows = source
        .where(
          (r) =>
              q.isEmpty ||
              r.agency.toLowerCase().contains(q) ||
              (_showPerson && r.person.toLowerCase().contains(q)),
        )
        .toList();
    int nullsLast<T extends Comparable<T>>(T? a, T? b, {bool desc = true}) {
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return desc ? b.compareTo(a) : a.compareTo(b);
    }

    int byName(AgencyStatRow a, AgencyStatRow b) {
      final c = a.agency.compareTo(b.agency);
      return c != 0 ? c : a.person.compareTo(b.person);
    }

    rows.sort((a, b) {
      final c = switch (_sort) {
        _SortKey.total => b.total.compareTo(a.total),
        _SortKey.fines => b.fines.compareTo(a.fines),
        _SortKey.confirmedFine => b.totalFineAmount.compareTo(
          a.totalFineAmount,
        ),
        _SortKey.avgDays => nullsLast<num>(
          a.avgResponseDays,
          b.avgResponseDays,
          desc: false,
        ),
        _SortKey.rating => nullsLast<num>(a.avgRating, b.avgRating),
        _SortKey.name => 0,
      };
      return c != 0 ? c : byName(a, b);
    });
    _viewSource = source;
    _viewKey = key;
    _viewRows = List.unmodifiable(rows);
    PerformanceTrace.record('stats.view_filter_sort', timer, rows: rows.length);
    return _viewRows;
  }

  bool get _showPerson => _type.endsWith('person');

  List<String> get _yearOptions {
    final years = _stats?.availableYears ?? [];
    return ['all', ...years];
  }

  String get _lawLabel =>
      _law == null ? '전체' : (_law == '__없음__' ? '없음' : _law!);

  void _setYear(String v) {
    if (v == _year) return;
    setState(() => _year = v);
    _load();
  }

  void _setLaw(String? law) {
    Navigator.pop(context);
    if (law == _law) return;
    setState(() => _law = law);
    _load();
  }

  void _showLawFilter() {
    final cat = _currentCat;
    final laws = [...cat.availableLaws];
    // 다른 분류에서 고른 법규는 이 분류 목록에 없어도 적용 중임을 보인다
    if (_law != null && _law != '__없음__' && !laws.contains(_law)) {
      laws.insert(0, _law!);
    }
    final hasEmpty = cat.hasEmptyLaw || _law == '__없음__';
    var query = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 전체 높이까지 끌어올려도 상태 표시줄 아래에서 멈춘다(SQ-U07).
      useSafeArea: true,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          final filtered = laws
              .where((l) => query.isEmpty || l.toLowerCase().contains(query))
              .toList();
          return DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            expand: false,
            builder: (_, controller) => Column(
              children: [
                // 손잡이는 테마(showDragHandle)가 그린다(SQ-U07).
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '위반법규 선택',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: '법규 이름으로 찾기',
                    ),
                    onChanged: (v) =>
                        setSheet(() => query = v.trim().toLowerCase()),
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    children: [
                      if (query.isEmpty)
                        _LawChip(
                          label: '전체',
                          selected: _law == null,
                          onTap: () => _setLaw(null),
                        ),
                      if (hasEmpty && query.isEmpty)
                        _LawChip(
                          label: '없음',
                          selected: _law == '__없음__',
                          onTap: () => _setLaw('__없음__'),
                        ),
                      ...filtered.map(
                        (l) => _LawChip(
                          label: l,
                          selected: _law == l,
                          onTap: () => _setLaw(l),
                        ),
                      ),
                      if (laws.isEmpty && !hasEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '이 분류에는 위반법규 값이 없습니다.',
                            style: TextStyle(color: context.sr.textSecondary),
                          ),
                        ),
                      if (query.isNotEmpty && filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '일치하는 법규가 없습니다.',
                            style: TextStyle(color: context.sr.textSecondary),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openMap() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReportMapScreen(initialYear: _year, initialCategory: _cat),
      ),
    );
  }

  void _scrollToDetail() {
    final ctx = _detailKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.02,
      );
    }
  }

  @override
  Widget build(BuildContext context) => PerformanceTrace.sync(
    'statistics.screen_build',
    () => _buildMeasured(context),
  );

  Widget _buildMeasured(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('통계'),
        actions: [
          TextButton.icon(
            onPressed: _openMap,
            icon: const Icon(Icons.map_outlined, size: 18),
            label: const Text('지도'),
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
      ),
      body: _loading && _stats == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _stats == null
          ? _buildError()
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    final rows = _visibleRows;
    // 0: 조건·요약·상세 머리, 1..n: 카드(또는 빈 안내), 마지막: 전국 안전신고 현황
    final cardCount = rows.isEmpty ? 1 : rows.length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        key: const PageStorageKey('stats-list'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: 1 + cardCount + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _buildHeader(rows);
          if (index == cardCount + 1) return _buildSunwi();
          if (rows.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  _search.isNotEmpty ? '검색 결과가 없습니다.' : '데이터가 없습니다.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          return _RowCard(
            row: rows[index - 1],
            showPerson: _showPerson,
            category: _cat,
            year: _year,
            law: _law,
          );
        },
      ),
    );
  }

  Widget _buildHeader(List<AgencyStatRow> rows) {
    final sr = context.sr;
    final summary = _overview?.forCategory(_cat);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Conditions(
          year: _year,
          yearOptions: _yearOptions,
          cat: _cat,
          lawLabel: _lawLabel,
          lawActive: _law != null,
          onYearChanged: _setYear,
          onCatChanged: (v) => setState(() => _cat = v),
          onLawTap: _showLawFilter,
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '새로 불러오지 못해 이전 결과를 보여 줍니다: $_error',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        const SizedBox(height: 10),
        // 요약 머리: 접기·상세 통계로 이동(큰 글자에서는 버튼이 다음 줄로)
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '요약 · ${_catLabels[_cat]}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: sr.textPrimary,
              ),
            ),
            Wrap(
              children: [
                TextButton(
                  key: const ValueKey('stats-summary-toggle'),
                  onPressed: () =>
                      setState(() => _summaryExpanded = !_summaryExpanded),
                  child: Text(_summaryExpanded ? '요약 접기' : '요약 펼치기'),
                ),
                TextButton.icon(
                  key: const ValueKey('stats-jump-detail'),
                  onPressed: _scrollToDetail,
                  icon: const Icon(Icons.south, size: 16),
                  label: const Text('상세 통계'),
                ),
              ],
            ),
          ],
        ),
        if (_summaryExpanded)
          StatsOverviewSection(
            summary: summary,
            categoryLabel: _catLabels[_cat] ?? '',
            yearBasis: _overview?.yearBasis ?? '',
            excludeWithdraw: _overview?.excludeWithdraw ?? false,
            year: _year,
            chartsExpanded: _chartsExpanded,
            onChartsExpandedChanged: (v) => setState(() => _chartsExpanded = v),
            onRetry: _overviewNotice != null && !_overviewLoading
                ? _retryOverview
                : null,
            notice:
                _overviewNotice ??
                (_overview == null ? '요약을 불러오는 중입니다…' : null),
          ),
        OutlinedButton.icon(
          key: const ValueKey('stats-open-map'),
          onPressed: _openMap,
          icon: const Icon(Icons.map_outlined),
          label: const Text('신고 지도 열기'),
        ),
        if (_law != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '신고 지도에는 답변 연도·분류만 적용됩니다(위반법규 조건은 지도에서 지원하지 않음).',
              style: TextStyle(fontSize: 11, color: sr.textSecondary),
            ),
          ),
        const SizedBox(height: 16),
        // ── 상세 통계 ──
        Text(
          '상세 통계',
          key: _detailKey,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: sr.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        _TypeGrid(
          type: _type,
          labels: _typeLabels,
          onChanged: (v) => setState(() => _type = v),
        ),
        const SizedBox(height: 8),
        Builder(
          builder: (context) {
            final search = TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: _showPerson ? '기관명·담당자명 검색' : '기관명 검색',
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '검색어 지우기',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _search = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _search = v),
            );
            final sort = DropdownButton<_SortKey>(
              value: _sort,
              underline: const SizedBox.shrink(),
              onChanged: (v) => setState(() => _sort = v ?? _SortKey.total),
              items: const [
                DropdownMenuItem(value: _SortKey.total, child: Text('총 건수순')),
                DropdownMenuItem(value: _SortKey.fines, child: Text('과태료 건수순')),
                DropdownMenuItem(
                  value: _SortKey.confirmedFine,
                  child: Text('확정 과태료순'),
                ),
                DropdownMenuItem(
                  value: _SortKey.avgDays,
                  child: Text('처리기간 짧은순'),
                ),
                DropdownMenuItem(value: _SortKey.rating, child: Text('별점 높은순')),
                DropdownMenuItem(value: _SortKey.name, child: Text('이름순')),
              ],
            );
            // 큰 글자(1.3배 초과)에서는 검색칸이 좁아지지 않게 정렬을 아래 줄로 내린다.
            if (MediaQuery.textScalerOf(context).scale(10) > 13) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  search,
                  Align(alignment: Alignment.centerRight, child: sort),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 8),
                sort,
              ],
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          _scopeText(rows, summary),
          style: TextStyle(
            fontSize: 11.5,
            color: sr.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  String _scopeText(List<AgencyStatRow> rows, OverviewSummary? summary) {
    final unit = _showPerson ? '명' : '곳';
    final all = _typeRows.length;
    final parts = <String>[
      '${_catLabels[_cat]} · ${_typeLabels[_type]}',
      _search.isEmpty
          ? '전체 $all$unit'
          : '검색 ${rows.length}$unit / 전체 $all$unit',
    ];
    if (summary != null && _stats != null) {
      final base = (_showPerson ? _currentCat.byPerson : _currentCat.byAgency)
          .fold<int>(0, (a, r) => a + r.total);
      final missing = summary.total - base;
      if (missing > 0) {
        parts.add(
          _showPerson
              ? '처리기관·담당자가 없는 $missing건은 담당자 목록에 없음'
              : '처리기관이 없는 $missing건은 기관 목록에 없음',
        );
      }
    }
    if (_type.startsWith('police')) parts.add("기관명에 '경찰'이 들어간 기관만");
    if (_type.startsWith('other')) parts.add("기관명에 '경찰'이 없는 기관만");
    parts.add('순서는 정렬 결과이며 평가 순위가 아닙니다. 카드를 누르면 해당 신고 목록으로 이동합니다.');
    return parts.join(' · ');
  }

  Widget _buildSunwi() {
    final sr = context.sr;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: sr.border),
          const SizedBox(height: 8),
          Text(
            '안전신문고 공개 통계의 행정구역별 현황입니다. 위의 내 신고 통계와 다른 자료이며 조건이 적용되지 않습니다.',
            style: TextStyle(
              fontSize: 11.5,
              color: sr.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          // 대시보드에서 옮겼다(2026-09-28).
          const SunwiSection(embedded: true),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
              onPressed: _load,
            ),
          ],
        ),
      ),
    );
  }
}

class _LawChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LawChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? context.sr.brandSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? color : context.sr.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? color : null,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

// ── 공통 조건(연도·분류·법규) ─────────────────────────────────────
class _Conditions extends StatelessWidget {
  final String year;
  final List<String> yearOptions;
  final String cat;
  final String lawLabel;
  final bool lawActive;
  final ValueChanged<String> onYearChanged;
  final ValueChanged<String> onCatChanged;
  final VoidCallback onLawTap;

  const _Conditions({
    required this.year,
    required this.yearOptions,
    required this.cat,
    required this.lawLabel,
    required this.lawActive,
    required this.onYearChanged,
    required this.onCatChanged,
    required this.onLawTap,
  });

  static const _cats = [
    ('traffic', '교통위반'),
    ('parking', '주정차위반'),
    ('other', '기타위반'),
  ];

  // 카테고리 식별색(교통 파랑 / 주정차 주황 / 기타 초록). 글자·테두리는 StatusTone 으로 AA 보정.
  Color _catColor(BuildContext context, String c) => switch (c) {
    'traffic' => context.sr.brand,
    'parking' => serverPartialAcceptColor,
    _ => serverAcceptColor,
  };

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 답변 연도(가로 스크롤)
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: yearOptions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final y = yearOptions[i];
              return _PillChip(
                label: y == 'all' ? '전체' : y,
                selected: year == y,
                onTap: () => onYearChanged(y),
                compact: true,
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: _cats.map((e) {
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _CategoryChip(
                  label: e.$2,
                  color: _catColor(context, e.$1),
                  selected: cat == e.$1,
                  onTap: () => onCatChanged(e.$1),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          label: '위반법규 선택, 현재 $lawLabel',
          excludeSemantics: true,
          child: InkWell(
            key: const ValueKey('stats-law-picker'),
            onTap: onLawTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: lawActive ? sr.brandSoft : scheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: lawActive ? scheme.primary : sr.border,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.gavel, size: 16, color: sr.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    '위반법규',
                    style: TextStyle(fontSize: 12.5, color: sr.textSecondary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      lawLabel,
                      softWrap: true,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: lawActive ? scheme.primary : sr.textPrimary,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more, size: 18, color: sr.textSecondary),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 여섯 보기: 두 줄(3+3)로 모두 보이게 한다(화면 밖에 숨기지 않음).
class _TypeGrid extends StatelessWidget {
  final String type;
  final Map<String, String> labels;
  final ValueChanged<String> onChanged;

  const _TypeGrid({
    required this.type,
    required this.labels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final keys = labels.keys.toList();
    // 큰 글자(1.3배 초과)에서는 2열 3줄, 보통은 3열 2줄. 어느 쪽이든 여섯 보기가 모두 보인다.
    final perRow = MediaQuery.textScalerOf(context).scale(10) > 13 ? 2 : 3;
    Widget row(List<String> ks) => Row(
      children: [
        for (final k in ks)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              child: _PillChip(
                key: ValueKey('stats-type-$k'),
                label: labels[k]!,
                selected: type == k,
                onTap: () => onChanged(k),
                expand: true,
              ),
            ),
          ),
      ],
    );
    return Column(
      children: [
        for (var i = 0; i < keys.length; i += perRow)
          row(keys.sublist(i, (i + perRow).clamp(0, keys.length))),
      ],
    );
  }
}

/// 선택형 알약 칩: 선택 = primary 채움(onPrimary 글자), 미선택 = 테두리만.
class _PillChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final bool expand;

  const _PillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sr = context.sr;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: BoxConstraints(minHeight: expand ? 36 : 0),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : (expand ? 6 : 14),
            vertical: expand ? 6 : 0,
          ),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? scheme.primary : sr.border),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            softWrap: true,
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? scheme.onPrimary : sr.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 카테고리 칩: 선택 시 식별색 틴트 + 굵은 테두리, 미선택은 표면색.
class _CategoryChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sr = context.sr;
    final tone = StatusTone.of(
      color,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? tone.background : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? tone.foreground : sr.border,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            softWrap: true,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected ? tone.foreground : sr.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 기관/담당자 카드 ────────────────────────────────────────────
class _RowCard extends StatelessWidget {
  final AgencyStatRow row;
  final bool showPerson;
  final String category;
  final String year;
  final String? law;

  const _RowCard({
    required this.row,
    required this.showPerson,
    required this.category,
    required this.year,
    required this.law,
  });

  void _openList(BuildContext context) {
    final agency = row.agency;
    final person = showPerson ? row.person : '';
    final provider = context.read<ReportProvider>();
    // S-08: 통계 연도는 답변일 기준이므로 drilldown 도 답변일 범위로 좁힌다.
    final responseDateStart = year == 'all' ? '' : '$year-01-01';
    final responseDateEnd = year == 'all' ? '' : '$year-12-31';
    provider.setFilter(
      ReportFilter(
        agency: agency,
        manager: person,
        law: law ?? '',
        responseDateStart: responseDateStart,
        responseDateEnd: responseDateEnd,
      ),
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReportListScreen(
          initialTabIndex: switch (category) {
            'parking' => 1,
            'other' => 2,
            _ => 0,
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sr = context.sr;
    Color fg(Color c) => StatusTone.of(
      c,
      brightness: theme.brightness,
      surface: scheme.surface,
    ).foreground;
    // (b) 분리 필드가 있으면(새 서버·Standalone) 기타·미분류를 셋으로 나눠 보인다. 구서버는 기존 한 칸.
    final hasSplit =
        row.dispositionUnknown != null &&
        row.noPenalty != null &&
        row.unclassified != null;
    final cells = <(String, int, double, Color)>[
      ('과태료', row.fines, row.finesPct, serverTrafficFineColor),
      ('경고/범칙금', row.warnings, row.warningsPct, serverTrafficPenaltyColor),
      ('불수용/기타', row.rejects, row.rejectsPct, serverRejectColor),
      // 표는 답변 완료 신고만이라 처리중은 없다(2026-09-28). 예전 서버가 처리중을 섞어 보낼 때만 보인다.
      if ((row.inProgress ?? 0) > 0)
        ('처리중', row.inProgress!, row.inProgressPct ?? 0, serverProcessingColor),
      if (hasSplit) ...[
        (
          '과태료 미확인',
          row.dispositionUnknown!,
          row.dispositionUnknownPct ?? 0,
          serverUnconfirmedColor,
        ),
        (
          '처분 대상 아님',
          row.noPenalty!,
          row.noPenaltyPct ?? 0,
          serverWithdrawColor,
        ),
        (
          '기타·미분류',
          row.unclassified!,
          row.unclassifiedPct ?? 0,
          serverUnconfirmedColor,
        ),
      ] else
        // S-04: 대시보드 '처분 미확인'(교통, 처분이 '미확인')과 뜻이 달라 이름을 나눈다.
        ('기타·미분류', row.unconfirmed, row.unconfirmedPct, serverUnconfirmedColor),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openList(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 이름 + 우측 '총 N건' ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          showPerson && row.person.isNotEmpty
                              ? row.person
                              : row.agency,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          softWrap: true,
                        ),
                        if (showPerson && row.person.isNotEmpty)
                          Text(
                            '소속 ${row.agency}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: sr.textSecondary,
                            ),
                            softWrap: true,
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '총 ',
                            style: TextStyle(
                              fontSize: 11,
                              color: sr.textSecondary,
                            ),
                          ),
                          TextSpan(
                            text: '${row.total}',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: scheme.primary,
                            ),
                          ),
                          TextSpan(
                            text: '건',
                            style: TextStyle(
                              fontSize: 11,
                              color: sr.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // ── 보조 영역: 처리기간·별점·금액(한 줄에 억지로 넣지 않고 줄바꿈) ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                decoration: BoxDecoration(
                  color: sr.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 14,
                      runSpacing: 4,
                      children: [
                        _MetaItem(
                          icon: Icons.schedule,
                          color: fg(serverCompletedColor),
                          text: row.avgResponseDays == null
                              ? '평균 처리 —'
                              : '평균 처리 ${row.avgResponseDays!.toStringAsFixed(1)}일'
                                    '${row.avgDaysCount != null ? ' (표본 ${row.avgDaysCount}건)' : ''}',
                        ),
                        _MetaItem(
                          icon: Icons.star,
                          color: fg(serverPartialAcceptColor),
                          text: row.avgRating == null
                              ? '평가 없음'
                              : '${row.avgRating!.toStringAsFixed(2)} (${row.ratingCount}명)',
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    StatsFineBreakdown(row: row),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // ── 처분별 건수·비율(3열 그리드) ──
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 300 ? 3 : 2;
                  final w =
                      (constraints.maxWidth - 6 * (columns - 1)) / columns;
                  return Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in cells)
                        SizedBox(
                          width: w,
                          child: _StatBadge(
                            label: c.$1,
                            count: c.$2,
                            pct: c.$3,
                            color: c.$4,
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              if (row.total > 0)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      for (final c in cells)
                        if (c.$2 > 0)
                          Flexible(
                            flex: c.$2,
                            child: Container(height: 6, color: c.$4),
                          ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _MetaItem({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            text,
            softWrap: true,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatBadge extends StatelessWidget {
  final String label;
  final int count;
  final double pct;
  final Color color;

  const _StatBadge({
    required this.label,
    required this.count,
    required this.pct,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = StatusTone.of(
      color,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );
    final muted = count == 0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      decoration: BoxDecoration(
        color: muted ? context.sr.surfaceAlt : tone.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: muted ? context.sr.border : tone.border),
      ),
      child: Column(
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: muted ? context.sr.textSecondary : tone.foreground,
            ),
          ),
          Text(
            '$label ${pct.toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 10,
              color: muted ? context.sr.textSecondary : tone.foreground,
            ),
            textAlign: TextAlign.center,
            softWrap: true,
          ),
        ],
      ),
    );
  }
}
