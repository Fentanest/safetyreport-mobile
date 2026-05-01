# safetyreport-mobile — CLAUDE.md

프로젝트 추적 문서. 코드베이스 파악 / 디자인 결정 / 함정 기록.

- 변경 이력과 세션 로그는 `CHANGELOG.md`에도 병행 기록.

---

## 프로젝트 개요

Flutter + Kotlin 하이브리드 Android 앱. 안전신문고 신고 처리 현황을 자동 모니터링.

**두 가지 사용 모드** — UI / 로직 대부분이 모드별로 분기:

| 모드 | 데이터 소스 | 사용 시점 |
|------|------------|-----------|
| **Client** (server) | 직접 운영하는 크롤링 서버 (`/home/better0101/projects/safetyreport`) | 라즈베리파이 등 24/7 서버 운영자 |
| **Standalone** | 안전신문고 공식 API 직접 호출 + 로컬 SQLite | 서버 없이 모바일 단독 |

`AppMode` enum (`lib/models/app_mode.dart`) 으로 식별. `ReportProvider.appMode` 가 단일 source of truth.
숨은 **Play Console 심사용 데모 경로**도 존재:
Standalone 로그인 화면에서 `demo / demo / demo` 입력 시
실제 로그인 없이 예시 신고 3건이 들어있는 로컬 DB를 연다.

---

## 기술 스택

- **Flutter**: UI / 상태관리 (Provider) / 로컬 DB (sqflite) / SharedPreferences / 보안 저장 (flutter_secure_storage)
- **Kotlin Native**: 백그라운드 서비스 3개, MainActivity 브릿지 (MethodChannel)
- **MethodChannel**: `com.fentanest.mysafetyreport/permissions` (모든 native ↔ Flutter 통신)

---

## 디렉토리 구조

아래 루트 항목은 **2026-05-01 기준 `git ls-files`로 추적되는 경로만** 적는다.
로컬 산출물/작업물 (`resultstest/`, `android/.kotlin/` 등)은 구조 표기에서 제외.

```
.github/                         ── GitHub Actions 워크플로
android/                         ── 실제 배포 대상 Android 프로젝트 + Kotlin 서비스
ios/                             ── 추적 중인 iOS Runner 스캐폴드
lib/                             ── Flutter 앱 본체
linux/                           ── 추적 중인 Linux 스캐폴드
macos/                           ── 추적 중인 macOS 스캐폴드
test/                            ── Flutter 기본 위젯 테스트
web/                             ── 추적 중인 Web 스캐폴드
windows/                         ── 추적 중인 Windows 스캐폴드
README.md                        ── 사용자용 프로젝트 안내
CHANGELOG.md                     ── 세션/변경 기록
CLAUDE.md                        ── 개발자용 코드베이스 컨텍스트/함정 기록
LICENSE                          ── 라이선스
PRIVACY_POLICY.md                ── 개인정보처리방침
VERSION                          ── 앱 버전 단일 소스
pubspec.yaml / pubspec.lock      ── Flutter 패키지/버전 정의
analysis_options.yaml            ── Dart/Flutter 분석 규칙
flutter_launcher_icons.yaml      ── 앱 아이콘 생성 설정
build_android_common.sh          ── Android 빌드 공통 함수 (버전 동기화, signing 파일 스테이징)
build_android_release.sh         ── release APK/AAB 빌드
build_test_apk.sh                ── 빠른 로컬 테스트 빌드

.github/workflows/
  build-apk.yml                    ── Android APK/AAB CI 빌드 + GitHub Release
android/
  app/src/main/kotlin/com/fentanest/mysafetyreport/
    MainActivity.kt                ── FlutterActivity, MethodChannel handler, intent 라우팅,
                                     edge-to-edge, SharedPreferences 손상 마이그레이션
    NotificationService.kt         ── NotificationListenerService — SPP 신고번호 추출 →
                                     Client: /crawl/enqueue / Standalone: 큐 + 감지 알림
    WsService.kt                   ── Client 모드 Foreground Service — WebSocket 유지
    SyncForegroundService.kt       ── Standalone 동기화 진행 중 프로세스 보호 FGS
build_test_apk.sh                 ── 빠른 로컬 APK 테스트 스크립트
build_android_common.sh           ── 버전/signer 공통 헬퍼
build_android_release.sh          ── build-apk.yml 과 동일한 Docker 기반 로컬 release APK/AAB 빌드

lib/
  main.dart                          ── 앱 lifecycle, MaterialApp 모드별 테마, 변경 카드 시트
  models/
    app_mode.dart                    ── AppMode enum + fromString
    report.dart                      ── Report 데이터 모델 (서버 컬럼명 한국어 그대로)
    file_item.dart                   ── 파일 브라우저 항목
    notification_item.dart           ── 알림 히스토리 항목
    rating_batch_result.dart         ── 별점 배치 결과 / 개별 신고 결과 모델
    agency_stats.dart                ── 통계 데이터 모델
  providers/
    report_provider.dart             ── 신고/요약/필터 (`&`/`,` 검색, 상태/별점 다중선택), 자동 sync 트리거 (init/resume), 데모 모드 상태
    notification_history_provider.dart ── 알림 히스토리 + 알림 탭 서브탭 인덱스 상태
  services/
    api_service.dart                 ── Client 모드 HTTP/WS 클라이언트
    local_db_service.dart            ── Standalone SQLite (서버와 동일 한국어 컬럼, Play review demo seed 포함)
    rating_service.dart              ── Client/Standalone 공통 별점 배치 처리 서비스
    sync_engine.dart                 ── 동기화 엔진 + ChangeType 상수 + FGS ref counting
    standalone_auth_service.dart     ── 안전신문고 로그인 (RSA + OAuth2 + 자동 재로그인)
    standalone_api_service.dart      ── 안전신문고 직접 API 호출 (재시도/토큰만료 처리, 만족도 POST 포함)
    standalone_parser.dart           ── API JSON → Report 파싱 (CRLF 정규화 포함)
    standalone_auto_sync_service.dart ── 알림 큐 drain (개별 fetch + 1회 증분 fallback)
    permission_service.dart          ── 권한 체크, WsService 토글
  screens/
    setup_screen.dart                ── 초기 모드 선택 + 로그인/서버 설정 + demo/demo/demo 데모 진입
    dashboard_screen.dart            ── 처리 요약, 모드별 에러 메시지
    report_list_screen.dart          ── 4탭 (교통/주정차/기타/중복차량)
    statistics_screen.dart           ── 연도×카테고리×유형 통계, 위반법규 필터, softWrap
    notifications_screen.dart        ── 알림 히스토리 (크롤링/신고결과/별점 주기 3탭)
    file_browser_screen.dart         ── 로컬/서버 파일 브라우저 + share_plus fallback
    crawl_screen.dart                ── Standalone 동기화 / Client 크롤링 (모드 분기, 데모 모드 동기화 비활성화)
    settings_screen.dart             ── 설정 (모드별 카드 분기 + 버그 제보 버튼)
    permission_screen.dart           ── 권한 가이드
    search_screen.dart               ── 신고번호/차량번호 검색
    filtered_list_screen.dart        ── 필터 적용된 신고 리스트
    watchlist_screen.dart            ── 감시목록
  widgets/
    report_detail_sheet.dart         ── 신고 상세 시트 + 인라인/전체화면 동영상
    report_list_card.dart            ── 신고 카드 공용 UI (`report_list`/`search`/`filtered_list` 공유)
    selection_action_bar.dart        ── 다중 선택 액션 바 (복사/크롤링/감시/별점 주기)
    search_filter_sheet.dart         ── 검색 필터 시트 (처리상태/별점 다중선택, 초록 `v`, `&`/`,` 안내)
```

