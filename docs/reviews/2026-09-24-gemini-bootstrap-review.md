# 2026-09-24 Gemini 독립 검토 (문서·환경 부트스트랩 단계)

- 호출: agy 1.2.9, 모델 `gemini-3.1-pro-high`, 읽기 전용 detached worktree(`c64be69a`) + `--add-dir` + `--sandbox` + `--output-format json`.
- 작업서·원문 응답: [2026-09-24-gemini-bootstrap/](2026-09-24-gemini-bootstrap/)
- 사후 검사: 메인 레포·worktree·agy scratch 에 Gemini 가 만든 파일 없음(`find -newer`, `git status`).

| 작업 | conversation_id | status | 소요 | 토큰 | 비고 |
|---|---|---|---|---|---|
| A 기능 보존표 초안 | f13b6b25-e8b5-4b47-be5a-dc9e70b14ed5 | SUCCESS | 329s | 343,733 | |
| B 시안 vs 기능 대조 | dae10724-8b9a-4355-b9c3-cdbfcf49ff00 | SUCCESS | 812s | 138,320 | 이미지 14장 열람 보고 |
| C 도구·테스트 검토 | 8358816c-e62e-4387-b989-fe866e13af5a | SUCCESS | 94s | 72,266 | 1차 실행은 권한 상향 재실행을 위해 중단 → 상향이 거부되어 같은 제한 구성으로 재실행한 결과 |

셸이 막혀 있어(§ runbook 3) Gemini 는 파일 보기 도구만 썼다. 그래서 A 는 범위가 얕았고, C 는 실행 검증을 못 했다. 실행 검증은 Opus 가 별도 worktree 에서 수행했다(`docs/testing/ui-test-plan.md` §4).

## A — 기능 보존표 초안
결과: 17행(요청 60~120행). 최종 보존표는 Opus 가 코드 탐색으로 전 화면을 다시 확인해 작성했다(`docs/design/feature-matrix.csv`).

| Gemini 주장 | 판정 | 근거 |
|---|---|---|
| 신고관리 하위 탭 4개(별점 포함), CLAUDE.md 3개 기술과 불일치 | **수용** | `report_management_screen.dart:25,49-52` |
| 7번째 탭 라벨 모드별 크롤링/동기화 | **수용** | `main.dart:1055` |
| 모드 테마 색이 `AppThemeMode.client/standalone` 에서 결정 | **반박** | `AppThemeMode` 는 system/light/dark. 색은 `AppMode` 로 결정(`main.dart:60-61`, `models/app_theme_mode.dart`) |
| Client 파일 탭 "여러 파일 묶어서 다운로드(archive)" | 수용(재확인) | `file_browser_screen.dart:1052` 다중 선택 zip |
| 설정 화면 행 | **반박(미검증 기입)** | Gemini 스스로 "직접 조회 안 함, 추정"으로 표기 → 사용 안 함, SET-01~16 으로 대체 |
| 권한 화면 5종 카드 | 수용 | `permission_screen.dart:148` |

