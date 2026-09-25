// 지도 탭 공유 업로드 패널 (plan-final §8.4).
//
// PC 와 같은 문구·상태. 필터 바 아래 접이식 카드로 두고 지도 컨트롤·FAB 과
// 겹치지 않게 한다. 라이트·다크는 Theme colorScheme, 스크린리더 라벨·live region.
//
// Client 모드: `업로드는 연결된 서버가 수행합니다` + 서버 상태/실행.
// 서버 경로 상수는 T5 가 server_contract.dart 에 추가하므로 여기서는 두지 않고,
// [CommunityServerUploadClient] 로 주입받는다 (테스트는 가짜, T5 병합 후 연결).
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/app_mode.dart';
import '../../services/app_prefs_keys.dart';
import '../community/upload/community_schedule.dart';
import '../community/upload/community_uploader.dart';
import '../community/upload/upload_defaults.dart';

/// Client 모드 서버 업로드 상태 (T5 가 server_contract.dart 로 구현해 주입).
class CommunityServerUploadState {
  const CommunityServerUploadState({this.statusText, this.pending});
  final String? statusText;
  final int? pending;
}

abstract class CommunityServerUploadClient {
  Future<CommunityServerUploadState?> status();
  Future<void> run();
}

class CommunityPanelData {
  const CommunityPanelData({
    required this.clientMode,
    this.pending = 0,
    this.blocked = 0,
    this.deadLetter = 0,
    this.lastResult,
    this.lastFinishedAt,
    this.reshareCandidates = 0,
    this.lastProjection,
    this.serverState,
    this.error,
  });

  final bool clientMode;
  final int pending;
  final int blocked;
  final int deadLetter;
  final String? lastResult;
  final String? lastFinishedAt;
  final int reshareCandidates;
  final String? lastProjection;
  final CommunityServerUploadState? serverState;
  final String? error;
}

/// 패널 데이터 로드 (게이트 불필요 — 로컬 개수만 읽는다).
Future<CommunityPanelData> loadCommunityPanelData({
  CommunityServerUploadClient? serverClient,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final mode = AppModeX.fromString(prefs.getString(AppPrefsKeys.appMode));
    if (mode != AppMode.standalone) {
      CommunityServerUploadState? serverState;
      try {
        serverState = await serverClient?.status();
      } catch (_) {
        serverState = null;
      }
      return CommunityPanelData(clientMode: true, serverState: serverState);
    }
    final uploader = await buildDefaultUploader(gate: CacheGateCheck());
    final status = await uploader.uploadStatus();
    return CommunityPanelData(
      clientMode: false,
      pending: status.pending,
      blocked: status.blocked,
      deadLetter: status.deadLetter,
      lastResult: status.lastResult,
      lastFinishedAt: status.lastFinishedAt,
      reshareCandidates: status.reshareCandidateCount,
      lastProjection: status.lastProjection,
    );
  } catch (e) {
    return CommunityPanelData(clientMode: false, error: '$e');
  }
}

Future<String> runCommunityUploadNow() async {
  final uploader = await buildDefaultUploader(gate: CacheGateCheck());
  final result = await uploader.requestCommunityUpload('manual');
  return result.result;
}

Future<String> runCommunityReshareNow() async {
  final uploader = await buildDefaultUploader(gate: CacheGateCheck());
  final result = await uploader.requestReshare();
  return result.result;
}

/// 필터 바 아래에 두는 접이식 카드 호스트 (스스로 로드·새로고침).
class CommunityUploadPanelHost extends StatefulWidget {
  const CommunityUploadPanelHost({
    super.key,
    this.serverClient,
    this.loader = loadCommunityPanelData,
  });

  final CommunityServerUploadClient? serverClient;
  final Future<CommunityPanelData> Function(
      {CommunityServerUploadClient? serverClient}) loader;

  @override
  State<CommunityUploadPanelHost> createState() =>
      _CommunityUploadPanelHostState();
}