---

## 핵심 흐름

### 1. 앱 부팅

```
MainActivity.onCreate
  ├─ cleanupCorruptedPrefs()         ── 손상된 v1 큐 (LIST_PREFIX+JSON) 데이터 마이그레이션
  ├─ WindowCompat.setDecorFitsSystemWindows(false)  ── Android 15 edge-to-edge
  ├─ super.onCreate()                ── Flutter 엔진 시작
  └─ handleNavIntent(intent)         ── 알림 탭으로 실행됐으면 nav_tab/event_type 추출

Flutter main()
  └─ MultiProvider
       ├─ ReportProvider..init()
       │    ├─ SharedPreferences 읽기 (5초 timeout, 손상 시 빈 상태로 진행)
       │    ├─ SyncEngine.changesEmitted 구독 (nonce 갱신 → main.dart 카드 시트)
       │    └─ if standalone → fire-and-forget:
       │         ├─ refreshAll()             ── 즉시 DB 데이터 표시
       │         └─ _drainAndRefresh()       ── 큐 drain + 후속 refresh
       └─ NotificationHistoryProvider..load()
```

### 2. 알림 감지 → 동기화 (모드 분기)

```
Kotlin NotificationService.onNotificationPosted(sbn)
  └─ if package = kr.go.safepeople | com.kakao.talk → SPP 신고번호 추출
       └─ sendEnqueue(reportNumber)
            ├─ Client  → POST /api/v1/crawl/enqueue + "📡 개별 크롤링 지시 중" 알림
            │           (서버가 처리 후 WS crawl_changes → WsService.showCrawlChangesNotif)
            └─ Standalone → handleStandaloneDetection
                              ├─ appendPendingReport (CSV 형식 큐)
                              └─ "📬 신규 신고 감지" heads-up 알림 (탭 시 nav_tab=5)
```

알림 탭 → MainActivity.onNewIntent → handleNavIntent → 500ms 지연 후 MethodChannel `navigateToTab` →  
Flutter `_handleNativeCall` → 동기화 탭 이동 + (Standalone) `checkAutoSyncOnResume()` → `_drainAndRefresh()`.
단, `standaloneDemoMode=true` 이면 resume 시 refreshAll 만 수행하고 실제 drain/sync 는 생략.

### 3. Standalone drainIfPending (`StandaloneAutoSyncService`)

큐 영속성 보장을 위해 **항목당 처리 → 결정 후 제거** 방식:

