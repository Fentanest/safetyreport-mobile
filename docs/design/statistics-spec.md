# 통계 개선 사양 (statistics-spec)

상태: **결정 완료(S-09 제외)·일부 구현(2026-09-24)** — S-02·월별 추이 구현, S-07 해소, S-01/S-03~S-06/S-08 결정 반영 예정. 작성 2026-09-24, base `c64be69a`.
범위: 승인된 개선 방향(통계 정보구조·시각화·월별 신고현황)의 지표 의미·분모·날짜 기준·결측 처리를 먼저 고정한다.
이 문서는 기존 기능 보존과 별개인 **개선 사양**이다. 기존 통계표·drilldown 동작은 `feature-matrix.csv` 에서 보존 대상으로 관리한다.

## 1. 현재 동작 (코드 근거)

| 항목 | Client | Standalone | 근거 |
|---|---|---|---|
| 데이터 원천 | `GET /api/v1/stats?year=&law=` (서버 집계) | `LocalDbService.computeStats()` (로컬 SQLite) | `statistics_screen.dart:63-76`, `api_service.dart:384-391` |
| 연도 필터 | 서버 | `신고일 LIKE 'YYYY%'` | `local_db_service.dart:860-862` |
| 위반법규 필터 | 서버 | exact match, `__없음__` = NULL/빈값 | `local_db_service.dart:864-871` |
| 취하 제외 | 서버 설정 `exclude_withdraw` | `처리상태 != '취하'` (앱 설정, 기본 true) | `report_provider.dart:656,665`, `local_db_service.dart:871-873` |
| 대표건 projection | **요청에 `dedupe` 미전달** → 서버 기본값 의존 | `useRepresentativeRecords` (기본 true) | `api_service.dart:384-391`, 서버 `api_route.py:91` |
| 집계 단위 | 카테고리(traffic/parking/other) × 기관/담당자 × 경찰/비경찰 | 동일 구조로 로컬 계산 | `models/agency_stats.dart`, `local_db_service.dart:1400-1500` |
| 행 지표 | total, 과태료/경고·범칙금/불수용/미확인 건수와 %, 과태료 합계, 평균 처리일, 평균 별점(+표본수) | 동일 | `agency_stats.dart:21-37` |
| 차트 | 통계 화면에는 없음 (fl_chart 는 대시보드에서만 사용) | 동일 | `grep fl_chart lib` → `dashboard_screen.dart:5` |
| drilldown | 행 탭 → `ReportFilter`(기관/담당자/연도/법규) 설정 후 `ReportListScreen` | 동일 | `statistics_screen.dart:665-680` |

## 2. 현재 코드에서 발견한 의미상 문제 (수정 전 결정 필요)

| ID | 문제 | 영향 | 근거 |
|---|---|---|---|
| S-01 | 평균 처리일: 서버는 음수 일수 제외 + 소수 1자리, Standalone 은 음수 포함·반올림 없음 | 모드별 값이 다를 수 있음 | 서버 `report_stats_service.py:501-508`, 모바일 `_AgencyAgg.add/toJson` |
| S-02 | `avg_days` 표본수(유효 답변 건수)가 payload 에 없음 | 기관 평균을 합쳐 전체 평균을 만들 수 없음. 카드용 "전체 평균 처리기간"을 정확히 못 냄 | `agency_stats.dart:24`, `_AgencyAgg.toJson` |
| S-03 | Standalone 취하 제외 SQL 이 `처리상태` NULL 행도 제외 | 처리상태 결측 행이 조용히 빠짐 | `local_db_service.dart:871-873` |
| S-04 | "미확인" 정의가 두 개: 대시보드는 교통만 `범칙금_과태료 == '미확인'`, 통계표는 전 카테고리에서 과태료·경고·범칙금·불수용/기타가 아닌 모든 행(처리중 포함) | 같은 이름, 다른 분모 | `local_db_service.dart:763-767` vs `_AgencyAgg.add` |
| S-05 | 과태료 합계에서 금액 미확인과 0원을 구분하지 않음 (`extractFineAmount` 실패 = 0) | "총 과태료"가 과소 표시될 수 있음 | `_AgencyAgg.add` |
| S-06 | 중복차량 목록은 대표건 projection 을 적용하지 않음 | 다른 화면과 건수 기준이 다름 | `local_db_service.dart:1537-1570` |
| S-07 | ~~Client 통계 요청에 `dedupe` 가 없어 앱 설정과 서버 집계 기준이 다를 수 있음~~ **해소(문제 아님)**: 파라미터가 없으면 서버가 자체 `use_representative_records` 로 기본값을 정하고, Client 앱의 대표건 설정 자체가 그 서버 설정을 읽고 바꾼다 | — | 서버 `web/routers/filters.py:6-13`, 모바일 `report_provider.dart:665-667` |
| S-08 | **연도 필터 기준 컬럼이 모드마다 다름**: 서버 `/stats`(및 새 `/stats/overview`)는 **답변일**, Standalone 은 **신고일**. 연도 목록도 서버는 답변일에서 뽑음 | 같은 "2026" 이 모드마다 다른 신고 집합 | 서버 `report_stats_service.py` `_apply_stats_row_filters`·`_load_available_years`, 모바일 `local_db_service.dart` `_queryStatsRows` |
| S-09 | 위반법규 필터: 서버는 부분 일치(`contains`), Standalone 은 완전 일치 | 비슷한 이름의 법규가 서버에서만 섞일 수 있음 | 서버 `_apply_stats_law_filter`, 모바일 `_queryStatsRows` |

