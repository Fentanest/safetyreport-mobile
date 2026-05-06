import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/dashboard_screen.dart';
import 'screens/report_list_screen.dart';
import 'screens/report_management_screen.dart';
import 'screens/statistics_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/file_browser_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/crawl_screen.dart';
import 'models/app_mode.dart';
import 'models/duplicate_group.dart';
import 'models/report.dart';
import 'providers/report_provider.dart';
import 'providers/notification_history_provider.dart';
import 'services/sync_engine.dart' show ChangeType;
import 'widgets/duplicate_group_detail_sheet.dart';
import 'widgets/report_detail_sheet.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ReportProvider()..init()),
        ChangeNotifierProvider(
          create: (_) => NotificationHistoryProvider()..load(),
        ),
      ],
      child: const SafetyReportApp(),
    ),
  );
}

class SafetyReportApp extends StatelessWidget {
  const SafetyReportApp({super.key});

  // Server (client) 모드 — 구글 블루 / Standalone 모드 — 머티리얼 그린
  static const _serverPrimary = Color(0xFF1A73E8);
  static const _serverIndicator = Color(0xFFE3EEFF);
  static const _standalonePrimary = Color(0xFF1B873B);
  static const _standaloneIndicator = Color(0xFFDFF1E3);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportProvider>(
      builder: (context, provider, _) {
        final isStandalone = provider.appMode == AppMode.standalone;
        final primary = isStandalone ? _standalonePrimary : _serverPrimary;
        final indicator = isStandalone
            ? _standaloneIndicator
            : _serverIndicator;

        return MaterialApp(
          title: '나만의 안전신문고',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            // 초록 시드는 surface 에 노란기가 도는 톤을 만들어냄 → 흰색으로 강제.
            // 카드/시트 등 모든 surface 계열을 중립 흰색 으로 통일.
            colorScheme:
                ColorScheme.fromSeed(
                  seedColor: primary,
                  brightness: Brightness.light,
                ).copyWith(
                  surface: Colors.white,
                  surfaceContainerLowest: Colors.white,
                  surfaceContainerLow: const Color(0xFFFAFAFA),
                  surfaceContainer: const Color(0xFFF5F5F5),
                  surfaceContainerHigh: const Color(0xFFEEEEEE),
                  surfaceContainerHighest: const Color(0xFFE0E0E0),
                ),
            scaffoldBackgroundColor: Colors.white,
            canvasColor: Colors.white,
            appBarTheme: AppBarTheme(
              centerTitle: false,
              backgroundColor: primary,
              foregroundColor: Colors.white,
              elevation: 0,
              titleTextStyle: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            cardTheme: const CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
                side: BorderSide(color: Color(0xFFE8EAED)),
              ),
            ),
            inputDecorationTheme: const InputDecorationTheme(
              contentPadding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
            ),
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: Colors.white,
              elevation: 8,
              shadowColor: Colors.black12,
              indicatorColor: indicator,
              labelTextStyle: const WidgetStatePropertyAll(
                TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: primary,
              brightness: Brightness.dark,
            ),
            appBarTheme: const AppBarTheme(
              centerTitle: false,
              backgroundColor: Color(0xFF1E1E2E),
              foregroundColor: Colors.white,
              elevation: 0,
              titleTextStyle: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            cardTheme: const CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
            ),
          ),
          home: Builder(
            builder: (_) {
              if (!provider.isInitialized) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              if (!provider.isConfigured) {
                return const SetupScreen();
              }
              return const MainNavigationScreen();
            },
          ),
        );
      },
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

