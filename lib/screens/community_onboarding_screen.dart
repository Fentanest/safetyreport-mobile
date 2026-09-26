import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../community/gate/community_account_client.dart';
import '../community/gate/community_gate.dart';
import '../services/community_auth_service.dart';

/// 필수 게이트 온보딩: `[필수] 카카오 인증` + `[필수] 신고내용 공유 동의`.
///
/// - `다음` 은 둘 다 완료 전 비활성. 서버 재검증 실패 시 이동하지 않는다.
/// - 생략·연기 동작 없음. 도움말·개인정보·로그아웃·앱 종료는 항상 가능.
/// - Android back = 앱 종료 (`SystemNavigator.pop()`).
class CommunityOnboardingScreen extends StatefulWidget {
  const CommunityOnboardingScreen({
    super.key,
    this.gate,
    this.auth,
    this.accountClient,
    this.consentText,
    this.onNext,
    this.privacyLauncher,
  });

  final CommunityGate? gate;
  final CommunityAuthService? auth;
  final CommunityAccountClient? accountClient;
  final String? consentText;
  final Future<void> Function()? onNext;
  final Future<bool> Function(Uri uri)? privacyLauncher;

  @override
  State<CommunityOnboardingScreen> createState() =>
      _CommunityOnboardingScreenState();
}

const _privacyUrl = 'https://safeauth.worklazy.net/privacy.html';

