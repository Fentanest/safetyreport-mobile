/// SharedPreferences 키 단일 소스.
///
/// 화면/위젯/서비스 어디서든 raw 문자열 대신 이 상수를 사용한다.
/// Kotlin 측은 `flutter.` prefix 가 붙은 동일 이름을 직접 알고 있으므로,
/// 여기서 키를 바꾸면 Kotlin 쪽도 같이 바꿔야 한다 (CLAUDE.md 의 키 표 참고).
class AppPrefsKeys {
  AppPrefsKeys._();

  // 모드 / 자격증명
  static const appMode = 'appMode';
  static const baseUrl = 'baseUrl';
  static const apiKey = 'apiKey';
  static const standaloneUsername = 'standaloneUsername';
  static const standalonePhoneNumber = 'standalonePhoneNumber';
  static const standaloneDemoMode = 'standaloneDemoMode';
  static const standaloneKakaoRestApiKey = 'standaloneKakaoRestApiKey';
  static const standaloneToken = 'standaloneToken';
  static const standaloneTokenExpiresAt = 'standaloneTokenExpiresAt';
  static const standaloneSyncTime = 'standaloneSyncTime';

  /// FlutterSecureStorage (Keystore) 에 저장하는 비밀번호 키.
  static const standalonePassword = 'standalone_password';

  // 큐 / 이벤트 (Kotlin 과 공유)
  static const standalonePendingReports = 'standalone_pending_reports';
  static const standaloneLastDetectedAt = 'standalone_last_detected_at';
  static const foregroundEvent = 'foreground_event';
  static const pendingCrawlChanges = 'pending_crawl_changes';
  static const notificationsHistory = 'notifications_history';

  // 자동 enqueue 알림 억제
  static const autoEnqueueCount = 'auto_enqueue_count';
  static const autoEnqueueLastAt = 'auto_enqueue_last_at';

  // DB 모드 전환 시 setup_screen 이 적용할 임시 액션
  static const pendingDbImport = 'pending_db_import';
}
