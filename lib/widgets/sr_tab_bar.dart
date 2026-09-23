import 'package:flutter/material.dart';

/// 앱바 하단 알약형 탭. 색·글자는 `AppTheme` 의 tabBarTheme 을 따른다.
/// 탭 수·순서·스와이프 동작은 호출부의 [TabController] 그대로다.
class SrTabBar extends StatelessWidget implements PreferredSizeWidget {
  final TabController? controller;
  final List<Widget> tabs;

  const SrTabBar({super.key, this.controller, required this.tabs});

  static const double _height = 48;

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: TabBar(
        controller: controller,
        tabs: tabs,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        indicatorPadding: const EdgeInsets.symmetric(vertical: 4),
      ),
    );
  }
}