const _permChannel = MethodChannel('com.fentanest.mysafetyreport/permissions');

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  int _selectedIndex = 0;

  final List<Widget> _screens = [
    const DashboardScreen(),
    const ReportListScreen(),
    const ReportManagementScreen(),
    const StatisticsScreen(),
    const NotificationsScreen(),
    const FileBrowserScreen(),
    const CrawlScreen(),
  ];

  late final AnimationController _syncIconController;

  @override
  void initState() {
    super.initState();
    _syncIconController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    WidgetsBinding.instance.addObserver(this);
    // Native에서 navigateToTab 호출 수신
    _permChannel.setMethodCallHandler(_handleNativeCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationHistoryProvider>().load();
      _checkPendingChanges();
    });
  }

  @override
  void dispose() {
    _syncIconController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPendingChanges();
      _checkForegroundEvent();
      // standalone: Kotlin NotificationService 가 설정한 sync pending 플래그 확인
      if (mounted) {
        context.read<ReportProvider>().checkAutoSyncOnResume();
      }
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'navigateToTab') {
      final args = call.arguments as Map?;
      final tab = (args?['tab'] as num?)?.toInt() ?? 4;
      final subTab = (args?['sub_tab'] as num?)?.toInt();
      final eventType = args?['event_type']?.toString() ?? '';
      final payloadJson = args?['payload_json']?.toString() ?? '';
      if (subTab != null && subTab >= 0) {
        context.read<NotificationHistoryProvider>().setPreferredTabIndex(
          subTab,
          notify: false,
        );
      }
      if (mounted) {
        setState(() => _selectedIndex = tab);
        _refreshOnTab(tab);
      }
      if (payloadJson.isNotEmpty && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _openNotificationPayloadDetail(payloadJson);
        });
      }
      // standalone: 알림 탭으로 진입 → 동기화 즉시 트리거
      if (eventType == 'standalone_sync' && mounted) {
        await context.read<ReportProvider>().checkAutoSyncOnResume();
      }
    }
  }

  /// 탭 변경 시 해당 화면 새로고침.
  /// 0 대시보드, 1 신고내역, 2 신고관리, 3 통계, 4 알림, 5 파일, 6 동기화/크롤링
  void _refreshOnTab(int index) {
    if (!mounted) return;
    final p = context.read<ReportProvider>();
    switch (index) {
      case 0:
        if (p.isConfigured) p.fetchSummary();
        break;
      case 1:
        if (p.isConfigured) {
          p.fetchTrafficReports();
          p.fetchParkingReports();
          p.fetchOtherReports();
          p.fetchDuplicateReports();
          p.fetchWatchlistNumbers();
        }
        break;
      case 2:
        p.fetchWatchlistNumbers();
        break;
      case 3:
        p.bumpStatsRefresh();
        break;
      case 4:
        context.read<NotificationHistoryProvider>().load();
        break;
      case 5:
        p.bumpFilesRefresh();
        break;
      case 6:
        // 동기화/크롤링 탭은 사용자 액션 기반이므로 자동 새로고침 없음
        break;
    }
  }

  Future<void> _checkForegroundEvent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString('foreground_event');
    if (raw == null) return;
    await prefs.remove('foreground_event');
    if (!mounted) return;
    try {
      final event = jsonDecode(raw) as Map<String, dynamic>;
      final title = event['title']?.toString() ?? '';
      final body = event['body']?.toString() ?? '';
      final payloadJson = event['payload_json']?.toString() ?? '';
      if (title.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              if (body.isNotEmpty)
                Text(body, style: const TextStyle(fontSize: 12)),
            ],
          ),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: payloadJson.isNotEmpty ? '상세 보기' : '알림 보기',
            onPressed: () {
              setState(() => _selectedIndex = 4);
              if (payloadJson.isNotEmpty) {
                _openNotificationPayloadDetail(payloadJson);
              }
            },
          ),
        ),
      );
    } catch (_) {}
  }

  void _openNotificationPayloadDetail(String payloadJson) {
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return;
      final data = Map<String, dynamic>.from(decoded as Map);
      final kind = data['notification_kind']?.toString() ?? 'report';
      if (kind == 'duplicate') {
        showDuplicateGroupDetailSheet(context, DuplicateGroup.fromJson(data));
      } else {
        showReportDetailSheet(context, Report.fromJson(data));
      }
    } catch (_) {}
  }

  Future<void> _checkPendingChanges() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString('pending_crawl_changes');
    if (raw == null || raw.isEmpty) return;
    await prefs.remove('pending_crawl_changes');

    List<dynamic> changes;
    try {
      changes = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return;
    }
    if (changes.isEmpty) return;
    if (!mounted) return;

    // 알림 히스토리에 extraData 포함해서 저장 (신고 결과 탭에서 상세 조회 가능하도록)
    context.read<NotificationHistoryProvider>().setPreferredTabIndex(
      1,
      notify: false,
    );
    await context.read<NotificationHistoryProvider>().addFromServerResults(
      changes.cast<Map<String, dynamic>>(),
    );

    // 알림 탭으로 이동
    setState(() => _selectedIndex = 4);

    // 변경 신고건 카드 뷰 표시
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    _showChangesBottomSheet(changes);
  }

  void _showChangesBottomSheet(List<dynamic> changes) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, controller) {
          final newCount = changes
              .where(
                (r) =>
                    (r as Map)['notification_kind'] != 'duplicate' &&
                    (r as Map)['change_type'] == ChangeType.newReport,
              )
              .length;
          final confirmCount = changes
              .where(
                (r) =>
                    (r as Map)['notification_kind'] != 'duplicate' &&
                    (r as Map)['change_type'] == ChangeType.individualConfirm,
              )
              .length;
          final duplicateCount = changes
              .where((r) => (r as Map)['notification_kind'] == 'duplicate')
              .length;
          final changedCount =
              changes.length - newCount - confirmCount - duplicateCount;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.sync_alt,
                          color: Colors.blue,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '변경 결과 ${changes.length}건',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (newCount > 0)
                          _changeBadge('신규', newCount, Colors.teal),
                        if (changedCount > 0)
                          _changeBadge('처리변경', changedCount, Colors.orange),
                        if (confirmCount > 0)
                          _changeBadge('개별 확인', confirmCount, Colors.blueGrey),
                        if (duplicateCount > 0)
                          _changeBadge('중복 변경', duplicateCount, Colors.indigo),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.all(12),
                  itemCount: changes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final r = changes[i] as Map<String, dynamic>;
                    final isDuplicate =
                        (r['notification_kind']?.toString() ?? '') ==
                        'duplicate';
                    if (isDuplicate) {
                      final statusLabel =
                          r['status_label']?.toString() ?? '중복 신고 변경';
                      final title = r['title']?.toString() ?? '중복 신고 변경';
                      final body = r['body']?.toString() ?? '';
                      final memberCount =
                          r['member_count']?.toString() ?? '';
                      final representativeReportNumber =
                          r['representative_report_number']?.toString() ?? '';

                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.pop(ctx);
                          showDuplicateGroupDetailSheet(
                            context,
                            DuplicateGroup.fromJson(r),
                          );
                        },
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      margin: const EdgeInsets.only(right: 6),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.indigo.withValues(
                                          alpha: 0.12,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: Colors.indigo.withValues(
                                            alpha: 0.5,
                                          ),
                                        ),
                                      ),
                                      child: const Text(
                                        '중복 변경',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.indigo,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.indigo.withValues(
                                          alpha: 0.12,
                                        ),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: Colors.indigo.withValues(
                                            alpha: 0.4,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        statusLabel,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.indigo,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 16,
                                      color: Colors.grey.shade400,
                                    ),
                                  ],
                                ),
                                if (body.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    body,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    if (representativeReportNumber.isNotEmpty)
                                      Text(
                                        '대표 신고번호: $representativeReportNumber',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    if (memberCount.isNotEmpty)
                                      Text(
                                        '멤버 수: ${memberCount}건',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    final changeType = r['change_type']?.toString() ?? '변경';
                    final isNew = changeType == ChangeType.newReport;
                    final isConfirm =
                        changeType == ChangeType.individualConfirm;
                    final badgeColor = isNew
                        ? Colors.teal
                        : isConfirm
                        ? Colors.blueGrey
                        : Colors.orange;
                    final badgeLabel = isNew
                        ? '신규'
                        : isConfirm
                        ? '개별 확인'
                        : '처리변경';
                    final reportNo = r['신고번호']?.toString() ?? '';
                    final name = r['신고명']?.toString() ?? '신고';
                    final status = r['처리상태']?.toString() ?? '';
                    final agency = r['처리기관']?.toString() ?? '';
                    final fine = r['범칙금_과태료']?.toString() ?? '';

                    Color statusColor = Colors.grey;
                    if (status == '수용')
                      statusColor = Colors.green;
                    else if (status == '일부수용')
                      statusColor = const Color(0xFF43A047);
                    else if (status.contains('불수용') || status == '기타')
                      statusColor = Colors.red;
                    else if (status.contains('처리') || status.contains('진행'))
                      statusColor = Colors.orange;
                    else if (status.contains('완료'))
                      statusColor = Colors.blue;
                    else if (status == '취하')
                      statusColor = Colors.brown;

                    // 과태료/범칙금/경고/미확인 결과 라벨용 색상
                    Color? fineColor;
                    if (fine.contains('과태료'))
                      fineColor = Colors.red.shade600;
                    else if (fine.contains('범칙금'))
                      fineColor = Colors.deepOrange;
                    else if (fine.contains('경고'))
                      fineColor = Colors.amber.shade800;
                    else if (fine == '미확인')
                      fineColor = Colors.grey;

                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.pop(ctx);
                        showReportDetailSheet(context, Report.fromJson(r));
                      },
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    margin: const EdgeInsets.only(right: 6),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: badgeColor.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: badgeColor.withOpacity(0.5),
                                      ),
                                    ),
                                    child: Text(
                                      badgeLabel,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: badgeColor,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: statusColor.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: statusColor.withOpacity(0.4),
                                      ),
                                    ),
                                    child: Text(
                                      status.isEmpty ? '처리 중' : status,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: statusColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (fineColor != null) ...[
                                    const SizedBox(width: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: fineColor.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: fineColor.withOpacity(0.4),
                                        ),
                                      ),
                                      child: Text(
                                        // 금액 있는 과태료/범칙금은 라벨만 굵게, 외(경고/미확인)는 그대로
                                        fine.split(':').first.trim(),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: fineColor,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.chevron_right,
                                    size: 16,
                                    color: Colors.grey.shade400,
                                  ),
                                ],
                              ),
                              if (reportNo.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.tag,
                                      size: 13,
                                      color: Colors.grey.shade500,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      reportNo,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (agency.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.business,
                                      size: 13,
                                      color: Colors.grey.shade500,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      agency,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (fine.isNotEmpty && fine != 'null') ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.receipt_long,
                                      size: 13,
                                      color: Colors.grey.shade500,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      fine,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _changeBadge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        '$label $count건',
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildSyncIcon({required bool isSelected}) {
    final icon = isSelected
        ? const Icon(Icons.sync)
        : const Icon(Icons.sync_outlined);
    return RotationTransition(
      turns: Tween<double>(begin: 0, end: -1).animate(_syncIconController),
      child: icon,
    );
  }

  int _lastPendingChangesNonce = 0;

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReportProvider>();
    final unread = context.watch<NotificationHistoryProvider>().unreadCount;

    if (p.isSyncing) {
      if (!_syncIconController.isAnimating) _syncIconController.repeat();
    } else {
      if (_syncIconController.isAnimating) _syncIconController.stop();
    }

    // standalone drain 이 변경을 기록하면 카드 시트 표시 (Client 모드 _checkPendingChanges 와 동일 흐름)
    if (p.pendingChangesNonce != _lastPendingChangesNonce) {
      _lastPendingChangesNonce = p.pendingChangesNonce;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkPendingChanges();
      });
    }

    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
          _refreshOnTab(index);
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: '대시보드',
          ),
          const NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: '신고내역',
          ),
          const NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: '신고관리',
          ),
          const NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: '통계',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications),
            ),
            label: '알림',
          ),
          const NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '파일',
          ),
          NavigationDestination(
            icon: _buildSyncIcon(isSelected: false),
            selectedIcon: _buildSyncIcon(isSelected: true),
            label: p.appMode == AppMode.standalone ? '동기화' : '크롤링',
          ),
        ],
      ),
    );
  }
}
