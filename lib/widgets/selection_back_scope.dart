import 'package:flutter/material.dart';

/// 다중 선택 중 시스템 뒤로가기를 "선택 취소"로 바꾼다.
///
/// 하단 탭은 `IndexedStack` 으로 살아 있으므로, 보이지 않는 탭에 선택이 남아 있어도
/// 현재 탭의 뒤로가기를 가로채지 않도록 `TickerMode`(main.dart 가 비활성 탭에 false)로 한 번 더 거른다.
class SelectionBackScope extends StatelessWidget {
  final bool selectionMode;
  final VoidCallback onCancel;
  final Widget child;

  const SelectionBackScope({
    super.key,
    required this.selectionMode,
    required this.onCancel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final intercept = selectionMode && TickerMode.valuesOf(context).enabled;
    return PopScope(
      canPop: !intercept,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && intercept) onCancel();
      },
      child: child,
    );
  }
}
