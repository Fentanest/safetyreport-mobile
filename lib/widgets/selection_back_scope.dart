import 'package:flutter/material.dart';

/// 다중 선택 중 시스템 뒤로가기를 "선택 취소"로 바꾼다.
///
/// 하단 탭은 `IndexedStack` 으로 살아 있으므로, 보이지 않는 탭에 선택이 남아 있어도
/// 현재 탭의 뒤로가기를 가로채지 않도록 `TickerMode`(main.dart 가 비활성 탭에 false)로 한 번 더 거른다.
///
/// 위에 [SelectionBackRegistry] 가 있으면(메인 하단 탭 화면) 가로채는 동안 거기에 등록해,
/// 같은 경로의 다른 뒤로가기 처리(비0 탭 → 대시보드, SQ-U05)가 선택 취소보다 먼저 움직이지 않게 한다.
class SelectionBackScope extends StatefulWidget {
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
  State<SelectionBackScope> createState() => _SelectionBackScopeState();
}

class _SelectionBackScopeState extends State<SelectionBackScope> {
  SelectionBackController? _registry;

  void _sync(bool intercept) {
    final registry = SelectionBackRegistry.maybeOf(context);
    if (!identical(registry, _registry)) {
      _registry?._active.remove(this);
      _registry = registry;
    }
    if (intercept) {
      registry?._active.add(this);
    } else {
      registry?._active.remove(this);
    }
  }

  @override
  void dispose() {
    _registry?._active.remove(this);
    _registry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intercept =
        widget.selectionMode && TickerMode.valuesOf(context).enabled;
    _sync(intercept);
    return PopScope(
      canPop: !intercept,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && intercept) widget.onCancel();
      },
      child: widget.child,
    );
  }
}

/// 뒤로가기를 "선택 취소"로 가로채는 [SelectionBackScope] 목록. 화면 State 가 한 번 만들어 들고 있는다.
class SelectionBackController {
  final Set<Object> _active = <Object>{};

  /// 지금 뒤로가기를 가로채는(보이는 탭에서 선택 중인) 범위가 있는가.
  bool get hasActiveSelection => _active.isNotEmpty;
}

/// 이 아래에서 뒤로가기를 "선택 취소"로 가로채는 [SelectionBackScope] 가 있는지 알려 준다.
///
/// 같은 경로의 PopScope 콜백은 모두 불리므로(순서 보장 없음), 루트의 탭 뒤로가기 처리는
/// 이 값을 보고 선택 취소가 처리할 뒤로가기를 건너뛴다.
class SelectionBackRegistry extends InheritedWidget {
  const SelectionBackRegistry({
    super.key,
    required this.controller,
    required super.child,
  });

  final SelectionBackController controller;

  static SelectionBackController? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<SelectionBackRegistry>()
      ?.controller;

  @override
  bool updateShouldNotify(SelectionBackRegistry oldWidget) =>
      !identical(controller, oldWidget.controller);
}
