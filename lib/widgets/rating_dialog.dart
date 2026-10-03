import 'package:flutter/material.dart';
import '../services/rating_service.dart';
import '../theme/sr_colors.dart';

/// Dialog owns the scrolling viewport; AlertDialog applies keyboard insets once.
/// Actions live outside that viewport and remain accessible as its height changes.
class RatingDialog extends StatefulWidget {
  final int count;
  final int eligibleCount;
  final bool causeSupported;
  final String initialCause;
  final ValueChanged<String>? onDraftChanged;
  const RatingDialog({
    super.key,
    required this.count,
    required this.eligibleCount,
    required this.causeSupported,
    this.initialCause = '',
    this.onDraftChanged,
  });
  @override
  State<RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<RatingDialog> {
  late final TextEditingController _cause = TextEditingController(
    text: widget.initialCause,
  );
  final _fieldKey = GlobalKey();
  int _score = 5;
  bool _finished = false;
  @override
  void dispose() {
    _cause.dispose();
    super.dispose();
  }

  void _finish([({int score, String cause})? result]) {
    if (_finished) return;
    _finished = true;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final compact =
        widget.causeSupported &&
        media.size.width >= 600 &&
        media.size.height - media.viewInsets.bottom < 260;
    final actions = <Widget>[
      TextButton(onPressed: _finish, child: const Text('취소')),
      FilledButton(
        onPressed: RatingService.causeError(_cause.text) != null
            ? null
            : () => _finish((
                score: _score,
                cause: widget.causeSupported
                    ? RatingService.normalizeCause(_cause.text)
                    : '',
              )),
        child: const Text('확인'),
      ),
    ];
    Widget field() => KeyedSubtree(
      key: const Key('rating-cause-field'),
      child: TextField(
        key: _fieldKey,
        controller: _cause,
        minLines: 1,
        maxLines: compact ? 2 : 4,
        onChanged: (value) {
          widget.onDraftChanged?.call(value);
          setState(() {});
        },
        decoration: InputDecoration(
          isDense: compact,
          labelText: compact ? null : '공통 사유 (선택)',
          hintText: compact ? '공통 사유 (선택)' : '예: 신속하게 처리해 주셔서 감사합니다.',
          helperText: compact ? null : '선택한 모든 건에 같은 사유를 함께 제출합니다.',
          helperMaxLines: 4,
          errorMaxLines: 4,
          counterText: compact
              ? ''
              : '${RatingService.normalizeCause(_cause.text).runes.length} / ${RatingService.ratingCauseMax}자',
          errorText: RatingService.causeError(_cause.text),
        ),
      ),
    );
    if (compact) {
      // Insets select the layout only; Dialog applies keyboard padding once.
      // Side actions preserve an editable viewport when a landscape IME and
      // large fonts leave too little height for actions below the input.
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SizedBox(
          width: 800,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(child: SingleChildScrollView(child: field())),
                const SizedBox(width: 12),
                Row(mainAxisSize: MainAxisSize.min, children: actions),
              ],
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      scrollable: true,
      title: const Text('별점 주기'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('선택한 ${widget.count}건에 대해 부여할 별점을 선택하세요.'),
          const SizedBox(height: 8),
          Text(
            '진행 가능 ${widget.eligibleCount}건, 자동 스킵 ${widget.count - widget.eligibleCount}건',
            style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(5, (index) {
              final score = index + 1;
              return ChoiceChip(
                selected: _score == score,
                label: Text('$score점'),
                avatar: Icon(
                  Icons.star,
                  size: 18,
                  color: _score == score
                      ? Theme.of(context).colorScheme.primary
                      : context.sr.textDisabled,
                ),
                onSelected: (_) => setState(() => _score = score),
              );
            }),
          ),
          const SizedBox(height: 16),
          if (widget.causeSupported)
            field()
          else
            Text(
              '서버를 업데이트하면 사유도 함께 보낼 수 있습니다.',
              style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
            ),
        ],
      ),
      actions: actions,
    );
  }
}
