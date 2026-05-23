# 2026-05-23 별점 관리 탭 리뷰

## 범위
- `lib/screens/report_management_screen.dart`
- `lib/screens/rating_management_panel.dart`
- `lib/providers/report_provider.dart`
- `lib/services/rating_service.dart`
- `lib/widgets/selection_action_bar.dart`
- 서버 기준 비교: `../safetyreport/services/report_query_service.py`

## 확인한 검증
- `dart analyze lib/services/rating_service.dart lib/providers/report_provider.dart lib/screens/report_management_screen.dart lib/screens/rating_management_panel.dart test/services/rating_service_test.dart`
- `flutter test test/services/rating_service_test.dart`

정적 분석과 추가한 단위 테스트는 통과했다. 다만 아래 항목들은 컴파일/테스트만으로는 잘 드러나지 않는 런타임 동작 및 서버 기준 불일치 이슈다.

## 주요 발견 사항

### 1. 서버 기준과 다른 “별점 가능” 판정으로 일부 신고가 누락될 수 있음
- 심각도: 높음
- 근거:
  - 모바일은 `RatingService.isListEligible()` 에서 `pollStatus == '참여 가능'` 을 강제한다.  
    `lib/services/rating_service.dart:96`
  - 별점 탭 목록도 이 조건을 그대로 사용한다.  
    `lib/providers/report_provider.dart:342`
  - 반면 서버앱은 `만족도조사여부 not in ['참여 완료', '참여 불가']` 와 `처리상태 not in [...]` 만 본다. 즉 `pollStatus` 가 빈 값이거나 덜 정규화된 행도 포함될 수 있다.  
    `../safetyreport/services/report_query_service.py:304`
- 영향:
  - 사용자가 요청한 “서버앱 참조” 기준과 1:1로 맞지 않는다.
  - 서버 웹의 별점 대상 목록에는 보이는데 모바일 별점 탭에는 안 보이는 신고가 생길 수 있다.
  - 특히 구버전 DB, 부분 동기화, 상태 재보강 전 레코드에서 발생할 가능성이 있다.
- 권장:
  - 모바일 목록 기준을 서버와 동일하게 맞추거나,
  - 최소한 “목록 기준”과 “실행 전 스킵 기준”을 분리해서 서버 parity 를 먼저 맞춘다.

### 2. 별점 탭에서 불가능한 필터 옵션이 그대로 노출됨
- 심각도: 보통
- 근거:
  - 별점 탭은 처음부터 `filteredRatingEligibleReports` 만 보여준다.  
    `lib/screens/rating_management_panel.dart:74`
  - 그런데 공용 `SearchFilterSheet` 는 `만족도 조사 여부` 옵션으로 `참여 완료`, `참여 가능` 을 모두 노출한다.  
    `lib/widgets/search_filter_sheet.dart:62`
  - 사용자가 별점 탭에서 `참여 완료` 를 선택하면 구조적으로 결과가 항상 0건이 된다.
- 영향:
  - 필터가 “동작은 하지만 절대 결과가 나올 수 없는” 상태를 만들 수 있다.
  - 사용자는 데이터가 없는 것인지, 필터가 모순되는 것인지 구분하기 어렵다.
- 권장:
  - 별점 탭 전용 필터 시트에서 `pollStatus` 를 숨기거나 `참여 가능` 으로 고정한다.
  - `별점 1~5점`, `참여 완료` 같이 이 탭과 상충하는 옵션은 숨기는 것이 안전하다.

### 3. 데이터가 갱신되면 선택 상태가 고아(stale) 상태로 남을 수 있음
- 심각도: 보통
- 근거:
  - 선택 모드 여부는 `_selected.isNotEmpty` 로만 판단한다.  
    `lib/screens/rating_management_panel.dart:21`
  - 실제 액션에 전달하는 리스트는 현재 메모리의 `provider.ratingEligibleReports` 와 교집합으로 다시 만든다.  
    `lib/screens/rating_management_panel.dart:76`
  - 따라서 새로고침/동기화 후 선택한 신고가 목록에서 사라지면, 화면은 여전히 선택 모드인데 실제 선택 건수는 0건이 될 수 있다.
  - 이 상태에서 하단 액션 바는 0건 기준으로 계속 열린다.  
    `lib/screens/rating_management_panel.dart:202`
    `lib/widgets/selection_action_bar.dart:37`
