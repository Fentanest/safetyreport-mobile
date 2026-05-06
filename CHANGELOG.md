# Changelog

작업, 버그 수정, 세션 기록용 문서.

- 구조/운영 컨텍스트는 `CLAUDE.md`에 유지
- 2026-05-01에 `CLAUDE.md`의 작업 이력 섹션과 최근 검색 기능 변경을 이 파일로 이관 시작

---

## 2026-05-07 (P0~P3 리팩토링)

### `docs/mobile-refactoring-plan-2026-05.md` 적용 1차 — 문자열 키/패널/카테고리 fetch 정리

상태: 완료 (P0~P3 1차 분량). P4 (refresh nonce 제거) 와 ReportProvider 분해는 별도 차수로 보류.

신규 파일:
- `lib/services/app_prefs_keys.dart` — SharedPreferences 키 단일 소스
- `lib/services/app_storage_paths.dart` — `mysafetyreport` 산출물 디렉토리 fallback 단일 소스
- `lib/services/pending_db_import_action.dart` — 모드 전환 시 SetupScreen 이 적용할 액션 value object
- `lib/services/pending_changes_store.dart` — `pending_crawl_changes` / `foreground_event` 키 wrapper
- `lib/services/standalone_pending_queue_store.dart` — Standalone 알림 큐 read/append/remove 단일 소스
- `lib/services/server_connection_service.dart` — Setup 공용 서버 연결 테스트 + Settings 서버 버전 조회용 공통 서비스
- `lib/services/repositories/watchlist_repository.dart`
- `lib/services/repositories/duplicate_repository.dart`
- `lib/services/repositories/sunwi_repository.dart`
- `test/services/pending_changes_store_test.dart`
- `test/services/pending_db_import_action_test.dart`
- `test/services/server_connection_service_test.dart`
- `test/services/standalone_pending_queue_store_test.dart`

화면/위젯 변경:
- `lib/screens/setup_screen.dart` — `_connectServer` 가 `ServerConnectionService.testConnection()` 사용. `_applyPendingDbImport` 이 `PendingDbImportAction` 사용. raw http retry 루프 / pending action 문자열 파서 제거.
- `lib/screens/settings_screen.dart` — `_loadServerVersion` 이 `ServerConnectionService.fetchVersionInfo()` 사용. `_backupDir` / `_exportsDir` 가 `AppStoragePaths` alias. pending action 저장이 `PendingDbImportAction.save()` 호출. 연결 테스트 UI(`_testConnection`)는 아직 기존 상세 응답 표시 경로 유지.
- `lib/screens/file_browser_screen.dart` — `_exportsDir` 이 `AppStoragePaths.exportsRoot()` 호출.
- `lib/screens/watchlist_screen.dart` — `WatchlistPanel._load` 이 `WatchlistRepository.fromProvider` 경유, `ApiService` / `LocalDbService` 직접 호출 제거.
- `lib/screens/duplicate_management_screen.dart` — `DuplicateManagementPanel._load` / `_saveGroup` 이 `DuplicateRepository.fromProvider` 경유.
- `lib/screens/sunwi_screen.dart` — `SunwiSection._load` / `_exportCsv` 가 `SunwiRepository.fromProvider` 경유. 캐시 엔트리도 `SunwiSnapshot` 단일 객체로 단순화.
- `lib/widgets/selection_action_bar.dart` — `_sync` 가 `StandalonePendingQueueStore.append()` 호출 (raw prefs.setString 제거).
- `lib/main.dart` — `_checkForegroundEvent` 가 `ForegroundEventStore.readAndClear()`, `_checkPendingChanges` 가 `PendingChangesStore.readAndClear()` 사용.

서비스/Provider 변경:
- `lib/providers/report_provider.dart` — `_hasLoadedTraffic/Parking/Other` 3개 boolean 을 `Set<String> _loadedCategories` 로 통합. `fetchTrafficReports/Parking/Other` 가 `fetchCategoryReports(category)` 공용 경로의 thin wrapper. `ensureCategoryReportsLoaded` / `refreshAll` 도 한 줄 루프로 정리.
- `lib/services/sync_engine.dart` — `pending_crawl_changes` 직접 쓰기 대신 `PendingChangesStore.append()` 사용. 키 문자열 모두 `AppPrefsKeys` 로 치환.
- `lib/services/standalone_auto_sync_service.dart` — 큐 IO 가 `StandalonePendingQueueStore` 경유.
- `lib/services/standalone_auth_service.dart`, `lib/providers/notification_history_provider.dart` — 키 문자열을 `AppPrefsKeys` alias 로 치환.
- `lib/services/sunwi_service.dart` — `_standaloneExportDir` 이 `AppStoragePaths.subDir('sunwi')` alias.

검증:
- `dart analyze`
  - 에러 없음
  - warning/info 잔존 (`settings_screen.dart` dead code, deprecation/style lint 포함)
- `flutter test`
  - 기존 placeholder 1건 + 신규 service/store 테스트 통과

