import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/report_provider.dart';
import '../services/local_db_service.dart';
import '../services/standalone_auth_service.dart';
import 'permission_screen.dart';

enum _Step { selectMode, serverConfig, standaloneConfig }

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  _Step _step = _Step.selectMode;

  final _urlController = TextEditingController();
  final _apiController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _obscurePw = true;
  bool _loading = false;
  String? _errorMessage;

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

  Future<void> _connectServer() async {
    final url = _urlController.text.trim();
    final key = _apiController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() => _errorMessage = '서버 URL과 API Key를 모두 입력해주세요.');
      return;
    }
    setState(() { _loading = true; _errorMessage = null; });
    final cleanUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    try {
      Object? lastError;
      http.Response? response;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          response = await http.get(
            Uri.parse('$cleanUrl/api/v1/summary'),
            headers: {'X-API-Key': key, 'Content-Type': 'application/json'},
          ).timeout(const Duration(seconds: 10));
          break;
        } on SocketException catch (e) {
          lastError = e;
        } on http.ClientException catch (e) {
          lastError = e;
        } on TimeoutException catch (e) {
          lastError = e;
        }
        if (attempt < 3) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      if (response == null) {
        throw Exception('네트워크 오류 (3회 재시도 실패): $lastError');
      }
      final checkedResponse = response;
      if (checkedResponse.statusCode == 200) {
        try {
          jsonDecode(checkedResponse.body);
          if (!mounted) return;
          await context.read<ReportProvider>().setConfig(cleanUrl, key);
          if (!mounted) return;
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => const PermissionScreen(isSetup: true)));
          return;
        } catch (_) {
          setState(() => _errorMessage = '서버 응답 파싱 실패. 올바른 서버인지 확인해주세요.');
        }
      } else if (checkedResponse.statusCode == 401) {
        setState(() => _errorMessage = 'API Key 인증 실패 (401)');
      } else {
        setState(() => _errorMessage = '서버 오류: HTTP ${checkedResponse.statusCode}');
      }
    } catch (e) {
      setState(() => _errorMessage = '서버에 연결할 수 없습니다.\n$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loginStandalone() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final phoneNumber =
        _phoneController.text.trim().replaceAll(RegExp(r'[^0-9]'), '');
    if (username.isEmpty || password.isEmpty || phoneNumber.isEmpty) {
      setState(() => _errorMessage = '아이디, 비밀번호, 휴대폰번호를 모두 입력해주세요.');
      return;
    }
    setState(() { _loading = true; _errorMessage = null; });
    try {
      await StandaloneAuthService.login(username, password);
      if (!mounted) return;
      await context.read<ReportProvider>().setStandaloneConfig(
        username,
        phoneNumber: phoneNumber,
      );
      // 모드 전환 시 settings_screen 이 저장한 pending_db_import 적용
      // (Client → Standalone 의 '서버 DB 변환' 또는 '백업 파일 사용' 선택 결과)
      await _applyPendingDbImport();
      if (!mounted) return;
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => const PermissionScreen(isSetup: true)));
    } catch (e) {
      setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// SharedPreferences 의 'pending_db_import' 키 처리:
  ///   - "convert:<path>" → 서버 DB 형식 .db 파일을 모바일 reports 테이블로 마이그레이션
  ///   - "copy:<path>"    → 모바일 형식 .db 백업 파일을 통째로 덮어쓰기
  ///   - 없음              → 빈 DB 그대로
  /// 적용 후 키 제거. 실패해도 로그인 자체는 성공으로 진행 (에러 메시지만 표시).
  Future<void> _applyPendingDbImport() async {
    final prefs = await SharedPreferences.getInstance();
    final action = prefs.getString('pending_db_import');
    if (action == null || action.isEmpty) return;
    await prefs.remove('pending_db_import');

    try {
      if (action.startsWith('convert:')) {
        final path = action.substring('convert:'.length);
        final imported = await LocalDbService.importFromServerDb(path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('서버 DB 변환 완료: $imported건 임포트'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } else if (action.startsWith('copy:')) {
        final path = action.substring('copy:'.length);
        await LocalDbService.replaceFromBackup(path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('백업 복원 완료: ${path.split('/').last}'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('DB 가져오기 실패 (빈 DB 로 시작): $e'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
          child: switch (_step) {
            _Step.selectMode      => _buildModeSelect(),
            _Step.serverConfig    => _buildServerConfig(),
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
          const Icon(Icons.shield_outlined, size: 60, color: Color(0xFF1A73E8)),
          const SizedBox(height: 20),
          const Text('나만의 안전신문고',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('연결 방식을 선택해주세요',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.grey)),
          const SizedBox(height: 40),
          _ModeCard(
            icon: Icons.dns_rounded,
            color: const Color(0xFF1A73E8),
            title: 'Client 모드',
            description: '직접 구축한 크롤링 서버와 연결합니다.\n자동 크롤링, 통계, 파일 관리 등 모든 기능을 사용할 수 있습니다.',
            onTap: () => _goToStep(_Step.serverConfig),
          ),
          const SizedBox(height: 16),
          _ModeCard(
            icon: Icons.phone_android_rounded,
            color: const Color(0xFF0F9D58),
            title: 'Standalone 모드',
            description: '안전신문고 계정으로 앱에서 직접 접근합니다.\n서버 없이 신고 현황을 조회할 수 있습니다.',
            onTap: () => _goToStep(_Step.standaloneConfig),
          ),
          const SizedBox(height: 32),
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
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back),
                onPressed: () => _goToStep(_Step.selectMode)),
            const SizedBox(width: 4),
            Text('서버 연결 설정',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cs.primary)),
          ]),
          const SizedBox(height: 24),
          const Icon(Icons.dns_rounded, size: 52, color: Color(0xFF1A73E8)),
          const SizedBox(height: 16),
          const Text('서버 URL과 API Key를 입력해주세요.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 28),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
                labelText: '서버 URL', hintText: 'https://',
                border: OutlineInputBorder(), prefixIcon: Icon(Icons.link)),
            keyboardType: TextInputType.url,
            autocorrect: false,
            enabled: !_loading,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _apiController,
            decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(), prefixIcon: Icon(Icons.vpn_key)),
            obscureText: true,
            autocorrect: false,
            enabled: !_loading,
          ),
          _buildError(),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.wifi_find, size: 18),
            label: Text(_loading ? '연결 확인 중...' : '연결 확인 후 시작하기'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
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
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back),
                onPressed: () => _goToStep(_Step.selectMode)),
            const SizedBox(width: 4),
            const Text('안전신문고 로그인',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                    color: Color(0xFF0F9D58))),
          ]),
          const SizedBox(height: 24),
          const Icon(Icons.lock_open_rounded, size: 52, color: Color(0xFF0F9D58)),
          const SizedBox(height: 16),
          const Text('안전신문고 아이디와 비밀번호를 입력하세요.\n서버 없이 앱에서 직접 신고 현황을 조회합니다.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, height: 1.5)),
          const SizedBox(height: 28),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
                labelText: '아이디', border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline)),
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
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(_obscurePw ? Icons.visibility_off : Icons.visibility, size: 20),
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
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.login, size: 18),
            label: Text(_loading ? '로그인 중...' : '로그인'),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF0F9D58),
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: _loading ? null : _loginStandalone,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.grey),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '비밀번호는 RSA 암호화 후 안전신문고 서버에 전송됩니다. 자동 재로그인을 위해 기기의 보안 저장소(암호화)에 저장됩니다.',
                    style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
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
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_errorMessage!,
                  style: TextStyle(color: Colors.red.shade800, fontSize: 13, height: 1.5)),
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
  final String? badge;
  final Color? badgeColor;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    this.badge,
    this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bc = badgeColor ?? color;
    final hasBadge = badge != null && badge!.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border.all(color: color.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(16),
            color: color.withOpacity(0.04),
          ),
          child: Row(
            children: [
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(title,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (hasBadge) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: bc.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: bc.withOpacity(0.4)),
                          ),
                          child: Text(badge!,
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: bc)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 6),
                    Text(description,
                        style: const TextStyle(fontSize: 13, color: Colors.grey, height: 1.4)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color.withOpacity(0.5)),
            ],
          ),
        ),
      ),
    );
  }
}
