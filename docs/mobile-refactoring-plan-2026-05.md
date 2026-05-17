# 모바일 리팩토링 계획 (2026-05)

## 목적

이번 후속 리팩토링의 목표는 새 기능 추가가 아니라, 모바일 레포 안에 퍼져 있는 다음 문제를 줄이는 것이다.

- 불필요한 헬퍼와 우회 계층 축소
- 화면에서 직접 서비스, `SharedPreferences`, 파일 경로를 만지는 패턴 제거
- `Client`/`Standalone` 모드 분기가 화면과 provider 전역으로 번지는 구조 정리

## 현재 진단

정량적으로 봐도 "기능 부족"보다 "구조 중복"이 더 큰 문제다.

- `lib/` 안에 `AppMode.standalone` 분기가 43회 등장한다.
- 모바일 재시도 루프가 9곳에 중복돼 있다.
- `SharedPreferences` 접근 지점이 88회로 퍼져 있다.
- `mysafetyreport` 저장 경로 literal 이 9회 반복된다.

핵심 hotspot 은 아래와 같다.

### 1. `ReportProvider`가 너무 많은 책임을 갖고 있다

`lib/providers/report_provider.dart:161` 이후 한 파일 안에서 아래 역할을 모두 처리한다.

- 세션/모드 상태
- 필터 상태와 가공 로직
- 요약/카테고리/중복/감시목록 로딩
- Standalone 재개 시 동기화
- `SharedPreferences` 영속화
- 탭 리프레시용 nonce 발행

특히 아래 메서드는 형태가 거의 비슷한데 모드 분기만 반복된다.

- `fetchSummary()` (`lib/providers/report_provider.dart:702`)
- `fetchTrafficReports()` (`lib/providers/report_provider.dart:739`)
- `fetchParkingReports()` (`lib/providers/report_provider.dart:763`)
- `fetchOtherReports()` (`lib/providers/report_provider.dart:787`)
- `fetchDuplicateReports()` (`lib/providers/report_provider.dart:811`)
- `fetchWatchlistNumbers()` (`lib/providers/report_provider.dart:832`)

추가로 설정 저장/로드와 모드 전환까지 같은 파일에 묶여 있다.

- `fetchAppConfig()` (`lib/providers/report_provider.dart:499`)
- `setStandaloneFilter()` (`lib/providers/report_provider.dart:520`)
- `init()` (`lib/providers/report_provider.dart:546`)
- `setConfig()` (`lib/providers/report_provider.dart:615`)
- `setStandaloneConfig()` (`lib/providers/report_provider.dart:636`)
- `resetConfig()` (`lib/providers/report_provider.dart:668`)

### 2. 일부 화면이 provider를 우회해 다시 data source를 고른다

재사용 패널 구조 자체는 의도된 설계지만, 패널 내부가 다시 `ApiService`/`LocalDbService`를 직접 선택하면서 책임이 분산돼 있다.

- `WatchlistPanel` 이 `_load()` 에서 다시 모드 분기 후 `LocalDbService` 또는 `ApiService`를 직접 호출 (`lib/screens/watchlist_screen.dart:43`)
- `DuplicateManagementPanel` 이 `_load()`/`_saveGroup()` 에서 직접 분기 (`lib/screens/duplicate_management_screen.dart:33`, `lib/screens/duplicate_management_screen.dart:85`)
- `SunwiSection` 이 `_load()`/`_exportCsv()` 에서 직접 분기 (`lib/screens/sunwi_screen.dart:78`, `lib/screens/sunwi_screen.dart:199`)
- `FileBrowserScreen` 이 로컬 파일/서버 파일 로직을 화면 state 안에서 모두 관리 (`lib/screens/file_browser_screen.dart:51`, `lib/screens/file_browser_screen.dart:149`, `lib/screens/file_browser_screen.dart:200`)
- `SettingsScreen` 이 `ApiService` 생성, raw HTTP, DB 백업/복원, 모드 전환 절차까지 직접 가진다 (`lib/screens/settings_screen.dart:74`, `lib/screens/settings_screen.dart:118`, `lib/screens/settings_screen.dart:448`, `lib/screens/settings_screen.dart:554`, `lib/screens/settings_screen.dart:674`)

결과적으로 provider는 "공용 상태 저장소" 역할을 못 하고, 화면마다 다른 우회 경로가 생긴다.