```
while (queue not empty):
  spp = queue.first
  ok = _tryFetchSingle(spp)            ── DB 조회 + 상세 API + upsert
  if !ok and !didIncremental:
    didIncremental = true (drain 당 1회만)
    SyncEngine.start(fullSync: false)  ── 증분 sync fallback
    ok = _tryFetchSingle(spp)          ── 증분 후 재시도
  _removeFromQueue(spp)                ── 성공/포기 무관 제거 (3회 retry 안 함)

→ FGS acquireFgs("개별 동기화 진행 중") wrapped (ref counting)
→ 종료 시 emitChanges(_singleFetchChanges) + emitDone
```

**앱 죽임 → 다음 launch 자동 재시도 보장**: 처리 도중 앱이 죽으면 항목이 큐에 남아 있어 다음 init drain 이 처리.  
**과거 버그**: drain 진입 즉시 큐를 비웠던 옛 코드는 처리 도중 죽으면 항목 영구 손실 → 현재 per-item 제거로 해결.

### 4. 변경사항 emit (SyncEngine)

```
SyncEngine.emitChanges(List<Map>)
  ├─ pending_crawl_changes SharedPref 누적 (main.dart 가 카드 시트로 표시)
  ├─ 각 신고에 대해 MethodChannel showNotification (heads-up):
  │    ├─ ChangeType.newReport         → "🆕 신규 신고"
  │    ├─ ChangeType.statusChanged     → "🔄 처리 변경"
  │    └─ ChangeType.individualConfirm → "✅ 개별 동기화"
  └─ changesEmittedController.add(null) → ReportProvider nonce++ → main.dart 트리거
```

`ChangeType` (sync_engine.dart) 가 모든 식별자의 single source of truth.  
`reportToChangeMap(report, changeType)` 가 표준 Map 형식 생성.

### 5. 다중 선택 별점 주기

```
ReportListScreen
  └─ SelectionActionBar
       └─ 별점 주기 버튼
            ├─ 1~5점 다이얼로그
            ├─ RatingService.ineligibleReason() 기준 선별
            │    └─ 참여 완료 / 참여 불가 / 답변 대기 / 취하 / 처리중 / 진행 / 진행중 자동 스킵
            └─ ReportProvider.submitRatings()
                 ├─ Client(server)
                 │    ├─ POST /api/v1/rating/start (API 키 인증 별점 작업 요청)
                 │    ├─ /api/v1/files/download?path=logs/current_rating.log 폴링
                 │    └─ 성공/스킵/실패를 RatingBatchResult 로 정리
                 └─ Standalone
                      ├─ public 만족도 score API로 기참여 여부 확인
                      ├─ POST /api/v1/portal/statistics/satisfactionstatistics 직접 전송
                      └─ LocalDbService.updateReportRatingByNumber() 로
                         만족도조사여부/별점/별점사유 즉시 반영

완료 후:
  ├─ NotificationHistoryProvider.addRatingBatchResult()
  ├─ MethodChannel showNotification(nav_tab=3, nav_subtab=2)
  └─ NotificationsScreen 의 "별점 주기" 탭에서 상세 카드 시트 표시
```

`RatingService` 는 Standalone 뿐 아니라 Client 모드에서도 `SyncForegroundService`
를 재사용한다. 별점 작업/로그 추적이 끝날 때까지 앱 프로세스가 쉽게 정리되지 않도록
동기화와 같은 보호 경로를 탄다.

---

## Standalone 인증 아키텍처

`lib/services/standalone_auth_service.dart`

### 로그인 흐름 (`dart:io HttpClient` 로 쿠키 자동 관리)

```
1. GET /api/v1/common/rsa/getPublicKey → RSAModulus + RSAExponent (hex)
   ↳ 서버가 Set-Cookie: JSESSIONID=xxx, HttpClient 자동 저장
2. password (UTF-8 bytes) → PKCS1 v1.5 RSA 암호화 (pointycastle) → hex 문자열 (512자)
3. POST /oauth/token (form-urlencoded)
   ↳ JSESSIONID 자동 전달 (서버가 RSA 키를 세션에 바인딩)
   ↳ client_id=web, grant_type=password, loginType=1, username, password(hex)
   → { access_token: "eyJ...", expires_in: 3599 }
```

**왜 `dart:io HttpClient` 인가**: `package:http` 의 정적 메서드는 매 호출마다 별도 클라이언트 → 쿠키 공유 안 됨. `HttpClient` 인스턴스 하나로 쿠키 자동 관리되므로 JSESSIONID 수동 추출 불필요.

### Play review 데모 모드

- SetupScreen / SettingsScreen 재로그인 다이얼로그에서
  `username=demo`, `password=demo`, `phone=demo` 입력 시 진입
- `LocalDbService.seedPlayReviewDemo()` 가 아래 3건을 로컬 DB에 시드:
  - `SPP-2604-2344496` (traffic, 별점 5, 별점사유 있음)
  - `SPP-2604-0419411` (parking, 별점 5)
  - `SPP-2604-2344422` (other)
- `ReportProvider.isStandaloneDemo` true:
  - keep-alive 타이머 시작 안 함
  - pending queue drain, 실제 sync, 자동 재로그인 진입 안 함
  - crawl/sync 화면에서 동기화 버튼 비활성화 + 안내 카드 표시
- Play Console review credentials 에는 영어로 `demo / demo / demo` 기재

### 토큰 만료 + 자동 재로그인

