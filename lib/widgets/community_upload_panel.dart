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
import '../community/community_wiring.dart';

import '../../models/app_mode.dart';
import '../../services/app_prefs_keys.dart';
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
    this.blockedReasons = const {},
    this.deadLetter = 0,
    this.lastResult,
    this.lastFinishedAt,
    this.reshareCandidates = 0,
    this.lastProjection,
    this.serverState,
    this.error,
    this.authRequired = 0,
    this.quarantined = 0,
    this.stored = 0,
    this.published = 0,
    this.oldestUnsentAt,
    this.nextRetryAt,
    this.lastCentralAckAt,
    this.controlState = 'ready',
    this.controlUntil,
    this.controlReason,
    this.lastRequest,
  });

  final bool clientMode;
  final int pending;
  final int blocked;
  final Map<String, int> blockedReasons;
  final int deadLetter;
  final String? lastResult;
  final String? lastFinishedAt;
  final int reshareCandidates;
  final String? lastProjection;
  final CommunityServerUploadState? serverState;
  final String? error;
  final int authRequired;
  final int quarantined;
  final int stored;
  final int published;

  /// UTC ISO 시각(표시할 때 한국 시간으로).
  final String? oldestUnsentAt;
  final String? nextRetryAt;
  final String? lastCentralAckAt;
  final String controlState;
  final String? controlUntil;
  final String? controlReason;
  final String? lastRequest;
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
    final uploader = await buildDefaultUploader(gate: CommunityWiring.gateCheck());
    final status = await uploader.uploadStatus();
    return CommunityPanelData(
      clientMode: false,
      pending: status.pending,
      blocked: status.blocked,
      blockedReasons: status.blockedReasons,
      deadLetter: status.deadLetter,
      lastResult: status.lastResult,
      lastFinishedAt: status.lastFinishedAt,
      reshareCandidates: status.reshareCandidateCount,
      lastProjection: status.lastProjection,
      authRequired: status.authRequired,
      quarantined: status.quarantined,
      stored: status.stored,
      published: status.published,
      oldestUnsentAt: status.oldestUnsentAt,
      nextRetryAt: status.nextRetryAt,
      lastCentralAckAt: status.lastCentralAckAt,
      controlState: status.controlState,
      controlUntil: status.controlUntil,
      controlReason: status.controlReason,
      lastRequest: status.lastRequest,
    );
  } catch (e) {
    return CommunityPanelData(clientMode: false, error: '$e');
  }
}

/// 수동 업로드 → 사용자 문구(PC 지도 패널과 같은 문구).
Future<String> runCommunityUploadNow() async {
  final uploader = await buildDefaultUploader(gate: CommunityWiring.gateCheck());
  return uploadRunMessage(await uploader.requestCommunityUpload('manual'));
}

Future<String> runCommunityReshareNow() async {
  final uploader = await buildDefaultUploader(gate: CommunityWiring.gateCheck());
  return uploadRunMessage(await uploader.requestReshare());
}

String uploadRunMessage(UploadRunResult result) {
  var text = runMessage(result.result);
  if (result.result == 'cooldown' && result.nextAttemptAt != null) text += ' (${kstLabel(result.nextAttemptAt)}까지)';
  if (result.errorCode != null && result.result != 'sent' && result.result != 'no_pending') {
    text += ' · ${uploadErrorText(result.errorCode)}';
  }
  return text;
}

/// UTC ISO → 한국 시간 'YYYY-MM-DD HH:mm'. 읽을 수 없으면 원문.
String kstLabel(String? iso) {
  if (iso == null) return '';
  final t = DateTime.tryParse(iso);
  if (t == null) return iso;
  final k = t.toUtc().add(const Duration(hours: 9));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${k.year}-${two(k.month)}-${two(k.day)} ${two(k.hour)}:${two(k.minute)}';
}

