import 'package:flutter/material.dart';

import '../services/community_server_link_service.dart';
import 'gate/community_gate.dart';

/// Client 모드: 이 앱에 로그인한 카카오 계정과 서버(PC·Docker)에 연결된 카카오 계정이 다르면 알린다.
///
/// 동의·공유는 카카오 계정마다 따로다. 같은 계정이면 서버에서 한 동의가 이 앱에도 그대로 적용되고,
/// 다른 계정이면 이 앱 계정으로 따로 동의해야 한다(2026-09-27). 비교는 계정 지문(`account.fingerprint`)으로만 한다.
class ClientAccountMismatchNotice extends StatefulWidget {
  const ClientAccountMismatchNotice({
    super.key,
    required this.gate,
    required this.baseUrl,
    required this.apiKey,
    this.fetchServerGate,
  });

  final CommunityGate gate;
  final String baseUrl;
  final String apiKey;

  /// 시험용 주입(기본 [CommunityServerLinkService.fetchCommunityGate]).
  final Future<CommunityGateLinkResult> Function()? fetchServerGate;

  @override
  State<ClientAccountMismatchNotice> createState() => _ClientAccountMismatchNoticeState();
}

class _ClientAccountMismatchNoticeState extends State<ClientAccountMismatchNotice> {
  String? _serverFingerprint;
  String? _serverName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await (widget.fetchServerGate ??
          () => CommunityServerLinkService.fetchCommunityGate(baseUrl: widget.baseUrl, apiKey: widget.apiKey))();
      final account = res.data?['account'];
      if (!mounted || account is! Map) return;
      setState(() {
        _serverFingerprint = account['fingerprint'] as String?;
        _serverName = account['display_name'] as String?;
      });
    } catch (_) {
      // 서버를 확인하지 못하면 안내하지 않는다(판단 근거 없음).
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.gate,
      builder: (context, _) {
        final phone = widget.gate.lastStatus;
        if (!serverAccountMismatch(phone?.fingerprint, _serverFingerprint)) {
          return const SizedBox.shrink();
        }
        final cs = Theme.of(context).colorScheme;
        final phoneName = phone?.displayName;
        return Card(
          key: const Key('clientAccountMismatch'),
          color: cs.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '서버에 연결된 카카오 계정이 이 앱의 카카오 계정과 다릅니다.',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: cs.onErrorContainer),
                ),
                const SizedBox(height: 4),
                Text(
                  '서버: ${_serverName ?? '카카오 사용자'} / 이 앱: ${phoneName ?? '카카오 사용자'}\n'
                  '같은 계정으로 로그인하면 서버에서 한 동의가 그대로 적용됩니다. '
                  '다른 계정이면 이 앱의 계정으로 따로 동의해야 하고, 신고 내역·공유는 서버 계정 기준입니다.',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: cs.onErrorContainer),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
