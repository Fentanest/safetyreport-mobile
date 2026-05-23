import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/report_provider.dart';

/// 신고 리스트 / 검색탭 공용 상세검색 팝업
class SearchFilterSheet extends StatefulWidget {
  final ReportProvider provider;
  final bool ratingManagementMode;
  const SearchFilterSheet({
    super.key,
    required this.provider,
    this.ratingManagementMode = false,
  });

  @override
  State<SearchFilterSheet> createState() => _SearchFilterSheetState();
}

class _SearchFilterSheetState extends State<SearchFilterSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _numCtrl;
  late final TextEditingController _ratingCauseCtrl;
  late final TextEditingController _agencyCtrl;
  late final TextEditingController _managerCtrl;
  late final TextEditingController _carCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _fineCtrl;
  late final TextEditingController _supplementCountCtrl;
  late final TextEditingController _reportContentCtrl;
  late final TextEditingController _processContentCtrl;
  late final TextEditingController _occurTimeStartCtrl;
  late final TextEditingController _occurTimeEndCtrl;

  late List<String> _selectedStatuses;
  late List<String> _selectedRatings;
  late String _reportDateStart;
  late String _reportDateEnd;
  late String _occurDateStart;
  late String _occurDateEnd;
  late String _responseDateStart;
  late String _responseDateEnd;
  late bool _excludePolice;
  late bool _onlyPolice;
  late String _selectedLaw;
  late String _pollStatus;
  bool _statusExpanded = false;
  bool _ratingExpanded = false;

  static const _fallbackStatusOptions = [
    '수용',
    '일부수용',
    '불수용',
    '처리중',
    '보완요청',
    '취하',
    '기타',
    '답변완료',
  ];
  static const _ratingOptions = <MapEntry<String, String>>[
    MapEntry('__none__', '없음'),
    MapEntry('1', '1점'),
    MapEntry('2', '2점'),
    MapEntry('3', '3점'),
    MapEntry('4', '4점'),
    MapEntry('5', '5점'),
  ];
  static const _pollStatusOptions = <String>['참여 완료', '참여 가능'];

  static String _canonicalStatusOption(String value) {
    final trimmed = value.trim();
    if (trimmed == '진행' ||
        trimmed == '진행중' ||
        trimmed == '검토중' ||
        trimmed == '처리중') {
      return '처리중';
    }
    return trimmed;
  }

  @override
  void initState() {
    super.initState();
    final f = widget.provider.filter;
    _nameCtrl = TextEditingController(text: f.name);
    _numCtrl = TextEditingController(text: f.reportNumber);
    _ratingCauseCtrl = TextEditingController(
      text: widget.ratingManagementMode ? '' : f.ratingCause,
    );
    _agencyCtrl = TextEditingController(text: f.agency);
    _managerCtrl = TextEditingController(text: f.manager);
    _carCtrl = TextEditingController(text: f.carNumber);
    _locationCtrl = TextEditingController(text: f.location);
    _fineCtrl = TextEditingController(text: f.fine);
    _supplementCountCtrl = TextEditingController(text: f.supplementCount);
    _reportContentCtrl = TextEditingController(text: f.reportContent);
    _processContentCtrl = TextEditingController(text: f.processContent);
    _occurTimeStartCtrl = TextEditingController(text: f.occurTimeStart);
    _occurTimeEndCtrl = TextEditingController(text: f.occurTimeEnd);
    _selectedStatuses = f.statuses
        .map(_canonicalStatusOption)
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    _selectedRatings = widget.ratingManagementMode
        ? <String>[]
        : List<String>.from(f.ratings);
    _reportDateStart = f.reportDateStart;
    _reportDateEnd = f.reportDateEnd;
    _occurDateStart = f.occurDateStart;
    _occurDateEnd = f.occurDateEnd;
    _responseDateStart = f.responseDateStart;
    _responseDateEnd = f.responseDateEnd;
    _excludePolice = f.excludePolice;
    _onlyPolice = f.onlyPolice;
    _selectedLaw = f.law;
    _pollStatus = widget.ratingManagementMode ? '' : f.pollStatus;
  }

  @override
  void dispose() {
    for (final c in [
      _nameCtrl,
      _numCtrl,
      _agencyCtrl,
      _managerCtrl,
      _carCtrl,
      _locationCtrl,
      _fineCtrl,
      _supplementCountCtrl,
      _reportContentCtrl,
      _ratingCauseCtrl,
      _processContentCtrl,
      _occurTimeStartCtrl,
      _occurTimeEndCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<String?> _pickDate(String current) async {
    final now = DateTime.now();
    final init = current.isNotEmpty ? DateTime.tryParse(current) ?? now : now;
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: now,
    );
    if (picked == null) return null;
    return '${picked.year}-${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
  }

  void _apply() {
    widget.provider.setFilter(
      ReportFilter(
        name: _nameCtrl.text.trim(),
        reportNumber: _numCtrl.text.trim(),
        ratings: widget.ratingManagementMode
            ? const <String>[]
            : List<String>.from(_selectedRatings),
        ratingCause: widget.ratingManagementMode
            ? ''
            : _ratingCauseCtrl.text.trim(),
        agency: _agencyCtrl.text.trim(),
        manager: _managerCtrl.text.trim(),
        carNumber: _carCtrl.text.trim(),
        law: _selectedLaw,
        location: _locationCtrl.text.trim(),
        fine: _fineCtrl.text.trim(),
        supplementCount: _supplementCountCtrl.text.trim(),
        reportContent: _reportContentCtrl.text.trim(),
        processContent: _processContentCtrl.text.trim(),
        statuses: List<String>.from(_selectedStatuses),
        reportDateStart: _reportDateStart,
        reportDateEnd: _reportDateEnd,
        occurDateStart: _occurDateStart,
        occurDateEnd: _occurDateEnd,
        responseDateStart: _responseDateStart,
        responseDateEnd: _responseDateEnd,
        occurTimeStart: _occurTimeStartCtrl.text.trim(),
        occurTimeEnd: _occurTimeEndCtrl.text.trim(),
        excludePolice: _excludePolice,
        onlyPolice: _onlyPolice,
        pollStatus: widget.ratingManagementMode ? '' : _pollStatus,
      ),
    );
    Navigator.pop(context);
  }

  void _clear() {
    widget.provider.clearFilter();
    Navigator.pop(context);
  }

  List<MapEntry<String, String>> get _statusOptions {
    final fromProvider = widget.provider.availableStatuses;
    final source = fromProvider.isNotEmpty
        ? fromProvider
        : _fallbackStatusOptions;
    final seen = <String>{};
    final values = <String>[...source, ..._selectedStatuses];
    return values
        .map(_canonicalStatusOption)
        .where((value) => value.isNotEmpty && seen.add(value))
        .map((value) => MapEntry(value, value))
        .toList();
  }

  List<String> get _lawOptions {
    final seen = <String>{};
    final values = <String>[...widget.provider.availableLaws, _selectedLaw];
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .toList();
  }

  String _singleSelectLabel(String value) {
    if (value == kEmptyLawFilterValue) return '없음';
    return value;
  }

  String _selectionSummary(
    List<MapEntry<String, String>> options,
    List<String> selectedValues,
  ) {
    final labels = options
        .where((option) => selectedValues.contains(option.key))
        .map((option) => option.value)
        .toList();
    if (labels.isEmpty) return '전체';
    if (labels.length <= 2) return labels.join(', ');
    return '${labels.first} 외 ${labels.length - 1}개';
  }

  void _toggleSelection(
    List<String> selectedValues,
    String value,
    List<MapEntry<String, String>> options,
  ) {
    final idx = selectedValues.indexOf(value);
    if (idx >= 0) {
      selectedValues.removeAt(idx);
    } else {
      selectedValues.add(value);
      final order = {
        for (var i = 0; i < options.length; i++) options[i].key: i,
      };
      selectedValues.sort(
        (a, b) => (order[a] ?? 999).compareTo(order[b] ?? 999),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusOptions = _statusOptions;
    final lawOptions = _lawOptions;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 핸들
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '상세 검색',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                TextButton(onPressed: _clear, child: const Text('전체 초기화')),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blueGrey.shade100),
              ),
              child: const Text(
                "안내: '&'는 AND, ','는 OR 조건입니다.",
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 12),

            // ── 신고 기본 정보 ──────────────────────────
            _sectionLabel('신고 기본 정보'),
            _input(_nameCtrl, '신고명', Icons.description_outlined),
            const SizedBox(height: 8),
            _input(_numCtrl, '신고번호', Icons.tag),
            const SizedBox(height: 8),
            if (!widget.ratingManagementMode) ...[
              _multiSelectDropdown(
                label: '별점',
                icon: Icons.star_outline,
                options: _ratingOptions,
                selectedValues: _selectedRatings,
                expanded: _ratingExpanded,
                onToggleExpanded: () => setState(() {
                  _ratingExpanded = !_ratingExpanded;
                  if (_ratingExpanded) _statusExpanded = false;
                }),
                onToggleValue: (value) => setState(() {
                  _toggleSelection(_selectedRatings, value, _ratingOptions);
                }),
                onClear: () => setState(() => _selectedRatings.clear()),
              ),
              const SizedBox(height: 8),
              _input(_ratingCauseCtrl, '별점사유', Icons.comment_outlined),
              const SizedBox(height: 8),
              _singleSelectDropdown(
                label: '만족도 조사 여부',
                icon: Icons.poll_outlined,
                options: _pollStatusOptions,
                currentValue: _pollStatus,
                onChanged: (v) => setState(() => _pollStatus = v),
              ),
              const SizedBox(height: 8),
            ],
            _input(_carCtrl, '차량번호', Icons.directions_car_outlined),
            const SizedBox(height: 8),
            _input(_locationCtrl, '위반장소', Icons.location_on_outlined),
            const SizedBox(height: 8),
            _singleSelectDropdown(
              label: '위반법규',
              icon: Icons.gavel_outlined,
              options: lawOptions,
              currentValue: _selectedLaw,
              onChanged: (value) => setState(() => _selectedLaw = value),
            ),
            const SizedBox(height: 8),
            _input(_reportContentCtrl, '신고내용', Icons.article_outlined),

            const SizedBox(height: 16),

            // ── 처리 정보 ───────────────────────────────
            _sectionLabel('처리 정보'),
            _input(_agencyCtrl, '처리기관', Icons.business_outlined),
            const SizedBox(height: 8),
            _input(_managerCtrl, '담당자', Icons.person_outline),
            const SizedBox(height: 8),
            _input(_fineCtrl, '과태료/범칙금', Icons.monetization_on_outlined),
            const SizedBox(height: 8),
            _input(_supplementCountCtrl, '보완횟수', Icons.history_edu_outlined),
            const SizedBox(height: 8),
            _input(_processContentCtrl, '처리내용', Icons.task_alt_outlined),
            const SizedBox(height: 8),
            _multiSelectDropdown(
              label: '처리상태',
              icon: Icons.checklist_outlined,
              options: statusOptions,
              selectedValues: _selectedStatuses,
              expanded: _statusExpanded,
              onToggleExpanded: () => setState(() {
                _statusExpanded = !_statusExpanded;
                if (_statusExpanded) _ratingExpanded = false;
              }),
              onToggleValue: (value) => setState(() {
                _toggleSelection(_selectedStatuses, value, statusOptions);
              }),
              onClear: () => setState(() => _selectedStatuses.clear()),
            ),
            const SizedBox(height: 10),
            // 경찰기관 토글
            Row(
              children: [
                Expanded(
                  child: _toggleChip(
                    '경찰기관 제외',
                    _excludePolice,
                    () => setState(() {
                      _excludePolice = !_excludePolice;
                      if (_excludePolice) _onlyPolice = false;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _toggleChip(
                    '경찰기관만',
                    _onlyPolice,
                    () => setState(() {
                      _onlyPolice = !_onlyPolice;
                      if (_onlyPolice) _excludePolice = false;
                    }),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── 날짜/시각 범위 ───────────────────────────
            _sectionLabel('날짜 / 시각 범위'),
            _dateRange(
              '신고일',
              _reportDateStart,
              _reportDateEnd,
              Colors.blue,
              (d) => setState(() => _reportDateStart = d),
              (d) => setState(() => _reportDateEnd = d),
            ),
            const SizedBox(height: 8),
            _dateRange(
              '발생일',
              _occurDateStart,
              _occurDateEnd,
              Colors.green,
              (d) => setState(() => _occurDateStart = d),
              (d) => setState(() => _occurDateEnd = d),
            ),
            const SizedBox(height: 8),
            _dateRange(
              '답변일',
              _responseDateStart,
              _responseDateEnd,
              Colors.orange,
              (d) => setState(() => _responseDateStart = d),
              (d) => setState(() => _responseDateEnd = d),
            ),
            const SizedBox(height: 8),
            // 발생시각
            Row(
              children: [
                Container(
                  width: 56,
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '발생시각',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _occurTimeStartCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: '14:30',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('~'),
                ),
                Expanded(
                  child: TextField(
                    controller: _occurTimeEndCtrl,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _apply(),
                    decoration: const InputDecoration(
                      hintText: '15:00',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.search, size: 18),
              label: const Text('검색 적용'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _apply,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _input(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    bool enabled = true,
  }) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _apply(),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        prefixIcon: Icon(icon, size: 18),
        isDense: true,
      ),
    );
  }

  Widget _multiSelectDropdown({
    required String label,
    required IconData icon,
    required List<MapEntry<String, String>> options,
    required List<String> selectedValues,
    required bool expanded,
    required VoidCallback onToggleExpanded,
    required ValueChanged<String> onToggleValue,
    required VoidCallback onClear,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onToggleExpanded,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              prefixIcon: Icon(icon, size: 18),
              suffixIcon: Icon(
                expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              ),
              isDense: true,
            ),
            child: Text(
              _selectionSummary(options, selectedValues),
              style: TextStyle(
                color: selectedValues.isEmpty ? Colors.grey.shade600 : null,
              ),
            ),
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
              color: Colors.white,
            ),
            child: Column(
              children: [
                _multiSelectOption(
                  label: '전체',
                  selected: selectedValues.isEmpty,
                  onTap: onClear,
                  onSubmit: _apply,
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                ...options.map(
                  (option) => _multiSelectOption(
                    label: option.value,
                    selected: selectedValues.contains(option.key),
                    onTap: () => onToggleValue(option.key),
                    onSubmit: _apply,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _singleSelectDropdown({
    required String label,
    required IconData icon,
    required List<String> options,
    required String currentValue,
    required ValueChanged<String> onChanged,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        prefixIcon: Icon(icon, size: 18),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: currentValue.isEmpty ? null : currentValue,
          hint: Text(
            '전체',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
          ),
          isExpanded: true,
          isDense: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('전체')),
            ...options.map(
              (option) => DropdownMenuItem(
                value: option,
                child: Text(_singleSelectLabel(option)),
              ),
            ),
          ],
          onChanged: (value) => onChanged(value ?? ''),
        ),
      ),
    );
  }

  Widget _multiSelectOption({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onSubmit,
  }) {
    return Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key != LogicalKeyboardKey.enter &&
            key != LogicalKeyboardKey.numpadEnter) {
          return KeyEventResult.ignored;
        }
        onTap();
        if (onSubmit != null) {
          onSubmit();
        }
        return KeyEventResult.handled;
      },
      child: InkWell(
        onTap: onTap,
        canRequestFocus: true,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                width: 18,
                child: Text(
                  selected ? 'v' : '',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toggleChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? Colors.blue.shade50 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? Colors.blue : Colors.grey.shade300,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: active ? Colors.blue : Colors.grey.shade600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _dateRange(
    String label,
    String start,
    String end,
    Color color,
    ValueChanged<String> onStart,
    ValueChanged<String> onEnd,
  ) {
    return Row(
      children: [
        Container(
          width: 40,
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: _dateTap(
            start.isEmpty ? '시작일' : start,
            color,
            () async {
              final d = await _pickDate(start);
              if (d != null) onStart(d);
            },
            start.isNotEmpty ? () => onStart('') : null,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text('~'),
        ),
        Expanded(
          child: _dateTap(end.isEmpty ? '종료일' : end, color, () async {
            final d = await _pickDate(end);
            if (d != null) onEnd(d);
          }, end.isNotEmpty ? () => onEnd('') : null),
        ),
      ],
    );
  }

  Widget _dateTap(
    String label,
    Color color,
    VoidCallback onTap,
    VoidCallback? onClear,
  ) {
    final hasValue = label != '시작일' && label != '종료일';
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        side: BorderSide(color: hasValue ? color : Colors.grey.shade300),
        foregroundColor: hasValue ? color : Colors.grey,
      ),
      onPressed: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          if (onClear != null)
            GestureDetector(
              onTap: onClear,
              child: Icon(Icons.close, size: 14, color: color),
            ),
        ],
      ),
    );
  }
}
