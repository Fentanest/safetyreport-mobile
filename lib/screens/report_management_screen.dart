import 'package:flutter/material.dart';

import 'data_editor_screen.dart';
import 'duplicate_management_screen.dart';
import 'rating_management_panel.dart';
import 'watchlist_screen.dart';
import '../navigation/main_tabs.dart';
import '../widgets/sr_tab_bar.dart';

class ReportManagementScreen extends StatefulWidget {
  final int initialTabIndex;

  const ReportManagementScreen({super.key, this.initialTabIndex = 0});

  @override
  State<ReportManagementScreen> createState() => _ReportManagementScreenState();
}

class _ReportManagementScreenState extends State<ReportManagementScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 3),
    );
  }

  /// 하단 탭 화면일 때 메인 화면이 보내는 하위 탭 요청(대시보드 "감시 목록 › 관리", SQ-U06).
  MainTabController? _mainTabs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tabs = MainTabScope.maybeOf(context);
    if (identical(tabs, _mainTabs)) return;
    _mainTabs?.removeListener(_applyMainTabRequest);
    _mainTabs = tabs;
    tabs?.addListener(_applyMainTabRequest);
    _applyMainTabRequest();
  }

  void _applyMainTabRequest() {
    final subTab = _mainTabs?.takeSubTab(MainTabs.management);
    if (subTab == null) return;
    final index = subTab.clamp(0, _tabController.length - 1);
    if (_tabController.index != index) _tabController.index = index;
  }

  @override
  void dispose() {
    _mainTabs?.removeListener(_applyMainTabRequest);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('신고관리'),
        bottom: SrTabBar(
          controller: _tabController,
          textScaler: MediaQuery.textScalerOf(context),
          labels: const ['별점', '감시 목록', '중복 신고', '데이터 수정'],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          RatingManagementPanel(),
          WatchlistPanel(),
          DuplicateManagementPanel(),
          DataEditorPanel(),
        ],
      ),
    );
  }
}
