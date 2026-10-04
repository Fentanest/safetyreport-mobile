import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../models/duplicate_group.dart';
import '../models/notification_item.dart';
import '../models/rating_batch_result.dart';
import '../models/report.dart';
import '../providers/notification_history_provider.dart';
import '../providers/report_provider.dart';
import '../server_palette.dart';
import '../services/api_service.dart';
import '../widgets/duplicate_group_detail_sheet.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/sr_tab_bar.dart';
import '../theme/sr_colors.dart';

const _permChannel = MethodChannel('com.fentanest.mysafetyreport/permissions');

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: context
          .read<NotificationHistoryProvider>()
          .preferredTabIndex,
    );
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      context.read<NotificationHistoryProvider>().setPreferredTabIndex(
        _tabController.index,
        notify: false,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationHistoryProvider>().load();
      _fetchServerResults();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<NotificationHistoryProvider>().load();
      _fetchServerResults();
    }
  }

  ApiService? _getApi() {
    final p = context.read<ReportProvider>();
    if (p.baseUrl.isEmpty) return null;
    return ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
  }

  bool get _isStandalone =>
      context.read<ReportProvider>().appMode == AppMode.standalone;

  /// Client 모드 서버 결과 확인. 결과를 먼저 기록에 영속 저장한 뒤에 완료 신호를 소비한다(SQ-B04) —
  /// 일은 provider 가 끝까지 하므로 화면이 닫혀도 결과가 남는다. 반환: 실패 없이 끝났는지(실패는 provider 가 로그를 남김).
  Future<bool> _fetchServerResults() async {
    if (_isStandalone) return true;
    final api = _getApi();
    if (api == null) return true;
    final poll = await context
        .read<NotificationHistoryProvider>()
        .pollServerCrawlResults(
          fetchResults: api.fetchCrawlResults,
          consumeDone: api.getCrawlDone,
        );
    final changedCount = poll.doneChangedCount;
    if (changedCount != null) unawaited(_showPushNotif(changedCount));
    return poll.ok;
  }

  Future<void> _showPushNotif(int changedCount) async {
    try {
      final body = changedCount > 0
          ? '크롤링이 완료되었습니다. $changedCount건의 변경사항이 있습니다.'
          : '크롤링이 완료되었습니다. 변경사항이 없습니다.';
      await _permChannel.invokeMethod('showNotification', {
        'title': '✅ 크롤링 완료',
        'body': body,
        'nav_tab': 4,
        'nav_subtab': 1,
        'event_type': 'crawl_result',
      });
    } catch (_) {}
  }

  Future<bool> _confirmClear(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('알림 기록 삭제'),
            content: const Text('모든 알림 기록을 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showDetail(BuildContext context, NotificationItem item) {
    context.read<NotificationHistoryProvider>().markRead(item.id);

    if (item.kind == NotificationItemKind.rating) {
      final extra = item.extraData;
      if (extra != null) {
        _showRatingDetail(context, RatingBatchResult.fromJson(extra));
      }
      return;
    }

    if (item.kind == NotificationItemKind.report &&
        item.extraData != null &&
        item.extraData!.isNotEmpty) {
      final report = Report.fromJson(item.extraData!);
      showReportDetailSheet(context, report);
      return;
    }

    if (item.kind == NotificationItemKind.duplicate &&
        item.extraData != null &&
        item.extraData!.isNotEmpty) {
      showDuplicateGroupDetailSheet(
        context,
        DuplicateGroup.fromJson(item.extraData!),
      );
      return;
    }

    final hasChanges = item.body.contains('변경사항이 있습니다');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: hasChanges ? 0.5 : 0.4,
        minChildSize: 0.3,
        maxChildSize: 0.7,
        expand: false,
        builder: (_, controller) => ListView(
          controller: controller,
          // 손잡이는 테마(showDragHandle)가 그린다(SQ-U07).
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_active,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.title,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Text(item.body, style: TextStyle(fontSize: 14, height: 1.6)),
            const SizedBox(height: 20),
            if (item.reportNumber.isNotEmpty)
              _detailRow('신고번호', item.reportNumber),
            _detailRow('수신 시각', item.timestamp),
            if (hasChanges) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: Icon(Icons.assignment_outlined),
                label: const Text('신고 결과 보기'),
                onPressed: () {
                  Navigator.pop(sheetCtx);
                  context
                      .read<NotificationHistoryProvider>()
                      .setPreferredTabIndex(1);
                  _tabController.animateTo(1);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showRatingDetail(BuildContext context, RatingBatchResult result) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 전체 높이까지 끌어올려도 상태 표시줄 아래에서 멈춘다(SQ-U07).
      useSafeArea: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => ListView(
          controller: controller,
          // 손잡이는 테마(showDragHandle)가 그린다(SQ-U07).
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            Row(
              children: [
                Icon(
                  Icons.star_rate_rounded,
                  color: StatusTone.of(
                    Colors.amber,
                    brightness: Theme.of(context).brightness,
                    surface: context.sr.surface,
                  ).foreground,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.title,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _countChip(
                  '성공 ${result.successCount}',
                  StatusTone.of(
                    Colors.green,
                    brightness: Theme.of(context).brightness,
                    surface: context.sr.surface,
                  ).foreground,
                  Icons.check_circle_outline,
                ),
                _countChip(
                  '스킵 ${result.skipCount}',
                  StatusTone.of(
                    Colors.orange,
                    brightness: Theme.of(context).brightness,
                    surface: context.sr.surface,
                  ).foreground,
                  Icons.fast_forward_outlined,
                ),
                _countChip(
                  '실패 ${result.failureCount}',
                  Theme.of(context).colorScheme.error,
                  Icons.error_outline,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _detailRow('목표 별점', '${result.score}점'),
            _detailRow('선택 건수', '${result.requestedCount}건'),
            _detailRow('실행 건수', '${result.eligibleCount}건'),
            _detailRow(
              '실행 모드',
              result.mode == 'standalone' ? 'Standalone' : 'Server 요청',
            ),
            _detailRow('완료 시각', result.timestamp),
            if (result.failedReportNumbers.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '실패 신고번호',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                result.failedReportNumbers.join(', '),
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.error,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              '상세 내역',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ...result.items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _RatingReportCard(
                  item: item,
                  onTap: item.hasReportData
                      ? () {
                          Navigator.pop(sheetCtx);
                          showReportDetailSheet(
                            context,
                            Report.fromJson(item.reportData!),
                          );
                        }
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(color: context.sr.textSecondary, fontSize: 13),
          ),
        ),
        Expanded(child: Text(value, style: TextStyle(fontSize: 13))),
      ],
    ),
  );

  Widget _countChip(String label, Color color, IconData icon) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NotificationHistoryProvider>();
    final allItems = provider.items;
    final isStandalone = context.select<ReportProvider, bool>(
      (p) => p.appMode == AppMode.standalone,
    );

    if (provider.preferredTabIndex != _tabController.index &&
        !_tabController.indexIsChanging) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabController.index != provider.preferredTabIndex) {
          _tabController.animateTo(provider.preferredTabIndex);
        }
      });
    }

    final crawlItems = allItems
        .where((item) => item.kind == NotificationItemKind.crawl)
        .toList(growable: false);
    final reportItems = allItems
        .where(
          (item) =>
              item.kind == NotificationItemKind.report ||
              item.kind == NotificationItemKind.duplicate,
        )
        .toList(growable: false);
    final ratingItems = allItems
        .where((item) => item.kind == NotificationItemKind.rating)
        .toList(growable: false);

    final crawlUnread = crawlItems.where((item) => !item.isRead).length;
    final reportUnread = reportItems.where((item) => !item.isRead).length;
    final ratingUnread = ratingItems.where((item) => !item.isRead).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('알림 기록'),
        actions: [
          if (allItems.isNotEmpty && provider.unreadCount > 0)
            TextButton.icon(
              icon: Icon(Icons.done_all, size: 18),
              label: const Text('모두 읽음'),
              onPressed: provider.markAllRead,
            ),
          if (allItems.isNotEmpty)
            IconButton(
              icon: Icon(Icons.delete_sweep_outlined),
              tooltip: '모두 비우기',
              onPressed: () async {
                if (await _confirmClear(context) && context.mounted) {
                  context.read<NotificationHistoryProvider>().clearAll();
                }
              },
            ),
        ],
        bottom: SrTabBar(
          controller: _tabController,
          textScaler: MediaQuery.textScalerOf(context),
          labels: const ['크롤링 현황', '신고 결과', '별점 주기'],
          badgeCounts: [crawlUnread, reportUnread, ratingUnread],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // 하위 탭 이름 "크롤링 현황"은 불변 항목이라 그대로 두고, 빈 상태 문구만 모드에 맞춘다(SQ-U08).
          // Standalone 동기화는 이 탭에 시작/완료 기록을 남기지 않고, 바뀐 신고만 "신고 결과" 탭에 남긴다.
          _buildGenericList(
            items: crawlItems,
            emptyMessage: isStandalone ? '동기화 알림이 없습니다.' : '크롤링 알림이 없습니다.',
            emptySubMessage: isStandalone
                ? '동기화로 바뀐 신고는 "신고 결과" 탭에 기록됩니다.'
                : '크롤링 시작/완료 알림이 여기에 기록됩니다.',
          ),
          _buildGenericList(
            items: reportItems,
            emptyMessage: '신고 결과가 없습니다.',
            emptySubMessage:
                '${isStandalone ? '동기화' : '크롤링'} 후 변경된 신고건과 중복 신고 변경이 여기에 기록됩니다.\n각 항목을 눌러 상세 정보를 확인하세요.',
          ),
          _buildRatingList(ratingItems),
        ],
      ),
    );
  }

  Future<void> _refresh() async {
    context.read<NotificationHistoryProvider>().load();
    final ok = await _fetchServerResults();
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('서버 변경 결과를 가져오지 못했습니다. 아래로 당겨 다시 시도하세요.')),
      );
    }
  }

  Widget _buildGenericList({
    required List<NotificationItem> items,
    required String emptyMessage,
    required String emptySubMessage,
  }) {
    if (items.isEmpty) {
      return _buildEmptyState(
        emptyMessage: emptyMessage,
        emptySubMessage: emptySubMessage,
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
        itemBuilder: (context, index) {
          final item = items[index];
          return _NotifTile(
            item: item,
            onTap: () => _showDetail(context, item),
          );
        },
      ),
    );
  }

  Widget _buildRatingList(List<NotificationItem> items) {
    if (items.isEmpty) {
      return _buildEmptyState(
        emptyMessage: '별점 주기 기록이 없습니다.',
        emptySubMessage: '여러 신고건에 별점을 주면 처리 결과가 여기에 기록됩니다.',
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = items[index];
          final result = item.extraData == null
              ? null
              : RatingBatchResult.fromJson(item.extraData!);
          return _RatingBatchTile(
            item: item,
            result: result,
            onTap: () => _showDetail(context, item),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState({
    required String emptyMessage,
    required String emptySubMessage,
  }) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        children: [
          SizedBox(
            height: 320,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 72,
                    color: context.sr.border,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    emptyMessage,
                    style: TextStyle(
                      color: context.sr.textSecondary,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    emptySubMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.sr.textSecondary,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final NotificationItem item;
  final VoidCallback onTap;

  const _NotifTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final unread = !item.isRead;
    final hasDetail =
        (item.kind == NotificationItemKind.report ||
            item.kind == NotificationItemKind.duplicate) &&
        item.extraData != null &&
        item.extraData!.isNotEmpty;
    final isDuplicate = item.kind == NotificationItemKind.duplicate;
    final status = isDuplicate
        ? (item.extraData?['status_label']?.toString() ?? '').trim()
        : (item.extraData?['처리상태']?.toString() ?? '').trim();
    final fine = isDuplicate
        ? ''
        : (item.extraData?['범칙금_과태료']?.toString() ?? '').trim();

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 10),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: unread
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                ),
              ),
            ),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isDuplicate
                    ? StatusTone.of(
                        StatusTone.of(
                          Colors.indigo,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).background
                    : hasDetail
                    ? StatusTone.of(
                        StatusTone.of(
                          Colors.orange,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).background
                    : StatusTone.of(
                        Theme.of(context).colorScheme.primary,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isDuplicate
                    ? Icons.content_copy_outlined
                    : hasDetail
                    ? Icons.assignment_outlined
                    : Icons.notifications_active,
                color: isDuplicate
                    ? StatusTone.of(
                        StatusTone.of(
                          Colors.indigo,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).foreground
                    : hasDetail
                    ? StatusTone.of(
                        StatusTone.of(
                          Colors.orange,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).foreground
                    : StatusTone.of(
                        Theme.of(context).colorScheme.primary,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).foreground,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: unread ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.sr.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  if (hasDetail && (status.isNotEmpty || fine.isNotEmpty)) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        if (status.isNotEmpty)
                          _miniChip(
                            status,
                            isDuplicate
                                ? StatusTone.of(
                                    Colors.indigo,
                                    brightness: Theme.of(context).brightness,
                                    surface: context.sr.surface,
                                  ).foreground
                                : _statusColor(status),
                          ),
                        if (fine.isNotEmpty && fine != 'null')
                          _miniChip(
                            fine.split(':').first.trim(),
                            _fineColor(context, fine),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (item.reportNumber.isNotEmpty) ...[
                        Icon(
                          Icons.tag,
                          size: 11,
                          color: context.sr.textDisabled,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          item.reportNumber,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.sr.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Icon(
                        Icons.access_time,
                        size: 11,
                        color: context.sr.textDisabled,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        item.timestamp,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.sr.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: context.sr.textDisabled),
          ],
        ),
      ),
    );
  }

  Widget _miniChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    ),
  );

  Color _statusColor(String status) {
    return serverStatusColor(status);
  }

  Color _fineColor(BuildContext context, String fine) {
    if (fine == '미확인') return context.sr.textSecondary;
    return serverFineColor(fine);
  }
}

class _RatingBatchTile extends StatelessWidget {
  final NotificationItem item;
  final RatingBatchResult? result;
  final VoidCallback onTap;

  const _RatingBatchTile({
    required this.item,
    required this.result,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final unread = !item.isRead;
    final successCount = result?.successCount ?? 0;
    final skipCount = result?.skipCount ?? 0;
    final failureCount = result?.failureCount ?? 0;

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: unread
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)
              : context.sr.border,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: StatusTone.of(
                        StatusTone.of(
                          Colors.amber,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).background,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.star_rate_rounded,
                      color: StatusTone.of(
                        StatusTone.of(
                          Colors.amber,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).foreground,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: unread
                                ? FontWeight.bold
                                : FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.timestamp,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.sr.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (unread)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                item.body,
                style: TextStyle(
                  fontSize: 13,
                  color: context.sr.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _summaryChip(
                    '성공 $successCount',
                    StatusTone.of(
                      Colors.green,
                      brightness: Theme.of(context).brightness,
                      surface: context.sr.surface,
                    ).foreground,
                  ),
                  _summaryChip(
                    '스킵 $skipCount',
                    StatusTone.of(
                      Colors.orange,
                      brightness: Theme.of(context).brightness,
                      surface: context.sr.surface,
                    ).foreground,
                  ),
                  _summaryChip(
                    '실패 $failureCount',
                    Theme.of(context).colorScheme.error,
                  ),
                  if (result != null)
                    _summaryChip(
                      '목표 ${result!.score}점',
                      StatusTone.of(
                        StatusTone.of(
                          Colors.amber,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).foreground,
                    ),
                ],
              ),
              if (result != null && result!.failedReportNumbers.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '실패 신고번호: ${result!.failedReportNumbers.join(', ')}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700),
    ),
  );
}

class _RatingReportCard extends StatelessWidget {
  final RatingBatchItem item;
  final VoidCallback? onTap;

  const _RatingReportCard({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    final report = item.hasReportData
        ? Report.fromJson(item.reportData!)
        : null;
    final badgeColor = switch (item.status) {
      RatingBatchItemStatus.success => StatusTone.of(
        Colors.green,
        brightness: Theme.of(context).brightness,
        surface: context.sr.surface,
      ).foreground,
      RatingBatchItemStatus.skip => StatusTone.of(
        Colors.orange,
        brightness: Theme.of(context).brightness,
        surface: context.sr.surface,
      ).foreground,
      RatingBatchItemStatus.failure => Theme.of(context).colorScheme.error,
    };

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.sr.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      report?.name.isNotEmpty == true
                          ? report!.name
                          : (item.name.isNotEmpty ? item.name : '신고 상세'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: badgeColor.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      item.status.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: badgeColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.tag, size: 13, color: context.sr.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      item.reportNumber.isNotEmpty
                          ? item.reportNumber
                          : (report?.reportNumber ?? ''),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.sr.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              if (report != null) ...[
                const SizedBox(height: 6),
                if (report.agency.isNotEmpty)
                  _metaRow(context, Icons.business, report.agency),
                if (report.status.isNotEmpty)
                  _metaRow(
                    context,
                    Icons.assignment_turned_in_outlined,
                    report.status,
                  ),
                if (report.pollStatus.isNotEmpty)
                  _metaRow(
                    context,
                    Icons.star_border_rounded,
                    report.pollStatus,
                  ),
              ],
              const SizedBox(height: 8),
              Text(
                item.message,
                style: TextStyle(
                  fontSize: 12.5,
                  color: badgeColor,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(height: 10),
                Text(
                  '탭해서 신고 상세 보기',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.sr.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaRow(BuildContext context, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 12, color: context.sr.textSecondary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