비고:
- 이번 차수에서 보류한 항목 (P4 refresh nonce 정리, `ReportProvider` 분해, `DbTransferService`/`FileExportService` 추출) 은 다음 차수로 이월.
- Kotlin native 의 SharedPreferences 키 이름과 호환을 유지한다. Kotlin 측 코드는 손대지 않았다.

---

## 2026-05-07

### 대시보드 임베드 신고현황 백지 방지 + Client 중복 신고 404 방어

상태: 완료

변경:
- `lib/screens/sunwi_screen.dart`
  - `SunwiSection(embedded: true)` 가 대시보드 안에서 자체 `ListView` 를 만들지 않고 일반 `Column`만 렌더하도록 수정
  - 대시보드 `SingleChildScrollView` 안에서 중첩 스크롤로 레이아웃이 깨져 백지로 보이던 문제 방지
- `lib/services/api_service.dart`
  - 서버가 `/api/v1/duplicates/groups` 를 아직 제공하지 않아 `404`를 돌릴 때 전용 예외로 분기
- `lib/screens/duplicate_management_screen.dart`
  - Client 모드에서 중복 신고 API 미지원(`404`)이면 크래시성 에러 대신 안내 문구와 빈 상태로 표시
  - Standalone 모드에서는 로드 전에 중복 projection 스키마 생성을 한 번 더 보장

비고:
- `404 중복 신고 그룹 조회 실패`는 Client 서버 버전 미지원일 때만 가능한 증상이고, Standalone은 동일 증상이 나지 않는다.

### 신고관리 탭 추가 + 신고현황 대시보드 하단 이동

상태: 완료

변경:
- `lib/main.dart`
  - 하단 `신고현황` 탭 제거
  - `신고내역`과 `통계` 사이에 `신고관리` 탭 추가
- `lib/screens/report_management_screen.dart`
  - `감시 목록`, `중복 신고` 하위 탭을 가진 관리 화면 추가
- `lib/screens/dashboard_screen.dart`
  - 대시보드 최하단에 `신고현황` 섹션을 임베드
  - 감시 목록 `관리`/`더 보기` 동선을 새 `신고관리 > 감시 목록` 화면으로 연결

비고:
- `SunwiSection` 은 대시보드 요약 로딩과 별개로 자체 로딩되어, 신고현황 데이터가 늦어도 대시보드 전체를 막지 않는다.

### 중복 신고 변경을 모바일 알림/신고 결과에 반영

상태: 완료

변경:
- `lib/models/notification_item.dart`
- `lib/providers/notification_history_provider.dart`
- `lib/screens/notifications_screen.dart`
  - `notification_kind=duplicate` 항목을 신고 결과 탭과 상세 시트에서 처리