## B — 시안 vs 기능 대조
| Gemini 주장 | 판정 | 근거 |
|---|---|---|
| 알림 '시스템 공지' 미구현 | **수용** | NotificationItemKind 에 없음 → UNS-02 |
| board 빈 상태 '파일 업로드' 미구현 | **수용** | 파일 탭에 업로드 없음, DB 복원(SET-12)과 다름 → UNS-03 |
| 컴포넌트 킷 바텀시트 '선택 삭제' 미구현 | **수용**(Gemini 는 미확인 표기) | 신고 레코드 삭제 경로 없음. 파일/알림 기록 삭제만 존재 → UNS-04 |
| 사이드 내비·표·페이지네이션 = PC 전용 | **수용** | → UNS-05 |
| "mobile white 하단 탭도 7개와 동일" | **반박** | 화이트 정본 하단 바는 대시보드/신고내역/신고관리/통계/알림 **5개**(이미지 직접 확인). 다크 정본은 7개 → DEC-02 |
| 컴포넌트 킷 FAB = '신고하기' | **부분 수용** | 이미지 라벨은 "상세 검색 및 도구"와 '+'. '+' 의미가 정의되지 않아 신고 접수로 쓰지 않는다는 결론만 수용 → UNS-01 |
| 처리결과 도넛에서 처리중 누락 | **수용** | 2,092+470+304+113 = 2,979 ≠ 3,037 (58건 누락) |
| 수용 71.5% 모수 오류 | **부분 수용** | 2,092/2,924(취하 제외) = 71.5% 로 설명되지만 취하 2.0%·일부수용 16.4% 는 다른 모수 → "카드마다 분모 혼재"로 정리 |
| 중복차량을 네 번째 카테고리로 합산 | **수용** | `local_db_service.dart:1549-1557`(부분집합) → statistics-spec §5 |
| 증감률·과태료 월별 차트 근거 없음 | **수용** | statistics-spec §4 |
| "평균 58.6일은 비현실적" | **반박** | 근거 없는 의견. 시안 수치는 어차피 사용하지 않음 |
| 로고: LOGO+white banner = 방패, favicon+dark banner = 카메라 | **부분 수용** | white banner 의 방패는 장식 요소이고 앱 로고 아님. 실제로는 현행 아이콘(카메라+도로, 다크 배너·목업 헤더), favicon(카메라+말풍선), LOGO(방패+콘) 3종 → D-05 |
| 글꼴 Noto Sans KR vs Pretendard, 수용색 #22C55E vs #10B981 | **수용** | → D-04, D-02 |
| 에셋 판정(badge/icons 불가, 배너·일러스트 정제 필요) | **수용** | asset-manifest 와 일치 |
| 놓친 점 | — | 상태색이 서버 웹과 공유된다는 점(README), 다크 정본 배경이 토큰 보드보다 푸른 점(픽셀 샘플), 알림 화면에 크롤링/동기화를 섞는 구조 문제(DEC-01) |

## C — 도구·테스트 검토
| Gemini 주장 | 판정 | 근거 |
|---|---|---|
| widget test/Guideline API 즉시 가능 | **수용·실증** | Opus 프로브 P1 에서 3종 Guideline 실행 |
| 골든은 한글 폰트 로드 필요, `loadAppFonts()` 사용 | **부분 수용** | 필요성은 맞음. `loadAppFonts()` 는 `golden_toolkit` 패키지 함수로 이 레포에 없다. `FontLoader` 로 직접 로드해 한글 렌더 확인. **Material 아이콘 폰트도 로드 필요**(Gemini 누락) |
| `ApiService` 가 provider getter 에서 하드코딩 생성 → DI 불가 | **수용** | `report_provider.dart:878` |
| Standalone 은 `databaseFactoryFfi` 로 가로채기 | **수용** | `local_db_service_regression_test.dart:153-158` |
| 기존 테스트 3개 파일 분석 | **반박(누락)** | 실제 8개 파일, 34 테스트(`ui-test-plan.md` §3) |
| TabBar 고정 색 단언을 대비/구분 단언으로 교체 | **수용** | `ui-test-plan.md` §3 방침 |
| integration_test 에 `testInstrumentationRunner` 필수 | **부분 수용** | Firebase Test Lab 등 네이티브 러너용. `flutter test integration_test` 로컬 실행에는 필수 아님 → 도입 시 재확인 |
| Dart MCP 불가 | **반박** | 샌드박스 제약 때문의 판단. `dart mcp-server --help` 종료코드 0, agy 에 25개 도구 노출 확인 |

## C2 — 테스트 기반 실행 검증 (권한 상향 구성, 사용자 명시 승인 후)
- 구성: 전용 쓰기 가능 worktree `../safetyreport-mobile-gemini-c` + `--add-dir` + 샌드박스 없음(셸 허용). status SUCCESS, 179s, 136,323 토큰.
- 사후 검사: 메인 레포에 Gemini 가 쓴 파일 없음(마커 이후 변경은 Opus 가 직접 고친 runbook 1개). worktree 변경은 `test/_tooling_probe/` 와 입력 폴더뿐.
- Opus 재실행: `p1_report_list_card_test` +6, `p2_golden_test` +1, `p3_...` +4 모두 종료코드 0 (재현됨).

