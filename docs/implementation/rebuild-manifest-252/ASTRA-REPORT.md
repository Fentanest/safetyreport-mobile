# 2.5.2 신고 내역 다시 불러오기 복구 보고서

작업 기준: `fix/rebuild-manifest-252`, `4ad9881d0a77afa6016fbc132f699552cc0c5748` (출시 2.5.1+180). 수정·시험 산출물은 이 작업 폴더에만 기록했다. 커밋·push·버전 변경·원격 서버 접근·배포는 하지 않았다.

## 변경 내용과 위치

| 파일·줄 | 변경 |
|---|---|
| `lib/community/manifest_result.dart:1` | 원인·재시도 가능 여부·사용자 조치·문구·안전한 진단 필드 정의, 구형 오류 해석 |
| `lib/community/upload/community_ingest_client.dart:113` | 목록 HTTP 결과를 `ManifestResult`로 반환, 오류 본문 대신 상태·코드·request_id 보존 |
| `lib/community/community_wiring.dart:79`, `:191` | 강제 게이트 갱신 연결, 잠금/연결/세션/점검/무결성 실패 구분. 기존 동기화 bool 계약에는 `isOk`만 전달 |
| `lib/community/upload_hooks.dart:21` | 복구 전용 게이트·목록 결과 훅. 연결이 없을 때 성공으로 처리하지 않음 |
| `lib/community/rebuild/community_rebuild.dart:26`, `:264`, `:596`, `:711` | `waiting_retry`, 원인별 안내, 강제 게이트 → 목록 → 기존 작업 재개, job 오류 및 진단 meta 저장 |
| `lib/community/rebuild/standalone_rebuild_runner.dart:163`, `:370` | 업로드 잠금은 15초, 일시 오류는 15·30·60·120·300초 간격. 5분 간격 유지, 횟수 소진 없음 |
| `lib/screens/community_rebuild_screen.dart:250`, `:282`, `:293`, `:492` | Standalone 복구 시 Client 설정을 전달하지 않음. 로그인/동의/연결 화면 이동, 업로드 전환, 실제 다시 시도 |
| `lib/widgets/rebuild_progress_card.dart:134` | 조치가 필요한 원인은 대시보드에서도 해당 조치 버튼 표시 |
| `lib/main.dart:974` | 시험 주입 함수의 목록 결과 타입 변경. 실행 모드·버전·초기화 필요 버전은 유지 |
| `lib/services/background_login_check.dart:142` | 기존 catch-up bool 계약에 결과의 `isOk` 전달 |
| `test/community/manifest_recovery_test.dart:1` | 실제 SQLite 잠금 경합/해제, HTTP 원인·진단, 무결성·범위 변경 회귀 |
| `test/community/rebuild_state_test.dart:473`, `:510`, `:555` | 원인별 상태·수집 차단·진단 저장·같은 작업 재개, 강제 게이트 선행 확인 |
| `test/community/rebuild_background_runner_test.dart:155` | 기존 `manifest_unavailable` 작업 첫 실행 자동 재개 |
| `test/widgets/standalone_rebuild_background_test.dart:326`, `:384`, `:410` | 최대 간격·횟수 제한 없음·수동 복구·원인별 예약, 잠금 경합 8회 후에도 15초 재확인 |
| `test/widgets/community_rebuild_screen_test.dart:383`, `:431`, `:455` | 원인별 안내·화면 이동·복귀 재개, 업로드 전환 호출, 다시 시도 버튼 |
| `test/community/integration_contract_test.dart:190`, `test/community/live_stack_test.dart:129` | 결과 타입 변경에 맞춰 성공/실패 판정 검사. live stack은 실행하지 않음 |
| `test/widgets/client_waiting_banner_test.dart:14` | 기존 배너 시험의 SharedPreferences 모의 저장소 누락 보완 |
| `test/community/rebuild_fresh_install_test.dart:69`, `test/community/rebuild_scope_generation_test.dart:77` | 기존 새 설치·계정 범위 시험의 타입 주입 갱신 |
| `docs/architecture/data-contracts.md:848` | 오래된 최대 5회/30분 재시도 설명을 현재 코드와 대조 정정 |
| `docs/releases/unreleased.md:3`, `CHANGELOG.md:3` | 사용자 관점 수정 한 줄 및 실제 변경 이력 |

## 원인별 동작

실패 시 `rebuild_jobs.last_error`에는 `manifest_<reason>`, `meta.rebuild_manifest:<run_id>`에는 `reason`, `http_status`, `server_code`, `request_id`를 저장한다. 코드·요청 ID는 영문/숫자 및 `_ . : -`, 최대 128자로 제한한다. 응답 메시지·계정·연결 식별자·인증 토큰·목록 본문은 진단에 기록하지 않는다.

