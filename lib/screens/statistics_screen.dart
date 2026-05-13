import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/agency_stats.dart';
import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../server_palette.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import 'report_list_screen.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  AgencyStats? _stats;
  bool _loading = true;
  String? _error;

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
    try {
      final p = context.read<ReportProvider>();
      AgencyStats stats;
      if (p.appMode == AppMode.standalone) {
        final raw = await LocalDbService.computeStats(
          year: _year == 'all' ? null : _year,
          law: _law,
          excludeWithdraw: p.excludeWithdraw,
          normalizePolice: p.normalizePolice,
          useRepresentativeRecords: p.useRepresentativeRecords,
        );
        stats = AgencyStats.fromJson(raw);
      } else {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        stats = await api.getStats(
          year: _year == 'all' ? null : _year,
          law: _law,
        );
      }
      if (mounted)
        setState(() {
          _stats = stats;
          _loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString();
          _loading = false;
        });
    }
  }

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
                color: Colors.grey.shade300,
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
      appBar: AppBar(title: const Text('통계')),
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
                    color: Colors.orange,
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
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
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
          color: selected ? color.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? color : Colors.grey.shade300),
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

  Color _catColor(String c) => switch (c) {
    'traffic' => Colors.blue,
    'parking' => Colors.orange,
    _ => Colors.green,
  };

  @override
  Widget build(BuildContext context) {
    final catColor = _catColor(cat);

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 0행: 연도별 (가로 스크롤)
          if (yearOptions.length > 1)
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                itemCount: yearOptions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final y = yearOptions[i];
                  final label = y == 'all' ? '전체' : y;
                  final selected = year == y;
                  return GestureDetector(
                    onTap: () => onYearChanged(y),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.blueGrey.shade700
                            : Colors.blueGrey.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected
                              ? Colors.blueGrey.shade700
                              : Colors.blueGrey.withOpacity(0.3),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: selected
                              ? Colors.white
                              : Colors.blueGrey.shade700,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          // 1행: 카테고리
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: _cats.map((e) {
                final selected = cat == e.$1;
                final color = _catColor(e.$1);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: GestureDetector(
                      onTap: () => onCatChanged(e.$1),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: selected ? color : color.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected ? color : color.withOpacity(0.3),
                          ),
                        ),
                        child: Text(
                          e.$2,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: selected ? Colors.white : color,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // 2행: 유형 (가로 스크롤)
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _types.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final e = _types[i];
                final selected = type == e.$1;
                return GestureDetector(
                  onTap: () => onTypeChanged(e.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: selected ? catColor : catColor.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected ? catColor : catColor.withOpacity(0.3),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      e.$2,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: selected ? Colors.white : catColor,
                      ),
                    ),
                  ),
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

// ── 통계 목록 ────────────────────────────────────────────────────
class _StatsTable extends StatelessWidget {
  final List<AgencyStatRow> rows;
  final bool showPerson;
  final String category;
  final String year;
  final String? law;
  final Future<void> Function() onRefresh;

  const _StatsTable({
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
          children: const [
            SizedBox(height: 120),
            Center(
              child: Text('데이터가 없습니다.', style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: rows.length,
        itemBuilder: (context, i) => _RowCard(
          row: rows[i],
          showPerson: showPerson,
          rank: i + 1,
          category: category,
          year: year,
          law: law,
        ),
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
    final scheme = Theme.of(context).colorScheme;
    final fineStr = _formatFine(row.totalFineAmount);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          final agency = row.agency;
          final person = showPerson ? row.person : '';
          final provider = context.read<ReportProvider>();
          final reportDateStart = year == 'all' ? '' : '$year-01-01';
          final reportDateEnd = year == 'all' ? '' : '$year-12-31';
          provider.setFilter(
            ReportFilter(
              agency: agency,
              manager: person,
              law: law ?? '',
              reportDateStart: reportDateStart,
              reportDateEnd: reportDateEnd,
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
                        const Icon(Icons.star, size: 12, color: Colors.amber),
                        const SizedBox(width: 2),
                        Text(
                          '${row.avgRating!.toStringAsFixed(2)} (${row.ratingCount})',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.amber,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (row.avgResponseDays != null) ...[
                        const Icon(
                          Icons.schedule,
                          size: 11,
                          color: Colors.teal,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${row.avgResponseDays!.toStringAsFixed(1)}일',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.teal,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (fineStr.isNotEmpty) ...[
                        const Icon(
                          Icons.payments_outlined,
                          size: 11,
                          color: serverTrafficFineColor,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          fineStr,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: serverTrafficFineColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              // ── 이름 + 우측 '총 처리 N건' ──
              Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: rank <= 3
                          ? [
                              Colors.amber,
                              Colors.grey.shade400,
                              Colors.brown.shade300,
                            ][rank - 1]
                          : scheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '$rank',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: rank <= 3 ? Colors.white : scheme.onSurface,
                        ),
                      ),
                    ),
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
                              color: Colors.grey.shade600,
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
                          const TextSpan(
                            text: '총 처리 ',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                          TextSpan(
                            text: '${row.total}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: scheme.primary,
                            ),
                          ),
                          const TextSpan(
                            text: '건',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _statBadge(
                    '과태료',
                    row.fines,
                    row.finesPct,
                    serverTrafficFineColor,
                  ),
                  const SizedBox(width: 6),
                  _statBadge(
                    '경고/범칙금',
                    row.warnings,
                    row.warningsPct,
                    serverTrafficPenaltyColor,
                  ),
                  const SizedBox(width: 6),
                  _statBadge(
                    '불수용',
                    row.rejects,
                    row.rejectsPct,
                    serverRejectColor,
                  ),
                ],
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
                            color: Colors.red.shade400,
                          ),
                        ),
                      if (row.warnings > 0)
                        Flexible(
                          flex: row.warnings,
                          child: Container(
                            height: 6,
                            color: Colors.orange.shade400,
                          ),
                        ),
                      if (row.rejects > 0)
                        Flexible(
                          flex: row.rejects,
                          child: Container(
                            height: 6,
                            color: Colors.grey.shade400,
                          ),
                        ),
                      Flexible(
                        flex:
                            (row.total - row.fines - row.warnings - row.rejects)
                                .clamp(0, row.total),
                        child: Container(
                          height: 6,
                          color: Colors.blue.shade100,
                        ),
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

  Widget _statBadge(String label, int count, double pct, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              '$label (${pct.toStringAsFixed(1)}%)',
              style: TextStyle(fontSize: 10, color: color.withOpacity(0.8)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