- `lib/services/sync_engine.dart`
- `lib/services/standalone_auto_sync_service.dart`
  - 크롤링/동기화 뒤 중복군 변경을 감지해 pending change 및 앱 알림에 포함
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt`
  - 푸시/알림 탭 클릭 시 중복군 상세 payload까지 전달

### 모바일 설정 문구/배치 정리

상태: 완료

변경:
- `lib/screens/settings_screen.dart`
  - `경찰 기관명 정규화 → 취하 데이터 숨기기 → 중복 신고 대표건만 반영` 순서로 정리
  - 대표건 기준 설명 문구를 줄바꿈하고 `비활성화할 경우` 표현으로 수정

## 2026-05-06

### Standalone 중복 신고 projection 추가 + 대표건 기준 전역 설정 준비

상태: 완료

변경:
- `lib/services/duplicate_projection_service.dart`
  - `raw_content` exact match 기준의 Standalone 중복군 계산 로직 추가
  - `duplicate_group`, `duplicate_member` 로컬 테이블 생성/갱신
  - 대표건 자동 우선순위(`과태료 > 경고/범칙금 > 처리상태 > 답변일 > synced_at > 신고번호`) 적용
  - `review_required`, `confirmed_duplicate`, `not_duplicate` 상태와 `auto`, `manual` 대표건 모드 지원
- `lib/models/duplicate_group.dart`
  - 중복군/멤버 모델 및 라벨 헬퍼 추가
- `lib/widgets/duplicate_group_detail_sheet.dart`
  - 중복군 상세 바텀시트 추가
- `lib/screens/duplicate_management_screen.dart`
  - Client/Standalone 겸용 중복 신고 관리 패널 추가
  - 대표건 child를 직접 선택하면 자동 모드에서도 저장 전에 `수동 고정`으로 전환되도록 UX 보강
- `lib/services/local_db_service.dart`
  - Standalone DB version `5 -> 6`
  - DB 생성/업그레이드 시 중복 projection 스키마 자동 생성
  - 요약/목록/통계/감시목록/검색에 `useRepresentativeRecords` 기준 projection 반영
  - demo seed, 서버 DB import, 백업 복원, 수정 저장 후 중복군 재계산 연결
- `lib/providers/report_provider.dart`
  - `useRepresentativeRecords` 전역 상태 추가
  - Standalone `fetchSummary`/카테고리 로드에 대표건 기준 여부 전달

검증:
- `dart analyze ...` 대상 파일 기준 에러 없음
  - 경고/info만 남음

비고:
- `review_required` 그룹은 대표건 기준 설정과 무관하게 child 전체를 보여주는 방향을 로컬 projection에서도 유지한다.

### 모바일 기본 재시도 5회 상향 + 설정 기본값 정리

상태: 완료

변경:
- `lib/services/network_retry_config.dart`
  - 모바일 공용 재시도 횟수 상수 추가 (`5회`)
- `lib/services/api_service.dart`
- `lib/services/standalone_api_service.dart`
- `lib/services/standalone_auth_service.dart`
- `lib/screens/setup_screen.dart`
- `lib/screens/file_browser_screen.dart`
  - 각 네트워크 재시도 루프가 공용 상수를 사용하도록 정리
- `lib/screens/settings_screen.dart`
  - `크롤링 완료 후 구글 시트 자동 업로드` 기본값을 `false` 로 정리
  - `중복 신고 대표건만 반영` 전역 스위치 추가

비고:
- 서버 기본값(`auto_export_sheet=false`, `use_representative_records=true`)과 맞춘 변경이다.

### Watchlist / Sunwi 섹션 분리 기반 정리

상태: 완료

변경:
- `lib/screens/watchlist_screen.dart`
  - `WatchlistScreen` 을 `WatchlistPanel` 래퍼로 분리
  - 다른 화면/탭 안에 감시목록 패널을 재사용할 수 있게 구조 정리
- `lib/screens/sunwi_screen.dart`
  - `SunwiScreen` 을 `SunwiSection` 래퍼로 분리
  - `embedded` 모드를 추가해 대시보드 하단 등에 같은 섹션을 재사용할 수 있는 기반 추가

### Standalone DB version 5 / entry_value·raw_content·synced_at round-trip 보존

상태: 완료

변경:
- `lib/services/local_db_service.dart`
  - Standalone DB version `4 -> 5`
  - 원본 payload 보존용 `report_raw` 사이드카 테이블 추가
  - 기존 `reports.raw_content` 는 마이그레이션 시 `report_raw` 로 이관하고 본 테이블에서는 비워 두도록 변경
  - `upsertReport()` 가 동일 내용 재동기화에서는 `synced_at` 를 유지하고,
    실제 추적 필드 변경 또는 raw payload 변경이 있을 때만 갱신하도록 수정
  - 최근 답변 쿼리를 `synced_at DESC` 기준으로 변경하고,
    `synced_at` 가 없는 레코드는 `답변일 DESC`, `신고번호 DESC` fallback 정렬 적용
  - `clearAll()` 이 `report_raw` 도 함께 정리하도록 수정
  - `importFromServerDb()` 가 `mysafety_entry_value`, `mysafety_raw_content`, `merge_* .synced_at` 를 함께 읽어
    더 이상 `entry_value=''`, `raw_content=''`, `synced_at=now` 로 덮어쓰지 않도록 수정

검증:
- `dart format lib/services/local_db_service.dart`
- `dart analyze lib/services/local_db_service.dart lib/models/report.dart lib/services/sync_engine.dart`
  - 새 변경과 직접 관련 없는 기존 info 4건 외 추가 오류 없음

비고:
- 서버 쪽 `mysafety_raw_content` / `detail+merge.synced_at` 구조는 `safetyreport` 레포의 동일자 CHANGELOG 참고
- 이번 변경으로 Standalone DB 가 서버 DB 를 import 해도 `entry_value` 와 `synced_at` 를 더 정확히 보존한다

### Client 서버 계약 상수화 / Flutter-Android 호출 경로 정리

상태: 완료

변경:
- `lib/services/server_contract.dart`
  - Client 모드 서버 API prefix, 헤더 이름, WebSocket 경로, 주요 엔드포인트를 단일 상수 집합으로 정리
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerContract.kt`
  - 네이티브 쪽에서도 동일한 API/WS 경로와 이벤트 타입 상수를 사용하도록 정리
- `lib/services/api_service.dart`
  - Client 모드 HTTP 호출이 `ServerContract` 를 통해 URI/헤더를 만들도록 전환
- `lib/screens/setup_screen.dart`, `lib/screens/settings_screen.dart`, `lib/screens/file_browser_screen.dart`
  - 화면별로 흩어져 있던 Client 모드 서버 경로 하드코딩을 계약 헬퍼 기준으로 정리
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt`
  - `/ws/events`, `api_key`, `crawl_started`/`crawl_finished`/`crawl_changes`/`ping` 문자열을 공용 계약 상수로 정리
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt`
  - `/api/v1/crawl/enqueue`, `X-API-Key` 를 공용 계약 상수로 사용하도록 전환

비고:
- 서버 쪽 공용 서비스/크롤러 리팩토링은 `safetyreport` 레포의 동일자 CHANGELOG 참고
- Client 모드 서버 계약 문자열을 한 곳으로 모은 변경이며, 기존 서버 API 경로 자체는 바꾸지 않음

---

## 2026-05-05

### 대시보드 최근 답변 더보기 / 상세 시트 필드 링크 / 별점 batch 비차단화

