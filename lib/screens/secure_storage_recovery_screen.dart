import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import '../theme/app_theme.dart';
import '../services/secure_storage_migration.dart';

class SecureStorageRecoveryApp extends StatelessWidget {
  const SecureStorageRecoveryApp({
    super.key,
    this.exit,
    this.readiness = SecureStorageReadiness.unavailable,
  });

  /// 시험 주입용.
  final Future<void> Function()? exit;
  final SecureStorageReadiness readiness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '나만의 안전신문고',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: SecureStorageRecoveryScreen(exit: exit, readiness: readiness),
  );
}

class SecureStorageRecoveryScreen extends StatelessWidget {
  const SecureStorageRecoveryScreen({
    super.key,
    this.exit,
    this.readiness = SecureStorageReadiness.unavailable,
  });
  final Future<void> Function()? exit;
  final SecureStorageReadiness readiness;

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
                        readiness ==
                                SecureStorageReadiness.reauthenticationRequired
                            ? '재로그인과 커뮤니티 연결 재설정이 필요합니다'
                            : '저장된 로그인 정보를 읽지 못했습니다',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        readiness ==
                                SecureStorageReadiness.reauthenticationRequired
                            ? '이전 보안 저장소 이관을 마치지 않은 설치입니다. 이 버전에서는 이전 로그인 정보를 변환할 수 없습니다. '
                                  '카카오·안전신문고 재로그인과 커뮤니티 연결 재설정이 필요합니다. '
                                  '앱 삭제나 데이터 초기화는 하지 마세요. 신고 자료 보존을 위해 현재 시작을 중단했습니다. '
                                  '이관을 지원하는 중간 버전에서 복구한 뒤 다시 업데이트할 수 있도록 개발자에게 문의해 주세요.'
                            : '저장 정보를 확인하는 중 오류가 발생했습니다. 자료가 없는 것으로 처리하지 않았습니다. '
                                  '앱을 다시 열어 확인해 주세요. 계속 실패하면 앱 삭제나 데이터 초기화 없이 개발자에게 문의해 주세요.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => (exit ?? () => SystemNavigator.pop())(),
                child: const Text('앱 종료'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