| 원인 | 저장 상태 / 다음 동작 |
|---|---|
| `ok` | 기존 run과 백업을 재사용하여 수집/검증/반영 진행 |
| `busy_upload_lease` | `waiting_retry`, HTTP 요청 없이 반환. 업로더 잠금은 유지하고 15초마다 재시도 |
| `no_context` | `prerequisites_required`, 공유 연결 확인 및 이 기기로 업로드 전환 버튼 |
| `no_token` | `prerequisites_required`, 카카오 다시 로그인 버튼 |
| `paused` | `waiting_retry`, 15초 → 최대 5분. 게이트에서 점검 종료 여부 재확인 |
| `auth` | `prerequisites_required`, HTTP 401/403 및 구조화된 서버 코드 보존, 로그인 안내 |
| `consent_required` | 동의 없음/철회/구버전/정책 불일치 코드를 구분하여 새 동의문 화면 제공 |
| `writer_required` | 다른 기기 연결/소유권 충돌. 공유 연결 확인 및 명시적 업로드 전환 버튼 |
| `rate_limited` | `waiting_retry`, 15·30·60·120·300초, 이후 300초 |
| `server_error` | 5xx/408, 비 JSON 오류 응답 포함. 위와 같은 자동 재시도 |
| `network` | 연결/시간 초과 및 게이트 조회 예외. 위와 같은 자동 재시도 |
| `invalid_response` | `prerequisites_required`, 기존 완료 목록 유지. 수동 다시 시도 가능, 자동 반복하지 않음 |
| 구형 `manifest_unavailable` | 일시 오류로 해석. 기존 job 존재가 안내 확인 기록이므로 첫 실행에 같은 run 자동 재개 |

재시도는 `refreshNow(silent: true)`로 캐시 유효 시간과 무관하게 게이트를 재검증한다. 게이트 내부의 기존 연결 등록·재연결·활성화 확인 이후에 목록을 다시 요청한다. `server_completed.dart`는 수정하지 않았으며 전체 페이지 세대·총건수·중복·범위 및 커밋 직전 연결·잠금 검사를 유지했다.

## 새 문구와 버튼

| 상황 | 안내 | 버튼 |
|---|---|---|
| 업로드 중 | 신고 자료를 보내고 있습니다. 전송이 끝나면 자동으로 다시 시도합니다. | 다시 시도 |
| 공유 연결 없음 | 공유 연결을 확인해 주세요. 다른 기기가 업로드 중이면 ‘이 기기로 업로드 전환’을 선택해 주세요. | 공유 연결 확인 / 이 기기로 업로드 전환 |
| 세션 없음·인증 거절 | 카카오 계정을 확인하지 못했습니다. 카카오로 다시 로그인해 주세요. | 카카오 다시 로그인 |
| 재동의 | 공유 동의문이 바뀌었거나 동의가 필요합니다. 새 동의문을 확인하고 동의해 주세요. | 새 동의문 확인 |
| 다른 기기 업로드 | 다른 기기가 업로드하고 있습니다. 공유 연결 화면에서 ‘이 기기로 업로드 전환’을 선택해 주세요. | 공유 연결 확인 / 이 기기로 업로드 전환 |
| 점검 | 공유 서버를 점검하고 있습니다. 잠시 후 자동으로 다시 시도합니다. | 다시 시도 |
| 요청 제한 | 공유 서버에 요청이 많습니다. 잠시 후 자동으로 다시 시도합니다. | 다시 시도 |
| 통신·서버 오류 | 공유 서버에 연결하지 못했습니다. 잠시 후 자동으로 다시 시도합니다. | 다시 시도 |
| 목록 무결성 실패 | 공유 목록을 안전하게 확인하지 못했습니다. 기존 자료는 유지됩니다. 잠시 후 다시 시도해 주세요. | 다시 시도 |
| 전환 실패 | 이 기기로 업로드를 전환하지 못했습니다. 카카오 로그인과 공유 동의를 확인해 주세요. | 기존 조치 버튼 유지 |

화면에 내부 코드·lease·manifest·context를 표시하지 않는다. “상태 다시 확인”은 Standalone에서 “다시 시도”로 변경했다. Client의 서버 상태 확인 버튼은 기존 동작을 유지한다.

## 시험 명령과 결과

