import 'dart:async';

import 'package:flutter/material.dart';

import '../community/rebuild/community_rebuild.dart';
import '../services/community_auth_service.dart';
import '../services/community_server_link_service.dart';
import '../theme/sr_colors.dart';

/// 초기화 크롤링 안내·확인·진행 화면 (`contracts/community-ingest/rebuild.md`).
///
/// Standalone: 로컬 job. Client: 서버 job (`연결된 서버에서 초기화 크롤링을 진행합니다`).
/// 초기화 필요·진행 중 조회·설정·도움말은 허용되므로 AppBar 뒤로가기는 막지 않는다.
class CommunityRebuildScreen extends StatefulWidget {
  const CommunityRebuildScreen({
    super.key,
    this.rebuild,
    this.isClient = false,
    this.serverBaseUrl = '',
    this.serverApiKey = '',
    this.auth,
    this.serverClient,
    this.onDone,
  });

  final CommunityRebuild? rebuild;
  final bool isClient;
  final String serverBaseUrl;
  final String serverApiKey;
  final CommunityAuthService? auth;
  final CommunityServerRebuildClient? serverClient;
  final Future<void> Function()? onDone;

  @override
  State<CommunityRebuildScreen> createState() => _CommunityRebuildScreenState();
}

/// 서버 job 호출 자리 (테스트 주입용).
class CommunityServerRebuildClient {
  const CommunityServerRebuildClient();
  Future<CommunityGateLinkResult> fetch(
    String baseUrl,
    String apiKey,
    String? token,
  ) => CommunityServerLinkService.fetchCommunityRebuild(
    baseUrl: baseUrl,
    apiKey: apiKey,
    userToken: token,
  );
  Future<CommunityGateLinkResult> start(
    String baseUrl,
    String apiKey,
    String? token,
  ) => CommunityServerLinkService.startCommunityRebuild(
    baseUrl: baseUrl,
    apiKey: apiKey,
    userToken: token,
  );
  Future<CommunityGateLinkResult> resume(
    String baseUrl,
    String apiKey,
    String? token,
  ) => CommunityServerLinkService.resumeCommunityRebuild(
    baseUrl: baseUrl,
    apiKey: apiKey,
    userToken: token,
  );
}

const _phases = ['백업 준비', '전체 신고 확인', '상세 수집', '새 저장 구조 반영', '완료'];

