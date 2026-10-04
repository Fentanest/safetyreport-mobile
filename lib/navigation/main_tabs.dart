import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../widgets/selection_back_scope.dart';
import '../widgets/sync_exit_guard.dart';

/// 하단 5개 탭 인덱스(PROJECT_RULES: 0~4 고정). 네이티브 딥링크의 옛 5(파일)·6(동기화/크롤링)은 [AppRoutes] 가 연다.
abstract final class MainTabs {
  static const dashboard = 0;
  static const reports = 1;
  static const management = 2;
  static const statistics = 3;
  static const notifications = 4;
  static const count = 5;

  /// 신고관리(2) 하위 탭: 0 별점, 1 감시 목록, 2 중복 신고, 3 데이터 수정.
  static const managementWatchlist = 1;
}

/// 메인 화면 안에서 하단 탭을 바꾸고 그 탭의 하위 탭을 고르는 통로(SQ-U06).
///
/// 하단 탭 화면을 `Navigator.push` 로 한 벌 더 띄우면 하단 내비게이션이 없고 하위 탭 상태도 따로 논다.
/// 탭 화면은 [takeSubTab] 으로 자기 몫의 요청을 꺼내고, 이미 떠 있으면 알림을 받아 바로 반영한다.
class MainTabController extends ChangeNotifier {
  MainTabController({required void Function(int index) onSelectTab})
    : _onSelectTab = onSelectTab;

  final void Function(int index) _onSelectTab;
  final Map<int, int> _pendingSubTabs = <int, int>{};

  /// 하단 탭 [tab] 으로 바꾸고, [subTab] 이 있으면 그 탭 화면의 하위 탭을 고른다.
  void goTo(int tab, {int? subTab}) {
    if (subTab != null) _pendingSubTabs[tab] = subTab;
    _onSelectTab(tab);
    if (subTab != null) notifyListeners();
  }

  /// [tab] 화면이 받을 하위 탭 요청을 꺼낸다(한 번만).
  int? takeSubTab(int tab) => _pendingSubTabs.remove(tab);
}

/// [MainTabController] 를 하단 탭 화면들에 내려 준다. 메인 화면 밖(push 된 화면)에서는 null 이다.
class MainTabScope extends InheritedWidget {
  const MainTabScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final MainTabController controller;

  static MainTabController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MainTabScope>()?.controller;

  @override
  bool updateShouldNotify(MainTabScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// 메인 하단 탭 화면의 Android 뒤로 가기(SQ-U05).
///
/// 순서: ① 보이는 탭의 다중 선택이 있으면 선택 취소만([SelectionBackScope]) ② 대시보드가 아니면 대시보드로
/// ③ 대시보드에서 동기화 중이면 종료하지 않고 안내([SyncExitGuard]) ④ 그 밖에는 앱 종료.
/// 위에 쌓인 화면(push)은 자기 경로가 먼저 닫히므로 영향이 없다.
class MainTabBackScope extends StatefulWidget {
  const MainTabBackScope({
    super.key,
    required this.currentIndex,
    required this.onReturnHome,
    required this.child,
    this.running,
  });

  final int currentIndex;
  final VoidCallback onReturnHome;
  final Widget child;

  /// 시험용 동기화 실행 상태. 없으면 `SyncEngine.runningListenable`.
  final ValueListenable<bool>? running;

  @override
  State<MainTabBackScope> createState() => _MainTabBackScopeState();
}

class _MainTabBackScopeState extends State<MainTabBackScope> {
  final SelectionBackController _selection = SelectionBackController();

  bool _onBackBlocked() {
    if (_selection.hasActiveSelection) return true;
    if (widget.currentIndex != MainTabs.dashboard) {
      widget.onReturnHome();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => SelectionBackRegistry(
    controller: _selection,
    child: SyncExitGuard(
      running: widget.running,
      allowPop: widget.currentIndex == MainTabs.dashboard,
      onBackBlocked: _onBackBlocked,
      child: widget.child,
    ),
  );
}
