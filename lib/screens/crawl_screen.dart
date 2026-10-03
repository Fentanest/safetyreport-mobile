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
import 'settings_screen.dart';
import '../theme/sr_colors.dart';

class CrawlScreen extends StatefulWidget {
  const CrawlScreen({super.key});

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
    if (_isRunning == val) return;
    setState(() => _isRunning = val);
    if (mounted) context.read<ReportProvider>().setSyncing(val);
  }

  bool _loading = true;

  WebSocket? _ws;
  final List<String> _logLines = [];
  final ScrollController _logScroll = ScrollController();
  Timer? _statusTimer;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _ws?.close();
    _syncSub?.cancel();
    _queueController.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatus();
    } else if (state == AppLifecycleState.paused) {
      _statusTimer?.cancel();
    }
  }

  bool get _isStandalone =>
      context.read<ReportProvider>().appMode == AppMode.standalone;

  ApiService? _api() {
    final p = context.read<ReportProvider>();
    if (p.baseUrl.isEmpty) return null;
    return ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
  }

  Future<void> _init() async {
    if (_isStandalone) {
      await _loadStandaloneInfo();
    } else {
      await _loadConfig();
      await _checkStatus();
      _startStatusPolling();
    }
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
          messenger?.showSnackBar(
            SnackBar(content: Text('데모 모드에서는 동기화를 실행할 수 없습니다.')),
          );
          return;
        }
        if (SyncEngine.isRunning || _isRunning) {
          messenger?.showSnackBar(SnackBar(content: Text('이미 동기화가 진행 중입니다.')));
          return;
        }
        await _startSync(fullSync: false);
        return;
      case 'quick_crawl':
        if (_isStandalone) return;
        if (_isRunning) {
          messenger?.showSnackBar(SnackBar(content: Text('이미 크롤링이 진행 중입니다.')));
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
      setState(() {
        // 최소 크롤링(min)은 레거시 전용이라 없앴다 — 예전 설정값 min 은 전체로 본다(서버와 같음)
        final mode = (cfg['crawl_mode'] ?? 'full').toString();
        _crawlMode = mode == 'reset' ? 'reset' : 'full';
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _checkStatus() async {
    final api = _api();
    if (api == null) return;
    try {
      final status = await api.getCrawlStatus();
      final running = status['running'] == true;
      final unresolved = CrawlUnresolved.fromStatus(status);
      if (mounted && !CrawlUnresolved.sameList(unresolved, _unresolved)) {
        setState(() => _unresolved = unresolved);
      }
      if (running && !_isRunning) _connectWs(api);
      if (!running && _isRunning) {
        _ws?.close();
        _ws = null;
      }
      if (mounted) _setRunning(running);
    } catch (_) {}
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkStatus(),
    );
  }

  void _connectWs(ApiService api) async {
    if (_ws != null) return;
    try {
      await ClientCompatibility.ensure(api.baseUrl, api.apiKey);
      // 서버는 2026-09-26 부터 로그 WS 에 API 키(또는 관리자 세션)와 커뮤니티 게이트를 요구한다(미충족 4403).
      _ws = await WebSocket.connect(
        ServerContract.wsClientUri(
          api.baseUrl,
          api.apiKey,
          '/crawl/ws/logs',
        ).toString(),
      );
      _ws!.listen(
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
          if (_ws?.closeCode == 4406) {
            _statusTimer?.cancel();
            ClientCompatibility.block(
              api.baseUrl,
              api.apiKey,
              ServerConnectionService.upgradeMessage(
                    jsonEncode({'code': _ws?.closeReason}),
                  ) ??
                  '앱과 PC 서버의 protocol 3 지원을 확인하고 업데이트하세요.',
            );
          }
          _ws = null;
          if (mounted) _setRunning(false);
        },
        onError: (_) => _ws = null,
        cancelOnError: true,
      );
    } catch (_) {
      _ws = null;
    }
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
      if (ok != true) return;
    }

    setState(() {
      _logLines.clear();
      _logLines.add('크롤링 시작 중...');
    });
    _setRunning(true);

    try {
      await api.startCrawl(
        crawlMode: _crawlMode,
        queueList: _queueController.text,
      );
      _connectWs(api);
    } catch (e) {
      _setRunning(false);
      setState(() {
        _logLines.add('오류: $e');
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
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
    if (ok != true) return;

    final api = _api();
    if (api == null) return;
    try {
      await api.killCrawl();
      _setRunning(false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
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
    final isDemo = context.watch<ReportProvider>().isStandaloneDemo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('데이터 동기화'),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
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
  /// 로그 창은 남은 높이를 모두 쓴다. edge-to-edge 에서 로그 마지막 줄이 시스템 내비게이션 바에
  /// 가리지 않도록 하단 안전 영역 위에서 끝낸다.
  Widget _withLogPanel({required Widget top, required double topMaxFraction}) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * topMaxFraction,
              ),
              child: top,
            ),
            const Divider(height: 1),
            Expanded(child: _logPanel()),
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
                      fontSize: 11,
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
                    fontSize: 11,
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
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: pct, minHeight: 6),
        ),
      ],
    );
  }

  Widget _demoInfoCard() {
    return Card(
      color: StatusTone.of(
        StatusTone.of(
          Colors.orange,
          brightness: Theme.of(context).brightness,
          surface: context.sr.surface,
        ).foreground,
        brightness: Theme.of(context).brightness,
        surface: context.sr.surface,
      ).background,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.visibility_outlined,
              color: StatusTone.of(
                StatusTone.of(
                  Colors.orange,
                  brightness: Theme.of(context).brightness,
                  surface: context.sr.surface,
                ).foreground,
                brightness: Theme.of(context).brightness,
                surface: context.sr.surface,
              ).foreground,
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
    final isDemo = context.watch<ReportProvider>().isStandaloneDemo;
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
    if (ok == true) _startSync(fullSync: true);
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
          IconButton(
            icon: Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
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
                      fontSize: 11,
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

  Widget _logPanel() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                if (_isRunning) ...[
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: StatusTone.of(
                        Colors.green,
                        brightness: Theme.of(context).brightness,
                        surface: context.sr.surface,
                      ).foreground,
                    ),
                  ),
                  SizedBox(width: 8),
                ],
                Text(
                  _isRunning ? '실행 중' : '대기 중',
                  style: TextStyle(
                    color: _isRunning
                        ? StatusTone.of(
                            Colors.green,
                            brightness: Theme.of(context).brightness,
                            surface: context.sr.surface,
                          ).foreground
                        : context.sr.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _logLines.isEmpty
                ? Center(
                    child: Text(
                      '로그 없음',
                      style: TextStyle(
                        color: context.sr.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _logScroll,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: _logLines.length,
                    itemBuilder: (_, i) => Text(
                      _logLines[i],
                      style: TextStyle(
                        color: StatusTone.of(
                          Colors.green,
                          brightness: Theme.of(context).brightness,
                          surface: context.sr.surface,
                        ).foreground,
                        fontSize: 10.5,
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
      borderRadius: BorderRadius.circular(8),
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
              style: TextStyle(fontSize: 11, color: context.sr.textSecondary),
            )
          : null,
      value: value,
      enabled: enabled,
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }
}
