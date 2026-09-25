# 개요·화면 구조·앱 흐름

> 이관 원본: 루트 `CLAUDE.md` (sha256 `32e8f475…9481`, 마지막 변경 커밋 `161b68dc`), 2026-09-24 분할.
> 본문은 원문을 **그대로** 옮겼다. 코드와 달라진 부분은 아래 "코드 대조 정정"에만 적고 원문은 고치지 않았다.
> 원본 전체 사본: [legacy-claude-reference.md](legacy-claude-reference.md) · 제목별 대응표: [README.md](README.md)

## 코드 대조 정정 (2026-09-24, base `c64be69a`)

| 원문 기술 | 현재 코드 | 근거 |
|---|---|---|
| 디렉토리 구조(2026-05-06 기준) | 누락 파일 존재: `lib/server_palette.dart`, `models/app_theme_mode.dart`, `screens/rating_management_panel.dart`, `services/app_prefs_keys.dart`, `app_storage_paths.dart`, `pending_changes_store.dart`, `pending_db_import_action.dart`, `server_connection_service.dart`, `standalone_pending_queue_store.dart`, `services/repositories/{duplicate,sunwi,watchlist}_repository.dart` | `git ls-files lib` |
| `test/ ── Flutter 기본 위젯 테스트` | 8개 파일: `report_navigation_regression_test.dart`, `widget_test.dart`, `services/` 6개(로컬 DB·pending 큐/변경·DB import·별점·서버 연결) | `ls test test/services` |
| 신고관리 = 감시 목록 / 중복 신고 / 데이터 수정 (3개), "세 번째 하위 탭은 데이터 수정" | **4개**: 별점 / 감시 목록 / 중복 신고 / 데이터 수정. 데이터 수정은 네 번째 | `lib/screens/report_management_screen.dart:25,49-52` |
| 부팅 흐름의 `enableEdgeToEdge()` | 제거됨. `WindowCompat.setDecorFitsSystemWindows(window, false)` 사용 (Android 15 메모와 일치) | `MainActivity.kt:46` |
| 모드별 테마: surface 흰색 강제 | 라이트는 흰 surface 유지, 다크 테마 별도 존재(`_darkSurface` 등), 사용자 테마 선택 `AppThemeMode` system/light/dark | `lib/main.dart:47-54,108`, `lib/models/app_theme_mode.dart` |

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
Standalone 로그인 화면에서 `demo / demo`(휴대폰번호 공란) 또는 `demo / demo / demo` 입력 시
실제 로그인 없이 예시 신고 3건이 들어있는 로컬 DB를 연다.

## 기술 스택

- **Flutter**: UI / 상태관리 (Provider) / 로컬 DB (sqflite) / SharedPreferences / 보안 저장 (flutter_secure_storage)
- **Kotlin Native**: 백그라운드 서비스 3개, MainActivity 브릿지 (MethodChannel)
- **MethodChannel**: `com.fentanest.mysafetyreport/permissions` (모든 native ↔ Flutter 통신)

## 디렉토리 구조

아래 루트 항목은 **2026-05-06 기준 `git ls-files`로 추적되는 경로만** 적는다.
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
    MainActivity.kt                ── FlutterFragmentActivity, MethodChannel handler, intent 라우팅,
                                     AndroidX enableEdgeToEdge, SharedPreferences 손상 마이그레이션
    ServerContract.kt              ── Client 모드 서버 API/WS 경로, 헤더, 이벤트 타입 단일 소스
    NotificationService.kt         ── NotificationListenerService — SPP 신고번호 추출 →
                                     Client: ServerContract 기준 /crawl/enqueue / Standalone: 큐 + 감지 알림
    WsService.kt                   ── Client 모드 Foreground Service — ServerContract 기준 WebSocket 유지
    SyncForegroundService.kt       ── Standalone 동기화 진행 중 프로세스 보호 FGS
build_test_apk.sh                 ── 빠른 로컬 APK 테스트 스크립트
build_android_common.sh           ── 버전/signer 공통 헬퍼
build_android_release.sh          ── build-apk.yml 과 동일한 Docker 기반 로컬 release APK/AAB 빌드

