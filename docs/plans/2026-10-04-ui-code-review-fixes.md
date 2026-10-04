# UI·코드 점검 55건 수정 추적표 (2026-10-04)

- 근거: [점검 보고서](../reviews/2026-10-04-ui-code-review/index.html) (dev `17c0ea0f` 기준, 에뮬레이터 작동점검 + 코드 상세검사)
- 결정: 사용자 지시(2026-10-04) — 메이저 버전 출시 전이므로 지적한 55건을 모두 고친다.
- 브랜치: `fix/ui-code-review-2026-10-04` (dev에서 분기). push·릴리즈·VERSION 변경 없음.
- 담당: 이 작업에 한해 `main.dart`·테마·Provider·`pubspec.yaml` 수정 권한을 이 작업 단위(Opus 총괄)가 가진다.
- 기준선: Flutter 3.47.5 고정. `flutter analyze` error 0 / warning 9(test/ unnecessary_cast). `flutter test` 기준값은 아래 "기준선" 절.
- 상태: `대기` → `진행` → `완료(커밋)` / `보류(사유)`. 중단 시 이 표에서 이어간다.
- 금지: Dart MCP analyze 도구 사용 금지(홈 전체 분석으로 메모리 8GB 이상, 2026-10-04 OOM 원인). 셸의 `flutter analyze`·`flutter test`만 쓴다.

## 구현 공통 규칙

- SDK는 `~/development/flutter-3.47.5/bin/flutter`만 쓴다. 기본 `flutter`(3.41.6)는 골든·lock이 달라진다.
- 메모리: `flutter test`는 `-j 2` 이하. 전체 suite는 WP 끝에 한 번. 에뮬레이터·Gradle 빌드와 동시에 돌리지 않는다.
- 결함마다 재현 테스트를 먼저 만든다(가능하면 수정 전 실패를 확인). 고정 색상 단언을 바꿀 때는 원래 목적을 유지한다.
- 제품 불변조건(PROJECT_RULES)·서버 API/WS 계약·DB 스키마를 바꾸지 않는다. 서버 레포 변경이 필요하면 멈추고 보고한다.
- 골든은 의도한 시각 변경일 때만 갱신하고, 변경 이유를 CHANGELOG에 적는다. 실패를 숨기려고 갱신하지 않는다.
- 커밋은 총괄이 WP 단위로 한다(제목 영문, 본문 한국어, CHANGELOG 함께). push는 요청 시에만.

## 작업 패키지 순서

| WP | 주제 | 항목 | 주요 파일 | 상태 |
|---|---|---|---|---|
| WP1 | 알림 경로 | B01 B02 B04 B12 P08 U08 | notification_history_provider, main(_checkPendingChanges), notifications_screen, report_detail_sheet(markReportRead), WsService.kt(ID) | 완료 |
| WP2 | DB 가져오기·설정 화면 결함 | B03 B06 B08 B14 B09(settings·setup) | pending_db_import_action, setup_screen, settings_screen, report_provider(capabilities) | 완료 |
| WP3 | 루트·내비·테마 | P01 U05 U06 B05 B13 U07 U04(탭 막대) | main, app_theme, community_gate, sr_tab_bar, dashboard(관리), 시트 9곳, MainActivity.kt | 완료 |
| WP4 | 목록·드릴다운·상세 | U01 U02 P09 U12 U13 U14 U20(상세) | report_list_screen, local_paged_report_list, statistics/map/detail 드릴다운, report_detail_sheet, status_badge | 완료 |
| WP5 | 지도 | U03 U10 U11 P05 U24(범례) | report_map_screen | 완료 |
| WP6 | 대시보드·통계 표시 | U15 U04(대시보드 그리드) U09 U24(당월) U25 U22 | dashboard_screen, stats_overview_section, stats_fine_breakdown, utils/format | 완료 |
| WP7 | 크롤링/동기화 화면·타이머 | B07 U18 P04 P10 B09(crawl) | crawl_screen, maintenance_status_bar, sunwi_screen | 완료 |
| WP8 | Provider·조회 비용 | P02 P06 P07 B10 B11 P12 P13 B09(나머지) | report_provider, local_db_service, local_paged_report_list, main(시작), pubspec | 완료 |
| WP9 | 파일·내보내기 | P03 P11 | file_browser_screen, local_db_service(export) | 완료 |
| WP10 | 디자인 일관성·접근성 | U16 U17 U19 U20 U21 U23 U26 U27 U28 | 앱바들, settings_screen 재배치, sr_colors/app_theme 토큰, 공용 빈 상태, search_filter_sheet, docs | 완료 |
| WP11 | 보고서 밖 추가 표시 결함 | UI 검토 L-3 L-7 L-8 L-9 | report_list_card, stats_overview_section, notifications_screen, rating_dialog | 완료 |
| VER | 통합 검증 | 전체 | analyze/test, 에뮬레이터 라이트·다크·1.3/2.0배, 골든 재검토 | 완료(1170 passed, 상태 칸 접근성 탭 동작 추가 수정, 기관 드릴다운 건수 차이는 backlog BL-2) |

## 항목별 배정