- 만료 5분 전부터 무효 판단 → `tryAutoRelogin()` 호출
- `flutter_secure_storage` (Android Keystore 기반) 에 비밀번호 저장
- `StandaloneApiService._getWithRetry()`: 401 → 자동 재로그인 후 1회 재시도
- 실패 시 `TokenExpiredException` → UI 가 수동 재로그인 다이얼로그

### 자격증명 저장

| 항목 | 저장소 | 키 |
|------|--------|-----|
| access_token | SharedPreferences | `standaloneToken` |
| 만료 시각 (ms) | SharedPreferences | `standaloneTokenExpiresAt` |
| 비밀번호 | FlutterSecureStorage | `standalone_password` |
| 아이디 | SharedPreferences | `standaloneUsername` |

---

## SQLite 스키마 (Standalone)

`lib/services/local_db_service.dart` — `standalone_reports.db`, version 4.

서버 DB 와 컬럼명 동일 (한국어). mobile-only 추가: `category`, `entry_value`, `raw_content`, `synced_at`.

```sql
CREATE TABLE reports (
  ID TEXT PRIMARY KEY, 상태 TEXT, 신고번호 TEXT, 신고명 TEXT, 신고일 TEXT,
  만족도조사여부 TEXT, 감시목록 TEXT DEFAULT 'N', 처리상태 TEXT, 차량번호 TEXT,
  위반법규 TEXT, 범칙금_과태료 TEXT, 벌점 TEXT, 처리기관 TEXT, 담당자 TEXT,
  답변일 TEXT, 발생일자 TEXT, 발생시각 TEXT, 위반장소 TEXT,
  종결여부 TEXT DEFAULT 'N', 신고내용 TEXT, 처리내용 TEXT, 지도 TEXT,
  첨부사진 TEXT, 첨부파일 TEXT,
  category TEXT, entry_value TEXT DEFAULT '', raw_content TEXT DEFAULT '',
  synced_at INTEGER
);
CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT);
```

### 주요 쿼리 함수
- `computeSummary(excludeWithdraw, normalizePolice)` — 대시보드 요약
- `computeStats(year, law, ...)` — 통계 화면 데이터
- `getDuplicateVehicleReports(...)` — 차량별 그룹화 (서버 `get_duplicate_records` 동일 정렬: `max(신고번호) DESC, 차량번호 ASC, 신고번호 DESC`)
- `getReportByNumber(reportNumber)` — 단건 fetch 용

---

## 신고리스트 상세검색

- `SearchFilterSheet`는 `report_list_screen.dart`와 `search_screen.dart`가 공용 사용.
- 실제 필터 적용은 `ReportProvider._applyFilter()`에서 처리하므로 **Client(server) 모드와 Standalone 모드에 동일하게 적용**된다.
- 신고 카드 렌더링은 `widgets/report_list_card.dart`로 공용화되어 `report_list_screen.dart`, `search_screen.dart`, `filtered_list_screen.dart`가 같은 카드 골격을 공유한다.
- `신고명`, `신고번호`, `차량번호`, `위반법규`, `위반장소`, `처리기관`, `담당자`, `과태료/범칙금`, `별점사유`, `신고내용`, `처리내용`은 `&` = AND, `,` = OR 문법을 사용한다.
- `처리상태`는 로드된 신고 목록에서 distinct 값을 추출해 다중선택 UI로 노출한다.
- `별점`은 `없음`, `1~5점` 다중선택 UI로 노출한다.
- 두 다중선택 UI 모두 선택된 항목 우측에 초록 `v`를 표시한다.
- `만족도 조사 여부`는 `참여 완료`, `참여 가능` 단일선택 드롭다운으로 노출한다. 서버 `data_table.html` 상세 검색에도 동일하게 추가되어 있다.

---

## SharedPreferences 키 (Kotlin ↔ Flutter 공유)

저장소: `FlutterSharedPreferences` (Android XML)

| 키 | 타입 | 용도 |
|----|------|------|
| `flutter.appMode` | String | "server" / "standalone" |
| `flutter.baseUrl` / `flutter.apiKey` | String | Client 모드 서버 |
| `flutter.standaloneUsername` | String | Standalone ID |
| `flutter.standalonePhoneNumber` | String | Standalone 휴대폰번호 (또는 demo) |
| `flutter.standaloneDemoMode` | bool | Play review 데모 모드 여부 |
| `flutter.standaloneToken` / `flutter.standaloneTokenExpiresAt` | String / int | OAuth 토큰 |
| `flutter.standalone_pending_reports` | **String (CSV)** | Standalone 큐 (아래 함정 주의) |
| `flutter.standalone_last_detected_at` | long | 디버그용 |
| `flutter.foreground_event` | String | WsService → 포그라운드 복귀 SnackBar |
| `flutter.pending_crawl_changes` | String (JSON) | 카드 시트 표시 대기 |
| `flutter.notifications_history` | String (JSON) | 알림 히스토리 (최대 200개) |
| `flutter.auto_enqueue_count` / `flutter.auto_enqueue_last_at` | int / long | Client 자동 enqueue 푸시 억제 |

### ⚠️ Flutter SharedPreferences 큐 형식 함정

