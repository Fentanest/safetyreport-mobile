# 데이터 계약·서버/DB·인증·집계 함정

> 이관 원본: 루트 `CLAUDE.md` (sha256 `32e8f475…9481`, 마지막 변경 커밋 `161b68dc`), 2026-09-24 분할.
> 본문은 원문을 **그대로** 옮겼다. 코드와 달라진 부분은 아래 "코드 대조 정정"에만 적고 원문은 고치지 않았다.
> 원본 전체 사본: [legacy-claude-reference.md](legacy-claude-reference.md) · 제목별 대응표: [README.md](README.md)

## 코드 대조 정정 (2026-09-24, base `c64be69a`)

| 원문 기술 | 현재 코드 | 근거 |
|---|---|---|
| SQLite `version 8`, 보완 요약 4컬럼 | **version 10**, 보완 컬럼 7개(`보완횟수`, `보완_미응답`, `보완_요청자`, `보완_요청일시`, `보완_완료일시`, `보완_요청_내용`, `보완_신고자_의견`) | `lib/services/local_db_service.dart:62,111-113,216` |
| errno=104 매트릭스의 "silent 3회 retry", Standalone API "최대 3회 재시도" | 공용 상수 `mobileMaxRetryAttempts = 5`, `mobileRetryDelaySeconds = 1` (같은 문서의 "설정 기본값 / 재시도 정책" 절과 일치) | `lib/services/network_retry_config.dart` |
| "Client 일반 API retry 없음" | 이번 단계 미재확인 → **미검증** | — |

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
  - 푸시 알림, foreground SnackBar, `pending_crawl_changes` 카드 시트, `신고 결과` 탭이
    같은 `report_detail` 을 열면 같은 신고번호의 일반 알림은 모두 읽음 처리한다.
  - 중복군 알림은 `duplicate_group_detail_sheet` 를 쓰므로 이 신고번호 공유 읽음 규칙에 포함하지 않는다.

## Client 중복 신고 API 호환성

- Client 서버가 아직 `/api/v1/duplicates/groups` 를 제공하지 않는 구버전일 수 있다.
- 이 경우 모바일은 `404`를 치명 에러로 취급하지 않고,
  `DuplicateManagementScreen` 에서 “서버가 중복 신고 관리 API를 아직 지원하지 않습니다.” 안내와 빈 상태를 보여준다.
- Standalone 모드는 HTTP가 아니라 로컬 SQLite projection 을 읽으므로 같은 `404` 증상은 발생하지 않는다.

## Standalone 인증 아키텍처

`lib/services/standalone_auth_service.dart`

### 로그인 흐름 (`dart:io HttpClient` 로 쿠키 자동 관리)

```
1. GET /api/v1/common/rsa/getPublicKey → RSAModulus + RSAExponent (hex)
   ↳ 서버가 Set-Cookie: JSESSIONID=xxx, HttpClient 자동 저장
2. password (UTF-8 bytes) → PKCS1 v1.5 RSA 암호화 (pointycastle) → hex 문자열 (512자)
3. POST /oauth/token (form-urlencoded)
   ↳ JSESSIONID 자동 전달 (서버가 RSA 키를 세션에 바인딩)
   ↳ client_id=web, grant_type=password, loginType=1, username, password(hex)
   → { access_token: "eyJ...", expires_in: 3599 }
```

**왜 `dart:io HttpClient` 인가**: `package:http` 의 정적 메서드는 매 호출마다 별도 클라이언트 → 쿠키 공유 안 됨. `HttpClient` 인스턴스 하나로 쿠키 자동 관리되므로 JSESSIONID 수동 추출 불필요.

### Play review 데모 모드

- SetupScreen / SettingsScreen 재로그인 다이얼로그에서
  `username=demo`, `password=demo` 입력 후 휴대폰번호를 비우거나 `demo`를 입력하면 진입
- `LocalDbService.seedPlayReviewDemo()` 가 아래 3건을 로컬 DB에 시드:
  - `SPP-2604-2344496` (traffic, 별점 5, 별점사유 있음)
  - `SPP-2604-0419411` (parking, 별점 5)
  - `SPP-2604-2344422` (other)
