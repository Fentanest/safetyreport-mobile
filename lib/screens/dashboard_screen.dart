import '../services/performance_trace.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../models/report.dart';
import '../server_palette.dart';
import '../services/report_policy.dart';
import '../widgets/auth_status_notice.dart';
import '../widgets/report_detail_sheet.dart';
import 'recent_answers_screen.dart';
import 'report_management_screen.dart';
import 'settings_screen.dart';
import 'filtered_list_screen.dart';
import '../theme/sr_colors.dart';
import '../widgets/mode_badge.dart';
import '../widgets/status_badge.dart';
import '../widgets/sr_app_bar_actions.dart';
import '../widgets/sr_page_padding.dart';
import '../widgets/sync_status_card.dart';
import '../navigation/main_tabs.dart';
import '../utils/format.dart';
import '../theme/sr_tokens.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<ReportProvider>();
      await provider.fetchSummary();
    });
  }

  @override
  Widget build(BuildContext context) => PerformanceTrace.sync(
    'dashboard.screen_build',
    () => _buildMeasured(context),
  );

  Widget _buildMeasured(BuildContext context) {
    // 이 화면이 그리는 값만 구독한다(SQ-P07). 최근 답변은 요약 또는 분류 미리보기에서 계산한다.
    context.select<ReportProvider, Object>(
      (p) => (
        p.appMode,
        p.isStandaloneDemo,
        p.isLoading,
        p.stats,
        p.errorMessage,
        p.hasLoadedCategoryReports,
        p.trafficReports,
        p.parkingReports,
        p.otherReports,
      ),
    );
    final provider = context.read<ReportProvider>();
    final stats = provider.stats;

    return Scaffold(
      appBar: AppBar(
        // 제목은 제 폭을 먼저 쓰고(최대 60%), 남는 폭이 모자랄 때만 모드 배지를 줄인다(SQ-U04 큰 글꼴).
        title: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * 0.6,
                ),
                child: const Text('대시보드', overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: ModeBadge(
                    mode: provider.appMode,
                    isDemo: provider.isStandaloneDemo,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 탭별 동작은 왼쪽, 설정은 항상 맨 끝(SQ-U16).
        actions: const [SyncActionButton(), SettingsActionButton()],
      ),
      body: RefreshIndicator(
        onRefresh: provider.refreshSummaryAndRecentAnswers,
        child: provider.isLoading && stats == null
            ? const Center(child: CircularProgressIndicator())
            : stats == null
            ? _buildErrorState(context, provider)
            : _buildContent(context, provider, stats),
      ),
    );
  }

  // ── 에러 상태 ──────────────────────────────────────
  Widget _buildErrorState(BuildContext context, ReportProvider provider) {
    final error = provider.errorMessage;
    final isStandalone = provider.appMode == AppMode.standalone;
    final icon = isStandalone ? Icons.storage_rounded : Icons.cloud_off_rounded;
    final title = isStandalone ? '데이터를 불러올 수 없습니다' : '서버에 연결할 수 없습니다';
    final subtitle = isStandalone
        ? '아래로 당겨 다시 시도하거나 동기화를 실행하세요.'
        : '아래로 당겨 다시 시도하세요.';
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 72, color: context.sr.textDisabled),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: context.sr.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _tone(serverRejectColor).background,
                        borderRadius: BorderRadius.circular(SrRadius.lg),
                        border: Border.all(
                          color: _tone(serverRejectColor).border,
                        ),
                      ),
                      child: SelectableText(
                        error,
                        style: TextStyle(
                          fontSize: 12,
                          color: _tone(serverRejectColor).foreground,
                          height: 1.6,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('다시 시도'),
                    onPressed: provider.fetchSummary,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('설정 확인'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 메인 콘텐츠 ────────────────────────────────────
  Widget _buildContent(
    BuildContext context,
    ReportProvider provider,
    DashboardStats stats,
  ) {
    final trafficTotal =
        stats.tFineCount +
        stats.tPenaltyCount +
        stats.tRejectCount +
        stats.tUnconfirmedCount;
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      // 가로 모드 좌우 컷아웃·내비 여백(SQ-U26).
      padding: srPagePadding(context, const EdgeInsets.all(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ReloginRequiredBanner(),
          _buildSummaryGrid(stats),
          const SizedBox(height: 12),
          const SyncStatusCard(),
          const SizedBox(height: 16),
          if (trafficTotal > 0) ...[
            _buildTrafficCard(stats),
            const SizedBox(height: 16),
          ],
          _buildChartCard(stats),
          const SizedBox(height: 16),
          _buildWatchlistSection(
            context,
            stats.watchlist,
            stats.watchlistTotal,
          ),
          const SizedBox(height: 16),
          _buildRecentSection(context, provider.recentAnswerReports),
          // 전국 신고현황(Sunwi)은 2026-09-28 통계 탭 아래로 옮겼다.
        ],
      ),
    );
  }

  // ── 처리 상태 요약 ─────────────────────────────────
  // 전체 건수를 머리 한 줄에 두고 상태 6종을 칸으로 둔다(SQ-U15). 칸 높이는 내용 높이를 따른다
  // (고정 가로세로 비율 없음 — 큰 글꼴에서 넘치지 않게, SQ-U04). 휴대전화 폭은 3열×2줄,
  // 글꼴 1.5배 이상이거나 칸이 너무 좁으면 2열×3줄. 6은 2·3 모두로 나눠져 혼자 남는 칸이 없다.
  Widget _buildSummaryGrid(DashboardStats stats) {
    final statuses = <_StatusTileData>[
      _StatusTileData(
        '보완 요청',
        stats.supplementCount,
        serverSupplementColor,
        Icons.assignment_late_rounded,
        (r) => ReportPolicy.norm(r.status) == ReportPolicy.supplementStatus,
      ),
      _StatusTileData(
        '처리 중',
        stats.processingCount,
        serverProcessingColor,
        Icons.pending_rounded,
        (r) => ReportPolicy.isProcessing(r.status),
      ),
      _StatusTileData(
        '수용',
        stats.acceptCount,
        serverAcceptColor,
        Icons.check_circle_rounded,
        (r) => ReportPolicy.norm(r.status) == '수용',
      ),
      _StatusTileData(
        '일부수용',
        stats.partialCount,
        serverPartialAcceptColor,
        Icons.check_circle_outline_rounded,
        (r) => ReportPolicy.norm(r.status) == '일부수용',
      ),
      _StatusTileData(
        '불수용/기타',
        stats.rejectCount,
        serverRejectColor,
        Icons.cancel_rounded,
        (r) => ReportPolicy.isReject(r.status),
      ),
      _StatusTileData(
        '취하',
        stats.withdrawCount,
        serverWithdrawColor,
        Icons.remove_circle_outline_rounded,
        (r) => ReportPolicy.isWithdrawn(r.status),
      ),
    ];
    const gap = 8.0;
    return Column(
      key: const ValueKey('dashboard-status-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTotalTile(
          stats.total,
          // 취하를 숨기는 설정이어도 '전체'에는 취하가 들어 있다 — 서버 대시보드와 같이 밝힌다(기술일지 O-01)
          withdrawIncluded: stats.withdrawGraphCount == 0
              ? stats.withdrawRawCount
              : 0,
        ),
        const SizedBox(height: gap),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final threeWide = (constraints.maxWidth - gap * 2) / 3;
            final columns = scale >= 1.5 || threeWide < 96 ? 2 : 3;
            final rows = <Widget>[];
            for (var i = 0; i < statuses.length; i += columns) {
              final cells = <Widget>[];
              for (var c = 0; c < columns; c++) {
                if (c > 0) cells.add(const SizedBox(width: gap));
                final index = i + c;
                cells.add(
                  Expanded(
                    child: index < statuses.length
                        ? _buildStatusTile(statuses[index])
                        : const SizedBox.shrink(),
                  ),
                );
              }
              if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
              // 같은 줄 칸은 가장 긴 칸의 높이에 맞춘다(라벨이 두 줄로 꺾여도 숫자 줄이 나란하다).
              rows.add(
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: cells,
                  ),
                ),
              );
            }
            return Column(children: rows);
          },
        ),
      ],
    );
  }

  void _openFiltered(String label, bool Function(Report) filter) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FilteredListScreen(
          title: label,
          category: 'all',
          metric: label,
          filter: filter,
        ),
      ),
    );
  }

  /// 전체 건수 머리 줄. 누르면 전체 목록(FilteredListScreen)으로 간다 — 이전 '전체' 카드와 같은 동작.
  Widget _buildTotalTile(int total, {int withdrawIncluded = 0}) {
    const label = '전체';
    final tone = _tone(context.sr.brand);
    final enabled = total > 0;
    final note = withdrawIncluded > 0
        ? '취하 ${formatCount(withdrawIncluded)} 포함'
        : null;
    // excludeSemantics 가 InkWell 의 탭 동작까지 숨기므로 Semantics 에 직접 onTap 을 준다(TalkBack 활성화).
    return Semantics(
      button: enabled,
      label: '$label ${formatCount(total)}${note == null ? '' : ', $note'}',
      onTap: enabled ? () => _openFiltered(label, (r) => true) : null,
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('dashboard-status-$label'),
        color: tone.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SrRadius.lg),
          side: BorderSide(color: tone.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => _openFiltered(label, (r) => true) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.assignment_rounded,
                    color: tone.foreground,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: tone.foreground,
                        ),
                      ),
                      if (note != null)
                        Text(
                          note,
                          style: TextStyle(
                            fontSize: SrFontSize.caption,
                            color: context.sr.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          formatCount(total),
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: tone.foreground,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _chevronSlot(tone.foreground, visible: enabled),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 화살표 자리는 0건 칸에도 같은 크기로 남긴다(보이지만 않게) — 칸마다 숫자·화살표 위치가 같다.
  Widget _chevronSlot(Color color, {required bool visible}) => Opacity(
    opacity: visible ? 1 : 0,
    child: Icon(Icons.chevron_right, size: 18, color: color),
  );

  Widget _buildStatusTile(_StatusTileData d) {
    final tone = _tone(d.color);
    final enabled = d.value > 0;
    final sr = context.sr;
    // 0건 칸: 배치는 같고, 바탕은 중립 면·글자는 흐리게, 누를 수 없음.
    final fg = enabled ? tone.foreground : sr.textSecondary;
    return Semantics(
      button: enabled,
      enabled: enabled,
      label: '${d.label} ${formatCount(d.value)}',
      onTap: enabled ? () => _openFiltered(d.label, d.filter) : null,
      excludeSemantics: true,
      child: Material(
        key: ValueKey('dashboard-status-${d.label}'),
        color: enabled ? tone.background : sr.surfaceAlt,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SrRadius.lg),
          side: BorderSide(color: enabled ? tone.border : sr.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => _openFiltered(d.label, d.filter) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      // 아이콘은 0건이어도 상태 기준색을 유지해 어떤 상태인지 색으로도 알 수 있다.
                      child: Icon(d.icon, color: tone.foreground, size: 15),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        d.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          formatCount(d.value),
                          // 한 줄 고정: IntrinsicHeight 가 줄바꿈된 높이를 재지 않게 한다.
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: fg,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    _chevronSlot(fg, visible: enabled),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  StatusTone _tone(Color base) {
    final theme = Theme.of(context);
    return StatusTone.of(
      base,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );
  }

  // ── 교통위반 카드 ──────────────────────────────────
  Widget _buildTrafficCard(DashboardStats stats) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.directions_car,
                  size: 18,
                  color: context.sr.textSecondary,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '교통위반 처리 현황',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _miniStat(
                  '과태료',
                  stats.tFineCount,
                  serverTrafficFineColor,
                  filter: (r) => ReportPolicy.hasFine(r.fineInfo),
                ),
                _miniStat(
                  '경고/범칙금',
                  stats.tPenaltyCount,
                  serverTrafficPenaltyColor,
                  filter: (r) => ReportPolicy.hasWarning(r.fineInfo),
                ),
                _miniStat(
                  '불수용',
                  stats.tRejectCount,
                  serverRejectColor,
                  filter: (r) => ReportPolicy.isReject(r.status),
                ),
                _miniStat(
                  '과태료 미확인',
                  stats.tUnconfirmedCount,
                  serverUnconfirmedColor,
                  filter: (r) => ReportPolicy.listFineFilter(
                    ReportPolicy.fineUnknownText,
                    r.fineInfo,
                    r.status,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(
    String label,
    int value,
    Color color, {
    required bool Function(Report) filter,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(SrRadius.md),
        onTap: value > 0
            ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FilteredListScreen(
                    title: '교통위반 — $label',
                    category: 'traffic',
                    metric: 'traffic:$label',
                    filter: filter,
                  ),
                ),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              // 큰 글꼴에서 "4,3/21"처럼 숫자가 꺾이지 않게 한 줄로 두고 칸에 맞춰 줄인다.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  formatNumber(value),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: _tone(color).foreground,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: SrFontSize.caption,
                  color: context.sr.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 파이 차트 ──────────────────────────────────────
  Widget _buildChartCard(DashboardStats stats) {
    final sections = [
      (stats.acceptCount, serverAcceptColor, '수용'),
      (stats.partialCount, serverPartialAcceptColor, '일부수용'),
      (stats.rejectCount, serverRejectColor, '불수용'),
      (stats.supplementCount, serverSupplementColor, '보완요청'),
      (stats.processingCount, serverProcessingColor, '처리중'),
      (stats.withdrawGraphCount, serverWithdrawColor, '취하'),
    ].where((e) => e.$1 > 0).toList();
    final total = sections.fold<int>(0, (sum, item) => sum + item.$1);
    if (total == 0) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  Icons.pie_chart,
                  size: 18,
                  color: context.sr.textSecondary,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '처리 현황',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '총 ${formatCount(total)}',
                  style: TextStyle(
                    color: context.sr.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                SizedBox(
                  height: 150,
                  width: 150,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          // 조각 안 흰 글자는 노랑·하늘색 위 대비가 부족해 범례에 비율을 둔다.
                          sections: sections
                              .map(
                                (e) => PieChartSectionData(
                                  value: e.$1.toDouble(),
                                  color: e.$2,
                                  showTitle: false,
                                  radius: 22,
                                ),
                              )
                              .toList(),
                          centerSpaceRadius: 50,
                          sectionsSpace: 2,
                        ),
                      ),
                      // 도넛 구멍(지름 100) 안에 머물도록 큰 글꼴에서는 줄인다.
                      SizedBox(
                        width: 88,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '총',
                                style: TextStyle(
                                  fontSize: SrFontSize.caption,
                                  color: context.sr.textSecondary,
                                ),
                              ),
                              Text(
                                formatCount(total),
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: context.sr.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: sections
                        .map(
                          (e) => Padding(
                            key: ValueKey('dashboard-legend-${e.$3}'),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            // 이름과 건수·비율은 항상 한 줄. 폭이 모자라면 건수·비율 글자만 줄인다
                            // (예전엔 다음 줄로 내려가 '일부수용' 줄만 두 줄이 됐다).
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: e.$2,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  e.$3,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text: formatCount(e.$1),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            TextSpan(
                                              text:
                                                  ' ${(e.$1 / total * 100).toStringAsFixed(1)}%',
                                              style: TextStyle(
                                                fontSize: SrFontSize.caption,
                                                color: context.sr.textSecondary,
                                              ),
                                            ),
                                          ],
                                        ),
                                        maxLines: 1,
                                        softWrap: false,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 감시 목록 관리: 메인 화면 안이면 하단 탭 2 + 하위 탭 "감시 목록"으로 바꾼다.
  /// 메인 화면 밖(단독으로 띄운 대시보드)에서만 신고관리 화면을 연다.
  void _openWatchlistManagement(BuildContext context) {
    final tabs = MainTabScope.maybeOf(context);
    if (tabs != null) {
      tabs.goTo(MainTabs.management, subTab: MainTabs.managementWatchlist);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ReportManagementScreen(
          initialTabIndex: MainTabs.managementWatchlist,
        ),
      ),
    );
  }

  // ── 감시 목록 섹션 ────────────────────────────────
  Widget _buildWatchlistSection(
    BuildContext context,
    List<Report> items,
    int? total,
  ) {
    // 대시보드에는 3건까지 한 줄 요약만 둔다(SQ-U15). 전체는 신고관리 > 감시 목록.
    const previewLimit = 3;
    final shown = items.length < previewLimit ? items.length : previewLimit;
    final allCount = (total ?? 0) > items.length ? total! : items.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.bookmark,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                '감시 목록',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            // 하단 탭 신고관리(2)의 "감시 목록"으로 전환한다 — 화면을 새로 쌓지 않는다(SQ-U06).
            TextButton.icon(
              icon: const Icon(Icons.chevron_right, size: 18),
              iconAlignment: IconAlignment.end,
              label: const Text('관리'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 48),
              ),
              onPressed: () => _openWatchlistManagement(context),
            ),
          ],
        ),
        if (allCount > shown)
          Text(
            '전체 ${formatCount(allCount)} · 최근 ${formatCount(shown)} 표시 (관리에서 전체 조회)',
            style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
          ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: context.sr.surfaceAlt,
              borderRadius: BorderRadius.circular(SrRadius.lg),
              border: Border.all(color: context.sr.border),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.bookmark_border,
                  size: 32,
                  color: context.sr.textDisabled,
                ),
                const SizedBox(height: 6),
                Text(
                  '감시 중인 신고가 없습니다.',
                  style: TextStyle(
                    color: context.sr.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          )
        else
          _buildWatchList(items.take(previewLimit).toList()),
        if (allCount > shown)
          Center(
            child: TextButton(
              onPressed: () => _openWatchlistManagement(context),
              child: Text('+ ${formatCount(allCount - shown)} 더 보기'),
            ),
          ),
      ],
    );
  }

  /// 감시 목록 미리보기 — 한 카드 안에 한 줄 행(신고명 · 상태 · 신고일). 누르면 상세 시트.
  Widget _buildWatchList(List<Report> reports) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < reports.length; i++) ...[
            if (i > 0) Divider(height: 1, color: context.sr.border),
            _buildWatchRow(reports[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildWatchRow(Report r) {
    final title = r.name.isNotEmpty
        ? r.name
        : (r.reportNumber.isNotEmpty ? r.reportNumber : '제목 없음');
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
    );
    final dateText = r.date.isEmpty
        ? null
        : Text(
            r.date,
            maxLines: 1,
            style: TextStyle(
              fontSize: SrFontSize.caption,
              color: context.sr.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    final badge = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 96),
      child: StatusBadge.status(r.status),
    );
    // 기본은 한 줄(신고명 · 상태 · 신고일). 글꼴 1.5배 이상에서는 신고일을 신고명 아래로 내려 넘치지 않게 한다.
    final large = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    return InkWell(
      key: ValueKey('dashboard-watch-row:${r.id}'),
      onTap: () => showReportDetailSheet(context, r),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: large
              ? Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [titleText, ?dateText],
                      ),
                    ),
                    const SizedBox(width: 8),
                    badge,
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: titleText),
                    const SizedBox(width: 8),
                    badge,
                    if (dateText != null) ...[
                      const SizedBox(width: 8),
                      dateText,
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  // ── 최근 답변 완료 섹션 ─────────────────────────────
  Widget _buildRecentSection(BuildContext context, List<Report> reports) {
    const previewLimit = 5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.notifications_active,
              size: 18,
              color: _tone(serverAcceptColor).foreground,
            ),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                '최근 답변 완료 (3일)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            if (reports.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('모두 보기'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RecentAnswersScreen(),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (reports.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                '3일 내 답변 완료된 신고가 없습니다.',
                style: TextStyle(color: context.sr.textSecondary),
              ),
            ),
          )
        else
          ...reports.take(previewLimit).map(_buildRecentCard),
        if (reports.length > previewLimit)
          Center(
            child: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RecentAnswersScreen()),
              ),
              child: Text(
                '+ ${formatCount(reports.length - previewLimit)} 더 보기',
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRecentCard(Report r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(SrRadius.lg),
          onTap: () => showReportDetailSheet(context, r),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        r.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(r.status),
                  ],
                ),
                const SizedBox(height: 8),
                if (r.reportNumber.isNotEmpty)
                  _metaRow(Icons.tag, '신고번호', r.reportNumber),
                if (r.date.isNotEmpty)
                  _metaRow(Icons.calendar_today, '신고일', r.date),
                if (r.responseDate.isNotEmpty)
                  _metaRow(Icons.check_circle_outline, '답변일', r.responseDate),
                if (r.agency.isNotEmpty)
                  _metaRow(Icons.business, '처리기관', r.agency),
                if (r.manager.isNotEmpty)
                  _metaRow(Icons.person_outline, '담당자', r.manager),
                if (r.fineInfo.isNotEmpty)
                  _metaRow(
                    Icons.monetization_on_outlined,
                    '과태료/범칙금',
                    r.fineInfo,
                  ),
                if (r.carNumber.isNotEmpty)
                  _metaRow(Icons.directions_car_outlined, '차량번호', r.carNumber),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metaRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 12, color: context.sr.textSecondary),
          const SizedBox(width: 4),
          Text(
            '$label ',
            style: TextStyle(
              fontSize: SrFontSize.caption,
              color: context.sr.textSecondary,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: SrFontSize.caption),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String status) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 110),
      child: StatusBadge.status(status),
    );
  }
}

/// 대시보드 상태 칸 하나(라벨·건수·기준색·아이콘·드릴다운 필터).
class _StatusTileData {
  final String label;
  final int value;
  final Color color;
  final IconData icon;
  final bool Function(Report) filter;

  const _StatusTileData(
    this.label,
    this.value,
    this.color,
    this.icon,
    this.filter,
  );
}