**문제**: 초기 Kotlin 코드는 큐를 `LIST_PREFIX (VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu) + JSON 배열` 로 저장했는데, Flutter 의 `LegacySharedPreferencesPlugin` 은 `LIST_PREFIX` 가 붙은 값을 Java `ObjectInputStream` 으로 디코딩 시도 → JSON 데이터에서 `StreamCorruptedException` → `getAll()` 전체 실패 → **모든 prefs 읽기 실패 → 로그인 풀림**.

**해결**:
- Kotlin `appendPendingReport`: 큐를 **CSV 문자열** (LIST_PREFIX 없음) 로 저장 → Flutter 가 일반 String 으로 읽음, deserialize 시도 안 함.
- `MainActivity.cleanupCorruptedPrefs()`: super.onCreate 전에 v1 (LIST_PREFIX+JSON) 데이터를 CSV 로 마이그레이션 (Kotlin 에서는 JSON 파싱 가능).
- Flutter `StandaloneAutoSyncService.readPendingQueue()` / `_writeQueue()`: CSV split/join.

---

## Foreground Service 정책

### `WsService` (Client 모드)
- WebSocket `ws://<baseUrl>/ws/events?api_key=<key>` 유지
- 지수 백오프 재연결 (3→6→12→24→60초)
- START_STICKY (OS 가 죽여도 자동 재시작)
- crawl_started/finished/changes 이벤트 수신 → push 알림

### `SyncForegroundService` (Standalone 모드)
- `SyncEngine.start()` 또는 `drainIfPending()` 실행 동안 가동
- `SyncEngine.acquireFgs / releaseFgs` 가 ref counting (drain → SyncEngine.start 중첩 안전)
- "🔄 동기화 진행 중" 알림 (LOW priority)
- START_NOT_STICKY (작업 끝나면 정지)
- swipe-away 방어 + OS kill 후순위 격상 (강제종료는 못 막음)

### 알림 채널

| 채널 ID | 중요도 | 용도 |
|---------|--------|------|
| `ws_service` | LOW | WsService 지속 알림 |
| `ws_push_v2` | HIGH | crawl_started/finished/changes heads-up |
| `enqueue_progress` | LOW | "📡 개별 크롤링 지시 중" 임시 |
| `standalone_detected_v2` | HIGH | "📬 신규 신고 감지" heads-up (탭 시 sync 트리거) |
| `sync_fgs` | LOW | "🔄 동기화 진행 중" Standalone FGS |
| `app_push_v2` | HIGH | Standalone 변경 알림 (Flutter → MethodChannel showNotification) |

---

## 자동 enqueue 알림 억제 로직 (Client 전용)

카카오톡 등 외부 알림 → `NotificationService.sendEnqueue()` 자동 트리거 시,
WsService 가 `crawl_started / crawl_finished` push 알림을 쌓는 게 지저분 → 억제.

1. `sendEnqueue` 호출 → `auto_enqueue_count++` + 타임스탬프 기록 + "📡 개별 크롤링 지시 중" ongoing 알림 표시
2. POST 완료/실패 시 finally 에서 ongoing 알림 소거
3. `WsService.showCrawlStartedNotif` / `showCrawlFinishedNotif`: `isAutoEnqueueActive()` true 면 return
4. `crawl_changes` (실제 결과) 는 억제 안 함 — 단, auto_enqueue 활성 세션이면 "🆕 개별 신규" / "🔄 개별 처리 변경" prefix 부착 (가독성)
5. `auto_enqueue_count > 0` 이어도 `auto_enqueue_last_at` 10분 초과 시 만료 (서버 미응답 대비)

---

## ChangeType 상수 (sync_engine.dart)

모든 변경 종류 식별자의 single source of truth — magic string 금지.

```dart
class ChangeType {
  static const newReport = '신규';            // DB 에 없던 ID
  static const statusChanged = '처리변경';     // 처리상태 변동
  static const individualConfirm = '개별확인'; // 알림 탭 단건 fetch + 변동 없음
}
```

사용처: `sync_engine.dart`, `standalone_auto_sync_service.dart`, `main.dart` (카드 시트), `notification_history_provider.dart` (히스토리 아이콘).

---

## 모드별 테마 (main.dart)

`MaterialApp` 을 `Consumer<ReportProvider>` 로 감싸 `appMode` 변화 시 시드 컬러 자동 전환:

| 모드 | Primary | Indicator |
|------|---------|-----------|
| Client | `#1A73E8` (구글 블루) | `#E3EEFF` |
| Standalone | `#1B873B` (머티리얼 그린) | `#DFF1E3` |

`colorScheme.copyWith(surface: white, ...)` 로 surface 계열은 흰색 강제 (Material 3 `fromSeed` 가 그린에서 파생하는 노란기 surface 톤 차단).

---

## 모드 전환 + DB 마이그레이션 (`settings_screen.dart`)

`_confirmModeReset()` 가 두 방향으로 분기:

### Standalone → Client
1. 현재 standalone DB 를 자동으로 `Documents/mysafetyreport/standalone_backup_<ts>.db` 로 복사 (사용자 추가 조작 없이 한 번의 확인만).
2. 백업 실패해도 모드 전환 자체는 진행 (사용자가 명시 요청).
3. `resetConfig()` → SetupScreen.

