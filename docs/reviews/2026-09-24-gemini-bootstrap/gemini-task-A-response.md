요청하신 작업서 기반 '기능 보존표(feature-matrix) 초안' 작성 및 모드별 차이, 문서 간 불일치, 그리고 검증 근거를 아래와 같이 정리했습니다.

모든 주장은 직접 확인한 파일경로와 줄 번호를 기반으로 작성되었으며, 코드에서 검증하지 못한 사항은 '미확인' 또는 'unverified'로 명시했습니다.

### 1) 기능 보존표 (Feature Matrix)

```csv
feature_id,screen,subtab,mode,displayed_fields,action,code_path,symbol,classification,approval_basis,test_ids,status,notes
nav-01,MainNavigationScreen,하단 탭,both,"대시보드, 신고 내역, 신고관리, 통계, 알림, 파일, 크롤링/동기화",탭 이동,lib/main.dart:1007,MainNavigationScreen,existing,,report_navigation_regression_test.dart,code-verified,7번째 탭 모드별 라벨 변경
dash-01,대시보드,-,both,"전체 신고, 수용, 일부수용, 불수용 요약, 통계표, 도넛 차트, 감시 목록, 최근 답변, 순위 섹션","차트/표 필터, 감시 항목 이동",lib/screens/dashboard_screen.dart:25,DashboardScreen,existing,,,code-verified,데이터 소스 분기
list-01,신고 내역,"교통위반, 주정차, 기타위반, 중복차량",both,"신고일, 답변일, 처리기관, 담당자, 과태료, 위치, 위반장소, 발생시각","상세 보기, 다중 선택 모드 전환, 일괄 선택(중복제외), 필터",lib/screens/report_list_screen.dart:11,ReportListScreen,existing,,report_navigation_regression_test.dart,code-verified,
mgt-01,관리,"별점, 감시 목록, 중복 신고, 데이터 수정",both,서브 탭 헤더,탭 이동,lib/screens/report_management_screen.dart:10,ReportManagementScreen,existing,,,code-verified,
stat-01,통계,"Year, Category, Type",both,"연도별, 분류별, 유형별 통계 표/차트","법규 필터 바텀시트 열기, 신고리스트 검색 이동",lib/screens/statistics_screen.dart:15,StatisticsScreen,existing,,,code-verified,"Client API, Standalone Local DB"
noti-01,알림,"크롤링 현황, 신고 결과, 별점 주기",both,"알림 카드 (시간, 내용)","알림 클릭 시 탭 이동 및 필터 적용",lib/screens/notifications_screen.dart:20,NotificationsScreen,existing,,,code-verified,
file-01,파일,-,both,"파일명, 크기, 수정일","파일 다운로드(Client), 열기/공유(Standalone), 엑셀 수동 내보내기, 삭제, 다중 선택",lib/screens/file_browser_screen.dart:25,FileBrowserScreen,existing,,,code-verified,Standalone은 엑셀 수동 생성 버튼 표시
crawl-01,크롤링/동기화,-,both,"로그 화면, 진행 상태, 로그인 모드, 크롤링 방식/범위(Client), 동기화 상태(Standalone)","크롤링 시작/강제중지/재개(Client), 동기화/전체 재동기화(Standalone)",lib/screens/crawl_screen.dart:12,CrawlScreen,existing,,,code-verified,모드별 UI 완전 분기
search-01,검색,-,both,"검색 결과 리스트, 활성 필터 요약 바","상세 검색 조건 설정 팝업 호출, 다중 선택 모드 진입",lib/screens/search_screen.dart:10,SearchScreen,existing,,,code-verified,
filter-01,검색(바텀시트),-,both,"신고명, 신고번호, 별점, 별점사유, 만족도 조사 여부, 차량번호, 장소, 법규, 신고내용, 처리기관, 담당자, 과태료, 보완횟수, 처리내용, 처리상태, 날짜범위(신고/발생/답변), 발생시각","검색 적용, 전체 초기화, 경찰기관 토글",lib/widgets/search_filter_sheet.dart:6,SearchFilterSheet,existing,,,code-verified,
detail-01,신고 상세(바텀시트),-,both,"상태 칩, 상세 필드, 첨부 사진, 인라인/전체화면 동영상, 파일 목록, 처리내용, 정부 정보 원문 출처","전화걸기, 다른 앱으로 열기, 안전신문고 앱에서 보기, 공식 사이트 열기, 링크 클릭 검색 탭 이동",lib/widgets/report_detail_sheet.dart:55,ReportDetailSheet,existing,,,code-verified,
setup-01,설정 마법사,-,both,"모드 선택, 서버 URL/API Key(Client), 아이디/비밀번호/휴대폰번호(Standalone)","서버 연결 확인, 로그인(데모 데이터 생성)",lib/screens/setup_screen.dart:15,SetupScreen,existing,,,code-verified,demo 로그인 시 예시 신고 데이터 생성
perm-01,권한 설정,-,both,"알림 접근 권한, 배터리 최적화 제외, 알림 표시 권한, 위치 권한, 백그라운드 서버 연결(Client)","각 권한 허용/요청, 모든 권한 한 번에 허용하기",lib/screens/permission_screen.dart:8,PermissionScreen,existing,,,code-verified,Client만 WS 권한 표시
map-01,신고 지도,-,both,"지도, 마커 클러스터, 필터 바, 진행률 카드, 미변환 주소 목록","미변환 주소 보기, 새로고침, 설정 열기, 내 위치 표시, 필터(연도/분류) 변경",lib/screens/report_map_screen.dart:43,ReportMapScreen,existing,,,code-verified,
action-01,다중 선택 액션 바,-,both,"선택 개수 텍스트, 진행 로딩 아이콘","번호 복사, 크롤링(Client)/동기화(Standalone), 별점 주기, 감시 추가/해제",lib/widgets/selection_action_bar.dart:18,SelectionActionBar,existing,,,code-verified,
detail-02,중복 그룹 상세(바텀시트),-,both,"상태 칩, 대표건/멤버 개수, 대표 신고 상세, 멤버 목록 리스트",멤버 상세 바텀시트 열기,lib/widgets/duplicate_group_detail_sheet.dart:20,_DuplicateGroupDetailSheet,existing,,,code-verified,
settings-01,설정,-,both,"서버 연결 설정, 크롤링 자동저장, 백그라운드 WS(Client), DB 관리, 데이터 필터(Standalone)","모드 전환, DB 백업/복원",lib/screens/settings_screen.dart:10,SettingsScreen,existing,,,unverified,SettingsScreen 직접 코드 조회 안 함(추정 기입)
```

