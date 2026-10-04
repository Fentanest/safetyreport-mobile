import 'dart:math' as math;

import 'package:flutter/material.dart';

/// UI 리뉴얼 디자인 토큰. 정의와 출처는 `docs/design/ui-renewal-spec.md` §2.
///
/// - 라이트: 토큰 보드 라이트 값.
/// - 다크: B안 "딥 다크"(2026-09-25 사용자 결정) — 채도 거의 없는 검정 계단. 서버 웹 `web/static/ui/tokens.css` 다크와 같은 값
///   (대응표 `docs/design/dark-palette.md`). 예전 슬레이트(푸른 기) 값은 D-01(2026-09-24).
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

  /// 의미색(SQ-U23). 글자·아이콘으로 바로 써도 [surface]/[background] 위 AA 이고,
  /// 틴트 칩·박스는 `context.tone(SrTone.x)`([StatusTone])로 만든다.
  final Color success;
  final Color warning;
  final Color info;

  /// 흰 글자를 올리는 채움(SnackBar·채운 버튼). 두 테마 같은 값, 흰 글자 5.0:1 이상.
  final Color successFill;
  final Color warningFill;
  final Color dangerFill;

  /// 신고 분류 식별색(교통 파랑 / 주정차 주황 / 기타 초록 — 통계 화면 규칙). 글자는 [StatusTone] 으로 보정한다.
  final Color categoryTraffic;
  final Color categoryParking;
  final Color categoryOther;

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
    required this.success,
    required this.warning,
    required this.info,
    required this.successFill,
    required this.warningFill,
    required this.dangerFill,
    required this.categoryTraffic,
    required this.categoryParking,
    required this.categoryOther,
  });

  /// 크롤링/동기화 로그 창 바탕. 라이트/다크 모두 어두운 터미널로 고정한다(spec §8 결정, SQ-U18).
  static const logPanel = Color(0xFF1E1E1E);

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
    success: Color(0xFF15803D), // green-700
    warning: Color(0xFFB45309), // amber-700
    info: Color(0xFF0369A1), // sky-700
    successFill: srSnackSuccess,
    warningFill: srSnackWarning,
    dangerFill: srSnackError,
    categoryTraffic: Color(0xFF0D6EFD), // = brand
    categoryParking: Color(0xFFF59E0B),
    categoryOther: Color(0xFF22C55E),
  );

  static const dark = SrColors(
    background: Color(0xFF0B0B0C), // web --sr-bg
    surface: Color(0xFF131314), // --sr-surface
    surfaceAlt: Color(0xFF1B1B1C), // --sr-surface-2
    border: Color(0xFF2D2D2F), // --sr-border
    textPrimary: Color(0xFFF3F3F4), // --sr-text
    textSecondary: Color(0xFF9EA0A4), // --sr-text-muted
    textDisabled: Color(0xFF6B6D72),
    brand: Color(0xFF2563EB), // --sr-primary (채움, 흰 글자 5.17:1)
    brandSoft: Color(0xFF192436), // --sr-primary-soft 를 surface 위에 합성한 값
    modeClient: Color(0xFF60A5FA),
    modeStandalone: Color(0xFF4ADE80),
    success: Color(0xFF4ADE80), // green-400
    warning: Color(0xFFFBBF24), // amber-400
    info: Color(0xFF38BDF8), // sky-400
    successFill: srSnackSuccess,
    warningFill: srSnackWarning,
    dangerFill: srSnackError,
    categoryTraffic: Color(0xFF2563EB), // = brand
    categoryParking: Color(0xFFF59E0B),
    categoryOther: Color(0xFF22C55E),
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
    Color? success,
    Color? warning,
    Color? info,
    Color? successFill,
    Color? warningFill,
    Color? dangerFill,
    Color? categoryTraffic,
    Color? categoryParking,
    Color? categoryOther,
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
      success: success ?? this.success,
      warning: warning ?? this.warning,
      info: info ?? this.info,
      successFill: successFill ?? this.successFill,
      warningFill: warningFill ?? this.warningFill,
      dangerFill: dangerFill ?? this.dangerFill,
      categoryTraffic: categoryTraffic ?? this.categoryTraffic,
      categoryParking: categoryParking ?? this.categoryParking,
      categoryOther: categoryOther ?? this.categoryOther,
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
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      successFill: Color.lerp(successFill, other.successFill, t)!,
      warningFill: Color.lerp(warningFill, other.warningFill, t)!,
      dangerFill: Color.lerp(dangerFill, other.dangerFill, t)!,
      categoryTraffic: Color.lerp(categoryTraffic, other.categoryTraffic, t)!,
      categoryParking: Color.lerp(categoryParking, other.categoryParking, t)!,
      categoryOther: Color.lerp(categoryOther, other.categoryOther, t)!,
    );
  }

  /// 분류 키(`traffic`/`parking`/`other`)의 식별색. 모르는 키는 보조 글자색.
  Color category(String key) => switch (key) {
    'traffic' => categoryTraffic,
    'parking' => categoryParking,
    'other' => categoryOther,
    _ => textSecondary,
  };
}

/// 성공/경고/실패 SnackBar·채움 배경. 흰 글자 대비 5.0:1 / 5.0:1 / 6.5:1 (Material green/orange/red 기본색은 AA 미달).
/// 두 테마 같은 값이다 — 다크의 기본 SnackBar 글자(onInverseSurface)는 어두워서 이 배경에는 흰 글자를 따로 준다(`showSrSnack`).
const srSnackSuccess = Color(0xFF15803D);
const srSnackWarning = Color(0xFFB45309);
const srSnackError = Color(0xFFB91C1C);

/// 의미 톤. `context.tone(SrTone.success)` 처럼 [StatusTone] 으로 받아 틴트 배경·테두리·AA 글자를 함께 쓴다.
enum SrTone { primary, success, warning, info, danger, neutral }

extension SrColorsContext on BuildContext {
  SrColors get sr {
    final theme = Theme.of(this);
    return theme.extension<SrColors>() ??
        (theme.brightness == Brightness.dark ? SrColors.dark : SrColors.light);
  }

  /// [tone] 의 기준색(글자·아이콘으로 바로 써도 표면 위 AA).
  Color semantic(SrTone tone) {
    final sr = this.sr;
    return switch (tone) {
      SrTone.primary => Theme.of(this).colorScheme.primary,
      SrTone.success => sr.success,
      SrTone.warning => sr.warning,
      SrTone.info => sr.info,
      SrTone.danger => Theme.of(this).colorScheme.error,
      SrTone.neutral => sr.textSecondary,
    };
  }

  /// 의미 톤을 현재 테마의 [surface](기본: 카드 표면) 위 틴트 묶음으로.
  /// 예전의 이중 호출(원색 → StatusTone 글자색 → 다시 StatusTone)을 대신한다(SQ-U23).
  StatusTone tone(SrTone tone, {Color? surface}) =>
      toneOf(semantic(tone), surface: surface);

  /// 임의 기준색(상태색·분류색 등)을 현재 테마의 [surface] 위 틴트 묶음으로.
  StatusTone toneOf(Color base, {Color? surface}) => StatusTone.of(
    base,
    brightness: Theme.of(this).brightness,
    surface: surface ?? sr.surface,
  );
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