- `ReportProvider.isStandaloneDemo` true:
  - keep-alive 타이머 시작 안 함
  - pending queue drain, 실제 sync, 자동 재로그인 진입 안 함
  - crawl/sync 화면에서 동기화 버튼 비활성화 + 안내 카드 표시
- Play Console review credentials 에는 영어로 `Standalone mode -> username demo, password demo, phone blank allowed` 로 기재

### 토큰 만료 + 자동 재로그인

- 만료 5분 전부터 무효 판단 → `tryAutoRelogin()` 호출
- `flutter_secure_storage` (Android Keystore 기반) 에 비밀번호 저장
- `StandaloneApiService._getWithRetry()`: 401 → 자동 재로그인 후 1회 재시도
- 실패 시 `TokenExpiredException` → UI 가 수동 재로그인 다이얼로그

### 자격증명 저장

| 항목 | 저장소 | 키 |
|------|--------|-----|
| access_token | SharedPreferences | `standaloneToken` |
| 만료 시각 (ms) | SharedPreferences | `standaloneTokenExpiresAt` |
| 비밀번호 | FlutterSecureStorage | `standalone_password` |
| 아이디 | SharedPreferences | `standaloneUsername` |

## SQLite 스키마 (Standalone)

`lib/services/local_db_service.dart` — `standalone_reports.db`, version 8.

서버 DB 와 컬럼명 동일 (한국어). mobile-only 추가: `category`, `entry_value`, `raw_content`, `synced_at`.
2026-05-06부터 raw payload 의 정본은 `report_raw` 사이드카 테이블에 둔다.
2026-05-07부터 중복군 hash는 서버와 동일한 SHA-256 기준을 사용하고, version 7부터 `duplicate_group.apply_globally` 컬럼을 가진다.
version 8 부터 보완요청 마지막 round 요약 4컬럼(`보완횟수`, `보완_미응답`, `보완_요청_내용`, `보완_신고자_의견`) 이 `reports` 테이블에 들어간다. 잠시 존재했던 `report_supplement_history` 다회차 테이블은 `_addSupplementColumns()` 마이그레이션에서 DROP 처리된다.