### Client → Standalone — 3-way 다이얼로그 (`_ChoiceTile`)
| 선택 | 동작 | pending_db_import 키 |
|------|------|----------------------|
| 서버 DB 받아 변환 | 현재 Client 자격증명으로 `/api/v1/settings/db` 다운로드 → Documents/mysafetyreport 에 저장 (★ reset 전에 — 자격증명 살아있을 때) | `convert:<path>` |
| 최신 백업 파일 사용 | Documents/Download/mysafetyreport 의 .db 중 가장 최근 modified 자동 발견 | `copy:<path>` |
| 처음부터 시작 | 빈 DB | (없음) |

선택 결과는 SharedPreferences 의 `pending_db_import` 키에 저장. SetupScreen 의 `_loginStandalone` 가 standalone 로그인 성공 직후 `_applyPendingDbImport()` 호출:
- `convert:<path>` → `LocalDbService.importFromServerDb(path)`
- `copy:<path>` → `LocalDbService.replaceFromBackup(path)`
- 적용 후 키 제거. 실패해도 로그인은 성공으로 처리 (SnackBar 만 안내).

### `LocalDbService.importFromServerDb(path)`
서버 DB 의 3개 merge 테이블 (`mysafetymerge_traffic` / `parking` / `other`) → 모바일 단일 `reports` 테이블 + `category` 컬럼 부여. `mysafety_watchlist` → `sync_meta('watchlist')` CSV 변환. 트랜잭션으로 묶어 일괄 INSERT. 임포트 건수 반환.

### `LocalDbService.replaceFromBackup(path)`
모바일 형식 백업 .db 를 그대로 덮어씀 (closeDb → File.copy → 다음 db getter 가 재오픈). 서버 DB 는 스키마 다르므로 이 메서드 사용 불가.

---

## errno=104 (connection reset) silent retry 매트릭스

안전신문고 / Client 서버는 가끔 connection reset 으로 응답을 끊음. 모든 주요 네트워크 호출에서 silent 3회 retry 로 사용자에게 노출되지 않게 흡수.

| 호출 | 위치 | retry 정책 |
|------|------|-----------|
| Standalone 일반 GET (목록/상세) | `StandaloneApiService._getWithRetry` | 3회 / 1초 sleep / 20s timeout / 401 시 자동 재로그인 + 1회 추가 |
| Standalone 로그인 Step 1 (RSA 키) | `StandaloneAuthService.login` | 3회 / `attempt`초 backoff / 15s timeout |
| Standalone 로그인 Step 3 (OAuth 토큰 POST) | `StandaloneAuthService.login` | 3회 / `attempt`초 backoff / 15s timeout |
| Client DB 다운로드 (서버→standalone 변환) | `ApiService.downloadDb` | 3회 / 1초 sleep / **2분** timeout (DB 가 MB 단위) |
| Client 일반 API (crawl/enqueue 등) | `ApiService` 메서드들 | retry 없음 (사용자 명시 요청 범위 외) |

catch 대상: `SocketException` (errno 104), `http.ClientException`, `TimeoutException`. 4xx/5xx HTTP 응답은 재시도 무의미 → 즉시 throw.

---

## refreshAll 직렬화 (Standalone)

```dart
if (_appMode == AppMode.standalone) {
  await fetchSummary();       // 순차 await
  await fetchTrafficReports();
  // ... (총 6개)
}
```

**왜 Future.wait 안 쓰나**: sqflite 는 단일 connection 으로 모든 op 를 직렬 처리. `Future.wait` 로 6개 동시 호출하면 큐만 가득 차서 `fetchSummary()` 의 5초 timeout 발동 ("DB 데드락 의심" 메시지). 실제 deadlock 아님 — 큐 포화. 순차 실행이 정답.

---

## Python ↔ Dart regex 함정 (CRLF)

| 언어 | `.` 가 매치 안 하는 줄바꿈 |
|------|-----------------------------|
| Python `re` | `\n` 만 |
| Dart `RegExp` | `\n`, `\r`, ` `, ` ` (ECMA-262) |

Traffic 신고 (`C_A_CONTENTS`) 가 CRLF 사용 → 서버 Python 코드를 그대로 포팅하면 Dart 에서 차량번호 regex 실패.

**해결**: `standalone_parser.dart` `parseJsonToReport()` 진입부에서:
```dart
final content = _normalizeNumbers(rawContent)
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n');
```

---

## 버전 관리

**단일 소스: `VERSION` 파일** (예: `1.0.6+8`)

- `build-apk.yml` CI: `sed` 로 `pubspec.yaml` 의 `version:` 줄 자동 교체
- Flutter 빌드: `--build-name` / `--build-number` 플래그
- 런타임 표시: `package_info_plus` (settings_screen.dart)

### 로컬 테스트 빌드 (`build_test_apk.sh`)
CI 와 동일한 Docker 이미지 (`ghcr.io/cirruslabs/flutter:stable`).

```bash
./build_test_apk.sh           # debug
./build_test_apk.sh --release # release (~/mysafetyreport-android/ 키스토어 필요)
```