지정된 `~/development/flutter-3.47.5/bin/flutter`만 사용했다. 원본 SDK 캐시가 읽기 전용이라 작업 폴더의 `build/flutter-cache` 복사본을 실행 중 해당 캐시 경로에 연결했다. 실제 원본 SDK는 수정하지 않았다. 임시 파일·Dart 설정·pub active_roots도 작업 폴더 안으로 연결했다. 의존성은 `pub get --offline`으로 준비했다.

```sh
bash build/run-flutter-252.sh pub get --offline
bash build/run-flutter-252.sh analyze --no-pub
bash build/run-flutter-252.sh test --no-pub --reporter expanded
```

- `pub get --offline`: 성공, 패키지/버전 파일 변경 없음.
- `flutter analyze --no-pub`: **No issues found**, 종료 코드 0 (`build/analyze-252.log`).
- 표준 전체 `flutter test`: **환경 차단**. 테스트 통신용 `127.0.0.1:0` 서버 소켓 생성이 `Operation not permitted`로 거절되어 시험 본문에 진입하지 못함 (`build/full-test-252.log`). 전체 통과로 보고하지 않는다.
- 원격 서버·실계정·live stack 시험: **NOT_RUN** (요청 범위 밖).

소켓을 사용하지 않는 보조 검증은 같은 SDK의 `frontend_server`와 `flutter_tester`, 기존 `test_api`/`test_core.Engine`으로 원래 시험 파일을 하나씩 선언·실행한다. 파일마다 별도 Flutter 프로세스를 사용하며 setUp/tearDown, 위젯 렌더, skip, timeout, assertion을 유지한다. 테스트 본문을 대체하거나 실패를 건너뛰지 않는다. 표준 CLI 통과와 구분한다.

```sh
python3 build/socketless-252/resident.py
```

보조 전체 실행 및 마지막 수정 파일 재실행을 합친 **최종 고유 결과**는 265개 파일 중 264개 정상 종료, **2,685건 통과 / 24건 건너뜀 / 1개 파일 환경 차단**이다. 건너뜀은 기존 시험의 조건을 그대로 따른 결과이며 live stack 3건, 폰트 조건이 맞지 않는 골든 4건 등이 포함된다. 실패를 성공이나 건너뜀으로 바꾸지 않았다.

- 환경 차단: `test/services/api_service_db_download_test.dart:181`의 실제 로컬 서버 소켓 생성. `Operation not permitted`로 파일 실행이 종료되었으므로 이 파일은 통과 건수에 포함하지 않았다.
- 5만 건 성능 시험 `test/services/plate_group_performance_test.dart`: 1건 통과(보조 전체 실행, 8.5초). 시간 초과가 없어 별도 재실행은 필요하지 않았다.
- 보조 실행에서 드러난 기존 Client 배너 시험의 `SharedPreferences` 모의 객체 누락을 보완하고 해당 2건을 재실행하여 통과했다. 앱 로직은 바꾸지 않았다.
- 이번 수정 관련 최종 회귀: 아래 9개 파일 **175건 통과**. 마지막 HTTP 분류·진단 보존 보강 및 배너 시험 수정 후 7개 파일을 재실행했다.

| 시험 파일 | 최종 통과 건수 |
|---|---:|
| `manifest_recovery_test.dart` | 19 |
| `rebuild_state_test.dart` | 37 |
| `rebuild_background_runner_test.dart` | 9 |
| `integration_contract_test.dart` | 20 |
| `rebuild_scope_generation_test.dart` | 5 |
| `rebuild_fresh_install_test.dart` | 9 |
| `community_rebuild_screen_test.dart` | 38 |
| `standalone_rebuild_background_test.dart` | 36 |
| `client_waiting_banner_test.dart` | 2 |

추가 재실행 명령:

```sh
python3 build/socketless-252/resident.py \
  test/community/manifest_recovery_test.dart \
  test/community/rebuild_state_test.dart \
  test/community/rebuild_background_runner_test.dart \
  test/community/integration_contract_test.dart \
  test/widgets/community_rebuild_screen_test.dart \
  test/widgets/standalone_rebuild_background_test.dart \
  test/widgets/client_waiting_banner_test.dart
```

증거: `build/socketless-252/full-resident-summary.log`, `final-targeted-summary.log`, `final-results.json`, 파일별 `*.resident.log`. 표준 시험 실패 로그와 보조 시험 결과는 별도 보존했다. `Runtime stages buffer failed verification`은 발생하지 않았다. `git diff --check` 통과, `VERSION`·`pubspec.yaml`·`pubspec.lock` diff 없음.

## 남은 위험과 검증 범위