```sql
CREATE TABLE reports (
  ID TEXT PRIMARY KEY, 상태 TEXT, 신고번호 TEXT, 신고명 TEXT, 신고일 TEXT,
  만족도조사여부 TEXT, 감시목록 TEXT DEFAULT 'N', 처리상태 TEXT, 차량번호 TEXT,
  위반법규 TEXT, 범칙금_과태료 TEXT, 벌점 TEXT, 처리기관 TEXT, 담당자 TEXT,
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
- `computeSummary(excludeWithdraw, normalizePolice)` — 대시보드 요약
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

선택 결과는 SharedPreferences 의 `pending_db_import` 키에 저장. SetupScreen 의 `_loginStandalone` 가 standalone 로그인 성공 직후 `_applyPendingDbImport()` 호출:
- `convert:<path>` → `LocalDbService.importFromServerDb(path)`
- `copy:<path>` → `LocalDbService.replaceFromBackup(path)`
- 적용 후 키 제거. 실패해도 로그인은 성공으로 처리 (SnackBar 만 안내).

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
| Client DB 다운로드 (서버→standalone 변환) | `ApiService.downloadDb` | 3회 / 1초 sleep / **2분** timeout (DB 가 MB 단위) |
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

- `POST /api/v1/crawl/enqueue` — 단건 큐 등록 `{"report_number": "SPP-..."}`
- `POST /api/v1/crawl/start` — 크롤링 시작 (mode/type/queue_list)
- `GET  /api/v1/crawl/config` — 크롤링 설정
- `GET  /api/v1/crawl/status` — 크롤링 상태 폴링
- `GET  /version` / `GET /version/latest` — 버전 / 업데이트 체크
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
  Kotlin `ServerContract.kt` 는 이 경로를 쓰지 않으므로 변경 없음.
- **Standalone** `LocalDbService.computeStatsOverview` / `summarizeOverviewRows` 가 같은 정의로 로컬 계산. `computeStats` 와 같은 행을 쓰도록 행 조회를 `_queryStatsRows` 로 분리(동작 동일).
- ~~연도 필터 기준 컬럼이 모드마다 다르다~~ → S-08 결정으로 두 모드 모두 **답변일**. 요약 화면 각주에 `year_basis` 로 표시한다.
- **기관/담당자 통계 행 규칙(S-10)**: 표 포함은 처리기관·담당자 값으로 정한다(처리상태로 빼지 않음). 배정된 처리중은 `in_progress` 로 따로 센다. 평균 처리일은 완료 신고만.
  서버 `report_stats_service._build_stats_tables` ↔ Standalone `LocalDbService.buildStatsCategory` 가 같은 정의 — 한쪽을 바꾸면 양쪽 테스트(`tests/test_report_stats_service.py`, `test/services/stats_tables_test.dart`)를 함께 고친다.
  서버 반올림은 `_round_half_up`(Dart `toStringAsFixed` 와 같음), 과태료 금액은 `40.000원` 점 구분자도 읽는다(`extractFineAmount` 와 같음).
- **DB v11 사진 촬영 시각** `reports.사진_첫촬영`(TEXT `YYYY-MM-DD HH:MM:SS`)·`사진_끝촬영`(TEXT)·`사진_촬영수`(INTEGER). 서버 detail/merge 와 같은 이름·형식, 서버 크롤러가 주정차 사진 EXIF 로 채운다.
  NULL = 아직 시도 안 함, `사진_촬영수 = 0` = 촬영 정보 없음. `Report` 모델에는 없으므로 `upsertReport`(REPLACE)가 기존 값을 이어받는다 — 모델에 없는 교환 컬럼을 추가할 때 같은 처리를 해야 한다.
  Standalone 은 아직 채우지 않는다(서버에서 가져온 값만 보존). 테스트 `test/services/photo_capture_columns_test.dart`.
- **서버↔모바일 DB 왕복 검사**(PROJECT_RULES §3-1): 서버 레포 `scripts/dev/db_roundtrip_check.py --mobile-repo <이 작업트리>` 가
  `test/tool/db_roundtrip_harness_test.dart`(환경변수 `SR_RT_MODE=import` 일 때만 실행, 평소 skip)로 이 레포의 `importFromServerDb` 를 호출한다.
  서버→모바일→서버, 모바일→서버→모바일 모두 원시 값 비교 차이 0(2026-09-24). 가져오기·내보내기 코드나 `reports` 컬럼을 바꾸면 돌린다.
  알려진 정규화(실제 데이터에는 나타나지 않음): 가져오기가 NULL→''(주소정규화·행정구역·지오코딩상태·캐시 error_message), NULL `synced_at`→가져온 시각. 저장 로직 리팩터링 때 NULL 보존으로 정리.
- **저장 계층 재설계 R0·R1(2026-09-24)** — 정본 계획은 서버 레포 `docs/plans/storage-refactor-plan.md`.
  - 계약 `contracts/storage-contract.json`(서버와 바이트 동일). `test/storage/storage_contract_test.dart` 가 스키마·버전 일치를 검사.
  - DB v12: `report_override`(사용자 수정값), `duplicate_decision`(중복 판단) 표 추가. 버전 상수는 `LocalDbService.dbVersion` 하나. 열 추가는 `lib/storage/schema_utils.dart addColumnIfMissing`(이미 있는 경우만 건너뜀).
  - 서버 DB 가져오기: 값 그대로(NULL 유지), 숫자 열 형 맞춤, `감시목록` 은 서버 `mysafety_watchlist` 로 전부 다시 계산하고 sync_meta 'watchlist' 를 항상 기록(서버 sync_meta 의 옛 사본은 무시), 새 표 복사, 표 읽기 오류는 가져오기 실패로(임시 DB 라 기존 데이터 보존).
  - 앱 백업 복원(`replaceFromBackup`): 종류(모바일)·버전(0 < v ≤ dbVersion) 확인 → 임시 사본 마이그레이션·무결성 검사 → `.bak` 롤백 교체.
  - 알려진 결함 고정 테스트 `test/storage/known_defects_test.dart`(M-1·2/3·12·24 — R3 에서 고치면 기대값을 뒤집는다).
