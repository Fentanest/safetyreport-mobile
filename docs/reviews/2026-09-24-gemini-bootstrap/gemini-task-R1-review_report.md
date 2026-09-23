# UI 리뉴얼 시범 구현 독립 검수 결과

## 치명/중요/경미 발견

### 1. 기능 보존 (Feature Preservation)
- **경미** `dashboard_screen.dart`: 요약 카드(대시보드)가 7개 그대로 유지되었고, 필터링 후 탭으로 이동하는 콜백(FilteredListScreen)이 잘 보존되었습니다 (`lib/screens/dashboard_screen.dart:200-264`). 감시 목록과 최근 답변 완료 항목들도 기존 로직 그대로 렌더링되며, 클릭 시 상세 시트가 올라오는 기능이 보존되었습니다.
- **중요** `report_list_screen.dart`: 목록 탭(교통위반, 주정차, 기타위반, 중복차량) 및 SelectionActionBar 가 정상적으로 보존되었습니다.
- **경미** `server_palette.dart`: 상태 색상 및 모드별(Client/Standalone) 표시는 `ModeBadge` 등으로 분리되었으나 기존 역할을 대체하여 기능이 유지되고 있습니다.
- **경미** `search_screen.dart` 등 진입점이 없는 래퍼 화면들은 UI 리뉴얼에서 무시되고 정상 작동합니다.

### 2. 통계 의미 (Statistics Semantics)
- **중요** `LocalDbService.computeStatsOverview` (모바일)와 `report_stats_service.py` (서버): 
  - 모바일 측 `lib/services/local_db_service.dart:1049-1100` 부근과 테스트 `test/services/stats_overview_test.dart`를 확인했습니다.
  - 서버 측 `services/report_stats_service.py:739` `_summarize_overview_frame` 와 테스트 `tests/test_report_stats_service.py`를 확인했습니다.
  - 양쪽 모두 S-01, S-02 스펙을 만족합니다. (1) 유효 표본(차이 >= 0)에 대해서만 평균 처리일을 계산하며, (2) 소수점 1자리로 반올림하고, (3) `avg_days_count` 를 반환하여 분모(표본수)를 제공합니다.
  - 양쪽 모두 `monthly_reported` 와 `monthly_answered` 로 시리즈를 분리하여 월별 추이를 생성합니다.
  - 서버 refactoring 이 `get_agency_stats` 기존 동작을 유지하는지: 필터 쿼리 `_apply_stats_row_filters`와 `_apply_stats_law_filter`를 모듈화하여 `get_stats_overview`와 공유함으로써 동일한 조건에서 집계됨을 확인했습니다.

### 3. 시각·접근성 (Visual & Accessibility)
- **중요** 색상 대비(WCAG): `flutter test` 중 접근성 Guideline API 테스트(`androidTapTargetGuideline`, `textContrastGuideline`)가 통과했습니다 (test logs 참조). 알파 블렌딩 오류는 `Color.alphaBlend` 사용으로 교체되었습니다. `report_navigation_regression_test.dart`에서 탭바 대비 검증이 제대로 수행되고 있습니다.
- **중요** ReportListCard overflow 결함 해소: `test/widgets/report_list_card_test.dart` 등에서 360dp, 1.0/2.0 text scale factor 에서 RenderFlex overflow(기존 48px/334px)가 발생하지 않도록 수정된 것을 테스트 코드를 통해 확인했습니다.
- **범위 밖**: 이번 작업에서 테마·신고 카드·대시보드·탭·통계 요약 범위에 해당하지 않는 화면(예: 파일 브라우저 등)은 여전히 기존의 하드코딩된 색상 및 구조를 따르며, 추후 작업으로 남겨져 있습니다.

### 4. 테스트 (Tests)
- **치명** `flutter test` 병렬 실행 시 SQLite DB lock 에러: 모바일 `flutter test` 시 `SqfliteFfiException (disk I/O error)` 및 `attempt to write a readonly database` 오류가 간헐적으로 발생합니다 (`test/services/local_db_service_regression_test.dart` 및 `test/services/stats_overview_test.dart`). 이는 두 테스트가 `sqflite_common_ffi` 의 동일한 DB 파일 경로를 사용하여 쓰기를 시도할 때 충돌하기 때문입니다. 각각 순차 실행 시에는 모두 통과합니다. `inMemoryDatabasePath` 를 활용하거나 랜덤 DB 이름을 사용하여 병렬 실행 시 충돌을 막도록 개선할 것을 권고합니다.
- `flutter analyze` 실행 결과 baseline과 동일하게 0 error, 2 warning 으로 유지되었습니다 (통과).

## 범위 밖 관찰
- D-01 (다크=슬레이트), D-02 (모바일 우선 상태색 변경), D-03 (Primary 통합 및 별도 모드 배지), D-04 (기본 글꼴 유지) 등의 사용자 결정이 모두 반영되었습니다.

## 실행 증거
- `flutter analyze`: 종료코드 1 (0 error, 2 warning - `setup_screen.dart` 의 `unused_element_parameter`) - Baseline 과 일치.
- `flutter test` (모바일): 병렬 실행 시 SQLite I/O 에러 발생(코드 1). 단독 실행 시 PASS.
- 서버 Python 테스트: `PYTHONPATH=. python -m unittest tests/test_report_stats_service.py` 3 tests ran, 종료코드 0 (PASS).
- `git status --short`:
  - 모바일: `CLAUDE.md`, `lib/main.dart`, `dashboard_screen.dart`, `report_list_screen.dart`, `statistics_screen.dart` 등 수정. 신규 테마 및 위젯 파일, 테스트 코드 생성.
  - 서버: `data_service.py`, `report_stats_service.py`, `api_route.py` 수정. `test_report_stats_service.py` 생성.