- 표준 `flutter test`의 전체 통과 확인은 로컬 소켓을 허용하는 실행 환경에서 다시 해야 한다. 실기기 Android 백그라운드 유지·복귀 및 실제 서버 인증 흐름은 검증하지 않았다.
- 재시도 타이머는 기존 앱 실행기에 속한다. 앱 프로세스가 종료되면 다음 실행 때 저장된 작업을 재개한다. Android가 프로세스를 중지한 동안 15초 간격 실행을 보장하는 새 서비스는 추가하지 않았다.
- 기존 `CloudAvailability`의 서비스 공통 쿨다운을 유지한다. 5분 이내로 복구 판정을 다시 하더라도 공통 쿨다운/서버 점검 중에는 실제 HTTP 요청이 더 늦어질 수 있다. 업로드 잠금 경합 자체는 쿨다운을 만들지 않는다.
- 한 번의 목록 조회가 끝날 때까지 기존 업로드 잠금과 범위 검증을 유지한다. 무결성 실패에 대해서는 자동 성공·검사 생략·기존 완료 목록 삭제로 우회하지 않는다.
- 다른 기기로부터 업로드를 가져오는 동작은 사용자가 “이 기기로 업로드 전환”을 눌렀을 때만 실행한다. 실패하면 수집을 시작하지 않는다.

## A 이슈 12번

### 판단과 구현

지시서의 공식 사이트 실측 결과를 기준으로 수정했다. 실제 코드는 비밀번호만 FlutterSecureStorage에, 토큰은 SharedPreferences에 보관하고 있었다. 따라서 토큰·JSESSIONID·WMONID·계정·만료·세대를 **하나의 보안 저장소 항목 `official_session_v1`**으로 묶었다. 토큰과 쿠키를 서로 다른 로그인에서 조합하지 않는다. 새 저장 성공 뒤 구버전 평문 토큰·만료·계정 키를 제거한다.

RSA 응답의 JSESSIONID·WMONID를 토큰 요청에 보내며 토큰 응답의 Set-Cookie를 우선 반영한다. 인증 API는 항상 이 세션의 Bearer와 Cookie를 함께 보낸다. Set-Cookie의 Expires 쉼표·쿠키 삭제를 처리하고, 현재 계정·세대·토큰·요청 당시 쿠키와 일치할 때만 갱신한다. 이전 계정이나 로그아웃 전 응답은 적용하지 않는다.

쿠키 없는 저장 토큰은 유효한 세션으로 인정하지 않는다. 저장된 아이디/보안 비밀번호로 첫 인증 API 요청 전에 재로그인한다. 포그라운드·WorkManager 로그인 점검·알림/동기화의 API가 같은 저장소를 읽고 설정은 매번 reload한다. Client/데모로 바뀐 뒤 자동 로그인이 시작되거나 저장되는 것도 막는다. 계정 전환 때 이전 계정 세션을 삭제하되, 이미 새 계정으로 로그인한 세션은 보존한다.

공식 API의 401은 재로그인 후 **요청 한 번만** 재시도한다. 새 세션 수명이 짧아 5분 갱신 여유에 걸려도 두 번째 재로그인을 추가하지 않는다. 재시도도 401이면 `OfficialSessionRejectedException.code == official_session_rejected`이며, 기기 로그에는 상태·재시도 횟수·응답 형식·이 코드만 남긴다. 로그인 오류 응답과 네트워크 예외 원문을 UI/로그에 그대로 전달하지 않는다. 인증 요청의 자동 리다이렉트도 막았다.

| 인증 요청 조사 결과 | 처리 |
|---|---|
| `StandaloneApiService` 목록·건수·상세 조회 | 공통 세션 헤더 + 응답 쿠키 갱신 + 401 한 번 재시도 |
| `ReportDetailSheet`의 공식 사진 인증 fallback | 공개 사진을 익명으로 먼저 읽는 기존 동작 유지. 401/403으로 인증이 필요하면 공통 API 경로에서 읽고 메모리 이미지로 표시 |
| 만족도 점수·사유·제출 | 기존 코드에서 Authorization을 보내지 않는 공개 API. 전화번호/신고번호 계약과 제출 1회 원칙 유지 |
| 보완 내역 | 공식 상세 응답을 통해 수집. 별도 인증 HTTP 경로 없음 |
| 공개 통계·일반 첨부 | Authorization 없는 경로 유지 |
| 커뮤니티 서버·Client 서버의 Authorization | 공식 사이트 토큰과 별개. 공식 쿠키를 보내지 않음 |

### 바꾼 파일·줄