S-02 외에는 코드를 수정하지 않았다. 새 요약은 각 모드의 기존 연도·법규 필터를 그대로 따르며, 화면 각주에 연도 기준 컬럼(`year_basis`)을 표시한다(S-08 결정 전까지 모드 차이를 숨기지 않기 위함).

## 3. 개선 정보구조 (제안)

1. **요약** — 카드: 총 신고, 답변 완료, 처리중, 보완요청, 수용/일부수용/불수용·기타, 취하(제외 설정 시 숨김), 평균 처리기간.
2. **월별 추이** — 두 개의 시리즈를 **따로** 둔다: 월별 신고(신고일 기준), 월별 답변(답변일 기준). 차트 제목에 기준 날짜를 표시한다.
3. **처리 결과 비율** — 도넛: 수용/일부수용/불수용·기타/처리중·보완요청/취하. 분모를 범례에 표시한다.
4. **기관·담당자 비교** — 기존 `AgencyStatRow` 를 가로 막대(Top N)로 요약. 기존 표는 유지.
5. **상세표** — 기존 기관/담당자 표를 보존하고, 행 탭 drilldown 도 그대로 유지한다.

시안의 "전국 신고현황(Sunwi)" 수치는 **내 신고 통계와 섞지 않는다.** Sunwi 는 대시보드 하단 섹션 그대로 둔다.

## 4. 지표 정의

| 지표 | 정의 | 분모 | 날짜 기준 | 결측/예외 |
|---|---|---|---|---|
| 총 신고 | 필터 통과 행 수 | — | 연도 = 신고일 | 신고일 없으면 연도 필터 선택 시 제외, "전체"에는 포함 |
| 답변 완료 | 처리상태 ∈ {수용, 일부수용, 불수용, 기타, 답변완료} | 총 신고 | — | 서버 `get_dashboard_stats` 와 동일 목록 유지 |
| 처리 결과 비율 | 상태별 건수 / 총 신고 | 총 신고(취하 제외 설정 반영) | — | 비율 합이 100%가 되도록 "그 외" 항목을 표시 |
| 월별 신고 | 신고일 `YYYY-MM` 별 건수 | — | **신고일** | 신고일 파싱 실패 건수를 차트 밖에 "날짜 없음 N건"으로 표시 |
| 월별 답변 | 답변일 `YYYY-MM` 별 건수 | — | **답변일** | 답변일 없음 = 미답변, 0건으로 넣지 않음 |
| 평균 처리기간 | Σ(답변일−신고일) / 유효 표본수 | **유효 표본수**(두 날짜 모두 있고 차이 ≥ 0) | 두 날짜 | 음수는 제외하고 "날짜 역전 N건" 별도 표시(S-01 결정 필요). 기관 평균의 단순 평균 금지 |
| 과태료 합계 | 금액 파싱 성공 건 합계 | — | **부과일 없음 → 월별 과태료 차트는 만들지 않는다(사용자 결정 2026-09-24)**. 부과일 데이터를 새로 만들거나 추정하지 않는다 | 금액 미확인 건수를 별도 표시(S-05) |
| 평균 별점 | Σ별점 / 표본수(1~5) | 별점 표본수 | — | 표본 0 → "—" |
| 증감률 | (현재 − 비교기간) / 비교기간 | 비교기간 값 | 같은 날짜 기준 | 비교기간 0 또는 데이터 미확보 → 증감률 표시 안 함. 진행 중인 달은 "진행 중" 표시 |

## 5. 공통 규칙
- 모든 카드·차트·표에 같은 필터(연도, 법규, 카테고리, 취하 제외, 대표건, 경찰기관 정규화)를 적용한다.
- 카테고리는 교통/주정차/기타 3개만 합산한다. **중복차량은 네 번째 카테고리로 더하지 않는다**(차량번호 2건 이상인 신고의 부분집합, `local_db_service.dart:1549-1557`).
- 한 신고가 두 카테고리에 동시에 존재하는지: Standalone 은 `reports.category` 단일 컬럼이라 배타적. Client 서버 3개 merge 테이블 간 중복 여부는 **미확인** → 서버 확인 항목.
- 표시 수치는 전부 런타임 집계에서 나온다. 시안의 3,037 / 58.6일 / 2,763만원 같은 숫자를 하드코딩하지 않는다. fixture 값은 테스트 전용.
- Client/Standalone 에 같은 정의를 적용한다. 한쪽이 지원하지 못하면 다른 지표로 조용히 대체하지 말고 "미지원"을 표시한다.

## 6. 데이터 공급 방안과 계약 의존성

