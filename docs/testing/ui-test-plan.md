# UI 테스트 계획 (ui-test-plan)

작성 2026-09-24, base `c64be69a`. 상태 표기: PASS / FAIL / BLOCKED / NOT_RUN. 실행하지 않은 것을 PASS로 쓰지 않는다.

## 1. 환경 (실측)

| 항목 | 값 | 확인 방법 |
|---|---|---|
| OS / 셸 | Ubuntu 24.04.5, Linux 7.0.0-31, bash | `uname -a` |
| Flutter / Dart / DevTools | 3.41.6 stable (db50e20168) / 3.11.4 / 2.54.2 | `flutter --version` |
| 프로젝트 SDK 제약 | `sdk: ^3.11.4` (설치 버전과 일치) | `pubspec.yaml` |
| Java | OpenJDK 21.0.12 (빌드 타깃 Java 17) | `java -version`, `android/app/build.gradle.kts:23-28` |
| AGP / Kotlin / Gradle | 8.11.1 / 2.2.20 / 8.14 | `android/settings.gradle.kts`, wrapper |
| Android SDK | `~/Android/Sdk`, platforms 34·35·36, build-tools 35·36.1·37, emulator 36.5.10 | `flutter doctor -v` |
| cmdline-tools | **23.0 설치 (2026-09-24)** `~/Android/Sdk/cmdline-tools/latest` (`commandlinetools-linux-16111833`, SHA-1 검증). `sdkmanager`/`avdmanager` 동작, 새 `android` CLI 1.0.16406183 동봉(sdkmanager 는 deprecated 안내) | `sdkmanager --version`, `avdmanager list avd` |
| 라이선스 | 사용자 수락(2026-09-24). `flutter doctor --android-licenses` 실행 → cmdline-tools 23 의 sdkmanager 가 "`--licenses` option is no longer needed" 로 응답. Flutter 3.41.6 은 이 출력을 해석 못 해 계속 **"license status unknown"** 표시(도구 호환 문제, 빌드 차단 여부는 첫 APK 빌드에서 확인) | `flutter doctor -v` |
| 남은 경고 | `ANDROID_HOME` 미설정, `adb` PATH 밖(`~/Android/Sdk/platform-tools/adb`), eglinfo 없음 | `flutter doctor -v` |
| 가속 | KVM 12 사용 가능 | `emulator -accel-check` |
| AVD | 개인용 `Pixel_9_Pro`(건드리지 않음) + **테스트 전용 `sr_uitest_api35`**(2026-09-24 생성: pixel_6 프로필 1080x2400@420dpi ≈ 411dp, Android 15 API 35 google_apis_playstore x86_64, data 10G) | `emulator -list-avds` |
| AVD 가동 | `sr_uitest_api35` headless 콜드부트 3회 PASS(첫 부팅 114s, 이후 52s), 소프트웨어 렌더링(SwANGLE/lavapipe, VM 에 GPU 없음), 설정 앱 렌더 스크린샷 확인. 부팅 직후 런처는 수십 초간 검은 화면일 수 있음 → 캡처 전 `mCurrentFocus` 확인 후 대기. 포트 5580 사용 | `emulator -avd sr_uitest_api35 -no-window -port 5580` |
| 연결 기기 | 없음(테스트 후 에뮬레이터 종료) | `adb devices -l` |
| Android CLI (`android`) / Patrol CLI | cmdline-tools 23.0 에 동봉(PATH 밖) / 미설치 | `cmdline-tools/latest/bin/android --version` |
| 한글 폰트(호스트) | Noto Sans CJK(TTC)만 있음 | `fc-list :lang=ko` |

## 2. Baseline (기존 코드, 변경 전)

