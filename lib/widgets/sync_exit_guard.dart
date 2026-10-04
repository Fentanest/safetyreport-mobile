import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/sync_engine.dart';
import 'sr_snack_bar.dart';

/// 동기화 중 Android 뒤로 가기가 실행 화면이나 앱 루트를 닫지 못하게 한다.
/// 중지는 동기화 화면의 중지 버튼으로 요청한다.
///
/// 메인 하단 탭 화면은 [allowPop]·[onBackBlocked] 로 "비0 탭 → 대시보드"(SQ-U05)를 같은 PopScope 에서 처리한다.
/// 한 콜백에서 순서대로 판단하므로 탭 이동 뒤에 동기화 안내가 잘못 뜨지 않는다.
class SyncExitGuard extends StatelessWidget {
  const SyncExitGuard({
    super.key,
    required this.child,
    this.running,
    this.allowPop = true,
    this.onBackBlocked,
  });

  final Widget child;
  final ValueListenable<bool>? running;

  /// false 면 동기화와 무관하게 이 경로의 뒤로 가기를 막고 [onBackBlocked] 에 맡긴다.
  final bool allowPop;

  /// 막힌 뒤로 가기를 호출부가 처리했으면 true 를 돌려준다(동기화 안내를 띄우지 않는다).
  final bool Function()? onBackBlocked;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: running ?? SyncEngine.runningListenable,
    child: child,
    builder: (context, isRunning, child) => PopScope(
      canPop: allowPop && !isRunning,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (onBackBlocked?.call() == true) return;
        if (isRunning) {
          showSrSnack(
            context,
            '동기화 중에는 앱을 종료할 수 없습니다. 중지 버튼으로 동기화를 멈춰 주세요.',
            hideCurrent: true,
          );
        }
      },
      child: child!,
    ),
  );
}