lib/
  main.dart                          ── 앱 lifecycle, MaterialApp 모드별 테마, 변경 카드 시트,
                                       하단 탭 라우팅(대시보드/신고내역/신고관리/통계/알림/파일/동기화)
  models/
    app_mode.dart                    ── AppMode enum + fromString
    duplicate_group.dart             ── 중복 신고 그룹/멤버 모델 + 상태/대표건 모드 라벨
    editor_schema.dart               ── 모바일/서버 공용 데이터 수정 필드 순서/예시 문구 모델
    report.dart                      ── Report 데이터 모델 (서버 컬럼명 한국어 그대로)
    report_map.dart                  ── 신고 지도 payload / missing address / 백필 진행률 모델
    file_item.dart                   ── 파일 브라우저 항목
    notification_item.dart           ── 알림 히스토리 항목
    rating_batch_result.dart         ── 별점 배치 결과 / 개별 신고 결과 모델
    agency_stats.dart                ── 통계 데이터 모델
    sunwi.dart                       ── 신고현황 payload / 대분류 / 소분류 / 순위 항목 모델
  providers/
    report_provider.dart             ── 신고/요약/필터 (`&`/`,` 검색, 상태/별점 다중선택, 위반법규 단일선택 + `없음` sentinel), recentAnswerReports 재계산, 자동 sync/지오코딩 재시도 트리거 (init/resume/refresh), 데모 모드 상태
    notification_history_provider.dart ── 알림 히스토리 + 알림 탭 서브탭 인덱스 상태
  services/
    api_service.dart                 ── Client 모드 HTTP 클라이언트 (ServerContract 기반 URI/헤더 생성)
    duplicate_projection_service.dart ── Standalone 중복군 계산/대표건 projection/중복 상태 갱신
    geocode_utils.dart               ── 주소 정규화 + geocode payload 헬퍼 (로컬 저장/백필 공용)
    local_db_service.dart            ── Standalone SQLite (서버와 동일 한국어 컬럼, Play review demo seed 포함)
    local_geocode_service.dart       ── Standalone 지도 좌표 백필 + queued 상태/자동 재개
    network_retry_config.dart        ── 모바일 공용 재시도 횟수/기본 대기 상수 (`5회`)
    rating_service.dart              ── Client/Standalone 공통 별점 배치 처리 서비스
    server_contract.dart             ── Client 모드 서버 API/WS 경로, 헤더, URI 빌더 단일 소스
    sync_engine.dart                 ── 동기화 엔진 + ChangeType 상수 + FGS ref counting
    standalone_auth_service.dart     ── 안전신문고 로그인 (RSA + OAuth2 + 자동 재로그인)
    standalone_api_service.dart      ── 안전신문고 직접 API 호출 (재시도/토큰만료 처리, 만족도 POST 포함)
    standalone_parser.dart           ── API JSON → Report 파싱 (CRLF 정규화 포함)
    standalone_auto_sync_service.dart ── 알림 큐 drain (개별 fetch + 1회 증분 fallback)
    permission_service.dart          ── 권한 체크, WsService 토글
    sunwi_service.dart               ── Standalone 전국 신고현황 수집 + sunwi CSV 생성
    repositories/editor_repository.dart ── Client/Standalone 데이터 수정 저장소 추상화
  screens/
    setup_screen.dart                ── 초기 모드 선택 + 로그인/서버 설정 + demo/demo(휴대폰 공란 허용) 데모 진입
    dashboard_screen.dart            ── 처리 요약, recentAnswerReports 기반 최근 답변 5건+더보기,
                                       감시 목록 요약, 대시보드 하단 임베드 신고현황
    report_management_screen.dart    ── 하단 `신고관리` 탭 셸 (감시 목록 / 중복 신고 / 데이터 수정 서브탭)
    data_editor_screen.dart          ── 모바일 데이터 수정 패널 + 수정 바텀시트
    duplicate_management_screen.dart ── Client/Standalone 겸용 중복 신고 관리 패널
    report_list_screen.dart          ── 4탭 (교통/주정차/기타/중복차량) + 통계/검색에서 넘어온 활성 필터 Chip 표시 + 현재 탭 건수/검색 결과 건수 배지
    report_map_screen.dart           ── Client/Standalone 공통 신고 지도 + 백필 진행률 카드 + 미변환 주소 시트
    statistics_screen.dart           ── 연도×카테고리×유형 통계, 위반법규 필터, 행 탭 시 신고리스트 상세검색 기반 drilldown
    sunwi_screen.dart                ── 신고현황 화면 + 재사용 가능한 `SunwiSection`
                                       (Client 서버 payload / Standalone 직접 수집, 3시간 TTL,
                                        대시보드 임베드 / 5초 자동 페이지 전환)
    notifications_screen.dart        ── 알림 히스토리 (크롤링/신고결과/별점 주기 3탭,
                                       duplicate 변경 상세 시트 포함)
    file_browser_screen.dart         ── 로컬/서버 파일 브라우저 + standalone 하위 폴더 탐색 + share_plus fallback
    crawl_screen.dart                ── Standalone 동기화 / Client 크롤링 (모드 분기, 데모 모드 동기화 비활성화)
    settings_screen.dart             ── 설정 (모드별 카드 분기 + 버그 제보 버튼 + 공식 출처/비공식 고지)
    permission_screen.dart           ── 권한 가이드
    search_screen.dart               ── 신고번호/차량번호 검색
    filtered_list_screen.dart        ── 필터 적용된 신고 리스트
    recent_answers_screen.dart       ── 최근 3일 답변 전체 화면 (summary fallback 대신 실제 카테고리 목록 재계산 결과 사용)
    watchlist_screen.dart            ── 감시목록 + 서버/다중선택 추가 안내
  widgets/
    report_detail_sheet.dart         ── 신고 상세 시트 + 카테고리 보존 필드 링크 + 인라인/전체화면 동영상 + 공식 출처 링크/비공식 고지
    report_list_card.dart            ── 신고 카드 공용 UI (`report_list`/`search`/`filtered_list` 공유)
    selection_action_bar.dart        ── 다중 선택 액션 바 (복사/크롤링/감시/별점 주기, batch 결과 비차단 알림 처리)
    search_filter_sheet.dart         ── 검색 필터 시트 (처리상태/별점 다중선택, 위반법규 데이터 기반 단일선택 + `없음`, 초록 `v`, `&`/`,` 안내)
    duplicate_group_detail_sheet.dart ── 중복군/child 상세 바텀시트
