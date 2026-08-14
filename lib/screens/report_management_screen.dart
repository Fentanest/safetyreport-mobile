import 'package:flutter/material.dart';

import 'data_editor_screen.dart';
import 'duplicate_management_screen.dart';
import 'rating_management_panel.dart';
import 'watchlist_screen.dart';

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

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('신고관리'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          tabs: const [
            Tab(text: '별점'),
            Tab(text: '감시 목록'),
            Tab(text: '중복 신고'),
            Tab(text: '데이터 수정'),
          ],
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
