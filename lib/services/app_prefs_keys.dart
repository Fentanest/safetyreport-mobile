/// SharedPreferences 키 단일 소스.
///
/// 화면/위젯/서비스 어디서든 raw 문자열 대신 이 상수를 사용한다.
/// Kotlin 측은 `flutter.` prefix 가 붙은 동일 이름을 직접 알고 있으므로,
/// 여기서 키를 바꾸면 Kotlin 쪽도 같이 바꿔야 한다 (CLAUDE.md 의 키 표 참고).
class AppPrefsKeys {
  AppPrefsKeys._();

  // 모드 / 자격증명
  static const appMode = 'appMode';
  static const themeMode = 'themeMode';
  static const baseUrl = 'baseUrl';
  static const apiKey = 'apiKey';
  static const standaloneUsername = 'standaloneUsername';
  static const standalonePhoneNumber = 'standalonePhoneNumber';
  static const standaloneDemoMode = 'standaloneDemoMode';

  /// 서버 변경 기록의 기기별 읽은 위치에 쓰는 식별자(설치마다 한 번 만듦, 개인정보 아님 — 저장 계층 재설계 R5).
  static const deviceInstallId = 'deviceInstallId';
  static const standaloneKakaoRestApiKey = 'standaloneKakaoRestApiKey';
  static const standaloneToken = 'standaloneToken';
  static const standaloneTokenExpiresAt = 'standaloneTokenExpiresAt';

  /// FlutterSecureStorage (Keystore) 에 저장하는 비밀번호 키.
  static const standalonePassword = 'standalone_password';

  // Standalone 커뮤니티 계정(Supabase Auth, 카카오) — 모두 FlutterSecureStorage 키다.
  // SharedPreferences·sqflite 에 넣지 않는다(docs/architecture/community-account.md).
  /// 연결된 세션(access/refresh token, 만료, 표시 이름) JSON 한 덩어리.
  static const communitySession = 'community_session_v1';

  /// 브라우저로 보낸 로그인(PKCE verifier, 시작 시각, attempt id). 복귀 링크를 받으면 지운다.
  static const communityPendingLogin = 'community_pending_login_v1';

  /// 마지막으로 소비한 복귀 링크의 SHA-256(중복 전달 방지). 코드 원문은 저장하지 않는다.
  static const communityConsumedCallback = 'community_consumed_callback_v1';

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

  // Standalone 자동 로그인 결과 기록 (설정 계정 카드·대시보드 경고용)
  static const standaloneAuthLastAt = 'standalone_auth_last_at';
  static const standaloneAuthLastOutcome = 'standalone_auth_last_outcome';
  static const standaloneAuthLastMessage = 'standalone_auth_last_message';

  /// 하루 1회 백그라운드 로그인 점검이 "재로그인 필요"를 알릴 때만 쓴다(값: `<epoch ms>|<메시지>`).
  /// Kotlin `SafetyReportApplication` 이 이 키 변경을 듣고 알림을 띄운다 — 이름을 바꾸면 Kotlin 도 같이.
  static const standaloneAuthAlert = 'standalone_auth_alert';

  // 스토어 별점 요청 조건 (ReviewPromptService)
  static const reviewFirstOpenAt = 'review_first_open_at';
  static const reviewActiveDays = 'review_active_days';
  static const reviewLastActiveDay = 'review_last_active_day';
  static const reviewRequestCount = 'review_request_count';
  static const reviewLastRequestAt = 'review_last_request_at';
}