class _CommunityOnboardingScreenState
    extends State<CommunityOnboardingScreen> {
  bool _consentChecked = false;
  bool _consentSaved = false;
  bool _consentBusy = false;
  String? _consentError;
  String? _loadedText;
  bool _consentExpanded = false;
  bool _nextBusy = false;
  String? _nextError;

  CommunityAuthService get _auth =>
      widget.auth ?? CommunityAuthService.instance;

  @override
  void initState() {
    super.initState();
    if (widget.consentText != null) {
      _loadedText = widget.consentText;
    } else {
      _loadConsentText();
    }
  }

  Future<void> _loadConsentText() async {
    try {
      final bundle = DefaultAssetBundle.of(context);
      final text = await bundle.loadString(
        'assets/community/share-consent-2026-09-26.1.md',
      );
      if (mounted) setState(() => _loadedText = text);
    } catch (_) {
      if (mounted) {
        setState(
          () => _loadedText = '동의문을 불러오지 못했습니다. 설정 > 도움말에서 확인해 주세요.',
        );
      }
    }
  }

  bool get _kakaoOk =>
      _auth.state.value.phase == CommunityAccountPhase.connected;

  bool get _canGoNext => _kakaoOk && _consentSaved;

  String? get _blockedReason {
    if (!_kakaoOk && !_consentSaved) return '카카오 인증과 신고내용 공유 동의를 모두 완료하면 다음 단계로 이동할 수 있습니다.';
    if (!_kakaoOk) return '카카오 인증을 완료하면 다음 단계로 이동할 수 있습니다.';
    if (!_consentSaved) return '신고내용 공유 동의를 완료하면 다음 단계로 이동할 수 있습니다.';
    return null;
  }

  Future<void> _saveConsent() async {
    final gate = widget.gate;
    final client = widget.accountClient;
    if (_consentBusy) return;
    setState(() {
      _consentBusy = true;
      _consentError = null;
    });
    try {
      if (client == null || gate == null) {
        throw const CommunityAccountError(
          code: 'unconfigured',
          message: '커뮤니티 서버 설정이 없어 동의를 저장할 수 없습니다.',
        );
      }
      final token = await _auth.getAccessToken();
      if (token == null || token.isEmpty) {
        throw const CommunityAccountError(
          code: 'kakao_required',
          message: '먼저 카카오 인증을 완료해 주세요.',
        );
      }
      await client.consent(
        accessToken: token,
        policyVersion: communityRequiredPolicyVersion,
        consentTextSha256: gate.lastStatus?.consentTextSha256 ?? '',
        via: gate.isStandalone ? 'mobile_standalone' : 'mobile_client',
      );
      await gate.refreshNow();
      if (!mounted) return;
      if (gate.lastStatus?.consentState == 'active') {
        setState(() => _consentSaved = true);
      } else {
        setState(
          () => _consentError = '동의 저장 뒤 서버 확인에 실패했습니다. 다시 시도해 주세요.',
        );
      }
    } on CommunityAccountError catch (e) {
      if (mounted) setState(() => _consentError = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _consentError = '동의 저장에 실패했습니다. 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) setState(() => _consentBusy = false);
    }
  }

  Future<void> _goNext() async {
    final gate = widget.gate;
    if (!_canGoNext || _nextBusy) return;
    setState(() {
      _nextBusy = true;
      _nextError = null;
    });
    try {
      if (gate != null) {
        await gate.requireFresh();
        if (!mounted) return;
        if (!gate.canEnter) {
          setState(() => _nextError = '서버에서 필수 설정을 확인하지 못했습니다. 다시 시도해 주세요.');
          return;
        }
      }
      await widget.onNext?.call();
    } finally {
      if (mounted) setState(() => _nextBusy = false);
    }
  }

  Future<void> _openPrivacy() async {
    final uri = Uri.parse(_privacyUrl);
    final launcher = widget.privacyLauncher;
    try {
      final ok = launcher != null
          ? await launcher(uri)
          : await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('브라우저를 열지 못했습니다.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('브라우저를 열지 못했습니다.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('서비스 이용을 위한 필수 설정'),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(
              tooltip: '도움말·개인정보',
              icon: const Icon(Icons.help_outline),
              onPressed: _openPrivacy,
            ),
            IconButton(
              tooltip: '앱 종료',
              icon: const Icon(Icons.close),
              onPressed: () => SystemNavigator.pop(),
            ),
          ],
        ),
        body: ListenableBuilder(
          listenable: Listenable.merge([
            _auth.state,
            if (widget.gate != null) widget.gate!,
          ]),
          builder: (context, _) => _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final gate = widget.gate;
    final gateState = gate?.state.state;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '카카오 인증과 신고내용 공유 동의를 모두 완료하면 다음 단계로 이동할 수 있습니다.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 16),
          if (gateState == 'config_invalid' ||
              gateState == 'verification_required' ||
              gate?.state.state == 'suspended')
            _recoveryBox(context, gate!),
          _kakaoCard(context),
          const SizedBox(height: 12),
          _consentCard(context),
          const SizedBox(height: 12),
          if (gate?.writerConflict != null) _writerConflictBox(context),
          if (gate?.manifestError != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  gate!.manifestError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (_blockedReason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _blockedReason!,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (_nextError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _nextError!,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          FilledButton(
            onPressed: _canGoNext && !_nextBusy ? _goNext : null,
            child: _nextBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('다음'),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.logout, size: 16),
                label: const Text('로그아웃'),
                onPressed: () async {
                  await _auth.disconnect();
                  gate?.invalidate('logout');
                  if (mounted) {
                    setState(() {
                      _consentSaved = false;
                      _consentChecked = false;
                    });
                  }
                },
              ),
              TextButton(
                onPressed: _openPrivacy,
                child: const Text('개인정보 처리 안내'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _requiredTag(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '[필수]',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      );

  Widget _kakaoCard(BuildContext context) {
    final st = _auth.state.value;
    final done = _kakaoOk;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _requiredTag(context),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '카카오 인증',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: done ? Colors.green : Theme.of(context).disabledColor,
                ),
              ],
            ),
            const SizedBox(height: 8),
            switch (st.phase) {
              CommunityAccountPhase.unconfigured => const Text(
                  '이 빌드에는 커뮤니티 서버 설정이 없어 연결할 수 없습니다.',
                  style: TextStyle(fontSize: 13),
                ),
              CommunityAccountPhase.connected => Text(
                  '연결된 계정: ${st.account?.displayName ?? '카카오 사용자'}',
                  style: const TextStyle(fontSize: 13),
                ),
              CommunityAccountPhase.awaitingBrowser => const Text(
                  '브라우저에서 카카오 로그인을 진행 중입니다.',
                  style: TextStyle(fontSize: 13),
                ),
              CommunityAccountPhase.exchanging => const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('계정 확인 중...', style: TextStyle(fontSize: 13)),
                  ],
                ),
              CommunityAccountPhase.confirmRequired => Text(
                  '로그인한 계정: ${st.candidate?.displayName ?? '카카오 사용자'} — 확인이 필요합니다.',
                  style: const TextStyle(fontSize: 13),
                ),
              CommunityAccountPhase.reauthRequired => const Text(
                  '로그인이 만료되었습니다. 다시 로그인해 주세요.',
                  style: TextStyle(fontSize: 13),
                ),
              CommunityAccountPhase.disconnected => Text(
                  st.notice ?? '카카오 계정으로 로그인합니다.',
                  style: const TextStyle(fontSize: 13),
                ),
            },
            if (st.phase == CommunityAccountPhase.confirmRequired) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: () => _auth.cancelCandidate(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _auth.confirmCandidate(),
                    child: const Text('이 계정으로 연결'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.login, size: 16),
                    label: Text(
                      done
                          ? '계정 변경'
                          : st.phase == CommunityAccountPhase.awaitingBrowser ||
                                  st.phase == CommunityAccountPhase.exchanging
                              ? '처리 중...'
                              : '카카오 계정으로 연결',
                    ),
                    onPressed:
                        st.phase == CommunityAccountPhase.exchanging
                            ? null
                            : () => _auth.startLogin(),
                  ),
                ),
                if (done) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _auth.startLogin(),
                    child: const Text('재시도'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _consentCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _requiredTag(context),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '신고내용 공유 동의',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                Icon(
                  _consentSaved ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: _consentSaved
                      ? Colors.green
                      : Theme.of(context).disabledColor,
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: Icon(
                _consentExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
              ),
              label: Text(_consentExpanded ? '동의문 접기' : '동의문 전문 보기'),
              onPressed: () =>
                  setState(() => _consentExpanded = !_consentExpanded),
            ),
            if (_consentExpanded) ...[
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _loadedText ?? '동의문을 불러오는 중...',
                    style: const TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                ),
              ),
            ],
            CheckboxListTile(
              value: _consentChecked,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('위 내용을 모두 읽고 공유에 동의합니다.', style: TextStyle(fontSize: 13)),
              onChanged: _consentSaved
                  ? null
                  : (v) => setState(() => _consentChecked = v ?? false),
            ),
            if (_consentError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _consentError!,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _consentChecked && !_consentSaved && !_consentBusy
                    ? _saveConsent
                    : null,
                child: _consentBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_consentSaved ? '동의 완료' : '동의하고 계속'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _writerConflictBox(BuildContext context) {
    final gate = widget.gate!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '다른 기기가 이 신고자 이름으로 업로드하고 있습니다.',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => gate.requestTakeover(),
              child: const Text('이 기기로 업로드 전환'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recoveryBox(BuildContext context, CommunityGate gate) {
    final s = gate.state.state;
    final title = switch (s) {
      'config_invalid' => '커뮤니티 서버 설정에 문제가 있습니다.',
      'suspended' => '커뮤니티 이용이 정지된 계정입니다.',
      _ => '서버에서 필수 설정을 확인하지 못했습니다.',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            if (gate.notice != null) ...[
              const SizedBox(height: 4),
              Text(gate.notice!, style: const TextStyle(fontSize: 12.5)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => gate.refreshNow(),
                  child: const Text('재시도'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await _auth.disconnect();
                    gate.invalidate('logout');
                  },
                  child: const Text('로그아웃'),
                ),
                OutlinedButton(
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('앱 종료'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
