import 'package:flutter/material.dart';

import '../models/report.dart';
import '../server_palette.dart';
import '../services/fine_estimate.dart' as fine_estimate;
import '../theme/sr_colors.dart';
import '../utils/format.dart';
import 'status_badge.dart';
import '../theme/sr_tokens.dart';

/// "추정 50,000원" 같은 흐린 보조 표기, 추정 대상이 아니면 null (row-estimate, 2026-10-12).
/// 대상 판정·계산은 [fine_estimate.estimateForReport] 를 그대로 쓴다(통계·커뮤니티 payload 와 같은
/// 함수 — 대상 판정 중복 구현 금지). [ReportCardMetaItem.fine] 과 목록·카드를 보이는 다른 화면
/// (watchlist/recent_answers/dashboard 의 자체 메타 행)이 함께 쓴다.
String? fineEstimateSuffix(Report report) {
  final est = fine_estimate.estimateForReport(report);
  if (est == null) return null;
  return '추정 ${formatWon(est['amount'] as int)}';
}

class ReportCardMetaItem {
  final IconData icon;
  final String text;

  /// 흐린 보조 표기(예: 추정 과태료 "추정 50,000원"). 확정 값([text])과 다른 색으로 이어 붙는다.
  final String? secondaryText;

  /// 스크린리더용 전체 라벨. 없으면 [text] + [secondaryText] 를 이어 읽는다.
  final String? semanticsLabel;

  const ReportCardMetaItem({
    required this.icon,
    required this.text,
    this.secondaryText,
    this.semanticsLabel,
  });

  /// 과태료/범칙금 메타 항목. 금액 없이 "과태료"만 있는 행에 법정 최저 기준 추정을 보조 표기로 더한다.
  /// 확정 값(원문)은 바꾸지 않는다.
  factory ReportCardMetaItem.fine(Report report) {
    final text = report.fineInfo;
    final suffix = fineEstimateSuffix(report);
    if (suffix == null) {
      return ReportCardMetaItem(icon: Icons.monetization_on_outlined, text: text);
    }
    return ReportCardMetaItem(
      icon: Icons.monetization_on_outlined,
      text: text,
      secondaryText: suffix,
      semanticsLabel: '$text, ${suffix.replaceFirst('추정', '추정 금액')}',
    );
  }
}

Color reportStatusColor(String status) {
  return serverStatusColor(status);
}

/// 신고 카드 공용 UI (`report_list`/`search`/`filtered_list`/지도 미변환 목록).
///
/// 표시 필드: 신고명, 처리상태, headerSuffix, 신고번호, 보완횟수/보완 요청자, 메타 행, 차량번호.
/// 긴 신고명·기관명·차량번호가 다른 정보를 밀어내지 않도록 모든 가로 요소가 줄어들 수 있다.
class ReportListCard extends StatelessWidget {
  final Report report;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final List<ReportCardMetaItem> metaItems;
  final Widget? headerSuffix;

