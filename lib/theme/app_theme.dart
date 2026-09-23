import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'sr_colors.dart';

/// 앱 공통 테마. 두 실행 모드가 같은 primary 를 쓰고(D-03), 모드는 `ModeBadge` 로 따로 표시한다.
/// 글꼴은 기기 기본(D-04)이라 fontFamily 를 지정하지 않는다.
class AppTheme {
  AppTheme._();

  /// 라이트 primary. 토큰 `#0D6EFD` 는 흰 글자 대비가 4.50:1 경계라 한 단계 어둡게 쓴다(5.84:1).
  static const lightPrimary = Color(0xFF0B5ED7);

  /// 다크 primary. 슬레이트 surface 위 글자/아이콘 대비 6.98:1, onPrimary 는 어두운 글자.
  static const darkPrimary = Color(0xFF60A5FA);

  static ThemeData light() => build(Brightness.light);
  static ThemeData dark() => build(Brightness.dark);

  static ThemeData build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final t = isDark ? SrColors.dark : SrColors.light;
    final primary = isDark ? darkPrimary : lightPrimary;
    final onPrimary = isDark ? t.background : Colors.white;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: t.brandSoft,
      onPrimaryContainer: isDark
          ? const Color(0xFFDBEAFE)
          : const Color(0xFF0B3C8C),
      secondary: isDark ? const Color(0xFF22D3EE) : const Color(0xFF0E7490),
      onSecondary: isDark ? t.background : Colors.white,
      // FilledButton.tonal 등이 쓰는 컨테이너. 지정하지 않으면 secondary 원색으로 칠해져 튄다.
      secondaryContainer: t.brandSoft,
      onSecondaryContainer: isDark
          ? const Color(0xFFDBEAFE)
          : const Color(0xFF0B3C8C),
      tertiaryContainer: t.surfaceAlt,
      onTertiaryContainer: t.textPrimary,
      errorContainer: isDark
          ? const Color(0xFF450A0A)
          : const Color(0xFFFEE2E2),
      onErrorContainer: isDark
          ? const Color(0xFFFECACA)
          : const Color(0xFF991B1B),
      error: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
      onError: isDark ? t.background : Colors.white,
      surface: t.surface,
      onSurface: t.textPrimary,
      onSurfaceVariant: t.textSecondary,
      surfaceContainerLowest: isDark ? t.background : Colors.white,
      surfaceContainerLow: t.surface,
      surfaceContainer: t.surfaceAlt,
      surfaceContainerHigh: isDark
          ? const Color(0xFF273244)
          : const Color(0xFFE9EEF5),
      surfaceContainerHighest: isDark
          ? const Color(0xFF2E3A4F)
          : const Color(0xFFE2E8F0),
      outline: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
      outlineVariant: t.border,
      inverseSurface: isDark ? t.textPrimary : const Color(0xFF1E293B),
      onInverseSurface: isDark ? t.background : const Color(0xFFF8FAFC),
      inversePrimary: isDark ? lightPrimary : darkPrimary,
      shadow: Colors.black,
      scrim: Colors.black,
    );

    // edge-to-edge: 아이콘 밝기만 조정하고 statusBarColor 는 싣지 않는다(docs/architecture/android-runtime.md).
    final overlayStyle = SystemUiOverlayStyle(
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
      systemStatusBarContrastEnforced: false,
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      borderSide: BorderSide(color: t.border),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: [t],
      scaffoldBackgroundColor: t.background,
      canvasColor: t.background,
      dividerColor: t.border,
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: t.background,
        foregroundColor: t.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: overlayStyle,
        titleTextStyle: TextStyle(
          color: t.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        // 시안의 알약형 선택 탭. 선택/미선택 모두 배경 대비 AA 를 만족해야 한다(test/theme).
        indicator: BoxDecoration(
          color: primary,
          borderRadius: BorderRadius.circular(999),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorColor: primary,
        dividerColor: Colors.transparent,
        labelColor: onPrimary,
        unselectedLabelColor: t.textSecondary,
        labelStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
        splashBorderRadius: BorderRadius.circular(999),
        overlayColor: WidgetStatePropertyAll(primary.withValues(alpha: 0.08)),
      ),
      cardTheme: CardThemeData(
        color: t.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: t.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface,
        modalBackgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: t.textDisabled,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? t.surfaceAlt : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        labelStyle: TextStyle(color: t.textSecondary),
        hintStyle: TextStyle(color: t.textSecondary),
        prefixIconColor: t.textSecondary,
        suffixIconColor: t.textSecondary,
        border: inputBorder,
        enabledBorder: inputBorder,
        disabledBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: t.border.withValues(alpha: 0.6)),
        ),
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: primary, width: 1.4),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.surface,
        elevation: 0,
        height: 68,
        indicatorColor: isDark ? primary.withValues(alpha: 0.22) : t.brandSoft,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? primary
                : t.textSecondary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? primary
                : t.textSecondary,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: primary,
        textColor: t.textPrimary,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: t.surfaceAlt,
        side: BorderSide(color: t.border),
        labelStyle: TextStyle(color: t.textPrimary, fontSize: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          side: BorderSide(color: t.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(t.border),
      ),
    );
  }
}