```

## 재사용 패널 구조

- `WatchlistScreen` 은 실제 본문을 `WatchlistPanel` 로 분리했다.
- `SunwiScreen` 은 실제 본문을 `SunwiSection` 으로 분리했다.
- `SunwiSection(embedded: true)` 는 대시보드 안에 들어가므로 자체 스크롤 컨테이너를 만들지 않고
  일반 children 묶음만 렌더해야 한다. 독립 화면일 때만 `RefreshIndicator + ListView` 를 사용한다.
- `ReportManagementScreen` 은 하단 네비게이션 탭 셸이고,
  실제 중복 관리는 `DuplicateManagementScreen`, 감시 목록은 `WatchlistPanel`,
  데이터 수정은 `DataEditorPanel` 을 재사용한다.
- 목적:
  - 추후 대시보드/관리 탭 안으로 같은 UI 를 재배치할 때 화면 전체를 복제하지 않기 위함

## 하단 탭 구조

- 현재 하단 탭 순서:
  - `대시보드`
  - `신고내역`
  - `신고관리`
  - `통계`
  - `알림`
  - `파일`
  - `동기화`
- `신고현황`은 더 이상 독립 하단 탭이 아니고, 대시보드 최하단 `SunwiSection(embedded: true)` 로 노출된다.
- 감시 목록 `관리`/`더 보기` 동선은 별도 전체화면 `WatchlistScreen` 이 아니라
  `신고관리 > 감시 목록` 탭으로 연결한다.
- `신고관리`의 세 번째 하위 탭은 `데이터 수정`이며,
  Client 모드는 서버 editor API를, Standalone은 로컬 SQLite 수정 경로를 사용한다.

## 핵심 흐름

### 1. 앱 부팅

```
MainActivity.onCreate
  ├─ cleanupCorruptedPrefs()         ── 손상된 v1 큐 (LIST_PREFIX+JSON) 데이터 마이그레이션
  ├─ super.onCreate()                ── Flutter 엔진 시작
  ├─ enableEdgeToEdge()              ── AndroidX 공식 edge-to-edge bootstrap
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