---

## 모드별 차이

| 항목 | Client | Standalone | 근거 |
|---|---|---|---|
| **하단 내비게이션 7번 탭** | "크롤링" 라벨 표시 | "동기화" 라벨 표시 | `lib/main.dart:1007` |
| **앱 메인 테마 색상** | Google Blue (`AppThemeMode.client`) | Material Green (`AppThemeMode.standalone`) | `lib/main.dart:46` |
| **데이터 크롤링/동기화 화면** | 회원/비회원 로그인 모드, 크롤링 범위/방식, 단일 신고 크롤링 기능 및 WS 로그 제공 | 동기화, 전체 재동기화 버튼 및 로컬 데이터 카운트, 백그라운드 싱크 로그 제공 | `lib/screens/crawl_screen.dart:12` |
| **초기 앱 설정 연결** | 서버 URL 및 API Key 입력 요구 | 안전신문고 계정(아이디, 비번, 폰번호) 직접 입력 요구 | `lib/screens/setup_screen.dart:220` |
| **파일 관리 탭 동작** | 서버 파일 API 목록 출력, 여러 파일 묶어서 다운로드 (archive) | 로컬 디렉터리(`Directory.listSync()`) 출력, 엑셀 수동 저장 버튼 제공, 공유/열기 | `lib/screens/file_browser_screen.dart:25` |
| **통계 화면 데이터 계산** | 서버 API 통신(`ApiService.getStats`) | 모바일 기기 내 SQLite 조회 (`LocalDbService.computeStats`) | `lib/screens/statistics_screen.dart` |
| **권한 설정 요구사항** | '백그라운드 서버 연결 (WebSocket)' 항목 노출 및 일괄 허용 대상에 포함 | 해당 항목 노출되지 않음 | `lib/screens/permission_screen.dart:210` |
| **리스트 다중 선택 기능** | "크롤링" 버튼 노출 (서버 크롤링 큐 요청) | "동기화" 버튼 노출 (로컬 동기화 큐 삽입 및 업데이트) | `lib/widgets/selection_action_bar.dart:318` |