상태: 완료

변경:
- `lib/screens/dashboard_screen.dart`
  - "최근 답변 완료 (3일)" 섹션을 감시 목록과 동일한 패턴으로 정리: 5건만 미리 보여주고
    그 이상은 "+ N건 더 보기" 링크로 별도 화면 이동
  - 우측 상단에 "모두 보기" 바로가기도 추가
- `lib/screens/recent_answers_screen.dart` (신규)
  - 대시보드 최근 답변 전체 리스트 화면
  - `ReportProvider.recentAnswerReports` 를 사용해 실제 카테고리 목록에서 최근 3일 답변을 재계산한 결과를 표시
- `lib/services/local_db_service.dart`
  - Standalone `computeSummary` 의 최근 답변 쿼리에 서버와 동일한 3일 윈도우 필터 추가,
    한도를 10 → 200 으로 상향
- `services/data_service.py` (서버 프로젝트)
  - `recent_answers[:20]` → `[:200]` 로 한도 상향
  - 대시보드 `recent_answers` / `watchlist` 항목에 `category` 필드 부여 (`traffic`/`parking`/`other`)
  - `get_duplicate_records`, `get_all_watchlist` 도 행마다 `category` 라벨 부여
- `lib/models/report.dart`
  - `Report.category` 필드 추가, `Report.fromJson` 에서 `category` JSON 키 읽기
- `lib/services/local_db_service.dart`
  - `_rowToReport`, `_rowToReportWithCounts` 에서 `category` 컬럼을 Report 로 매핑
- `lib/providers/report_provider.dart`
  - `findCategory(report)` / `categoryToTabIndex(category)` 헬퍼 추가
    (Report.category 우선, 없으면 현재 로드된 카테고리 리스트에서 검색)
  - `ensureCategoryReportsLoaded()` / `recentAnswerReports` / `refreshSummaryAndRecentAnswers()` 추가
  - 최근 답변 화면은 summary 축약본이 아니라 실제 traffic/parking/other 목록에서 최근 3일 답변을 다시 계산해 사용
- `lib/widgets/report_detail_sheet.dart`
  - 차량번호 / 위반장소 / 위반법규 / 담당자 4개 필드를 클릭 가능한 링크로 변경
  - 탭 시 시트를 닫고 신고 내역 화면으로 이동, 동시에 해당 신고 카테고리 탭과 일치하는
    `ReportFilter` (carNumber / location / law / manager) 를 적용
  - 이동 전 `ensureCategoryReportsLoaded()` 를 통해 카테고리 재확인, 끝까지 못 찾으면 잘못된 기본 탭으로 보내지 않고 SnackBar 로 중단
- `web/templates/base.html` (서버 프로젝트)
  - `linkField` 헬퍼 추가, 모달 상세에서 위 4개 필드를 카테고리별 데이터 페이지로 이동하는
    `<a>` 링크로 렌더링
  - 행 데이터의 `category` 필드를 우선 사용하고, 없으면 현재 URL 의 `/data/<cat>` 로 추정
- `web/templates/data_table.html` (서버 프로젝트)
  - URL 쿼리 `car`, `law`, `location` 파라미터를 받아 상세 검색 입력에 자동 채우고
    `qAgency || qPerson || qCar || qLaw || qLocation` 일 때 자동 검색 트리거
- `lib/widgets/selection_action_bar.dart`
  - 별점 batch 처리(`_rate`)를 fire-and-forget 으로 변경
  - 시작 즉시 SnackBar 로 안내하고 선택 모드를 해제. 액션 바 전체가 스피너로 잠기는
    문제 해결 (FGS keep-alive 는 RatingService 내부 acquireFgs/releaseFgs 로 그대로 유지)
  - 결과는 알림 (rating_result) + 히스토리 + 완료 SnackBar 로만 통지
  - `dart:async` 의 `unawaited` 사용
- `lib/services/api_service.dart`
  - 카테고리별 목록 API 응답에 `category` 가 빠져 있으면 요청한 카테고리(`traffic`/`parking`/`other`)를 보강
- `lib/models/rating_batch_result.dart`
  - 별점 batch 결과 히스토리 직렬화에 `category` 저장 추가

비고:
- Standalone DB(스키마 v4) 는 이미 `category` 컬럼을 갖고 있어 모바일은 추가 마이그레이션
  없이 바로 활용 가능
- Client(server) 모드는 신규로 응답에 `category` 키가 들어오지만 기존 모바일 빌드는
  무시하므로 호환성 영향 없음

### Android 15 edge-to-edge 공식 경로 전환

상태: 완료

변경:
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - `FlutterActivity` → `FlutterFragmentActivity` 로 전환
  - 수동 `WindowCompat.setDecorFitsSystemWindows(false)` 호출 제거
  - AndroidX `enableEdgeToEdge()` 를 적용해 Android 15+ 기본 edge-to-edge 와
    하위 버전 동작을 같은 경로로 맞춤