### 3. 네트워크 재시도 로직이 공통 상수만 공유하고 구현은 중복돼 있다

재시도 횟수 상수는 `lib/services/network_retry_config.dart` 로 모였지만, 실제 루프는 여러 곳에 복제돼 있다.

- `ApiService._sendWithRetry()` / `_sendMultipartWithRetry()` (`lib/services/api_service.dart:31`, `lib/services/api_service.dart:55`)
- `StandaloneApiService._getPublicWithRetry()` / `_postPublicFormWithRetry()` / `_getWithRetry()` (`lib/services/standalone_api_service.dart:57`, `lib/services/standalone_api_service.dart:83`, `lib/services/standalone_api_service.dart:133`)
- `StandaloneAuthService.login()` 내부 RSA 조회/토큰 요청 (`lib/services/standalone_auth_service.dart:64`, `lib/services/standalone_auth_service.dart:116`)
- `SetupScreen._connectServer()` (`lib/screens/setup_screen.dart:67`)
- 파일 다운로드 (`lib/screens/file_browser_screen.dart:770`)

이 상태에서는 재시도 정책을 바꿔도 모든 위치를 같이 수정해야 한다.

### 4. 문자열 key/경로/임시 액션 포맷이 흩어져 있다

`SharedPreferences` key 와 파일 경로, pending action 포맷이 화면과 서비스에 문자열로 흩어져 있다.

- `pending_db_import` 해석이 `SetupScreen` 과 `SettingsScreen` 에 분산 (`lib/screens/setup_screen.dart:214`, `lib/screens/settings_screen.dart:752`)
- `standalone_pending_reports` 큐 쓰기가 `SelectionActionBar` 에서 직접 발생 (`lib/widgets/selection_action_bar.dart:65`)
- 동일 큐 key 를 `StandaloneAutoSyncService` 가 별도 상수로 보유 (`lib/services/standalone_auto_sync_service.dart:42`)
- `pending_crawl_changes` 소비가 `main.dart` 에, 생산이 `SyncEngine` 에 분리 (`lib/main.dart:283`, `lib/services/sync_engine.dart:301`)
- 저장 경로 fallback 가 `FileBrowserScreen._exportsDir()`, `SettingsScreen._backupDir()`, `SunwiService._standaloneExportDir()` 에 각각 존재 (`lib/screens/file_browser_screen.dart:149`, `lib/screens/settings_screen.dart:660`, `lib/services/sunwi_service.dart:157`)

이 부분은 기능 버그보다 "나중에 바꾸기 어려운 구조 부채"에 가깝다.

### 5. 탭 새로고침이 nonce + side effect 기반이다

- `ReportProvider` 가 `_statsRefreshNonce`, `_filesRefreshNonce`, `_sunwiRefreshNonce`, `_pendingChangesNonce` 를 발행 (`lib/providers/report_provider.dart:186`)
- `main.dart` 가 탭별 새로고침 동작을 switch 문으로 직접 유지 (`lib/main.dart:247`)

이 구조는 당장은 동작하지만, 화면 수가 늘수록 "어느 탭에서 무엇을 다시 불러와야 하는지"가 분산된다.

## 무엇을 먼저 줄일지

### 바로 줄여야 하는 것

- 화면에서 직접 `ApiService`/`LocalDbService` 선택
- 화면에서 직접 `SharedPreferences` key 문자열 쓰기
- 화면마다 복제된 재시도 루프
- 파일 경로 fallback, DB staging, pending action parsing 같은 절차형 헬퍼
- 카테고리별 fetch 메서드 복제

### 바로 없애지 않을 것

아래 래퍼 자체는 1차 제거 대상이 아니다.

- `WatchlistScreen` / `WatchlistPanel`
- `SunwiScreen` / `SunwiSection`
- `ReportManagementScreen`

이 래퍼들은 `CLAUDE.md` 기준으로 임베드 재사용 의도가 분명하다. 문제는 래퍼의 존재보다, 래퍼 안에서 data source 선택과 side effect 까지 다시 수행하는 점이다.

## 우선순위별 계획

### P0. 문자열 key / 파일 경로 / pending action 타입화

가장 먼저 작은 위험으로 얻을 수 있는 정리다.

