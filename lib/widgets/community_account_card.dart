import 'dart:async';

import 'package:flutter/material.dart';

import '../services/community_auth_service.dart';
import 'community_card_parts.dart';

/// 앱 전체에서 한 번만 쓰는 전역 키 — 로그인 복귀 링크는 어느 화면에서나 올 수 있어서
/// 계정 확인 창·안내를 루트 Navigator/ScaffoldMessenger 로 띄운다(`main.dart` 의 MaterialApp).
final communityAuthNavigatorKey = GlobalKey<NavigatorState>();
final communityAuthMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// 설정 > Standalone "커뮤니티 계정" 카드.
class CommunityAccountCard extends StatefulWidget {
  final CommunityAuthService? service;
  const CommunityAccountCard({super.key, this.service});

  @override
  State<CommunityAccountCard> createState() => _CommunityAccountCardState();
}

class _CommunityAccountCardState extends State<CommunityAccountCard> {
  CommunityAuthService get _svc =>
      widget.service ?? CommunityAuthService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_svc.load());
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDisconnect(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('커뮤니티 계정 연결 해제'),
        content: Text(
          '$name 계정 연결을 이 기기에서 해제합니다. '
          '다른 기기의 로그인과 안전신문고 계정·신고 데이터는 그대로입니다.',
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
    if (ok == true) await _run(() => _svc.disconnect());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ValueListenableBuilder<CommunityAuthState>(
          valueListenable: _svc.state,
          builder: (context, st, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CommunityCardHeader(
                  icon: Icons.forum_outlined,
                  title: '커뮤니티 계정',
                ),
                const SizedBox(height: 4),
                Text(
                  '카카오 계정으로 커뮤니티 지도에 연결합니다. 안전신문고 계정과는 별개입니다.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                ..._body(context, st),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, CommunityAuthState st) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurfaceVariant;
    const uploadNote = '계정 연결만으로 신고 데이터가 업로드되지는 않습니다.';
    switch (st.phase) {
      case CommunityAccountPhase.unconfigured:
        return [
          const CommunityStatusLine(label: '설정되지 않음'),
          const SizedBox(height: 8),
          Text(
            '이 빌드에는 커뮤니티 서버 설정이 없어 연결할 수 없습니다.',
            style: TextStyle(color: muted, fontSize: 12.5),
          ),
        ];
      case CommunityAccountPhase.disconnected:
        return [
          const CommunityStatusLine(label: '연결 안 됨'),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.login, size: 18),
              label: const Text('카카오 계정으로 연결'),
              onPressed: _busy ? null : () => _run(_svc.startLogin),
            ),
          ),
          const SizedBox(height: 10),
          const CommunityNoticeBox(text: uploadNote),
        ];
      case CommunityAccountPhase.awaitingBrowser:
        return [
          const CommunityStatusLine(
            label: '브라우저 로그인 대기',
            tone: CommunityTone.attention,
          ),
          const SizedBox(height: 8),
          Text(
            '브라우저에서 카카오 로그인을 마치면 앱으로 돌아옵니다. '
            '돌아오지 않으면 로그인을 다시 시작해 주세요.',
            style: TextStyle(color: muted, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          CommunityButtonBar(
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => _run(_svc.cancelPendingLogin),
                child: const Text('취소'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_browser, size: 18),
                label: const Text('다시 시작'),
                onPressed: _busy ? null : () => _run(_svc.startLogin),
              ),
            ],
          ),
        ];
      case CommunityAccountPhase.exchanging:
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
                  '계정 확인 중...',
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              ),
            ],
          ),
        ];
      case CommunityAccountPhase.confirmRequired:
        final c = st.candidate;
        return [
          const CommunityStatusLine(
            label: '계정 확인',
            tone: CommunityTone.attention,
          ),
          const SizedBox(height: 10),
          CommunityInfoRow(label: '로그인한 계정', value: c?.displayName ?? '-'),
          if (c?.isDifferentAccount == true) ...[
            const SizedBox(height: 8),
            CommunityNoticeBox(
              icon: Icons.warning_amber_rounded,
              tone: CommunityTone.danger,
              text:
                  '지금 연결된 ${st.account?.displayName ?? '다른'} 계정이 '
                  '이 계정으로 바뀝니다.',
            ),
          ],
          const SizedBox(height: 12),
          CommunityButtonBar(
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => _run(_svc.cancelCandidate),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await _svc.confirmCandidate();
                      }),
                child: const Text('이 계정으로 연결'),
              ),
            ],
          ),
        ];
      case CommunityAccountPhase.connected:
        final a = st.account;
        return [
          const CommunityStatusLine(label: '연결됨', tone: CommunityTone.positive),
          const SizedBox(height: 10),
          CommunityInfoRow(label: '계정', value: a?.displayName ?? '-'),
          CommunityInfoRow(
            label: '연결 시각',
            value: formatCommunityTime(a?.connectedAt),
          ),
          const SizedBox(height: 8),
          Text(uploadNote, style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('연결 해제'),
              onPressed: _busy
                  ? null
                  : () => _confirmDisconnect(a?.displayName ?? '이'),
            ),
          ),
        ];
      case CommunityAccountPhase.reauthRequired:
        final a = st.account;
        return [
          const CommunityStatusLine(
            label: '다시 로그인 필요',
            tone: CommunityTone.danger,
          ),
          const SizedBox(height: 10),
          if (a != null) CommunityInfoRow(label: '계정', value: a.displayName),
          Text(
            '로그인이 만료되었거나 해제되었습니다. 카카오 계정으로 다시 로그인해 주세요.',
            style: TextStyle(color: muted, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          CommunityButtonBar(
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _confirmDisconnect(a?.displayName ?? '이'),
                child: const Text('연결 해제'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.login, size: 18),
                label: const Text('다시 로그인'),
                onPressed: _busy ? null : () => _run(_svc.startLogin),
              ),
            ],
          ),
        ];
    }
  }
}