- 영향:
  - “0건 선택됨” 상태의 액션 바가 남을 수 있다.
  - 사용자가 별점/복사/감시 동작을 눌러도 체감상 이상 동작처럼 보일 수 있다.
- 권장:
  - 빌드 시점에 `_selected` 를 현재 데이터와 교집합으로 정리하거나,
  - `selectedReports.isEmpty` 면 자동으로 선택 모드를 종료한다.

## 리팩토링 필요 지점

### A. `ReportListScreen` 와 `RatingManagementPanel` 의 선택/리스트 로직 중복
- 중복 위치:
  - 카드 선택/해제
  - 전체 선택
  - 하단 `SelectionActionBar`
  - empty/loading/refresh 패턴
- 현재 문제:
  - 유사한 UX 버그가 두 화면에서 서로 다르게 재발할 수 있다.
  - 예를 들어 선택 상태 정리 방식이 화면마다 달라지기 쉽다.
- 권장:
  - `SelectableReportListScaffold` 같은 공용 위젯/컨트롤러로 추출
  - 입력값만 받도록 분리:
    - `title`
    - `reports`
    - `onRefresh`
    - `header`
    - `headerSuffixBuilder`

### B. 별점 가능 판정 규칙을 “목록용”과 “실행용”으로 분리 필요
- 현재 문제:
  - `RatingService.isListEligible()` 와 `ineligibleReason()` 가 사실상 같은 계약을 공유한다.
  - 하지만 서버 기준을 따르는 “목록 노출”과 실제 실행 직전 스킵 판단은 항상 같지 않을 수 있다.
- 권장:
  - 예:
    - `isRatingListCandidate(report)` : 서버 parity 우선
    - `validateRatingSubmission(report)` : 실행 가능 여부 + 메시지 반환
  - 이렇게 나누면 “목록에는 보이되 실행 직전에 안내 후 스킵” 같은 서버 동작을 더 자연스럽게 재현할 수 있다.

### C. 별점 탭 전용 필터 정책을 분리하는 것이 안전
- 현재 문제:
  - `ReportProvider.filter` 가 전역 상태라서 `신고 내역` 화면과 `별점` 탭이 같은 필터 상태를 공유한다.
  - 필터 칩이 보이긴 하지만, 사용자는 “왜 별점 탭이 갑자기 0건인지” 를 매번 추적해야 한다.
- 권장:
  - 최소안: 별점 탭 진입 시 상충 필터를 비활성화
  - 권장안: `ReportFilter` 는 유지하되, `RatingManagementPanel` 전용 visible/applicable filter schema 를 두기

### D. `ratingEligibleReports` 계산/정렬 비용을 한 곳으로 모으기
- 현재 문제:
  - `ratingEligibleReports` 와 `filteredRatingEligibleReports` 가 각각 병합/정렬 경로를 탄다.  
    `lib/providers/report_provider.dart:342`
    `lib/providers/report_provider.dart:349`
  - `RatingManagementPanel.build()` 에서도 `reports` 와 `selectedReports` 계산 시 이를 반복 참조한다.  
    `lib/screens/rating_management_panel.dart:74`
    `lib/screens/rating_management_panel.dart:76`
- 영향:
  - 데이터량이 커질수록 build 비용이 커진다.
  - 선택 상태 보정 로직을 넣을 때도 소스가 분산된다.
- 권장:
  - 병합 원본을 하나의 private helper 로 만들고,
  - 필요하면 provider 내부에서 한 번만 정렬한 결과를 재사용한다.

## 추천 작업 순서
1. 서버 `get_unrated_records` 와 모바일 별점 목록 기준을 맞춘다.
2. 별점 탭 전용 필터 정책을 분리하거나, 최소한 모순 옵션을 숨긴다.
3. 선택 상태를 현재 목록과 동기화하는 정리 로직을 넣는다.
4. `ReportListScreen` / `RatingManagementPanel` 공용 선택 리스트 scaffold 를 추출한다.

## 메모
- 현재 추가된 테스트는 `RatingService` 의 기본 판정만 검증한다.
- 서버 parity 회귀를 막으려면 다음 케이스도 테스트에 추가하는 것이 좋다.
  - `pollStatus == ''` 이고 `처리상태 == 답변완료`
  - `pollStatus == 참여 가능` 이지만 `처리상태 == 검토중`
  - 목록에는 보이지만 실행 시 스킵되는 케이스의 기대 동작
