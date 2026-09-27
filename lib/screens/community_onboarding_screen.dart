import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../community/gate/community_account_client.dart';
import '../community/gate/community_gate.dart';
import '../community/client_account_notice.dart';
import '../community/kakao_logout.dart';
import '../services/community_auth_service.dart';
import '../widgets/consent_markdown.dart';

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
    this.onNext,
    this.privacyLauncher,
    this.onReportsWiped,
    this.clientServer,
  });

  final CommunityGate? gate;
  final CommunityAuthService? auth;
  final CommunityAccountClient? accountClient;
  final Future<void> Function()? onNext;
  final Future<bool> Function(Uri uri)? privacyLauncher;

  /// 카카오 로그아웃·"지우고 이 계정으로 시작"으로 신고 자료를 지운 뒤(화면 목록 갱신용).
  final Future<void> Function()? onReportsWiped;

  /// Client 모드면 서버 주소·API 키 — 이 앱과 서버의 카카오 계정이 다르면 알린다([ClientAccountMismatchNotice]).
  final ({String baseUrl, String apiKey})? clientServer;

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

  /// 중앙이 내려준 지금 동의문(본문 해시 확인됨, 2026-09-27). 카카오 인증 전에는 받을 수 없다.
  CommunityPolicy? _policy;
  String? _policyError;
  bool _policyLoading = false;
  // 동의문은 처음부터 펼쳐 둔다 — 본문을 보지 않고 동의하지 않게(Codex 검수 P1).
  bool _consentExpanded = true;
  bool _nextBusy = false;
  String? _nextError;

  CommunityAuthService get _auth =>
      widget.auth ?? CommunityAuthService.instance;

  @override
  void initState() {
    super.initState();
    _auth.state.addListener(_onAuthChanged);
    _loadPolicy();
  }

  @override
  void dispose() {
    _auth.state.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (_kakaoOk && _policy == null && !_policyLoading) _loadPolicy();
  }

  /// 동의문은 앱에 넣어 두지 않고 중앙 `policy` 로 받는다. 카카오 인증 전에는 안내만 보인다.
  Future<void> _loadPolicy() async {
    final client = widget.accountClient;
    if (!_kakaoOk || client == null) {
      if (mounted) setState(() => _policy = null);
      return;
    }
    setState(() {
      _policyLoading = true;
      _policyError = null;
    });
    try {
      final token = await _auth.getAccessToken();
      if (token == null || token.isEmpty) {
        throw const CommunityAccountError(code: 'kakao_required', message: '먼저 카카오 인증을 완료해 주세요.');
      }
      final policy = await client.policy(accessToken: token);
      if (mounted) setState(() => _policy = policy);
    } on CommunityAccountError catch (e) {
      if (mounted) setState(() => _policyError = e.message);
    } catch (_) {
      if (mounted) setState(() => _policyError = '동의 문서를 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _policyLoading = false);
    }
  }

  /// 이 계정이 이미 지금 정책(버전·동의문 해시)에 동의해 있는가 — 다른 기기·서버에서 한 동의도 같은 카카오 계정이면 이어진다.
  bool get _consentActiveOnServer {
    final st = widget.gate?.lastStatus;
    return st != null &&
        st.consentState == 'active' &&
        st.requiredPolicyVersion.isNotEmpty &&
        st.consentPolicyVersion == st.requiredPolicyVersion &&
        st.grantConsentTextSha256 == st.consentTextSha256;
  }

  bool get _consentDone => _kakaoOk && (_consentSaved || _consentActiveOnServer);

  String get _docText {
    if (!_kakaoOk) return '카카오 인증을 마치면 동의 문서를 불러옵니다.';
    if (_policy != null) return _policy!.consentText;
    if (_policyError != null) return _policyError!;
    return '동의 문서를 불러오는 중...';
  }

  bool get _kakaoOk =>
      _auth.state.value.phase == CommunityAccountPhase.connected;

  bool get _canGoNext => _kakaoOk && _consentDone;

  String? get _blockedReason {
    if (!_kakaoOk && !_consentDone) return '카카오 인증과 신고내용 공유 동의를 모두 완료하면 다음 단계로 이동할 수 있습니다.';
    if (!_kakaoOk) return '카카오 인증을 완료하면 다음 단계로 이동할 수 있습니다.';
    if (!_consentDone) return '신고내용 공유 동의를 완료하면 다음 단계로 이동할 수 있습니다.';
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
      final policy = _policy;
      if (policy == null) {
        throw const CommunityAccountError(code: 'policy_missing', message: '동의 문서를 먼저 불러와 주세요.');
      }
      // 화면에 보인 본문의 (버전, 해시) 그대로 보낸다. 그 사이 중앙 정책이 바뀌었으면 policy_mismatch — 새 본문을 다시 보인다.
      await client.consent(
        accessToken: token,
        policyVersion: policy.version,
        consentTextSha256: policy.consentTextSha256,
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
      if (e.code == 'policy_mismatch') {
        if (mounted) {
          setState(() {
            _consentChecked = false;
            _policy = null;
            _consentError = '동의 문서가 바뀌었습니다. 새 문서를 확인한 뒤 다시 동의해 주세요.';
          });
        }
        await _loadPolicy();
      } else if (mounted) {
        setState(() => _consentError = e.message);
      }
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

  bool _ownerBusy = false;

  Future<void> _logout() async {
    final done = await KakaoLogout.confirmAndRun(
      context,
      gate: widget.gate,
      auth: _auth,
      afterWipe: widget.onReportsWiped,
    );
    if (done && mounted) {
      setState(() {
        _consentSaved = false;
        _consentChecked = false;
      });
    }
  }

  Future<void> _adopt() async {
    final gate = widget.gate;
    if (gate == null || _ownerBusy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이 계정으로 새로 시작'),
        content: const Text(
          '이 기기에 남아 있는 다른 카카오 계정의 신고 내역을 모두 지우고, 지금 로그인한 계정으로 새로 시작합니다. '
          '신고 내역은 안전신문고에서 처음부터 다시 불러옵니다(감시 목록은 남습니다).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('지우고 시작'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _ownerBusy = true);
    try {
      final error = await KakaoLogout.adopt(
        gate: gate,
        auth: _auth,
        afterWipe: widget.onReportsWiped,
      );
      if (error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      }
    } finally {
      if (mounted) setState(() => _ownerBusy = false);
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
          if (gateState == 'db_owner_mismatch') _ownerMismatchBox(context),
          _kakaoCard(context),
          if (gate != null && widget.clientServer != null && _kakaoOk)
            ClientAccountMismatchNotice(
              gate: gate,
              baseUrl: widget.clientServer!.baseUrl,
              apiKey: widget.clientServer!.apiKey,
            ),
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
                onPressed: _logout,
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
                  _consentDone ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: _consentDone
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
                  child: ConsentMarkdown(text: _docText),
                ),
              ),
            ],
            // 불러오지 못했으면 이 화면에서 다시 받을 수 있게(네트워크·요청 한도 뒤 막히지 않게 — Codex 검수 P2)
            if (_kakaoOk && _policy == null && _policyError != null && !_policyLoading)
              TextButton.icon(
                key: const Key('consentPolicyRetry'),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('동의 문서 다시 불러오기'),
                onPressed: _loadPolicy,
              ),
            CheckboxListTile(
              value: _consentChecked || _consentDone,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('위 내용을 모두 읽고 공유에 동의합니다.', style: TextStyle(fontSize: 13)),
              onChanged: _consentDone || _policy == null
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
                onPressed: _consentChecked && !_consentDone && _policy != null && !_consentBusy
                    ? _saveConsent
                    : null,
                child: _consentBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_consentDone ? '동의 완료' : '동의하고 계속'),
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

  /// 게이트 `db_owner_mismatch`: 이 기기의 신고 자료가 지금 로그인한 카카오 계정의 것이 아니다.
  Widget _ownerMismatchBox(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: const Key('communityOwnerMismatch'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '이 기기의 신고 내역은 다른 카카오 계정의 것입니다.',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: cs.error),
            ),
            const SizedBox(height: 4),
            const Text(
              '지금 계정으로 쓰려면 남아 있는 신고 내역을 지우고 새로 시작해야 합니다. '
              '원래 계정의 신고 내역을 지키려면 로그아웃한 뒤 원래 계정으로 로그인하세요.',
              style: TextStyle(fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton(
                  key: const Key('communityOwnerAdopt'),
                  onPressed: _ownerBusy ? null : _adopt,
                  child: const Text('신고 내역 지우고 이 계정으로 시작'),
                ),
                OutlinedButton(
                  key: const Key('communityOwnerLogout'),
                  onPressed: _ownerBusy ? null : _logout,
                  child: const Text('로그아웃(신고 내역 유지)'),
                ),
              ],
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
                  onPressed: _logout,
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