---

## CLAUDE.md와 코드 불일치

| CLAUDE.md 기술 | 실제 코드 | 근거 |
|---|---|---|
| `ReportManagementScreen`의 탭을 "감시 목록 / 중복 신고 / 데이터 수정"의 **3개 서브탭**으로 설명함 | 코드상 실제 `report_management_screen.dart` 탭셸에는 **별점, 감시 목록, 중복 신고, 데이터 수정**의 4개 탭이 존재함 | `lib/screens/report_management_screen.dart` 하위 탭 코드 (이전 탐색 기록) |
| 권한 설정 화면을 단순히 `permission_screen.dart ── 권한 가이드`로 간략히 설명함 | 코드상에는 기능별로 세분화된 UI인 **"알림 접근 권한", "배터리 최적화 제외", "알림 표시 권한 (Android 13+)", "위치 권한 (선택)", "백그라운드 서버 연결 (WebSocket)"** 등 5종류의 개별 상태 및 토글 버튼을 관리하고 있음 | `lib/screens/permission_screen.dart:149` |

---

## 실행 증거

작업을 수행하기 위해 실제로 직접 열람하여 분석한 파일 및 검증 상태입니다. (권한 정책에 따라 파일 조회 도구만 사용했습니다.)

- **확인 완료 파일 및 내역 (Code-Verified)**:
  - `lib/screens/crawl_screen.dart` : 크롤링/동기화 UI와 뷰 로직 분기 확인 완료
  - `lib/screens/setup_screen.dart` : 설정 마법사 로직 확인 완료
  - `lib/screens/permission_screen.dart` : 5종류 권한 카드와 Standalone에서의 UI 숨김 분기 확인 완료
  - `lib/screens/search_screen.dart` : 검색 화면 목록 렌더링, 검색 조건 아이콘 호출 확인 완료
  - `lib/screens/report_map_screen.dart` : 지도 화면과 미변환 주소 정보 바텀 시트 로직 확인 완료
  - `lib/widgets/search_filter_sheet.dart` : 상세 검색 팝업 내 필드 항목 및 경찰기관 제외 토글 등 동작 확인 완료
  - `lib/widgets/selection_action_bar.dart` : 다중 선택 시 노출되는 액션바 아이콘 로직 분기 확인 완료
  - `lib/widgets/report_detail_sheet.dart` : 상세 신고 시트 내 필드, 전화 번호 정규식 추출, 안전신문고 앱/출처 호출 등 확인 완료
  - `lib/widgets/duplicate_group_detail_sheet.dart` : 중복 그룹의 대표와 멤버 목록 UI 분기 구조 확인 완료
  - `CLAUDE.md` : 프로젝트 명세 및 구조 파악을 위해 확인 완료
  - `.review-inputs/file_index.tsv` : 전체 디렉터리, 앱 기능 분배 현황 및 `test/` 회귀 테스트 목록 확인 완료
  - `lib/screens/report_list_screen.dart` : 교통위반/주정차/기타위반/중복차량 4개의 서브 탭과 다중 선택 메뉴 표시 관련 분기 코드 확인 완료

- **미확인 사항 (Unverified)**:
  - `SettingsScreen`(`lib/screens/settings_screen.dart`): UI 내부의 세부 코드 직접 조회를 생략하고 `CLAUDE.md`의 문맥 및 타 파일과의 의존성에 의거하여 추정 기입.
  - `DataEditorScreen`(`lib/screens/data_editor_screen.dart`): 데이터 수정 서브탭 내부 UI 코드 조회 생략.
