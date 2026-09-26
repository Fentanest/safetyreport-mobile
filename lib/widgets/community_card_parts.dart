import 'package:flutter/material.dart';

import '../theme/sr_colors.dart';

/// 커뮤니티 계정 카드(Standalone/Client) 공용 조각. 색은 테마 토큰만 쓴다.

String formatCommunityTime(DateTime? t) {
  if (t == null) return '-';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

class CommunityCardHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const CommunityCardHeader({
    super.key,
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: cs.primary,
            ),
          ),
        ),
      ],
    );
  }
}

enum CommunityTone { neutral, positive, attention, danger }

/// 상태 한 줄: 점 + 라벨.
class CommunityStatusLine extends StatelessWidget {
  final String label;
  final CommunityTone tone;
  const CommunityStatusLine({
    super.key,
    required this.label,
    this.tone = CommunityTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = communityTone(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: t.border),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: t.foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

StatusTone communityTone(BuildContext context, CommunityTone tone) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final base = switch (tone) {
    CommunityTone.neutral => cs.onSurfaceVariant,
    CommunityTone.positive => cs.primary,
    CommunityTone.attention => cs.tertiary,
    CommunityTone.danger => cs.error,
  };
  return StatusTone.of(base, brightness: theme.brightness, surface: cs.surface);
}

/// 틴트 안내 상자.
class CommunityNoticeBox extends StatelessWidget {
  final String text;
  final IconData icon;
  final CommunityTone tone;
  const CommunityNoticeBox({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.tone = CommunityTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = communityTone(context, tone);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: t.foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 라벨: 값 (좁은 폭·큰 글꼴에서 줄바꿈).
class CommunityInfoRow extends StatelessWidget {
  final String label;
  final String value;
  const CommunityInfoRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// 버튼 여러 개를 폭에 맞춰 줄바꿈해 놓는다(텍스트 배율 2.0 대비).
class CommunityButtonBar extends StatelessWidget {
  final List<Widget> children;
  const CommunityButtonBar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: children,
      ),
    );
  }
}