| ID | 내용 | WP | 상태 |
|---|---|---|---|
| U01 | 신고내역 앱바 건수 배지 0건 | WP4 | 완료 |
| U02 | 드릴다운 필터가 하단 신고내역 탭에 남음 | WP4 | 완료 |
| U03 | 다크 지도 라벨 흰 바탕 흰 글자, 라벨 문구 잘림 | WP5 | 완료 |
| U04 | 글꼴 2.0배 넘침·탭 이름 잘림 | WP3(탭 막대)·WP6(대시보드) | 완료 |
| U05 | 비0 탭 뒤로가기 즉시 종료 | WP3 | 완료 |
| U06 | 대시보드 "관리"가 중복 화면 push | WP3 | 완료 |
| U07 | 바텀시트 손잡이 이중 | WP3 | 완료 |
| U08 | Standalone 알림 빈 문구 "크롤링" | WP1 | 완료 |
| U09 | 월별 추이 세로축 최상단 잘림 | WP6 | 완료 |
| U10 | 지도 OSM 출처 표기 | WP5 | 완료 |
| U11 | 지도 진입 즉시 위치 권한 요청 | WP5 | 완료 |
| U12 | 상세 라벨 82px 고정 폭 | WP4 | 완료 |
| U13 | 상태 칩 대비 미달(StatusBadge 우회) | WP4 | 완료 |
| U14 | 동영상 닫은 뒤 세로 고정 | WP4 | 완료 |
| U15 | 대시보드 요약 카드 밀도 | WP6 | 완료 |
| U16 | 탭별 앱바·검색 위치 불일치 | WP10 | 완료 |
| U17 | 설정 화면 순서·중복 | WP10 | 완료 |
| U18 | 동기화 화면 빈 로그 패널·대비 | WP7 | 완료 |
| U19 | 12 미만 글자 | WP10 | 완료 |
| U20 | 툴팁·터치 영역 | WP10(상세 시트는 WP4) | 완료 |
| U21 | 빈/오류 상태 공용화·재시도 | WP10 | 완료 |
| U22 | 숫자·금액 표기 통일 | WP6 | 완료 |
| U23 | 의미색·반경 토큰 | WP10 | 완료 |
| U24 | 지도 범례·당월 막대 구분 | WP5·WP6 | 완료 |
| U25 | 확정/추정 시각 구분 | WP6 | 완료 |
| U26 | 시스템 바 여백 | WP10 | 완료 |
| U27 | 상세 검색 시트 입력칸 정리 | WP10 | 완료 |
| U28 | 문서 불일치·동의 화면 증거 | WP10 | 완료 |
| P01 | 테마 재생성·루트 재빌드 | WP3 | 완료 |
| P02 | statsRefreshNonce 전역 재조회 | WP8 | 완료 |
| P03 | 엑셀 내보내기 전량·UI isolate | WP9 | 완료 |
| P04 | 유지보수 폴링 백그라운드 | WP7 | 완료 |
| P05 | 지도 마커 매 빌드 재생성 | WP5 | 완료 |
| P06 | 목록 SELECT r.* | WP8 | 완료 |
| P07 | Selector 부재·무변경 알림 | WP8 | 완료 |
| P08 | 알림 기록 반복 reload·저장 | WP1 | 완료 |
| P09 | 상세 "같은 조건 검색" 200행 | WP4 | 완료 |
| P10 | 전국 현황 타이머 화면 밖 | WP7 | 완료 |
| P11 | 파일 화면 동기 stat | WP9 | 완료 |
| P12 | 시작 초기화 직렬 | WP8 | 완료 |
| P13 | cached_network_image 미사용 | WP8 | 완료 |
| B01 | 읽은 신고의 새 변경 유실 | WP1 | 완료 |
| B02 | 알림 기록 lost update | WP1 | 완료 |
| B03 | DB 변환 대기 작업 선삭제 | WP2 | 완료 |
| B04 | 소비형 완료 신호 순서 | WP1 | 완료 |
| B05 | MethodChannel 처리기 수명 | WP3 | 완료 |
| B06 | 다운로드 진행 창 뒤로가기 | WP2 | 완료 |
| B07 | 크롤링 화면 폴링·dispose | WP7 | 완료 |
| B08 | 서버 변경 시 capabilities·저장 이중 실행 | WP2 | 완료 |
| B09 | await 뒤 mounted 누락 | WP2·WP7·WP8 | 완료 |
| B10 | 감시 목록 epoch | WP8 | 완료 |
| B11 | _isLoading 공유 | WP8 | 완료 |
| B12 | 알림 기록 ID 충돌 | WP1 | 완료 |
| B13 | 재구성 게이트 onDone 반복 | WP3 | 완료 |
| B14 | 재로그인 컨트롤러 미해제 | WP2 | 완료 |

## 기준선

- 2026-10-04, HEAD `77ea5d9f`(코드는 `17c0ea0f`와 동일), Flutter 3.47.5: `flutter test -j 2` **914 passed / 16 skipped / 0 failed**, `flutter analyze` **error 0 / warning 9 / info 0**(test/ unnecessary_cast).