| Gemini 주장 | 판정 | 근거 |
|---|---|---|
| P1: 360dp 에서 overflow 1.0배 55px / 1.3배 160px / 2.0배 406px, 라이트·다크 동일, Guideline 3종 통과 | **수용** | 재실행 통과. Opus 수치(48/334px)와 차이는 fixture·테마 차이. 결함 존재는 동일 |
| P1: 원인은 `_CarNumberChip` 이 Flexible 없이 `Expanded` 옆에 놓임 | **수용** | `report_list_card.dart:192-193`, `_CarNumberChip` :258 |
| P2: `NotoSansCJK-Regular.ttc` + `…/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf` 를 `FontLoader` 로 로드하면 골든 생성 후 재비교 통과 | **수용** | 재실행 통과. 아이콘 폰트 경로 확보 → 골든 계획에 반영 |
| P3: TabBar 고정색 단언을 대비·구분·indicator·탭 이동 단언으로 교체한 초안이 현행 코드에서 통과 | **반박(거짓 통과)** | `Color.computeLuminance()` 는 alpha 를 무시해 `Colors.white70` 을 흰색으로 계산. 실제 합성 대비는 white70 on `#1A73E8` = **3.0:1**(AA 미달), white = 4.5:1(경계). 배경도 앱 테마가 아니라 테스트 기본 테마에서 읽음. → 교체 단언은 배경과 alpha 합성 후 대비를 계산해야 하며, 그러면 **현행 미선택 탭 라벨이 AA 미달임이 드러남**(리뉴얼에서 수정 대상) |

## R1 — 시범 구현 독립 검수 (권한 상향 구성)
- 대상: 모바일 미커밋 변경(테마·카드·대시보드·탭·통계 요약) + 서버 `feature/stats-overview-api` 변경의 폐기용 사본. 실제 에뮬레이터 스크린샷·시안·골든 후보 제공.
- conversation `e797e74c-e8f0-43b6-84a7-b9131b0baf9d`, SUCCESS, 152s, 147,524 토큰. 상세 보고서: `2026-09-24-gemini-bootstrap/gemini-task-R1-review_report.md`.
- 사후 검사: 원본 레포에 Gemini 쓰기 없음(마커 이후 변경 9개는 모두 Opus 의 문서 편집).

| Gemini 주장 | 판정 | 근거 / 조치 |
|---|---|---|
| **치명**: 병렬 `flutter test` 에서 DB 테스트 두 파일이 같은 sqflite 경로를 써 `disk I/O error` 간헐 실패 | **수용·수정** | Opus 재현: 전체 실행 4회 모두 실패(2~9건). 원인은 새 `stats_overview_test.dart` 가 기존 DB 테스트와 기본 ffi 경로 공유. 두 파일 모두 `setDatabasesPath(임시 디렉터리)` 로 분리 → 전체 실행 6회 연속 90개 통과 |
| 기능 보존(카드 7개·콜백·탭·액션바·모드 분기) 유지 | 수용 | Opus 확인과 일치(feature-matrix 갱신) |
| 서버/모바일 요약 정의 동일, refactor 동작 유지 | 수용 | 같은 입력·기대값 테스트 양쪽 통과, refactor 전후 `get_agency_stats` 8개 조합 JSON 동일 |
| "S-01 도 양쪽 만족" | **부분 반박** | 새 요약은 서버 규칙(음수 제외·1자리)을 따르지만, S-01 은 기존 Standalone 기관표 평균(`_AgencyAgg`)의 차이이며 변경하지 않았다 → 결정 대기 유지 |
| 시각·접근성 문제 없음 | **보류(근거 부족)** | 스크린샷별 지적이 없다. Opus 실렌더 확인에서 차트 y축 라벨 중복을 찾아 이미 수정. 범위 밖 화면(통계 필터 칩, 별점 패널 머리, 알림 빈 상태)의 잔여 하드코딩 색은 Opus 도 확인 |

