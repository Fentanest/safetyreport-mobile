import 'package:flutter/material.dart';

import '../server_palette.dart';
import '../theme/sr_colors.dart';

/// 공용 빈 목록 / 오류 상태(SQ-U21). 대시보드 오류 화면(아이콘 · 제목 · 설명 · 동작)과 같은 구성이다.
///
/// - 빈 상태: 흐린 아이콘 + 제목 + 설명(+ 선택 동작).
/// - 오류 상태([SrEmptyState.error]): 오류 톤 아이콘 + 원문 상자(있으면) + "다시 시도" 버튼.
///   오류가 빈 목록과 같은 문구로 보이지 않게 한다.
///
/// [scrollable] 이 true(기본)면 남은 높이를 채우는 스크롤 영역으로 감싸 `RefreshIndicator` 당김이 동작한다.
class SrEmptyState extends StatelessWidget {
  const SrEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.scrollable = true,
  }) : isError = false,
       detail = null,
       onRetry = null;

  const SrEmptyState.error({
    super.key,
    this.icon = Icons.error_outline_rounded,
    this.title = '데이터를 불러오지 못했습니다',
    this.message = '잠시 뒤 다시 시도하세요.',
    this.detail,
    required VoidCallback this.onRetry,
    this.action,
    this.scrollable = true,
  }) : isError = true;

  final IconData icon;
  final String title;
  final String? message;

  /// 오류 원문(선택 가능한 오류 톤 상자로 보인다). 오류 상태에서만 쓴다.
  final String? detail;

  /// 오류 상태의 "다시 시도".
  final VoidCallback? onRetry;

  /// 추가 동작(예: "설정 확인", "조건 초기화").
  final Widget? action;
  final bool isError;
  final bool scrollable;

  static const retryKey = ValueKey('sr-empty-state-retry');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sr = context.sr;
    final tone = StatusTone.of(
      serverRejectColor,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 56,
            color: isError ? tone.foreground : sr.textDisabled,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: sr.textPrimary,
            ),
          ),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: sr.textSecondary,
                height: 1.45,
              ),
            ),
          ],
          if (isError && detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tone.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: tone.border),
              ),
              child: SelectableText(
                detail!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tone.foreground,
                  height: 1.5,
                ),
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              key: retryKey,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
              onPressed: onRetry,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
    final semantic = Semantics(
      container: true,
      liveRegion: isError,
      child: Center(child: content),
    );
    if (!scrollable) return semantic;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
            minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
          ),
          child: semantic,
        ),
      ),
    );
  }
}
