# 데이터 계약·서버/DB·인증·집계 함정

> 이관 원본: 루트 `CLAUDE.md` (sha256 `32e8f475…9481`, 마지막 변경 커밋 `161b68dc`), 2026-09-24 분할.
> 본문은 원문을 **그대로** 옮겼다. 코드와 달라진 부분은 아래 "코드 대조 정정"에만 적고 원문은 고치지 않았다.
> 원본 전체 사본: [legacy-claude-reference.md](legacy-claude-reference.md) · 제목별 대응표: [README.md](README.md)

## 코드 대조 정정 (2026-09-24, base `c64be69a`)

대용량 SQL/페이지·revision 캐시, protocol 3, 키보드 사유 입력 및 공유 DB 저장의 현재 구조는 [bounded-reads.md](bounded-reads.md)를 우선한다. Client의 추가 서버 계약은 [client-read-handoff.md](client-read-handoff.md), 실행 증거/한계는 [검증 기록](../reviews/2026-10-03-runtime-validation.md)을 따른다.

| 원문 기술 | 현재 코드 | 근거 |
|---|---|---|
| SQLite `version 8`, 보완 요약 4컬럼 | **version 10**, 보완 컬럼 7개(`보완횟수`, `보완_미응답`, `보완_요청자`, `보완_요청일시`, `보완_완료일시`, `보완_요청_내용`, `보완_신고자_의견`) | `lib/services/local_db_service.dart:62,111-113,216` |
| errno=104 매트릭스의 "silent 3회 retry", Standalone API "최대 3회 재시도" | 공용 상수 `mobileMaxRetryAttempts = 5`, `mobileRetryDelaySeconds = 1` (같은 문서의 "설정 기본값 / 재시도 정책" 절과 일치) | `lib/services/network_retry_config.dart` |
| "Client 일반 API retry 없음" | 이번 단계 미재확인 → **미검증** | — |
| 위반법규 파싱 (2026-09-27) | Standalone은 최신 처리내용에서 `도로교통법 제N조`와 `「자동차관리법」제29조`처럼 꺾쇠 안에 법 이름이 있는 조문을 읽는다. 법 이름·조·항 사이 공백을 허용하고 저장값은 공백을 정리한다. 서버와 합성 입력 계약을 공유한다. | `lib/services/standalone_parser.dart`, `contracts/parser-vectors.json` |

### 이번 대조에서 새로 발견한 집계 주의점 (코드 미수정, 통계 사양에서 다룸)
- Standalone `excludeWithdraw` 필터가 SQL `처리상태 != '취하'` 라서 `처리상태` 가 NULL 인 행도 함께 빠진다. → `local_db_service.dart:871-873`
- 평균 처리일: 서버는 음수 일수 제외(`days >= 0`) + 소수 1자리 반올림, Standalone `_AgencyAgg` 는 음수 포함·반올림 없음. 모드 간 값이 다를 수 있다. → 서버 `services/report_stats_service.py:501-508`, 모바일 `local_db_service.dart` `_AgencyAgg.add/toJson`
- `avg_days` 의 표본수(유효 답변 건수)가 payload 에 없다 → 기관 평균을 합쳐 전체 평균을 만들 수 없다. 상세: `docs/design/statistics-spec.md`

---

## Client 서버 계약 단일 소스

Client 모드 서버 경로와 이벤트 문자열은 Flutter/Dart 와 Android/Kotlin 에서 각각 한 곳에 모아둔다.

- Dart: `lib/services/server_contract.dart`
  - `/api/v1` prefix, `X-API-Key`, `/ws/events`, `api_key`
  - `summary`, `reports/{category}`, `stats`, `watchlist`, `crawl/*`, `settings/db`, `rating/start`, `files/download`, `server/version`, `sunwi/*`
  - `apiUri()`, `apiHeaders()`, `wsEventsUri()` 로 URI/헤더 구성
- Kotlin: `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerContract.kt`
  - `API_PREFIX`, `API_KEY_HEADER`, `WS_EVENTS_PATH`, `WS_API_KEY_QUERY`
  - `EVENT_CONNECTED`, `EVENT_PING`, `EVENT_CRAWL_STARTED`, `EVENT_CRAWL_FINISHED`, `EVENT_CRAWL_CHANGES`
  - `CRAWL_ENQUEUE_PATH`, `apiUrl()`, `wsEventsUrl()`

원칙:
- Client 모드 관련 문자열을 화면/서비스에 직접 하드코딩하지 않는다.
- 서버 경로를 바꿀 때는 Dart/Kotlin 계약 파일부터 수정하고, 그 다음 호출부를 따라간다.
- 서버 리팩토링이 내부 구조만 바꾸는 경우에도, 모바일 Client 모드는 위 계약이 유지되는지 먼저 확인한다.

## Standalone 중복 projection

- Standalone 모드는 서버의 `duplicate_group_service.py` 를 그대로 공유하지 못하므로,
  `lib/services/duplicate_projection_service.dart` 에서 로컬 SQLite 기준 중복군 계산을 별도로 유지한다.
- source of truth 는 `report_raw.raw_content` 이다.
  - `raw_content` normalize → payload hash
  - 같은 hash 가 2건 이상이면 중복군 후보
- 중복 상태는 세 가지다.
  - `review_required`
  - `confirmed_duplicate`
  - `not_duplicate`
- 대표건 모드는 두 가지다.
  - `auto`: refresh 때마다 우선순위로 재선정
  - `manual`: 사용자가 고른 대표건 유지
- 모바일 중복 신고 관리 패널에서는 child를 직접 고르면 대표건 모드를 즉시 `manual` 로 전환한다.
  서버 저장 로직도 동일하게 auto 추천값과 다른 child를 저장하려는 경우 `manual` 로 승격시킨다.
- 로컬 projection 규칙:
  - `confirmed_duplicate` 만 canonical collapse 대상
  - `review_required` 와 `not_duplicate` 는 child 전체 유지
- `LocalDbService` 의 요약/목록/검색/통계는 `useRepresentativeRecords` 플래그를 받아
  raw 또는 canonical projection 을 선택한다.

## 설정 기본값 / 재시도 정책

- 모바일 공용 재시도 횟수는 `lib/services/network_retry_config.dart` 의 `mobileMaxRetryAttempts = 5` 가 단일 소스다.
- 다음 경로가 이 상수를 공유한다.
  - `ApiService`
  - `StandaloneApiService`
  - `StandaloneAuthService`
  - `SetupScreen` 서버 연결 테스트
  - `FileBrowserScreen` 다운로드
- 설정 기본값:
  - `auto_export_sheet = false`
  - `use_representative_records = true`

## 중복 변경 알림 흐름

- 서버/Standalone 중복군 재계산에서 `notification_kind=duplicate` 변경이 나오면:
  - `sync_engine.dart` / `standalone_auto_sync_service.dart` 가 pending changes 에 합친다.
  - `NotificationHistoryProvider` 가 신고 결과 탭 히스토리로 적재한다.
  - `MainActivity` / `WsService` 는 Android 알림 intent 에 `payload_json` 을 함께 싣는다.
- 사용자가 푸시나 앱 내 알림을 눌렀을 때:
  - `main.dart` 가 `payload_json` 을 읽어
  - `duplicate_group_detail_sheet.dart` 로 바로 상세를 연다.
- 일반 신고 변경과 중복군 변경은 같은 신고 결과 탭을 공유하지만,
  `NotificationItemKind.duplicate` 로 구분해 아이콘/상세 시트를 다르게 처리한다.
- 일반 신고 결과(`notification_kind != duplicate`) 읽음 상태 규칙:
  - `NotificationHistoryProvider` 는 `신고번호`를 trim + upper-case 한 값으로 읽음 상태를 공유한다.
  - 푸시 알림, foreground SnackBar, 대기 변경(`inbox.pending.*`) 카드 시트, `신고 결과` 탭이
    같은 `report_detail` 을 열면 같은 신고번호의 일반 알림은 모두 읽음 처리한다.
  - 중복군 알림은 `duplicate_group_detail_sheet` 를 쓰므로 이 신고번호 공유 읽음 규칙에 포함하지 않는다.

## Client 중복 신고 API 호환성

- Client 서버가 아직 `/api/v1/duplicates/groups` 를 제공하지 않는 구버전일 수 있다.
- 이 경우 모바일은 `404`를 치명 에러로 취급하지 않고,
  `DuplicateManagementScreen` 에서 “서버가 중복 신고 관리 API를 아직 지원하지 않습니다.” 안내와 빈 상태를 보여준다.
- Standalone 모드는 HTTP가 아니라 로컬 SQLite projection 을 읽으므로 같은 `404` 증상은 발생하지 않는다.

## Standalone 인증 아키텍처

`lib/services/standalone_auth_service.dart`

### 로그인 흐름 (`dart:io HttpClient` + 명시적 세션 쿠키 전달)

```
1. GET /api/v1/common/rsa/getPublicKey → RSAModulus + RSAExponent (hex)
   ↳ 서버가 Set-Cookie: JSESSIONID=xxx, 응답 쿠키에서 JSESSIONID 수동 추출
2. password (UTF-8 bytes) → PKCS1 v1.5 RSA 암호화 (pointycastle) → hex 문자열 (512자)
3. POST /oauth/token (form-urlencoded)
   ↳ 토큰 요청 cookies에 JSESSIONID 명시적 추가 (서버가 RSA 키를 세션에 바인딩)
   ↳ client_id=web, grant_type=password, loginType=1, username, password(hex)
   → { access_token: "eyJ...", expires_in: 3599 }
```

**왜 `dart:io HttpClient` 인가**: `package:http` 의 정적 메서드는 매 호출마다 별도 클라이언트 → 쿠키 공유 안 됨. `login()`은 RSA 응답의 JSESSIONID를 읽어 토큰 요청에 직접 추가한다. 자동 쿠키 보관을 계약으로 가정하지 않는다. 네트워크 재시도마다 소유한 연결을 닫고, 인증 응답은 1MiB 이내에서 읽는다.

### Demo 보기 (Play Console 검토에도 사용)

- 첫 모드 선택 화면의 `Demo 보기`를 누르면 카카오·안전신문고 계정 없이 들어간다. 기존 `demo/demo` 로그인도 같은 경로를 유지한다.
- `LocalDbService.seedPlayReviewDemo()` 가 별도 `standalone_reports_demo.db`를 비우고 가상 신고 100건을 생성한다. 날짜·상태·카테고리·좌표·감시 목록을 섞어 실제 대시보드·신고내역·지도·통계 화면을 채운다. 실제 신고 원문·담당자·첨부 URL은 쓰지 않는다.
- `ReportProvider.isStandaloneDemo` true: 안전신문고 세션, keep-alive, 동기화, 별점 제출, 커뮤니티 업로드, WebSocket, 초기화 크롤링을 실행하지 않는다. 메인 탐색은 카카오 게이트 없이 허용한다.
- Play Console 앱 액세스 안내에는 `Open the app, tap Demo 보기 below Client and Standalone. No login is required.`라고 적으면 된다. 이 경로는 모든 사용자에게 보인다.

### 토큰 만료 + 자동 재로그인

- 만료 5분 전부터 무효 판단 → `StandaloneAuthService.relogin()` 호출
- `flutter_secure_storage` (Android Keystore 기반) 에 비밀번호 저장
- `StandaloneApiService._getWithRetry()`: 401 → 자동 재로그인 후 1회 재시도
- **2026-09-24 변경 (제보: 동기화 중 '토큰 만료')**
  - `relogin()` 은 한 번에 하나만 돈다(single-flight). `refreshSessionIfNeeded()` 도 진행 중인 재로그인을 기다린다.
    예전에는 진행 중이면 바로 돌아와 뒤따르는 동기화가 만료 토큰으로 시작하고 로그인이 겹쳤다.
  - 실패를 셋으로 나눈다: `noCredentials`(저장된 비밀번호 없음·보안 저장소 읽기 실패), `rejected`(HTTP 400/401 — RSA 세션 오류 제외),
    `transient`(네트워크·점검·5xx·비정상 응답, 1회 더 시도). 예전에는 모두 '토큰 만료'로 알렸다.
  - 예외: `rejected`/`noCredentials` → `TokenExpiredException`(재로그인 안내), `transient` → `AuthTemporarilyUnavailableException`(잠시 후 재시도).
    `login()` 자체는 `LoginRejectedException` / `AuthTemporarilyUnavailableException` 을 던진다.
  - 결과는 `standalone_auth_last_*` 키와 `StandaloneAuthService.status`(ValueNotifier)에 기록 → 대시보드·동기화 화면 '재로그인 필요' 경고(재로그인 필요할 때만),
    설정 계정 카드 '마지막 로그인' 줄. 백그라운드 isolate 결과는 앱 시작·복귀 때 `reloadStatus()` 로 반영.
  - `StandaloneAutoSyncService` drain 은 인증 실패 시 큐를 **보존**하고 멈춘다(예전엔 otherError 로 큐에서 지워 신고를 놓칠 수 있었다).
  - 테스트: `test/services/standalone_auth_relogin_test.dart`(실제 로그인 호출 없음, `loginOverride`).
