import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/community_server_link_service.dart';
import 'community_card_parts.dart';

/// 설정 > Client "서버의 커뮤니티 계정" 카드.
///
/// 서버가 인증·세션의 주인이다. 이 카드는 서버 API 만 부르고 Supabase 주소·토큰을 다루지 않는다.
/// 서버에 닿지 못하면 오류만 보이고 Standalone 로그인으로 바꾸지 않는다(M07).
/// 상태가 pending/confirm_required 이고 카드가 보이며 앱이 앞에 있을 때만 약 3초마다 새로 읽는다.
class CommunityServerAccountCard extends StatefulWidget {
  final String baseUrl;
  final String apiKey;
  final http.Client? client;
  final Future<bool> Function(Uri uri)? launcher;
  final Duration pollInterval;

  const CommunityServerAccountCard({
    super.key,
    required this.baseUrl,
    required this.apiKey,
    this.client,
    this.launcher,
    this.pollInterval = const Duration(seconds: 3),
  });

  @override
  State<CommunityServerAccountCard> createState() =>
      _CommunityServerAccountCardState();
}

class _CommunityServerAccountCardState extends State<CommunityServerAccountCard>
    with WidgetsBindingObserver {
  CommunityServerStatus? _status;
  CommunityServerError? _error;
  bool _loading = true;
  bool _busy = false;
  bool _foreground = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant CommunityServerAccountCard old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.apiKey != widget.apiKey) {
      _status = null;
      _error = null;
      _loading = true;
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    if (fg) {
      unawaited(_refresh());
    } else {
      _poll?.cancel();
    }
  }

  Future<void> _refresh() async {
    _poll?.cancel();
    final r = await CommunityServerLinkService.fetchStatus(
      baseUrl: widget.baseUrl,
      apiKey: widget.apiKey,
      client: widget.client,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.isOk) {
        _status = r.status;
        _error = null;
      } else {
        _error = r.error;
        // 404(구서버)·권한 없음이면 이전 상태를 버린다.
        if (r.error!.kind == CommunityServerErrorKind.unsupported ||
            r.error!.kind == CommunityServerErrorKind.permissionRequired) {
          _status = null;
        }
      }
    });
    _schedulePoll();
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (!mounted || !_foreground) return;
    if (_status?.needsPolling != true) return;
    _poll = Timer(widget.pollInterval, () {
      if (mounted) unawaited(_refresh());
    });
  }

  Future<void> _act(Future<CommunityServerResult> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    CommunityServerResult r;
    try {
      r = await call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    setState(() {
      if (r.isOk) {
        _status = r.status;
        _error = null;
      } else {
        _error = r.error;
      }
    });
    _schedulePoll();
  }

  Future<void> _start() async {
    await _act(
      () => CommunityServerLinkService.start(
        baseUrl: widget.baseUrl,
        apiKey: widget.apiKey,
        client: widget.client,
      ),
    );
    if (_error == null) await _openBrowser();
  }

  /// 1회용 연결 링크 — 로그·복사 없이 외부 브라우저로만 연다.
  Future<void> _openBrowser() async {
    final uri = _status?.pending?.safeBootstrapUri;
    if (uri == null) return;
    var ok = false;
    try {
      ok =
          await (widget.launcher ??
              (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      setState(
        () => _error = const CommunityServerError(
          CommunityServerErrorKind.server,
          message: '브라우저를 열지 못했습니다. 다시 시도해 주세요.',
        ),
      );
    }
  }

  Future<void> _confirm(String requestId) => _act(
    () => CommunityServerLinkService.confirm(
      baseUrl: widget.baseUrl,
      apiKey: widget.apiKey,
      requestId: requestId,
      client: widget.client,
    ),
  );

  Future<void> _cancel(String? requestId) => _act(
    () => CommunityServerLinkService.cancel(
      baseUrl: widget.baseUrl,
      apiKey: widget.apiKey,
      requestId: requestId,
      client: widget.client,
    ),
  );

  Future<void> _disconnect(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('서버의 커뮤니티 계정 연결 해제'),
        content: Text(
          '서버에 연결된 $name 계정을 해제합니다. 서버의 커뮤니티 업로드도 멈춥니다. '
          '신고 데이터는 지워지지 않습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('연결 해제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _act(
      () => CommunityServerLinkService.disconnect(
        baseUrl: widget.baseUrl,
        apiKey: widget.apiKey,
        client: widget.client,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: CommunityCardHeader(
                    icon: Icons.forum_outlined,
                    title: '서버의 커뮤니티 계정',
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  visualDensity: VisualDensity.compact,
                  tooltip: '새로고침',
                  onPressed: _busy ? null : _refresh,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '연결된 서버가 카카오 계정으로 커뮤니티 지도에 연결합니다. '
              '이 휴대폰에는 로그인 정보가 저장되지 않습니다.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ..._body(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurfaceVariant;
    final s = _status;
    final err = _error;
    final out = <Widget>[];

    if (_loading && s == null) {
      return [
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '상태 확인 중...',
                style: TextStyle(color: muted, fontSize: 13),
              ),
            ),
          ],
        ),
      ];
    }

    if (err != null) {
      out.addAll([
        CommunityNoticeBox(
          icon: err.kind == CommunityServerErrorKind.permissionRequired
              ? Icons.admin_panel_settings_outlined
              : Icons.error_outline,
          tone: err.kind == CommunityServerErrorKind.unsupported
              ? CommunityTone.neutral
              : CommunityTone.danger,
          text: err.message,
        ),
        const SizedBox(height: 10),
      ]);
    }
    if (s == null) {
      if (err != null && err.kind != CommunityServerErrorKind.unsupported) {
        out.add(
          CommunityButtonBar(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('다시 확인'),
                onPressed: _busy ? null : _refresh,
              ),
            ],
          ),
        );
      }
      return out;
    }

    const uploadNote = '계정 연결만으로 신고 데이터가 업로드되지는 않습니다.';
    final manage = s.canManage;
    Widget permissionNote() => const CommunityNoticeBox(
      icon: Icons.admin_panel_settings_outlined,
      text: CommunityServerError.permissionMessage,
    );

    switch (s.state) {
      case CommunityServerState.unconfigured:
        out.addAll([
          const CommunityStatusLine(label: '설정되지 않음'),
          const SizedBox(height: 8),
          Text(
            '서버에 커뮤니티 설정이 없습니다. 서버 관리자 화면에서 설정해 주세요.',
            style: TextStyle(color: muted, fontSize: 12.5),
          ),
        ]);
      case CommunityServerState.disabled:
        out.addAll([
          const CommunityStatusLine(label: '꺼짐'),
          const SizedBox(height: 8),
          Text(
            '서버에서 커뮤니티 기능이 꺼져 있습니다.',
            style: TextStyle(color: muted, fontSize: 12.5),
          ),
        ]);
      case CommunityServerState.disconnected:
        out.addAll([
          const CommunityStatusLine(label: '연결 안 됨'),
          const SizedBox(height: 12),
          if (manage)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.login, size: 18),
                label: const Text('카카오 계정으로 연결'),
                onPressed: _busy ? null : _start,
              ),
            )
          else
            permissionNote(),
          const SizedBox(height: 10),
          const CommunityNoticeBox(text: uploadNote),
        ]);
      case CommunityServerState.pending:
        final p = s.pending;
        out.addAll([
          const CommunityStatusLine(
            label: '연결 대기',
            tone: CommunityTone.attention,
          ),
          const SizedBox(height: 12),
          Text('비교코드', style: TextStyle(color: muted, fontSize: 12.5)),
          const SizedBox(height: 4),
          SelectableText(
            p?.displayCode.isNotEmpty == true ? p!.displayCode : '-',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '브라우저에서 비교코드가 같은지 확인하세요.',
            style: TextStyle(color: cs.onSurface, fontSize: 13),
          ),
          if (p?.expiresAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '요청 만료: ${formatCommunityTime(p!.expiresAt)}',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '연결 링크는 한 번만 쓰는 링크입니다. 다른 사람에게 보내지 마세요.',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (manage)
            CommunityButtonBar(
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _cancel(p?.requestId),
                  child: const Text('요청 취소'),
                ),
                if (p?.safeBootstrapUri != null)
                  FilledButton.icon(
                    icon: const Icon(Icons.open_in_browser, size: 18),
                    label: const Text('브라우저 열기'),
                    onPressed: _busy ? null : _openBrowser,
                  ),
              ],
            )
          else
            permissionNote(),
        ]);
      case CommunityServerState.confirmRequired:
        final c = s.candidate;
        out.addAll([
          const CommunityStatusLine(
            label: '계정 확인 필요',
            tone: CommunityTone.attention,
          ),
          const SizedBox(height: 10),
          Text(
            '연결된 서버를 확인해 주세요.',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          CommunityInfoRow(label: '서버가 확인한 계정', value: c?.displayName ?? '-'),
          if (c?.isDifferentAccount == true) ...[
            const SizedBox(height: 8),
            CommunityNoticeBox(
              icon: Icons.warning_amber_rounded,
              tone: CommunityTone.danger,
              text:
                  '서버에 지금 연결된 ${s.account?.displayName ?? '다른'} 계정이 '
                  '이 계정으로 바뀝니다.',
            ),
          ],
          const SizedBox(height: 12),
          if (manage && c != null)
            CommunityButtonBar(
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _cancel(c.requestId),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: _busy ? null : () => _confirm(c.requestId),
                  child: const Text('이 계정으로 연결'),
                ),
              ],
            )
          else if (!manage)
            permissionNote(),
        ]);
      case CommunityServerState.connected:
        final a = s.account;
        out.addAll([
          const CommunityStatusLine(label: '연결됨', tone: CommunityTone.positive),
          const SizedBox(height: 10),
          CommunityInfoRow(label: '계정', value: a?.displayName ?? '-'),
          CommunityInfoRow(
            label: '연결 시각',
            value: formatCommunityTime(a?.connectedAt),
          ),
          CommunityInfoRow(
            label: '커뮤니티 업로드',
            value: s.uploadEnabled ? '켜짐' : '꺼짐',
          ),
          const SizedBox(height: 12),
          if (manage)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('연결 해제'),
                onPressed: _busy
                    ? null
                    : () => _disconnect(a?.displayName ?? '이'),
              ),
            )
          else
            permissionNote(),
        ]);
      case CommunityServerState.reauthRequired:
      case CommunityServerState.storeUnreadable:
        final a = s.account;
        final reauth = s.state == CommunityServerState.reauthRequired;
        out.addAll([
          CommunityStatusLine(
            label: reauth ? '다시 로그인 필요' : '저장된 연결을 읽지 못함',
            tone: CommunityTone.danger,
          ),
          const SizedBox(height: 10),
          if (a != null) CommunityInfoRow(label: '계정', value: a.displayName),
          Text(
            reauth
                ? '서버의 커뮤니티 로그인이 만료되었거나 해제되었습니다. 다시 연결해 주세요.'
                : '서버가 저장된 커뮤니티 연결을 읽지 못했습니다. 다시 연결하거나 서버 관리자 화면을 확인해 주세요.',
            style: TextStyle(color: muted, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (manage)
            CommunityButtonBar(
              children: [
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _disconnect(a?.displayName ?? '이'),
                  child: const Text('연결 해제'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('다시 연결'),
                  onPressed: _busy ? null : _start,
                ),
              ],
            )
          else
            permissionNote(),
        ]);
      case CommunityServerState.unknown:
        out.addAll([
          const CommunityStatusLine(label: '알 수 없는 상태'),
          const SizedBox(height: 8),
          Text(
            '앱이 모르는 상태입니다. 앱을 업데이트해 주세요.',
            style: TextStyle(color: muted, fontSize: 12.5),
          ),
        ]);
    }
    final lastError = s.lastErrorMessage;
    if (lastError != null && lastError.isNotEmpty && err == null) {
      out.addAll([
        const SizedBox(height: 10),
        Text(
          '최근 오류: ${lastError.length > 200 ? '${lastError.substring(0, 200)}…' : lastError}',
          style: TextStyle(color: muted, fontSize: 12),
        ),
      ]);
    }
    return out;
  }
}
