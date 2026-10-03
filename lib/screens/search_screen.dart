import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/report_provider.dart';
import '../widgets/search_filter_sheet.dart';
import '../widgets/local_paged_report_list.dart';
import '../theme/sr_colors.dart';

class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  void _openSearchPopup(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) =>
          SearchFilterSheet(provider: context.read<ReportProvider>()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('검색'),
        actions: [
          if (provider.hasFilter)
            TextButton(
              onPressed: provider.clearFilter,
              child: const Text('초기화'),
            ),
          IconButton(
            icon: Badge(
              isLabelVisible: provider.hasFilter,
              child: const Icon(Icons.tune),
            ),
            tooltip: '검색 조건',
            onPressed: () => _openSearchPopup(context),
          ),
        ],
      ),
      body: Column(
        children: [
          if (provider.hasFilter && provider.filter.activeLabels.isNotEmpty)
            Container(
              color: context.sr.brandSoft,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final label in provider.filter.activeLabels)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Chip(label: Text(label)),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: provider.hasFilter
                ? LocalPagedReportList(filter: provider.filter)
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.search,
                          size: 72,
                          color: context.sr.textDisabled,
                        ),
                        const SizedBox(height: 16),
                        const Text('검색 조건을 설정하세요.'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.tune),
                          label: const Text('검색 조건 설정'),
                          onPressed: () => _openSearchPopup(context),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: !provider.hasFilter
          ? FloatingActionButton.extended(
              onPressed: () => _openSearchPopup(context),
              icon: const Icon(Icons.search),
              label: const Text('검색'),
            )
          : null,
    );
  }
}
