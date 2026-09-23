import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/report.dart';
import '../providers/report_provider.dart';
import '../server_palette.dart';
import '../theme/app_theme.dart';
import '../theme/sr_colors.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/status_badge.dart';

/// 대시보드의 "최근 답변 완료 (3일)" 더보기 화면.
/// 실제 카테고리 목록을 기준으로 최근 답변을 재구성해 모두 보여준다.
class RecentAnswersScreen extends StatefulWidget {
  const RecentAnswersScreen({super.key});

  @override
  State<RecentAnswersScreen> createState() => _RecentAnswersScreenState();
}

class _RecentAnswersScreenState extends State<RecentAnswersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<ReportProvider>().refreshSummaryAndRecentAnswers();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final items = provider.recentAnswerReports;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '최근 답변 완료 (3일)${items.isNotEmpty ? ' (${items.length})' : ''}',
        ),
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_off_outlined,
                    size: 64,
                    color: context.sr.textDisabled,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '3일 내 답변 완료된 신고가 없습니다.',
                    style: TextStyle(
                      color: context.sr.textSecondary,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: provider.refreshSummaryAndRecentAnswers,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 12,
                ),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, i) => _RecentCard(report: items[i]),
              ),
            ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  final Report report;
  const _RecentCard({required this.report});

  Color _statusColor(String s) {
    return serverStatusColor(s);
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(report.status);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showReportDetailSheet(context, report),
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
                      report.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusBadge(label: report.status, color: color),
                ],
              ),
              const SizedBox(height: 8),
              if (report.reportNumber.isNotEmpty)
                _row(context, Icons.tag, '신고번호', report.reportNumber),
              if (report.date.isNotEmpty)
                _row(context, Icons.calendar_today, '신고일', report.date),
              if (report.responseDate.isNotEmpty)
                _row(
                  context,
                  Icons.check_circle_outline,
                  '답변일',
                  report.responseDate,
                ),
              if (report.agency.isNotEmpty)
                _row(context, Icons.business, '처리기관', report.agency),
              if (report.manager.isNotEmpty)
                _row(context, Icons.person_outline, '담당자', report.manager),
              if (report.fineInfo.isNotEmpty)
                _row(
                  context,
                  Icons.monetization_on_outlined,
                  '과태료/범칙금',
                  report.fineInfo,
                ),
              if (report.carNumber.isNotEmpty)
                _row(
                  context,
                  Icons.directions_car_outlined,
                  '차량번호',
                  report.carNumber,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) => Padding(
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
