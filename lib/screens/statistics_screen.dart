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
import '../theme/sr_colors.dart';
import '../widgets/stats_overview_section.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  AgencyStats? _stats;
  bool _loading = true;
  String? _error;

  /// 요약 카드 + 월별 추이. 기관표와 독립적으로 불러와서 실패해도 표는 그대로 보인다.
  StatsOverview? _overview;
  String? _overviewNotice;

  String _year = 'all'; // 'all' | '2026' | '2025' | ...
  String _cat = 'traffic'; // traffic | parking | other
  String _type =
      'agency'; // agency | person | police-agency | police-person | other-agency | other-person
  String? _law; // null = 전체, '__없음__' = 법규 없음, 그 외 = 특정 법규

  int _lastRefreshNonce = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 탭 전환 시 ReportProvider.bumpStatsRefresh() 로 nonce 가 변경되면 재로드
    final nonce = context.watch<ReportProvider>().statsRefreshNonce;
    if (nonce != _lastRefreshNonce) {
      _lastRefreshNonce = nonce;
      if (nonce != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final p = context.read<ReportProvider>();
    final year = _year == 'all' ? null : _year;
    try {
      AgencyStats stats;
      if (p.appMode == AppMode.standalone) {
        final raw = await LocalDbService.computeStats(
          year: year,
          law: _law,
          excludeWithdraw: p.excludeWithdraw,
          normalizePolice: p.normalizePolice,
          useRepresentativeRecords: p.useRepresentativeRecords,
        );
        stats = AgencyStats.fromJson(raw);
      } else {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        stats = await api.getStats(year: year, law: _law);
      }
      if (mounted) {
        setState(() {
          _stats = stats;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
      return;
    }
    await _loadOverview(p, year);
  }

  Future<void> _loadOverview(ReportProvider p, String? year) async {
    StatsOverview? overview;
    String? notice;
    try {
      if (p.appMode == AppMode.standalone) {
        // sqflite 단일 연결: 기관표 집계가 끝난 뒤 순차 실행한다.
        overview = StatsOverview.fromJson(
          await LocalDbService.computeStatsOverview(
            year: year,
            law: _law,
            excludeWithdraw: p.excludeWithdraw,
            useRepresentativeRecords: p.useRepresentativeRecords,
          ),
        );
      } else {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        overview = await api.getStatsOverview(year: year, law: _law);
      }
    } on ApiFeatureUnavailableException catch (e) {
      notice = e.message;
    } catch (e) {
      notice = '요약을 불러오지 못했습니다: $e';
    }
    if (!mounted) return;
    setState(() {
      _overview = overview;
      _overviewNotice = notice;
    });
  }

  static const _catLabels = {
    'traffic': '교통위반',
    'parking': '주정차위반',
    'other': '기타위반',
  };

  Widget get _overviewHeader => StatsOverviewSection(
    summary: _overview?.forCategory(_cat),
    categoryLabel: _catLabels[_cat] ?? '',
    yearBasis: _overview?.yearBasis ?? '',
    excludeWithdraw: _overview?.excludeWithdraw ?? false,
    notice: _overviewNotice ?? (_overview == null ? '요약을 불러오는 중입니다…' : null),
  );

  List<AgencyStatRow> get _currentRows {
    if (_stats == null) return [];
    final group = _cat == 'traffic'
        ? _stats!.traffic
        : _cat == 'parking'
        ? _stats!.parking
        : _stats!.other;
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

  CategoryStats get _currentCat {
    if (_stats == null)
      return const CategoryStats(
        byAgency: [],
        byPerson: [],
        policeByAgency: [],
        policeByPerson: [],
        otherByAgency: [],
        otherByPerson: [],
      );
    return _cat == 'traffic'
        ? _stats!.traffic
        : _cat == 'parking'
        ? _stats!.parking
        : _stats!.other;
  }

  bool get _showPerson => _type.endsWith('person');

  List<String> get _yearOptions {
    final years = _stats?.availableYears ?? [];
    return ['all', ...years];
  }

  void _showLawFilter() {
    final cat = _currentCat;
    final laws = cat.availableLaws;
    final hasEmpty = cat.hasEmptyLaw;
    if (laws.isEmpty && !hasEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, controller) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.sr.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '위반법규 필터',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                children: [
                  _LawChip(
                    label: '전체',
                    selected: _law == null,
                    onTap: () {
                      Navigator.pop(context);
                      if (_law != null) setState(() => _law = null);
                      _load();
                    },
                  ),
                  if (hasEmpty)
                    _LawChip(
                      label: '없음',
                      selected: _law == '__없음__',
                      onTap: () {
                        Navigator.pop(context);
                        final newLaw = '__없음__';
                        if (_law != newLaw) setState(() => _law = newLaw);
                        _load();
                      },
                    ),
                  ...laws.map(
                    (l) => _LawChip(
                      label: l,
                      selected: _law == l,
                      onTap: () {
                        Navigator.pop(context);
                        if (_law != l) setState(() => _law = l);
                        _load();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lawActive = _law != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('통계'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ReportMapScreen(initialYear: _year, initialCategory: 'all'),
              ),
            ),
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
      body: Column(
        children: [
          _NavBar(
            year: _year,
            yearOptions: _yearOptions,
            cat: _cat,
            type: _type,
            onYearChanged: (v) {
              setState(() => _year = v);
              _load();
            },
            onCatChanged: (v) => setState(() => _cat = v),
            onTypeChanged: (v) => setState(() => _type = v),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _buildError()
                : _StatsTable(
                    header: _overviewHeader,
                    rows: _currentRows,
                    showPerson: _showPerson,
                    category: _cat,
                    year: _year,
                    law: _law,
                    onRefresh: _load,
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _showLawFilter,
        tooltip: '위반법규 필터',
        backgroundColor: lawActive
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        foregroundColor: lawActive
            ? Theme.of(context).colorScheme.onPrimary
            : Theme.of(context).colorScheme.onSurface,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.gavel, size: 20),
            if (lawActive)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: serverSupplementColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
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

// ── 3-way 네비게이션 바 ──────────────────────────────────────────
class _NavBar extends StatelessWidget {
  final String year;
  final List<String> yearOptions;
  final String cat;
  final String type;
  final ValueChanged<String> onYearChanged;
  final ValueChanged<String> onCatChanged;
  final ValueChanged<String> onTypeChanged;

  const _NavBar({
    required this.year,
    required this.yearOptions,
    required this.cat,
    required this.type,
    required this.onYearChanged,
    required this.onCatChanged,
    required this.onTypeChanged,
  });

  static const _cats = [
    ('traffic', '교통위반'),
    ('parking', '주정차위반'),
    ('other', '기타위반'),
  ];

  static const _types = [
    ('agency', '기관별'),
    ('person', '담당자별'),
    ('police-agency', '경찰 기관'),
    ('police-person', '경찰 담당자'),
    ('other-agency', '비경찰 기관'),
    ('other-person', '비경찰 담당자'),
  ];

  // 카테고리 식별색(교통 파랑 / 주정차 주황 / 기타 초록). 글자·테두리는 StatusTone 으로 AA 보정.
  Color _catColor(String c) => switch (c) {
    'traffic' => const Color(0xFF0D6EFD),
    'parking' => serverPartialAcceptColor,
    _ => serverAcceptColor,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 0행: 연도별 (가로 스크롤)
          if (yearOptions.length > 1)
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
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
          // 1행: 카테고리
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: _cats.map((e) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _CategoryChip(
                      label: e.$2,
                      color: _catColor(e.$1),
                      selected: cat == e.$1,
                      onTap: () => onCatChanged(e.$1),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // 2행: 유형 (가로 스크롤)
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              itemCount: _types.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final e = _types[i];
                return _PillChip(
                  label: e.$2,
                  selected: type == e.$1,
                  onTap: () => onTypeChanged(e.$1),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

/// 선택형 알약 칩: 선택 = primary 채움(onPrimary 글자), 미선택 = 테두리만.
class _PillChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  const _PillChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
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
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 14),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? scheme.primary : sr.border),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
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
          padding: const EdgeInsets.symmetric(vertical: 9),
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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

// ── 통계 목록 ────────────────────────────────────────────────────
class _StatsTable extends StatelessWidget {
  final Widget? header;
  final List<AgencyStatRow> rows;
  final bool showPerson;
  final String category;
  final String year;
  final String? law;
  final Future<void> Function() onRefresh;

  const _StatsTable({
    this.header,
    required this.rows,
    required this.showPerson,
    required this.category,
    required this.year,
    required this.law,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
          children: [
            ?header,
            const SizedBox(height: 60),
            Center(
              child: Text(
                '데이터가 없습니다.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: rows.length + (header == null ? 0 : 1),
        itemBuilder: (context, index) {
          final i = header == null ? index : index - 1;
          if (i < 0) return header!;
          return _RowCard(
            row: rows[i],
            showPerson: showPerson,
            rank: i + 1,
            category: category,
            year: year,
            law: law,
          );
        },
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  final AgencyStatRow row;
  final bool showPerson;
  final int rank;
  final String category;
  final String year;
  final String? law;

  const _RowCard({
    required this.row,
    required this.showPerson,
    required this.rank,
    required this.category,
    required this.year,
    required this.law,
  });

  String _formatFine(int amount) {
    if (amount <= 0) return '';
    if (amount >= 10000) {
      final man = amount ~/ 10000;
      final rest = amount % 10000;
      if (rest == 0) return '${man}만원';
      return '${man}만 ${_comma(rest)}원';
    }
    return '${_comma(amount)}원';
  }

  String _comma(int v) {
    return v.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sr = context.sr;
    // 기준색을 카드 표면 위 AA 글자색으로 바꾼다.
    Color fg(Color c) => StatusTone.of(
      c,
      brightness: theme.brightness,
      surface: scheme.surface,
    ).foreground;
    final fineStr = _formatFine(row.totalFineAmount);
    // 2026-09-24: 확정 과태료와 법정 최저 기준 추정 과태료는 항상 따로 표시한다(PROJECT_RULES §3-2).
    final estimatedStr = (row.estimatedFineCount ?? 0) > 0
        ? _formatFine(row.estimatedFineAmount ?? 0)
        : '';
    final fineParts = <String>[
      if (fineStr.isNotEmpty)
        row.fineAmountUnknown > 0
            ? '확정 $fineStr · 금액 미확인 ${row.fineAmountUnknown}건'
            : '확정 $fineStr',
      if (estimatedStr.isNotEmpty)
        '추정 $estimatedStr (${row.estimatedFineCount}건)',
    ];
    // (b) 분리 필드가 있으면(새 서버·Standalone) 기타·미분류를 셋으로 나눠 보인다. 구서버는 기존 한 칸.
    final hasSplit =
        row.dispositionUnknown != null &&
        row.noPenalty != null &&
        row.unclassified != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
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
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 좌상단 메트릭 한 줄 (별점 · 평균 소요 · 과태료 합계) ──
              if (row.avgRating != null ||
                  row.avgResponseDays != null ||
                  fineStr.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      if (row.avgRating != null) ...[
                        Icon(Icons.star, size: 12, color: fg(_ratingColor)),
                        const SizedBox(width: 2),
                        Text(
                          '${row.avgRating!.toStringAsFixed(2)} (${row.ratingCount})',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: fg(_ratingColor),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (row.avgResponseDays != null) ...[
                        Icon(
                          Icons.schedule,
                          size: 11,
                          color: fg(serverCompletedColor),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${row.avgResponseDays!.toStringAsFixed(1)}일',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: fg(serverCompletedColor),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (fineParts.isNotEmpty) ...[
                        Icon(
                          Icons.payments_outlined,
                          size: 11,
                          color: fg(serverTrafficFineColor),
                        ),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            fineParts.join(' / '),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: fg(serverTrafficFineColor),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              // ── 이름 + 우측 '총 N건' ──
              Row(
                children: [
                  Builder(
                    builder: (context) {
                      // 1~3위 금·은·동은 틴트 원 + AA 글자(흰 글자 채움은 대비 미달).
                      final medal = rank <= 3
                          ? StatusTone.of(
                              _medalColors[rank - 1],
                              brightness: theme.brightness,
                              surface: scheme.surface,
                            )
                          : null;
                      return Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: medal?.background ?? sr.surfaceAlt,
                          shape: BoxShape.circle,
                          border: Border.all(color: medal?.border ?? sr.border),
                        ),
                        child: Center(
                          child: Text(
                            '$rank',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: medal?.foreground ?? sr.textSecondary,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.agency,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                          ),
                          softWrap: true,
                        ),
                        if (showPerson && row.person.isNotEmpty)
                          Text(
                            row.person,
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
                    padding: const EdgeInsets.only(left: 6),
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(color: scheme.primary),
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
                              fontSize: 16,
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
              LayoutBuilder(
                builder: (context, constraints) {
                  final badgeWidth = (constraints.maxWidth - 6) / 2;
                  return Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      SizedBox(
                        width: badgeWidth,
                        child: _statBadge(
                          '과태료',
                          row.fines,
                          row.finesPct,
                          serverTrafficFineColor,
                        ),
                      ),
                      SizedBox(
                        width: badgeWidth,
                        child: _statBadge(
                          '경고/범칙금',
                          row.warnings,
                          row.warningsPct,
                          serverTrafficPenaltyColor,
                        ),
                      ),
                      SizedBox(
                        width: badgeWidth,
                        child: _statBadge(
                          '불수용/기타',
                          row.rejects,
                          row.rejectsPct,
                          serverRejectColor,
                        ),
                      ),
                      if (!hasSplit)
                        SizedBox(
                          width: badgeWidth,
                          // S-04: 대시보드 '처분 미확인'(교통, 처분이 '미확인')과 뜻이 달라 이름을 나눈다.
                          child: _statBadge(
                            '기타·미분류',
                            row.unconfirmed,
                            row.unconfirmedPct,
                            serverUnconfirmedColor,
                          ),
                        ),
                      if (hasSplit && row.dispositionUnknown! > 0)
                        SizedBox(
                          width: badgeWidth,
                          child: _statBadge(
                            '처분 미확인',
                            row.dispositionUnknown!,
                            row.dispositionUnknownPct ?? 0,
                            serverUnconfirmedColor,
                          ),
                        ),
                      if (hasSplit && row.noPenalty! > 0)
                        SizedBox(
                          width: badgeWidth,
                          child: _statBadge(
                            '처분 대상 아님',
                            row.noPenalty!,
                            row.noPenaltyPct ?? 0,
                            serverWithdrawColor,
                          ),
                        ),
                      if (hasSplit && row.unclassified! > 0)
                        SizedBox(
                          width: badgeWidth,
                          child: _statBadge(
                            '기타·미분류',
                            row.unclassified!,
                            row.unclassifiedPct ?? 0,
                            serverUnconfirmedColor,
                          ),
                        ),
                      // S-10: 배정된 처리중 신고. 구서버(null)·0건이면 숨긴다.
                      if ((row.inProgress ?? 0) > 0)
                        SizedBox(
                          width: badgeWidth,
                          child: _statBadge(
                            '처리중',
                            row.inProgress!,
                            row.inProgressPct ?? 0,
                            serverProcessingColor,
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 6),
              if (row.total > 0)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      if (row.fines > 0)
                        Flexible(
                          flex: row.fines,
                          child: Container(
                            height: 6,
                            color: serverTrafficFineColor,
                          ),
                        ),
                      if (row.warnings > 0)
                        Flexible(
                          flex: row.warnings,
                          child: Container(
                            height: 6,
                            color: serverTrafficPenaltyColor,
                          ),
                        ),
                      if (row.rejects > 0)
                        Flexible(
                          flex: row.rejects,
                          child: Container(height: 6, color: serverRejectColor),
                        ),
                      if (row.unconfirmed > 0)
                        Flexible(
                          flex: row.unconfirmed,
                          child: Container(
                            height: 6,
                            color: serverUnconfirmedColor,
                          ),
                        ),
                      if ((row.inProgress ?? 0) > 0)
                        Flexible(
                          flex: row.inProgress!,
                          child: Container(
                            height: 6,
                            color: serverProcessingColor,
                          ),
                        ),
                      Flexible(
                        flex:
                            (row.total -
                                    row.fines -
                                    row.warnings -
                                    row.rejects -
                                    row.unconfirmed -
                                    (row.inProgress ?? 0))
                                .clamp(0, row.total),
                        child: Container(height: 6, color: sr.border),
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

  static const _ratingColor = Color(0xFFF59E0B);
  static const _medalColors = [
    Color(0xFFF59E0B), // 금
    Color(0xFF94A3B8), // 은
    Color(0xFFB45309), // 동
  ];

  Widget _statBadge(String label, int count, double pct, Color color) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final tone = StatusTone.of(
          color,
          brightness: theme.brightness,
          surface: theme.colorScheme.surface,
        );
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: tone.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tone.border),
          ),
          child: Column(
            children: [
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: tone.foreground,
                ),
              ),
              Text(
                '$label (${pct.toStringAsFixed(1)}%)',
                style: TextStyle(fontSize: 10, color: tone.foreground),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );
  }
}
