import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/agency_stats.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import 'filtered_list_screen.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  AgencyStats? _stats;
  bool _loading = true;
  String? _error;

  String _year = 'all';  // 'all' | '2026' | '2025' | ...
  String _cat = 'traffic';  // traffic | parking | other
  String _type = 'agency';  // agency | person | police-agency | police-person | other-agency | other-person

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final p = context.read<ReportProvider>();
      final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
      final stats = await api.getStats(year: _year == 'all' ? null : _year);
      if (mounted) setState(() { _stats = stats; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<AgencyStatRow> get _currentRows {
    if (_stats == null) return [];
    final group = _cat == 'traffic' ? _stats!.traffic
                : _cat == 'parking' ? _stats!.parking
                : _stats!.other;
    return switch (_type) {
      'agency'        => group.byAgency,
      'person'        => group.byPerson,
      'police-agency' => group.policeByAgency,
      'police-person' => group.policeByPerson,
      'other-agency'  => group.otherByAgency,
      'other-person'  => group.otherByPerson,
      _               => group.byAgency,
    };
  }

  bool get _showPerson => _type.endsWith('person');

  List<String> get _yearOptions {
    final years = _stats?.availableYears ?? [];
    return ['all', ...years];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('통계'),
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
                        rows: _currentRows,
                        showPerson: _showPerson,
                        category: _cat,
                        onRefresh: _load,
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 16),
          FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
              onPressed: _load),
        ]),
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
    ('other',   '기타위반'),
  ];

  static const _types = [
    ('agency',        '기관별'),
    ('person',        '담당자별'),
    ('police-agency', '경찰 기관'),
    ('police-person', '경찰 담당자'),
    ('other-agency',  '비경찰 기관'),
    ('other-person',  '비경찰 담당자'),
  ];

  Color _catColor(String c) => switch (c) {
    'traffic' => Colors.blue,
    'parking' => Colors.orange,
    _         => Colors.green,
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                        color: selected ? Colors.blueGrey.shade700 : Colors.blueGrey.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected ? Colors.blueGrey.shade700 : Colors.blueGrey.withOpacity(0.3),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                          color: selected ? Colors.white : Colors.blueGrey.shade700,
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
                          color: selected
                              ? color
                              : color.withOpacity(0.08),
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
                      color: selected
                          ? catColor
                          : catColor.withOpacity(0.07),
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
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
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
  final Future<void> Function() onRefresh;

  const _StatsTable({
    required this.rows,
    required this.showPerson,
    required this.category,
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
              child: Text('데이터가 없습니다.',
                  style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        itemCount: rows.length,
        itemBuilder: (context, i) => _RowCard(
            row: rows[i], showPerson: showPerson, rank: i + 1, category: category),
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  final AgencyStatRow row;
  final bool showPerson;
  final int rank;
  final String category;

  const _RowCard({
    required this.row,
    required this.showPerson,
    required this.rank,
    required this.category,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          final agency = row.agency;
          final person = showPerson ? row.person : '';
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FilteredListScreen(
                title: (showPerson && person.isNotEmpty)
                    ? '$agency / $person'
                    : agency,
                category: category,
                filter: (r) {
                  final agencyMatch = r.agency == agency;
                  final personMatch =
                      person.isEmpty || r.manager == person;
                  return agencyMatch && personMatch;
                },
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24, height: 24,
                    decoration: BoxDecoration(
                      color: rank <= 3
                          ? [Colors.amber, Colors.grey.shade400, Colors.brown.shade300][rank - 1]
                          : scheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('$rank',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: rank <= 3 ? Colors.white : scheme.onSurface)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.agency,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14),
                            overflow: TextOverflow.ellipsis),
                        if (showPerson && row.person.isNotEmpty)
                          Text(row.person,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600),
                              overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${row.total}건',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: scheme.primary)),
                      const Text('총 처리',
                          style: TextStyle(fontSize: 10, color: Colors.grey)),
                      if (row.avgResponseDays != null) ...[
                        Text('${row.avgResponseDays!.toStringAsFixed(1)}일',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.teal)),
                        const Text('평균 소요',
                            style: TextStyle(fontSize: 10, color: Colors.grey)),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _statBadge('과태료', row.fines, row.finesPct, Colors.red),
                  const SizedBox(width: 8),
                  _statBadge('경고/범칙금', row.warnings, row.warningsPct, Colors.orange),
                  const SizedBox(width: 8),
                  _statBadge('불수용', row.rejects, row.rejectsPct, Colors.grey),
                ],
              ),
              const SizedBox(height: 8),
              if (row.total > 0)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      if (row.fines > 0)
                        Flexible(
                          flex: row.fines,
                          child: Container(height: 6, color: Colors.red.shade400),
                        ),
                      if (row.warnings > 0)
                        Flexible(
                          flex: row.warnings,
                          child: Container(height: 6, color: Colors.orange.shade400),
                        ),
                      if (row.rejects > 0)
                        Flexible(
                          flex: row.rejects,
                          child: Container(height: 6, color: Colors.grey.shade400),
                        ),
                      Flexible(
                        flex: row.total - row.fines - row.warnings - row.rejects,
                        child: Container(height: 6, color: Colors.blue.shade100),
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
            Text('$count',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: color)),
            Text('$label ($pct%)',
                style: TextStyle(fontSize: 10, color: color.withOpacity(0.8)),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