| 위치 | 변경 |
|---|---|
| `lib/services/official_session.dart:5` | 보안 세션 모델, 허용 쿠키 두 종류, 병합·삭제·Set-Cookie 파싱 |
| `lib/services/standalone_auth_service.dart:45`, `:155`, `:419`, `:465`, `:518` | 별도 세션 거절 예외, 실제 로그인 쿠키 수집, 원자적 보안 항목 저장, 계정/모드/세대 검사, 자동 이행 |
| `lib/services/standalone_auth_service.dart:556` 부근 | 다른 계정 세션 제거, 로그아웃 세션·비밀번호 삭제 및 epoch 변경 |
| `lib/services/standalone_api_service.dart:193`, `:216` | 모든 인증 GET 헤더, 응답 쿠키 반영, 안전한 401 재시도·진단 |
| `lib/providers/report_provider.dart:1229`, `:1311` 부근 | Standalone→Client 전환 시 삭제, 계정 변경 시 새 계정 세션 보존/옛 계정 세션 삭제 |
| `lib/widgets/report_detail_sheet.dart:1312`, `:1350`, `:1459` | 사진의 저장 토큰 직접 전송 제거, 공통 인증 경로·메모리 이미지 사용 |
| `test/services/official_session_test.dart:1` | 로그인 함수를 바꾸지 않고 RSA/토큰 요청·쿠키·실제 API 헤더 검사, 수명·401·오류 비밀값·계정/모드·백그라운드 회귀 |
| `test/services/standalone_auth_relogin_test.dart:1`, `test/services/background_login_check_test.dart:1` | 기존 테스트의 보안 세션 fixture 및 안전한 오류 문구 반영 |
| `test/widgets/report_photo_auth_test.dart:1` | 익명→인증 요청의 토큰/쿠키, 새 로그인, 외부 호스트 차단 검사 |
| `docs/architecture/data-contracts.md`, `android-runtime.md` | 옛 SharedPreferences 토큰 설명을 코드와 대조 정정 |

### 새 문구

| 상황 | 문구 |
|---|---|
| 재로그인 후 API 401 | 안전신문고가 로그인을 받아 주지 않습니다. 잠시 뒤 다시 시도해 주세요. |
| 로그인 응답/세션 확보 실패 | 안전신문고 로그인을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요. |
| 인증 GET 연결 실패 | 안전신문고에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요. |
| 실제 로그인 자격증명 거절 | 안전신문고가 로그인을 거부했습니다. 아이디와 비밀번호를 확인하고 설정 > 재로그인에서 다시 로그인해 주세요. |
| 계정·모드 변경 중인 요청 | 로그인 설정이 변경되었습니다. 다시 확인해 주세요. |

`TokenExpiredException`은 저장된 자격증명이 없거나 실제 로그인 거절일 때만 기존 수동 로그인 경로로 사용한다. API의 재시도 401을 “만료”로 바꾸지 않는다.

### 시험 명령·결과

```sh
python3 build/socketless-ac-252/resident.py \
  test/services/official_session_test.dart \
  test/services/standalone_auth_relogin_test.dart \
  test/services/background_login_check_test.dart \
  test/widgets/report_photo_auth_test.dart
```

같은 Flutter 3.47.5 엔진의 소켓 없는 보조 실행: 공식 요청 형식 11건, 기존 자동 재로그인 9건, 백그라운드 점검 4건, 사진 6건 **총 30건 통과**. 계정/모드 전환 관련 기존 저장소·설정·B 범위 시험은 마지막 변경 후 추가 확인했다. 전체 결과와 표준 CLI 제한은 아래 공통 검증 절에 기록한다.

### 검수자 확인 필요 — 에뮬레이터·실기기

- 기존 2.5.1 데이터·저장 계정을 유지해 업데이트한 후, 별도 재로그인 조작 없이 동기화 첫 목록 요청이 성공하는지 확인한다.
- 실제 RSA/토큰 응답의 JSESSIONID 회전과 선택 WMONID가 보안 세션에 반영되는지 확인한다. 진단 화면·로그·버그 보고서에 실제 비밀값을 복사하지 않는다.
- 목록·상세·인증이 필요한 사진, 전체 동기화, B의 다시 불러오기를 각각 확인한다. 공개 만족도/별점 제출의 기존 동작은 테스트 계정에서 별도 확인한다.
- 앱을 종료·재실행하고 WorkManager 점검/알림 엔진을 실행하여 같은 세션을 읽는지 확인한다.
- 토큰/쿠키 만료·서버 재거절 상황에서 재로그인과 요청 재시도가 한 번씩 이루어지고 새 안내가 나타나는지 확인한다.
- 로그아웃·다른 공식 계정 로그인·Client/데모 전환 후 예전 계정 세션이 남거나 늦은 백그라운드 응답으로 되살아나지 않는지 확인한다.