- `AppPrefsKeys` 추가
- `AppStoragePaths` 추가
- `PendingDbImportAction` value object 추가
- `PendingChangesStore` 또는 `AppEventStore` 추가

대상 치환 예시:

- `'pending_db_import'`
- `'standalone_pending_reports'`
- `'pending_crawl_changes'`
- `'/storage/emulated/0/Documents/mysafetyreport'`
- `'/storage/emulated/0/Download/mysafetyreport'`

우선 적용 후보:

- `lib/screens/setup_screen.dart`
- `lib/screens/settings_screen.dart`
- `lib/widgets/selection_action_bar.dart`
- `lib/services/standalone_auto_sync_service.dart`
- `lib/services/sunwi_service.dart`
- `lib/main.dart`

완료 기준:

- 화면 코드에서 raw prefs key 문자열 직접 쓰기 제거
- 화면 코드에서 저장 경로 literal 제거

### P1. 모드별 repository 계층 도입

핵심은 "화면이 모드 분기를 알지 않게 하는 것"이다.

후보 인터페이스:

- `ReportRepository`
- `WatchlistRepository`
- `DuplicateRepository`
- `SunwiRepository`
- `SettingsRepository`

구현은 최소 두 가지로 나눈다.

- `Server...Repository`
- `Standalone...Repository`

1차 마이그레이션 대상:

- `WatchlistPanel`
- `DuplicateManagementPanel`
- `SunwiSection`

이 세 군데는 이미 재사용 패널인데 내부에서 다시 모드를 고르고 있어 효과가 크다.

완료 기준:

- 위 3개 패널에서 `ApiService(...)`, `LocalDbService...`, `provider.appMode == ...` 직접 사용 제거

### P2. `ReportProvider` 분해

`ReportProvider` 는 이번 리팩토링의 가장 큰 구조 부채다. 한 번에 갈아엎기보다 기능군 기준으로 분해한다.

권장 분해 방향:

- `SessionConfigProvider`
  - 모드, URL/API key, standalone 계정, demo 여부
- `ReportQueryProvider`
  - summary, category reports, filter, recent answers
- `SyncStatusProvider`
  - pending changes, sync running 상태, refresh trigger

함께 정리할 중복:

- `fetchTrafficReports()` / `fetchParkingReports()` / `fetchOtherReports()` 를 `fetchCategoryReports(String category)` 기반으로 통합
- `_hasLoadedTrafficReports` 같은 category별 flag 를 map 구조로 통합
- `refreshAll()` 의 모드 분기와 load order 정책을 coordinator 로 이동

완료 기준:

- `report_provider.dart` 에서 세션 저장/동기화 lifecycle/카테고리 쿼리 로직이 분리됨
- category별 fetch 중복 메서드가 1개 공용 경로로 축소됨

### P3. 화면의 절차형 로직을 서비스로 내리기

특히 `SetupScreen`, `SettingsScreen`, `FileBrowserScreen` 은 UI 보다 절차형 로직 비중이 너무 높다.

분리 후보:

- `ServerConnectionService`
  - setup 연결 확인
  - 설정 화면 연결 테스트
  - 서버 버전 확인
- `DbTransferService`
  - DB 백업
  - DB 복원
  - staging/wal/shm 처리
  - server/mobile 형식 감지
- `StandaloneQueueService`
  - 신고번호 enqueue
  - pending queue read/write/remove
- `FileExportService`
  - standalone Excel export
  - sunwi CSV export 경로 처리

즉시 통합 후보:

- `SetupScreen._connectServer()` 와 `SettingsScreen._testConnection()`
- `FileBrowserScreen._exportsDir()` 와 `SettingsScreen._backupDir()` 와 `SunwiService._standaloneExportDir()`
- `SelectionActionBar._sync()` 와 `StandaloneAutoSyncService` 의 큐 쓰기

완료 기준:

- `SettingsScreen` 과 `SetupScreen` 에서 raw HTTP/retry/prefs parsing 상당수 제거
- `FileBrowserScreen` 은 UI 조작과 파일 표시만 담당

### P4. refresh nonce / 탭 side effect 정리

현재 구조는 동작하지만 확장성이 떨어진다.

