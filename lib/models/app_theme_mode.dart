import 'package:flutter/material.dart';

enum AppThemeMode { system, light, dark }

extension AppThemeModeX on AppThemeMode {
  ThemeMode get themeMode {
    switch (this) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }

  String get label {
    switch (this) {
      case AppThemeMode.system:
        return '시스템 설정 사용';
      case AppThemeMode.light:
        return '라이트 모드';
      case AppThemeMode.dark:
        return '다크 모드';
    }
  }

  static AppThemeMode fromString(String? value) {
    return AppThemeMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AppThemeMode.system,
    );
  }
}
