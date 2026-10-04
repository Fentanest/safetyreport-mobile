import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/report_provider.dart';
import '../models/app_mode.dart';
import '../services/app_prefs_keys.dart';
import '../services/local_db_service.dart';
import '../services/pending_db_import_action.dart';
import '../services/server_connection_service.dart';
import '../services/standalone_auth_service.dart';
import '../theme/sr_colors.dart';
import '../widgets/sr_snack_bar.dart';
import '../theme/sr_tokens.dart';

enum _Step { selectMode, serverConfig, standaloneConfig }

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, this.initialMode, this.onModeSelected});

  final AppMode? initialMode;
  final ValueChanged<AppMode>? onModeSelected;

  /// 테스트에서 실제 안전신문고 로그인 대신 쓰는 함수. null 이면 [StandaloneAuthService.login].
  @visibleForTesting
  static Future<void> Function(String username, String password)?
  standaloneLoginOverride;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late _Step _step;

  @override
  void initState() {
    super.initState();
    _step = switch (widget.initialMode) {
      AppMode.server => _Step.serverConfig,
      AppMode.standalone => _Step.standaloneConfig,
      null => _Step.selectMode,
    };
  }

  final _urlController = TextEditingController();
  final _apiController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _obscurePw = true;
  bool _loading = false;

  /// 로그인 뒤 대기 DB 가져오기 중(버튼 문구용).
  bool _importing = false;
  String? _errorMessage;

  bool _isPlayReviewDemoLogin(
    String username,
    String password,
    String rawPhone,
  ) {
    return LocalDbService.isPlayReviewDemoLogin(
      username: username,
      password: password,
      rawPhone: rawPhone,
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _goToStep(_Step step) {
    setState(() {
      _step = step;
      _errorMessage = null;
    });
  }

  void _selectMode(AppMode mode) {
    if (widget.onModeSelected != null) {
      widget.onModeSelected!(mode);
    } else {
      _goToStep(
        mode == AppMode.server ? _Step.serverConfig : _Step.standaloneConfig,
      );
    }
  }

  Future<void> _enterDemo() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      await LocalDbService.seedPlayReviewDemo();
      if (!mounted) return;
      final provider = context.read<ReportProvider>();
      await provider.setStandaloneConfig(
        LocalDbService.playReviewDemoUsername,
        phoneNumber: LocalDbService.playReviewDemoPhone,
        isDemoMode: true,
      );
      await provider.refreshAll();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppPrefsKeys.pendingDbImport);
      _finishSetup();
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '데모 데이터 준비 실패: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _finishSetup() {
    if (!mounted) return;
    // 모드 전환에서는 설정 화면 위에 SetupScreen이 push된다. 루트 흐름으로 돌아간다.
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.popUntil((route) => route.isFirst);
  }

  Future<void> _connectServer() async {
    final url = _urlController.text.trim();
    final key = _apiController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() => _errorMessage = '서버 URL과 API Key를 모두 입력해주세요.');
      return;
    }
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final result = await ServerConnectionService.testConnection(
        baseUrl: url,
        apiKey: key,
      );
      if (!mounted) return;
      if (!result.isOk) {
        setState(() => _errorMessage = result.message ?? '서버에 연결할 수 없습니다.');
        return;
      }
      await context.read<ReportProvider>().setConfig(result.normalizedUrl, key);
      // 루트의 설정 완료 흐름이 다음 화면을 선택한다. 권한 화면을 다시 쌓지 않는다.
      _finishSetup();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = '서버에 연결할 수 없습니다.\n$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loginStandalone() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final rawPhone = _phoneController.text.trim();
    final phoneNumber = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
    if (_isPlayReviewDemoLogin(username, password, rawPhone)) {
      await _enterDemo();
      return;
    }
    if (username.isEmpty || password.isEmpty || phoneNumber.isEmpty) {
      setState(() => _errorMessage = '아이디, 비밀번호, 휴대폰번호를 모두 입력해주세요.');
      return;
    }
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final loginOverride = SetupScreen.standaloneLoginOverride;
      if (loginOverride != null) {
        await loginOverride(username, password);
      } else {
        await StandaloneAuthService.login(username, password);
      }
      if (!mounted) return;
      final provider = context.read<ReportProvider>();
      final messenger = ScaffoldMessenger.of(context);
      // 모드 전환 시 settings_screen 이 저장한 pending_db_import 를 Standalone 모드를 켜기 **전에** 적용한다
      // (Client → Standalone 의 '서버 DB 변환' 또는 '백업 파일 사용' 선택 결과, SQ-B03).
      // setStandaloneConfig 가 먼저면 루트가 곧바로 게이트 통과 흐름(drain·자동 동기화·초기화 판정)을 시작해
      // 빈 DB 에 먼저 쓰거나 가져오기를 "작업 중"으로 거절시킬 수 있다. 모드가 꺼진 동안에는 그런 작업이 없다.
      final imported = await _applyPendingDbImport();
      if (imported.status == PendingDbImportStatus.kept) {
        // 결정을 받지 못했다(화면이 닫힘 등). 대기 작업을 남기고 모드도 켜지 않는다 — 다음 로그인에서 다시 시도.
        if (mounted) {
          setState(
            () => _errorMessage =
                'DB 가져오기를 마치지 못해 Standalone 모드를 켜지 않았습니다. 다시 로그인하면 다시 시도합니다.',
          );
        }
        return;
      }
      await provider.setStandaloneConfig(username, phoneNumber: phoneNumber);
      _showImportOutcome(messenger, imported);
      if (imported.status == PendingDbImportStatus.applied) {
        unawaited(provider.refreshAll());
      }
      // 설정 저장 후 루트가 다음 화면을 선택한다.
      _finishSetup();
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = e.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _importing = false;
        });
      }
    }
  }

  /// `pending_db_import` 키에 저장된 [PendingDbImportAction] 을 적용한다.
  /// 성공하거나 사용자가 버릴 때만 지운다. 실패하면 남긴 채 "다시 시도 / 버리기"를 묻는다(SQ-B03).
  Future<PendingDbImportOutcome> _applyPendingDbImport() async {
    if (mounted) setState(() => _importing = true);
    return PendingDbImportAction.applyPending(
      onFailure: (action, error) async {
        if (!mounted) return null;
        return showDialog<PendingDbImportFailureChoice>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('DB 가져오기 실패'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(error.toString().replaceFirst('Exception: ', '')),
                    const SizedBox(height: 12),
                    const Text('가져올 파일'),
                    SelectableText(action.path),
                    const SizedBox(height: 12),
                    const Text(
                      '다시 시도하면 같은 파일로 다시 가져옵니다. '
                      '버리면 빈 DB 로 시작하고, 파일은 위 위치에 그대로 남습니다.',
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(ctx, PendingDbImportFailureChoice.discard),
                  child: const Text('버리고 빈 DB로 시작'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(ctx, PendingDbImportFailureChoice.retry),
                  child: const Text('다시 시도'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 가져오기 결과 안내. 모드를 켠 뒤 이 화면이 사라져도 보이도록 미리 잡아 둔 [messenger] 로 띄운다.
  void _showImportOutcome(
    ScaffoldMessengerState messenger,
    PendingDbImportOutcome outcome,
  ) {
    if (!messenger.mounted) return;
    switch (outcome.status) {
      case PendingDbImportStatus.applied:
        final message = outcome.message;
        if (message == null) return;
        showSrSnackOn(
          messenger,
          message,
          kind: SrSnackKind.success,
          duration: const Duration(seconds: 4),
        );
      case PendingDbImportStatus.discarded:
        showSrSnackOn(
          messenger,
          'DB 가져오기를 버리고 빈 DB 로 시작합니다. 파일: ${outcome.action?.path}',
          kind: SrSnackKind.warning,
          duration: const Duration(seconds: 8),
        );
      case PendingDbImportStatus.none:
      case PendingDbImportStatus.kept:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: switch (_step) {
            _Step.selectMode => _buildModeSelect(),
            _Step.serverConfig => _buildServerConfig(),
            _Step.standaloneConfig => _buildStandaloneConfig(),
          },
        ),
      ),
    );
  }

  Widget _buildModeSelect() {
    return SingleChildScrollView(
      key: const ValueKey('selectMode'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          // 서버 웹 로그인 화면과 같은 로고(2026-09-24). 라이트/다크 두 벌을 테마로 고른다.
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Image.asset(
                Theme.of(context).brightness == Brightness.dark
                    ? 'assets/branding/logo_lockup_dark.png'
                    : 'assets/branding/logo_lockup_light.png',
                semanticLabel: '나만의 안전신문고',
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '연결 방식을 선택해주세요',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: context.sr.textSecondary),
          ),
          const SizedBox(height: 40),
          _ModeCard(
            icon: Icons.dns_rounded,
            color: Theme.of(context).colorScheme.primary,
            title: 'Client 모드',
            description:
                '직접 구축한 크롤링 서버와 연결합니다.\n자동 크롤링, 통계, 파일 관리 등 모든 기능을 사용할 수 있습니다.',
            onTap: () => _selectMode(AppMode.server),
          ),
          const SizedBox(height: 16),
          _ModeCard(
            icon: Icons.phone_android_rounded,
            color: context.tone(SrTone.success).foreground,
            title: 'Standalone 모드',
            description: '안전신문고 계정으로 앱에서 직접 접근합니다.\n서버 없이 신고 현황을 조회할 수 있습니다.',
            onTap: () => _selectMode(AppMode.standalone),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: _loading ? null : _enterDemo,
              style: TextButton.styleFrom(
                textStyle: const TextStyle(
                  decoration: TextDecoration.underline,
                ),
              ),
              child: const Text('Demo 보기'),
            ),
          ),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_errorMessage != null)
            Text(_errorMessage!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildServerConfig() {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: const ValueKey('serverConfig'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back),
                tooltip: '모드 선택으로 돌아가기',
                onPressed: () => _goToStep(_Step.selectMode),
              ),
              const SizedBox(width: 4),
              Text(
                '서버 연결 설정',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Icon(
            Icons.dns_rounded,
            size: 52,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            '서버 URL과 API Key를 입력해주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.sr.textSecondary),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '서버 URL',
              hintText: 'https://',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            enabled: !_loading,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _apiController,
            decoration: const InputDecoration(
              labelText: 'API Key',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.vpn_key),
            ),
            obscureText: true,
            autocorrect: false,
            enabled: !_loading,
          ),
          _buildError(),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: _loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : Icon(Icons.wifi_find, size: 18),
            label: Text(_loading ? '연결 확인 중...' : '연결 확인 후 시작하기'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: _loading ? null : _connectServer,
          ),
        ],
      ),
    );
  }

  Widget _buildStandaloneConfig() {
    return SingleChildScrollView(
      key: const ValueKey('standaloneConfig'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back),
                tooltip: '모드 선택으로 돌아가기',
                // 로그인·DB 가져오기 중에는 떠나지 않는다(SQ-B03).
                onPressed: _loading ? null : () => _goToStep(_Step.selectMode),
              ),
              const SizedBox(width: 4),
              Text(
                '안전신문고 로그인',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: context.tone(SrTone.success).foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Icon(
            Icons.lock_open_rounded,
            size: 52,
            color: context.tone(SrTone.success).foreground,
          ),
          const SizedBox(height: 16),
          Text(
            '안전신문고 아이디와 비밀번호를 입력하세요.\n서버 없이 앱에서 직접 신고 현황을 조회합니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.sr.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: '아이디',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
            ),
            autocorrect: false,
            textInputAction: TextInputAction.next,
            enabled: !_loading,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: '비밀번호',
              border: const OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePw ? Icons.visibility_off : Icons.visibility,
                  size: 20,
                ),
                tooltip: _obscurePw ? '비밀번호 보기' : '비밀번호 숨기기',
                onPressed: () => setState(() => _obscurePw = !_obscurePw),
              ),
            ),
            obscureText: _obscurePw,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _loading ? null : _loginStandalone(),
            enabled: !_loading,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _phoneController,
            decoration: const InputDecoration(
              labelText: '휴대폰번호',
              helperText: '별점 사유 조회에 사용됩니다. 숫자만 입력해도 됩니다.',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.phone_outlined),
            ),
            keyboardType: TextInputType.phone,
            autocorrect: false,
            enabled: !_loading,
          ),
          _buildError(),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: _loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : Icon(Icons.login, size: 18),
            label: Text(
              _importing ? 'DB 가져오는 중...' : (_loading ? '로그인 중...' : '로그인'),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: context.sr.successFill,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: _loading ? null : _loginStandalone,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.sr.surfaceAlt,
              borderRadius: BorderRadius.circular(SrRadius.lg),
              border: Border.all(color: context.sr.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: context.sr.textSecondary,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '비밀번호는 RSA 암호화 후 안전신문고 서버에 전송됩니다. 자동 재로그인을 위해 기기의 보안 저장소(암호화)에 저장됩니다.',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.sr.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    if (_errorMessage == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.tone(SrTone.danger).background,
          borderRadius: BorderRadius.circular(SrRadius.lg),
          border: Border.all(
            color: context.tone(SrTone.danger).border,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _errorMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SrRadius.xl),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(SrRadius.xl),
            color: color.withValues(alpha: 0.04),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(SrRadius.lg),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: color,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.sr.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}
