import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/stats_overview.dart';
import '../server_palette.dart';
import '../theme/sr_colors.dart';

/// 통계 화면 상단 요약(2026-09-28 개편). 모든 수치는 [summary] 런타임 집계
/// (Client: 서버 `/api/v1/stats/overview`, Standalone: `LocalDbService.computeStatsOverview`)에서 온다.
/// 정의: `docs/design/statistics-spec.md` §9 — 월별 추이는 답변일 기준 처리 건수, 확정·추정 과태료는 따로.
///
/// 구성: 2열 요약 카드 6개 → 간결한 월별 처리 추이 → (펼치기) 처분 분포·위반 유형.
class StatsOverviewSection extends StatelessWidget {
  final OverviewSummary? summary;
  final String categoryLabel;

  /// 연도 필터가 어느 날짜 컬럼 기준인지('답변일').
  final String yearBasis;

  /// 요약을 표시할 수 없을 때 안내 문구(구서버 미지원·실패). null 이면 정상.
  final String? notice;

  /// 요약만 실패했을 때 다시 불러오기. null 이면 버튼을 숨긴다.
  final VoidCallback? onRetry;

  /// 취하 데이터 숨기기 설정이 적용됐는지(각주 표시용).
  final bool excludeWithdraw;

  /// 선택한 답변 연도('all' 또는 'YYYY'). 월 축 범위를 정한다.
  final String year;

  /// 처분 분포·위반 유형 차트를 펼쳤는지.
  final bool chartsExpanded;
  final ValueChanged<bool>? onChartsExpandedChanged;

  /// 테스트에서 '이번 달'을 고정하려고 쓴다. null 이면 기기 날짜.
  final DateTime? now;

  const StatsOverviewSection({
    super.key,
    required this.summary,
    required this.categoryLabel,
    required this.yearBasis,
    this.notice,
    this.onRetry,
    this.excludeWithdraw = false,
    this.year = 'all',
    this.chartsExpanded = false,
    this.onChartsExpandedChanged,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    if (notice != null || summary == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sr.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sr.border),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: sr.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  notice ?? '요약을 불러오지 못했습니다.',
                  style: TextStyle(fontSize: 12.5, color: sr.textSecondary),
                ),
              ),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    final s = summary!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SummaryGrid(summary: s),
          const SizedBox(height: 12),
          _MonthlyTrendCard(summary: s, year: year, now: now ?? DateTime.now()),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('stats-charts-toggle'),
              onPressed: onChartsExpandedChanged == null
                  ? null
                  : () => onChartsExpandedChanged!(!chartsExpanded),
              icon: Icon(
                chartsExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(
                chartsExpanded ? '처분 분포·위반 유형 접기' : '처분 분포·위반 유형 펼치기',
              ),
            ),
          ),
          if (chartsExpanded) ...[
            _DispositionCard(summary: s),
            const SizedBox(height: 12),
            _ReportTypesCard(summary: s),
            const SizedBox(height: 8),
          ],
          _Footnotes(
            summary: s,
            yearBasis: yearBasis,
            excludeWithdraw: excludeWithdraw,
          ),
        ],
      ),
    );
  }
}

String _comma(num value) => value.toInt().toString().replaceAllMapped(
  RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
  (match) => '${match[1]},',
);

/// 분모 0 은 계산 불가('—'), 실제 0 은 0.0%.
String _pct(int n, int d) =>
    d > 0 ? '${(n / d * 100).toStringAsFixed(1)}%' : '—';

class _SummaryItem {
  final String label;
  final String value;
  final List<String> captions;
  final Color color;

  const _SummaryItem(this.label, this.value, this.captions, this.color);
}

class _SummaryGrid extends StatelessWidget {
  final OverviewSummary summary;

