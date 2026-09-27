import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/sync_engine.dart';

/// 동기화 중 Android 뒤로 가기가 실행 화면이나 앱 루트를 닫지 못하게 한다.
/// 중지는 동기화 화면의 중지 버튼으로 요청한다.
class SyncExitGuard extends StatelessWidget {
  const SyncExitGuard({super.key, required this.child, this.running});

  final Widget child;
  final ValueListenable<bool>? running;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: running ?? SyncEngine.runningListenable,
    child: child,
    builder: (context, isRunning, child) => PopScope(
      canPop: !isRunning,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && isRunning) {
          final messenger = ScaffoldMessenger.maybeOf(context);
          messenger?.hideCurrentSnackBar();
          messenger?.showSnackBar(
            const SnackBar(
              content: Text('동기화 중에는 앱을 종료할 수 없습니다. 중지 버튼으로 동기화를 멈춰 주세요.'),
            ),
          );
        }
      },
      child: child!,
    ),
  );
}