| 명령 | 결과 | 로그 |
|---|---|---|
| `flutter analyze` | 종료코드 **1**: error 0, warning 2(`unused_element_parameter`), info 73(deprecated_member_use 39, unnecessary_underscores 10, unnecessary_brace_in_string_interps 9, use_null_aware_elements 6, use_build_context_synchronously 6, curly_braces 3) | 세션 스크래치 `baseline/analyze.log` |
| `flutter test` | 종료코드 0, **34 passed** (8개 파일) | `baseline/test.log` |
| `pubspec.lock` | 실행 전후 동일 | sha256 비교 |

규칙: 리뉴얼 후 analyze 의 error/warning 수가 늘면 실패로 본다. info 증가는 보고하고, 기존 info 를 이번 작업에서 정리할지는 별도로 정한다.

## 3. 기존 테스트가 지키는 것

| 파일 | 회귀 방지 대상 |
|---|---|
| `test/report_navigation_regression_test.dart` | 안전신문고 앱 딥링크 URI(:63-70), 카테고리 없는 신고의 재조회/탭 결정(:76-100), **신고관리 TabBar 색/indicator**(:103-119) |
| `test/services/local_db_service_regression_test.dart` | 백업 복원·지도 메타·주소 좌표 파싱 (sqflite ffi) |
| `test/services/pending_changes_store_test.dart` | 변경 카드 시트 대기열 / 포그라운드 이벤트 |
| `test/services/pending_db_import_action_test.dart` | 모드 전환 DB import 예약 |
| `test/services/rating_service_test.dart` | 별점 대상 선별/결과 |
| `test/services/server_connection_service_test.dart` | 서버 연결 테스트 응답 처리 |
| `test/services/standalone_pending_queue_store_test.dart` | Standalone CSV 큐 |
| `test/widget_test.dart` | 기본 스모크 |

### TabBar 색 단언 교체 방침
`report_navigation_regression_test.dart:116-119` 는 `labelColor == Colors.white` 등 고정값을 단언한다. 새 테마에서는 이 값이 바뀔 수 있으므로
본래 목적을 지키는 단언으로 바꾼다: ① 선택/미선택 라벨 색이 서로 다르다, ② 두 색 모두 탭바 배경 대비 WCAG AA(4.5:1) 이상,
③ indicator 가 보인다(두께 > 0, 배경과 다른 색), ④ 탭을 누르면 해당 패널로 이동한다. 테마 토큰에서 기대값을 읽고 리터럴 색을 쓰지 않는다.
**주의(2026-09-24 C2 검수):** 대비는 반드시 alpha 를 배경에 합성한 뒤 계산하고(`Color.alphaBlend(fg, bg)` 후 luminance), 배경은 실제 앱 테마로 렌더된 AppBar 색에서 읽는다. `computeLuminance()` 를 반투명 색에 그대로 쓰면 거짓 통과한다. 현행 미선택 라벨 `white70` on `#1A73E8` = 3.0:1 로 **AA 미달**(선택 라벨 white = 4.5:1 경계) → 새 테마에서 해소 대상.

## 4. 도구 가동 확인 (이번 단계 실측)

| 도구 | 상태 | 증거 |
|---|---|---|
| flutter_test widget + 접근성 Guideline API | **PASS(가동)** | 프로브 P1: `androidTapTargetGuideline`, `labeledTapTargetGuideline`, `textContrastGuideline` 평가 실행됨 |
| 골든(`matchesGoldenFile`) + 한글 폰트 | **PASS** | 한글 `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc` + 아이콘 `~/development/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf` 를 `FontLoader` 로 로드 → 골든 생성 후 재비교 통과(Gemini C2 재현, Opus 재실행 확인) |
| Dart MCP (`dart mcp-server`) | 실행 파일 가동 PASS / agy 노출 PASS / 실제 도구 호출 NOT_RUN | `--help` 종료코드 0, agy 가 25개 도구 노출 |
| Flutter 공식 Claude 플러그인 | 설치 PASS / 이 세션 로드 NOT_RUN(새 세션 필요) | `claude plugin list` |
| integration_test | NOT_RUN (의존성 없음) | `pubspec.yaml` |
| Patrol | NOT_RUN (미설치) | — |
| 에뮬레이터/adb | 가동 PASS(`sr_uitest_api35`), 앱 설치/실행 NOT_RUN | 부팅·스크린샷 |