  const _SummaryGrid({required this.summary});

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final d = s.disposition;
    final fa = s.fineAmount;
    final items = <_SummaryItem>[
      _SummaryItem('총 건수', '${_comma(s.total)}건', [
        '처리 중 ${_comma(s.processing)}건 · 보완요청 ${_comma(s.supplement)}건',
      ], context.sr.brand),
      _SummaryItem('답변 완료', '${_comma(s.completed)}건', [
        '총 ${_comma(s.total)}건 중 ${_pct(s.completed, s.total)}',
        '수용 ${_comma(s.accept)} · 일부 ${_comma(s.partial)} · 불수용/기타 ${_comma(s.reject)}',
      ], serverCompletedColor),
      _SummaryItem('과태료 건수', d == null ? '미지원' : '${_comma(d.fines)}건', [
        d == null
            ? '서버가 처분 분포를 제공하지 않습니다'
            : '총 ${_comma(s.total)}건 중 ${_pct(d.fines, s.total)}',
      ], serverTrafficFineColor),
      _SummaryItem('경고·범칙금 건수', d == null ? '미지원' : '${_comma(d.warnings)}건', [
        if (d != null) '총 ${_comma(s.total)}건 중 ${_pct(d.warnings, s.total)}',
      ], serverTrafficPenaltyColor),
      _SummaryItem(
        '평균 처리기간',
        s.avgDays == null ? '—' : '${s.avgDays!.toStringAsFixed(1)}일',
        [
          '완료 신고 유효 표본 ${_comma(s.avgDaysCount)}건',
          if (s.reversedDateCount > 0)
            '날짜 역전 ${_comma(s.reversedDateCount)}건 제외',
        ],
        serverPartialAcceptColor,
      ),
      _SummaryItem(
        '확정 과태료',
        fa == null ? '미지원' : '${_comma(fa.confirmedAmount)}원',
        fa == null
            ? ['서버가 금액 요약을 제공하지 않습니다']
            : [
                '금액 확인 ${_comma(fa.confirmedCount)}건 · 미확인 ${_comma(fa.unknownCount)}건',
                '추정(법정 최저) ${_comma(fa.estimatedAmount)}원 · ${_comma(fa.estimatedCount)}건',
              ],
        serverTrafficFineColor,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // 휴대전화 폭은 2열. 태블릿 폭(≥560)만 3열. 작은 화면에 3열 이상을 억지로 넣지 않는다.
        final columns = constraints.maxWidth >= 560 ? 3 : 2;
        const gap = 8.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: _SummaryTile(item: item),
              ),
          ],
        );
      },
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final _SummaryItem item;

  const _SummaryTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sr = context.sr;
    final tone = StatusTone.of(
      item.color,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );
    // 윗변 강조 띠는 안쪽 막대로 그린다(둥근 모서리 + 색이 다른 테두리는 Flutter 가 허용하지 않음).
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sr.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 3, color: tone.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: _tileBody(context, tone, sr),
          ),
        ],
      ),
    );
  }

  Widget _tileBody(BuildContext context, StatusTone tone, SrColors sr) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.label,
          style: TextStyle(
            fontSize: 12,
            color: sr.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        // 금액·건수는 말줄임 없이 줄바꿈한다(큰 글자에서도 값이 숨지 않게).
        Text(
          item.value,
          softWrap: true,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: tone.foreground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        for (final caption in item.captions)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              caption,
              softWrap: true,
              style: TextStyle(fontSize: 11, color: sr.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// 월별 처리 추이 — 답변일 기준 처리 건수(막대)와 그중 과태료(가는 막대). 당월은 집계 중으로 흐리게.
class _MonthlyTrendCard extends StatelessWidget {
  final OverviewSummary summary;
  final String year;
  final DateTime now;

  const _MonthlyTrendCard({
    required this.summary,
    required this.year,
    required this.now,
  });

  static const double _groupWidth = 36;

  static String _ym(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  static String _next(String key) {
    final y = int.parse(key.substring(0, 4));
    final m = int.parse(key.substring(5, 7));
    return m == 12 ? '${y + 1}-01' : '$y-${(m + 1).toString().padLeft(2, '0')}';
  }

  /// 월 축: 연도를 고르면 그해 1월~(12월과 이번 달 중 이른 달), 전체면 첫 답변월~마지막 답변월.
  /// 미래 달을 0건 실적으로 그리지 않는다. PC `trendSvg` 와 같은 규칙.
  List<String> _months(Map<String, int> answered) {
    final data = answered.keys.toList()..sort();
    final nowKey = _ym(now);
    String start;
    String end;
    if (year != 'all') {
      if (data.isEmpty) return const [];
      start = '$year-01';
      end = '$year-12'.compareTo(nowKey) < 0 ? '$year-12' : nowKey;
      if (data.last.compareTo(end) > 0) end = data.last;
      if (end.compareTo(start) < 0) end = start;
    } else {
      if (data.isEmpty) return const [];
      start = data.first;
      end = data.last;
    }
    final keys = <String>[];
    for (var k = start; keys.length < 600; k = _next(k)) {
      keys.add(k);
      if (k == end) break;
    }
    return keys;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sr = context.sr;
    final answered = {
      for (final e in summary.monthlyAnswered) e.month: e.count,
    };
    final fineSeries = summary.monthlyAnsweredFine;
    final fine = {
      for (final e in fineSeries ?? const <MonthlyCount>[]) e.month: e.count,
    };
    final months = _months(answered);
    final nowKey = _ym(now);
    final barColor = theme.colorScheme.primary;
    final fineColor = StatusTone.of(
      serverTrafficFineColor,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    ).foreground;
    final answeredSum = answered.values.fold<int>(0, (a, b) => a + b);
    final unanswered = summary.total - answeredSum;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    '월별 처리 추이',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: sr.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '답변일 기준',
                  style: TextStyle(fontSize: 11, color: sr.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _LegendSwatch(color: barColor, label: '처리(답변) 건수'),
                if (fineSeries != null)
                  _LegendSwatch(color: fineColor, label: '그중 과태료'),
                _LegendSwatch(
                  color: barColor.withValues(alpha: 0.35),
                  label: '이번 달(집계 중)',
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (months.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '선택한 조건에 답변일이 있는 신고가 없습니다.',
                    style: TextStyle(color: sr.textSecondary, fontSize: 12),
                  ),
                ),
              )
            else
              Semantics(
                label:
                    '월별 처리 추이. ${months.map((m) => '$m 처리 ${answered[m] ?? 0}건${fineSeries != null ? ', 과태료 ${fine[m] ?? 0}건' : ''}${m == nowKey ? ', 집계 중' : ''}').join('. ')}',
                excludeSemantics: true,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = math.max(
                      constraints.maxWidth,
                      months.length * _groupWidth,
                    );
                    final chart = SizedBox(
                      width: width,
                      height: 170,
                      child: _buildChart(
                        context,
                        months: months,
                        answered: answered,
                        fine: fineSeries == null ? null : fine,
                        nowKey: nowKey,
                        barColor: barColor,
                        fineColor: fineColor,
                      ),
                    );
                    if (width <= constraints.maxWidth) return chart;
                    // 기간이 길면 가로 스크롤. 가장 최근 달이 먼저 보이도록 오른쪽부터.
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      child: chart,
                    );
                  },
                ),
              ),
            const SizedBox(height: 6),
            Text(
              [
                if (unanswered > 0)
                  '답변일 없는 ${_comma(unanswered)}건(미답변 등)은 추이에 없음',
                if (months.contains(nowKey)) '이번 달은 집계 중',
                '처리율은 계산하지 않음(신고월·답변월 기준이 다름)',
              ].join(' · '),
              style: TextStyle(
                fontSize: 11,
                color: sr.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart(
    BuildContext context, {
    required List<String> months,
    required Map<String, int> answered,
    required Map<String, int>? fine,
    required String nowKey,
    required Color barColor,
    required Color fineColor,
  }) {
    final sr = context.sr;
    final maxValue = [
      ...months.map((m) => answered[m] ?? 0),
      1,
    ].reduce(math.max);
    final yInterval = math.max(1, (maxValue / 4).ceil()).toDouble();
    final chartMaxY = ((maxValue / yInterval).ceil() + 1) * yInterval;
    final spansYears =
        months.first.substring(0, 4) != months.last.substring(0, 4);
    final labelEvery = months.length <= 12 ? 1 : (months.length / 12).ceil();

    String monthLabel(String ym) {
      final mm = int.tryParse(ym.substring(5, 7)) ?? 0;
      return spansYears
          ? '${ym.substring(2, 4)}.${ym.substring(5, 7)}'
          : '$mm월';
    }

    return BarChart(
      BarChartData(
        maxY: chartMaxY,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: sr.border, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              interval: yInterval,
              getTitlesWidget: (value, meta) {
                if (value != value.roundToDouble() ||
                    value > maxValue + yInterval) {
                  return const SizedBox.shrink();
                }
                return Text(
                  value.toInt().toString(),
                  style: TextStyle(fontSize: 10, color: sr.textSecondary),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= months.length || i % labelEvery != 0) {
                  return const SizedBox.shrink();
                }
                final isNow = months[i] == nowKey;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    monthLabel(months[i]),
                    style: TextStyle(
                      fontSize: 10,
                      color: isNow ? barColor : sr.textSecondary,
                      fontWeight: isNow ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) =>
                Theme.of(context).colorScheme.inverseSurface,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final m = months[group.x];
              final isFine = rodIndex == 1;
              return BarTooltipItem(
                '$m${m == nowKey ? '(집계 중)' : ''} ${isFine ? '과태료' : '처리'} ${rod.toY.toInt()}건',
                TextStyle(
                  color: Theme.of(context).colorScheme.onInverseSurface,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < months.length; i++)
            BarChartGroupData(
              x: i,
              barsSpace: 2,
              barRods: [
                BarChartRodData(
                  toY: (answered[months[i]] ?? 0).toDouble(),
                  width: 12,
                  color: months[i] == nowKey
                      ? barColor.withValues(alpha: 0.35)
                      : barColor,
                  borderSide: months[i] == nowKey
                      ? BorderSide(color: barColor, width: 1)
                      : BorderSide.none,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3),
                  ),
                ),
                if (fine != null)
                  BarChartRodData(
                    toY: (fine[months[i]] ?? 0).toDouble(),
                    width: 5,
                    color: fineColor,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(2),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendSwatch({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: context.sr.textSecondary),
        ),
      ],
    );
  }
}

/// 처분 분류 한 줄(라벨·색). PC `DISP` 와 같은 순서·의미색. 표 카드·상세에서도 같은 색을 쓴다.
class StatsDisposition {
  final String key;
  final String label;
  final Color color;

  const StatsDisposition(this.key, this.label, this.color);

  static const all = [
    StatsDisposition('fines', '과태료', serverTrafficFineColor),
    StatsDisposition('warnings', '경고/범칙금', serverTrafficPenaltyColor),
    StatsDisposition('rejects', '불수용/기타', serverRejectColor),
    StatsDisposition('disposition_unknown', '과태료 미확인', serverUnconfirmedColor),
    StatsDisposition('no_penalty', '처분 대상 아님', serverWithdrawColor),
    StatsDisposition('unclassified', '기타·미분류', serverUnconfirmedColor),
  ];
}

class _HBar extends StatelessWidget {
  final String label;
  final int count;
  final int denominator;
  final double fraction;
  final Color color;

  const _HBar({
    required this.label,
    required this.count,
    required this.denominator,
    required this.fraction,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sr = context.sr;
    final fg = StatusTone.of(
      color,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    ).foreground;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 좁은 폭·큰 글자에서는 값이 다음 줄로 내려간다(잘리지 않게).
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 2,
            children: [
              Text(
                label,
                softWrap: true,
                style: TextStyle(
                  fontSize: 12.5,
                  color: count == 0 ? sr.textSecondary : sr.textPrimary,
                ),
              ),
              Text(
                '${_comma(count)}건 · ${_pct(count, denominator)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: count == 0 ? sr.textSecondary : sr.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Stack(
              children: [
                Container(height: 6, color: sr.surfaceAlt),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: Container(height: 6, color: fg),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const _ChartCard({
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: sr.textPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(fontSize: 11, color: sr.textSecondary),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _DispositionCard extends StatelessWidget {
  final OverviewSummary summary;

  const _DispositionCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final d = summary.disposition;
    final sr = context.sr;
    if (d == null) {
      return _ChartCard(
        title: '처분 분포',
        children: [
          Text(
            '서버가 처분 분포를 제공하지 않습니다(구버전).',
            style: TextStyle(fontSize: 12, color: sr.textSecondary),
          ),
        ],
      );
    }
    final counts = {
      'fines': d.fines,
      'warnings': d.warnings,
      'rejects': d.rejects,
      'disposition_unknown': d.dispositionUnknown,
      'no_penalty': d.noPenalty,
      'unclassified': d.unclassified,
    };
    // 처리중(답변 전)은 처분이 없으니 빼고 답변된 신고를 분모로 한다(2026-09-28, PC 와 같음).
    final total = math.max(0, summary.total - d.inProgress);
    return _ChartCard(
      title: '처분 분포',
      subtitle: '답변된 신고 ${_comma(total)}건 기준',
      children: [
        for (final item in StatsDisposition.all)
          _HBar(
            label: item.label,
            count: counts[item.key]!,
            denominator: total,
            fraction: total > 0 ? counts[item.key]! / total : 0,
            color: item.color,
          ),
        const SizedBox(height: 4),
        Text(
          [
            if (d.inProgress > 0) '처리 중(답변 전) ${_comma(d.inProgress)}건은 처분이 없어 뺐습니다.',
            d.overlap > 0
                ? '과태료·경고/범칙금·불수용이 함께 적힌 신고 ${_comma(d.overlap)}건은 두 항목에 모두 세어, 항목 합이 기준 건수보다 많습니다.'
                : '여섯 항목은 서로 겹치지 않으며 합계가 기준 건수와 같습니다.',
          ].join(' '),
          style: TextStyle(fontSize: 11, color: sr.textSecondary, height: 1.4),
        ),
      ],
    );
  }
}

class _ReportTypesCard extends StatefulWidget {
  final OverviewSummary summary;

  const _ReportTypesCard({required this.summary});

  @override
  State<_ReportTypesCard> createState() => _ReportTypesCardState();
}

class _ReportTypesCardState extends State<_ReportTypesCard> {
  static const _topN = 6;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final types = widget.summary.reportTypes;
    final sr = context.sr;
    if (types == null) {
      return _ChartCard(
        title: '위반 유형별 현황',
        children: [
          Text(
            '서버가 위반 유형 집계를 제공하지 않습니다(구버전).',
            style: TextStyle(fontSize: 12, color: sr.textSecondary),
          ),
        ],
      );
    }
    final total = widget.summary.total;
    final max = types.fold<int>(1, (a, t) => math.max(a, t.count));
    final shown = _all ? types : types.take(_topN).toList();
    return _ChartCard(
      title: '위반 유형별 현황',
      subtitle: '신고명 기준 · 유형 ${_comma(types.length)}개',
      children: [
        if (types.isEmpty)
          Text(
            '표시할 신고가 없습니다.',
            style: TextStyle(fontSize: 12, color: sr.textSecondary),
          ),
        for (final t in shown)
          _HBar(
            label: t.name.isEmpty ? '(신고명 없음)' : t.name,
            count: t.count,
            denominator: total,
            fraction: t.count / max,
            color: context.sr.brand,
          ),
        if (types.length > _topN)
          TextButton(
            onPressed: () => setState(() => _all = !_all),
            child: Text(
              _all
                  ? '상위 $_topN개만 보기'
                  : '전체 ${_comma(types.length)}개 유형 보기 (상위 $_topN개 표시 중)',
            ),
          ),
      ],
    );
  }
}

class _Footnotes extends StatelessWidget {
  final OverviewSummary summary;
  final String yearBasis;
  final bool excludeWithdraw;

  const _Footnotes({
    required this.summary,
    required this.yearBasis,
    required this.excludeWithdraw,
  });

  @override
  Widget build(BuildContext context) {
    final notes = <String>[
      if (yearBasis.isNotEmpty) '연도 필터는 $yearBasis 기준입니다.',
      if (excludeWithdraw)
        '취하 데이터 숨기기 설정에 따라 취하 건은 제외했습니다(대시보드 \'전체\'는 취하 포함).',
      '확정 과태료는 답변에 금액이 적힌 건만, 추정은 금액 없는 과태료의 법정 최저 기준이며 둘을 더하지 않습니다.',
      if (summary.undatedReportCount > 0)
        '신고일이 없는 ${summary.undatedReportCount}건이 있습니다.',
    ];
    final sr = context.sr;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '· $note',
              style: TextStyle(
                fontSize: 11,
                color: sr.textSecondary,
                height: 1.4,
              ),
            ),
          ),
      ],
    );
  }
}