### 5. 다중 선택 별점 주기

```
ReportListScreen
  └─ SelectionActionBar
       └─ 별점 주기 버튼
            ├─ 1~5점 + 공통 사유(선택) 다이얼로그
            │    └─ 사유 칸은 Standalone 항상, Client 는 서버 app/config capabilities 에 rating_cause 가 있을 때만
            │       (길이는 코드포인트, 상한 1000 — RatingService.normalizeCause/causeError, 서버와 공용 벡터)
            ├─ RatingService.ineligibleReason() 기준 선별 (서버 services/rating_eligibility 와 같은 규칙·공용 벡터)
            │    └─ 참여 완료 / 참여 불가 / 답변 대기 / 취하 / 처리중 / 진행 / 진행중 / 검토중 자동 스킵
            └─ ReportProvider.submitRatings(score, cause)
                 ├─ Client(server)
                 │    ├─ POST /api/v1/rating/start {report_numbers, score, cause?}
                 │    ├─ /api/v1/files/download?path=logs/current_rating.log 폴링 (로그 줄 형식이 계약)
                 │    └─ 성공/스킵/실패를 RatingBatchResult 로 정리
                 └─ Standalone (서버 star_rating_service 와 같은 흐름)
                      ├─ public 만족도 score API로 확인 — 점수 있으면 스킵(이번에 제출했으면 성공)
                      ├─ POST …/satisfactionstatistics (STSFDG_CAUSE = 사유)
                      ├─ 다시 조회해 점수가 보일 때만 성공(아니면 최대 3회 재시도 후 실패)
                      └─ 사이트가 돌려준 점수·사유를 updateReportRatingByNumber() 로 저장

완료 후:
  ├─ NotificationHistoryProvider.addRatingBatchResult()
  ├─ MethodChannel showNotification(nav_tab=4, nav_subtab=2)
  └─ NotificationsScreen 의 "별점 주기" 탭에서 상세 카드 시트 표시
```

`RatingService` 는 Standalone 뿐 아니라 Client 모드에서도 `SyncForegroundService`
를 재사용한다. 별점 작업/로그 추적이 끝날 때까지 앱 프로세스가 쉽게 정리되지 않도록
동기화와 같은 보호 경로를 탄다.
UI 레벨에서는 `SelectionActionBar._rate()` 가 `_busy` 전체 잠금을 걸지 않고
fire-and-forget 으로 시작한다. 사용자는 즉시 선택 모드에서 빠져나오고,
완료 결과만 알림/히스토리/SnackBar 로 확인한다.

### 6. 최근 답변 / 카테고리 라우팅

- `DashboardStats.recentAnswers` 는 가벼운 요약용 fallback 이다. 대시보드와
  `RecentAnswersScreen` 은 가능하면 `ReportProvider.recentAnswerReports` 를 사용한다.
- Client 모드 `fetchSummary()` 는 서버 `/summary` 가 `exclude_withdraw=true` 를 함께 보내면
  `withdrawCount=0`, recent answers/watchlist 취하 제거를 한 번 더 적용해 서버/앱 배포 순서가 엇갈려도 화면 기준을 유지한다.
- `ReportProvider.ensureCategoryReportsLoaded()` 는 traffic / parking / other 원본 목록을
  한 번 확보하고, `recentAnswerReports` 는 그 실제 목록에서 최근 3일 답변을 다시 계산한다.
  그래서 summary 쿼리 한도에 잘리지 않고 카테고리도 유지된다.
- `recentAnswerReports` 의 최종 정렬 기준은 서버 대시보드와 맞춰 `synced_at DESC`,
  fallback `답변일 DESC`, `신고번호 DESC` 이다.
  `답변일`만 보면 같은 날 여러 건이 섞일 수 있으므로, `Report` 모델이 `syncedAt` 을
  실제로 보존하고 있어야 한다.
- `ReportProvider.findCategory(report)` 는 `Report.category` 를 우선 사용하고, 비어 있으면
  로드된 카테고리 목록에서 다시 찾는다.
- `report_detail_sheet.dart` 의 차량번호 / 위반장소 / 위반법규 / 담당자 링크는
  `ensureCategoryReportsLoaded()` 후에도 카테고리를 못 찾으면 이동을 막고 SnackBar 로 종료한다.
  교통 탭(0번)으로 조용히 기본 이동시키지 않는다.
