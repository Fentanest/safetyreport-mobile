import 'package:flutter/material.dart';
import '../models/report_sort.dart';

class ReportSortButton extends StatelessWidget {
  const ReportSortButton({
    super.key,
    required this.sort,
    required this.onChanged,
    this.duplicates = false,
  });
  final ReportSort sort;
  final bool duplicates;
  final ValueChanged<ReportSort> onChanged;
  @override
  Widget build(BuildContext context) => Semantics(
    label: sort.semantics,
    button: true,
    excludeSemantics: true,
    onTap: () => _choose(context),
    child: TextButton.icon(
      key: const Key('reportSortButton'),
      onPressed: () => _choose(context),
      icon: const Icon(Icons.sort, size: 18),
      label: Text(sort.description, style: const TextStyle(fontSize: 13)),
    ),
  );
  Future<void> _choose(BuildContext context) async {
    var selected = sort;
    final result = await showModalBottomSheet<ReportSort>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheet).height * .9,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '신고내역 정렬',
                      style: Theme.of(sheet).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    RadioGroup<ReportSortField>(
                      groupValue: selected.field,
                      onChanged: (field) {
                        if (field != null) {
                          setSheetState(
                            () => selected = ReportSort(
                              field: field,
                              ascending: selected.ascending,
                            ),
                          );
                        }
                      },
                      child: Column(
                        children: [
                          for (final field in ReportSortField.values)
                            if (duplicates ||
                                field != ReportSortField.duplicateCount)
                              RadioListTile<ReportSortField>(
                                value: field,
                                title: Text(field.label),
                                dense: true,
                              ),
                        ],
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final ascending in [true, false])
                          ChoiceChip(
                            label: Text(ascending ? '오름차순' : '내림차순'),
                            selected: selected.ascending == ascending,
                            onSelected: (_) => setSheetState(
                              () => selected = ReportSort(
                                field: selected.field,
                                ascending: ascending,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheet, selected),
                      child: const Text('적용'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (result != null) onChanged(result);
  }
}
