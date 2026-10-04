import '../services/client_compatibility.dart';
import '../services/server_contract.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/server_connection_service.dart';
import '../services/crawl_unresolved.dart';
import '../services/local_db_service.dart';
import '../services/sync_engine.dart';
import '../widgets/auth_status_notice.dart';
import '../widgets/sync_exit_guard.dart';
import '../widgets/sr_app_bar_actions.dart';
import '../theme/sr_colors.dart';
import '../theme/sr_tokens.dart';
import '../widgets/sr_snack_bar.dart';

class CrawlScreen extends StatefulWidget {
  const CrawlScreen({super.key, this.apiFactory, this.connectLogSocket});

  /// 테스트 주입용. null 이면 Provider 의 서버 주소·키로 [ApiService] 를 만든다.
  @visibleForTesting
  final ApiService? Function(ReportProvider provider)? apiFactory;

  /// 테스트 주입용. null 이면 호환성 확인 뒤 서버 로그 WebSocket 에 연결한다.
  @visibleForTesting
  final Future<WebSocket> Function(ApiService api)? connectLogSocket;

  @override
  State<CrawlScreen> createState() => CrawlScreenState();
}

class CrawlScreenState extends State<CrawlScreen> with WidgetsBindingObserver {
  // ── 서버 모드 상태 ──────────────────────────────────────────────────────────
  String _crawlMode = 'full';
  final _queueController = TextEditingController();

  bool _isRunning = false;
  List<CrawlUnresolved> _unresolved = const [];
  void _setRunning(bool val) {
    if (!mounted || _isRunning == val) return;
    setState(() => _isRunning = val);
    context.read<ReportProvider>().setSyncing(val);
  }

  bool _loading = true;

  WebSocket? _ws;

  /// 연결 중인 로그 WebSocket 이 있으면 true — 같은 시점의 두 번째 연결을 막는다.
  bool _wsConnecting = false;

  /// 닫기 요청(크롤링 종료·화면 dispose)마다 증가. 연결이 끝났을 때 값이 바뀌었으면 그 소켓은 닫는다.
  int _wsEpoch = 0;
  final List<String> _logLines = [];
  final ScrollController _logScroll = ScrollController();
  final GlobalKey _topAreaKey = GlobalKey();
  Timer? _statusTimer;

  /// 앱이 화면에 보이는가(paused/hidden 이면 상태 폴링을 멈춘다).
  bool _foreground = true;