- `ApiService.getReports(category)` 는 서버 응답에 `category` 가 비어 와도
  `traffic` / `parking` / `other` 를 보강해서 넣는다.
- `rating_batch_result.dart` 의 히스토리 직렬화도 `category` 를 함께 저장한다.
  알림/별점 결과 화면에서 상세 시트를 다시 열어도 원래 신고 탭으로 돌아갈 수 있어야 한다.

## 신고리스트 상세검색

- `SearchFilterSheet`는 `report_list_screen.dart`와 `search_screen.dart`가 공용 사용.
- 실제 필터 적용은 `ReportProvider._applyFilter()`에서 처리하므로 **Client(server) 모드와 Standalone 모드에 동일하게 적용**된다.
- 신고 카드 렌더링은 `widgets/report_list_card.dart`로 공용화되어 `report_list_screen.dart`, `search_screen.dart`, `filtered_list_screen.dart`가 같은 카드 골격을 공유한다.
- `신고명`, `신고번호`, `차량번호`, `위반장소`, `처리기관`, `담당자`, `과태료/범칙금`, `별점사유`, `신고내용`, `처리내용`은 `&` = AND, `,` = OR 문법을 사용한다.
- `위반법규`는 자유입력이 아니라 로드된 신고 데이터에서 distinct 추출한 **단일선택 드롭다운**이다.
  - 빈 값 신고가 하나라도 있으면 내부 sentinel `kEmptyLawFilterValue = "__없음__"` 를 포함하고, UI에는 `없음`으로 표시한다.
  - `ReportProvider._applyFilter()`는 일반 법규는 exact match, sentinel 은 `r.law.trim().isEmpty` 로 처리한다.
- `처리상태`는 로드된 신고 목록에서 distinct 값을 추출해 다중선택 UI로 노출한다.
- `별점`은 `없음`, `1~5점` 다중선택 UI로 노출한다.
- 두 다중선택 UI 모두 선택된 항목 우측에 초록 `v`를 표시한다.
- `만족도 조사 여부`는 `참여 완료`, `참여 가능` 단일선택 드롭다운으로 노출한다. 서버 `data_table.html` 상세 검색에도 동일하게 추가되어 있다.
- `statistics_screen.dart`의 통계 행 탭은 별도 `FilteredListScreen`이 아니라 `ReportFilter`를 세팅한 뒤 `ReportListScreen(initialTabIndex: ...)`로 이동한다.
  - 기관/담당자/연도/위반법규 필터를 함께 넘기며, 통계의 `법규 없음`도 같은 sentinel 으로 전달한다.

## 신고현황 / 파일 브라우저

- `sunwi_screen.dart`는 `ReportProvider.bumpSunwiRefresh()` 신호를 받아도 즉시 재수집하지 않고, 모드별 메모리 캐시 기준 **마지막 수집 후 3시간이 지났을 때만** 재동기화한다.
- 사용자가 명시적으로 당겨서 새로고침하거나 상단 새로고침 버튼을 누른 경우에는 3시간 TTL을 무시하고 강제 재수집한다.
- `sunwi_screen.dart`의 대분류/소분류는 서버 대시보드와 동일하게 5초마다 자동 전환된다. 사용자가 좌우 버튼으로 직접 넘기면 타이머를 다시 시작한다.
- Standalone `sunwi` CSV는 `Documents/mysafetyreport/sunwi/` 또는 기기 제한 시 `Download/mysafetyreport/sunwi/`에 저장된다.
- `file_browser_screen.dart` standalone 모드는 루트 `mysafetyreport`뿐 아니라 그 하위 폴더도 탐색 가능해야 한다. `sunwi/`처럼 기능별 하위 폴더가 생겨도 파일 탭에서 바로 진입할 수 있어야 한다.

## 정부 정보 출처 / 비공식 고지

- Play Console 대응으로 **앱 안에서 정부 정보 원문 출처를 직접 열 수 있어야 한다**.
- 현재 공식 출처는 `https://www.safetyreport.go.kr/` 로 통일한다.
- 출처/비공식 고지는 아래 두 위치에 중복 노출한다.
  - `widgets/report_detail_sheet.dart`
    - `안전신문고 앱에서 보기` 버튼 바로 아래
  - `screens/settings_screen.dart`
    - `앱 정보` 카드 내부