### 로컬 정식 Android 릴리즈 빌드 (`build_android_release.sh`)
`build-apk.yml` 과 동일한 순서:
- `VERSION` 읽기
- `pubspec.yaml version:` 동기화
- Docker Flutter 이미지에서 `flutter build apk --release`
- 이어서 `flutter build appbundle --release`
- 산출물 복사:
  - `build/app/outputs/flutter-apk/mysafetyreport.apk`
  - `build/app/outputs/bundle/release/mysafetyreport.aab`

```bash
./build_android_release.sh
```

기본 키 경로:
- `~/mysafetyreport-android/key.properties`
- `~/mysafetyreport-android/upload-keystore.jks`

---

## 주요 작업 이력 (이 세션)

시간순 누적 변경 — 컨텍스트 파악용.

20. **2026-04-27 버그 수정 묶음**
    - Client 파싱 강건화: `Report.fromJson`, `AgencyStats.fromJson` 에 문자열 숫자/빈 문자열 허용 파서 추가. 서버가 `''`를 보내는 경우 `type 'String' is not a subtype of type 'num?'` 방지.
    - Standalone DB 백업 일관성: `LocalDbService.exportBackup()` 추가. sqflite WAL 환경에서 main `.db`만 복사하면 최신 별점/사유 등이 누락될 수 있어, 백업/모드 전환 자동백업 시 DB를 닫아 flush 후 복사하도록 변경.
    - Client → Standalone 전환 2번째 선택지 변경: "최신 백업 파일 사용" 자동 탐색/비활성화를 제거하고, 사용자가 `.db` 파일을 직접 고르는 `FilePicker` 방식으로 교체.
    - 파일 브라우저 정렬: standalone 로컬 파일 / client 서버 파일 모두 **파일명 내림차순** 정렬.
    - Standalone 파일 열기 권한 우회: 외부 저장소 원본을 바로 `OpenFilex.open()` 하지 않고 앱 temp 디렉토리로 복사 후 열도록 변경. 일부 기기의 `MANAGE_EXTERNAL_STORAGE` 요구/permission denied 완화 목적.
    - Client → Standalone 전환 시 `WsService` 정지 보강: `ReportProvider.setStandaloneConfig/resetConfig` 에서 즉시 `stopWsService()` 호출, `MainActivity.autoStartWsServiceIfConfigured()` 도 현재 모드가 `server`가 아니거나 자격증명이 비면 살아 있는 `WsService`를 강제 정지하도록 변경. 전환 후 "서버 연결 대기 중..." 지속 알림 방지.
21. **Play Console 심사용 데모 모드**
    - Standalone 로그인에서 `demo / demo / demo` 입력 시 실제 안전신문고 인증 없이 로컬 예시 DB 3건 시드 후 진입.
    - `ReportProvider.isStandaloneDemo` 상태 추가: keep-alive, pending queue drain, 실제 sync, 자동 재로그인 진입 차단.
    - `crawl_screen.dart` 에 데모 안내 카드 추가, 동기화/재동기화 버튼 비활성화.
    - 재로그인 다이얼로그에서도 같은 데모 자격증명으로 재진입 가능.
22. **Android 빌드/릴리즈 정리**
    - `.github/workflows/build-apk.yml` 유지: VERSION→pubspec 동기화 후 Docker Flutter 이미지에서 APK/AAB 빌드.
    - 로컬용 `build_android_release.sh` 추가: CI 와 동일한 경로/키스토어 마운트, release APK/AAB 동시 빌드.
    - 기존 `build_test_apk.sh` 는 debug/간이 release 용으로 유지.
23. **신고 카드 중복 UI 공용화 + CLAUDE 구조 정리**
    - `report_list_screen.dart`, `search_screen.dart`, `filtered_list_screen.dart`에 반복되던 신고 카드 UI를 `widgets/report_list_card.dart`로 통합.
    - 상태칩/선택 강조/차량번호 배지/메타 행 렌더링을 공용화하고, 각 화면은 필요한 메타 항목만 전달하도록 단순화.
    - `CLAUDE.md`의 루트 구조는 git 추적 경로 기준으로만 표기하도록 명시하고, `build_android_common.sh`와 신규 공용 위젯을 반영.
24. **`CLAUDE.md` git 반영 + 상세검색 키보드 선택 처리**
    - `.gitignore`에서 `CLAUDE.md`를 제거해 문서 자체를 저장소에 반영.
    - `CLAUDE.md` 상단 설명과 루트 구조 표기를 git 추적 문서 기준으로 다시 정리.
    - `search_filter_sheet.dart`의 키보드 Enter 처리에서 선택 토글이 항상 먼저 반영되도록 조정해 다중선택 접근성을 보강.
25. **별점 로그 파싱 버그 수정 + 만족도 조사 여부 검색 필터 추가**
    - Client 모드 별점 주기: 서버 로그 파싱 regex가 타임스탬프 브래킷 `[2026-...]`을 신고번호로 오인식하던 버그 수정. `\[(.+?)\]` → `\[(SPP-.+?)\]` 로 변경.
    - 서버 `data_table.html` 상세 검색과 모바일 `SearchFilterSheet`에 `만족도 조사 여부` 단일선택 드롭다운 추가 (참여 완료 / 참여 가능).
    - `ReportFilter`에 `pollStatus` 필드 추가, `_applyFilter()`에 필터 로직 반영.