  const ReportListCard({
    super.key,
    required this.report,
    required this.selectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.metaItems,
    this.headerSuffix,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sr = context.sr;
    final supplementRequester = report.supplementRequester.trim();
    final supplementTone = StatusTone.of(
      serverSupplementColor,
      brightness: theme.brightness,
      surface: scheme.surface,
    );
    final visibleMetaItems = metaItems
        .where((item) => item.text.trim().isNotEmpty)
        .toList(growable: false);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SrRadius.lg),
        side: BorderSide(
          color: isSelected ? scheme.primary : sr.border,
          width: isSelected ? 2 : 1,
        ),
      ),
      color: isSelected ? sr.brandSoft : scheme.surface,
      child: InkWell(
        borderRadius: BorderRadius.circular(SrRadius.lg),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 10, top: 1),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isSelected ? scheme.primary : sr.textSecondary,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            report.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                              height: 1.3,
                              color: sr.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: StatusBadge.status(report.status),
                        ),
                        if (headerSuffix != null) ...[
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 96),
                            child: headerSuffix!,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.tag, size: 13, color: sr.textSecondary),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            report.reportNumber,
                            style: TextStyle(
                              color: sr.textSecondary,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (report.supplementCount > 0) ...[
                          const SizedBox(width: 6),
                          StatusBadge(
                            label: '보완횟수:${report.supplementCount}회',
                            color: serverSupplementColor,
                            fontSize: SrFontSize.caption,
                          ),
                        ],
                      ],
                    ),
                    if (report.supplementCount > 0 &&
                        supplementRequester.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.history_edu,
                            size: 12,
                            color: supplementTone.foreground,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '보완 요청자: $supplementRequester',
                              style: TextStyle(
                                color: supplementTone.foreground,
                                fontSize: SrFontSize.caption,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    Divider(height: 16, color: sr.border),
                    _MetaAndCarNumber(
                      metaItems: visibleMetaItems,
                      carNumber: report.carNumber,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 메타 정보 열 + 차량번호 칩.
///
/// 칩은 먼저 자기 폭(글자 배율 반영)을 받고 메타 열이 남은 폭을 말줄임으로 쓴다(L-8).
/// 칩이 행 폭의 [_chipMaxFraction] 을 넘으면(좁은 폭·큰 글자) 자르지 않고 메타 열 아래로 내린다.
class _MetaAndCarNumber extends StatelessWidget {
  final List<ReportCardMetaItem> metaItems;
  final String carNumber;

  const _MetaAndCarNumber({required this.metaItems, required this.carNumber});

  static const double _gap = 8;
  static const double _chipMaxFraction = 0.5;

  @override
  Widget build(BuildContext context) {
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < metaItems.length; i++) ...[
          if (i > 0) const SizedBox(height: 3),
          _MetaRow(
            icon: metaItems[i].icon,
            text: metaItems[i].text,
            secondaryText: metaItems[i].secondaryText,
            semanticsLabel: metaItems[i].semanticsLabel,
          ),
        ],
      ],
    );
    if (carNumber.isEmpty) return meta;

    final chip = _CarNumberChip(carNumber: carNumber);
    return LayoutBuilder(
      builder: (context, constraints) {
        final chipWidth = _CarNumberChip.intrinsicWidth(context, carNumber);
        final besideMeta =
            chipWidth <= constraints.maxWidth * _chipMaxFraction;
        if (besideMeta) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: meta),
              const SizedBox(width: _gap),
              chip,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (metaItems.isNotEmpty) ...[meta, const SizedBox(height: 6)],
            Align(alignment: Alignment.centerRight, child: chip),
          ],
        );
      },
    );
  }
}

class _MetaRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? secondaryText;
  final String? semanticsLabel;

  const _MetaRow({
    required this.icon,
    required this.text,
    this.secondaryText,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    final baseStyle = TextStyle(color: sr.textSecondary, fontSize: 12);
    final hasSecondary = secondaryText != null && secondaryText!.isNotEmpty;
    final textWidget = hasSecondary
        ? Text.rich(
            TextSpan(
              children: [
                TextSpan(text: text),
                TextSpan(
                  text: ' $secondaryText',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            ),
            style: baseStyle,
            overflow: TextOverflow.ellipsis,
          )
        : Text(text, style: baseStyle, overflow: TextOverflow.ellipsis);

    final row = Row(
      children: [
        Icon(icon, size: 12, color: sr.textSecondary),
        const SizedBox(width: 4),
        Expanded(child: textWidget),
      ],
    );
    if (!hasSecondary) return row;
    return Semantics(
      label: semanticsLabel ?? '$text $secondaryText',
      excludeSemantics: true,
      child: row,
    );
  }
}

class _CarNumberChip extends StatelessWidget {
  final String carNumber;

  const _CarNumberChip({required this.carNumber});

  static const _padding = EdgeInsets.symmetric(horizontal: 10, vertical: 5);
  static const double _borderWidth = 1;
  static const _textStyle = TextStyle(
    fontWeight: FontWeight.w700,
    fontSize: 13,
    letterSpacing: 0.4,
  );

  /// 말줄임 없이 그릴 때의 칩 폭(현재 글꼴·글자 배율 기준).
  static double intrinsicWidth(BuildContext context, String carNumber) {
    final painter = TextPainter(
      text: TextSpan(
        text: carNumber,
        style: DefaultTextStyle.of(context).style.merge(_textStyle),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width + _padding.horizontal + _borderWidth * 2;
  }

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    return Container(
      padding: _padding,
      decoration: BoxDecoration(
        color: sr.surfaceAlt,
        borderRadius: BorderRadius.circular(SrRadius.md),
        border: Border.all(color: sr.border, width: _borderWidth),
      ),
      child: Text(
        carNumber,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _textStyle.copyWith(color: sr.textPrimary),
      ),
    );
  }
}