/// 확인된 코드만 사람이 읽는 말로(원인을 추정하지 않는다 — PC ERROR_TEXT 와 같음).
String uploadErrorText(String? code) {
  if (code == null || code.isEmpty) return '';
  const known = {
    'rate_limited': '요청이 많아 서버가 잠시 대기를 요청함(429)',
    'busy': '서버 혼잡(503)',
    'service_unavailable': '서비스 일시 중단(503)',
    'server_error': '서버 일시 오류(500)',
    'offline': '네트워크 연결 실패',
    'invalid_ack': '서버 응답 형식 이상',
    'ack_missing': '일부 응답 누락',
    'auth_unavailable': '인증 서버 연결 실패',
    'blocked:cross_account_mismatch': '다른 계정의 같은 신고와 처리상태 외 내용이 달라 이전할 수 없음',
    'blocked:report_identity_mismatch': '같은 링크 ID의 신고번호가 다르거나 이전 계정에 신고번호가 없어 이전할 수 없음',
    'blocked:ambiguous_existing_owners': '기존 소유 계정이 여럿이라 자동 이전할 수 없음',
  };
  final hit = known[code];
  if (hit != null) return hit;
  final http = RegExp(r'^http_(\d{3})$').firstMatch(code);
  if (http != null) return '서버 일시 오류(HTTP ${http.group(1)})';
  return '오류 $code';
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
        result = runMessage('requested');
      } else {
        result = await runCommunityUploadNow();
      }
      if (!mounted) return;
      setState(() => _notice = result);
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
      setState(() => _notice = result);
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

/// 실행 결과 코드 → 문구. 새 코드(UC-1)와 예전 기록의 코드를 모두 읽는다(PC RESULT_TEXT 와 같음).
String runMessage(String result) {
  switch (result) {
    case 'sent':
    case 'success':
      return '중앙 저장 확인';
    case 'no_pending':
    case 'no_change':
      return '보낼 미전송 자료가 없습니다';
    case 'not_due':
      return '미전송 자료는 다음 재시도 시각에 보냅니다';
    case 'more_pending':
      return '남은 자료를 이어서 보냅니다';
    case 'partial':
      return '일부만 저장 확인 — 확인이 필요한 항목이 있습니다';
    case 'cooldown':
      return '서버가 일시적으로 요청을 받지 못해 잠시 기다립니다';
    case 'deferred':
      return '다음 기회에 다시 시도합니다';
    case 'busy_other_run':
      return '다른 업로드가 진행 중입니다';
    case 'blocked_gate':
      return '커뮤니티 연결 확인 뒤 보냅니다';
    case 'needs_auth':
    case 'auth_required':
      return '인증 필요 — 커뮤니티 계정을 다시 연결해 주세요';
    case 'needs_consent':
    case 'consent_required':
      return '공유 동의 확인 필요';
    case 'connection_required':
      return '연결 확인 필요';
    case 'offline':
      return '네트워크 연결 후 전송합니다';
    case 'requested':
      return '서버에 업로드를 요청했습니다';
    default:
      return '실패($result)';
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
    if (data.controlState == 'cooling_down') {
      return '서버가 일시적으로 요청을 받지 못해 ${kstLabel(data.controlUntil)}까지 기다립니다';
    }
    if (data.authRequired > 0) return '커뮤니티 계정 인증이 필요합니다';
    if (data.lastProjection != null) {
      return projectionMessage(data.lastProjection);
    }
    if (data.lastResult != null) return runMessage(data.lastResult!);
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
      if (data.authRequired > 0) '인증 필요 ${data.authRequired}건 — 다시 연결하면 대기 중인 자료를 그대로 보냅니다',
      if (data.controlState == 'cooling_down')
        '서버 대기: ${kstLabel(data.controlUntil)}까지'
            '${data.controlReason == null ? '' : ' · ${uploadErrorText(data.controlReason)}'}',
      if (data.oldestUnsentAt != null) '가장 오래된 미전송: ${kstLabel(data.oldestUnsentAt)}',
      if (data.nextRetryAt != null) '다음 재시도: ${kstLabel(data.nextRetryAt)}',
      data.lastCentralAckAt != null
          ? '마지막 중앙 저장 확인: ${kstLabel(data.lastCentralAckAt)}'
          : '중앙 저장 확인 기록 없음',
      if (data.stored > 0) '중앙 저장 ${data.stored}건 중 지도 반영 ${data.published}건',
      if (data.quarantined > 0) '중앙 보관·지도 미반영 ${data.quarantined}건(확인 필요)',
      if (data.lastProjection != null)
        '최근: ${projectionMessage(data.lastProjection)}',
      if (data.blocked > 0) '보류 ${data.blocked}건(사유 확인 필요)',
      for (final entry in data.blockedReasons.entries)
        if (entry.value > 0) '${uploadErrorText(entry.key)} ${entry.value}건',
      if (data.deadLetter > 0) '전송 불가 ${data.deadLetter}건',
      if (data.lastFinishedAt != null)
        '마지막 전송: ${kstLabel(data.lastFinishedAt)}'
            '${data.lastResult == null ? '' : ' · ${runMessage(data.lastResult!)}'}'
            '${data.lastRequest == null ? '' : ' · 추적 ${data.lastRequest}'}',
      '(한국 시간)',
    ];
    return lines;
  }
}