## G1·G2 — 범위 밖 화면 색 통일 구현 위임 (권한 상향, 파일 분담 병렬)
- base `00028685`. G1: 알림·파일·동기화/크롤링·지도(주변 UI)·권한·설정 마법사·신고현황(Sunwi). G2: 신고관리 패널들·최근 답변·필터 목록·상세/검색/선택/중복 시트. Opus: main·대시보드·설정·통계·신고내역·검색·테마.
- G1: SUCCESS 315s. G2: SUCCESS 1,064s. Opus 는 각 담당 파일만 가져오고 나머지 변경은 버렸다.

| 항목 | 판정 | 근거 / 조치 |
|---|---|---|
| G1·G2 모두 담당 밖 파일 수정 | **반박(범위 위반)** | G1: `duplicate_management_screen`(G2 담당)·`settings_screen`(Opus 담당), G2: models/services 11개 — 대부분 `dart format` 전체 실행. 담당 파일만 반영 |
| G1 "지도 화면 주변 UI 통일 완료" | **반박(허위 보고)** | `report_map_screen.dart` 는 변경 없음(git diff). Opus 가 직접 통일(마커 색 로직 보존) |
| 동작 보존 | **수용(검증)** | 담당 17개 파일의 문자열 리터럴·콜백/내비/필터 호출 수 비교: 사라진 문자열은 의도한 버그 수정 1건(`'검색 $reports.length건'`)뿐 |
| 남긴 하드코딩 | **부분 수용** | 동영상 오버레이(흑/백)·지도 마커·터미널 로그 패널은 타당. 그러나 신고현황 `black87/black54` 글자, 알림 `grey.shade200` 테두리, 버튼 안 흰 스피너 4곳, 설정 마법사 회색 박스, 선택 액션바 SnackBar 아이콘 흰색(다크에서 안 보임)은 Opus 가 수정 |
| G1 신고현황 순위 배지 | **반박(새 버그)** | 배경을 톤 전경색(다크에서 밝은 색)으로 칠하고 흰 글자 → 다크에서 판독 불가. 틴트 배경+AA 글자로 수정 |
| rating_management_panel 보간 버그 수정 | **수용** | `'검색 ${reports.length}건'` |

## R2 — 최종 독립 검수 (데모 데이터 전 화면 + 전체 diff)
- conversation `127f5cf6-e824-4263-9cb3-74d07a562766`, SUCCESS 199s. 입력: 에뮬레이터 Standalone 데모 데이터 라이트/다크 38장(실데이터는 주지 않음), `c64be69a..119647fa` 전체 diff. 원본 레포 쓰기 없음.

| Gemini 주장 | 판정 | 근거 / 조치 |
|---|---|---|
| S-10(기관표 행 포함 규칙 모드 차이) — 경미, 결정 필요 | 수용 | 이미 statistics-spec 에 기록 |
| `flutter analyze` warning 11건 존재 | **수용(Opus 오기 정정)** | Opus 가 "warning 0"으로 보고했으나 검사 명령이 경고 줄을 놓쳤다. 9건(G2 반영분 unused/duplicate import·unused local) 제거 → warning 2(기존) |
| D-06 딥링크·바로가기 변환 결함 없음, "최대 2초 대기로 레이스 없음" | 부분 수용 | 결론은 맞지만, 이중 push 레이스는 Opus 가 에뮬레이터 E2E 로 발견해 이미 수정(동기 open 플래그)한 뒤였다 |
| 스크린샷상 대비·잘림 문제 없음 | 수용(보조) | Opus 실렌더 검수와 일치. 선택 모드 뒤로가기(기존 동작)는 Gemini 가 언급하지 않음 |