### 프로브 결과 (Opus 전용 worktree, 운영 코드 무변경)
- P1 `ReportListCard` 360×800, 긴 신고명·기관명·차량번호(`서울31바5845`×3), 라이트/다크 × 글자배율 1.0/2.0:
  - **RenderFlex overflow**: 1.0배 48px, 2.0배 334px (라이트·다크 동일). → 현행 카드의 기존 결함. 리뉴얼 카드에서 고친다.
  - 접근성 Guideline 3종: 모두 통과(이 fixture 기준).
- P2 골든: 생성은 됐지만 같은 overflow 로 테스트 FAIL. 한글은 정상, 아이콘은 박스.

## 5. 테스트 층과 계획

| 층 | 대상 | 방법 | 비고 |
|---|---|---|---|
| Unit | 통계 지표(statistics-spec §7), 상태 색 매핑, 필터 | `flutter_test` | 계산 의미 변경은 승인 후 |
| Widget | 신고 카드, 상태 배지, 탭, 요약 카드, 선택 액션바, 빈/오류 상태 | `WidgetTester` + Guideline API + overflow 감지 | 360/412dp × textScale 1.0/1.3/2.0 × light/dark |
| Golden | 승인된 시범 화면의 실제 Flutter 렌더 | `matchesGoldenFile`, 번들 테스트 폰트 + MaterialIcons 로드, 고정 날짜/locale `ko_KR` | 이 Linux 호스트에서만 기준 생성. `--update-goldens` 는 기준 생성 커밋에서만, 실패 숨기기 금지 |
| 앱 내부 동선 | 탭 이동, 검색 drilldown, 선택 액션 | `integration_test` (도입 시 dev_dependency 추가 승인 필요) | 에뮬레이터 필요 |
| 네이티브 | 권한 화면, 알림 탭 딥링크, 파일 선택, 공유 시트 | Patrol 우선 검토, 아니면 수동 실행 증거 | 앱 내부 테스트 통과로 대체하지 않음 |
| 실기기 시각/성능 | 대량 목록·통계 스크롤 | profile 빌드 + DevTools | 에뮬레이터 결과로 실기기 성능 단정 금지 |

## 6. Fixture 전략
- **주입 지점**
  - 공통: `ChangeNotifierProvider<ReportProvider>.value` 로 fake provider 주입(기존 테스트 `report_navigation_regression_test.dart:107-110` 방식).
  - Client: `ReportProvider._api` 가 getter 에서 `ApiService` 를 직접 생성(`report_provider.dart:878`) → 생성자 DI 불가. 위젯 테스트는 provider 서브클래스로 데이터 주입, 서비스 테스트는 `http` mock 또는 `HttpOverrides`.
  - Standalone: `LocalDbService` 는 static. `sqflite_common_ffi` + `databaseFactoryFfi`(기존 `local_db_service_regression_test.dart:153-158`)로 임시 DB에 fixture 행 삽입.
  - 순수 위젯(`ReportListCard`, 배지, 요약 카드)은 `Report` 객체만으로 렌더 가능 — provider 불필요(프로브 P1 확인).