비고:
- 앱 코드에서 직접 쓰던 수동 edge-to-edge 진입점은 제거했다. 이후 Play Console 에
  경고가 남는다면 Flutter/AndroidX 내부 호출 여부를 추가 점검해야 한다.

## 2026-05-04
- '신고리스트'탭을 '신고내역'탭으로 변경(줄바꿈 이슈)

## 2026-05-03
변경:
- 플레이스토어 심사 결과에 따라 아이콘 변경함

## 2026-05-02

### 통계 드릴다운을 신고리스트 상세검색 기반으로 전환 + 위반법규 단일선택 보강

상태: 완료

변경:
- `lib/screens/statistics_screen.dart`
  - 통계 행 탭 시 기존 `FilteredListScreen` 대신 신고리스트 화면을 열도록 변경
  - 기관/담당자/연도/위반법규 필터를 `ReportFilter`에 주입하고 카테고리에 맞는 탭으로 진입
  - 통계의 `법규 없음(__없음__)` 상태도 신고리스트 필터로 그대로 전달
- `lib/screens/report_list_screen.dart`
  - 초기 탭 인덱스 지정 지원 추가
  - 통계/검색에서 넘어온 활성 필터를 상단 Chip으로 표시
- `lib/providers/report_provider.dart`
  - 위반법규 빈 값 전용 sentinel `kEmptyLawFilterValue` 추가
  - 로드된 교통/주정차/기타 신고 데이터에서 유효한 위반법규 목록을 수집하고, 빈 값 신고가 있으면 `없음` 옵션도 포함
  - 위반법규 필터를 자유입력 부분검색이 아닌 단일 선택 exact match / `없음` 매칭으로 변경
- `lib/widgets/search_filter_sheet.dart`
  - 위반법규 입력을 데이터 기반 단일선택 드롭다운으로 변경
  - 드롭다운의 `__없음__` 내부값을 사용자에게는 `없음`으로 표시
- `lib/screens/search_screen.dart`
  - 공용 상세검색 시트가 주정차 데이터까지 함께 로드/검색하도록 보강

비고:
- Client 모드는 이미 `/api/v1/reports/{category}` 원본 목록을 받아 모바일에서 필터링하는 구조라 서버 API 추가는 불필요

### Play Console 정부 정보 출처/비공식 고지 추가

상태: 완료

변경:
- `lib/widgets/report_detail_sheet.dart`
  - `안전신문고 앱에서 보기` 버튼 아래에 안전신문고 공식 출처 URL(`https://www.safetyreport.go.kr/`) 표시
  - `안전신문고 공식 사이트 열기` 외부 링크 버튼 추가
  - 비공식 앱 / 비정부 대표 아님 / 원문은 공식 서비스에서 확인해야 함 안내 문구 추가
- `lib/screens/settings_screen.dart`
  - `앱 정보` 카드에 동일한 공식 출처 URL, 외부 링크 버튼, 비공식 고지 문구 추가
- `CHANGELOG.md`, `CLAUDE.md`
  - 검색/통계 드릴다운 변경 및 Play Console 대응 지점 기록

### Standalone 모드 다중 선택 동기화 버튼 추가

상태: 완료

변경:
- `lib/widgets/selection_action_bar.dart`
  - Standalone 모드에서 여러 신고를 선택했을 때 Client 모드의 '크롤링' 버튼과 동일한 위치에 '동기화' 버튼 추가
  - 선택된 신고번호들을 `standalone_pending_reports` 큐에 추가하고 `StandaloneAutoSyncService.drainIfPending()`을 호출하여 개별 동기화 처리
  - `SharedPreferences` 누락된 임포트 추가 및 `withOpacity` deprecation 경고 수정

### Client 별점 주기 로그 파싱 버그 수정

상태: 완료

원인:
- 서버 로그 포맷이 `[timestamp][level|file] >> - [SPP-...] N점 별점 부여 성공 (API)` 인데,
  모바일의 regex `\[(.+?)\]`가 첫 번째 브래킷인 타임스탬프를 캡처해 신고번호 매칭 실패
- 성공 로그가 기록되어도 모바일에서 "서버 로그에서 결과를 확인하지 못했습니다." 표시

수정:
- `lib/services/rating_service.dart`
  - 4개 regex의 캡처 그룹을 `(.+?)` → `(SPP-.+?)`로 변경
  - 타임스탬프 브래킷을 건너뛰고 신고번호만 정확히 캡처

### 만족도 조사 여부 검색 필터 추가

상태: 완료

변경:
- 서버 `web/templates/data_table.html`
  - 상세 검색 사이드바의 별점사유 뒤에 `만족도 조사 여부` 드롭다운 추가
  - 옵션: 전체 / 참여 완료 / 참여 가능 (단일 선택)
  - JS 필터 로직에 `만족도조사여부` 필드 검사 추가
- 모바일 `lib/providers/report_provider.dart`
  - `ReportFilter`에 `pollStatus` 필드 추가
  - `_applyFilter()`에 `pollStatus` 필터 로직 반영
  - `activeLabels`에 만족도 필터 표시 추가
