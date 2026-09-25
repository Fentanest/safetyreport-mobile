import 'package:flutter/material.dart';

import '../community/rebuild/community_rebuild.dart';
import '../services/community_auth_service.dart';
import '../services/community_server_link_service.dart';

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
  Future<CommunityGateLinkResult> fetch(String baseUrl, String apiKey, String? token) =>
      CommunityServerLinkService.fetchCommunityRebuild(
        baseUrl: baseUrl,
        apiKey: apiKey,
        userToken: token,
      );
  Future<CommunityGateLinkResult> start(String baseUrl, String apiKey, String? token) =>
      CommunityServerLinkService.startCommunityRebuild(
        baseUrl: baseUrl,
        apiKey: apiKey,
        userToken: token,
      );
  Future<CommunityGateLinkResult> resume(String baseUrl, String apiKey, String? token) =>
      CommunityServerLinkService.resumeCommunityRebuild(
        baseUrl: baseUrl,
        apiKey: apiKey,
        userToken: token,
      );
}

const _phases = ['백업 준비', '전체 신고 확인', '상세 수집', '새 저장 구조 반영', '완료'];

class _CommunityRebuildScreenState extends State<CommunityRebuildScreen> {
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _serverJob;
  bool _serverLoading = false;

  CommunityAuthService get _auth =>
      widget.auth ?? CommunityAuthService.instance;

  @override
  void initState() {
    super.initState();
    widget.rebuild?.addListener(_onRebuild);
    _init();
  }

  Future<void> _init() async {
    if (widget.isClient) {
      await _loadServer();
    } else {
      await widget.rebuild?.load();
    }
  }

  @override
  void dispose() {
    widget.rebuild?.removeListener(_onRebuild);
    super.dispose();
  }

  void _onRebuild() {
    if (mounted) setState(() {});
    final s = widget.rebuild?.state;
    if (s == RebuildStates.completed || s == RebuildStates.completedWithGaps) {
      widget.onDone?.call();
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
      final res = await (widget.serverClient ?? const CommunityServerRebuildClient())
          .fetch(widget.serverBaseUrl, widget.serverApiKey, token);
      if (!mounted) return;
      if (res.isOk) {
        setState(() => _serverJob = res.data);
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  communityRebuildPreservedText,
                  style: TextStyle(fontSize: 12.5, height: 1.5),
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

  Widget _phaseRow(String state) {
    final activeIndex = switch (state) {
      RebuildStates.preparingBackup => 0,
      RebuildStates.running => 2,
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
              color: i <= activeIndex ? Colors.green : null,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('상태: ${_stateLabel(rebuild.state)}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                if (rebuild.job?['backup_ref'] != null)
                  Text('백업: ${rebuild.job!['backup_ref']}',
                      style: const TextStyle(fontSize: 12)),
                Text(
                  '성공 ${counts['fetched'] ?? 0}건 · 실패 $failed건 · '
                  '보존된 기존 행 ${counts['orphan_preserved'] ?? 0}건',
                  style: const TextStyle(fontSize: 12.5),
                ),
                if (rebuild.notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(rebuild.notice!, style: const TextStyle(fontSize: 12.5)),
                  ),
                const SizedBox(height: 8),
                _phaseRow(rebuild.state),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (rebuild.state == RebuildStates.required ||
            rebuild.state == RebuildStates.prerequisitesRequired ||
            rebuild.state == RebuildStates.awaitingConfirmation ||
            rebuild.state == RebuildStates.failed ||
            rebuild.state == RebuildStates.paused)
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      final ok = await rebuild.start(confirmedBy: 'user');
                      if (!ok && mounted && rebuild.notice != null) {
                        setState(() => _error = rebuild.notice);
                      }
                    }),
            child: Text(_busy ? '진행 중...' : '확인 — 초기화 크롤링 시작'),
          ),
        if (failed > 0 &&
            (rebuild.state == RebuildStates.validating || rebuild.state == RebuildStates.failed))
          OutlinedButton(
            onPressed: _busy ? null : () => _run(() => rebuild.acceptGaps()),
            child: Text('누락 $failed건을 확인하고 계속'),
          ),
        if (rebuild.state == RebuildStates.paused)
          OutlinedButton(
            onPressed: _busy ? null : () => _run(() => rebuild.resume()),
            child: const Text('일시정지된 초기화 계속'),
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
                Text('상태: ${_stateLabel(state)}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
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
                        widget.serverClient ?? const CommunityServerRebuildClient();
                    final res = state == 'paused'
                        ? await client.resume(
                            widget.serverBaseUrl, widget.serverApiKey, token)
                        : await client.start(
                            widget.serverBaseUrl, widget.serverApiKey, token);
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