1. **Standalone 모드 신규 구현**: 안전신문고 직접 로그인 (RSA + OAuth), 자동 재로그인, sqflite 로컬 DB, 증분 sync, 카드 시트
2. **알림 큐 인프라**: Kotlin NotificationService 가 SPP 추출 → SharedPreferences 큐 → Flutter drain
3. **SharedPreferences 손상 버그 fix**: LIST_PREFIX+JSON 형식이 LegacyPlugin 의 Java deserialize 와 충돌 → CSV 형식으로 변경 + MainActivity 마이그레이션
4. **DB 큐 폭주 fix**: Standalone refreshAll 의 Future.wait → 순차 await (sqflite 단일 connection)
5. **CrawlScreen sync 가시성**: SyncEngine.events 항상 구독, log/progress 도착 시 `_isRunning` 자동 true
6. **단건/개별 용어 통일**: '단건' → '개별' (`ChangeType.individualConfirm` 등)
7. **중복차량 정렬 서버 동일화**: max(신고번호) DESC → 차량번호 ASC → 신고번호 DESC
8. **Standalone 그린 테마**: MaterialApp Consumer 로 appMode 별 시드 컬러 동적 전환
9. **Android 15 edge-to-edge**: WindowCompat.setDecorFitsSystemWindows (enableEdgeToEdge 는 receiver mismatch 로 사용 불가)
10. **xlsx 파일 fallback**: OpenFilex 실패 → share_plus 의 Share.shareXFiles → 시스템 공유 sheet
11. **개별 sync done 신호**: SyncEngine.emitDone → CrawlScreen 의 `_isRunning` 영구 true 버그 fix
12. **Foreground Service**: SyncForegroundService — drainIfPending / SyncEngine.start 동안 프로세스 보호
13. **큐 영속성**: drainIfPending 의 per-item 제거 (옛 즉시 비움 → 앱 죽으면 항목 영구 손실 fix)
14. **3회 retry 제거**: 사용자 요청대로 개별+증분 fallback 1회씩으로 단순화
15. **리팩토링**: dead `standalone_sync_pending` 플래그 제거, ChangeType 상수화, `_drainAndRefresh` 헬퍼 추출
16. **버그 제보 버튼**: 설정 → 앱 정보 카드에 GitHub issues 링크
17. **모드 전환 + DB 마이그레이션**: standalone→client 자동 백업, client→standalone 3-way 선택 (서버 DB 변환 / 최신 백업 사용 / 처음부터). `pending_db_import` SharedPref 로 SetupScreen 까지 의도 전달. `LocalDbService.importFromServerDb` (서버 3 merge 테이블 → 모바일 단일 reports + category, watchlist CSV 변환), `replaceFromBackup` 추가
18. **errno=104 retry 매트릭스 보강**: standalone 로그인 Step 3 (토큰 POST) 에 3회 retry 추가, Client `downloadDb` 에 3회 retry + 2분 timeout. standalone 일반 GET / 로그인 Step 1 은 기존부터 retry 있어 그대로 유지
19. **main 브랜치 병합**: 1.0.7+11 (main minor bump + alone build 누적), READ_MEDIA_* tools:remove 권한 정리, 개인정보처리방침 통합

---

## 외부 참조

- **Client 모드 서버 프로젝트 (로컬)**: `/home/better0101/projects/safetyreport`
- **사용자 가이드 (모바일)**: <https://hb.worklazy.net/mysafetyreport/>
- **라즈베리파이 서버 설정**: <https://hb.worklazy.net/raspberry-pi-mysafetyreport-setup/>
- **서버 GitHub**: <https://github.com/Fentanest/safetyreport>
- **모바일 GitHub**: <https://github.com/Fentanest/safetyreport-mobile>
- **버그 제보**: <https://github.com/Fentanest/safetyreport-mobile/issues>

---

## 서버 API 주요 엔드포인트 (Client 모드)

- `POST /api/v1/crawl/enqueue` — 단건 큐 등록 `{"report_number": "SPP-..."}`
- `POST /api/v1/crawl/start` — 크롤링 시작 (mode/type/queue_list)
- `GET  /api/v1/crawl/config` — 크롤링 설정
- `GET  /api/v1/crawl/status` — 크롤링 상태 폴링
- `GET  /version` / `GET /version/latest` — 버전 / 업데이트 체크
- `ws://<baseUrl>/ws/events` — 이벤트 스트림 (WsService 연결)
- `ws://<baseUrl>/crawl/ws/logs` — 실시간 로그 (CrawlScreen)

## 안전신문고 API 엔드포인트 (Standalone 모드)

`StandaloneApiService` (`lib/services/standalone_api_service.dart`)

- `GET https://www.safetyreport.go.kr/api/v1/common/rsa/getPublicKey` — RSA 공개키
- `POST https://www.safetyreport.go.kr/oauth/token` — OAuth2 토큰 발급
- `GET /api/v1/portal/mypage/mysafereport?startRowNum=&endRowNum=...` — 신고 목록
- `GET /api/v1/portal/mypage/mysafereport/{C_NO}` — 신고 상세

타임아웃: 20초 / 시도, 최대 3회 재시도. 401 → 자동 재로그인 후 1회 재시도.
