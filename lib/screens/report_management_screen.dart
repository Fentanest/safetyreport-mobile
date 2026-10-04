import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/report_provider.dart';
import '../widgets/sr_app_bar_actions.dart';

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
    _tabController.addListener(_onTabChanged);
  }

  /// 앱바 검색/필터 아이콘은 지금 하위 탭의 검색을 연다(SQ-U16). 하위 탭이 바뀌면 다시 그린다.
  void _onTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    setState(() {});
  }

  static const _ratingTab = 0;
  static const _editorTab = 3;

  /// 하위 탭에 자기 검색이 있으면 그 시트를 연다. 감시 목록·중복 신고는 검색이 없다
  /// (중복 신고의 상태 카드는 본문에서 고르는 분류다).
  VoidCallback? _filterActionFor(int tab) => switch (tab) {
    _ratingTab => () => openRatingFilterSheet(context),
    _editorTab => () => openDataEditorFilterSheet(context),
    _ => null,
  };

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
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = _tabController.index;
    final filterAction = _filterActionFor(tab);
    // 별점 탭은 별점 상태 조건(별점·별점사유·만족도)을 쓰지 않는다 — 그 탭에 적용되는 조건만 배지로 보인다.
    final filterActive = context.select<ReportProvider, bool>(
      (p) => switch (tab) {
        _ratingTab => !p.filter.withoutRatingStateFilters().isEmpty,
        _editorTab => p.hasFilter,
        _ => false,
      },
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('신고관리'),
        actions: [
          if (filterAction != null)
            FilterActionButton(active: filterActive, onPressed: filterAction),
          const SettingsActionButton(),
        ],
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