- **하루 1회 백그라운드 로그인 점검** (`lib/services/background_login_check.dart`, `workmanager`)
  - 토큰은 1시간짜리라 주기 갱신은 의미가 없다. 대신 앱이 닫혀 있는 동안 비밀번호 변경·계정 잠김을 미리 알아채 알린다.
  - Standalone(데모 제외) 에서 등록, Client 전환·데모·초기화 때 해제. 24시간 주기, 첫 실행 6시간 뒤, 네트워크 연결·배터리 부족 아님 조건.
  - 살아 있는 토큰이 있으면 로그인하지 않는다. `rejected`/`noCredentials` 일 때만 `standalone_auth_alert` 키를 쓰고(72시간에 한 번),
    Kotlin `SafetyReportApplication` 이 알림을 띄운다(`docs/architecture/android-runtime.md`). 일시 오류는 조용히 다음 날.

### 자격증명 저장

| 항목 | 저장소 | 키 |
|------|--------|-----|
| access_token | SharedPreferences | `standaloneToken` |
| 만료 시각 (ms) | SharedPreferences | `standaloneTokenExpiresAt` |
| 비밀번호 | FlutterSecureStorage | `standalone_password` |
| 아이디 | SharedPreferences | `standaloneUsername` |
| 커뮤니티 계정 세션 (Supabase access/refresh token, 표시 이름) | FlutterSecureStorage | `community_session_v1` |
| 커뮤니티 로그인 대기 (PKCE verifier, 시작 시각) | FlutterSecureStorage | `community_pending_login_v1` |
| 커뮤니티 복귀 링크 소비 표시 (SHA-256) | FlutterSecureStorage | `community_consumed_callback_v1` |

FlutterSecureStorage는 BL-1에서 10.3.4 → **11.2.0**으로 올라간다. v9의 ESP/옛 cipher를 v11에서 이관할 수 없다.
`encryptedSharedPreferences` 매개변수만 제거하며 namespace·키·cipher는 유지한다.

- `secureStorageV10Migrated=true`: 기존 표시를 지우거나 다시 쓰지 않는다. 앱 시작 때 저장소 읽기를 검증한 뒤 기존 인증 흐름으로 간다.
- 표시가 없는 Android 기존 설치: 보안 저장소를 열기 전에 네이티브 `storedSecureEntries`로 키 개수만 센다(값·키 이름 출력 없음).
  저장 항목 또는 기존 앱 설정이 있으면 재로그인·커뮤니티 연결 재설정 안내를 띄우고 일반 시작을 막는다.
  복구 화면의 **저장된 로그인 정보 초기화하고 다시 로그인**에서 삭제·보존 범위를 확인하고 명시적으로 동의하면,
  Android 보안 저장소 플러그인 전용 preferences의 암호문·keyset·wrapped key·암호화 설정만 지운다. 신고 DB·앱 설정·커뮤니티 DB는 보존한다.
  초기화 후 빈 보안 저장소 읽기에 성공해야 `secureStorageV11Initialized`를 기록하고 `main()`의 정상 시작 흐름으로 돌아간다.
  카카오 로그인·연결 확인은 기존 게이트가 처리한다. v10 이관 표시를 위조하지 않으며 자동 초기화는 없다.
  초기화·읽기 실패 시 복구 화면에 남고 정상 시작을 호출하지 않는다.
- 빈 Android 신규 설치: 네이티브 저장 항목과 앱 설정이 모두 비어 있고 읽기가 성공한 때만
  별도 `secureStorageV11Initialized=true`를 쓴다. 신규 설치를 v10 이관 완료로 위장하지 않는다.
- Android 이외: 같은 Keychain 등 저장소 읽기를 확인하고 v11 준비 표시를 남긴다. iOS 실기기 확인은 별도다.
- 검사/읽기 예외는 `unavailable`로 분리해 오류 화면으로 보낸다. WorkManager는 두 준비 표시 중 하나가 있기 전에는 인증 접근을 하지 않는다.

**코드 대조 정정:** 이전 문서는 `resetOnError` 기본이 false라고 적었으나, 10.3.4와 11.2.0의 Dart
`AndroidOptions` 기본은 true이고 native에 전달된다(Java 자체 fallback은 false). 기본 옵션을 유지하면
플러그인이 오류 자료를 삭제한 뒤 null/빈 목록을 반환할 위험이 있다. 오류 시 자료 보존을 완전히 보장하려면
`resetOnError: false`의 명시가 필요하며, 브리프의 나머지 옵션 유지와 충돌하므로 사용자 확인 대상이다.

