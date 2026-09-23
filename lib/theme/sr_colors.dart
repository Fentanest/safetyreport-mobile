import 'dart:math' as math;

import 'package:flutter/material.dart';

/// UI 리뉴얼 디자인 토큰. 정의와 출처는 `docs/design/ui-renewal-spec.md` §2.
///
/// - 라이트: 토큰 보드 라이트 값.
/// - 다크: 토큰 보드의 슬레이트 값 (D-01, 2026-09-24 사용자 결정).
/// 화면 코드는 색을 직접 쓰지 말고 `context.sr` 또는 `Theme.of(context).colorScheme` 을 읽는다.
@immutable
class SrColors extends ThemeExtension<SrColors> {
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;

  /// 브랜드 파랑(차트·장식용). 글자/버튼 채움은 대비를 맞춘 `ColorScheme.primary` 를 쓴다.
  final Color brand;
  final Color brandSoft;

  /// 실행 모드 식별색 (D-03: primary 통합 후 모드는 별도 표시).
  final Color modeClient;
  final Color modeStandalone;

  const SrColors({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.brand,
    required this.brandSoft,
    required this.modeClient,
    required this.modeStandalone,
  });

  static const light = SrColors(
    background: Color(0xFFF8FAFC),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF1F5F9),
    border: Color(0xFFE2E8F0),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF64748B),
    textDisabled: Color(0xFF94A3B8),
    brand: Color(0xFF0D6EFD),
    brandSoft: Color(0xFFE7F1FF),
    modeClient: Color(0xFF0D6EFD),
    modeStandalone: Color(0xFF16A34A),
  );

  static const dark = SrColors(
    background: Color(0xFF0B1220),
    surface: Color(0xFF111827),
    surfaceAlt: Color(0xFF1F2937),
    border: Color(0xFF334155),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFFCBD5E1),
    textDisabled: Color(0xFF64748B),
    brand: Color(0xFF0D6EFD),
    brandSoft: Color(0xFF172554),
    modeClient: Color(0xFF60A5FA),
    modeStandalone: Color(0xFF4ADE80),
  );

  @override
  SrColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? brand,
    Color? brandSoft,
    Color? modeClient,
    Color? modeStandalone,
  }) {
    return SrColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      brand: brand ?? this.brand,
      brandSoft: brandSoft ?? this.brandSoft,
      modeClient: modeClient ?? this.modeClient,
      modeStandalone: modeStandalone ?? this.modeStandalone,
    );
  }

  @override
  SrColors lerp(ThemeExtension<SrColors>? other, double t) {
    if (other is! SrColors) return this;
    return SrColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      brandSoft: Color.lerp(brandSoft, other.brandSoft, t)!,
      modeClient: Color.lerp(modeClient, other.modeClient, t)!,
      modeStandalone: Color.lerp(modeStandalone, other.modeStandalone, t)!,
    );
  }
}

extension SrColorsContext on BuildContext {
  SrColors get sr {
    final theme = Theme.of(this);
    return theme.extension<SrColors>() ??
        (theme.brightness == Brightness.dark ? SrColors.dark : SrColors.light);
  }
}

/// WCAG 2.x 대비. 반투명 전경은 반드시 [background] 위에 합성한 뒤 계산한다
/// (`computeLuminance()` 는 alpha 를 무시하므로 그대로 쓰면 거짓 통과한다).
double contrastRatio(Color foreground, Color background) {
  final opaqueBackground = background.a < 1.0
      ? Color.alphaBlend(background, Colors.white)
      : background;
  final composited = Color.alphaBlend(foreground, opaqueBackground);
  final l1 = composited.computeLuminance();
  final l2 = opaqueBackground.computeLuminance();
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

/// 상태·처분 배지 색 묶음. [foreground] 는 [background] 대비 4.5:1 이상이 되도록 보정된다.
@immutable
class StatusTone {
  final Color base;
  final Color foreground;
  final Color background;
  final Color border;

  const StatusTone({
    required this.base,
    required this.foreground,
    required this.background,
    required this.border,
  });

  static const double minContrast = 4.5;

  /// [base] 상태색을 [surface] 위 틴트 배지로 만든다.
  /// 라이트는 글자를 어둡게, 다크는 밝게 조금씩 옮겨 AA 를 맞춘다.
  factory StatusTone.of(
    Color base, {
    required Brightness brightness,
    required Color surface,
  }) {
    final isDark = brightness == Brightness.dark;
    final background = Color.alphaBlend(
      base.withValues(alpha: isDark ? 0.22 : 0.12),
      surface,
    );
    final border = Color.alphaBlend(
      base.withValues(alpha: isDark ? 0.45 : 0.35),
      surface,
    );
    final target = isDark ? Colors.white : Colors.black;
    var foreground = base;
    for (
      var step = 1;
      step <= 20 && contrastRatio(foreground, background) < minContrast;
      step++
    ) {
      foreground = Color.lerp(base, target, step * 0.05)!;
    }
    return StatusTone(
      base: base,
      foreground: foreground,
      background: background,
      border: border,
    );
  }
}