class _CommunityRebuildScreenState extends State<CommunityRebuildScreen>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _done = false;
  Timer? _refreshTimer;
  String? _error;
  Map<String, dynamic>? _serverJob;
  bool _serverLoading = false;
  bool _permissionRequired = false;

  CommunityAuthService get _auth =>
      widget.auth ?? CommunityAuthService.instance;

  /// 이전 버전 DB 를 비운 기록(기존 사용자 안내). Standalone 은 로컬 판정, Client 는 서버 상태의 legacy_reset.
  Map<String, Object?>? get _legacyReset {
    if (widget.isClient) {
      final v = _serverJob?['legacy_reset'];
      return v is Map ? v.cast<String, Object?>() : null;
    }
    return widget.rebuild?.legacyReset;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.rebuild?.addListener(_onRebuild);
    if (!widget.isClient) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed &&
            widget.rebuild?.isExecuting == false) {
          unawaited(widget.rebuild?.refresh());
        }
      });
    }
    _init();
  }

  Future<void> _init() async {
    if (widget.isClient) {
      await _loadServer();
    } else {
      await widget.rebuild?.refresh();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.rebuild?.removeListener(_onRebuild);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !widget.isClient) {
      unawaited(widget.rebuild?.refresh());
    }
  }

  void _onRebuild() {
    if (mounted) setState(() {});
    final s = widget.rebuild?.state;
    if (!_done &&
        (s == RebuildStates.completed ||
            s == RebuildStates.completedWithGaps)) {
      _done = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pending = widget.rebuild?.pendingUploads;
        if (pending != null && pending > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('초기화 완료 · 공유 전송 대기 $pending건')),
          );
        }
        widget.onDone?.call();
      });
    }
  }

  Future<String?> _userToken() => _auth.getAccessToken();

  Future<void> _loadServer() async {
    setState(() {
      _serverLoading = true;
      _error = null;
    });
    try {
      final token = await _userToken();
      final res =
          await (widget.serverClient ?? const CommunityServerRebuildClient())
              .fetch(widget.serverBaseUrl, widget.serverApiKey, token);
      if (!mounted) return;
      if (res.isOk) {
        setState(() {
          _serverJob = res.data;
          _permissionRequired = false;
        });
        // 서버가 초기화 필요 없음(완료했거나 새 설치)이라고 하면 이 화면에 머물지 않는다.
        // 예전엔 완료된 서버에서도 앱을 켤 때마다 시작 버튼을 눌러야 했다.
        if (res.data?['required'] == false) await widget.onDone?.call();
      } else if (res.needsPermission) {
        setState(() {
          _serverJob = null;
          _permissionRequired = true;
        });
      } else if (res.needsOnboarding) {
        setState(() => _error = '서버에서 커뮤니티 설정을 먼저 완료해야 합니다.');
      } else {
        setState(() => _error = res.message ?? '서버 상태를 확인하지 못했습니다.');
      }
    } finally {
      if (mounted) setState(() => _serverLoading = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '작업 상태를 확인하지 못했습니다. 상태를 다시 확인해 주세요.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isClient && _permissionRequired) {
      return Scaffold(
        appBar: AppBar(title: const Text('서버 권한 확인')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    CommunityGateLinkResult.permissionMessage,
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
              if (_error != null) Text(_error!),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _serverLoading ? null : _loadServer,
                child: Text(_serverLoading ? '확인 중...' : '상태 다시 확인'),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('초기화 크롤링')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.isClient)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '연결된 서버에서 초기화 크롤링을 진행합니다. 이 기기에서는 전수 수집을 하지 않습니다.',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  communityRebuildGuideText,
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _legacyReset == null
                      ? communityRebuildPreservedText
                      : '$communityRebuildLegacyText'
                            '${_legacyReset!['backup'] == null ? '' : '\n백업: ${_legacyReset!['backup']}'}',
                  key: const Key('rebuildPreservedText'),
                  style: const TextStyle(fontSize: 12.5, height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (widget.isClient) _serverBody() else _localBody(),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _phaseRow(String state, {bool? listComplete}) {
    final activeIndex = switch (state) {
      RebuildStates.preparingBackup => 0,
      RebuildStates.running => listComplete == false ? 1 : 2,
      RebuildStates.validating => 3,
      RebuildStates.committing => 3,
      RebuildStates.completed || RebuildStates.completedWithGaps => 4,
      _ => -1,
    };
    return Column(
      children: [
        for (var i = 0; i < _phases.length; i++)
          ListTile(
            dense: true,
            leading: Icon(
              i < activeIndex || activeIndex == 4
                  ? Icons.check_circle
                  : i == activeIndex
                  ? Icons.sync
                  : Icons.radio_button_unchecked,
              color: i <= activeIndex ? context.semantic(SrTone.success) : null,
              size: 20,
            ),
            title: Text(_phases[i], style: const TextStyle(fontSize: 13)),
          ),
      ],
    );
  }

  Widget _localBody() {
    final rebuild = widget.rebuild;
    if (rebuild == null) return const SizedBox.shrink();
    final counts = rebuild.counts();
    final failed = counts['failed_permanent'] ?? 0;
    final executing = rebuild.isExecuting;
    final unavailable = _busy || executing || rebuild.waitingForWorker;
    final remaining =
        (counts['pending'] ?? 0) + (counts['failed_retryable'] ?? 0);
    final at = rebuild.lastProgressAt?.toLocal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '상태: ${rebuild.stopping
                      ? '중단 확인 중'
                      : rebuild.waitingForWorker
                      ? '다른 작업 종료 확인 중'
                      : _stateLabel(rebuild.state)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (rebuild.job?['backup_ref'] != null)
                  Text(
                    '백업: ${rebuild.job!['backup_ref']}',
                    style: const TextStyle(fontSize: 12),
                  ),
                Text(
                  rebuild.countsKnown
                      ? '성공 ${counts['fetched'] ?? 0}건 · 실패 $failed건 · 남은 $remaining건\n'
                            '보존된 기존 행 ${counts['orphan_preserved'] ?? 0}건'
                      : '진행 건수 확인 중...',
                  style: const TextStyle(fontSize: 12.5),
                ),
                if (at != null)
                  Text(
                    '마지막 진행: ${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
                    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 12),
                  ),
                if (rebuild.notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      rebuild.notice!,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                const SizedBox(height: 8),
                _phaseRow(
                  rebuild.state,
                  listComplete: rebuild.job?['list_complete'] == 1,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (executing)
          OutlinedButton(
            onPressed: rebuild.stopping ? null : () => rebuild.requestPause(),
            child: Text(rebuild.stopping ? '중단 확인 중...' : '일시정지'),
          ),
        if (!executing && !RebuildStates.terminalOk.contains(rebuild.state))
          FilledButton(
            onPressed: unavailable
                ? null
                : () => _run(() async {
                    await rebuild.start(confirmedBy: 'user');
                  }),
            child: Text(
              unavailable
                  ? '작업 확인 중...'
                  : rebuild.state == RebuildStates.required ||
                        rebuild.state == RebuildStates.prerequisitesRequired
                  ? '확인 — 초기화 크롤링 시작'
                  : '이어서 진행',
            ),
          ),
        if (failed > 0 && rebuild.state == RebuildStates.validating)
          OutlinedButton(
            onPressed: unavailable
                ? null
                : () => _run(() => rebuild.acceptGaps()),
            child: Text('누락 $failed건을 확인하고 계속'),
          ),
        TextButton(
          onPressed: () => _run(() => rebuild.refresh()),
          child: const Text('상태 다시 확인'),
        ),
      ],
    );
  }

  Widget _serverBody() {
    if (_serverLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final job = _serverJob;
    final state = job?['state']?.toString() ?? 'required';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '상태: ${_stateLabel(state)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _phaseRow(state),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final token = await _userToken();
                  final client =
                      widget.serverClient ??
                      const CommunityServerRebuildClient();
                  final res = state == 'paused'
                      ? await client.resume(
                          widget.serverBaseUrl,
                          widget.serverApiKey,
                          token,
                        )
                      : await client.start(
                          widget.serverBaseUrl,
                          widget.serverApiKey,
                          token,
                        );
                  if (!mounted) return;
                  if (res.isOk) {
                    setState(() => _serverJob = res.data);
                    final s = res.data?['state']?.toString();
                    if (s == 'completed' || s == 'completed_with_gaps') {
                      await widget.onDone?.call();
                    }
                  } else {
                    setState(() => _error = res.message ?? '서버 초기화에 실패했습니다.');
                  }
                }),
          child: Text(_busy ? '진행 중...' : '확인 — 초기화 크롤링 시작'),
        ),
      ],
    );
  }

  String _stateLabel(String state) => switch (state) {
    RebuildStates.required => '필요',
    RebuildStates.prerequisitesRequired => '준비 필요',
    RebuildStates.awaitingConfirmation => '확인 대기',
    RebuildStates.preparingBackup => '백업 준비',
    RebuildStates.running => '전체 신고 확인·상세 수집 중',
    RebuildStates.validating => '검증 중',
    RebuildStates.committing => '새 저장 구조 반영 중',
    RebuildStates.completed => '완료',
    RebuildStates.completedWithGaps => '완료(일부 누락 수락)',
    RebuildStates.paused => '일시정지',
    RebuildStates.failed => '실패',
    _ => state,
  };
}