- `ReportProvider.bumpStatsRefresh()` 류 nonce 제거 검토
- 탭 전환 후 새로고침을 `MainNavigationScreen` switch 문이 아니라 feature 단위 refresh contract 로 이관
- `pending_crawl_changes` 소비도 `main.dart` 직접 접근 대신 store/service 를 통해 처리

이 작업은 P0~P3 이후가 안전하다. 먼저 data source 와 side effect 를 줄여야 nonce 제거가 쉬워진다.

## 바로 손댈 수 있는 중복 후보

이번 계획을 실제 작업으로 옮길 때 가장 먼저 꺼내기 좋은 항목들이다.

1. `fetchTrafficReports` / `fetchParkingReports` / `fetchOtherReports` 통합
2. `SetupScreen._connectServer` 와 `SettingsScreen._testConnection` 공용화
3. `FileBrowserScreen._exportsDir`, `SettingsScreen._backupDir`, `SunwiService._standaloneExportDir` 공용화
4. `SelectionActionBar._sync` 의 prefs 직접 쓰기 제거
5. `WatchlistPanel._load`, `DuplicateManagementPanel._load`, `SunwiSection._load` 의 직접 분기 제거
6. `SettingsScreen` 의 DB 백업/복원/모드 전환 절차를 서비스로 이동

## 이번 차수에서 보류할 것

다음 항목은 지금 문서의 우선순위에서 뒤로 둔다.

- `LocalDbService` 대규모 재작성
- `DuplicateProjectionService` 알고리즘 변경
- `SunwiService` 수집 알고리즘 자체 재설계

이 영역들은 최근 변경 폭이 컸고, "불필요한 헬퍼/우회 계층 제거"보다 회귀 리스크가 더 크다.

## 추천 실행 순서

1. P0: prefs key / storage path / pending action 타입화
2. P1: `Watchlist`, `Duplicate`, `Sunwi` 3개 패널을 repository 경유로 전환
3. P2: `ReportProvider` 를 세션/쿼리/동기화 기준으로 분해
4. P3: `SetupScreen`, `SettingsScreen`, `FileBrowserScreen` 절차형 로직 이동
5. P4: refresh nonce 제거와 탭 새로고침 단순화

## 완료 후 기대효과

- 화면이 모드별 저장소 구현을 몰라도 된다.
- 문자열 key 와 로컬 경로 수정이 한 곳에서 끝난다.
- 신규 기능을 붙일 때 `Client`/`Standalone` 분기를 또 복제하지 않아도 된다.
- 최근 추가된 `중복 신고`, `신고관리`, `sunwi 임베드` 기능도 같은 패턴으로 유지할 수 있다.

## 2026-05-17 실행 상태

### 이번 라운드에서 실제 반영된 항목

- `P0` 일부 반영
  - `lib/services/app_prefs_keys.dart` 기반 설정 key 정리 지속
  - standalone 지오코딩/지도 설정, pending import 흐름, 지도 진행률 표시가 공용 key 와 service 쪽으로 이동
- `P1/P3` 일부 반영
  - 통계 탭의 지도 기능은 화면이 직접 좌표 계산을 하지 않고 `ApiService` / `LocalGeocodeService` / `LocalDbService` 를 통해 가져오도록 분리
  - DB import 는 staging/validation/commit 절차가 `LocalDbService.importFromServerDb()` 내부로 정리되어 설정 화면이 세부 교체 절차를 덜 알게 됨
- 안정화 후속
  - watchlist 변경 시 representative projection cache 무효화
  - import 교체 실패 시 backup 복구 및 backup 보존 경로 보강
  - dead field `top_agency` 제거
  - `sqflite_common_ffi` 기반 regression test 추가

### 이번 라운드에서 자동 검증된 항목

- `flutter analyze lib/models/report_map.dart lib/services/local_db_service.dart test/services/local_db_service_regression_test.dart`
- `flutter test`
  - representative projection cache invalidation
  - invalid server DB import preserve

### 아직 남아 있는 구조 작업

- `ReportProvider` 분해 자체는 아직 시작 전이며, `Client`/`Standalone` 분기 다수는 그대로 남아 있다.
- `Watchlist`, `Duplicate`, `Sunwi` 패널의 repository 추상화도 아직 계획 단계다.
- 이번 차수는 새 지도/지오코딩 기능과 import 안정화, 회귀 테스트 보강이 우선이었고, 대규모 provider 분해는 다음 차수 대상이다.
