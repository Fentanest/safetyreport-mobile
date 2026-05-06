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
import '../services/api_service.dart';
import '../widgets/duplicate_group_detail_sheet.dart';
import '../widgets/report_detail_sheet.dart';

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

  Future<void> _fetchServerResults() async {
    if (_isStandalone) return;
    final api = _getApi();
    if (api == null) return;
    try {
      final done = await api.getCrawlDone();
      if (done['done'] == true) {
        final changedCount = (done['changed_count'] as num?)?.toInt() ?? 0;
        final results = await api.fetchCrawlResults();
        if (mounted) {
          context.read<NotificationHistoryProvider>().setPreferredTabIndex(1);
          await context
              .read<NotificationHistoryProvider>()
              .addFromServerResults(results);
        }
        _showPushNotif(changedCount);
      }
    } catch (_) {}
  }

  Future<void> _showPushNotif(int changedCount) async {
    try {
      final body = changedCount > 0
          ? '크롤링이 완료되었습니다. ${changedCount}건의 변경사항이 있습니다.'
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
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: hasChanges ? 0.5 : 0.4,
        minChildSize: 0.3,
        maxChildSize: 0.7,
        expand: false,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.notifications_active, color: Colors.blue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Text(item.body, style: const TextStyle(fontSize: 14, height: 1.6)),
            const SizedBox(height: 20),
            if (item.reportNumber.isNotEmpty)
              _detailRow('신고번호', item.reportNumber),
            _detailRow('수신 시각', item.timestamp),
            if (hasChanges) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.assignment_outlined),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.star_rate_rounded, color: Colors.amber),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
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
                  Colors.green,
                  Icons.check_circle_outline,
                ),
                _countChip(
                  '스킵 ${result.skipCount}',
                  Colors.orange,
                  Icons.fast_forward_outlined,
                ),
                _countChip(
                  '실패 ${result.failureCount}',
                  Colors.red,
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
                  color: Colors.red.shade700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                result.failedReportNumbers.join(', '),
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.red.shade700,
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
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
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
              icon: const Icon(Icons.done_all, size: 18),
              label: const Text('모두 읽음'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: provider.markAllRead,
            ),
          if (allItems.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '모두 비우기',
              onPressed: () async {
                if (await _confirmClear(context) && context.mounted) {
                  context.read<NotificationHistoryProvider>().clearAll();
                }
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          tabs: [
            _tabWithBadge('크롤링 현황', crawlUnread),
            _tabWithBadge('신고 결과', reportUnread),
            _tabWithBadge('별점 주기', ratingUnread),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildGenericList(
            items: crawlItems,
            emptyMessage: '크롤링 알림이 없습니다.',
            emptySubMessage: '크롤링 시작/완료 알림이 여기에 기록됩니다.',
          ),
          _buildGenericList(
            items: reportItems,
            emptyMessage: '신고 결과가 없습니다.',
            emptySubMessage:
                '크롤링 후 변경된 신고건과 중복 신고 변경이 여기에 기록됩니다.\n각 항목을 눌러 상세 정보를 확인하세요.',
          ),
          _buildRatingList(ratingItems),
        ],
      ),
    );
  }

  Tab _tabWithBadge(String label, int unread) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (unread > 0) ...[const SizedBox(width: 6), _unreadBadge(unread)],
        ],
      ),
    );
  }

  Widget _unreadBadge(int count) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: Colors.red,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      '$count',
      style: const TextStyle(
        fontSize: 11,
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Future<void> _refresh() async {
    context.read<NotificationHistoryProvider>().load();
    await _fetchServerResults();
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
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
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
        separatorBuilder: (_, __) => const SizedBox(height: 10),
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
                    color: Colors.grey.shade300,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    emptyMessage,
                    style: const TextStyle(color: Colors.grey, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    emptySubMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.grey,
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
                  color: unread ? Colors.blue : Colors.transparent,
                ),
              ),
            ),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isDuplicate
                    ? Colors.indigo.shade50
                    : hasDetail
                    ? Colors.orange.shade50
                    : Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isDuplicate
                    ? Icons.content_copy_outlined
                    : hasDetail
                    ? Icons.assignment_outlined
                    : Icons.notifications_active,
                color: isDuplicate
                    ? Colors.indigo.shade700
                    : hasDetail
                    ? Colors.orange.shade700
                    : Colors.blue.shade700,
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
                      color: Colors.grey.shade600,
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
                            isDuplicate ? Colors.indigo : _statusColor(status),
                          ),
                        if (fine.isNotEmpty && fine != 'null')
                          _miniChip(
                            fine.split(':').first.trim(),
                            _fineColor(fine),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (item.reportNumber.isNotEmpty) ...[
                        Icon(Icons.tag, size: 11, color: Colors.grey.shade400),
                        const SizedBox(width: 2),
                        Text(
                          item.reportNumber,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade400,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Icon(
                        Icons.access_time,
                        size: 11,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        item.timestamp,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade400),
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
    if (status == '일부수용') return const Color(0xFF43A047);
    if (status.contains('수용') && !status.contains('불')) return Colors.green;
    if (status.contains('불수용') || status == '기타') return Colors.red;
    if (status.contains('처리') || status.contains('진행')) return Colors.orange;
    if (status.contains('완료')) return Colors.blue;
    if (status == '취하') return Colors.brown;
    return Colors.grey;
  }

  Color _fineColor(String fine) {
    if (fine.contains('과태료')) return Colors.red.shade600;
    if (fine.contains('범칙금')) return Colors.deepOrange;
    if (fine.contains('경고')) return Colors.amber.shade800;
    if (fine == '미확인') return Colors.grey;
    return Colors.grey;
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
              : Colors.grey.shade200,
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
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.star_rate_rounded,
                      color: Colors.amber.shade800,
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
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (unread)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.blue,
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
                  color: Colors.grey.shade700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _summaryChip('성공 $successCount', Colors.green),
                  _summaryChip('스킵 $skipCount', Colors.orange),
                  _summaryChip('실패 $failureCount', Colors.red),
                  if (result != null)
                    _summaryChip('목표 ${result!.score}점', Colors.amber.shade800),
                ],
              ),
              if (result != null && result!.failedReportNumbers.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '실패 신고번호: ${result!.failedReportNumbers.join(', ')}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red.shade700,
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
      RatingBatchItemStatus.success => Colors.green,
      RatingBatchItemStatus.skip => Colors.orange,
      RatingBatchItemStatus.failure => Colors.red,
    };

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
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
                      style: const TextStyle(
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
                  const Icon(Icons.tag, size: 13, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      item.reportNumber.isNotEmpty
                          ? item.reportNumber
                          : (report?.reportNumber ?? ''),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
              if (report != null) ...[
                const SizedBox(height: 6),
                if (report.agency.isNotEmpty)
                  _metaRow(Icons.business, report.agency),
                if (report.status.isNotEmpty)
                  _metaRow(Icons.assignment_turned_in_outlined, report.status),
                if (report.pollStatus.isNotEmpty)
                  _metaRow(Icons.star_border_rounded, report.pollStatus),
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
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 12, color: Colors.grey),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