- 모바일 `lib/widgets/search_filter_sheet.dart`
  - 별점사유 아래에 `만족도 조사 여부` 단일선택 드롭다운 UI 추가
  - `_singleSelectDropdown` 위젯 메서드 추가

## 2026-05-01

### Client 별점 요청 302 대응

상태: 완료

변경:
- `lib/services/api_service.dart`
  - Client 모드 별점 시작 요청 경로를 웹 세션 기반 `/rating/start`에서 API 키 기반 `/api/v1/rating/start`로 변경
  - 서버가 예전 코드라 `302 /login`을 돌려줄 때 원인 파악이 쉬운 안내 메시지를 반환하도록 보강
- `CLAUDE.md`
  - Client 별점 흐름 설명을 새 API 경로 기준으로 수정

### 알림 탭 별점 주기 추가 + 다중 선택 배치 처리

상태: 완료

변경:
- `lib/widgets/selection_action_bar.dart`
  - 신고리스트 다중 선택 액션에 `별점 주기` 버튼 추가
  - 1~5점 선택 다이얼로그 추가
  - 완료 후 성공/스킵/실패 집계 푸시 알림 전송
- `lib/services/rating_service.dart`
  - Client(server) / Standalone 공통 별점 배치 처리 서비스 추가
  - 서버앱 참조 기준으로 별점 불가 신고(`참여 완료`, `참여 불가`, `답변 대기`, `취하/처리중/진행*`) 자동 스킵
  - Client는 서버 `/rating/start` 요청 후 `current_rating.log` 폴링으로 완료/실패 추적
  - Standalone은 안전신문고 만족도 API에 직접 POST 하고 로컬 DB 별점 상태 즉시 반영
  - 두 모드 모두 작업 중 `SyncForegroundService`를 재사용해 프로세스 보존
- `lib/models/rating_batch_result.dart`
  - 별점 배치 결과/개별 신고 결과 모델 추가
- `lib/models/notification_item.dart`
  - 알림 kind(`crawl` / `report` / `rating`) 구분 추가
- `lib/providers/notification_history_provider.dart`
  - 별점 배치 결과를 알림 히스토리에 저장하는 로직 추가
  - 알림 탭 내부 서브탭 선호 인덱스 상태 추가
- `lib/screens/notifications_screen.dart`
  - 알림 탭을 `크롤링 현황 / 신고 결과 / 별점 주기` 3탭으로 확장
  - 별점 주기 결과 카드, 성공/스킵/실패 요약, 실패 신고번호 표시 추가
  - 항목 탭 시 신고 상세로 이동 가능한 report 카드형 상세 시트 추가
- `lib/services/api_service.dart`
  - Client 모드용 서버 별점 시작 요청 / 서버 current_rating.log 조회 메서드 추가
- `lib/services/standalone_api_service.dart`
  - Standalone 모드용 만족도 POST / 상태 조회 / 워밍업 메서드 추가
- `lib/services/local_db_service.dart`
  - 신고번호 기준 만족도조사여부 / 별점 / 별점사유 갱신 메서드 추가
- `lib/providers/report_provider.dart`
  - 별점 배치 실행 후 전체 데이터 새로고침 + 최신 report 데이터로 결과 보강하는 메서드 추가
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - 로컬 알림에 `nav_subtab` / `event_type` payload 지원 추가
  - 푸시 알림 탭 시 `알림 > 별점 주기` 또는 `알림 > 신고 결과`로 직접 진입 가능하게 수정
- `lib/main.dart`
  - native intent의 `sub_tab` 수신 및 신고 결과 도착 시 알림 서브탭 자동 이동 추가
- `test/widget_test.dart`
  - 기본 샘플 카운터 테스트를 현재 앱 구조와 충돌 없는 placeholder 테스트로 교체

### 신고 카드 공용화 + 문서 git 반영

상태: 완료

변경:
- `lib/widgets/report_list_card.dart`
  - 신고 카드 공용 UI 추가: 상태칩, 선택 강조, 차량번호 배지, 메타 행 렌더링 통합
- `lib/screens/report_list_screen.dart`
  - 일반 신고 / 중복차량 카드가 공용 카드 위젯을 사용하도록 리팩토링
  - 중복차량 횟수 배지는 화면 전용 `headerSuffix`로 분리
- `lib/screens/search_screen.dart`
  - 검색 결과 카드 중복 UI 제거, 공용 카드 위젯 사용
- `lib/screens/filtered_list_screen.dart`
  - 필터 결과 카드 중복 UI 제거, 공용 카드 위젯 사용
- `CLAUDE.md`
  - `.gitignore` 해제 전제로 git 추적 문서 기준 설명으로 갱신
  - 프로젝트 루트 구조를 git 추적 항목 기준으로 정리
- `.gitignore`
  - `CLAUDE.md` ignore 규칙 제거

### 상세검색 다중선택 키보드 처리 보정

상태: 완료

변경:
- `lib/widgets/search_filter_sheet.dart`
  - Enter/숫자패드 Enter 입력 시 먼저 `onTap()`을 실행하도록 조정
  - 이미 선택된 항목이 아니어도 키보드로 선택 토글 + 제출이 일관되게 동작하도록 수정

