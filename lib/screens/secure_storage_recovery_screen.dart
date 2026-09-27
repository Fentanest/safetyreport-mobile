// 보안 저장소 v10 이관이 확인되지 않은 시작(lib/services/secure_storage_migration.dart). 평소 화면 대신 이 화면만 띄운다.
// 로그인 정보를 지워 우회하는 버튼은 두지 않는다(카카오 로그인은 필수 — 2026-09-27 사용자 결정). 앱을 다시 열면 이관을 다시 시도한다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import '../theme/app_theme.dart';

class SecureStorageRecoveryApp extends StatelessWidget {
  const SecureStorageRecoveryApp({super.key, this.exit});

  /// 시험 주입용.
  final Future<void> Function()? exit;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '나만의 안전신문고',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: SecureStorageRecoveryScreen(exit: exit),
      );
}

class SecureStorageRecoveryScreen extends StatelessWidget {
  const SecureStorageRecoveryScreen({super.key, this.exit});
  final Future<void> Function()? exit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text('저장된 로그인 정보를 준비하지 못했습니다', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text('앱 업데이트 뒤 이 기기에 저장된 로그인 정보를 새 보안 형식으로 옮기지 못했습니다. '
                  '앱을 다시 열면 다시 시도합니다. 여러 번 다시 열어도 이 화면이 계속 보이면 앱을 삭제한 뒤 다시 설치해 주세요 '
                  '(이 기기에 저장된 신고 자료도 함께 지워지고, 카카오 로그인부터 다시 시작합니다).'),
              const Spacer(),
              FilledButton(
                onPressed: () => (exit ?? () => SystemNavigator.pop())(),
                child: const Text('앱 종료(다시 열어 재시도)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
