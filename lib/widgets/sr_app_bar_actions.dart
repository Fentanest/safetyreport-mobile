import 'package:flutter/material.dart';

import '../models/report_filter.dart';
import '../screens/settings_screen.dart';
import '../theme/sr_colors.dart';

/// 하단 5개 탭 앱바의 공통 동작(SQ-U16).
///
/// 규칙: 모든 탭 앱바는 [SettingsActionButton] 으로 끝나고, 탭별 동작은 그 왼쪽에 둔다.
/// 목록형 화면의 검색/필터는 앱바 [FilterActionButton] 하나로 열고, 걸린 조건은 본문 맨 위
/// [ActiveFilterChipBar] 에 칩으로 보이며 칩마다 × 로 하나씩 푼다.
class SettingsActionButton extends StatelessWidget {
  const SettingsActionButton({super.key = defaultKey});

  static const defaultKey = ValueKey('appbar-settings');

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.settings),
    tooltip: '설정',
    onPressed: () => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    ),
  );
}

/// 앱바의 검색/필터 아이콘. 조건이 걸려 있으면 점 배지를 단다.
class FilterActionButton extends StatelessWidget {
  const FilterActionButton({
    super.key = defaultKey,
    required this.active,
    required this.onPressed,
  });

  static const defaultKey = ValueKey('appbar-filter');

  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Badge(isLabelVisible: active, child: const Icon(Icons.filter_list)),
    tooltip: '검색/필터',
    onPressed: onPressed,
  );
}

/// 걸린 검색 조건 칩 줄. 칩의 × 는 그 조건만 풀고, "초기화"는 모두 푼다.
/// 조건이 없으면 아무것도 그리지 않는다.
class ActiveFilterChipBar extends StatelessWidget {
  const ActiveFilterChipBar({
    super.key,
    required this.conditions,
    required this.onRemove,
    required this.onClear,
  });

  final List<ReportFilterCondition> conditions;
  final ValueChanged<ReportFilterField> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (conditions.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('active-filter-chips'),
      width: double.infinity,
      color: context.sr.brandSoft,
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final condition in conditions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InputChip(
                        key: ValueKey('filter-chip-${condition.field.name}'),
                        label: Text(condition.label),
                        backgroundColor: scheme.surface,
                        side: BorderSide(color: scheme.primary),
                        onDeleted: () => onRemove(condition.field),
                        deleteButtonTooltipMessage: '조건 해제',
                      ),
                    ),
                ],
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('filter-chips-clear'),
            onPressed: onClear,
            child: const Text('초기화'),
          ),
        ],
      ),
    );
  }
}