### 신고리스트 상세검색 AND/OR + 다중선택 공통 적용

상태: 완료

변경:
- `lib/providers/report_provider.dart`
  - `ReportFilter`의 `rating` / `status` 단일값을 `ratings` / `statuses` 다중값으로 확장
  - `_contains()`에 `&` = AND, `,` = OR 검색 문법 적용
  - `availableStatuses` 추가: 현재 로드된 신고 목록에서 distinct 처리상태를 추출
  - `ReportProvider._applyFilter()`가 목록 공통 필터이므로 Client(server) 모드와 Standalone 모드에 동시에 반영
- `lib/widgets/search_filter_sheet.dart`
  - 상세검색 상단에 `&` / `,` 안내 문구 추가
  - `처리상태`, `별점`을 다중선택 드롭다운 UI로 변경
  - 선택된 항목 우측에 초록 `v` 표시
  - `report_list_screen.dart`, `search_screen.dart`가 공유하는 필터 시트에 동일 동작 적용

## 2026-05-02

### 문서 역할 분리 정리

상태: 완료

변경:
- `CLAUDE.md`
  - 세션별 작업 이력 섹션을 제거하고 구조/작동 방식/운영 메모만 남기도록 정리
  - 작업/버그/세션 기록은 `CHANGELOG.md`에만 남긴다는 규칙을 상단에 명시
- `CHANGELOG.md`
  - 기존 `CLAUDE.md`에 남아 있던 작업 이력 잔재는 날짜별 변경 항목 기준으로 이 파일에서 관리하도록 정리

### 신고현황 탭 + sunwi 이식

변경:
- 하단 네비게이션에 `신고현황` 탭 추가. 위치는 `통계`와 `알림` 사이.
- 새 `SunwiScreen` / `SunwiService` / `SunwiPayload` 모델 추가.
- Client 모드에서는 서버 `/api/v1/sunwi/payload` 데이터를 그대로 표시.
- Standalone 모드에서는 안전신문고 통계 API를 직접 순회 호출해 전국 Top5 데이터를 생성.
- 화면 상단에 `ALL CSV 생성`, `TOP5 CSV 생성` 버튼 추가.
- Standalone CSV는 `Documents/mysafetyreport/sunwi/`에 `sunwi_category_all_latest.csv`, `sunwi_category_top5_latest.csv`로 저장.
- 새 탭 삽입에 맞춰 알림/파일/동기화 탭 인덱스를 한 칸씩 뒤로 조정하고, Android `NotificationService` / `WsService` / Flutter `showNotification` 연동 인덱스도 함께 수정.

### DB import 안정화

변경:
- 외부 `.db` import 전에 임시 staging/snapshot을 만들어 `-wal`/`-shm`를 함께 병합하는 경로 추가.
- `LocalDbService.detectDbKind`, `importFromServerDb`, `replaceFromBackup`가 모두 같은 snapshot 규칙을 사용하도록 통일.
- Setup/복원 화면의 파일 선택을 다중 선택 허용으로 바꿔 `.db`와 `-wal`/`-shm`를 함께 staging 가능하게 보강.
- Standalone 복원도 파일 형식을 자동 감지해 모바일 백업은 그대로 복원, 서버 DB는 변환 import 하도록 수정.

### 신고현황/감시목록/파일 탭 사용성 보정

상태: 완료

변경:
- `lib/screens/sunwi_screen.dart`
  - 탭 전환 nonce가 들어와도 모드별 마지막 수집 시각 기준 3시간 TTL 안에서는 캐시를 재사용하고, 3시간 경과 시에만 재동기화하도록 변경
  - 사용자가 직접 새로고침할 때만 TTL을 무시하는 강제 재수집 경로 추가
  - 서버 대시보드와 동일하게 대분류/소분류를 5초마다 자동 전환하고, 수동 이동 시 타이머를 리셋하도록 보강
- `lib/screens/watchlist_screen.dart`
  - 빈 감시목록 안내 문구에 서버 추가 외에도 신고리스트 다중 선택 모드에서 바로 추가할 수 있다는 안내 반영
- `lib/screens/file_browser_screen.dart`
  - Standalone 파일 탭이 `mysafetyreport` 하위 폴더도 표시하도록 로컬 브라우저를 파일 전용 목록에서 폴더 탐색형으로 확장
  - 현재 위치 카드와 상위 폴더 이동 항목을 추가해 `sunwi/` 하위 CSV 폴더에 앱 안에서 직접 진입 가능하게 수정
- `CLAUDE.md`
  - `sunwi` 3시간 TTL/5초 자동 전환과 standalone 파일 탭 하위 폴더 탐색 규칙을 구조 문서에 반영

### Play Console demo 로그인 완화

상태: 완료

변경:
- `lib/services/local_db_service.dart`
  - Play review demo 판정 로직을 공용 helper로 추출
  - demo 계정을 `demo / demo / demo`뿐 아니라 `demo / demo` + 휴대폰번호 공란도 허용하도록 완화
