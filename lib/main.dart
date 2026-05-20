import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'screens/dashboard_screen.dart';
import 'screens/report_list_screen.dart';
import 'screens/report_management_screen.dart';
import 'screens/statistics_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/file_browser_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/crawl_screen.dart';
import 'models/app_mode.dart';
import 'models/app_theme_mode.dart';
import 'models/duplicate_group.dart';
import 'models/report.dart';
import 'providers/report_provider.dart';
import 'providers/notification_history_provider.dart';
import 'services/pending_changes_store.dart';
import 'services/sync_engine.dart' show ChangeType;
import 'server_palette.dart';
import 'widgets/duplicate_group_detail_sheet.dart';
import 'widgets/report_detail_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
  static const _darkSurface = Color(0xFF09131A);
  static const _darkSurfaceLow = Color(0xFF101D26);
  static const _darkSurfaceMid = Color(0xFF172733);
  static const _darkSurfaceHigh = Color(0xFF213545);

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
          theme: _buildTheme(
            brightness: Brightness.light,
            primary: primary,
            indicator: indicator,
          ),
          darkTheme: _buildTheme(
            brightness: Brightness.dark,
            primary: primary,
            indicator: indicator,
          ),
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

  ThemeData _buildTheme({
    required Brightness brightness,
    required Color primary,
    required Color indicator,
  }) {
    final isDark = brightness == Brightness.dark;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    );
    final surface = isDark ? _darkSurface : Colors.white;
    final surfaceLow = isDark ? _darkSurfaceLow : const Color(0xFFFAFAFA);
    final surfaceMid = isDark ? _darkSurfaceMid : const Color(0xFFF5F5F5);
    final surfaceHigh = isDark ? _darkSurfaceHigh : const Color(0xFFE0E0E0);
    final appBarColor = isDark
        ? Color.alphaBlend(primary.withValues(alpha: 0.20), _darkSurfaceMid)
        : primary;
    final appBarForeground = isDark ? baseScheme.onSurface : Colors.white;
    final outline = isDark ? const Color(0xFF2C4151) : const Color(0xFFE8EAED);
    final scheme = baseScheme.copyWith(
      primary: primary,
      surface: surface,
      surfaceContainerLowest: isDark ? const Color(0xFF060D13) : Colors.white,
      surfaceContainerLow: surfaceLow,
      surfaceContainer: surfaceMid,
      surfaceContainerHigh: isDark ? _darkSurfaceHigh : const Color(0xFFEEEEEE),
      surfaceContainerHighest: surfaceHigh,
      outlineVariant: outline,
    );
    final overlayStyle = SystemUiOverlayStyle(
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
      systemStatusBarContrastEnforced: false,
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: surface,
      canvasColor: surface,
      dividerColor: scheme.outlineVariant,
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: appBarColor,
        foregroundColor: appBarForeground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: overlayStyle,
        titleTextStyle: TextStyle(
          color: appBarForeground,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        modalBackgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.55),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? scheme.surfaceContainerHigh.withValues(alpha: 0.82)
            : scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(
            alpha: isDark ? 0.82 : 0.88,
          ),
        ),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: inputBorder,
        enabledBorder: inputBorder,
        disabledBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: primary, width: 1.4),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark
            ? scheme.surfaceContainerLow.withValues(alpha: 0.96)
            : Colors.white.withValues(alpha: 0.98),
        elevation: 8,
        shadowColor: isDark ? Colors.black45 : Colors.black12,
        indicatorColor: isDark ? primary.withValues(alpha: 0.22) : indicator,
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        textColor: scheme.onSurface,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? scheme.surfaceContainerHigh : null,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(scheme.outlineVariant),
      ),
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
  final GlobalKey<CrawlScreenState> _crawlScreenKey =
      GlobalKey<CrawlScreenState>();
  String _lastQuickActionSignature = '';

  late final List<Widget> _screens = [
    const DashboardScreen(),
    const ReportListScreen(),
    const ReportManagementScreen(),
    const StatisticsScreen(),
    const NotificationsScreen(),
    const FileBrowserScreen(),
    CrawlScreen(key: _crawlScreenKey),
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
        for (var attempt = 0; attempt < 5; attempt++) {
          final crawlState = _crawlScreenKey.currentState;
          if (crawlState != null) {
            await crawlState.handleQuickAction(eventType);
            return;
          }
          await Future.delayed(const Duration(milliseconds: 200));
        }
        return;
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

                    final statusColor = serverStatusColor(status);

                    // 과태료/범칙금/경고/미확인 결과 라벨용 색상
                    Color? fineColor;
                    if (fine == '미확인') {
                      fineColor = Colors.grey;
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
    _refreshNativeQuickActionsIfNeeded(p);

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
