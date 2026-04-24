enum AppMode { server, standalone }

extension AppModeX on AppMode {
  String get displayName =>
      this == AppMode.server ? 'Client 모드' : '직접 연결 (스탠드어론)';

  static AppMode fromString(String? s) => AppMode.values.firstWhere(
        (m) => m.name == s,
        orElse: () => AppMode.server,
      );
}