class _CommunityUploadPanelHostState extends State<CommunityUploadPanelHost> {
  CommunityPanelData? _data;
  var _running = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final data =
        await widget.loader(serverClient: widget.serverClient);
    if (!mounted) return;
    setState(() => _data = data);
  }

  Future<void> _uploadNow() async {
    setState(() {
      _running = true;
      _notice = null;
    });
    try {
      String result;
      if ((_data?.clientMode ?? false) && widget.serverClient != null) {
        await widget.serverClient!.run();
        result = 'requested';
      } else {
        result = await runCommunityUploadNow();
      }
      if (!mounted) return;
      setState(() => _notice = _runMessage(result));
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = '업로드 요청 실패: $e');
    } finally {
      if (mounted) setState(() => _running = false);
      await _reload();
    }
  }

  Future<void> _reshare() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이전 수집 사본 다시 공유'),
        content: Text(
            '재동의·기기 전환 뒤 이전에 수집한 사본 ${_data?.reshareCandidates ?? 0}건을 다시 공유합니다. 계속하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('다시 공유'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _running = true;
      _notice = null;
    });
    try {
      final result = await runCommunityReshareNow();
      if (!mounted) return;
      setState(() => _notice = _runMessage(result));
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = '다시 공유 실패: $e');
    } finally {
      if (mounted) setState(() => _running = false);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    return CommunityUploadPanel(
      data: data,
      running: _running,
      notice: _notice,
      onUploadNow: _uploadNow,
      onReshare: _reshare,
    );
  }
}

String _runMessage(String result) {
  switch (result) {
    case 'success':
      return '업로드 완료';
    case 'no_change':
      return '보낼 자료가 없습니다';
    case 'partial':
      return '일부만 전송됨(보류 확인)';
    case 'deferred':
      return '다음 기회에 전송합니다';
    case 'auth_required':
      return '커뮤니티 계정 확인이 필요합니다';
    case 'offline':
      return '네트워크 연결 후 전송합니다';
    case 'requested':
      return '서버에 업로드를 요청했습니다';
    default:
      return '전송 실패($result)';
  }
}

/// 접이식 카드 본체. 라이트·다크 대응, 스크린리더 라벨·live region.
class CommunityUploadPanel extends StatelessWidget {
  const CommunityUploadPanel({
    super.key,
    required this.data,
    this.running = false,
    this.notice,
    this.onUploadNow,
    this.onReshare,
  });

  final CommunityPanelData data;
  final bool running;
  final String? notice;
  final VoidCallback? onUploadNow;
  final VoidCallback? onReshare;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: '공유 업로드 상태',
      child: Card(
        margin: EdgeInsets.zero,
        color: cs.surfaceContainerLow,
        child: ExpansionTile(
          leading: const Icon(Icons.cloud_upload_outlined),
          title: Text(_summaryTitle(),
              semanticsLabel: '공유 업로드, ${_summaryTitle()}'),
          subtitle: data.clientMode ? null : Text(_summarySubtitle()),
          children: [
            Semantics(
              liveRegion: true,
              label: '공유 업로드 상세 상태',
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ..._detailLines().map((line) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(line,
                              style: Theme.of(context).textTheme.bodySmall),
                        )),
                    if (notice != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(notice!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.primary)),
                      ),
                    Row(
                      children: [
                        if (!data.clientMode || onUploadNow != null)
                          FilledButton.tonal(
                            onPressed:
                                running ? null : () => onUploadNow?.call(),
                            child: Text(running
                                ? '전송 중…'
                                : (data.clientMode ? '서버에서 업로드' : '지금 업로드')),
                          ),
                        if (!data.clientMode &&
                            data.reshareCandidates > 0) ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed:
                                running ? null : () => onReshare?.call(),
                            child: Text(
                                '이전 수집 사본 다시 공유(${data.reshareCandidates}건)'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _summaryTitle() {
    if (data.error != null) return '공유 업로드 확인 필요';
    if (data.clientMode) return '공유 업로드(서버)';
    if (data.pending > 0) return '전송 대기 ${data.pending}건';
    return '공유 업로드';
  }

  String _summarySubtitle() {
    if (data.lastProjection != null) {
      return projectionMessage(data.lastProjection);
    }
    if (data.lastResult != null) return _runMessage(data.lastResult!);
    return '전송 대기 없음';
  }

  List<String> _detailLines() {
    if (data.error != null) return ['상태를 읽지 못했습니다: ${data.error}'];
    if (data.clientMode) {
      return [
        '업로드는 연결된 서버가 수행합니다',
        if (data.serverState?.statusText != null)
          '서버: ${data.serverState!.statusText}',
      ];
    }
    final lines = <String>[
      '전송 대기 ${data.pending}건',
      if (data.lastProjection != null)
        '최근: ${projectionMessage(data.lastProjection)}',
      if (data.blocked > 0) '보류 ${data.blocked}건(사유 확인 필요)',
      if (data.deadLetter > 0) '전송 불가 ${data.deadLetter}건',
      if (data.lastFinishedAt != null) '마지막 전송: ${data.lastFinishedAt}',
    ];
    return lines;
  }
}