| 지표 | Standalone | Client | 계약 변경 |
|---|---|---|---|
| 월별 신고/답변 | 로컬 SQL 집계 추가 | **서버 신규 endpoint (사용자 결정 2026-09-24)** | **서버 계약 변경 의존성**: 서버 레포(`/home/better0101/projects/safetyreport`)에 월별 집계 API 추가 → `server_contract.dart`/`ServerContract.kt` 에 경로 추가. 필터(연도·법규·취하·대표건·경찰 정규화)를 쿼리로 받아 Standalone 과 같은 정의로 집계. 구서버 404 는 "미지원" 표시(중복 API 호환 방식과 동일) |
| 전체 평균 처리기간 (S-02) | **구현**: `LocalDbService.computeStatsOverview` 가 원자료에서 직접 계산 | **구현**: 서버 `/stats/overview` 가 계산해 `avg_days`·`avg_days_count` 로 내려줌 | 기관 평균 합산 안 함. 기존 `/stats` 는 변경 없음 |
| 금액 미확인 건수 | 로컬 집계 추가 | 서버 필드 추가 필요 | **서버 계약 변경 의존성** |
| 대표건 기준 일치(S-07) | 해당 없음 | `getStats` 에 `dedupe` 전달 | 서버는 이미 `dedupe` 파라미터를 받음 → 앱만 수정 |

## 6-1. 통계 요약 API 계약 (2026-09-24 신설)

`GET /api/v1/stats/overview?year=&law=&dedupe=` (X-API-Key). 파라미터 해석은 `/stats` 와 같다. 모바일 계약 상수 `ServerContract.statsOverviewPath`.
구서버는 404 → 앱은 "서버가 통계 요약 API를 아직 지원하지 않습니다" 안내를 표시하고 기관표는 그대로 보여 준다.

```json
{"status": "success", "data": {
  "all": {…}, "traffic": {…}, "parking": {…}, "other": {…},
  "available_years": ["2026", …], "year_basis": "답변일", "exclude_withdraw": true, "dedupe_mode": "canonical"}}
```
각 요약 객체: `total, completed, accept, partial, reject, supplement, processing, withdraw,
avg_days(소수1자리|null), avg_days_count, reversed_date_count, undated_report_count,
monthly_reported[{month:"YYYY-MM",count}](신고일 기준), monthly_answered[…](답변일 기준)`.

- 행 집합: `get_agency_stats` 와 같은 로딩·대표건 projection·행 필터·취하 제외·법규 필터(공통 헬퍼로 분리, 기존 출력 동일성 8개 조합 확인).
- 날짜: 앞 10자 `YYYY-MM-DD` 만 유효. 존재하지 않는 날짜는 결측. 평균은 두 날짜 모두 유효하고 차이 ≥ 0 인 행만.
- 상태 분류: 완료 {수용, 불수용, 일부수용, 기타, 답변완료}, 처리중 {처리중, 진행, 진행중, 검토중}, 불수용/기타는 합산.
- 같은 입력·기대값 테스트: 서버 `tests/test_report_stats_service.py`, 모바일 `test/services/stats_overview_test.dart`.

## 7. 테스트 (구현 전에 unit test 먼저)
빈 데이터 / 1건 / 미답변만 / 취하만 / 처리상태 NULL / 중복군(confirmed·review_required) / 연도 경계(12-31↔01-01) / 잘못된 날짜 / 날짜 역전 /
금액 미확인 vs 0원 / 기관별 표본수 차이(가중 평균 검증) / 법규 `없음` sentinel. 합계·범례·차트·표가 같은 조건에서 일치하는지와
차트·행 선택 → 목록 drilldown 시 날짜 기준·기관·분류·법규가 보존되는지 확인한다. 세부 계획: `docs/testing/ui-test-plan.md`.

## 8. 결정 현황
| 항목 | 상태 |
|---|---|
| Client 월별 추이 공급 방식 | **결정·구현: 서버 API 신설**(`/stats/overview`) |
| 과태료 월별 차트 | **결정: 만들지 않음**, 부과일 데이터 생성·추정 안 함 |
| S-02 전체 평균 처리일 | **결정·구현: Standalone 직접 계산, Client 는 서버가 계산해 API 로 제공** |
| S-07 | **해소(문제 아님)** |
| S-01 | **결정(권고대로)**: Standalone 기관표 평균 처리일도 서버처럼 음수 제외 + 소수 1자리 |
| S-03 | **결정(권고대로)**: 버그로 수정 — 취하 제외 시 처리상태 NULL 행 유지 |
| S-04 | **결정(권고대로)**: '미확인' 라벨을 뜻에 맞게 분리(대시보드 "처분 미확인" / 통계표 "기타·미분류") |
| S-05 | **결정(권고대로)**: 과태료 합계 옆 "금액 미확인 N건" 표시(Client 는 서버 필드 추가) |
| S-06 | **결정(권고대로)**: 현행 유지(중복차량 목록은 대표건 미적용) |
| S-08 | **결정: 답변일** — Standalone 연도 필터·연도 목록을 답변일 기준으로 변경(서버와 통일) |
| S-09 | 사용자 확인 대기(이전 권고 없음) |
