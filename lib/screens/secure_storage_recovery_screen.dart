import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import '../theme/app_theme.dart';
import '../services/secure_storage_migration.dart';

class SecureStorageRecoveryApp extends StatelessWidget {
  const SecureStorageRecoveryApp({
    super.key,
    this.exit,
    this.reset,
    this.onRecovered,
    this.readiness = SecureStorageReadiness.unavailable,
  });

  /// 시험 주입용.
  final Future<void> Function()? exit;
  final Future<void> Function()? reset;
  final Future<void> Function()? onRecovered;
  final SecureStorageReadiness readiness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '나만의 안전신문고',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: SecureStorageRecoveryScreen(
      exit: exit,
      readiness: readiness,
      reset: reset,
      onRecovered: onRecovered,
    ),
  );
}

class SecureStorageRecoveryScreen extends StatefulWidget {
  const SecureStorageRecoveryScreen({
    super.key,
    this.exit,
    this.reset,
    this.onRecovered,
    this.readiness = SecureStorageReadiness.unavailable,
  });
  final Future<void> Function()? exit;
  final Future<void> Function()? reset;
  final Future<void> Function()? onRecovered;
  final SecureStorageReadiness readiness;

  @override
  State<SecureStorageRecoveryScreen> createState() =>
      _SecureStorageRecoveryScreenState();
}

class _SecureStorageRecoveryScreenState
    extends State<SecureStorageRecoveryScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('저장된 로그인 정보를 초기화할까요?'),
        content: const Text(
          '저장된 안전신문고 비밀번호, 카카오 로그인 정보와 커뮤니티 연결 정보가 사라집니다. '
          '신고 자료, 앱 설정과 기기에 저장된 커뮤니티 자료는 그대로 남습니다. '
          '계속하려면 다시 로그인하고 연결을 확인해야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('초기화하고 다시 로그인'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.reset ?? SecureStorageMigration.resetForReauthentication)();
      await widget.onRecovered?.call();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = '로그인 정보 초기화를 마치지 못했습니다. 다시 시도해 주세요. 신고 자료와 설정은 유지됩니다.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      Text(
                        widget.readiness ==
                                SecureStorageReadiness.reauthenticationRequired
                            ? '재로그인과 커뮤니티 연결 재설정이 필요합니다'
                            : '저장된 로그인 정보를 읽지 못했습니다',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.readiness ==
                                SecureStorageReadiness.reauthenticationRequired
                            ? '이전 보안 저장소 이관을 마치지 않은 설치입니다. 이 버전에서는 이전 로그인 정보를 변환할 수 없습니다. '
                                  '카카오·안전신문고 재로그인과 커뮤니티 연결 재설정이 필요합니다. '
                                  '아래 버튼에서 저장된 로그인 정보만 초기화한 뒤 다시 로그인할 수 있습니다. '
                                  '신고 자료, 앱 설정과 기기에 저장된 커뮤니티 자료는 유지됩니다.'
                            : '저장 정보를 확인하는 중 오류가 발생했습니다. 자료가 없는 것으로 처리하지 않았습니다. '
                                  '앱을 다시 열어 확인해 주세요. 계속 실패하면 앱 삭제나 데이터 초기화 없이 개발자에게 문의해 주세요.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null) Text(_error!),
              if (widget.readiness ==
                  SecureStorageReadiness.reauthenticationRequired)
                FilledButton(
                  onPressed: _busy ? null : _confirmReset,
                  child: Text(_busy ? '초기화 중…' : '저장된 로그인 정보 초기화하고 다시 로그인'),
                ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => (widget.exit ?? () => SystemNavigator.pop())(),
                child: const Text('앱 종료'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