- 고지 문구 핵심:
  - 이 앱은 안전신문고의 공식 앱이 아니며 정부기관을 대표하지 않는다.
  - 안전신문고 데이터를 사용자 편의용으로 조회/정리해 보여주는 비공식 도구다.
  - 원문 확인과 실제 민원 처리는 안전신문고 공식 서비스에서 진행해야 한다.

## 모드별 테마 (main.dart)

`MaterialApp` 을 `Consumer<ReportProvider>` 로 감싸 `appMode` 변화 시 시드 컬러 자동 전환:

| 모드 | Primary | Indicator |
|------|---------|-----------|
| Client | `#1A73E8` (구글 블루) | `#E3EEFF` |
| Standalone | `#1B873B` (머티리얼 그린) | `#DFF1E3` |

`colorScheme.copyWith(surface: white, ...)` 로 surface 계열은 흰색 강제 (Material 3 `fromSeed` 가 그린에서 파생하는 노란기 surface 톤 차단).

## 외부 참조

- **Client 모드 서버 프로젝트 (로컬)**: `/home/better0101/projects/safetyreport`
- **사용자 가이드 (모바일)**: <https://hb.worklazy.net/mysafetyreport/>
- **라즈베리파이 서버 설정**: <https://hb.worklazy.net/raspberry-pi-mysafetyreport-setup/>
- **서버 GitHub**: <https://github.com/Fentanest/safetyreport>
- **모바일 GitHub**: <https://github.com/Fentanest/safetyreport-mobile>
- **버그 제보**: <https://github.com/Fentanest/safetyreport-mobile/issues>

---

## 2026-09-24 이후 변경 (UI 리뉴얼 시범)

- **테마 계층**: `lib/theme/sr_colors.dart`(토큰 `SrColors` ThemeExtension, `contrastRatio`, `StatusTone`) + `lib/theme/app_theme.dart`(`AppTheme.build`).
  `main.dart` 는 `AppTheme.light()/dark()` 만 쓰고 `themeMode`(system/light/dark) 저장·복원은 그대로다.
  위 원문 "모드별 테마" 절의 모드별 primary(파랑/초록)는 **폐지**됐다. 두 모드 공통 primary, 모드는 `ModeBadge`(대시보드 앱바)로 표시.
- **앱바/탭**: 앱바는 배경색(파란 앱바 폐지). 신고내역·신고관리·알림 상단 탭은 `lib/widgets/sr_tab_bar.dart`(알약형, 테마 색). 앱바 안에 `Colors.white` 를 쓰면 라이트 테마에서 안 보이므로 금지.
- **상태 배지**: `lib/widgets/status_badge.dart`. 기준색은 `server_palette.dart`(D-02: 모바일 먼저 토큰 상태색, 서버 웹은 별도 추종), 글자/배경은 `StatusTone` 이 AA(4.5:1) 보정.
- **신고 카드**: `report_list_card.dart` 가 긴 신고명·차량번호에서 넘치지 않도록 재배치(표시 필드·콜백 동일).
- **통계 요약**: `lib/widgets/stats_overview_section.dart` + `lib/models/stats_overview.dart`. 데이터는 `LocalDbService.computeStatsOverview`(Standalone) / `ApiService.getStatsOverview`(Client). 정의: `docs/design/statistics-spec.md` §4·§6-1.
- **하단 탭 5개(D-06)**: 0 대시보드, 1 신고내역, 2 신고관리, 3 통계, 4 알림. 동기화/크롤링·파일은 `lib/navigation/app_routes.dart` 로 연다.
  위 원문 "하단 탭 구조"(7개)는 **구버전**이다. 네이티브는 여전히 nav_tab 5/6 을 보낼 수 있고 Flutter 가 화면으로 변환한다.
  동기화 화면은 GlobalKey 를 쓰므로 반드시 `AppRoutes.openCrawl` 로만 연다(동기 open 플래그로 중복 push 방지).
- 전 화면 토큰 통일 완료(2026-09-24). 남긴 색 목록은 CHANGELOG 같은 날짜 항목 참조. SnackBar 성공/실패는 `srSnackSuccess`/`srSnackError`.