실제 공식 사이트 왕복과 Android 보안 저장소/OS 작업 실행은 **NOT_RUN**이다. 앱 내 single-flight는 isolate별이며 서로 다른 엔진의 동시 재로그인까지 직렬화하는 새 전역 잠금은 추가하지 않았다. 영속 계정·모드·epoch 및 요청 세션 대조로 오래된 자료 사용을 막는다.

## C 이슈 11번

### 판단과 구현 — 1~10항

| 항목 | 구현·판단 |
|---|---|
| 1 | 상세 검색 화면과 같은 순서/라벨: 신고번호 → 과태료/범칙금 → 별점 → 보완횟수 → 신고일 → 발생일 → 답변일 |
| 2 | 검색 조건 칩 아래, 카드 목록/페이지 건수 줄 바로 위 오른쪽에 작은 현재 정렬 버튼을 배치. 앱바 검색·설정·탭을 밀어내지 않고 목록을 보며 바로 바꿀 수 있게 했다. 기존 Material 테마의 버튼·시트·라디오·칩을 사용 |
| 3 | SQL NULL을 양방향 모두 마지막으로, 동률은 `신고번호 DESC, ID DESC`. 별점 0은 미부여, 보완횟수 0은 유효 값이며 NULL과 구분. 금액은 기존 확정 금액 파서만 사용 |
| 4 | 기본값은 기존 신고번호 내림차순. `report_sort:<mode>:<tab>`으로 기억. 필터와 결합하고 변경 시 페이지 0/스크롤 0으로 복귀. Standalone은 DB에서 정렬 후 LIMIT |
| 5 | 연결·revision별 TEMP 정렬값/7개 보조 인덱스. 1,000행씩 준비하고 쓰기 후 캐시 재구성. 5만 건의 모든 기준·방향을 예산 시험 |
| 6 | 현재 기준·화살표 및 `정렬: 답변일, 최신순/오래된순` 등의 읽기 라벨. 접근성 탭 동작·48dp 지침 검사 |
| 7 | SQL 결과 7×2, 값 없음/동률/필터/캐시 갱신/Client 전체 페이지 정렬, 위젯 선택·기억·복원·스크롤 시험 |
| 8 | 요청한 사용자 문구를 `docs/releases/unreleased.md`에 추가 |
| 9 | 중복차량은 중복횟수를 맨 앞에 추가. 기존 카드의 전체 횟수로 정렬하며 검색으로 일부 카드가 숨겨져도 전체 횟수는 유지 |
| 10 | 필터에 맞는 묶음 카드의 MIN(오름)/MAX(내림) 대표값으로 묶음 정렬, 같은 기준/방향으로 내부 카드 정렬. 전부 값 없는 묶음은 마지막. 동률은 필터 전 기존 묶음 순서. Standalone은 20개 **차량 묶음** 단위 페이지, Client 기존 전체 목록도 묶음을 유지 |

Client 일반 목록은 기존 서버 계약에 정렬 파라미터가 없어, 기본값은 기존 페이지/검색 경로를 유지하고 선택 정렬은 서버의 마지막 페이지까지 읽은 카드 값을 독립적인 임시 SQLite에 넣어 정렬한다. 첫 페이지만 정렬하지 않는다. 한 번 완성한 자료는 기준·방향 변경에 재사용하고 필터·자료 revision·계정·화면 수명이 바뀌면 폐기한다. 개인/교환 DB 스키마·원본 값·서버 계약은 변경하지 않았다.

중복차량은 기존 행 단위 페이징이 묶음을 자를 수 있었으므로 카드 화면에서 `groupPage:true`를 사용한다. 기존 내부 행 페이지 호출은 호환 유지했다. 페이지 건수는 이 화면에서 “차량 묶음” 단위라고 명시한다. Client 중복차량은 원래 전체 목록이므로 페이지를 새로 자르지 않는다.

### 바꾼 파일·줄