/// 어느 화면에서든 로그인 복귀 뒤 "이 계정으로 연결" 확인 창과 안내를 띄운다.
/// `MaterialApp.builder` 로 앱 전체를 감싼다(Navigator 바깥이므로 전역 키를 쓴다).
class CommunityAuthPrompt extends StatefulWidget {
  final Widget child;
  final CommunityAuthService? service;
  const CommunityAuthPrompt({super.key, required this.child, this.service});

  @override
  State<CommunityAuthPrompt> createState() => _CommunityAuthPromptState();
}

class _CommunityAuthPromptState extends State<CommunityAuthPrompt> {
  CommunityAuthService get _svc =>
      widget.service ?? CommunityAuthService.instance;
  int _seenNotice = 0;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _seenNotice = _svc.state.value.noticeSerial;
    _svc.state.addListener(_onState);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onState());
  }

  @override
  void dispose() {
    _svc.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final st = _svc.state.value;
    if (st.noticeSerial != _seenNotice) {
      _seenNotice = st.noticeSerial;
      final notice = st.notice;
      if (notice != null) {
        communityAuthMessengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(notice)));
      }
    }
    if (st.phase == CommunityAccountPhase.confirmRequired &&
        st.candidate != null &&
        !_dialogOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showConfirm());
    }
  }

  Future<void> _showConfirm() async {
    if (_dialogOpen) return;
    final st = _svc.state.value;
    final c = st.candidate;
    final ctx = communityAuthNavigatorKey.currentContext;
    if (c == null ||
        ctx == null ||
        st.phase != CommunityAccountPhase.confirmRequired) {
      return;
    }
    _dialogOpen = true;
    try {
      final ok = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (dctx) => CommunityConfirmDialog(
          displayName: c.displayName,
          replacingName: c.isDifferentAccount
              ? (st.account?.displayName ?? '다른')
              : null,
        ),
      );
      // 창이 떠 있는 동안 카드에서 먼저 처리했으면 아무것도 안 한다(서비스가 무시).
      if (ok == true) {
        await _svc.confirmCandidate();
      } else if (ok == false) {
        await _svc.cancelCandidate();
      }
    } finally {
      _dialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 계정 확인 창(Standalone 복귀 직후). 뒤로 가기로 닫히지 않는다 — 둘 중 하나를 고른다.
class CommunityConfirmDialog extends StatelessWidget {
  final String displayName;
  final String? replacingName;
  const CommunityConfirmDialog({
    super.key,
    required this.displayName,
    this.replacingName,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('이 계정으로 연결할까요?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommunityInfoRow(label: '카카오 계정', value: displayName),
              const SizedBox(height: 8),
              if (replacingName != null) ...[
                CommunityNoticeBox(
                  icon: Icons.warning_amber_rounded,
                  tone: CommunityTone.danger,
                  text: '지금 연결된 $replacingName 계정이 이 계정으로 바뀝니다.',
                ),
                const SizedBox(height: 8),
              ],
              const Text(
                '계정 연결만으로 신고 데이터가 업로드되지는 않습니다.',
                style: TextStyle(fontSize: 12.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('이 계정으로 연결'),
          ),
        ],
      ),
    );
  }
}