  // ── 스탠드어론 모드 상태 ─────────────────────────────────────────────────────
  int _localCount = 0;
  String? _lastSyncTime;
  int _syncProgress = 0;
  int _syncTotal = 0;
  StreamSubscription<SyncEvent>? _syncSub;
  String? _pendingQuickAction;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground =
        lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.hidden &&
        lifecycle != AppLifecycleState.detached;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _init();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStatusPolling();
    _closeWs();
    _syncSub?.cancel();
    _queueController.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        // 상태 확인·폴링은 Client(크롤링) 전용. 초기 로딩 중이면 _init 이 폴링을 시작한다.
        if (_isStandalone || _loading) return;
        _checkStatus();
        _startStatusPolling();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _stopStatusPolling();
      case AppLifecycleState.inactive:
        break;
    }
  }

  bool get _isStandalone =>
      context.read<ReportProvider>().appMode == AppMode.standalone;

  ApiService? _api() {
    final p = context.read<ReportProvider>();
    final factory = widget.apiFactory;
    if (factory != null) return factory(p);
    if (p.baseUrl.isEmpty) return null;
    return ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
  }

  Future<void> _init() async {
    if (!mounted) return;
    if (_isStandalone) {
      await _loadStandaloneInfo();
    } else {
      await _loadConfig();
      if (!mounted) return;
      await _checkStatus();
      if (!mounted) return;
      _startStatusPolling();
    }
    if (!mounted) return;
    await _runPendingQuickActionIfNeeded();
  }

  Future<void> handleQuickAction(String eventType) async {
    if (!mounted) return;
    if (eventType != 'quick_sync' && eventType != 'quick_crawl') return;
    if (_loading) {
      _pendingQuickAction = eventType;
      return;
    }
    await _executeQuickAction(eventType);
  }

  Future<void> _runPendingQuickActionIfNeeded() async {
    final pending = _pendingQuickAction;
    if (pending == null) return;
    _pendingQuickAction = null;
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      handleQuickAction(pending);
    });
  }

  Future<void> _executeQuickAction(String eventType) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    switch (eventType) {
      case 'quick_sync':
        if (!_isStandalone) return;
        if (context.read<ReportProvider>().isStandaloneDemo) {
          if (messenger != null) {
            showSrSnackOn(messenger, '데모 모드에서는 동기화를 실행할 수 없습니다.');
          }
          return;
        }
        if (SyncEngine.isRunning || _isRunning) {
          if (messenger != null) showSrSnackOn(messenger, '이미 동기화가 진행 중입니다.');
          return;
        }
        await _startSync(fullSync: false);
        return;
      case 'quick_crawl':
        if (_isStandalone) return;
        if (_isRunning) {
          if (messenger != null) showSrSnackOn(messenger, '이미 크롤링이 진행 중입니다.');
          return;
        }
        await _startCrawl();
        return;
    }
  }

  // ── 스탠드어론 ───────────────────────────────────────────────────────────────

  Future<void> _loadStandaloneInfo() async {
    int count = _localCount;
    String? syncTime = _lastSyncTime;
    String? loadError;
    try {
      // DB 가 다른 작업 (drainIfPending 의 upsert, refreshAll 의 computeSummary 등)
      // 으로 바쁘면 직렬 큐에서 대기. 10초 timeout 으로 spinner 영구 잠금 방지.
      count = await LocalDbService.getTotalCount().timeout(
        const Duration(seconds: 10),
      );
      syncTime = await SyncEngine.getLastSyncTime().timeout(
        const Duration(seconds: 10),
      );
    } catch (e) {
      loadError = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _localCount = count;
      _lastSyncTime = syncTime;
      _loading = false;
      if (loadError != null) {
        _logLines.add('[로드 지연/오류] $loadError');
      }
    });
    // 항상 구독 — drainIfPending 이 뒤늦게 시작하는 sync 이벤트도 수신
    if (_syncSub == null) _subscribeToSyncEvents();
    if (SyncEngine.isRunning) _setRunning(true);
  }

  void _subscribeToSyncEvents() {
    _syncSub?.cancel();
    _syncSub = SyncEngine.events.listen((event) {
      if (!mounted) return;
      setState(() {
        switch (event.type) {
          case SyncEventType.log:
            if (!_isRunning) _setRunning(true);
            _logLines.add(event.message);
            if (_logLines.length > 300) {
              _logLines.removeRange(0, _logLines.length - 300);
            }
          case SyncEventType.progress:
            if (!_isRunning) _setRunning(true);
            _syncProgress = event.current;
            _syncTotal = event.total;
          case SyncEventType.done:
            _setRunning(false);
            _syncProgress = event.current;
            _syncTotal = event.total;
            _loadStandaloneInfo();
            unawaited(context.read<ReportProvider>().refreshAll());
          case SyncEventType.error:
            _setRunning(false);
            _logLines.add('[오류] ${event.message}');
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });
  }

  Future<void> _startSync({required bool fullSync}) async {
    if (SyncEngine.isRunning) return;

    setState(() {
      _logLines.clear();
      _syncProgress = 0;
      _syncTotal = 0;
    });
    _setRunning(true);

    _subscribeToSyncEvents();

    SyncEngine.start(fullSync: fullSync);
  }

  void _stopSync() {
    SyncEngine.stop();
    _syncSub?.cancel();
    _setRunning(false);
  }

  // ── 서버 모드 ────────────────────────────────────────────────────────────────

  Future<void> _loadConfig() async {
    final api = _api();
    if (api == null) return;
    try {
      final cfg = await api.getCrawlConfig();
      if (!mounted) return;
      setState(() {
        // 최소 크롤링(min)은 레거시 전용이라 없앴다 — 예전 설정값 min 은 전체로 본다(서버와 같음)
        final mode = (cfg['crawl_mode'] ?? 'full').toString();
        _crawlMode = mode == 'reset' ? 'reset' : 'full';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _checkStatus() async {
    final api = _api();
    if (api == null) return;
    try {
      final status = await api.getCrawlStatus();
      if (!mounted) return;
      final running = status['running'] == true;
      final unresolved = CrawlUnresolved.fromStatus(status);
      if (!CrawlUnresolved.sameList(unresolved, _unresolved)) {
        setState(() => _unresolved = unresolved);
      }
      if (running && !_isRunning) _connectWs(api);
      if (!running && _isRunning) _closeWs();
      _setRunning(running);
    } catch (_) {}
  }

  /// 5초 상태 폴링. 화면이 살아 있고 앱이 보일 때만 돈다(복귀 시 didChangeAppLifecycleState 가 다시 켠다).
  void _startStatusPolling() {
    _stopStatusPolling();
    if (!mounted || !_foreground) return;
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _checkStatus();
    });
  }

  void _stopStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  /// 열린(또는 연결 중인) 로그 WebSocket 을 닫는다. 연결 중이던 소켓은 연결이 끝나는 즉시 닫힌다.
  void _closeWs() {
    _wsEpoch++;
    final ws = _ws;
    _ws = null;
    if (ws != null) unawaited(ws.close().catchError((_) {}));
  }

  Future<void> _connectWs(ApiService api) async {
    if (_ws != null || _wsConnecting) return;
    _wsConnecting = true;
    final epoch = _wsEpoch;
    final WebSocket ws;
    try {
      ws = await (widget.connectLogSocket ?? _connectLogSocket)(api);
    } catch (_) {
      _wsConnecting = false;
      return;
    }
    _wsConnecting = false;
    // 연결 중에 화면이 닫혔거나 크롤링이 끝났으면 늦게 열린 소켓을 남기지 않는다.
    if (!mounted || epoch != _wsEpoch || _ws != null) {
      unawaited(ws.close().catchError((_) {}));
      return;
    }
    _ws = ws;
    try {
      ws.listen(
        (data) {
          if (!mounted) return;
          final lines = data
              .toString()
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .toList();
          setState(() {
            _logLines.addAll(lines);
            if (_logLines.length > 200) {
              _logLines.removeRange(0, _logLines.length - 200);
            }
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_logScroll.hasClients) {
              _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
            }
          });
        },
        onDone: () {
          if (ws.closeCode == 4406) {
            _stopStatusPolling();
            ClientCompatibility.block(
              api.baseUrl,
              api.apiKey,
              ServerConnectionService.upgradeMessage(
                    jsonEncode({'code': ws.closeReason}),
                  ) ??
                  '앱과 PC 서버의 protocol 3 지원을 확인하고 업데이트하세요.',
            );
          }
          if (!identical(_ws, ws)) return;
          _ws = null;
          _setRunning(false);
        },
        onError: (_) {
          if (identical(_ws, ws)) _ws = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (identical(_ws, ws)) _ws = null;
    }
  }

  static Future<WebSocket> _connectLogSocket(ApiService api) async {
    await ClientCompatibility.ensure(api.baseUrl, api.apiKey);
    // 서버는 2026-09-26 부터 로그 WS 에 API 키(또는 관리자 세션)와 커뮤니티 게이트를 요구한다(미충족 4403).
    return WebSocket.connect(
      ServerContract.wsClientUri(
        api.baseUrl,
        api.apiKey,
        '/crawl/ws/logs',
      ).toString(),
    );
  }

  Future<void> _startCrawl() async {
    final api = _api();
    if (api == null) return;

    if (_crawlMode == 'reset') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('DB 초기화 경고'),
          content: const Text(
            'DB를 초기화하고 처음부터 새로 크롤링합니다.\n기존 데이터가 모두 삭제됩니다. 계속하시겠습니까?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('초기화 및 시작'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() {
      _logLines.clear();
      _logLines.add('크롤링 시작 중...');
    });
    _setRunning(true);
    final provider = context.read<ReportProvider>();

    try {
      await api.startCrawl(
        crawlMode: _crawlMode,
        queueList: _queueController.text,
      );
      if (!mounted) return;
      _connectWs(api);
    } catch (e) {
      if (!mounted) {
        // 시작 요청이 실패했는데 화면이 이미 닫혔다 — 대시보드의 진행 표시만 되돌린다.
        provider.setSyncing(false);
        return;
      }
      _setRunning(false);
      setState(() {
        _logLines.add('오류: $e');
      });
      showSrSnack(context, e.toString(), kind: SrSnackKind.error);
    }
  }

  Future<void> _killCrawl() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('강제 중지'),
        content: const Text('진행 중인 데이터는 저장되지 않습니다.\n정말 중지하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('강제 중지'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final api = _api();
    if (api == null) return;
    final provider = context.read<ReportProvider>();
    try {
      await api.killCrawl();
      if (!mounted) {
        provider.setSyncing(false);
        return;
      }
      _setRunning(false);
    } catch (e) {
      if (mounted) {
        showSrSnack(context, e.toString(), kind: SrSnackKind.error);
      }
    }
  }

  // ── 빌드 ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SyncExitGuard(
      child: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _isStandalone
          ? _buildStandalone()
          : _buildServer(),
    );
  }

  // ── 스탠드어론 UI ────────────────────────────────────────────────────────────

  Widget _buildStandalone() {
    final isDemo = context.select<ReportProvider, bool>(
      (p) => p.isStandaloneDemo,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('데이터 동기화'),
        actions: [
          const SettingsActionButton(),
        ],
      ),
      body: _withLogPanel(
        // 상태 카드는 내용 높이만 쓰고 남는 세로 공간은 로그 창이 받는다.
        topMaxFraction: 0.5,
        top: RefreshIndicator(
          onRefresh: _loadStandaloneInfo,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ReloginRequiredBanner(),
                _infoCard(),
                if (isDemo) ...[SizedBox(height: 12), _demoInfoCard()],
                SizedBox(height: 16),
                if (_isRunning && _syncTotal > 0) ...[
                  _progressBar(),
                  SizedBox(height: 16),
                ],
                _syncButtons(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 상단 제어 영역 + 로그 창. 상단은 내용 높이만 차지하되 [topMaxFraction] 을 넘으면 스크롤되고,
  /// 로그 창은 남은 높이를 모두 쓴다. 로그가 한 줄도 없으면 로그 창은 한 줄 높이로 접히고
  /// 상단이 남는 높이를 쓴다(SQ-U18). edge-to-edge 에서 로그 마지막 줄이 시스템 내비게이션 바에
  /// 가리지 않도록 하단 안전 영역 위에서 끝낸다.
  Widget _withLogPanel({required Widget top, required double topMaxFraction}) {
    final hasLogs = _logLines.isNotEmpty;
    // 로그가 생겨 배치가 바뀌어도 제어 영역(스크롤·입력 포커스) 상태를 유지한다.
    top = KeyedSubtree(key: _topAreaKey, child: top);
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            if (hasLogs)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * topMaxFraction,
                ),
                child: top,
              )
            else
              Expanded(child: top),
            const Divider(height: 1),
            if (hasLogs) Expanded(child: _logPanel()) else _logPanel(),
          ],
        ),
      ),
    );
  }

  Widget _infoCard() {
    final displayTime = _lastSyncTime != null
        ? _formatSyncTime(_lastSyncTime!)
        : '없음';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '마지막 동기화',
                    style: TextStyle(
                      fontSize: SrFontSize.caption,
                      color: context.sr.textSecondary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    displayTime,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '저장된 신고',
                  style: TextStyle(
                    fontSize: SrFontSize.caption,
                    color: context.sr.textSecondary,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '$_localCount건',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressBar() {
    final pct = _syncTotal > 0 ? _syncProgress / _syncTotal : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '상세 조회 중...',
              style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
            ),
            Text(
              '$_syncProgress / $_syncTotal',
              style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
            ),
          ],
        ),
        SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(SrRadius.sm),
          child: LinearProgressIndicator(value: pct, minHeight: 6),
        ),
      ],
    );
  }

  Widget _demoInfoCard() {
    return Card(
      color: context.tone(SrTone.warning).background,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.visibility_outlined,
              color: context.tone(SrTone.warning).foreground,
            ),
            SizedBox(width: 12),
            const Expanded(
              child: Text(
                '현재 Demo 보기 모드입니다. 동기화 없이 가상 신고 100건을 표시합니다.',
                style: TextStyle(height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _syncButtons() {
    final isDemo = context.select<ReportProvider, bool>(
      (p) => p.isStandaloneDemo,
    );
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            icon: Icon(Icons.sync),
            label: const Text('동기화'),
            onPressed: _isRunning || isDemo
                ? null
                : () => _startSync(fullSync: false),
          ),
        ),
        SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            icon: Icon(Icons.refresh),
            label: const Text('전체 재동기화'),
            onPressed: _isRunning || isDemo ? null : () => _confirmFullSync(),
          ),
        ),
        if (_isRunning) ...[
          SizedBox(width: 8),
          IconButton.filled(
            icon: Icon(Icons.stop),
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _stopSync,
            tooltip: '동기화 중지',
          ),
        ],
      ],
    );
  }

  Future<void> _confirmFullSync() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('전체 재동기화'),
        content: const Text(
          '모든 신고를 다시 받아 갱신하고 로컬 공유 사본을 새로 만듭니다. '
          '기존 수정값과 감시 목록, Supabase에 공유한 자료는 유지됩니다.\n계속하시겠습니까?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('재동기화'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) _startSync(fullSync: true);
  }

  String _formatSyncTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return '방금 전';
      if (diff.inHours < 1) return '${diff.inMinutes}분 전';
      if (diff.inDays < 1) return '${diff.inHours}시간 전';
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  // ── 서버 모드 UI ─────────────────────────────────────────────────────────────

  Widget _buildServer() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('크롤링 제어'),
        actions: [
          const SettingsActionButton(),
        ],
      ),
      body: _withLogPanel(
        // 크롤링 중에는 제어 영역을 줄이고(넘치면 스크롤) 로그 창을 넓힌다.
        topMaxFraction: _isRunning ? 0.4 : 0.6,
        top: RefreshIndicator(
          onRefresh: _init,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('1. 크롤링 범위'),
                RadioGroup<String>(
                  groupValue: _crawlMode,
                  onChanged: (v) {
                    if (v != null) setState(() => _crawlMode = v);
                  },
                  child: Column(
                    children: [
                      _radioTile('전체 크롤링', 'full', ''),
                      _radioTile('DB 초기화 후 새로 크롤링', 'reset', '', isRed: true),
                    ],
                  ),
                ),

                SizedBox(height: 12),

                _sectionTitle('2. 큐 (선택사항)'),
                if (_unresolved.isNotEmpty) _unresolvedNotice(),
                TextField(
                  controller: _queueController,
                  maxLines: 3,
                  style: TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'SPP-231120-1234567\nSPP-231121-7654321',
                    hintStyle: TextStyle(
                      fontSize: SrFontSize.caption,
                      color: context.sr.textSecondary,
                    ),
                  ),
                ),

                SizedBox(height: 16),

                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: Icon(Icons.play_arrow),
                        label: const Text('크롤링 시작'),
                        onPressed: _isRunning ? null : _startCrawl,
                      ),
                    ),
                    SizedBox(width: 8),
                    FilledButton.icon(
                      icon: Icon(Icons.stop),
                      label: const Text('강제 중지'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: _isRunning ? _killCrawl : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 공통 로그 패널 ───────────────────────────────────────────────────────────

  /// 로그 창은 앱 테마와 관계없이 늘 어둡다. 글자색은 이 배경을 기준으로 맞춘다(SQ-U18).
  static const _logPanelColor = SrColors.logPanel;
  static final Color _logTextColor = StatusTone.of(
    SrColors.dark.success,
    brightness: Brightness.dark,
    surface: _logPanelColor,
  ).foreground;
  static final Color _logMutedColor = SrColors.dark.textSecondary;
  static const double _logFontSize = 12;

  Widget _logPanel() {
    final hasLogs = _logLines.isNotEmpty;
    final header = Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, hasLogs ? 4 : 8),
      child: Row(
        children: [
          if (_isRunning) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _logTextColor,
              ),
            ),
            SizedBox(width: 8),
          ],
          Text(
            _isRunning ? '실행 중' : '대기 중',
            style: TextStyle(
              color: _isRunning ? _logTextColor : _logMutedColor,
              fontSize: _logFontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (!hasLogs) ...[
            const Spacer(),
            Text(
              '로그 없음',
              style: TextStyle(color: _logMutedColor, fontSize: _logFontSize),
            ),
          ],
        ],
      ),
    );
    return Container(
      key: const Key('crawl-log-panel'),
      color: _logPanelColor,
      child: !hasLogs
          ? header
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                Expanded(
                  child: ListView.builder(
                    controller: _logScroll,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: _logLines.length,
                    itemBuilder: (_, i) => Text(
                      _logLines[i],
                      style: TextStyle(
                        color: _logTextColor,
                        fontSize: _logFontSize,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ── 헬퍼 위젯 ────────────────────────────────────────────────────────────────

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 13,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  /// 서버 대기 큐에서 처리하지 못한 번호(최근 5개).
  Widget _unresolvedNotice() => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(SrRadius.md),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '처리하지 못한 신고번호',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
        for (final u in _unresolved.take(5))
          Text(
            '${u.number} — ${u.message}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
      ],
    ),
  );

  /// 선택 값·변경 처리는 감싼 [RadioGroup] 이 맡는다.
  Widget _radioTile(
    String title,
    String value,
    String subtitle, {
    bool enabled = true,
    bool isRed = false,
  }) {
    return RadioListTile<String>(
      title: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          color: isRed
              ? Theme.of(context).colorScheme.error
              : (enabled ? null : context.sr.textSecondary),
          fontWeight: isRed ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: subtitle.isNotEmpty
          ? Text(
              subtitle,
              style: TextStyle(
                fontSize: SrFontSize.caption,
                color: context.sr.textSecondary,
              ),
            )
          : null,
      value: value,
      enabled: enabled,
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }
}