| 위치 | 변경 |
|---|---|
| `lib/models/report_sort.dart:3`, `:20`, `:71`, `:129` | 기준·방향·설정 직렬화, 정렬값, Client 묶음 대표값/내부 정렬 |
| `lib/models/report.dart:70`, `:124`, `:225`, `:297` | 보완횟수 NULL과 실제 0 구분을 모델/복사에서 유지 |
| `lib/services/report_sort_store.dart:9`, `:19`, `:37`, `:84` | TEMP 정렬 테이블·인덱스와 Client 전체 페이지의 임시 SQLite 정렬 |
| `lib/services/local_db_service.dart:2430`, `:2588`, `:2659`, `:2746` | 일반 정렬 SQL, revision 캐시, 그룹 대표값 CTE·그룹 단위 LIMIT 및 카드 정렬 |
| `lib/widgets/report_sort_button.dart:4` | 스크롤 가능한 선택 시트, 방향 칩, 읽기 라벨/탭 동작 |
| `lib/widgets/local_paged_report_list.dart:37`, `:63`, `:166`, `:273`, `:410` | 정렬 전달·snapshot 수명·페이지/스크롤 복원·묶음 페이지 표기 |
| `lib/screens/report_list_screen.dart:71`, `:96`, `:192`, `:398`, `:460` | 모드/탭별 기억, 목록 위 버튼, Client 중복 필터·묶음 정렬 |
| `test/services/report_sort_test.dart:1` | 32건: 7×2 일반/Client, 8×2 그룹, 기본값·필터·기억·revision 갱신 |
| `test/services/report_sort_performance_test.dart:1` | 5만 건에서 30가지 쿼리(일반 14 + 그룹 16) 예산 |
| `test/widgets/report_sort_button_test.dart:1`, `report_sort_paging_test.dart:1` | 360dp·라이트/다크·글씨 1/2배·접근성·저장/복원·실제 페이지/스크롤 복귀 |
| `test/widgets/tap_target_guideline_test.dart:55` 부근 | 정렬 기억을 읽는 화면에 맞춰 설정 저장소 모의 객체 초기화 |
| `docs/architecture/bounded-reads.md` | 정렬·Client 전체 후보 준비·묶음 페이지의 코드 대조 정정 |

### 새 문구

| 위치 | 문구 |
|---|---|
| 기본 버튼 | 신고번호 ↓ |
| 선택 버튼 예 | 답변일 ↑ / 중복횟수 ↓ |
| 시트 | 신고내역 정렬 / 오름차순 / 내림차순 / 적용 |
| 접근성 예 | 정렬: 신고번호, 내림차순 / 정렬: 답변일, 오래된순 |
| 묶음 페이지 예 | 전체 10개 차량 묶음 · 1 / 1 페이지 |
| 릴리스 노트 | 신고내역을 신고번호·과태료·별점·보완횟수·신고일·발생일·답변일로 정렬하고, 오름차순과 내림차순을 고를 수 있습니다. |

### 시험 명령·결과

```sh
python3 build/socketless-ac-252/resident.py \
  test/services/report_sort_test.dart \
  test/services/report_sort_performance_test.dart \
  test/widgets/report_sort_button_test.dart \
  test/widgets/report_sort_paging_test.dart \
  test/widgets/tap_target_guideline_test.dart
```

보조 실행에서 정렬 SQL/묶음 32건, 5만 건 예산 1건, 버튼·기억·접근성 5건, 페이지/스크롤 복귀 1건, 기존 접근성 지침 5건이 통과했다. 기존 상세 검색 드릴다운 9건과 페이지 미리 받기 1건도 전체 실행에서 통과했다.

5만 건 단독 측정: 첫 정렬값/인덱스 준비 포함 일반 쿼리 2,429ms, 이후 일반 쿼리 45~381ms. 첫 그룹 조회 1,265ms, 이후 그룹 조회 223~340ms. 30개 조합 모두 쿼리당 5,000ms 미만. 기존 `plate_group_performance_test.dart`도 전체 보조 실행에서 통과했다. 숫자는 이 호스트의 시험 자료 기준이며 실제 Android 성능 보장은 아니다.

### 검수자 확인 필요 — 에뮬레이터·실기기

