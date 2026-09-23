import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../models/report.dart';
import '../server_palette.dart';
import '../widgets/report_detail_sheet.dart';
import 'recent_answers_screen.dart';
import 'report_management_screen.dart';
import 'settings_screen.dart';
import 'filtered_list_screen.dart';
import 'sunwi_screen.dart';
import '../theme/sr_colors.dart';
import '../widgets/mode_badge.dart';
import '../widgets/status_badge.dart';

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
      if (!mounted) return;
      unawaited(provider.ensureCategoryReportsLoaded());
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final stats = provider.stats;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Flexible(
              child: Text('대시보드', overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            ModeBadge(
              mode: provider.appMode,
              isDemo: provider.isStandaloneDemo,
            ),
          ],
        ),
        actions: [
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
                        borderRadius: BorderRadius.circular(10),
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSummaryGrid(stats),
          const SizedBox(height: 16),
          if (trafficTotal > 0) ...[
            _buildTrafficCard(stats),
            const SizedBox(height: 16),
          ],
          _buildChartCard(stats),
          const SizedBox(height: 16),
          _buildWatchlistSection(context, stats.watchlist),
          const SizedBox(height: 16),
          _buildRecentSection(context, provider.recentAnswerReports),
          const SizedBox(height: 16),
          const SunwiSection(embedded: true),
        ],
      ),
    );
  }

  // ── 요약 그리드 (6칸) ─────────────────────────────
  Widget _buildSummaryGrid(DashboardStats stats) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      childAspectRatio: 1.65,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      children: [
        _buildStatCard(
          '전체',
          stats.total,
          context.sr.brand,
          Icons.assignment_rounded,
          filter: (r) => true,
        ),
        _buildStatCard(
          '보완 요청',
          stats.supplementCount,
          serverSupplementColor,
          Icons.assignment_late_rounded,
          filter: (r) => r.status == '보완요청',
        ),
        _buildStatCard(
          '처리 중',
          stats.processingCount,
          serverProcessingColor,
          Icons.pending_rounded,
          filter: (r) =>
              r.status == '처리중' ||
              r.status == '진행' ||
              r.status == '진행중' ||
              r.status == '검토중',
        ),
        _buildStatCard(
          '수용',
          stats.acceptCount,
          serverAcceptColor,
          Icons.check_circle_rounded,
          filter: (r) => r.status == '수용',
        ),
        _buildStatCard(
          '일부수용',
          stats.partialCount,
          serverPartialAcceptColor,
          Icons.check_circle_outline_rounded,
          filter: (r) => r.status == '일부수용',
        ),
        _buildStatCard(
          '불수용/기타',
          stats.rejectCount,
          serverRejectColor,
          Icons.cancel_rounded,
          filter: (r) => r.status == '불수용' || r.status == '기타',
        ),
        _buildStatCard(
          '취하',
          stats.withdrawCount,
          serverWithdrawColor,
          Icons.remove_circle_outline_rounded,
          filter: (r) => r.status == '취하',
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String label,
    int value,
    Color color,
    IconData icon, {
    required bool Function(Report) filter,
  }) {
    final tone = _tone(color);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: tone.border),
      ),
      color: tone.background,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: value > 0
            ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FilteredListScreen(
                    title: label,
                    category: 'all',
                    filter: filter,
                  ),
                ),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: tone.foreground,
                      ),
                    ),
                  ),
                  Icon(icon, color: tone.foreground, size: 20),
                ],
              ),
              Row(
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '$value건',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: tone.foreground,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  if (value > 0) ...[
                    const Spacer(),
                    Icon(Icons.chevron_right, size: 18, color: tone.foreground),
                  ],
                ],
              ),
            ],
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
                const Text(
                  '교통위반 처리 현황',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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
                  filter: (r) => r.fineInfo.contains('과태료'),
                ),
                _miniStat(
                  '경고/범칙금',
                  stats.tPenaltyCount,
                  serverTrafficPenaltyColor,
                  filter: (r) =>
                      r.fineInfo.contains('경고') || r.fineInfo.contains('범칙금'),
                ),
                _miniStat(
                  '불수용',
                  stats.tRejectCount,
                  serverRejectColor,
                  filter: (r) => r.status.contains('불수용') || r.status == '기타',
                ),
                _miniStat(
                  '처분 미확인',
                  stats.tUnconfirmedCount,
                  serverUnconfirmedColor,
                  filter: (r) =>
                      r.fineInfo == '미확인' &&
                      !r.status.contains('불수용') &&
                      r.status != '기타',
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
        borderRadius: BorderRadius.circular(8),
        onTap: value > 0
            ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FilteredListScreen(
                    title: '교통위반 — $label',
                    category: 'traffic',
                    filter: filter,
                  ),
                ),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _tone(color).foreground,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: context.sr.textSecondary),
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
                const Text(
                  '처리 현황',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  '총 $total건',
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
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '총',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.sr.textSecondary,
                            ),
                          ),
                          Text(
                            '$total건',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: context.sr.textPrimary,
                            ),
                          ),
                        ],
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
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: e.$2,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    e.$3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                Text(
                                  '${e.$1}건',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 40,
                                  child: Text(
                                    '${(e.$1 / total * 100).toStringAsFixed(1)}%',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: context.sr.textSecondary,
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

  // ── 감시 목록 섹션 ────────────────────────────────
  Widget _buildWatchlistSection(BuildContext context, List<Report> items) {
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
            TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text('관리'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const ReportManagementScreen(initialTabIndex: 1),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: context.sr.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
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
          ...items.take(5).map((r) => _buildWatchItem(r)),
        if (items.length > 5)
          Center(
            child: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const ReportManagementScreen(initialTabIndex: 1),
                ),
              ),
              child: Text('+ ${items.length - 5}건 더 보기'),
            ),
          ),
      ],
    );
  }

  Widget _buildWatchItem(Report r) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showReportDetailSheet(context, r),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.bookmark,
                    color: Theme.of(context).colorScheme.primary,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
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
                _metaRow(Icons.monetization_on_outlined, '과태료/범칙금', r.fineInfo),
              if (r.carNumber.isNotEmpty)
                _metaRow(Icons.directions_car_outlined, '차량번호', r.carNumber),
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
              child: Text('+ ${reports.length - previewLimit}건 더 보기'),
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
          borderRadius: BorderRadius.circular(12),
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
            style: TextStyle(fontSize: 11, color: context.sr.textSecondary),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11),
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