- `lib/screens/setup_screen.dart`
  - 초기 Standalone 로그인에서 휴대폰번호가 비어 있어도 `demo / demo`로 심사용 데모 진입 가능하게 수정
  - 데모 모드 저장 시 내부 phone 값은 기존과 동일하게 `demo`로 유지
- `lib/screens/settings_screen.dart`
  - 재로그인 / 휴대폰번호 갱신 다이얼로그도 같은 demo 판정 규칙을 사용하도록 통일
- `CLAUDE.md`
  - Play Console 심사 계정 안내를 `phone blank allowed` 기준으로 갱신

### 문서 정리

상태: 완료

변경:
- `CLAUDE.md`
  - `ReportProvider` / `search_filter_sheet` 설명에 새 검색 규칙 반영
  - 신고리스트 상세검색이 Client(server) / Standalone 공통 로직임을 명시
- `CHANGELOG.md`
  - 모바일 레포 최초 생성
  - 기존 `CLAUDE.md`의 주요 작업 이력을 이 파일로 이관

## 2026-04-27

### 버그 수정 묶음

변경:
- Client 파싱 강건화: 서버가 `''`를 보내는 경우도 `Report.fromJson`, `AgencyStats.fromJson`이 안전하게 파싱하도록 보강
- Standalone DB 백업 일관성: WAL 환경에서 최신 별점/사유 누락이 없도록 `LocalDbService.exportBackup()`에서 flush 후 복사
- Client → Standalone 전환 시 최신 백업 자동 탐색을 제거하고 `.db` 직접 선택 방식으로 변경
- 파일 브라우저 정렬을 standalone 로컬 파일 / client 서버 파일 모두 파일명 내림차순으로 통일
- Standalone 외부 저장소 파일은 temp 디렉토리 복사 후 열도록 변경
- Client → Standalone 전환 시 남아 있던 `WsService`를 즉시 정지하도록 보강

### Play Console 심사용 데모 모드

변경:
- `demo / demo / demo` 자격증명으로 실제 로그인 없이 예시 신고 3건 시드 후 진입
- `ReportProvider.isStandaloneDemo` 추가: keep-alive, pending queue drain, 실제 sync, 자동 재로그인 차단
- 동기화 화면에서 데모 안내 카드 표시, 동기화/재동기화 버튼 비활성화
- 재로그인 다이얼로그에서도 동일한 데모 자격증명으로 재진입 가능

### Android 빌드/릴리즈 정리

변경:
- `.github/workflows/build-apk.yml` 유지: VERSION → `pubspec.yaml` 동기화 후 Docker 기반 APK/AAB 빌드
- 로컬용 `build_android_release.sh` 추가: CI와 같은 경로/키스토어 마운트로 release APK/AAB 동시 빌드
- `build_test_apk.sh`는 debug/간이 release 용으로 유지

## 2026-04 기존 이관 기록

- Standalone 모드 신규 구현: 안전신문고 직접 로그인(RSA + OAuth), 자동 재로그인, sqflite 로컬 DB, 증분 sync, 카드 시트
- Kotlin `NotificationService`가 SPP 신고번호를 큐에 적재하고 Flutter drain으로 넘기는 알림 큐 인프라 구축
- Legacy SharedPreferences 손상 이슈를 CSV 큐 형식과 `MainActivity` 마이그레이션으로 해결
- Standalone `refreshAll()`의 `Future.wait`를 순차 await로 바꿔 sqflite 단일 connection 충돌 완화
- `CrawlScreen`이 sync/log 이벤트를 항상 구독하도록 조정해 실행 상태 가시성 개선
- 사용자 용어를 `단건`에서 `개별`로 통일 (`ChangeType.individualConfirm` 등)
- 중복차량 정렬을 서버와 동일한 `max(신고번호) DESC → 차량번호 ASC → 신고번호 DESC`로 맞춤
- Standalone 전용 그린 테마 도입: `appMode`에 따라 MaterialApp 시드 컬러 동적 전환
- Android 15 edge-to-edge 대응
- xlsx 열기 실패 시 `share_plus` 공유 sheet로 fallback
- `SyncEngine.emitDone`로 개별 sync 완료 신호를 명시해 `_isRunning` 고착 버그 수정
- `SyncForegroundService`로 drain/sync 중 프로세스 보호
- drain 시 per-item 제거 방식으로 바꿔 앱 종료 시 큐 항목 영구 손실 방지
- 사용자 요청에 맞춰 개별 fetch + 증분 fallback 1회 구조로 단순화
- dead `standalone_sync_pending` 제거, ChangeType 상수화, `_drainAndRefresh()` 추출
- 설정 화면에 GitHub issues 버그 제보 버튼 추가
- standalone → client 자동 백업, client → standalone 3-way 선택, 서버 DB → 모바일 DB 변환 경로 추가
- standalone 로그인 Step 3과 Client `downloadDb`에 retry/timeout 매트릭스 보강
- `main` 브랜치 병합으로 1.0.7+11 누적 변경, 권한/개인정보처리방침 정리 반영