SQLite 파일·스키마·교환 값 계약은 바꾸지 않는다. Android 연결만 SQLite 3.53.4 번들로 바꾸며 기존 DB 디렉터리,
WAL, `user_version`, FTS3/4/5를 유지한다. 구버전 DB는 기존 `migrateInPlace`/`resetLegacyDatabase` 정책을 그대로 따른다
(구조 16→17은 제자리 변환, 더 오래된 DB는 일관 백업 후 기존 초기화 정책). 엔진 교체를 이유로 이 정책을 우회하거나
구버전 스키마를 현재 버전으로 표시하지 않는다. 네이티브 inbox는 교환 DB와 별개다. 엔진과 빌드 설정은
[Android 런타임](android-runtime.md#android-sqlite-번들-bl-1)을 따른다.

DB는 `openAppDatabase`를 통해 열며 `onConfigure`에서 다른 SQL보다 먼저 연결별
`busy_timeout`을 설정한다. 기본 5초, 기존 community DB·구버전 변환/초기화는 30초다.
신고 DB·community DB의 WAL을 유지하고 읽기 전용 사본·백업/복원·중복군 별도 연결에도
대기를 적용한다. 내보내는 portable 사본의 `journal_mode=DELETE`는 그대로 유지한다.
대기는 무한 재시도가 아니다. 대기 한도 초과와 SQLite의 교착 방지 오류는 호출자에게 전파한다
([SQLite busy handler](https://www.sqlite.org/c3ref/busy_handler.html)).
대시보드 트랜잭션에는 네트워크 호출이 없으며, 동기화는 페이지/개별 저장,
중복군 digest는 128행 단위다. 가져오기의 전체 복사 트랜잭션은 private staging 파일에만 쓴다.
구버전 변환/초기화는 일관 백업까지 원본 잠금을 보유하므로 데이터 규모·기기 속도에 따라
다른 연결의 대기 한도를 넘을 수 있다. 원자성·백업 무결성을 위해 임의로 분할하지 않는다.

커뮤니티 계정(카카오, Supabase Auth)은 안전신문고 계정과 별개다. Standalone 만 폰에 세션을 두고, Client 는 서버가 세션 주인이라 폰에 아무것도 저장하지 않는다.
토큰은 SharedPreferences·SQLite 에 넣지 않는다(DB 스키마 변경 없음). 자료 주인 카카오 회원번호만 `sync_meta['kakao_member_id']`(아래 2026-09-27 절). 흐름·서버 API(`/api/v1/community-auth/*`, capability `community_account`)는
[community-account.md](community-account.md).

커뮤니티 공유 사본 `community.db`(개인 DB 와 별도 파일, 서버↔모바일 교환 대상 아님 — PROJECT_RULES 3-1 무관): `meta.schema_version` **2**
(PC 와 같은 값). v2(2026-09-27) = 영속 전송 제어 `upload_control` 표 + `upload_runs.result` 결과 코드 확장(표 재생성·행 보존) + 인덱스.
v1 파일은 열 때 번호 단계(`_migrations`)로 올리며 앱·백그라운드 isolate 가 함께 열어도 한 번만 적용된다(지우거나 초기화하지 않음).
토큰 갱신 잠금은 이 파일의 `leases`(`auth_refresh`)를 쓴다(비밀은 저장하지 않음). 설명: [community-upload.md](community-upload.md).

## SQLite 스키마 (Standalone)

`lib/services/local_db_service.dart` — `standalone_reports.db`, version 8.

서버 DB 와 컬럼명 동일 (한국어). mobile-only 추가: `category`, `entry_value`, `raw_content`, `synced_at`.
2026-05-06부터 raw payload 의 정본은 `report_raw` 사이드카 테이블에 둔다.
2026-05-07부터 중복군 hash는 서버와 동일한 SHA-256 기준을 사용하고, version 7부터 `duplicate_group.apply_globally` 컬럼을 가진다.
version 8 부터 보완요청 마지막 round 요약 4컬럼(`보완횟수`, `보완_미응답`, `보완_요청_내용`, `보완_신고자_의견`) 이 `reports` 테이블에 들어간다. 잠시 존재했던 `report_supplement_history` 다회차 테이블은 `_addSupplementColumns()` 마이그레이션에서 DROP 처리된다.
version 16 부터 `처리기관코드`(TEXT, 선택 답변의 `C_MANAGE_ORG` 원문, 없으면 NULL)가 `reports` 에 들어간다. 서버 스키마 5와 함께 교환·백업 왕복한다(서버 detail·merge `처리기관코드`와 같은 열).

```sql
CREATE TABLE reports (
  ID TEXT PRIMARY KEY, 상태 TEXT, 신고번호 TEXT, 신고명 TEXT, 신고일 TEXT,
  만족도조사여부 TEXT, 감시목록 TEXT DEFAULT 'N', 처리상태 TEXT, 차량번호 TEXT,
  위반법규 TEXT, 범칙금_과태료 TEXT, 벌점 TEXT, 처리기관 TEXT, 처리기관코드 TEXT, 담당자 TEXT,
  답변일 TEXT, 발생일자 TEXT, 발생시각 TEXT, 위반장소 TEXT,
  종결여부 TEXT DEFAULT 'N', 신고내용 TEXT, 처리내용 TEXT, 지도 TEXT,
  첨부사진 TEXT, 첨부파일 TEXT,
  category TEXT, entry_value TEXT DEFAULT '', raw_content TEXT DEFAULT '',
  synced_at INTEGER,
  보완횟수 INTEGER DEFAULT 0,
  보완_미응답 TEXT DEFAULT 'N',
  보완_요청_내용 TEXT DEFAULT '',
  보완_신고자_의견 TEXT DEFAULT ''
);
CREATE TABLE report_raw (
  ID TEXT PRIMARY KEY,
  raw_content TEXT NOT NULL DEFAULT '',
  raw_type TEXT NOT NULL DEFAULT '',
  saved_at INTEGER
);
CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT);
```

- `reports.synced_at`
  - Unix epoch milliseconds
  - "이 신고 row 의 추적 대상 필드가 마지막으로 실제 반영된 시각"
  - 동일 내용 재동기화에서는 유지, 실제 처리결과/답변 payload 변경 시에만 갱신
  - `Report.fromJson`, local row → `Report`, 알림 extraData 직렬화 모두 이 값을 잃지 않아야
    최근 답변 / 알림 상세 정렬이 서버와 같은 기준으로 유지된다.
- `reports.raw_content`
  - 레거시 호환용 컬럼으로 남아 있지만 신규 데이터의 payload 정본은 `report_raw` 가 담당
- `reports.보완횟수 / 보완_미응답 / 보완_요청_내용 / 보완_신고자_의견`
  - 보완요청 마지막 round 1세트만 보존. 다회차 이력 전체는 저장하지 않는다.
  - `보완_요청_내용` 본문 prefix 에 `"보완 요청자: <name> (<phone>) · 요청 일시: ... · 완료 일시: ..."` 가 함께 들어가 마지막 답변자와 다를 수 있는 보완 요청자를 텍스트로 명시한다.
  - Standalone 은 `standalone_parser.summarizeLastSupplementFromJson()` 가 안전신문고 API 응답 `SPLMNT_*` 필드로 같은 4 컬럼을 채운다.
  - Client 모드는 서버 응답 `보완횟수 / 보완_미응답 / 보완_요청_내용 / 보완_신고자_의견` 을 그대로 받아 `Report.fromJson` 에서 매핑한다.
- `importFromServerDb()`
  - `mysafetymerge_*` 뿐 아니라 `mysafety_entry_value`, `mysafety_raw_content`, `mysafety_sync_meta`, `mysafety_duplicate_group`, `mysafety_duplicate_member` 를 함께 읽는다
  - 서버 `synced_at` 가 있으면 그대로 복원하고, 없을 때만 import 시점 `now` 를 fallback 사용
  - 서버 duplicate group/member 테이블이 이미 있으면 import 직후 재계산으로 덮어쓰지 않고 exact copy 를 유지한다
  - 서버 `last_sync`, `watchlist`, 기타 sync meta key/value 도 함께 복원한다
  - 단, `map_backfill_state` 같은 서버측 지도 백필 런타임 상태는 그대로 들고 오지 않는다. standalone 에서는 import/restore 뒤 `refreshAll()` → `LocalGeocodeService.ensureMapBackfillStartedFromStoredKey()` 흐름으로 다시 계산한다.
- `LocalGeocodeService`
  - 진행률 상태는 `config_required/config_warning/queued/running/error/completed`
  - `SyncEngine.isRunning` 또는 `StandaloneAutoSyncService.isRunning` 이면 백필을 즉시 돌리지 않고 `queued` 로 남긴다. standalone 은 서버와 달리 self-lock보다는 sqflite 단일 큐 포화가 주요 리스크다.
  - queued/pending/error 상태의 재시도는 지도 첫 진입뿐 아니라 `ReportProvider.refreshAll()`, setup import 적용 직후, standalone sync 완료 직후에도 자동으로 다시 건다.

### 주요 쿼리 함수
- `computeSummary(excludeWithdraw)` — 대시보드 요약
- `excludeWithdraw=true` 면 summary/원형 그래프 기준 `withdrawCount=0` 으로 내려간다. 실제 로컬 원본 취하 개수는 `withdrawRawCount` 로 별도 보존한다.
- 최근 답변 정렬은 `synced_at DESC`, 동순위 `신고번호 DESC`
  - `synced_at` 없는 과거 row 는 `답변일 DESC`, `신고번호 DESC` fallback
- `computeStats(year, law, ...)` — 통계 화면 데이터
- `getDuplicateVehicleReports(...)` — 차량별 그룹화 (서버 `get_duplicate_records` 동일 정렬: `max(신고번호) DESC, 차량번호 ASC, 신고번호 DESC`)
- `getReportByNumber(reportNumber)` — 단건 fetch 용

## 모드 전환 + DB 마이그레이션 (`settings_screen.dart`)

`_confirmModeReset()` 가 두 방향으로 분기:

### Standalone → Client
1. 현재 standalone DB 를 자동으로 `Documents/mysafetyreport/standalone_backup_<ts>.db` 로 복사 (사용자 추가 조작 없이 한 번의 확인만).
2. 백업 실패해도 모드 전환 자체는 진행 (사용자가 명시 요청).
3. `resetConfig()` → SetupScreen.

### Client → Standalone — 3-way 다이얼로그 (`_ChoiceTile`)
| 선택 | 동작 | pending_db_import 키 |
|------|------|----------------------|
| 서버 DB 받아 변환 | 현재 Client 자격증명으로 `/api/v1/settings/db` 다운로드 → Documents/mysafetyreport 에 저장 (★ reset 전에 — 자격증명 살아있을 때) | `convert:<path>` |
| 최신 백업 파일 사용 | Documents/Download/mysafetyreport 의 .db 중 가장 최근 modified 자동 발견 | `copy:<path>` |
| 처음부터 시작 | 빈 DB | (없음) |

선택 결과는 SharedPreferences 의 `pending_db_import` 키에 저장. SetupScreen 의 `_loginStandalone` 가 안전신문고 로그인 성공 뒤, **Standalone 모드를 켜기(`setStandaloneConfig`) 전에** `PendingDbImportAction.applyPending()` 으로 적용한다(2026-10-04, SQ-B03):
- `convert:<path>` → `LocalDbService.importFromServerDb(path)`
- `copy:<path>` → `LocalDbService.replaceFromBackup(path)`
- 모드를 먼저 켜면 루트가 게이트 통과 흐름(drain·자동 동기화·초기화 판정)을 시작해 빈 DB 에 먼저 쓰거나 가져오기를 "작업 중"으로 거절시킬 수 있다. 모드가 꺼진 동안에는 그런 쓰기가 없다.
- 키는 **적용에 성공했을 때만** 지운다(저장값이 그 작업일 때만). 실패하면 키를 남기고 "다시 시도 / 버리고 빈 DB로 시작" 대화상자(받은 파일 경로 표시, 뒤로가기 막음)를 띄운다. 버리면 키만 지우고 받은 파일은 남긴다.
- 결정을 받지 못하면(화면 닫힘 등) 키를 남기고 모드도 켜지 않는다. 다음 로그인에서 다시 시도한다.
- 데모 진입(`_enterDemo`)은 기존대로 대기 작업을 지운다.

### `LocalDbService.importFromServerDb(path)`
서버 DB 의 3개 merge 테이블 (`mysafetymerge_traffic` / `parking` / `other`) → 모바일 단일 `reports` 테이블 + `category` 컬럼 부여. `mysafety_entry_value`, `mysafety_raw_content`, `mysafety_sync_meta`, `mysafety_duplicate_group`, `mysafety_duplicate_member`도 함께 복원한다. `mysafety_watchlist` 는 `sync_meta('watchlist')` 와 `reports.감시목록`을 다시 맞춘다. duplicate group/member가 없는 구서버 DB만 마지막에 로컬 projection 재계산을 수행한다.

### `LocalDbService.replaceFromBackup(path)`
모바일 형식 백업 .db 를 그대로 덮어씀 (closeDb → File.copy → 다음 db getter 가 재오픈). 서버 DB 는 스키마 다르므로 이 메서드 사용 불가.

## errno=104 (connection reset) silent retry 매트릭스

안전신문고 / Client 서버는 가끔 connection reset 으로 응답을 끊음. 모든 주요 네트워크 호출에서 silent 3회 retry 로 사용자에게 노출되지 않게 흡수.

| 호출 | 위치 | retry 정책 |
|------|------|-----------|
| Standalone 일반 GET (목록/상세) | `StandaloneApiService._getWithRetry` | 3회 / 1초 sleep / 20s timeout / 401 시 자동 재로그인 + 1회 추가 |
| Standalone 로그인 Step 1 (RSA 키) | `StandaloneAuthService.login` | 3회 / `attempt`초 backoff / 15s timeout |
| Standalone 로그인 Step 3 (OAuth 토큰 POST) | `StandaloneAuthService.login` | 3회 / `attempt`초 backoff / 15s timeout |
| Client DB 다운로드 (DB 백업·서버→standalone 변환) | `ApiService.downloadDbToFile` | **재시도 없음**, 파일로 흘려 받기, 30초 무응답이면 요청을 닫고 멈춤, 진행률·취소 (2026-09-27 — 예전 `downloadDb` 는 전체 2분 제한 + 이전 요청을 끊지 않는 5회 재시도라 느린 회선에서 최대 약 10분 스피너만 돌았다) |
| Client 일반 API (crawl/enqueue 등) | `ApiService` 메서드들 (`ServerContract` 경유) | retry 없음 (사용자 명시 요청 범위 외) |

catch 대상: `SocketException` (errno 104), `http.ClientException`, `TimeoutException`. 4xx/5xx HTTP 응답은 재시도 무의미 → 즉시 throw.

## refreshAll 직렬화 (Standalone)

```dart
if (_appMode == AppMode.standalone) {
  await fetchSummary();       // 순차 await
  await fetchTrafficReports();
  // ... (총 6개)
}
```

**왜 Future.wait 안 쓰나**: sqflite 는 단일 connection 으로 모든 op 를 직렬 처리. `Future.wait` 로 6개 동시 호출하면 큐만 가득 차서 `fetchSummary()` 의 5초 timeout 발동 ("DB 데드락 의심" 메시지). 실제 deadlock 아님 — 큐 포화. 순차 실행이 정답.

## Python ↔ Dart regex 함정 (CRLF)

| 언어 | `.` 가 매치 안 하는 줄바꿈 |
|------|-----------------------------|
| Python `re` | `\n` 만 |
| Dart `RegExp` | `\n`, `\r`, ` `, ` ` (ECMA-262) |

Traffic 신고 (`C_A_CONTENTS`) 가 CRLF 사용 → 서버 Python 코드를 그대로 포팅하면 Dart 에서 차량번호 regex 실패.

**해결**: `standalone_parser.dart` `parseJsonToReport()` 진입부에서:
```dart
final content = _normalizeNumbers(rawContent)
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n');
```

## 서버 API 주요 엔드포인트 (Client 모드)

Client 모드 URI/헤더는 실제 코드에서 `lib/services/server_contract.dart` 와
`android/.../ServerContract.kt` 를 단일 source of truth 로 사용한다.

- `POST /api/v1/crawl/enqueue` — 단건 큐 등록 `{"report_number": "SPP-..."}`. request_id 없음 — 같은 요청을
  다시 보내면 서버가 또 접수할 수 있다(idempotent 아님).
- `POST /api/v1/crawl/notification` — 백그라운드 알림 처리(`notification_background.dart`)가 쓰는 idempotent
  버전 `{"report_number": "SPP-...", "request_id": "<고유 키>"}`. 같은 `request_id` 재전송은 다시 접수하지 않고
  같은 ack(`{"status":"accepted","request_id":...}`)를 돌려준다. **이 경로가 없는(404) 구서버**(2026-10 redroid
  실측: 운영 PC 서버에 없어 Doze 중에도 3회 모두 404)는 `drainClientNotifications`/`_sendClientNotification`
  가 `/crawl/enqueue` 로 대신 보낸다 — 그 결과(baseUrl·시각)를 기억해 재확인 없이 바로 옛 경로로 보내고,
  6시간 지나면 새 경로를 한 번 더 시도한다(`AppPrefsKeys.crawlNotificationUnsupportedBaseUrl/At`). 옛 경로는
  idempotent 하지 않으므로 POST **전** `crawl_legacy_enqueue_uncertain.<알림 키>`를 영속 저장한다.
  HTTP 200 확인 뒤 `AppPrefsKeys.crawlLegacyEnqueueSentKeys`를 기록하고 미확정 표시를 제거한다.
  응답 유실·종료·비200 결과는 성공으로 ACK하지 않고 원래 pending과 미확정 표시를 보존한다.
  미확정 요청은 재시작·6시간 캐시 만료·서버 업데이트 후에도 자동 POST하지 않는다. 네이티브 200건 배치와
  작업 완료 판정에서도 제외하여 뒤의 새 알림은 계속 처리한다. 미확정 항목만으로는 재시도하지 않으며
  접수 확인 필요를 안내한다. 전송 직전 종료라면
  미전송일 수도 있으므로 서버에서 결과를 확인하고 필요 시 사용자가 새 크롤링을 요청해야 한다.
- `POST /api/v1/crawl/start` — 크롤링 시작 (mode/type/queue_list)
- `GET  /api/v1/crawl/config` — 크롤링 설정
- `GET  /api/v1/crawl/status` — 크롤링 상태 폴링
- `GET  /version` / `GET /version/latest` — 버전 / 업데이트 체크
- `GET /api/v1/server/version` (`X-API-Key`) — Client 접속 호환성 확인. `version`의 major가 3 이상일 때만 저장된 Client 설정으로 신고 화면·서버 작업에 들어간다. 3 미만, 엔드포인트 없음, 인증·네트워크 오류, 읽을 수 없는 버전은 진입을 막고 재확인을 안내한다. 새 서버 설정 저장 시에도 이 검사를 요약 조회보다 먼저 한다.
- `ws://<baseUrl>/ws/events` — 이벤트 스트림 (WsService 연결)
- `ws://<baseUrl>/crawl/ws/logs` — 실시간 로그 (CrawlScreen)

## 안전신문고 API 엔드포인트 (Standalone 모드)

`StandaloneApiService` (`lib/services/standalone_api_service.dart`)

- `GET https://www.safetyreport.go.kr/api/v1/common/rsa/getPublicKey` — RSA 공개키
- `POST https://www.safetyreport.go.kr/oauth/token` — OAuth2 토큰 발급
- `GET /api/v1/portal/mypage/mysafereport?startRowNum=&endRowNum=...` — 신고 목록
- `GET /api/v1/portal/mypage/mysafereport/{C_NO}` — 신고 상세

타임아웃: 20초 / 시도, 최대 3회 재시도. 401 → 자동 재로그인 후 1회 재시도.

---

## 2026-09-24 이후 변경

- **Client 신규 엔드포인트** `GET /api/v1/stats/overview` (`ServerContract.statsOverviewPath`). 요약 카드 + 월별 추이 + 전체 평균 처리일(표본 수 포함). 계약 상세: `docs/design/statistics-spec.md` §6-1.
  서버 구현: `services/report_stats_service.py::get_stats_overview` (서버 레포 브랜치 `feature/stats-overview-api`). 구서버 404 → `ApiFeatureUnavailableException` → 화면에 미지원 안내, 기관표는 유지.
- (2026-09-28, 추가형) `/stats/overview` 각 분류 요약에 `monthly_answered_fine[{month,count}]`, `disposition{fines warnings rejects unconfirmed in_progress disposition_unknown no_penalty unclassified overlap}`,
  `fine_amount{confirmed_amount confirmed_count unknown_count estimated_amount estimated_count}`, `report_types[{name,count}]`, `/stats` 행에 `avg_days_count`. 모델 `OverviewSummary`(필드 없으면 null)·`AgencyStatRow.avgDaysCount`.
  정의·벡터는 서버 `docs/architecture/data-contracts.md` "2026-09-28 통계 화면 개편" 과 `contracts/stats-overview-vectors.json`. DB 스키마·교환 컬럼 변경 없음.
  Kotlin `ServerContract.kt` 는 이 경로를 쓰지 않으므로 변경 없음.
- **Standalone** `LocalDbService.computeStatsOverview` / `summarizeOverviewRows` 가 같은 정의로 로컬 계산. `computeStats` 와 같은 행을 쓰도록 행 조회를 `_queryStatsRows` 로 분리(동작 동일).
- ~~연도 필터 기준 컬럼이 모드마다 다르다~~ → S-08 결정으로 두 모드 모두 **답변일**. 요약 화면 각주에 `year_basis` 로 표시한다.
- **기관/담당자 통계 행 규칙(S-10)**: 표 포함은 처리기관·담당자 값으로 정한다(처리상태로 빼지 않음). 배정된 처리중은 `in_progress` 로 따로 센다. 평균 처리일은 완료 신고만.
  서버 `report_stats_service._build_stats_tables` ↔ Standalone `LocalDbService.buildStatsCategory` 가 같은 정의 — 한쪽을 바꾸면 양쪽 테스트(`tests/test_report_stats_service.py`, `test/services/stats_tables_test.dart`)를 함께 고친다.
  서버 반올림은 `_round_half_up`(Dart `toStringAsFixed` 와 같음), 과태료 금액은 `40.000원` 점 구분자도 읽는다(`extractFineAmount` 와 같음).
- **DB v11 사진 촬영 시각** `reports.사진_첫촬영`(TEXT `YYYY-MM-DD HH:MM:SS`)·`사진_끝촬영`(TEXT)·`사진_촬영수`(INTEGER). 서버 detail/merge 와 같은 이름·형식, 서버 크롤러가 주정차 사진 EXIF 로 채운다.
  NULL = 아직 시도 안 함, `사진_촬영수 = 0` = 촬영 정보 없음. `Report` 모델에는 없으므로 `upsertReport`(REPLACE)가 기존 값을 이어받는다 — 모델에 없는 교환 컬럼을 추가할 때 같은 처리를 해야 한다.
  테스트 `test/services/photo_capture_columns_test.dart`.
  - 2026-09-25부터 Standalone 도 직접 채운다: `lib/services/photo_capture_time.dart` 가 서버 `services/photo_capture_time.py` 와 같은 규칙(사진 앞 128KB, EXIF DateTimeOriginal → DateTime, 네트워크 오류면 NULL 유지해 다음에 다시, 모두 받았는데 없으면 0). 같은 입력·같은 결과는 두 레포 공용 `contracts/exif-vectors.json`(합성 JPEG 7건)으로 양쪽 테스트.
  - 채우는 곳은 서버와 1:1 로 같은 세 군데(동작 로직을 항상 같게):
    1. 상세 저장 때 — `SyncEngine`·`StandaloneAutoSyncService._tryFetchSingle` 이 `upsertReport` 직전에 `MaintenanceService.prefetchForSave`(서버 `reports_repo._prefetch_derived`): 주정차이고 아직 없는 신고(새 신고 포함)면 사진을 읽어 `upsertReport(photoCapture:)` 로 함께 저장. 이미 값이 있으면 이어받는다.
    2. 동기화 끝 — 중지되지 않은 `SyncEngine` 동기화와 큐 지정 동기화(drain, 증분 fallback 을 안 탔을 때) 끝에 `MaintenanceService.backfillMissing(limit: 30)`(서버 `_process_and_save_results` 의 `backfill_missing`).
    3. 한 번 훑기 — `MaintenanceService.startPhotoBackfill()` 이 `refreshAll()`(앱 시작·동기화 뒤·설정 변경 뒤) 때마다 남은 대상 전체를 COUNT 후 128행 ID cursor로 처리한다(서버 기동 때 `maintenance_service`). 0.4초 간격, 동기화 중이면 기다렸다 이어 가고, 백업·복원이 DB 를 닫으려 하면 멈춘다(`runBackgroundWork`). 데모 모드는 하지 않는다.
  - 대상(2·3): 주정차, `사진_촬영수 IS NULL`, `첨부사진` URL, 신고일 ≥ `attachmentCutoff`(오늘 − 6개월, 서버 `relativedelta` 처럼 말일로 맞춤 — 8/31 → 2/28), 최신 ID 부터.
  - 진행 표시: `lib/widgets/maintenance_status_bar.dart` 가 탭 바 바로 위 한 줄 박스(작업 없으면 높이 0)로 그린다. Standalone 은 `MaintenanceService.localJobs()`(사진 작업 + `LocalGeocodeService` 지도 좌표 채우기), Client 는 서버 `GET /api/v1/maintenance/status` 를 작업 중 2초·평소 30초마다 읽는다(구서버·오류면 표시 안 함). 끝나면 "… 완료"를 6초 보여 주고 숨김. 서버 웹 `base.html` `#srJobBar` 와 같은 문구·모양.
- **서버↔모바일 DB 왕복 검사**(PROJECT_RULES §3-1): 서버 레포 `scripts/dev/db_roundtrip_check.py --mobile-repo <이 작업트리>` 가
  `test/tool/db_roundtrip_harness_test.dart`(환경변수 `SR_RT_MODE=import` 일 때만 실행, 평소 skip)로 이 레포의 `importFromServerDb` 를 호출한다.
  서버→모바일→서버, 모바일→서버→모바일 모두 원시 값 비교 차이 0(2026-09-24). 가져오기·내보내기 코드나 `reports` 컬럼을 바꾸면 돌린다.
  알려진 정규화(실제 데이터에는 나타나지 않음): 가져오기가 NULL→''(주소정규화·행정구역·지오코딩상태·캐시 error_message), NULL `synced_at`→가져온 시각. 저장 로직 리팩터링 때 NULL 보존으로 정리.
- **저장 계층 재설계 R0·R1(2026-09-24)** — 정본 계획은 서버 레포 `docs/plans/storage-refactor-plan.md`.
  - 계약 `contracts/storage-contract.json`(서버와 바이트 동일). `test/storage/storage_contract_test.dart` 가 스키마·버전 일치를 검사.
  - DB v12: `report_override`(사용자 수정값), `duplicate_decision`(중복 판단) 표 추가. 버전 상수는 `LocalDbService.dbVersion` 하나. 열 추가는 `lib/storage/schema_utils.dart addColumnIfMissing`(이미 있는 경우만 건너뜀).
  - 서버 DB 가져오기: 값 그대로(NULL 유지), 숫자 열 형 맞춤, `감시목록` 은 서버 `mysafety_watchlist` 로 전부 다시 계산하고 sync_meta 'watchlist' 를 항상 기록(서버 sync_meta 의 옛 사본은 무시), 새 표 복사, 표 읽기 오류는 가져오기 실패로(임시 DB 라 기존 데이터 보존).
  - 앱 백업 복원(`replaceFromBackup`): 종류(모바일)·버전(0 < v ≤ dbVersion) 확인 → 임시 사본 마이그레이션·무결성 검사 → `.bak` 롤백 교체.
  - **2026-09-26 감사 보강(SOL-02·03·05, 서버 레포와 함께 변경)**:
    - 모르는 열: 서버 DB 에서 읽는 표에 이 앱의 대상 표에 없는 열이 있고 NULL 아닌 값('' 포함)이 있으면 교체 전에 `UnknownColumnsException`.
      값이 모두 NULL 인 열은 통과. 서버는 반대 방향에 같은 규칙(`exchange.UnknownColumns`, 409).
    - entry_value: 서버 `mysafety_entry_value` 행 없음 → `reports.entry_value` NULL, 행의 값(빈 문자열 포함) → 같은 값. 서버 복원은 앱 값이 원천(빈 문자열도 덮음, NULL 은 행 없음).
    - 가져오기·복원이 성공해도 직전 DB 를 `<db>.before_import.<epoch ms>.bak` 으로 남긴다(최근 3개, `LocalDbService.latestImportBackup`). 실패하면 되돌리고 그 사본은 지운다.
  - 알려진 결함 고정 테스트 `test/storage/known_defects_test.dart`(M-1·2/3·12·24 — R3 에서 고치면 기대값을 뒤집는다).
- **R2·R3(2026-09-24)**: `reports` 는 **사이트 원본**(서버 title+detail 과 같은 뜻). 사용자 수정값은 `report_override`, 화면·통계는 보기 `reports_effective`(원본 위에 수정값, DB 를 열 때마다 재생성 — 이 보기가 참조하는 열을 DROP/RENAME 하려면 먼저 보기를 지울 것).
  서버 DB 가져오기는 `mysafety` + `mysafetydetail_*` 를 읽고(구서버만 merge), 6개월 지난 첨부는 `attachment_policy.dart` 로 화면에서 가림.
  `upsertReport(…, ratingLookup:)` 는 UPDATE 로 사이트·계산 열만 쓴다. 데모 계정은 `standalone_reports_demo.db`(설정 키 `standaloneDemoMode`). DB v13.

## 이전 버전 DB 처리 — 초기화 크롤링 릴리스 (2026-09-27, 서버 레포와 함께)
이번 릴리스는 이전 DB 를 새 구조로 옮기지 않는다. 아래 "앱 업데이트 때 DB 처리" 의 업데이트 로직(`onUpgrade: _migrateLocalDatabase`, `backupBeforeUpgrade`)은
`lib/services/local_db_service.dart` 의 `_open`·`_createImportTargetDb` 에서 **주석으로 남겨 비활성**했다(함수 본체는 다음 스키마 변경 때 다시 켜려고 남김).
- **2026-10-11 앱 DB 17 (현재 기준, 이 아래 v16 설명보다 우선)**: `reports` 에 `ssnpc_cd`·`ssnpc_type`(안전신문고 분류 코드), `category` 는 5분류
  (`traffic` `parking` `safety` `living` `other`, `lib/services/report_category.dart` — 정본 `contracts/report-categories.json`, 서버와 바이트 동일).
  `_open` 은 `migrateInPlace(path)`(버전 16 → 17 제자리 변환: 백업 `<db>.before_v17.<ms>.bak` → 열 추가 → entry_value 로 분류 다시 정하기 →
  행 수·값 대조 → 커밋) 다음 `resetLegacyDatabase`(이제 16 미만만). 서버 DB 가져오기는 서버 스키마 6(`mysafety_report` 의 category 있는 행 +
  `mysafety_report_body` + 사용자 표)만 받는다. category NULL(목록만 본 신고)이 한 건이라도 있으면 앱에 둘 자리가 없어 가져오기를
  거절한다(`_preflightServerPopulation`, 조용히 빼면 그 DB 를 빈 서버에 복원할 때 사라진다). Client 는 `X-SR-Taxonomy: 5` 를 보내야 5분류 응답을 받는다(서버 `core/utils/taxonomy_compat.py`).
  계획: 서버 레포 `docs/plans/2026-10-11-report-taxonomy.md`.
- `_open`: 먼저 `resetLegacyDatabase(path)`. 저장 버전이 1 이상 `dbVersion` 미만이면 **파일을 바꾸지 않고 그 자리에서** 한 쓰기 트랜잭션(`BEGIN IMMEDIATE`)으로:
  버전 재확인(다른 연결이 먼저 끝냈으면 아무것도 안 함) → 남길 자료(감시목록 `sync_meta['watchlist']`, 열 구성이 같은 `geocode_cache`) 읽기 →
  별도 연결의 일관된 사본(`LocalDbService.copyDatabaseConsistent`: 새 파일에 원본을 ATTACH 해 한 읽기 트랜잭션으로 스키마·표·`sqlite_sequence`·`user_version` 을 옮기고 표별 행 수·integrity_check 확인 — `VACUUM INTO` 는 SQLite 3.27 부터라 Android 7~10 에서 실패해 쓰지 않는다) → `<db>.legacy_v<옛 버전>.<epoch ms>.bak`
  (파일 복사가 아니라 WAL 에만 있던 쓰기까지 담는다 — Sol 검토 2, 구형 Android — Sol 재검증 4)
  사본은 가상 표(FTS 등)를 먼저 만들어 그 보조 표는 다시 만들지 않고 원본 행으로 채우며, 인덱스 → 보기 → 트리거 순서(보기의 INSTEAD OF 트리거)로 만든다(Sol 재검증 5).
  비우기도 가상 표를 먼저 DROP 한다.
  → 커뮤니티 dataset 선회전(실패하면 ROLLBACK, 아무것도 안 바뀜) → 표·보기 전부 DROP → `_createSchema` → 남길 자료와
  `sync_meta['legacy_reset']` = `{from_version, backup, kept, dropped, at}` 기록 → `PRAGMA user_version = dbVersion` → COMMIT.
  트랜잭션 동안 다른 연결의 쓰기는 잠김 오류로 실패한다(백업에도 새 DB 에도 없는 쓰기가 생기지 않게, Sol 재검증 1). 열린 DB 의 WAL 삭제·파일 이름 교체는
  SQLite 가 손상 경로로 꼽으므로 하지 않는다(Sol 재검증 3). 데모 DB(`demoDbFileName`)를 비울 때는 커뮤니티 dataset 을 선회전하지 않는다(Sol 재검증 2).
  수정값·중복 판단·메모·신고는 옮기지 않는다(백업에만 남음). 초기화 크롤링이 신고를 다시 채운다.
- `onUpgrade` 는 `_refuseLegacyUpgrade`(옛 버전이 비우기를 거치지 않고 여기 오면 `LegacyDatabaseException` 으로 멈춤 — sqflite 는 onUpgrade 가 없으면 옛 구조에 새 번호만 적는다).
- 가져오기 거절(`_refuseOtherVersion`, 서버 `exchange.refuse_other_version` 과 같은 규칙·문구): 서버 DB 가져오기는 `user_version == LocalDbService.serverSchemaVersion`(계약
  `schema_version.server`, 테스트가 확인), 앱 백업 복원·직전 DB 되돌리기는 `version == dbVersion` 만 받는다. 아니면 `LegacyDatabaseException`
  (`이전 버전 {서버|모바일 앱} DB(스키마 N)는 가져올 수 없습니다(지금 M). …` / `더 새 버전 …`) — 스테이징·교체 전에 멈춘다. Client 모드의 복원은 서버가 같은 규칙으로 409.
- 초기화 크롤링(`lib/community/rebuild/community_rebuild.dart`): 새 설치(`personalDbFacts`: 신고 0건 ∧ `legacy_reset` 없음)는 필요 없음 — 공식 계정이 있으면 완료 기준선
  (`confirmed_at='fresh_install'`)을 적는다. `legacy_reset` 이 있으면 필요하고 안내 화면이 보존 항목 대신 이전 DB 백업·비움 안내(`communityRebuildLegacyText`)를 보인다.
  Client 는 서버 상태의 `required=false` 면 안내 화면을 바로 지나가고, 서버의 `legacy_reset` 을 같은 문구로 보인다.
- 데모(심사용 합성 데이터, `standalone_reports_demo.db`)는 초기화 대상이 아니다: `main.dart rebuildAppliesOnDevice` = Standalone ∧ 데모 아님(첫 데모 로그인이 시드한
  신고 때문에 초기화 화면이 나오지 않게, Sol 검토 4). 판정·안내 화면·동기화 차단 모두 이 조건을 쓴다.
- 일반 동기화 차단: `SyncEngine.rebuildBlocks`(main 이 Standalone 판정으로 설치)가 true 거나 판정이 실패하면 `SyncEngine.start`(초기화 run 제외)가
  네트워크 전에 `rebuildBlockedMessage` 로 끝난다(서버 크롤 409 와 같음). 게이트 통과 직후 공유 대기열 처리도 여기서 막힌다.
- 함께 고친 초기화 결함: 목록이 0건인 계정도 `list_complete=1` 로 완료된다(예전엔 끝낼 수 없었음), 같은 run 재시도의 사전 백업은 지난 사본을 지우고
  다시 만든다(예전엔 대상 파일이 있어 실패), 무결성 검사는 만든 사본에서 한다(예전엔 원본을 검사). 사전 백업도 `VACUUM INTO` 대신 같은 일관된 사본을 쓴다
  (예전엔 Android 7~10 에서 백업이 실패해 초기화 크롤링을 시작할 수 없었다).
- 계약: `contracts/community-ingest/rebuild.md` "이전 버전 개인 DB"(map 레포 원본의 사본).

## 2026-09-27 신고 자료의 주인 = 카카오 계정 (서버·모바일 함께)

사용자 결정: 카카오 로그인은 필수, 카카오 로그아웃은 신고 자료를 지운다, 다른 사람의 DB 는 가져오지 못한다.
- 키 `kakao_member_id`: 서버 `mysafety_sync_meta`, 모바일 `sync_meta`. 값은 카카오 회원번호 원문(숫자 문자열, GoTrue `identities[provider=kakao]` 에서 읽음 —
  `user_metadata` 는 쓰지 않음). 스키마·버전 변경 없음(key/value 행 하나). 교환 때 다른 sync_meta 키와 같이 그대로 옮긴다 —
  서버 레포 `scripts/dev/db_roundtrip_check.py` 가 S0·M1·S2·M3 네 DB 모두 같은 값인지 따로 확인한다(`[owner]`).
- 쓰는 때: 게이트가 처음 통과할 때(주인 표시가 없을 때만), "신고 내역 지우고 이 계정으로 시작". 지우는 때: 카카오 로그아웃·위 전환(자료와 함께).
  `start.py --reset` 은 이 키를 남긴다(같은 사용자의 초기화).
- 가져오기·복원(서버 `exchange.restore`, 모바일 `importFromServerDb`·`replaceFromBackup`): 버전 검사 바로 뒤·무엇이든 바꾸기 전에 파일의 주인을 본다.
  없거나(이 기능 전 DB 포함) 지금 로그인한 계정과 다르거나 로그인 계정 번호를 모르면 거절(서버 409 `ForeignDatabaseRefused`, 모바일 `ForeignDatabaseException`).
- 카카오 로그아웃이 비우는 범위 = 이전 DB 초기화와 같다: 서버는 `admin_users`·`api_keys`·`mysafety_watchlist`·`mysafety_geocode_cache` 유지,
  모바일은 감시목록(`sync_meta['watchlist']`)·`geocode_cache` 유지. 백업은 만들지 않는다. 크롤링·동기화·지도 변환 중이면 거절(아무것도 안 바꿈).
- API: `POST /api/v1/community-auth/disconnect` 는 **삭제**(사용자 결정 "경로 삭제", 코드 주석 처리). 폰에서 서버의 카카오 로그인을 풀 수 없다.
  상태 DTO 의 로그인 후보에 `is_different_data_owner`(하위호환 추가). 게이트 상태에 `db_owner_mismatch` 추가.

## 앱 업데이트 때 DB 처리 (2026-09-25) — 2026-09-27 부터 비활성(위 절)
- DB 를 열 때 sqflite 가 저장된 버전을 보고 `_migrateLocalDatabase` 로 `LocalDbService.dbVersion`(현재 15)까지 올린다. sqflite 가 이 과정을 한 트랜잭션으로 돌려 실패하면 통째로 되돌아간다.
- 올리기 전에 `LocalDbService.backupBeforeUpgrade` 가 DB 파일을 `<db>.pre_v<옛 버전>.<epoch ms>.bak` 로 복사한다(버전 없이 열어 WAL 을 합친 뒤 복사, 새 설치·이미 최신이면 건너뜀, 최근 3개 유지). 앱 데이터 폴더 안이라 앱을 지우면 함께 지워진다.
- **이전 버전 앱으로 되돌리면 새 DB 를 열지 못한다**: 구조는 추가만 했지만 sqflite 가 버전 번호가 내려가는 것(onDowngrade 없음)을 막는다. 되돌릴 때는 `.pre_v<그 앱의 버전>` 백업을 원래 이름으로 바꾸거나, 앱 데이터를 지우고 다시 동기화한다(Standalone) / 서버에서 다시 받는다(Client).
- 앱 백업 복원(`replaceFromBackup`)은 따로: 종류·버전 확인 → 임시 사본 업그레이드·검사 → `.bak` 남기고 교체. 새 앱이 만든 백업은 거부한다.

## 2026-09-25 서버↔모바일 동등성 검수(G17)로 맞춘 규칙
- DB v15: 옛 상태 보정(`_normalizeLegacyProcessingStates`)을 서버 `_normalize_processing_layers` 와 같게(NULL 은 '' 로 비교) 다시 적용하고, 서버 `repair_car_numbers` 와 같은 차량번호 복구(`*` 가 든 번호를 저장된 본문 원문으로 다시 뽑기)를 한 번 돈다. 가져오기·복원은 값을 바꾸지 않는다(왕복 무손실).
- 상세 저장(`upsertReport`): 본문 원문 종류 `report_body`, 새 원문이 비면 기존 유지, 원문 내용·종류 중 하나라도 바뀌면 변경(서버 `_save_raw`). 반환값 `({isNew, changed, syncedAt})` 으로 동기화가 변경 알림을 판정한다 — 서버 reports_repo 와 같은 기준(신규 / 추적 열·category·entry_value·원문 변경). 처리상태가 바뀌면 '처리변경', 그 밖엔 서버와 같은 '변경'. payload 에 `notification_kind`·`change_reason`·보완 필드·`synced_at`, 순서는 서버 `_report_change_sort_key` 와 같게.
- 변경 판정 열 목록 = 계약 `change_tracked.columns`(서버 `CHANGE_TRACKED_COLUMNS` 와 같은 목록, 양쪽 테스트).
- 파서: 빈 문자열 주소(`RN_ADRES`·`SPLMNT_RN_ADRES`)는 다음 후보로, `C_NOW` 는 "10.0" 같은 소수 표기도 읽음(서버 `int(float())`).
- 통계 법규 선택지는 연도·취하 제외·대표건 적용 후, 법규 필터 전 행에서(서버 `get_agency_stats`).
- 옛 중복군 상태·대표건 모드 변환은 서버 `_LEGACY_STATUS_MAP` 과 같게(`normalizeDuplicateStatus`/`normalizeRepresentativeMode`).
- 전체 재동기화는 사라진 신고 정리를 중복군 재계산보다 먼저 한다.
- 계산 동등성 하네스 `test/tool/logic_parity_harness_test.dart` — 서버 `scripts/dev/logic_parity_check.py` 가 호출(평소 flutter test 에서는 건너뜀).

## 공식 신고 위치 (현재 dev)

PC 저장소 `scripts/debug/extractor.py`가 저장한 `testresults/*_api_raw.json` 7건에서 `result.C_A_W`(위도)와 `C_A_E`(경도)가 확인됐다. 완료된 보완의 `SPLMNT_C_A_W/E`가 유효하면 보완 좌표를 쓴다. 보완 주소가 바뀌고 좌표 쌍이 유효하지 않으면 이전 위치를 새 주소에 붙이지 않는다.

- 위도 32~39.5, 경도 124~132의 유한한 쌍만 기존 `reports.위도`·`경도`에 저장한다. 반올림·소수점 절사는 하지 않는다. 좌표가 없으면 두 열 모두 NULL이다.
- `주소정규화`는 공식 주소의 공백 정리값, `행정구역`은 빈 문자열, `지오코딩상태`는 좌표가 있으면 `ok`, 주소만 있으면 `not_found`다. 이 열 이름은 서버와 DB를 교환하기 위해 유지한다.
- 재동기화는 같은 주소여도 좌표를 덮어쓴다. 사용자가 고친 표시 주소는 공식 좌표를 바꾸지 않는다. Client·Standalone 지도는 저장된 좌표를 읽고, 커뮤니티 공유는 저장 전 공식 상세 응답 좌표를 읽는다.
- 커뮤니티 wire `location.source="geocode"`는 기존 입력 계약의 좌표 있음 표시값이다. 보완으로 바뀐 좌표는 재동기화할 때 새 `completed_observation`으로 전달된다. 카카오 REST 주소 변환 키는 필요하지 않다.

## registry 2026-09-29.1과 통계 키 전환 (2026-09-29)

- `shared/agency-region-registry`(스키마 v2, PC·지도와 바이트 동일)를 asset 으로 번들한다:
  manifest·links·index·legacy·institutions·region_events(vectors·provenance·data-sources 제외).
- 통계(기관·담당자 표, 지도 브레이크다운·기관수)의 묶음 기준이 표시 이름에서 `agency_stat_key` 로
  바뀌었다(서버와 같은 규칙·같은 동점 정렬). 출력 행·breakdown에 `agency_key` 추가.
  원문 `처리기관`·`처리기관코드`는 덮어쓰지 않으며, 과거 신고는 조회 시 새 registry 로 다시
  계산된다(재크롤링 없음). DB 스키마 변경 없음(version 16 유지).
- 성능 주의(2026-09-30): registry 해석은 신고 행마다 UI isolate 에서 불린다. 벤더 복사본
  (`lib/services/agency_registry.dart`)은 링크 색인과 (코드, 이름)별 결과를 스냅샷 객체에 캐시한다.
  정본 `resolve.dart` 처럼 호출마다 links 전체로 색인을 만들면 신고 3천 건에서 ANR 이 난다.
  캐시는 스냅샷 수명과 같다(asset 번들이라 실행 중 불변). 실행 중 registry 를 교체하는 기능을
  만들면 새 스냅샷 객체로 바꿔 캐시가 함께 버려지게 한다. 시작 때 JSON 해석은 `compute` 로 한다.

## 2026-09-29 기관 표시 옵션 폐지

Standalone은 저장된 `standaloneNormalizePolice`를 읽거나 적용하지 않는다. Client는 서버의 호환용 `normalize_police` 값을 무시한다. 기관코드 registry가 신고 표시와 통계의 현행명·통계 키를 항상 계산하며, 미확정 기관은 원문 이름을 유지한다. DB 원문 `처리기관`·`처리기관코드`는 바꾸지 않는다.

### 코드 대조 정정 — 대용량 가져오기/중복

서버 title/detail 또는 legacy merge, raw/entry는 128행 native JOIN 페이지로 읽는다. 가져오기 전체 raw Map과 중복 inventory 전량 보관을 제거했다. 교환 컬럼/NULL/수정값은 그대로이며 파생 digest/revision 표는 원문을 보관하지 않는다. 중복 staging·원자적 교체·백업 수명은 [bounded reads](bounded-reads.md)를 따른다.


## 종료 이벤트 재연결 복구

서버 `/ws/events`의 추가형 `event_id`와 `connected.data.latest_event_id/replay_gap/cursor_reset`을 사용한다. `WsService`는 서버/API key 설정 scope별 커서를 `after`로 보내고 이미 처리한 종료 이벤트를 건너뛴다. `PrefsInbox.put`의 terminalCursor 인자로 이력과 커서를 같은 Editor commit에 저장한다. 저장 실패는 1013 재연결로 복구하며, 오래된 이벤트가 서버의 256개 보존 범위를 벗어나면 현황 확인 알림을 표시한다. crawl_finished의 outcome succeeded/partial/failed/cancelled/unknown을 구별하고 결과 불명을 성공으로 표시하지 않는다. 기존 event payload와 DB 교환 schema는 유지한다.

SharedPreferences의 disk commit 실패는 메모리 변경을 되돌리지 않는다. PrefsInbox는 정상 history/cursor를 한 commit으로 쓰고 실패하면 이번 새 history 키·잘린 기존 history·기존/부재 cursor만 메모리에 복구한 뒤 오류를 전달한다. WsService는 오류 후1013으로 재연결하여 아직 저장하지 못한 terminal을 건너뛰지 않는다. OS 알림 표시 자체의 exactly-once를 보장하는 계약은 아니다.

## 신고 지도 핀 기준 pin_basis (2026-10-05)

- 근거: [핀 기준 명세](../plans/2026-10-05-map-pin-basis.md) §1·§3. 정본 벡터 `contracts/map-pin-basis-vectors.json`(서버와 바이트 동일). DB 스키마·저장 좌표·교환 형식 변경 없음.
- 주소키 = `trim(주소정규화)`, 비면 `trim(위반장소)` (`COALESCE(NULLIF(trim(주소정규화),''),trim(위반장소))`).
- Standalone `LocalDbService.computeReportMapStats` / `computeReportMapMissingGroups` 에 `pinBasis`(기본 `'coords'`, `'address'` 외 모두 coords).
  address 모드는 같은 주소키 신고들(연도·분류·중복 모드·필터 적용 뒤 모집단)의 유효 공식 좌표 중 가장 많이 나온 (위도,경도) 쌍(동률이면 위도 작은 것→경도 작은 것)을 effective 좌표로 쓴다.
  유효 좌표 판정은 기존 지도 것과 같고(`_validMapCoordinate` ≒ SQL typeof·범위), DB 원값은 바꾸지 않는다.
  meta geocoded/missing 건수·bounds 거르기·셀 묶기·좌표 없는 목록이 모두 effective 기준이다. 캐시 키(metaKey/cacheKey)와 meta(`pin_basis`)에 핀 기준을 포함한다.
  대표 좌표는 모집단 읽기 뒤 Dart(`resolveMapPinBasis`)에서 계산해 TEMP 표(`sr_pin_rep_*`)로 SQL 과 조인한다 — 기기 SQLite window 함수에 의존하지 않는다.
- Client `ApiService.getReportMapStats` / `getReportMapMissingGroups` 에 `pinBasis`(기본 coords). address 일 때만 `pin_basis=address` 쿼리를 붙인다(구 서버는 무시하므로 하위호환, coords 는 기존 요청과 바이트 동일). 서버 경로 상수는 그대로.
- 지도 화면 `report_map_screen.dart`: 필터 바에 "핀 기준" ChoiceChip 2개(위도·경도/주소, 분류 선택과 같은 화면 상태 유지) + 주소 모드 안내
  "같은 주소의 신고를 한 핀으로 묶고, 그 주소에서 가장 많이 신고된 공식 좌표에 표시합니다." 바꾸면 지도·좌표 없는 신고 목록을 다시 읽는다.
  `ReportMapMeta.pinBasis`(구 응답에 없으면 coords).
- 테스트: `test/map_pin_basis_test.dart`(벡터 effective 좌표·건수·점 집합·좌표 없는 그룹 수/건수·구성원), 지도 위젯 토글 확인 1건.
- 후속 A(§5, 2026-10-05): meta `address_groups` 를 서버 정의와 같게 — effective 좌표가 있는 신고의 서로 다른 (위도, 경도, 주소키) 조합 수(주소키 빈 신고도 `(lat,lng,'')` 로 셈, `pin_basis=address` 면 effective 좌표 기준). 벡터 expected(coords 6, address 4)를 `test/map_pin_basis_test.dart` 에서 확인한다.
- 후속 B(§6, 2026-10-05): Standalone 칸 점(`_MapCellAccumulator.toJson`)의 `address`/`address_count`/`region` 을 `contracts/map-cluster-label-vectors.json` 규칙대로 낸다(정본은 벡터 description).
  주소키=`trim(주소정규화)`, 비면 `trim(위반장소)`. `address_count`=비지 않은 주소키 종류 수. 대표 주소키=신고 수 최다(동률이면 문자열 작은 것).
  `address`=대표 키 신고들의 비지 않은 `trim(위반장소)` 중 최소값, 없으면 대표 키, 키가 하나도 없으면 `''`.
  `region`=0곳 `'주소 정보 없음'` / 1곳 `address` / 2곳 이상 `'{address} 외 {N-1}곳'`. 점에 `address_count` 추가(하위호환, `ReportMapPoint.addressCount` 없으면 0).
  칸 `cluster` 판정은 기존 그대로(묶음 점 탭=확대 유지). 새 region 이 마커 라벨로 새지 않도록 `mapPointRegionName` 은 실제 주소 보유 묶음 점에 `''`을 돌려 마커 라벨 `'N건 묶음'`을 유지하고, `'주소 정보 없음'`은 일반 문구로 취급한다. 화면 범위 합성 셀(`visibleMapCells`, 주소가 일반 문구)은 기존처럼 region 을 보인다.

### 코드 대조 정정 — Android 업데이트 백업과 소유자 보호 (2026-10-06)

- 이전 DB 초기화 백업은 `copyReadOnlyDatabaseSnapshot(sourceSnapshot: txn)`으로 원본 잠금을 이미 가진 트랜잭션에서 읽는다. 대상 파일만 별도 연결로 열어 128행씩 복사·값/타입 대조, 스키마·rowid·sequence·버전 보존 및 integrity_check를 수행한다. 원본을 다시 열거나 ATTACH하지 않는다. 원본 트랜잭션은 백업 완료→커뮤니티 dataset 회전→초기화가 끝날 때까지 유지하여 중간 쓰기 유실을 막는다. 앞의 별도 읽기 연결/ATTACH 설명은 이 경로에는 적용되지 않는다.
- 소유자 검사 실패는 `local_db_unavailable`와 인증 실패 사유를 구분한다. CommunityStore 열기에 실패하면 연결과 실패한 Future를 해제하여 재시도한다.
- DB 소유자를 확인할 수 없는 로그아웃은 삭제하지 않고 세션만 닫는다. 먼저 DB 밖 SharedPreferences에 `communityOwnerQuarantined=true`를 영속 기록한다. 이후 실제 소유자 표시가 있는 자료는 해당 계정만 접근하고, 주인 없는 자료는 `quarantined`로 차단하여 명시적인 자료 비우기/새 계정 시작을 요구한다. 비우기 성공 후 보호 표시를 해제한다. 게이트가 막힌 동안 writer 등록/업로드는 허용하지 않는다. 정상 소유자 로그아웃의 자료 삭제 및 다른 계정 자료 보존 규칙은 유지한다.
- PC `services/community_gate.py`도 주인 확인 실패를 차단한다. PC `services/community_account_ops.py:logout`은 여전히 DB 주인 읽기 예외를 `OperationRefused`로 처리하여 로그아웃도 막는다. PC에도 세션만 닫는 복구를 제공하려면 별도의 영속 보호 표시와 회귀 테스트가 필요하다. 이번 모바일 변경은 PC 코드를 수정하지 않는다.

## 공식 계정과 개인 DB 소유권

안전신문고 로그인 ID와 그 해시는 개인 DB에 저장하지 않는다. 로그인 ID는 기존 설정
`standaloneUsername`에서만 읽으며, `datasetKeyForOfficialId`로 계산한 해시와 중앙
`status.official_account.dataset_key`를 대조한다. 등록 시 서버의 양방향 1:1 거절도 적용한다.

- 모바일 백업 복원, 직전 DB 되돌리기, 서버 DB 가져오기, 파일 자동 판별, pending import의
  주인 검사는 **카카오 회원번호만** 사용한다. 같은 카카오라면 다른 안신 계정 시절의 백업 및
  안신 계정 정보가 없는 옛 백업도 허용한다. 카카오 주인이 없거나 다르면 기존대로 거절한다.
  최종 교체 직전에도 카카오 계정·설정 세대·대상 경로를 재확인한다.
- 개발 중 사용했던 `official_account_key`는 생성하거나 소유권 판정에 읽지 않는다.
  배포 이력이 없으므로 별도 제거 마이그레이션은 없다. 기존 파일의 임의 메타 왕복 보존 계약은 유지한다.
- 설정 ID가 바뀌거나 서버 바인딩이 후보 ID와 다르면 경고 → Documents/mysafetyreport
  (실패 시 Download/mysafetyreport)의 `standalone_backup_<microseconds>.db` →
  SQLite 일관 스냅샷·무결성 검사 → pending 기록 → 중앙 공유자료 삭제/바인딩 해제 확인 →
  community dataset rotate → 개인 자료·감시목록 비우기 → 새 설정/연결 순서다.
  백업 또는 서버 해제 확인 실패 시 개인 자료를 지우지 않는다.
- `official_account_change_pending=true`는 계정 정보 없는 중단 상태값이다. 해제 응답 유실/중간 종료 시
  명시적인 재시도 전까지 진입·동기화를 막는다. `official_account_restart_required=true`는
  성공 후 새로 시작 안내를 유지한다. 두 키에 ID/해시를 쓰지 않는다.
- Client→Standalone: resetConfig는 카카오 세션을 비우지만 루트에서 카카오 재인증 후 공식 로그인을
  진행한다. 가져오기 전 설정/서버 기준 계정 변경 절차를 확인하고, 가져오기를 끝낸 뒤 모드를 활성화한다.
  같은 준비를 두 번 수행해 방금 가져온 자료를 비우지 않도록 후보 ID를 Provider 메모리에만 보관한다.
  가져오기에는 공식 ID가 필요 없다. 성공/명시적 버리기 전에는 pending 액션을 제거하지 않는다.

### 코드 대조 정정

사용자 r2 정정으로 개인 DB 공식 계정 해시와 복원 거절 규칙을 제거했다. PC 교환 DB에
`official_account_key`를 요구하지 않으며 스키마/임의 메타 보존 계약도 변경하지 않는다.

### 코드 대조 정정 — Standalone 초기화 중단 복구 (2026-10-08)

- 초기화 화면은 `RebuildCoordinator`가 DB 경로·dataset·공식 계정·Provider 세대별로 보유한 `CommunityRebuild`에 연결한다. 화면 종료는 작업 종료가 아니다. 계정/자료 범위가 바뀌면 이전 작업에 중단을 요청하고 실제 종료 뒤 해제한다. Client의 서버 job 경로는 사용하지 않는다.
- 저장된 `running`/`preparing_backup`/`awaiting_confirmation`/`committing`만으로 실행 중으로 판단하지 않는다. 로컬 실행 Future가 없고 `rebuild`·`personal_sync`의 유효한 lease가 없을 때 같은 run을 `paused`로 바꿔 재개를 제공한다. 기존 버전이 남긴 유효한 lease는 강제로 삭제하지 않는다(기존 rebuild 최대 30분, personal_sync 10분). 새 rebuild lease는 2분·30초 갱신이다. 다른 작업의 유효한 lease가 있으면 종료 확인 상태와 재조회 수단을 제공한다.
- 초기화 전체가 `SyncOperationAdmission`을 사용한다. 같은 실행의 SyncEngine 진입은 같은 Zone에서 재사용한다. 재개 연타는 하나의 Future를 공유한다. 소유권/자료 세대를 외부 응답 후 확인하고, capture는 community 트랜잭션 안에서, 개인 DB 저장은 community lease를 잠근 동안 검증한다. 중단 요청은 기존 Future가 끝나기 전 잠금을 해제하거나 새 작업을 시작하지 않는다.
- 수집 무진행 5분(백업 15분)은 중단 요청으로 바꾼다. 전체 신고 수집의 총시간 제한은 아니다. 게이트 확인은 45초, 공유 목록 사전 확인은 2분으로 제한한다. DB 쓰기/기존 수집 Future를 단순 timeout으로 버리고 새 쓰기를 시작하지 않는다. 네트워크 요청은 기존 요청별 timeout을 따른다. 저장소 자체가 응답하지 않는 경우는 종료 확인을 유지하며, 프로세스 재시작 후 lease와 checkpoint로 복구한다.
- `rebuild_items`를 집계하여 이전 시도를 포함한 성공/영구 실패/재시도/대기 건수를 표시한다. 목록 완료 체크는 실제 `list_complete`가 기준이며, 엔진은 목록 페이지와 상세 처리마다 `updated_at`을 기록한다. 상태 저장은 해당 필드만 UPDATE하여 엔진 checkpoint를 오래된 메모리 행으로 덮어쓰지 않는다. 준비/검증 중 화면 재조회가 실행 객체의 상태를 덮어쓰지 않게 한다.
- 최초 백업은 integrity_check 후 재사용한다. 새 백업은 별도 임시 파일을 검증하고 소유권 확인 뒤 최종 이름으로 바꾼다. DB job에 경로를 기록하기 직전 종료된 경우에도 이미 완성된 사본을 재사용한다. 사본이 없거나 손상되면 부분 수집 DB를 원래 백업인 것처럼 덮어쓰지 않고 중단한다.
- 검증 checkpoint는 재수집 없이 재검증하며 영구 누락 수락은 계속 사용자 명시 동의가 필요하다. 소유자·계정·게이트·목록 완전성·staging·작업 소유권 검증은 유지한다.
- (2026-10-11) Standalone 은 더 이상 이 화면에 머물지 않는다 — 안내 한 번 뒤 메인으로 가고 `StandaloneRebuildRunner` 가 같은
  `CommunityRebuild` 를 백그라운드로 진행한다([community-gate.md](community-gate.md) "Standalone 백그라운드 진행"). 이 화면은 대시보드
  카드의 '자세히' 로 연다. 실행 전체를 `LocalDbService.runBackgroundWork` 로 등록해 백업·준비·반영 단계에서도 파일 교체가 거절된다
  (예전에는 수집 단계만 등록돼 있었다).
- rebuild의 로컬 수집 종료는 공유 업로드 완료를 기다리지 않는다. 영속 outbox를 기존 업로더가 처리하고, 완료 시 해당 run의 공유 전송 대기 건수가 있으면 별도 안내한다. 서버 장애를 수집 성공으로 바꾸거나 전송 대기 자료를 삭제하지 않는다. 개인/교환 DB 스키마, 공유 payload, 버전 값은 변경하지 않는다.

### 코드 대조 정정 — Standalone 재시도와 준비 오류

- `StandaloneRebuildRunner`는 `prerequisites_required/manifest_unavailable`에 1·2·5·10·30분 간격으로 최대 5회 자동 재시도한다. 공유 목록 확인의 예외·시간 초과도 같은 상태로 남긴다. 사용자 일시정지와 영구 누락 확인 대기는 자동 재개하지 않는다.
- 작업 충돌은 `rebuild`·`personal_sync` lease 중 가장 늦은 실제 만료 시각에 5초를 더해 예약한다. 만료 정보가 없으면 60초 뒤 확인하며 최대 15회 재시도한다. 갱신된 잠금은 매번 다시 읽고, 잠금을 강제로 해제하지 않는다. 만료 조회 실패나 횟수 소진 시 예약을 끝내고 사용자 재시도를 안내한다.
- 대시보드 카드·상세 화면에는 실제 타이머가 있을 때만 자동 재시도 대기를 표시한다. 수집 시작 전 실패도 재시도 예약 시각·횟수를 일반 알림으로 전한다. 예약 종료 시 중단 안내와 수동 재시도 경로를 남긴다.
- 예약과 횟수는 현재 앱 프로세스의 실행기에 속한다. 프로세스 종료 뒤에는 다음 앱 실행 때 저장된 작업으로 재개 여부를 다시 판정한다. 타이머를 프로세스 밖에서 실행하는 별도 서비스는 아니다. 수동 재시도는 횟수를 초기화하며, 계정·자료 범위 변경이나 객체 해제 뒤 도착한 이전 조회 응답은 새 예약을 만들지 않는다.
- 초기 준비의 저장소 열기·범위 조회 오류는 필요 없음(`null`)과 구분한다. `StandaloneRebuildGate`가 오류 화면과 '다시 시도'를 유지하고 준비 전체를 재실행한다. 정상 판정 전에는 `onDone`으로 메인에 진입하지 않는다. 다른 계정의 DB는 기존 계정 복구 화면을 유지한다.


## 과태료 금액 오타 해석

`범칙금_과태료` 원문과 DB 교환 값은 보존한다. 정상 정수/천 단위 쉼표·점 표기는 그대로 읽는다.
깨진 구분자 묶음은 구분자를 제거한 숫자와, 첫 묶음(1~3자리)을 유지하고 뒤 묶음을 3자리로 맞춘 숫자만 후보로 만든다.
짧은 묶음은 끝에 0을 붙이고, 긴 묶음은 3자리 뒤가 모두 0일 때만 그 0을 지운다(다른 숫자는 바꾸지 않는다).
기존 fine_estimate 금액표(기본·2시간 가중)와 위반 조항별 법정 금액표의 합집합에 후보 하나만 일치할 때 확정으로 읽는다.
일치 없음/복수 일치/사용 가능한 규칙·조항 없음은 금액 미확인이며 기존 추정 대상 판정으로 이어진다. 범칙금에는 과태료 규칙을 적용하지 않는다.
PC는 `services/fine_estimate.py`, 모바일은 `lib/services/fine_estimate.dart`가 숫자 판정 정본이다. 통계·업로드는 신고 맥락을 함께 넘긴다.
공유 시험 벡터는 `fine_amount_typo_vectors.json`이며 합성 후보 집합과 실제 법정 집합 모두에서 복수 일치 방어 조건을 검사한다.
파서 버전 pc-parser-7/mobile-parser-7은 기존 규칙·파서 버전 기반 재전송 경로를 다시 실행한다.
재전송은 journal 최신 payload의 추정 필드만 재계산하며, 확정 금액의 파서 보정은 새 상세 관측을 수집할 때 반영한다.
상세 화면의 보정값/원문 표기는 표시용이며 DB에 쓰지 않는다.

### 코드 대조 정정 — 금액 판정 입력과 토큰 경계

| 항목 | 정정된 계약 |
|---|---|
| 숫자 토큰 | `[0-9,.]+` 전체를 통계·업로드·표시가 공유한다. 앞/뒤 쉼표·점은 버리지 않고, 빈 묶음은 미확인으로 처리한다. |
| 판정 입력 | category, entry_value, ssnpc_cd, ssnpc_type, 신고명, 위반법규, 차량번호, 사진_첫촬영, 사진_끝촬영, 발생시각을 함께 넘긴다. 모바일 Report 변환은 fineRecordForReport가 정본이다. |
| 코드 우선순위 | 분류 코드가 있으면 메뉴보다 우선한다. 일반 주정차 메뉴 + EP-03은 fire_lane 500000원, 코드가 없으면 parking 40000원이다. 통계·업로드·목록/상세·추정 금액 내보내기 모두 같다. |
| 규칙 버전 | 양쪽 RULE_VERSION/ruleVersion은 2026-10-13.2. 파서 버전은 pc-parser-7/mobile-parser-7을 유지한다. 공유 벡터와 커뮤니티 계약 벡터·MANIFEST도 함께 변경한다. |
| 재전송 범위 | PC `_backfill_payload`, 모바일 `refreshFineEstimate`는 journal의 `amount`를 보존하고 `fine_estimate`만 재계산한다. 버전 상승만으로 과거 공유 확정 금액을 보정하지 않는다. PC의 종전 “로컬 값으로 payload를 만든다”는 설명을 이 코드에 맞춰 정정한다. |
| 저장·표시·내보내기 | DB와 내보내기의 확정 원문은 보존한다. 목록/상세만 해석한 보정값을 쓰고, 상세에만 원문 보조를 붙인다. 미확인 금액의 추정은 같은 상세 줄에서 별도로 표시한다. |

추정 과태료 업로드는 아직 미릴리스다. 코드 우선 적용으로 추정액·payload 해시가 바뀌는 범위는 있지만,
이미 배포된 추정값을 다시 보내야 하는 추가 부담은 없다. 기존 버전 기반 재전송 경로와 해시 멱등성은 유지한다.

### 기존 자료 재전송의 동시성·삭제 경계

`fine_estimate_resend`는 일반 동기화와 같은 `personal_sync` lease를 확보한 뒤 개인 DB 행을 읽는다.
잠금이 사용 중이면 완료 표시 없이 다음 실행에 맡기며, capture 발급 트랜잭션과 완료 표시 직전에 소유권을 확인한다.
`runBackgroundWork`로 DB 파일 교체와도 수명을 맞춘다. `report_latest`가 가리키는 journal이 `deleted_by_user`이면
후보에서 제외하고, 후보 조회 후 삭제될 경우를 위해 발급 트랜잭션에서도 다시 검사한다. 새 실시간 수집의 규칙은 그대로다.

### 코드 대조 정정 — 재전송의 최신 관측 보존

재전송은 발급 트랜잭션 안에서 같은 로컬 데이터셋·신고의 `source_revision`이 가장 큰 journal payload를 읽는다.
재공유로 계정별 과거 이력이나 `report_latest` 포인터가 달라도 최신 관측이 기준이다.
개인 DB에서는 ID와 추정 입력(접수 메뉴·분류 코드·차량번호·사진 시각·발생시각·신고명)만 읽는다.
법규는 journal payload를 사용하고, **`fine_estimate` 이외의 payload 필드와 신고번호는 그대로 보존**한다.
확정 금액이 있거나 과태료가 아니거나 추정 규칙이 없으면 추정 필드를 제거한다.
동일 payload면 계정 문맥이 달라도 새 이벤트를 만들지 않고, `detail_status`의 상태·관측 시각도 갱신하지 않는다.
`personal_save_state`가 pending/failed여도 보충을 허용하며, 개인 DB의 과태료 문구로 후보를 제한하지 않는다.
동의·계정 문맥·삭제 차단·기존 커서와 완료 표시는 유지한다. 스키마·개인 DB 원문은 변경하지 않는다.

중복차량 조회의 `normalize_plate` 보조 SQLite 연결은 DB 경로·SQL·인자만 전달한 별도 isolate에서
열기·정규화·조회·행 변환·닫기를 수행한다. 실패 때도 닫으며 호출자의 DB 수명 보호가 작업 완료까지 유지된다.
페이지 조회 TEMP 매핑의 `max_report_no`는 원본처럼 NULL을 허용한다. 신고 DB 스키마·원문·교환 계약은 바꾸지 않는다.

## 이륜 번호판 정규화와 추정 규칙 버전

| 규칙 버전 | 의미 |
|---|---|
| `2026-10-12.1` | 금액 오타 정리 규칙. 지역+시군구 이륜 번호판은 정규화되지 않아 승용등으로 추정하는 회귀가 있었다. |
| `2026-10-13.1` | 지역 필수 이륜형을 인식한다. `경기도군포시다2671` → `경기군포다2671`, 차종 `이륜`, 금액군 `이륜등`. 주정차는 추정 없음, 일반도로 버스전용차로는 40,000원. |

지역은 기존 사전의 긴 이름을 먼저 적용한다. 지역 뒤 시군구는 한글 1~3자이며 별도 `시/군/구` 접미 한 글자를 제거한다.
한 글자 지명 자체는 제거하지 않는다. 숫자 앞 마지막 한글은 용도 글자로 고정해 지명 분할을 추측하지 않는다. 접미 제거 뒤에도 두 글자 이상 지명이 `시/군/구`로 끝나
재정규화 결과가 달라지는 복수 접미 해석은 모호하므로 제외한다. 약칭과 지명 첫 글자가 다시 지역 정식명으로 읽히는 경우도 제외한다
(예: `경기도도봉다1234`를 줄인 `경기도봉다1234`의 `도`가 지역인지 지명인지 모호함).
지명 사전으로 오타를 교정하지 않으며, 지역 없는 `여수사6361`·`천안차2711`은 제외한다.
경계는 지역 앞과 숫자4 뒤에서 검사한다. 서로 다른 후보가 두 개 이상이면 미인식이다.
원문 차량번호·확정 금액은 그대로 보존하며 정규화된 값은 차종 판정과 중복차량 묶기에 사용한다.

규칙 버전이 달라지면 기존 재전송 완료 표식이 만료된다. 최신 journal payload의 추정만 재계산해
주정차의 잘못된 추정을 제거하고 버스전용차로 50,000원을 40,000원으로 교정한다.
다른 payload 필드는 유지한다. 재전송 완료 뒤 동일 버전으로 다시 실행하면 중복 이벤트를 만들지 않는다.
지도 수집기는 `rule_version`을 길이 제한 문자열로 받으므로 새 버전 허용 목록 변경은 필요하지 않다.
기존 중앙의 오계산은 각 PC·모바일이 업데이트 후 재전송해야 고쳐진다. SQL은 앱 추정을 임의로 다시 계산하지 않는다.


### 위반 조항별 법정 금액표

- 원문: [도로교통법 시행령, 시행 2026-10-02, 대통령령 제36728호](https://www.law.go.kr/LSW/lsInfoP.do?lsiSeq=290387&efYd=20261002).
  [별표 6](https://www.law.go.kr/LSW/flDownload.do?flSeq=169705915&bylClsCd=110201)(별표 개정일 2025-03-18),
  [별표 7](https://www.law.go.kr/LSW/flDownload.do?flSeq=169705941&bylClsCd=110201)(별표 개정일 2020-12-01).
  시행령 시행일과 별표 개정일은 서로 다르다. 작성일 2026-10-13. 원문 PDF SHA-256도 JSON metadata에 저장한다.
- PC `services/data/traffic_fine_table.json`, 모바일 `assets/data/traffic_fine_table.json`은 바이트 동일하다.
  44개 조, 세부 항·호와 상위 합집합 포함 110개 조회 키. 각 키의 `amounts`는 차종별 원 단위 집합,
  `references`는 `별표번호:행번호`, `includes`는 상위 조·항에 합산한 확인된 하위 조항이다.
  원문이 차종별로 나누지 않은 정액·기간 가산액은 `차종무관`에 두고 행위자/적용 범위를 `notes`에 기록한다.
  제50조제4항은 `개인형이동장치`로 별도 구분하여 승용·승합·이륜 금액에 섞이지 않게 한다.
  `제160조제3항`은 부과 근거이지 위반행위 조항이므로 조회 키가 아니다. 감경·체납 가산금·별표 8/10 범칙금은 제외한다.
- `제14조5항`/`제14조제5항`, 공백, 법률명 생략을 정규화한다. 조 및 호의 `의2`는 보존한다.
  다른 법률, 복수 조항, 미확인 하위 조항을 상위 조항으로 추측해 연결하지 않는다.
  항 생략 시에는 표에 명시한 상위 집합만 조회한다(예: 제25조의2는 확인된 제1항·제2항의 합집합).
- `legal_fine_amounts`/`legalFineAmounts`는 기존 `_RULES`의 기본·2시간 가중 금액을 유지하고 해당 위반 조항의
  차종별 일반·보호구역·속도 구간·2시간 가중 금액을 합친다. 번호판 미상은 그 조항 전 차종,
  화물의 4톤 경계·긴급차 원차종 미상은 승용등+승합등을 사용한다. 추정 함수의 기존 차종 선택은 바꾸지 않는다.
  표로 보호구역 여부나 실제 부과액을 계산하지 않으며, 오직 깨진 숫자의 두 후보 대조에만 쓴다.
- 정상 형식 금액은 표와 달라도 그대로 읽는다. 깨진 숫자는 후보 중 정확히 하나만 집합에 포함될 때 읽는다.
  0개 또는 2개 일치면 원문/금액 미확인을 유지한다. 제23조의 `40,0000` → `40,000`.
  실제 법정 집합에도 모호성이 있다: 별표 6 제10호의3(법 제50조의3제6항)은 10만원부터 500만원까지
  10만원 단위 기간 가산액이므로 `100,0000`의 10만원/100만원 후보가 모두 맞아 보정하지 않는다.
- `_RULES`, `classify`, `estimate`의 대상 유형·추정 금액은 그대로다. 다만 보정 성공으로 금액 미확인 여부가 바뀐다.
  제23조는 추정 규칙 없이 확정 4만원이 되고, 일반 주정차+제32조 `120,0000`은 기존 추정 4만원 대신 확정 12만원이 된다.
  따라서 양쪽 규칙 버전 `2026-10-13.2`로 기존 재전송 경로를 재실행한다. 파서 버전은 pc-parser-7/mobile-parser-7 유지.
  커뮤니티 observations 벡터의 규칙 버전·canonical JSON·해시·MANIFEST는 PC/모바일 사본만 변경한다.
  지도 저장소 정본 반영은 통합 담당자가 수행해야 한다.
  **재전송 한계:** 기존 backfill은 journal의 `amount`를 보존하므로 과거 공유된 금액 미확인을 보정하지 않는다.
  화면·로컬 통계와 새 상세 관측의 payload에는 즉시 적용되고, 과거 공유 금액은 새 상세 관측 때 반영된다.
- Python은 모듈 기준 경로로 JSON을 읽고 PyInstaller 데이터 옵션에 포함한다.
  모바일은 `tool/generate_traffic_fine_table.py`가 같은 JSON 전체를 `traffic_fine_table.g.dart`에 그대로 넣는다.
  동기 함수·백그라운드 isolate에서 초기화 순서 없이 사용하며 Flutter asset 비동기 로딩은 필요 없다.
  `--check`와 시험이 원본 JSON/생성 문자열/벡터의 SHA-256 일치를 검사한다.
- PC `web/routers/filters.py` → `fine_corrected_text`에는 위반법규가 이미 전달된다.
  Client 페이지 API는 위반법규를 포함한 원문 필드를 반환하고 `ApiService.getReportsPage` → `Report.fromJson` → `law` →
  `fineRecordForReport`로 전달한다. 목록 `ReportCardMetaItem.fine` → `fineTextForReport`, 상세 `_fineField` →
  `correctedFineText`를 사용한다. 화면 보정값·상세 원문 보조 표기만 달라지며 DB/내보내기 원문은 보존한다.

## Client 서버 검색 v1

AppMode.server의 조건 검색·전체 5분류 목록은 `/api/v1/app/config`의
`capabilities: [...,"report_search_v1"]`와 `report_search_version:1`을 모두 확인한 뒤
`GET /api/v1/reports/{category}/search`를 사용한다. 제품 버전·protocol 3·DB schema는 변경하지 않는다.
`category`는 5개 분류 또는 `all`. 파라미터는 `search_version=1`, `filter`(JSON 객체),
`offset`(결과 기준), `limit`(최대 200), `dedupe=canonical|raw`이다.

`ReportFilter.toSearchJson()`이 모든 필터를 전송한다. 문자열 키는 name/reportNumber/id/ratingCause/agency/
manager/carNumber/law/location/fine/supplementCount/reportContent/processContent/pollStatus 및
reportDate·occurDate·responseDate·occurTime 각각의 Start/End이며, ratings/statuses는 문자열 배열,
excludePolice/onlyPolice는 bool이다. 빈 조건의 의미·쉼표 OR/`&` AND·Unicode 소문자 부분 검색·
리터럴 `%`/`_`·법규 완전 일치·`__없음__`·별점 `__none__`·NULL·날짜/시각 경계는 기존
`ReportProvider.matchesFilter`와 같으며 양쪽 `contracts/client-search-vectors.json`으로 대조한다.
기관은 현행 registry 표시명, 상태는 canonical 표시값을 사용한다.

서버는 정확 판정과 중복 대표건 투영 후 신고번호 DESC/ID DESC 순서로 total·페이지를 같은
DB 스냅샷에서 구한다. COUNT 캐시는 없다. 응답은 기존 페이지 필드에 `search_version`, `filter` echo,
`server_ms`를 더하며, 모바일은 버전·조건·분류·offset·limit·dedupe를 검증한다.
full report(본문·처리내용·첨부·보완 포함)를 받아 기존 상세/편집 흐름을 유지하고,
`all`의 각 행 category를 임의로 덮지 않는다.

ReportProvider의 in-flight key는 epoch/revision/dedupe/category/offset/limit/**직렬화된 조건**을 포함한다.
한 소비자의 취소가 다른 소비자의 공유 요청을 끊지 않는다. LocalPagedReportList의 generation/sequence와
epoch/revision 검증으로 과거 검색 응답을 버리며 최대 3페이지 보관·다음 한 페이지 prefetch만 한다.
서버·키·계정·모드 전환은 `_resetDatasetView`에서 capability/페이지 in-flight를 무효화하고,
설정 갱신은 capability를 다시 반영한다. 같은 서버 주소에서 업그레이드한 경우 설정 새로고침으로 확인한다.

capability의 성공적인 미제공은 기존 `scanClientReports` 경로를 사용한다. 원본 200건씩의
취소 가능한 순회, 전체 정확 total 및 결과 400건 window를 유지한다.
인증/timeout/5xx, 새 검색 경로 404 또는 echo/버전 오류를 구버전으로 처리하지 않는다.
페이지 API까지 없는 서버에는 기존 업데이트 필요 오류를 표시한다.
임의 Dart predicate가 있는 `FilteredListScreen`의 대시보드 드릴다운 및 rating scope는 기존 정확 순회로
명시 분리한다. 조건 없는 단일 분류는 기존 `/page` 제한 조회를 유지한다. Standalone SQL 검색은 변경하지 않는다.
PC 계약을 먼저 배포하고 모바일을 갱신한다. Kotlin ServerContract에도 검색 capability/version 상수를
공유하지만 네이티브 백그라운드 작업에서 이 API를 호출하지 않는다.


## 명시 과태료 금액 문법 확대 (2026-10-14)

답변에서 과태료에 직접 연결된 정수 원·쉼표/점 묶음·정수 만원, 선택적 콜론·소괄호와 전각 숫자/구분자를 읽는다. Python `services/fine_amount_syntax.py`, Dart `lib/services/fine_amount_syntax.dart`는 같은 `contracts/explicit-fine-vectors.json`을 검증한다. 만원은 원 숫자로 환산해 기존 `범칙금_과태료`의 `과태료: N원` 형식으로 전달한다. 기존 공통 금액 파서의 손상 숫자 후보 보정·차종/법정 금액 대조는 그대로다.

상한·조건부 금액, 서로 다른 금액(감경 전후 포함)은 명시액 채택을 보류한다. 여러 값 중 첫 값이나 합계를 쓰지 않는다. 정수 만원만 추가하며 소수 만원·혼합 한글 단위·역방향 금액 문장은 미지원이다. 실제 데이터의 조건부 역방향 금액과 포상금은 채택하지 않는다. 범칙금/벌점 우선순위는 유지한다. 내부 None과 숫자0은 구분하지만 기존 외부 계약(숫자 읽기 실패도0,0은 추정 대상)은 변경하지 않는다.

처분을 결정하는 메뉴·수용 정책, 법규 인식, 최소 추정의 유형/금액/RULE_VERSION은 변경하지 않는다. 확정액을 읽으면 기존 통계·업로드 경로에서 추정 합계에 포함하지 않는다. 파서 버전만 pc-parser-8/mobile-parser-8로 올린다. 기존 버전 기반 재전송은 journal의 amount를 보존하고 fine_estimate만 재계산하므로 과거 답변을 자동 재파싱하거나 금액을 수정하지 않는다. 새 상세 수집에 적용되며 과거 값 보정은 별도 승인한 재파싱이 필요하다.


## 미확인 처분의 사건별 과태료 보완 (2026-10-14)

기존 처분/금액 파서와 최종 상태 판정, 취하 처분 제거가 끝난 뒤 `supplement_case_fine` / `supplementCaseFine`을 호출한다. 완료 상태(수용·일부수용·불수용·기타·답변완료)의 빈 처분 또는 미확인에만 적용한다. 명시액(0원 포함)·기존 과태료·범칙금·벌점·경고와 취하/이송/진행 상태는 유지한다.

답변의 문장·항목 경계를 유지하고, 실제 관측한 위반 확인→부과 결정, 완결된 부과 예정 문장, 사전통지서 발송, 구조화된 `처리결과: 수용(과태료 부과)`를 인식한다. 해당 사건의 부과 불가와 충돌하면 보완하지 않는다. 불수용 상태라도 본문에 해당 사건의 부과가 명확하면 처분을 과태료로 보완하되 원본 상태는 바꾸지 않는다. 구조화된 수용 결과가 명시된 경우에만 표시 처리상태도 수용으로 보완한다. 기존 메뉴별 수용 정책과 최소 추정 유형/금액/RULE_VERSION은 유지한다. 법규 저장·복수 조문 선택·조/호 오타 보정 및 기신고 전용 분기는 추가하지 않는다.

정본 구현은 Python `services/case_fine_supplement.py`와 Dart `lib/services/case_fine_supplement.dart`. 인식용 사본에만 기본 HTML entity/숫자 entity, 전각 ASCII, 공백 정규화를 적용하며 원문은 보존한다. `contracts/case-fine-supplement-vectors.json`은 실제 관측 답변 발췌에서 식별정보를 제거한 공통 회귀 입력이다. 원본 백업·개인 식별정보는 계약 벡터에 포함하지 않는다.

파서 버전은 pc-parser-9/mobile-parser-9. 기존 버전 기반 재전송은 journal의 원래 금액 판정을 보존하며 추정 필드만 재계산한다. 이번 변경에 과거 답변 자동 재파싱/DB 보정은 포함하지 않는다. 새 상세 수집에 적용되며 기존 데이터의 일괄 보정은 별도 작업이다.
