import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/stats_overview.dart';
import '../server_palette.dart';
import '../theme/sr_colors.dart';

/// 통계 화면 상단 요약(카드 + 월별 추이). 모든 수치는 [summary] 런타임 집계에서 온다.
/// 정의: `docs/design/statistics-spec.md` §4 (월별 신고 = 신고일 기준, 월별 답변 = 답변일 기준).
class StatsOverviewSection extends StatelessWidget {
  final OverviewSummary? summary;
  final String categoryLabel;

  /// 연도 필터가 어느 날짜 컬럼 기준인지 ('신고일' / '답변일').
  final String yearBasis;

  /// 요약을 표시할 수 없을 때 안내 문구(구서버 미지원 등). null 이면 정상.
  final String? notice;

  const StatsOverviewSection({
    super.key,
    required this.summary,
    required this.categoryLabel,
    required this.yearBasis,
    this.notice,
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
          Text(
            '$categoryLabel 요약',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: sr.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          _SummaryGrid(summary: s),
          const SizedBox(height: 12),
          _MonthlyChartCard(summary: s),
          const SizedBox(height: 6),
          _Footnotes(summary: s, yearBasis: yearBasis),
        ],
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  final OverviewSummary summary;

  const _SummaryGrid({required this.summary});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avg = summary.avgDays;
    final items = <_SummaryItem>[
      _SummaryItem('총 신고', '${summary.total}건', null, scheme.primary),
      _SummaryItem(
        '답변 완료',
        '${summary.completed}건',
        null,
        serverCompletedColor,
      ),
      _SummaryItem(
        '처리 중',
        '${summary.processing}건',
        summary.supplement > 0 ? '보완요청 ${summary.supplement}건 별도' : null,
        serverProcessingColor,
      ),
      _SummaryItem(
        '평균 처리기간',
        avg == null ? '—' : '${avg.toStringAsFixed(1)}일',
        '표본 ${summary.avgDaysCount}건',
        serverAcceptColor,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
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

class _SummaryItem {
  final String label;
  final String value;
  final String? caption;
  final Color color;

  const _SummaryItem(this.label, this.value, this.caption, this.color);
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
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sr.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: sr.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              item.value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: tone.foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (item.caption != null) ...[
            const SizedBox(height: 2),
            Text(
              item.caption!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: sr.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _MonthlyChartCard extends StatelessWidget {
  final OverviewSummary summary;

  const _MonthlyChartCard({required this.summary});

  static const double _pointWidth = 34;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sr = context.sr;
    final reportedColor = theme.colorScheme.primary;
    final answeredColor = StatusTone.of(
      serverCompletedColor,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    ).foreground;

    final months = <String>{
      ...summary.monthlyReported.map((e) => e.month),
      ...summary.monthlyAnswered.map((e) => e.month),
    }.toList()..sort();
    final reported = {
      for (final e in summary.monthlyReported) e.month: e.count,
    };
    final answered = {
      for (final e in summary.monthlyAnswered) e.month: e.count,
    };
    final spansYears =
        months.isNotEmpty &&
        months.first.substring(0, 4) != months.last.substring(0, 4);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '월별 추이',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: sr.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _LegendItem(
                  color: reportedColor,
                  label: '신고 (신고일 기준)',
                  dashed: false,
                ),
                _LegendItem(
                  color: answeredColor,
                  label: '답변 (답변일 기준)',
                  dashed: true,
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (months.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '표시할 월별 데이터가 없습니다.',
                    style: TextStyle(color: sr.textSecondary, fontSize: 12),
                  ),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = math.max(
                    constraints.maxWidth,
                    months.length * _pointWidth,
                  );
                  final chart = SizedBox(
                    width: width,
                    height: 180,
                    child: _buildChart(
                      context,
                      months: months,
                      reported: reported,
                      answered: answered,
                      reportedColor: reportedColor,
                      answeredColor: answeredColor,
                      spansYears: spansYears,
                    ),
                  );
                  if (width <= constraints.maxWidth) return chart;
                  // 기간이 길면 가로 스크롤. 가장 최근 달이 먼저 보이도록 오른쪽부터 시작한다.
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: chart,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart(
    BuildContext context, {
    required List<String> months,
    required Map<String, int> reported,
    required Map<String, int> answered,
    required Color reportedColor,
    required Color answeredColor,
    required bool spansYears,
  }) {
    final sr = context.sr;
    final maxValue = [
      ...reported.values,
      ...answered.values,
      1,
    ].reduce(math.max);
    // 건수는 정수라 눈금도 정수 간격으로 둔다(작은 값에서 같은 숫자 라벨이 반복되지 않게).
    final yInterval = math.max(1, (maxValue / 4).ceil()).toDouble();
    final chartMaxY = ((maxValue / yInterval).ceil() + 1) * yInterval;
    final labelEvery = months.length <= 12 ? 1 : (months.length / 12).ceil();

    List<FlSpot> spotsFor(Map<String, int> source) => [
      for (var i = 0; i < months.length; i++)
        FlSpot(i.toDouble(), (source[months[i]] ?? 0).toDouble()),
    ];

    String monthLabel(String ym) {
      final mm = int.tryParse(ym.substring(5, 7)) ?? 0;
      return spansYears
          ? '${ym.substring(2, 4)}.${ym.substring(5, 7)}'
          : '$mm월';
    }

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: math.max(0, months.length - 1).toDouble(),
        minY: 0,
        maxY: chartMaxY,
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
              reservedSize: 34,
              interval: yInterval,
              getTitlesWidget: (value, meta) {
                if (value != value.roundToDouble()) {
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
              interval: 1,
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 ||
                    i >= months.length ||
                    value != i.toDouble() ||
                    i % labelEvery != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    monthLabel(months[i]),
                    style: TextStyle(fontSize: 10, color: sr.textSecondary),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) =>
                Theme.of(context).colorScheme.inverseSurface,
            getTooltipItems: (spots) => spots.map((spot) {
              final month = months[spot.x.round()];
              final isReported = spot.barIndex == 0;
              return LineTooltipItem(
                '$month ${isReported ? '신고' : '답변'} ${spot.y.toInt()}건',
                TextStyle(
                  color: Theme.of(context).colorScheme.onInverseSurface,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spotsFor(reported),
            color: reportedColor,
            barWidth: 2.5,
            isCurved: false,
            dotData: FlDotData(show: months.length <= 18),
            belowBarData: BarAreaData(
              show: true,
              color: reportedColor.withValues(alpha: 0.10),
            ),
          ),
          LineChartBarData(
            spots: spotsFor(answered),
            color: answeredColor,
            barWidth: 2.5,
            isCurved: false,
            dashArray: const [6, 4],
            dotData: FlDotData(show: months.length <= 18),
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final bool dashed;

  const _LegendItem({
    required this.color,
    required this.label,
    required this.dashed,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 8,
          child: CustomPaint(
            painter: _LegendLinePainter(color: color, dashed: dashed),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: context.sr.textSecondary),
        ),
      ],
    );
  }
}

class _LegendLinePainter extends CustomPainter {
  final Color color;
  final bool dashed;

  _LegendLinePainter({required this.color, required this.dashed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + 4, size.width), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LegendLinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dashed != dashed;
}

class _Footnotes extends StatelessWidget {
  final OverviewSummary summary;
  final String yearBasis;

  const _Footnotes({required this.summary, required this.yearBasis});

  @override
  Widget build(BuildContext context) {
    final notes = <String>[
      if (yearBasis.isNotEmpty) '연도 필터는 $yearBasis 기준입니다.',
      '평균 처리기간은 신고일·답변일이 모두 있는 신고만으로 계산합니다(표본 ${summary.avgDaysCount}건).',
      if (summary.reversedDateCount > 0)
        '답변일이 신고일보다 앞선 ${summary.reversedDateCount}건은 평균에서 제외했습니다.',
      if (summary.undatedReportCount > 0)
        '신고일이 없는 ${summary.undatedReportCount}건은 월별 신고 추이에서 빠졌습니다.',
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
