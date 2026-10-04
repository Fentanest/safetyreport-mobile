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

  /// 키보드 압축 배치인지(직전 build 기준).
  bool _keyboardCompact = false;

  /// 세로 화면 + 키보드에서 이 높이(글자 배율 반영)보다 남은 높이가 작으면 압축 배치를 쓴다.
  static const double _keyboardCompactHeight = 480;
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

  /// 입력칸(글자 수 줄 포함)이 대화상자 스크롤 영역 안에 다 보이게 맞춘다.
  void _revealField() {
    final fieldContext = _fieldKey.currentContext;
    if (!mounted || !_keyboardCompact || fieldContext == null) return;
    Scrollable.ensureVisible(
      fieldContext,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final inset = media.viewInsets.bottom;
    final available = media.size.height - inset;
    final compact =
        widget.causeSupported && media.size.width >= 600 && available < 260;
    // L-7: 세로 화면에서 키보드가 열려 남은 높이가 작으면 설명 문구(안내·건수·도움말)를 접고
    // 입력칸을 3줄 이상 + 글자 수와 함께 보이게 한다. 키보드를 닫으면 원래 배치로 돌아온다.
    final keyboardCompact =
        widget.causeSupported &&
        !compact &&
        inset > 0 &&
        available < media.textScaler.scale(_keyboardCompactHeight);
    if (keyboardCompact && !_keyboardCompact) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealField());
    }
    _keyboardCompact = keyboardCompact;
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
        minLines: keyboardCompact ? 3 : 1,
        maxLines: compact ? 2 : 4,
        onChanged: (value) {
          widget.onDraftChanged?.call(value);
          setState(() {});
        },
        decoration: InputDecoration(
          isDense: compact,
          labelText: compact ? null : '공통 사유 (선택)',
          hintText: compact ? '공통 사유 (선택)' : '예: 신속하게 처리해 주셔서 감사합니다.',
          helperText: compact || keyboardCompact
              ? null
              : '선택한 모든 건에 같은 사유를 함께 제출합니다.',
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
    // Dialog 는 키보드 높이를 짧은 애니메이션으로 반영한다. 스크롤 영역 크기가 바뀔 때마다 다시 맞춘다.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (_keyboardCompact && notification.depth == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _revealField());
        }
        return false;
      },
      child: _fullDialog(context, actions, field, keyboardCompact),
    );
  }

  Widget _fullDialog(
    BuildContext context,
    List<Widget> actions,
    Widget Function() field,
    bool keyboardCompact,
  ) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      scrollable: true,
      title: const Text('별점 주기'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!keyboardCompact) ...[
            Text('선택한 ${widget.count}건에 대해 부여할 별점을 선택하세요.'),
            const SizedBox(height: 8),
            Text(
              '진행 가능 ${widget.eligibleCount}건, 자동 스킵 ${widget.count - widget.eligibleCount}건',
              style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
            ),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(5, (index) {
              final score = index + 1;
              return ChoiceChip(
                selected: _score == score,
                // 선택은 채움색으로 보인다. 체크 표시가 별 아이콘을 덮던 문제(L-7).
                showCheckmark: false,
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
          SizedBox(height: keyboardCompact ? 12 : 16),
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