- 업데이트 직후 6개 탭의 기본 순서가 이전과 같은지, 목록 바로 위 버튼을 쉽게 찾을 수 있는지 확인한다.
- 불수용 필터 + 답변일 양방향, 날짜 없는 신고가 뒤에 오는지 확인한다. 같은 값의 신고 순서가 재조회/페이지 이동에도 유지되어야 한다.
- 과태료/범칙금의 알려진 금액과 금액 미확인, 별점 미부여, 보완횟수 실제 0을 구분해서 확인한다.
- 앱 재시작·탭 전환·모드 전환에서 정렬 기억이 해당 모드/탭에만 적용되는지, 선택 변경 시 맨 위/첫 페이지로 가는지 확인한다.
- 중복차량의 8개 기준 양방향에서 묶음 전체 이동, MIN/MAX 대표값, 내부 카드 순서, NULL 묶음 후순위, 동률 기본 순서를 확인한다.
- 20번째/21번째 차량 경계에서 묶음이 잘리지 않는지 확인한다. 검색으로 일부 카드가 숨겨져도 카드의 전체 중복횟수와 정렬 기준은 일치해야 한다.
- Client에서 마지막 서버 페이지에만 있는 큰/작은 값도 첫 정렬 결과에 반영되는지, 준비 중 화면 이탈/필터 변경 때 이전 결과가 섞이지 않는지 확인한다.
- 360dp·글씨 2배·라이트/다크·TalkBack에서 버튼/시트 내용 잘림, 읽기 라벨과 탭 실행, 하단 시스템 UI와 겹침을 확인한다.
- 실제 5만 건 기기에서 최초 준비 지연·스크롤 반응·메모리를 확인한다. 매우 큰 단일 차량 묶음은 요구사항에 따라 쪼개지 않으므로 일반 200행 페이지 상한보다 클 수 있다.

Client 최초 선택 정렬은 전체 목록을 받아야 하므로 서버 응답 시간의 영향을 받는다. 기존 서버 계약을 바꾸거나 부분 목록을 전체 정렬처럼 표시하는 방법으로 우회하지 않았다.

### A·C 공통 최종 검증

- 지정된 Flutter 3.47.5의 `flutter analyze --no-pub`: **No issues found**, 종료 코드 0 (`build/analyze-ac-252.log`).
- 표준 `flutter test --no-pub --reporter expanded`: 로컬 테스트 통신 서버 소켓(`127.0.0.1:0`) 생성이 `Operation not permitted`로 차단되어 270개 파일이 로딩 단계에서 실패했다 (`build/full-test-ac-252.log`). **표준 전체 통과를 확인한 것으로 보고하지 않는다.**
- 같은 SDK의 `flutter_tester`·기존 `test_api/test_core`를 쓰는 소켓 없는 파일별 보조 실행: **270개 중 269개 파일 정상 종료, 2,735건 통과·24건 기존 조건에 따른 건너뜀, 1개 파일 환경 차단**. 전체 실행 후 마지막 수정 파일의 재실행으로 결과를 갱신한 고유 집계다.
- 남은 환경 차단은 기존 `test/services/api_service_db_download_test.dart:181`의 실제 로컬 소켓 시험이다. 이 파일은 통과 집계에 넣지 않았다. 테스트를 지우거나 건너뜀으로 바꾸지 않았다.
- 기존 `plate_group_performance_test.dart` 및 새 5만 건 모든 정렬 예산 시험은 전체 보조 실행에서도 통과했다. `Runtime stages buffer failed verification`은 발생하지 않았다.
- B의 원인별 목록 요청·상태기계·자동 재개·화면 회귀와 계정 범위 회귀도 통과했다. B의 상태기계·완료 목록 무결성 코드는 이번 A·C 작업에서 변경하지 않았다.
- 새 정렬 기억 기능 때문에 기존 접근성 시험도 설정 저장소를 읽게 되므로 해당 fixture에 `SharedPreferences.setMockInitialValues({})`를 추가했다. 기존 접근성 검사 5건을 재실행하여 통과했다.
- `git diff --check` 통과. `VERSION`·`pubspec.yaml`·`pubspec.lock` 변경 없음. 커밋·push·원격 서버 접근·배포 없음. 원래 SDK/다른 프로젝트를 쓰기 대상으로 사용하지 않았으며 캐시·임시 파일은 작업 폴더 안에 두었다.

```sh
bash build/run-flutter-252.sh analyze --no-pub
bash build/run-flutter-252.sh test --no-pub --reporter expanded
python3 build/socketless-ac-252/resident.py
# 마지막 계정 전환 관련 재실행
python3 build/socketless-ac-252/resident.py \
  test/services/official_session_test.dart \
  test/storage/official_account_binding_test.dart \
  test/storage/known_defects_test.dart \
  test/providers/report_provider_capabilities_test.dart \
  test/widgets/setup_pending_db_import_test.dart \
  test/community/rebuild_scope_generation_test.dart \
  test/community/single_login_test.dart
```

증거: `build/socketless-ac-252/full-summary.log`, `final-targeted-summary.log`, `last-sort-summary.log`, `account-final-summary.log`, `final-results.json` 및 파일별 `*.resident.log`. 실행기는 기존 B 검증과 같은 방식이며 파일마다 별도 Flutter 프로세스로 원래 시험 본문을 실행한다. 실서버/실계정·실기기 확인은 위 A·C 목록에 따라 검수자가 수행해야 한다.