- **플러그인 fake**: `SharedPreferences.setMockInitialValues`, `flutter_secure_storage`/`video_player`/MethodChannel 은 `TestDefaultBinaryMessengerBinding` mock handler, `cached_network_image`/`flutter_map` 타일은 네트워크 차단 fake. 네트워크 이미지·지도는 골든 대상에서 제외하거나 placeholder 고정.
- **fixture 내용**(두 모드 공통 JSON 1벌): 긴 한글 신고명, 긴 기관명(경찰청 하위 부서 포함), 비정상적으로 긴 차량번호, 결측(답변일·담당자·처리상태 NULL), 빈 목록, 로딩, 오류, 선택 상태, 보완요청(보완횟수>0), 중복군(confirmed/review_required), 취하, 사진·동영상 첨부 URL(로컬 fake), 연도 경계, 날짜 역전, 금액 미확인.
- 데모 경로(`demo/demo`)의 3건만으로 UI 검증 완료를 선언하지 않는다. 운영 로그인·별점 API·실서버는 쓰지 않는다.
- **DB 를 쓰는 테스트 파일은 `setUpAll` 에서 `databaseFactory.setDatabasesPath(임시 디렉터리)` 로 전용 경로를 쓴다.** `flutter test` 는 파일 단위 병렬이라 기본 ffi 경로를 공유하면 서로의 `standalone_reports.db` 를 덮어써 간헐 실패한다(2026-09-24 R1 재현·수정).

## 7. 디바이스 규칙
- 테스트는 전용 AVD `sr_uitest_api35`(serial `emulator-5580`)에서만 한다. 개인용 `Pixel_9_Pro` 는 조작하지 않는다. 360dp 검증은 `adb shell wm size 1080x2400` 유지 + `wm density 480`(≈360dp) 처럼 런타임 조정 후 원복한다.
- 디바이스 serial·실행 앱·Dart MCP runtime URI 는 작업서마다 한 에이전트에만 배정한다.
- 개인 실기기의 운영 앱을 uninstall/`pm clear` 하지 않는다. 테스트 빌드는 별도 applicationId suffix(예: `.uitest`) 사용을 검토한다(Gradle 변경 = 승인 필요).

## 8. 시범 구현 검증 체크리스트 (다음 단계)
1. 테마 계층 도입 후 analyze/test baseline 유지.
2. 신고 카드: overflow 0건(360dp, 1.0/1.3/2.0), Guideline 3종 통과, 라이트/다크 골든.
3. 대시보드 요약/처리 현황, 통계 요약 일부: 수치가 fixture 집계와 일치, 라이트/다크 골든.
4. 에뮬레이터에서 Client(fake 서버)·Standalone(fixture DB) 각각 실렌더 스크린샷 → Gemini 독립 검수.

## 9. 실행 기록 (2026-09-24)

| 항목 | 결과 |
|---|---|
| `flutter test` | 95 passed (단위·위젯·접근성·골든 4장, DB 테스트 파일별 임시 경로) |
| `flutter analyze` | error 0 / warning 0 / info 47 (시작 baseline: warning 2, info 73) |
| 에뮬레이터 내비게이션 E2E (`sr_uitest_api35`, Standalone 데모) | 하단 5탭, 동기화 카드/앱바 → 동기화, 딥링크 nav_tab 6/5/4, 런처 바로가기 quick_sync(데모 차단 안내), 설정 > 파일 관리, 뒤로가기 복귀 — 전부 PASS. 바로가기 이중 push 결함 발견·수정 |
| 실데이터 Client 렌더 | 실서버 DB 사본 + 로컬 최소 API(새 서버 코드) + 에뮬레이터 Client 모드, 라이트/다크 16화면씩. 캡처는 세션 임시 폴더에만(레포·Gemini 제외) |
| 데모 데이터 전 화면 렌더 | 라이트/다크 19화면씩 → Gemini 최종 검수 입력 |

- 캡처 드라이버: 앱 포커스·기대 라벨을 확인하고 찍는다(세션 스크래치 `render/shoot.py`, uiautomator 덤프 기반). 좌표 대신 라벨로 탭한다.
- **발견된 기존 동작(이번 변경 전부터)**: 신고내역에서 길게 눌러 선택 모드에 들어간 뒤 안드로이드 뒤로가기를 누르면 선택 해제가 아니라 앱이 나간다(`PopScope` 없음, base `c64be69a` 동일). 범위 밖이라 미수정 — 결정 필요.
- 선택 모드 닫기(X) 버튼에 접근성 라벨(tooltip)이 없다. 기존 동작, 미수정.
