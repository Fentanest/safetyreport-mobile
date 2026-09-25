import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:workmanager/workmanager.dart';
import 'screens/dashboard_screen.dart';
import 'screens/report_list_screen.dart';
import 'screens/report_management_screen.dart';
import 'screens/statistics_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/notifications_screen.dart';
import 'models/app_mode.dart';
import 'models/app_theme_mode.dart';
import 'models/duplicate_group.dart';
import 'models/report.dart';
import 'providers/report_provider.dart';
import 'providers/notification_history_provider.dart';
import 'services/background_login_check.dart';
import 'services/pending_changes_store.dart';
import 'services/review_prompt_service.dart';
import 'services/sync_engine.dart' show ChangeType;
import 'server_palette.dart';
import 'navigation/app_routes.dart';
import 'theme/app_theme.dart';
import 'theme/sr_colors.dart';
import 'widgets/status_badge.dart';
import 'widgets/duplicate_group_detail_sheet.dart';
import 'widgets/report_detail_sheet.dart';
import 'widgets/maintenance_status_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Standalone 하루 1회 로그인 점검(BackgroundLoginCheck). 등록/해제는 ReportProvider 가 모드에 따라 한다.
  try {
    await Workmanager().initialize(backgroundTaskDispatcher);
  } catch (_) {}
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

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportProvider>(
      builder: (context, provider, _) {
        // 두 모드 공통 테마(D-03). 모드는 ModeBadge 로 따로 표시한다.
        return MaterialApp(
          title: '나만의 안전신문고',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: provider.themeMode.themeMode,
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
    with WidgetsBindingObserver {
  int _selectedIndex = 0;
  String _lastQuickActionSignature = '';
  late final List<Widget?> _screenCache = List<Widget?>.filled(_tabCount, null);

  /// 하단 탭 수(D-06: 7 → 5). 동기화/크롤링·파일은 [AppRoutes] 로 연다.
  static const _tabCount = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Native에서 navigateToTab 호출 수신
    _permChannel.setMethodCallHandler(_handleNativeCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationHistoryProvider>().load();
      _checkPendingChanges();
    });
    unawaited(ReviewPromptService.recordAppOpen());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ReviewPromptService.recordAppOpen());
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
        // 옛 하단 탭 인덱스 5(파일)·6(동기화/크롤링)은 화면을 따로 연다(Kotlin 은 그대로 6 을 보냄).
        if (tab == 5) {
          AppRoutes.openFiles(context);
        } else if (tab == 6) {
          // 런처 바로가기(quick_*)는 아래 _handleNavigationEvent 가 화면을 연 뒤 명령까지 전달한다.
          if (eventType != 'quick_sync' && eventType != 'quick_crawl') {
            AppRoutes.openCrawl(context);
          }
        } else {
          final index = tab.clamp(0, _tabCount - 1);
          setState(() => _selectedIndex = index);
          _refreshOnTab(index);
        }
      }
      if (payloadJson.isNotEmpty && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _openNotificationPayloadDetail(payloadJson);
        });
      }
      if (eventType.isNotEmpty && mounted) {
        await _handleNavigationEvent(eventType);
      }
    }
  }

  Future<void> _handleNavigationEvent(String eventType) async {
    switch (eventType) {
      case 'standalone_sync':
        await context.read<ReportProvider>().checkAutoSyncOnResume();
        return;
      case 'quick_sync':
      case 'quick_crawl':
        await AppRoutes.runQuickAction(context, eventType);
        return;
    }
  }

  /// 탭 변경 시 해당 화면 새로고침.
  /// 0 대시보드, 1 신고내역, 2 신고관리, 3 통계, 4 알림 (파일·동기화/크롤링은 [AppRoutes])
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
    }
  }

  Future<void> _checkForegroundEvent() async {
    final event = await ForegroundEventStore.readAndClear();
    if (event == null || !mounted) return;
    final title = event['title']?.toString() ?? '';
    final body = event['body']?.toString() ?? '';
    final payloadJson = event['payload_json']?.toString() ?? '';
    if (title.isEmpty) return;
    if (payloadJson.isNotEmpty) {
      final payload = _decodeNotificationPayload(payloadJson);
      if (payload != null) {
        final history = context.read<NotificationHistoryProvider>();
        await history.ensureLoaded();
        if (!mounted) return;
        if (history.isPayloadRead(payload)) return;
      }
    }
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
  }

  Map<String, dynamic>? _decodeNotificationPayload(String payloadJson) {
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  void _openNotificationPayloadDetail(String payloadJson) {
    final data = _decodeNotificationPayload(payloadJson);
    if (data == null) return;
    unawaited(
      context.read<NotificationHistoryProvider>().markPayloadRead(data),
    );
    final kind = data['notification_kind']?.toString() ?? 'report';
    if (kind == 'duplicate') {
      showDuplicateGroupDetailSheet(context, DuplicateGroup.fromJson(data));
    } else {
      showReportDetailSheet(context, Report.fromJson(data));
    }
  }

  Future<void> _checkPendingChanges() async {
    final changes = await PendingChangesStore.readAndClear();
    if (changes.isEmpty || !mounted) return;
    final history = context.read<NotificationHistoryProvider>();
    await history.ensureLoaded();
    if (!mounted) return;
    final unreadChanges = changes.where((change) {
      final kind = change['notification_kind']?.toString() ?? 'report';
      if (kind == 'duplicate') return true;
      return !history.isPayloadRead(change);
    }).toList();
    if (unreadChanges.isEmpty) return;

    // 알림 히스토리에 extraData 포함해서 저장 (신고 결과 탭에서 상세 조회 가능하도록)
    history.setPreferredTabIndex(1, notify: false);
    await history.addFromServerResults(unreadChanges);
    if (!mounted) return;

    // 알림 탭으로 이동
    setState(() => _selectedIndex = 4);

    // 변경 신고건 카드 뷰 표시
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    _showChangesBottomSheet(unreadChanges);
  }

  void _showChangesBottomSheet(List<Map<String, dynamic>> changes) {
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
                    r['notification_kind'] != 'duplicate' &&
                    r['change_type'] == ChangeType.newReport,
              )
              .length;
          final confirmCount = changes
              .where(
                (r) =>
                    r['notification_kind'] != 'duplicate' &&
                    r['change_type'] == ChangeType.individualConfirm,
              )
              .length;
          final duplicateCount = changes
              .where((r) => r['notification_kind'] == 'duplicate')
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
                        color: context.sr.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.sync_alt,
                          color: Theme.of(context).colorScheme.primary,
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
                          _changeBadge('신규', newCount, changeNewColor),
                        if (changedCount > 0)
                          _changeBadge('처리변경', changedCount, changeStatusColor),
                        if (confirmCount > 0)
                          _changeBadge(
                            '개별 확인',
                            confirmCount,
                            changeConfirmColor,
                          ),
                        if (duplicateCount > 0)
                          _changeBadge(
                            '중복 변경',
                            duplicateCount,
                            changeDuplicateColor,
                          ),
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
                    final r = changes[i];
                    final isDuplicate =
                        (r['notification_kind']?.toString() ?? '') ==
                        'duplicate';
                    if (isDuplicate) {
                      final statusLabel =
                          r['status_label']?.toString() ?? '중복 신고 변경';
                      final title = r['title']?.toString() ?? '중복 신고 변경';
                      final body = r['body']?.toString() ?? '';
                      final memberCount = r['member_count']?.toString() ?? '';
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
                                    const Padding(
                                      padding: EdgeInsets.only(right: 6),
                                      child: StatusBadge(
                                        label: '중복 변경',
                                        color: changeDuplicateColor,
                                        fontSize: 10,
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
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 120,
                                      ),
                                      child: StatusBadge(
                                        label: statusLabel,
                                        color: changeDuplicateColor,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 16,
                                      color: context.sr.textDisabled,
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
                                      color: context.sr.textSecondary,
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
                                          color: context.sr.textSecondary,
                                        ),
                                      ),
                                    if (memberCount.isNotEmpty)
                                      Text(
                                        '멤버 수: ${memberCount}건',
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
                        ),
                      );
                    }
                    final changeType = r['change_type']?.toString() ?? '변경';
                    final isNew = changeType == ChangeType.newReport;
                    final isConfirm =
                        changeType == ChangeType.individualConfirm;
                    final badgeColor = isNew
                        ? changeNewColor
                        : isConfirm
                        ? changeConfirmColor
                        : changeStatusColor;
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

                    final statusColor = serverStatusColor(status);

                    // 과태료/범칙금/경고/미확인 결과 라벨용 색상
                    Color? fineColor;
                    if (fine == '미확인') {
                      fineColor = serverUnconfirmedColor;
                    } else if (fine.isNotEmpty) {
                      fineColor = serverFineColor(fine);
                    }

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
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: StatusBadge(
                                      label: badgeLabel,
                                      color: badgeColor,
                                      fontSize: 10,
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
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 110,
                                    ),
                                    child: StatusBadge(
                                      label: status.isEmpty ? '처리 중' : status,
                                      color: statusColor,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (fineColor != null) ...[
                                    const SizedBox(width: 4),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 90,
                                      ),
                                      // 금액 있는 과태료/범칙금은 라벨만, 외(경고/미확인)는 그대로
                                      child: StatusBadge(
                                        label: fine.split(':').first.trim(),
                                        color: fineColor,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.chevron_right,
                                    size: 16,
                                    color: context.sr.textDisabled,
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
                                      color: context.sr.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      reportNo,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: context.sr.textSecondary,
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
                                      color: context.sr.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      agency,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: context.sr.textSecondary,
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
                                      color: context.sr.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      fine,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: context.sr.textSecondary,
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
    return StatusBadge(label: '$label $count건', color: color, fontSize: 12);
  }

  int _lastPendingChangesNonce = 0;

  Widget _buildScreen(int index) {
    final cached = _screenCache[index];
    if (cached != null) return cached;
    final screen = switch (index) {
      0 => const DashboardScreen(),
      1 => const ReportListScreen(),
      2 => const ReportManagementScreen(),
      3 => const StatisticsScreen(),
      4 => const NotificationsScreen(),
      _ => const SizedBox.shrink(),
    };
    _screenCache[index] = screen;
    return screen;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReportProvider>();
    final unread = context.watch<NotificationHistoryProvider>().unreadCount;
    _refreshNativeQuickActionsIfNeeded(p);

    // standalone drain 이 변경을 기록하면 카드 시트 표시 (Client 모드 _checkPendingChanges 와 동일 흐름)
    if (p.pendingChangesNonce != _lastPendingChangesNonce) {
      _lastPendingChangesNonce = p.pendingChangesNonce;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkPendingChanges();
      });
    }

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: List<Widget>.generate(_tabCount, (index) {
          final cached = _screenCache[index];
          if (cached != null || index == _selectedIndex) {
            // 숨은 탭은 TickerMode false — 애니메이션 정지 + SelectionBackScope 가 뒤로가기를 가로채지 않게 한다.
            return TickerMode(
              enabled: index == _selectedIndex,
              child: _buildScreen(index),
            );
          }
          return const SizedBox.shrink();
        }),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 업데이트 뒤 한 번 훑기 진행(작업이 없으면 높이 0). Client 는 서버 작업, Standalone 은 이 기기 작업.
          if (p.isConfigured && !p.isStandaloneDemo)
            MaintenanceStatusBar(
              key: ValueKey('maintenance-${p.appMode.name}'),
              fetchServerStatus: p.appMode == AppMode.server
                  ? p.fetchMaintenanceStatus
                  : null,
            ),
          _buildNavigationBar(unread),
        ],
      ),
    );
  }

  Widget _buildNavigationBar(int unread) {
    return NavigationBar(
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
      ],
    );
  }

  void _refreshNativeQuickActionsIfNeeded(ReportProvider provider) {
    final signature = [
      provider.appMode.name,
      provider.isConfigured ? 'configured' : 'not-configured',
      provider.isStandaloneDemo ? 'demo' : 'live',
    ].join('|');
    if (signature == _lastQuickActionSignature) return;
    _lastQuickActionSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshNativeQuickActions());
    });
  }

  Future<void> _refreshNativeQuickActions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _permChannel.invokeMethod('refreshQuickActions');
    } catch (_) {}
  }
}
