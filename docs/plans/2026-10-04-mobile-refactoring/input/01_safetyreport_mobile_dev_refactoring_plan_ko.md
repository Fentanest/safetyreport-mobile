# safetyreport-mobile/dev 전체 리팩터링 계획

문서 버전: mobile-refactor-plan-2026-10-04.1  
작업 모드: **PLAN ONLY — 구현·앱 실행·테스트·기기 조작·배포 승인 아님**  
대상: `Fentanest/safetyreport-mobile`, `dev`  
이번에 다시 확인한 HEAD: `ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60`  
커밋: 2026-10-03 08:23:25 UTC, `fix: remove hidden full report loads and bound duplicate rebuilds`  
첨부 감사 기준과 HEAD 차이: 없음. Sol이 사용할 때는 최신 상태를 다시 확인한다.

## 문서 읽는 순서

이 문서는 승인 후 실행할 **설계와 변경 단위**를 정한다. `04_work_items_and_evidence_ko.md`는 27개 발견별 재현·반증·변경 경계·수용 조건을 담는다. `03_source_audit_original.md`는 사용자가 첨부한 감사 원문을 바이트 변경 없이 보존한 것이다. `02_sol_planning_prompt_ko.md`는 Sol에게 계획의 현행성 확인과 상세화를 지시한다.

근거 표기: **[A]** 첨부 감사와 해당 발견 ID, **[R01]~[R12]** 이번에 다시 연 저장소 파일, **[O01]~[O04]** 공식 기술 문서. 자세한 경로·구간·검토 범위는 04 문서 끝에 있다. 아래의 “제안”은 현재 구현된 기능이나 확정된 서버 API가 아니다.

---

## 0. 핵심 결정

**전면 재작성보다 ‘삭제·완료·ACK의 근거를 확보한 뒤, 기존 bounded 구조의 첫 계산과 중복 작업을 줄이는 리팩터링’을 권장한다.**

순서는 다음과 같다.

1. 전체 동기화의 삭제 조건, 외부 DB snapshot/변환, rebuild 완료 판정을 먼저 안전하게 만든다.
2. 알림 처리 큐와 이력 보관을 분리하고, Dart·Kotlin·동기화·업로드의 작업 소유권과 계정/서버 세대를 일치시킨다.
3. 최근 답변 전체 조회, count/page 일관성, 지도 unknown·날짜·좌표 의미를 바로잡는다.
4. 이미 줄여 놓은 메모리 사용을 유지하면서 cold 인덱스·registry·통계·거대 중복군·반복 manifest 비용을 측정하여 줄인다.
5. Client의 기존 서버 API 한계는 모바일 내부 개선과 서버 공동 계약으로 분리한다.
6. 검증된 경계를 중심으로 큰 서비스와 Provider를 작은 책임으로 나눈다. 파일 분리 자체를 성능 성과로 계산하지 않는다.

### 이번에 하지 않는 일

제품 코드 수정, Flutter/Gradle/앱/테스트/벤치마크 실행, SDK·패키지 설치, 실제 로그인·수집·별점·업로드, 운영 DB 접근·변경, 실기기 앱 제거/초기화, 서명·VERSION 변경, push·PR 생성·릴리즈·배포를 하지 않는다. 작성한 검증 명령과 고장 주입은 **후속 승인 후의 절차**다.

Flutter/Provider/Navigator/sqflite 전면 교체, Compose 전환, 모든 코드를 isolate로 이동, largeHeap, 전체 자료 샘플링, 최소 Android 버전 상향, 감시·중복 기능 삭제를 기본 해법으로 삼지 않는다. 정밀 측정이 없는 속도 배수·완료 시간·배터리 절감률을 약속하지 않는다.

### 가장 먼저 준비할 구현 묶음

첫 묶음은 PR0의 계약·fixture 설계와 PR1A/1B/1C의 **삭제/교환/완료 안전성**이다. 각각 독립 변경으로 검수한다. 인지된 파괴 가능성을 그대로 둔 채 조회 성능 PR에 먼저 합치지 않는다. 다만 읽기 전용 프로파일 설계나 독립적인 UI 분석까지 전부 중단시키지는 않는다.

---

## 1. 근거와 검증 범위

### 1.1 이번에 수행한 것

- 연결된 GitHub로 `dev` HEAD를 다시 읽어 첨부 감사 SHA와 일치함을 확인했다.
- 첨부 감사 본문, 27개 발견, 검증 한계, 624개 파일의 기존 검토 범위표를 계획의 출발점으로 사용했다.
- 저장소의 규칙·bounded 조회·Client 인계·sync·외부 snapshot·rebuild·native inbox/알림·최근 답변·과거 검수·저장 계약 등 **12개 파일의 전체 또는 지정 구간**을 다시 열었다. 긴 응답은 실제 확인된 구간만 근거로 삼았다.
- WAL, Future timeout, Flutter 성능 측정, Android 알림 채널에 관한 공식 설명을 설계 전제 확인용으로 참고했다.
- 계획 문서와 인계 파일을 생성했다. 기존 감사 파일은 변경하지 않았다.

### 1.2 수행하지 않은 것

이번에 624개 파일을 새로 모두 심층 감사하지 않았다. 첨부 감사의 447개 텍스트 확보·blob 대조나 작은 SQLite 실험을 재실행하지 않았다. Flutter analyze/test, Kotlin/Gradle/lint, APK/merged manifest, emulator/S24, 실제 sync·DB 왕복·성능·전력·OOM/ANR 재현은 모두 **NOT_RUN**이다.

코드에서 가능한 실패 경로를 찾았다는 것과 실제 이용자의 자료가 유실됐다는 것은 다르다. 과거 Galaxy S24/58,388건 제보는 재현 우선순위의 근거다. 현 dev에서 같은 장애가 난다는 뜻도, 원인이 OOM이라는 뜻도 아니다. [A §5, 부록 B]

### 1.3 발견 상태 표기

- `RECHECKED_STATIC`: 이번 지정 구간에서 해당 코드 구조를 다시 확인했다. 통합 재현 통과 아님.
- `BOUNDARY_RECHECKED`: 화면/종료/호출 경계 일부를 확인했다. 전체 경로는 첨부 감사 근거이며 추가 확인 필요.
- `AUDIT_SOURCE`: 첨부 감사의 발견을 유지한다. 이번에 해당 전체 경로를 새로 검증하지 않았다.
- `HISTORICAL_REPORT`: 저장소/감사가 보고한 과거 실행. 이번 실행 수치가 아니다.
- `PROPOSED`: 이 계획에서 권장하는 설계·테스트·분리 방법.

Sol은 실행 시 `현재도 존재 / 이미 해결 / 반증됨 / 미재현 / 판단 자료 부족`을 따로 적는다. 같은 SHA라도 정적 추론이 틀렸을 수 있으므로 반증 절차를 생략하지 않는다.

---

## 2. 현재 구조와 책임 지도

현재 제품은 이미 접수한 신고를 조회·관리하는 Android 앱이다. Flutter UI·Provider·SQLite와 Kotlin 알림/WS/FGS·MethodChannel을 함께 사용한다. Client와 Standalone은 같은 화면을 일부 공유하지만 작업의 수행 주체가 다르다. [R01, R02, A §2]

```text
앱 시작 / 알림 탭 / launcher quick action
  → main.dart / app_routes.dart
  → 설정·모드·카카오·동의 gate / Provider 초기화
  → 5개 하단 탭 및 필요한 route의 지연 생성

Standalone 읽기
  화면 → ReportProvider / report_query / repository
      → LocalDbService → SQLite effective projection / COUNT / TEMP snapshot
      → 좁은 페이지 / 가중치 집계 / Report DTO → 차트·목록·지도

Client 읽기
  화면 → ReportProvider / ApiService
      → self-host 인증·protocol 검사 → 서버의 실제 집계/페이지 API
      → bytes / UTF-8 / JSON / Report → 화면
  ※ 일부 scope는 아직 전량 응답 또는 후보 페이지 내 필터에 머문다.

Standalone 쓰기
  수동 sync / native 알림 inbox / 예약·resume
      → SyncEngine / StandaloneAutoSyncService
      → 사이트 인증·목록·상세 → capture / 개인 DB save
      → 중복 projection / 변경 알림 / sync 상태 / uploader

커뮤니티
  account / gate / context → capture retry journal / community store
      → rebuild staging 또는 immutable outbox → lease / batch / ACK

Kotlin
  NotificationService / WsService / SyncForegroundService
      ↔ SharedPreferences inbox / MethodChannel / Dart worker
```

이 지도는 호출 경계 요약이다. 전체 caller inventory를 대체하지 않는다. 상세 호출자는 PR0에서 함수 단위로 대조한다. 위 모듈 이름은 기존 경로이며 아래 제안 계층과 구별한다.

### 2.1 데이터와 writer

| 자료 | 의미·주요 writer | 리팩터링에서 보존할 것 |
|---|---|---|
| 개인 reports / raw | 사이트 원본과 로컬 저장 | 원문·타입·NULL·ID를 성능 목적으로 변형하지 않음 |
| 사용자 override·감시·중복 결정 | 사용자 의사 | 재동기화·자동 대표·교환이 덮거나 잃지 않음 |
| 중복 group/member·digest | 파생 자료 | source/decision revision에 맞는 결과만 원자 publish |
| sync_meta / job 상태 | 진행·성공·복구 근거 | 목록 성공과 상세 완전 성공을 혼동하지 않음 |
| community capture / outbox / staging | 공유 원문·전송 내구성 | event ID·payload·revision·ACK 불확실성·owner 보존 |
| native inbox / retry journal | 아직 처리되지 않은 의무 | UI 이력 보관 상한으로 unacked work를 지우지 않음 |
| registry / query cache / TEMP | 해석·조회용 파생 자료 | 원본으로 오인하지 않음; identity와 revision 무효화 |
| prefs / secure storage | 설정·모드·권한 상태 | Dart/native/headless 소비자와 migration 순서 확인 |
| media / export / backup | 임시 캐시 또는 사용자 파일 | 미완성 파일과 정상 완성본 구분; 실패 시 기존 파일 보존 |

실제 writer는 UI isolate 하나로 한정되지 않는다. background isolate, Kotlin, DB 교환, 직접 connection, file operation이 존재할 수 있다. 같은 프로세스의 bool·Future·refcount만으로 모든 writer가 직렬화된다고 가정하지 않는다. [A DB-03, S-04, N-08]

### 2.2 주요 경로의 실행 장소를 표로 만든다

PR0에서는 각 `await` 전후를 표시하여 다음을 채운다: 호출자, isolate/thread, 읽는 DB/설정, 보유한 lock/lease, 네트워크 side effect, 결과 반영 지점, 취소 가능 지점, dispose 후 잔여 작업.

`async`라는 이유로 CPU 계산이 UI isolate 밖에 있다고 쓰지 않는다. native SQLite 실행, MethodChannel 복사, Dart 변환·누산, raster 지연을 별도 항목으로 측정한다. `runBackgroundWork`는 현재 close를 막는 보호일 수 있으며, 업무 간 상호 배제나 background engine 소유권과 동일하지 않다. [A S-04, R03]

---

## 3. 유지할 기능과 데이터 계약

### 3.1 기능 보존 매트릭스

| 기능 | 현재 진입점 / 참고 경로 | 필수 검증 |
|---|---|---|
| 시작·모드 전환 | main.dart, setup/settings, report_provider | server/standalone별 초기화, gate/epoch, 이전 계정 화면 미노출 |
| 대시보드 | dashboard_screen, computeSummary | 정확한 전체 건수와 preview 구분, 최근 답변·감시 전체 진입 |
| 신고내역 4분류 | report_list_screen, local_paged_report_list | 페이지 경계, 검색·선택·상세·복사와 실제 모집단 |
| 신고관리 4탭 | rating/watchlist/duplicates/editor | 미평가·0점, 수동 대표, 사용자 수정 보존 |
| 통계 | statistics_screen, stats_* widgets | 개인 통계·Sunwi 구분, 경찰/비경찰·기관/담당자·법규·금액 의미 |
| 지도 | report_map_screen, map query/presentation | 전체 메타·viewport·cluster·주소 상세·missing의 일치 |
| 상세·첨부 | report_detail_sheet, client_media_access | 원문 표시, 정부 출처, 올바른 media·origin별 자격증명 |
| 알림 3탭 | notifications / history provider / native | 큐와 이력 구분, 탭/상세 이동, 중복·늦은 event 처리 |
| sync/crawl | sync_engine / crawl_screen | Client 서버 작업과 Standalone 로컬 동기화의 상태 분리 |
| DB 백업·교환·파일 | local_db_service, db_export_location | 전체 값 왕복, 기존 DB 보호, 실제 저장 위치·파일 크기 |
| 카카오·동의·공유 | community/* | owner/context/freshness/lease/ACK, 재개와 로그아웃 |
| 내비게이션·접근성 | app_routes/main, selection scopes | 하단 0~4, 옛 native 5/6, shortcut, 뒤로가기·선택 취소·IME |

기능 상세는 `docs/design/feature-matrix.csv`를 기준으로 확장한다. 여기에 없는 행도 누락하지 않는다. 이 표는 CSV의 모든 항목을 새로 실행해 보았다는 의미가 아니다. [A §2~3, R01~R02]

### 3.2 가장 높은 우선순위: DB 교환

정본에 현재 서버 schema 5 / 모바일 schema 16이 명시돼 있다. 제품 VERSION·wire protocol 3과 서로 다른 버전 축이다. [R12]

서버→모바일→서버, 모바일→서버→모바일에서 **교환 대상 모든 entity와 모든 컬럼의 값·타입**을 비교한다. 단순 건수, DB 파일 크기, 대표 몇 행 또는 checksum 한 개로 대체하지 않는다. NULL과 빈 문자열, integer/real/text, ID 선행 0, 한글·개행·날짜, raw·override·중복 결정/member·sync_meta·owner를 포함한다.

저장 시 NULL과 빈 문자열의 구분은 유지한다. 특정 change notification에서 둘을 같은 변경값으로 다루는 계약과 저장·왕복 계약을 혼동하지 않는다. [R12]

새 컬럼·값 의미·변환 정책 변경은 서버 동시 계약/변환/양방향 테스트/배포 순서가 필요한 **공동 작업**이다. 모바일 단독으로 교환 스키마를 올리지 않는다. 반면 TEMP lookup·정확한 필터·UI 정렬 캐시처럼 교환 의미를 바꾸지 않는 개선은 공동 스키마 변경과 분리한다.

### 3.3 통계 불변 조건

- 원본 상태, canonical 표시 상태, lifecycle, 중복 raw/canonical은 별개의 축이다.
- 일부수용·과태료·불수용 등 기존 중첩 의미를 임의의 배타적 enum으로 축소하지 않는다.
- 확정 금액과 추정 금액은 다른 값이다. 원문·표·합계·내보내기에서 섞지 않는다.
- 표/차트/지도/필터/상세/다운로드의 날짜·결측·분모·대표건 규칙을 공유 벡터로 대조한다.
- 같은 이름의 다른 기관·담당자를 합치지 않는다. 현행 기관 해석과 당시 원문을 함께 보존한다.
- `not_duplicate`, `review_required`, 수동 대표와 기존 동률 결정, 비대표 감시가 대표에 계승되는 규칙을 보존한다.
- 최적화된 구현과 legacy oracle이 다를 때 “새 결과가 더 그럴듯하다”로 채택하지 않는다. 기존 버그 수정인지 계산 회귀인지 별도 결정한다.
- 법률·금액 규칙 자체를 이번 성능 계획으로 새로 판단하지 않는다. [A §3, R02~R03]

### 3.4 보안·사용자 경험 불변 조건

auth/protocol/owner/consent 검사를 생략하지 않는다. 캐시된 화면 열람과 신규 외부 작업 허용 정책을 구분한다. 출처·비공식 고지, 5탭과 기존 하위 분류, 별점 1,000 rune·개행·실패 draft·취소 미제출을 유지한다.

측정에는 비식별 run ID, stage, epoch, revision, 개수·bytes·시간만 남긴다. 토큰·쿠키·키·알림 본문·신고 원문·차량번호·개인 주소를 로그·스크린샷·fixture·프롬프트에 넣지 않는다. 필요한 회귀는 합성값으로 만든다.

---

## 4. 이미 적용된 개선을 회귀시키지 않는 기준선

아래는 첨부 감사와 bounded 문서가 설명하는 현재 보호다. 이번 계획은 이를 다시 만드는 계획이 아니다. [A §4, R03]

| 기존 보호 | 잘못된 리팩터링 | 유지/개선 방향 |
|---|---|---|
| dashboard 전체 category preload 제거 | 탭 진입을 빠르게 하려고 startup에서 모두 읽음 | 필요한 탭만 준비, 첫 데이터와 초기 비용을 함께 측정 |
| summary SQL COUNT·preview 200 | preview 길이를 전체 count로 사용 | total과 preview 타입/라벨 분리 |
| 통계 narrow TEMP·1,000 그룹 stream | 큰 Report 배열을 isolate에 통째로 보냄 | 좁은 batch·backpressure·가중치 보존 |
| revision·epoch·sequence | 건수만 같으면 캐시 재사용 | 같은 건수 수정·복원·다른 계정도 무효화 |
| native 큐 진입 전 취소 재검사 | 결과만 버리고 CTAS를 계속 예약 | 대기 중 폐기와 실행 중 취소 한계 분리 |
| 지도 메타와 ≤1,024 로컬 셀 | 셀 제한으로 전체 신고를 잘라 집계 | 전체 메타 별도, cluster는 확대·상세 분리 |
| duplicate digest 128·staging·원자 publish | raw 전체 또는 group 전체 Report 복제 | giant group의 작은 hash도 별도 메모리 예산 검사 |
| 그룹/멤버 50 페이지 | 수동 대표 선택 때 전량 멤버 로드 | membership 단건 확인과 페이지 밖 대표 유지 |
| DB JOIN 128행 가져오기 | 누락을 막으려고 전체 원문 Map 구축 | preflight 정확성 + 같은 bounded 전송 |
| 사진 decode·MediaStore 개선 | 원본 decode 또는 전체 파일 bytes 회귀 | decode 크기·pending publish·완성 검증 유지 |

각 보호에 대한 기존 테스트를 찾아 재사용한다. 소스 문자열이 있다는 검사와 실제 런타임 제한이 지켜지는 검사를 구분한다.

---

## 5. 권장 목표 구조 — 현재 프레임워크 안에서 분리

다음 이름은 **설계상 책임이며 제안 신규 모듈**이다. 이 경로/클래스가 이미 있다는 뜻이 아니다. 처음에는 기존 facade 뒤에 작은 순수 함수·adapter로 도입하고, 동작 검증 뒤 이동한다.

```text
화면 / Provider
  ├─ QueryCoordinator: query key, 구독자, latest result, 취소, snapshot
  ├─ OperationCoordinator: 작업 admission, 실행 소유권, 세대, 재개
  └─ ViewModel: exact total / preview / progress / 오류 / 적용 조건

데이터 계층
  ├─ ReportReadRepository: count/page/detail/membership
  ├─ AnalyticsRepository: narrow snapshot + typed accumulator
  ├─ DbExchangeService: snapshot/preflight/reconcile/publish
  └─ DuplicateProjectionService: existing bounded builder 유지

작업 계층
  ├─ SyncRun / RebuildRun: persisted 결과와 완료 조건
  ├─ InboxClaimStore / RetryJournal: 내구성·claim·ack
  └─ OutboxRunner: 기존 event/lease/ACK 계약을 유지

플랫폼 경계
  └─ NativeRuntimeAdapter: config generation, WS, 알림, FGS 상태
```

### 5.1 공통 컨텍스트의 최소 정보

제안 `OperationContext`는 mode, account identity, server origin/config generation, dataset epoch, DB connection identity, source revision, registry snapshot identity, operation/run ID, cancellation 상태를 **불변 snapshot**으로 보유한다. 실제 비밀 값은 로그용 context에 넣지 않는다.

계정·주소·키·동의·모드 변경 시 기존 작업의 admission을 닫고 generation을 증가시킨다. 새 요청 전, 중요한 await 후, 로컬 결과 publish 직전의 generation/owner를 비교한다. 오래된 세대의 응답은 새 DB·새 계정에 반영하지 않는다.

다만 이미 원격에서 접수된 POST는 generation 변경으로 되돌릴 수 없다. 이를 “취소 성공”이라 보고하지 말고 옛 scope의 `unknown outcome` 또는 확인 대기 기록으로 보존한다. 전송 전 fence와 전송 후 reconcile은 다른 방어다.

### 5.2 오류/결과 타입의 의미

| 상태 | 의미 | 큐/화면/재시도 |
|---|---|---|
| loading / preparing | 준비 또는 정상 읽기 진행 | 0건으로 표시하지 않음 |
| ready / empty | 검증된 결과가 있고, empty는 정확한 0 | total·조건·revision 함께 표시 |
| stale | 이전 성공 결과가 남음 | 이전 조건과 갱신 중/실패를 표시, 다른 계정에는 재사용 금지 |
| busy / deferred | 기존 작업이 owner | join/defer, 실패나 성공으로 소비하지 않음 |
| partial | 일부만 완료 | 성공/실패/대기 개수와 다음 행동, 전체 완료 금지 |
| retryable | 일시 실패 | 내구 큐 유지, 제한된 backoff·Retry-After |
| blocked | 인증/동의/호환/owner 문제 | 자동 반복 중단, 데이터 보존, 해결 후 명시 재개 |
| failed_permanent | 계약상 확정된 영구 실패 | 명시 결과와 필요 시 gap 승인; 단순 404 문자열만으로 확정 금지 |
| cancel_requested | 중지 요청 수락 | 아직 실행 중인 SQL/atomic save와 구분 |
| cancelled | 소유한 작업 종료 확인 | 전송 미확인 side effect가 있으면 별도 남김 |
| unknown_outcome | 외부 반영 여부 불명 | 자동 중복 POST 금지, 조회/ACK 확인 또는 사용자 안내 |

기존 public response/enum을 한 번에 전부 바꾸지 않는다. 내부 typed result를 먼저 도입하고 호환 adapter로 기존 UI·API와 연결한다. 성공처럼 보이던 오류가 더 명확하게 드러나는 변화는 사용자 영향으로 기록한다.

### 5.3 취소의 세 가지 시점

1. **대기 전/대기 중:** 아직 필요 없는 SQL·HTTP를 큐에 넣지 않는다. owner 작업을 기다린 뒤에도 취소를 다시 확인한다.
2. **실행 중:** 소유한 transport에 실제 abort/close를 전달한다. 공유 로그인 refresh는 다른 대기자가 있으면 한 구독자의 취소만으로 끊지 않는다. native SQL은 현재 지원되는 취소 수준 이상을 약속하지 않는다.
3. **commit 중/후:** 원자 저장은 일관되게 끝낸다. commit 뒤 UI가 닫혔다고 저장 사실을 지우지 않는다. 다음 작업 예약과 UI 적용만 막고 journal을 통해 상태를 복구한다.

`Future.timeout`은 원래 Future의 완료를 막는 취소 API가 아니다. 따라서 timeout 문구가 뜨는 시각과 실제 작업이 idle이 되는 시각을 따로 계측한다. [O02]

---

## 6. 데이터 안전성 설계

### 6.1 fullSync: 부재를 삭제 근거로 쓰려면 먼저 완전성을 증명

대상: `sync_engine.dart`의 목록 수집·`removeReportsNotIn` 호출, `standalone_api_service.dart`, `local_db_service.dart`. 발견 S-02/S-08. [R05, A S-02]

현재 예외/stop 때 삭제를 막는 방어는 유지한다. 그러나 HTTP 200과 빈 값이 아닌 목록만으로 중간 page 누락·반복·동시 목록 이동을 배제할 수 없다.

**제안 흐름**

```text
run admission + immutable owner/epoch
  → 목록 응답 shape 검사
  → page 범위·cursor·unique ID를 좁은 staging에 기록
  → 선언 total/수집 unique/종료 조건/중복 page/동시 변경 검증
  → authoritative inventory 여부 판정
       불충분: 정상 받은 행만 upsert, 기존 부재 행 보존, partial/재확인
       충분: 삭제 후보 계산 → owner/revision 재확인 → 승인된 cleanup
  → 상세 성공/대기/실패와 목록 성공을 별도로 마감
```

“완전성 증명”은 제안 내부 결과 타입이다. 공식 사이트에 snapshot token이 있다고 가정하지 않는다. count가 맞아도 같은 수의 추가·삭제나 페이지 이동이 가능하다. 안정된 snapshot/cursor 보장을 확인할 수 없다면 **absence만으로 파괴적 cleanup을 허용하지 않는 기본안**을 채택하고, 확인용 재조회/기존 자료 유지 정책을 명시한다.

0건 결과는 정상 0·인증 실패·잘못된 응답·부분 목록과 구분한다. 원격 0이라는 이유로 즉시 로컬 전체를 지우지 않는다. 기존 제품 계약에서 정상 빈 계정의 정리 의미를 확인한다. 보존해야 할 override/raw/중복/감시 관계를 하나의 삭제 단위로 정의한다.

목록 staging은 raw/body를 저장하지 않고 run ID·신고 ID·필요 상태·page 검사 정보만 둔다. 장기 persisted staging을 도입하면 개인 교환 DB에 섞지 않고 기존 community/job 저장소와 복구 journal의 적합성을 비교한다. 신규 저장 형식은 버전·정리·복구 정책을 함께 설계한다.

### 6.2 rebuild: 반환 객체가 아니라 영속 item 상태로 완료 판정

대상: `community_rebuild.dart`, `rebuild_helpers.dart`, `sync_engine.dart`. 발견 S-01. [R07, A S-01]

`list_complete`, pending/retryable/permanent 상태와 run owner를 commit 직전에 읽는다. API 상세 조회 성공뿐 아니라 capture·item 상태 저장의 성공까지 반영한다. `pending > 0` 또는 `failed_retryable > 0`이면 completed가 될 수 없다. 영구 누락이 있으면 기존 확인 UI에서 사용자가 명시 승인한 해당 run의 누락 집합만 `completedWithGaps`로 마감한다.

읽기 검증과 publish 사이에 다른 작업이 상태를 바꾸지 못하도록 같은 DB transaction 또는 유효한 revision/lease 조건부 publish를 설계한다. 별도 DB가 둘 이상이면 둘 전체가 자동으로 원자적이라고 가정하지 말고 prepare/commit journal과 재시작 복구를 정의한다.

staging merge의 **삭제 없음**은 유지한다. 로컬 rebuild 완료, outbox 생성, 중앙 업로드 ACK 완료는 별개의 결과다. 중앙 네트워크 실패를 이유로 완료된 로컬 원본을 롤백하거나, 로컬 완료를 중앙 반영 완료로 표시하지 않는다.

### 6.3 외부 DB: snapshot 획득·preflight·변환·publish 분리

대상: `local_db_service.dart` snapshot/import/export, storage contract/tests. 발견 DB-01/DB-02. [R06, R12, A DB-01~02]

권장 절차는 다음과 같다.

1. 입력의 출처를 구분한다: 정상 종료된 단일 백업, 살아 있는 DB 경로, content URI로 받은 파일, sidecar 포함 묶음. 읽기 가능한 main 파일만으로 일관된 snapshot임을 자동 보증하지 않는다.
2. 외부 원본은 변경하지 않는다. 일관된 export/backup 또는 writer가 멈춘 것으로 확인된 입력을 private 작업 사본으로 확보한다. 임의로 main/WAL을 따로 복사한 뒤 size/mtime만 같다고 동시 writer 안전을 선언하지 않는다.
3. 필요한 WAL 복사/open/checkpoint가 실패하면 명확히 중단한다. checkpoint 반환 상태와 단일 완성 snapshot을 검증하고, 확인 전 sidecar를 지워 성공으로 만들지 않는다. WAL에는 아직 main에 없는 commit이 존재할 수 있다. [O01]
4. schema·owner·entity·키·관계·카디널리티를 **변환 전** 검사한다. INNER JOIN으로 사라질 orphan, category 간 ID 충돌, 빈 ID, raw/override/member 관계를 확인한다.
5. 지원 계약에 맞는 모든 행을 보존하거나 모호한 입력을 명확히 거절한다. 일반 SQLite에서 가능하다는 이유만으로 rowid 0/-1을 skip하지 않는다. 실제 지원 계약이 허용한다면 cursor의 시작 경계를 고쳐 포함한다.
6. 검증된 입력 snapshot 하나를 128행 JOIN/page로 변환한다. `INSERT OR REPLACE` 충돌로 원본 두 행을 한 행으로 줄이는 것을 정상 변환으로 인정하지 않는다.
7. keyed reconciliation으로 모든 교환 entity의 키 집합·값·타입을 대조한다. 정상 0건 DB도 정책에 맞게 별도 처리하며 `count > 0`을 무결성 증거로 쓰지 않는다.
8. 검증 통과 후 기존 file-operation/background barrier 안에서 publish한다. 실패/취소/디스크 부족이면 기존 DB·사용자 변경·입력 사본을 보존한다. 임시파일 cleanup 실패는 원인과 재정리 대상만 남긴다.

외부 파일에 애초에 WAL이 누락되어 전달됐다면 main만으로 모든 누락 commit을 검출할 수 있다고 약속하지 않는다. 지원 입력 형태와 “어느 방식으로 백업해야 하는가”를 사용자 안내·계약에 적는다. `quick_check` 성공은 관계·모든 값 보존 검사를 대신하지 않는다.

---

## 7. 큐·native·권한·백그라운드 설계

### 7.1 history 제한과 processing 내구성 분리

대상: `PrefsInbox.kt`, Dart `prefs_inbox.dart`, `standalone_pending_queue_store.dart`, `standalone_auto_sync_service.dart`, `capture_retry_store.dart`. 발견 N-04/S-03/S-04. [R08, A 관련 항목]

현재 unique key append 보호는 유지하되 HISTORY 보관 상한과 처리할 QUEUE의 생존 조건을 분리한다. 200을 2,000으로 늘리거나 메모리 List를 무제한으로 만드는 안은 채택하지 않는다.

**제안 claim/ack 흐름**

```text
native 수신
  → durable event key/sequence 저장 성공
  → Dart가 특정 event key 집합을 claim
  → 해당 owner/epoch의 작업 수행
  → 로컬 결과 또는 재시도 의무를 영속 기록
  → claim한 event key만 ACK/삭제
```

같은 신고번호의 새 알림이 처리 도중 들어와도 새 event key는 소비하지 않는다. number dedupe는 작업 결합에만 사용하고 ACK 식별자로 사용하지 않는다. 완료 기록 뒤 ACK 전 crash이면 재실행이 같은 로컬 결과를 만들도록 멱등 처리한다. native prefs의 `apply`가 반환했다는 사실만으로 원하는 수준의 내구성이 확보됐다고 단정하지 말고 지원 저장소의 crash 창을 검증한다.

history는 제품 허용 보관 정책대로 제한할 수 있다. unacked queue는 디스크 예산·backpressure·명시 overflow 상태를 둔다. 공간 부족 때 조용히 옛 작업을 삭제하거나 “처리 성공”으로 표시하지 않는다. journal 방식 변경은 legacy CSV/기존 key migration과 중도 재시작을 포함한다.

### 7.2 sync/drain/rating/upload의 admission

현재 별도 running flag나 DB close 보호는 업무 상호 배제를 모두 보장하지 않는다. 제안 coordinator는 dataset/account별로 어떤 조합이 동시에 가능한지 명시한다.

| 조합 | 기본 제안 |
|---|---|
| 같은 dataset의 manual sync + auto drain | 단일 owner. drain은 join/defer, fallback 재진입 deadlock 방지 |
| local read + 짧은 save | 지원 connection 정책 안에서 허용; count/page snapshot 보장 |
| DB 교환 + 쓰기/읽기 publish | 기존 barrier 유지, 새 admission 차단, 종료 확인 후 교환 |
| 별점 POST + 동일 대상 별점 POST | 중복 admission 금지; 응답 불명은 자동 재제출하지 않음 |
| outbox 업로드 + sync | 기존 capture-before-save·lease·pace를 지키는 범위에서만 허용 |
| mode/account 변경 + 이전 작업 | 새 세대 admission 전에 이전 소유권을 정리하고 결과 fence |

retry journal의 atomic rename은 파일 찢어짐 방지와 lost update 방지가 다른 문제다. read-modify-write 전체를 직렬화하거나 버전 CAS/transaction을 사용한다. 여러 isolate/native 경계라면 Dart 단일 Future 잠금만으로 끝내지 않는다. community DB 장애 때도 retry intent가 필요하므로 이를 고장 난 DB에만 종속시키지 않는다.

### 7.3 연결 세대와 권한 freshness

대상: `ReportProvider.setConfig`, settings, `WsService`, `NotificationService`, `ClientGateGuard`, `ServerVersionCompatibility`, gate/uploader. 발견 N-02/N-03/S-06.

서버 A→B, 키만 변경, A→B→A, 로그아웃, 동의/모드 변경을 서로 다른 generation으로 본다. native 서비스가 이미 running이라는 이유로 새 설정을 무시하지 않도록 stop/rebind/revalidate 책임을 한 곳에 둔다. callback과 POST dispatch 직전 owner/generation을 확인한다.

compatibility 결과는 per-call immutable 값으로 반환하고 connection generation에 묶인 cache로 보관한다. 여러 probe가 전역 failure 값을 덮어 써 결과를 섞지 않게 한다.

foreground 신규 작업 60초와 장애 시 성공 cache 600초는 첨부 감사에 함께 기록되어 있다. 600초 허용 자체를 결함으로 단정하지 않는다. **열람 / foreground write / background read / background write별 승인된 정책표**를 먼저 작성하고 Dart/native가 같은 의미로 검사하게 한다. 미래 clock·재부팅·시각 역행·malformed timestamp 때 유효기간을 무한 연장하지 않는다.

owner/register/manifest/secure write 같은 후속 await에서도 generation을 확인한다. 중앙 서버의 재검증은 별도 방어이며, 낡은 로컬 context를 활성화해도 괜찮다는 근거가 아니다. `personal_save_state`는 현재 표시용 계약이므로 이것만으로 전송 차단 여부를 임의 변경하지 않는다. [A S-06 및 추가 계약]

### 7.4 native 알림과 호환성

원본 title/body는 package allowlist 검사 전 로그에 쓰지 않는다. 허용된 앱도 기본 로그는 유형·개수·실패분류로 제한한다. 원문 알림을 수집·보관하는 별도 진단 기능을 추가하지 않는다. [R09]

알림마다 raw thread를 만들기보다 제한된 worker와 대기열을 제안한다. connect/read/whole-operation deadline, 자원 finally close, 작업 중지와 Retry-After를 구분한다. `auto_enqueue_count`는 외부 요청 시도와 접수 성공의 의미를 분리하고 수동 크롤 완료 알림까지 억제하지 않게 한다.

POST의 응답 유실은 접수 실패의 증거가 아니다. 서버에 멱등 키나 접수 조회 계약이 없으면 무조건 재전송하는 구현은 보류하고 unknown outcome을 명시한다. 새 correlation 필드는 서버 공동 계약 없이 보내지 않는다.

API24/25 지원은 실제 merged manifest와 고정 SDK를 후속 검증한다. 채널 API는 API26 이상에서 사용하도록 모든 producer를 점검하고, 낮은 버전의 호환 알림을 보존한다. 최소 지원 버전을 몰래 올려 문제를 숨기지 않는다. [A N-01, O04]

알림 ID/tag, PendingIntent action/data/requestCode, FGS 예약 ID를 구분한다. 평범한 화면 이동 intent와 한 번만 실행해야 할 quick command를 분리한다. intent 소비와 process recreation을 검증하되 외부 side effect의 exactly-once를 로컬 flag 하나로 보장한다고 쓰지 않는다.

### 7.5 FGS는 작업 소유권의 증거가 아니다

FGS 알림 존재·HOME 복귀와 실제 Dart engine/작업 생존은 다른 관측이다. 기본안은 **실제 owner 확인 + checkpoint 복구 + 명확한 중단/재개**다. 곧바로 headless engine 전면 재설계를 시작하지 않는다. [A N-08]

HOME, Activity 재생성, task removal, OS process kill, force-stop을 다른 케이스로 테스트한다. FGS 시작 거절/timeout·nested refcount와 Dart running이 일치해야 한다. force-stop 뒤 계속 실행된다는 보장은 하지 않는다. 요구가 “화면과 독립적으로 지속 실행”으로 확정되면 engine/worker 소유권 변경을 별도 설계 승인 대상으로 분리한다.

---

## 8. 조회 정확성과 화면 상태 개선

### 8.1 DB 준비와 read snapshot

`_initFuture` 실패 뒤 같은 오류 Future만 반환하지 않도록 identity-safe reset을 제안한다. 이전 실패 Future의 finally가 새로 시작한 정상 Future를 지우지 않게 한다. close도 실패에 안전하게 캐시/connection identity를 정리하되 사용 중인 DB를 강제로 닫지 않는다. [A DB-06]

기관 TEMP lookup은 connection+source revision+registry identity별 single-flight로 준비한다. shared table DELETE/INSERT의 일부만 보이는 상태를 막고, 동일 connection transaction 안에서는 그 transaction executor를 사용한다. 독립 호출을 기다리다 스스로의 DB queue를 기다리는 교착을 만들지 않는다. REPLACE나 예외 무시로 충돌을 숨기지 않는다. [A DB-03]

count+page, missing group+preview는 짧은 read snapshot으로 일관되게 읽거나 bounded revision retry를 적용한다. 이미 바뀐 revision에 과거 total을 붙이지 않는다. 무한 재시도 대신 갱신 중/재조회 상태를 제공한다. 마지막 행이 사라진 경우 빈 preview를 정상적으로 처리한다.

### 8.2 최근 답변은 preview와 전체 목록을 분리

대시보드의 200건 preview는 유지한다. “더보기”는 같은 최근 3일 경계·정렬·raw/canonical·override 규칙의 exact count/page를 조회하도록 설계한다. 화면의 total은 받은 preview의 길이가 아니다. 로컬은 bounded SQL로 구현 가능한 경로이며, Client는 실제 서버 계약 유무를 별도로 판단한다. [A UI-01, R10]

초기 loading, 이전 결과 refresh, 정상 empty, 실패를 분리한다. error를 `3일 내 답변 ... 없습니다`로 표시하지 않는다. 199/200/201/1,001건과 preview 밖 최근 자료, 자정·NULL·override·중복 조건을 검증한다. 느린 연속 페이지나 계정 전환 후 과거 응답은 반영하지 않는다.

### 8.3 지도 unknown과 유효성

`_MapCellAccumulator`가 직접 센 unknown을 중첩 처분 개수의 합으로 다시 빼지 않도록 설계한다. 직접 predicate 또는 판정된 행의 union을 사용한다. fine+rejected 한 행과 unknown 한 행이면 실제 unknown 1을 보존해야 한다. `_weight > 1` 및 여러 셀에서도 동일해야 한다. [A DB-04]

날짜는 통계 계약상 strict calendar-day parser를 통일하고 overflow 날짜·타임존/DST·역전일을 별도 처리한다. 원본 문자열을 “정리”해 DB에 덮지 않는다. 좌표의 finite/range 유효성을 map metadata와 missing drilldown에서 일치시킨다. missing 주소가 전체와 합쳐졌을 때 정확한 동일 모집단이 되는지 확인한다. [A DB-05]

### 8.4 첨부 열기·캐시

`_openExternal`은 filename만으로 이전 파일을 재사용하지 않도록 resource identity를 설계한다. origin, 리소스 URL 또는 안정 ID, dataset/account/credential generation과 완성 여부를 묶는다. 비밀 query/token을 로그나 노출 파일명에 넣지 않는다. 인증이 바뀌어도 무조건 캐시를 같이 쓰는 기본안은 채택하지 않는다. [A UI-02]

동일 filename 다른 URL·계정, 동시 다운로드, 부분 파일, 바뀐 원격 내용, timeout을 구분한다. 임시 `.part`와 완료본을 분리하고 검증 뒤 원자적으로 게시한다. Content-Length가 없는 응답은 무조건 불량으로 오인하지 말고 지원 transfer 규칙을 명시한다. 다운로드는 byte budget·deadline·취소와 실제 cleanup을 갖추되 전체 bytes/string을 중첩 보관하지 않는다.

서버 자격증명은 승인된 same-origin 경계에만 전송한다. 정부/CDN 첨부에 self-host API 키를 붙이지 않는다. “다른 앱 열기”는 파일 완료 이후의 UI 행동이며 background에서 강제로 파일 앱을 띄우지 않는다.

### 8.5 통계·목록 화면의 배치 원칙

map 레포의 참여자 랭킹 3탭·순위표를 이 앱에 이식하지 않는다. 이 앱의 기존 5탭과 개인 통계/기관·담당자·법규·경찰 구분이 기준이다.

제안은 새 통계나 장식 추가가 아니라 **안정된 조건 영역 → 선택한 결과 → 상세 비교**의 읽는 순서다. 기존 다크/라이트 토큰·라벨·분모 설명·접근성을 유지하고, 별도의 인사이트/운영 포인트/중복 KPI 카드를 만들지 않는다.

- 연도·분류·정렬·검색 입력과 적용 결과를 구분한다. 조회 중 UI 선택은 반응하되 이전 값을 새 조건의 결과로 위장하지 않는다.
- 통계 `_visibleRows`의 반복 copy/filter/sort는 source/result revision+필터+정렬 key로 한 번 계산해 재사용한다. build는 이미 계산한 view를 읽도록 한다.
- Provider 전체 갱신이 모든 탭을 재구축하는지 계측하고 필요한 필드만 구독하도록 좁힌다. 무조건 모든 notifyListeners를 제거하지 않는다.
- ListView의 지연 생성, 키보드·가로 화면·큰 글자·scroll position·선택 취소를 보존한다.
- 목록 페이지/필터 변경 시 선택 대상 의미는 기존 “현재 페이지” 계약을 유지한다. 사용자 모르게 전체 선택으로 바꾸지 않는다.
- chart 표시용 점 수를 줄여야 한다면 집계/내보내기/tooltip 의미와 구분하고 허용된 표현 축약만 사용한다. 계산 자료를 샘플링하지 않는다.

---
## 9. 성능·메모리·네트워크·전력 개선 계획

### 9.1 cold 통계: 이미 narrow해진 다음 구간을 측정

대상: `LocalDbService.computeStatsBundle`, 집계 accumulator, `agency_registry.dart`, `PerformanceTrace`, 통계 화면. [R03, A §5, UI-03]

현재 흐름은 `DB open/인덱스 → registry → native CTAS/GROUP BY → 좁은 1,000그룹 전달 → Dart 가중치 누산 → 기관표/overview → chart/view`로 나누어 본다. UI isolate에 raw 전체가 있는 옛 흐름으로 가정하지 않는다.

| 후보 | 조사·개선 제안 | 채택 조건 / 기각할 경우 |
|---|---|---|
| 최초 인덱스 준비 | 실제 중복 index·쿼리 plan·추가 준비 시간을 확인하고 필요한 순서로 준비 | 첫 조회 정확성 유지. 인덱스 없이도 안전한 fallback과 준비 상태가 없으면 무작정 뒤로 미루지 않음 |
| registry 초기화 | snapshot 초기화와 distinct pair 해석 재사용 확인, 불필요 중복 parse 제거 | manifest/버전 교체 때 무효화. 전체 identity를 임의의 기관명 문자열로 축소 금지 |
| GROUP BY 압축률 | 원본 행 N과 그룹 G, G/N·임시 disk·정렬 비용 측정 | G≈N이면 불필요한 high-cardinality 키 제거 가능성을 계산 의미와 대조 |
| 전달 비용 | native row bytes·MethodChannel 복사·Dart map 생성 비용 분리 | batch 크기는 실험 변수. batch 키우기로 메모리·입력반응을 악화시키면 기각 |
| 누산 | 행/그룹당 반복 날짜·상태·금액 parse를 typed metric으로 재사용 | 확정/추정·가중치·NULL·유효 표본과 반올림 순서 oracle 일치 |
| 출력 view | 차트/표 공통 결과, 정렬·필터 모델의 revision cache | 같은 값 수정·다른 필터·계정의 과거 결과 재사용 금지 |
| isolate 경계 | CPU가 큰 순수 누산만 좁은 입력으로 offload 비교 | 전송/복사/worker 준비가 더 비싸면 유지. 원문 전체 이관 금지 |

COUNT와 상세 집계가 모두 필요하더라도 같은 projection/정규화 일을 반복하지 않도록 한다. 그렇다고 모든 지표를 영구 집계 테이블에 저장하는 설계를 첫 단계로 쓰지 않는다. persistent derived aggregate 도입은 모든 writer의 무효화·교환 영향·복구·디스크 예산이 증명될 때 별도 제안한다.

다른 사용자가 요구하지 않은 날짜 기준 변경이나 분모 변경을 성능 개선에 섞지 않는다. 잘못된 기존 규칙을 고치는 경우는 correctness PR로 분리하고 공통 벡터와 승인 근거를 남긴다.

### 9.2 중복 계산: bounded와 빠름은 다르다

대상: `bounded_duplicate_rebuild.dart`, `duplicate_projection_service.dart`, duplicate repository, sync/auto-drain. [A S-08, R03]

128행 digest, worker acknowledgment, source revision 검증, staging 연결, 최종 원자 publish와 legacy 동률 규칙은 유지한다. 다음 비용을 별도 측정한다.

- 첫 digest 생성, digest cache hit/miss, 원문 길이, distinct field hash 개수.
- 작은 군 다수와 1~2개의 giant group을 별도 workload로 구성한다.
- worker에 남은 hash 목록의 bytes·최대 resident 수, sort/majority 계산량.
- main/임시 DB의 총 read/write bytes, staging 공간, 최종 publish native queue 점유.
- 조회·동기화·사용자 대표 결정이 겹쳤을 때 revision retry 횟수와 실패/취소 cleanup.

**의사결정만 바뀌는 fast path**를 후보로 둔다. 원문 digest/자동 추천을 바꿀 필요가 없는 수동 대표·상태 변경이라면 해당 군의 projection만 갱신할 수 있는지 검증한다. 전체 rebuild oracle과 동률·감시 계승·알림·foreign writer parity가 맞아야 채택한다. 변경 의존성이 불명확하면 기존 bounded full rebuild로 fallback하되 사용자에게 실제 진행을 표시한다.

기존 3회 revision 재시도 등을 무한 루프로 바꾸지 않는다. 계속 writer가 바뀌는 조건은 deferred/retry 안내와 기존 정상 projection 보존으로 처리한다. 처리량을 높이려고 원자 publish를 부분 교체로 바꾸지 않는다.

### 9.3 sync의 전량 상태와 반복 후처리

`existingStatus`, `allItems`, `toSync`, `capturedEventIds` 등의 계정 크기 메모리를 조사한다. 실제 필요한 ID/상태만 run staging과 SQL join으로 옮기는 방안을 비교한다. 목록 완전성 증명에 필요한 모든 ID를 없애는 것이 아니라 **보관 위치와 projection을 줄이는 것**이다. [A S-08, R05]

누적 captured ID 전체를 매 10건마다 다시 조회하는 progress 계산은 run별 증분 집계/상태 변경 delta로 바꾸는 후보를 둔다. progress 값은 정확한 source state를 기준으로 하고, ACK 변화·재시작·오류 때 다시 reconcile 가능해야 한다. 100% 표시를 빨리 하기 위해 대기 이벤트를 빼지 않는다.

auto-drain의 건별 duplicate refresh는 작은 batch/checkpoint로 합칠 수 있는지 검증한다. 실제 변경 알림을 보존하고 각 건의 실패·ACK 경계가 유지되어야 한다. 외부 사이트 요청 간격이나 uploader pace를 없애 처리량을 높이지 않는다.

### 9.4 gate poll·manifest·uploader 비용

기존 60초 poll 자체를 무조건 늘리는 것이 아니라 status 확인과 manifest 전체 재구축의 결합을 조사한다. 변경 없음 버전/ETag/delta를 중앙 정본이 실제 지원하는지 확인한다. 제안 API를 호출하지 않는다. [A S-07]

full manifest가 필요한 경우 page 단위 staging, 키 유일성, cursor 전진, 예상 count, owner/lease/generation 검증 뒤 atomic publish한다. old manifest를 먼저 지워 부분 자료만 남기지 않는다. 소유한 client는 finally close하고 빌린 shared client는 임의로 닫지 않는다. run마다 고유 lease owner와 유효한 renewal/조건부 release를 사용한다.

저장소 감사가 계산한 58,388키의 최소 12페이지·행별 insert 횟수는 코드상 작업량 단서다. 이를 측정한 요청 시간이나 운영 비용으로 바꾸어 쓰지 않는다.

uploader의 20 event / 256KiB UTF-8 envelope, 1.1초 spacing, lease/heartbeat, scoped cooldown, immutable retry, unknown ACK, one-shot rating, capture-before-personal-save를 유지한다. 전역 재시도 flag나 공통 cache로 각각의 scope를 섞지 않는다. [A 추가 계약]

### 9.5 Client 내부에서 바로 가능한 개선

실제 서버 API를 바꾸지 않아도 query snapshot·불필요 total 요청 재사용·취소·동일 요청 single-flight·decode 경계·화면 제한 표시·메모리 수명은 개선 후보다. 재사용 key는 origin/config generation/owner/filter/dedupe/sort/페이지와 유효한 revision을 포함한다. 서버가 revision을 주지 않으면 영구적으로 cache를 유효하다고 취급하지 않는다.

현재 category별 limit1 COUNT 대기 후 실제 page 요청의 비용을 계측한다. 잘못된 병렬화로 전량 세 category 응답을 한꺼번에 쌓지 않는다. 전송 bytes→string→map→Report의 순간 중복을 측정하고 큰 decode isolate는 transfer 비용·취소·fallback까지 비교한다. isolate를 쓰더라도 full HTTP body를 여러 번 들고 있으면 완전한 bounded 해결이 아니다. [A UI-03~04, R04]

### 9.6 전력·장시간 메모리

배터리 성과는 요청 수 감소만으로 확정하지 않는다. 동일 기기·화면/백그라운드 상태에서 wakeup, CPU running, 네트워크 bytes/요청, 작업 재실행, 메모리 plateau와 가능한 장치 계측을 기록한다. thermal·충전·화면 밝기·네트워크 조건을 고정하거나 한계를 명시한다.

hidden 탭의 ticker·observer·timer·poll·native connection이 계속 필요한지 확인한다. 필요한 WS/알림 감지를 UI 성능 때문에 끄지 않는다. HOME·resume·idle·logout 후 잔여 작업과 bounded queue 길이를 관찰한다. 실제 에너지 측정이 없으면 “전력 소비 감소 후보”이지 “배터리 N% 절약”이 아니다.

---

## 10. 서버/다른 저장소와의 계약 의존성

아래 표는 모바일 `client-read-handoff.md`의 **현재 계약과 제안**을 기준으로 작성했다. 이번에 서버 전체를 새로 조사·수정한 것이 아니다. 서버팀 인계 시 최신 PC HEAD에서 다시 검증한다. [R04]

| 인계 ID | 현 상태 | 모바일 단독으로 할 일 | 서버 공동 작업이 필요한 일 |
|---|---|---|---|
| C-01 | 실제 category page와 viewport map 연결 | 기존 경로 유지, 취소·로딩·identity 검증 | 변경 필요 시 additive 계약/compatibility 명세 |
| C-02 | 복합 조건은 현재 후보 페이지 내 적용 | `전체 대상 N / 페이지 조건 일치 M` 명확화 | 전체 필터 COUNT·정렬·연속 page 및 snapshot/revision |
| C-03 | summary recent는 200 preview, watchlist 전량 가능 | preview를 total로 표시하지 않음, decode 수명 개선 | exact totals·bounded previews·번호 membership 계약 |
| C-04 | watchlist/duplicates/missing에 큰 응답 가능 | 실제 응답 관측, 안전한 실패·취소·재진입 | scoped group/member/missing pagination, 정확한 총계 |
| C-05 | 전체 custom status·ID→category 단건 계약 부족 | 현재 제공 범위만 정직하게 표시 | DISTINCT filter metadata·lookup API 정본 |
| C-06 | PC 거대 중복군 복원의 과거 미완료 보고 | 동일 합성 fixture·모바일 출력 근거 인계 | PC 계산 개선과 giant-group 실제 양방향 검증 |
| C-07 | schema5/16 교환 계약 | 모바일 preflight/실패 보존 개선 | 컬럼/값/변환 변경 시 양쪽 동일 단위·전체 값 왕복 |
| C-08 | enqueue POST 멱등/접수조회 지원 확인 필요 | unknown outcome 보존·폭주 차단 | 필요 시 correlation/idempotency/조회 정본 확정 |

### 공동 계약의 필수 항목

1. endpoint·method·params·DTO·오류코드·인증/protocol·capability를 명확히 한다.
2. raw/canonical, OR/AND 검색, 경찰/법규/NULL/날짜/별점 eligibility/감시 계승을 같은 공용 벡터로 검증한다.
3. COUNT와 page가 같은 snapshot인지 정의한다. revision 변화 시 명시 재시작/충돌 정책을 둔다.
4. 기존 full endpoint를 몰래 잘라 page처럼 반환하지 않는다. 기존 소비자를 위한 additive/협상 방식으로 도입한다.
5. 신서버+구모바일, 구서버+신모바일, 양쪽신버전 조합을 표로 검증한다. capability 부재 시 없는 API를 반복 호출하지 않는다.
6. rollout은 계약·서버 구현/검증 → 모바일 capability 연결 → 양쪽 통합 검수 → 승인 배포로 구분한다. 기존 protocol3 차단 의미를 약화하지 않는다.

모바일 전용 read/UX 개선은 위 서버 의존성 때문에 모두 막히지 않는다. 그러나 C-02~05가 미완료인 상태에서 “Client의 전체 50만 건 기능·메모리가 완전히 bounded”라고 완료 보고할 수는 없다.

---

## 11. 단계별 변경 단위와 의존성

첨부 감사의 **PR0~PR6**를 유지하고, 내부를 작은 단위로 세분화했다. 이는 PR 생성/코드 수정 지시가 아니라 후속 구현 승인 시의 변경 계획이다. 각 단위의 실제 diff 크기가 크면 추가로 나누되 안전성 수정과 대규모 이동을 섞지 않는다.

```text
PR0  근거·계약·fixture·측정 설계
 ├─ PR1A fullSync 삭제 증명
 ├─ PR1B 외부 DB snapshot / preflight / reconciliation
 └─ PR1C rebuild terminal 검증
        ↓
 PR2A 큐 claim/ACK·typed outcome
 PR2B 연결 세대·gate·transport 경계
 PR2C native 로그·알림·채널·one-shot intent
 PR2D FGS/engine 소유권 확인과 복구 계약
        ↓
 PR3A DB read·TEMP·map/date 정확성
 PR3B recent 전체 조회·media identity·화면 상태
        ↓
 PR4A cold 통계·준비·view 모델
 PR4B 중복·sync 후처리·manifest 비용
        ↓
 PR5A Client 내부 요청·decode
 PR5B 서버 공동 계약 연결 (별도 의존성)
        ↓
 PR6A facade 뒤 책임 분리 / dead branch 정리
 PR6B 통합 검수·CI·운영 적용 준비
```

화살표는 모든 파일을 순차 편집하라는 의미가 아니다. source 안정성·계약·테스트 의존성을 뜻한다. PR1B와 PR2C처럼 독립 영역은 분리 작업 가능하지만 `local_db_service.dart`, Provider, main, 공통 계약·Manifest/Gradle에는 single writer를 둔다.

### PR0 — 현황·불변 조건·fixture·측정 기반

**대상:** 정본 docs/feature matrix/contracts, tests/tool/performance trace. 신규 테스트명/모듈은 제안으로 표기한다.

**작업:** 최신 HEAD delta와 변경자 inventory, 27개 발견 상태 재분류, API/DB/WS/MethodChannel 계약표, source·derived·queue write 경계 작성. 실행 승인 뒤 사용할 fake clock/HTTP/DB fault hook 설계와 비식별 계측 정의. 현 baseline은 결과를 가져오기 전까지 NOT_RUN.

**선행 검사:** 테스트 fixture가 운영 endpoint, 기기 운영 app ID, 실제 계정/서명에 접근하지 않는지 정적으로 검토. 기존 test가 source grep인지 함수/위젯/통합 실행인지 구분.

**통과:** 27개 ID가 모두 구현/검증/보류 단위에 연결되고, source path·함수·추론·현재 방어·반증법이 존재. 권한·실행 전제 누락 없음.

**롤백:** 문서/계측 추가만 되돌릴 수 있으며 제품 behavior/DB/queue에 변화가 없어야 한다. 계측이 원문/비밀을 남기면 후속 단계 중단.

### PR1A — 전체 동기화 목록 완전성과 삭제 장벽

**대상:** sync engine 목록 loop/cleanup, standalone API 응답 파싱, local DB 삭제 함수. S-02, S-08의 staging 경계 일부.

**변경:** untyped null→empty를 계약 검증 결과로 분리하고 page/unique/변경 evidence를 모은다. 완전성 부족은 기존 row/raw/override 보존과 partial/revalidate로 귀결. source snapshot 보장 없는 count-only cleanup 채택 금지.

**선행 회귀:** 401건 중 middle short/duplicate/빈ID/반복page/null result, total 유지하며 한 건 교체, list HTTP 오류/stop. 각 경우 기존 row/raw/override 값 전체 비교.

**통과:** 불완전 inventory의 삭제 0; 명확한 정상 정책의 cleanup만 수행; 기존 사용자 override/감시/중복 의미 보존. 실패 뒤 last_success를 갱신하지 않는지 검사.

**대안/롤백:** 광범위 목록 polling 반복으로 완전성처럼 보이게 만드는 안을 기각. 결과 구조 변경은 adapter로 기존 UI 유지. rollback해도 검증 안 된 삭제를 되살리지 않고 보호 경로를 유지한다.

### PR1B — snapshot과 DB 교환 보존

**대상:** `_prepareExternalDbSnapshot`, import JOIN/cursor/insert/publish, export/close barrier, storage tests. DB-01/DB-02.

**변경:** 일관된 source snapshot 획득·sidecar 실패 거절·검증된 private snapshot 재사용, entity preflight와 keyed reconciliation. narrow JOIN 페이지는 유지. 새 schema/컬럼은 이 PR의 기본안에 없음.

**선행 회귀:** WAL-only commit, sidecar copy/open/checkpoint 실패, 동시 writer·disk full, valid+orphan, cross-category ID, rowid0/-1, unknown column, raw/member orphan, 정상 0건 입력. destination과 원본의 불변 비교.

**통과:** 지원 입력 전체 값/타입 보존 또는 명시 거절. 실패 전후 기존 DB/파일/owner 불변, 임시본을 완료 파일로 잘못 표시하지 않음. 스키마 의존 변경은 별도 공동 승인.

**롤백:** 이전 정상본으로 복구할 수 있는 journal/backup 경계. 새 입력을 읽지 못하는 옛 코드로 자동 downgrade 금지. 앱 제거·데이터 초기화를 롤백으로 제안하지 않는다.

### PR1C — rebuild 완료·부분 성공·commit 조건

**대상:** rebuild engine/controller/helpers, sync result/item state. S-01, S-03 일부.

**변경:** typed run result, persisted item 상태·list completion·owner/gen·gap approval를 commit 직전에 검증. pending/retryable이 남으면 complete하지 않는다. no-delete merge 보존.

**선행 회귀:** 실제 engine+fake HTTP에서 first detail503, 중도 stop, item 상태 쓰기 실패, retry 승격, resume·process death, gap 승인 전후. 결과 객체만 임의 생성하는 fake 한 종류로 끝내지 않는다.

**통과:** pending/retryable 잔존 상태에서 completed 0; 취소/실패와 UI·DB 상태 일치; local completion과 upload ACK 구분.

**롤백:** 기존 staging·item journal을 유지하고 active run을 옛 엔진으로 재해석하지 않음. 누락 승인 목록은 run별로 보존.

### PR2A — 큐 claim·ACK·retry journal·admission

**대상:** native/Dart inbox, pending queue, auto sync, capture retry store. N-04/S-03/S-04.

**변경:** history 상한과 processing 수명 분리, claim key 단위 ACK, typed retry/blocked/busy 처리, dataset coordinator와 journal RMW 원자성. 기존 unique append·CSV migration·community 장애 시 복구 경로 보존.

**선행 회귀:** 199/200/201/1,000, 같은 번호 재게시, add/add·add/remove interleave, ACK 전 crash/commit 뒤 crash, failed/busy fallback, 429→200/503→200.

**통과:** unique unacked 누락 0; fetch 중 새 알림 소모 0; deadlock 0; disk/queue pressure는 명시 상태. HTTP 시도 횟수와 성공 ACK를 혼동하지 않음.

**롤백:** 새 queue/journal 버전은 역호환 또는 명시 차단. migration 완료 전 legacy queue 삭제 금지. 내구 데이터와 폐기 가능한 cache를 분리.

### PR2B — 연결·계정 세대와 네트워크 수명

**대상:** Provider.setConfig/settings, WS/native enqueue, ClientGateGuard/compatibility, auth service, gate/uploader. N-02/N-03/N-06/S-05/S-06.

**변경:** immutable generation, dispatch/await/publish fence, per-call compatibility result, 승인 freshness 정책, owned transport deadline/abort/finally. 민감 로그 제거는 PR2C와 소유권 조정.

**선행 회귀:** A열린socket+B전환, key-only, A→B→A, 지연 auth/status/owner/register/manifest 후 logout, headers-only body stall, shared refresh 대기자 중 한 명 취소, enqueue 응답 유실.

**통과:** 새 세대에 old event/result 반영 0; stale generation에서 신규 POST dispatch 0; 이미 접수 가능성 있는 이전 요청은 unknown으로 보존; auth 실패와 네트워크/업데이트 오류 구분.

**롤백:** 안전 fence와 차단은 유지. 과거 queue를 새 서버에 자동 재전송 금지. TTL 임의 연장·protocol downgrade 금지.

### PR2C — native 로그·알림 identity·API 호환·quick action

**대상:** NotificationService/MainActivity/WsService/ServerContract 및 알림 모델, manifest/lint test 경계. N-01/N-05/N-07, N-06 일부.

**변경:** prefilter 원문 로그 제거, 공통 알림 namespace/tag·PendingIntent identity·FGS 예약 구분, API26 guard/하위 버전 adapter, navigation과 one-shot command 소비 분리.

**선행 회귀:** 무관/허용앱 fake알림, API24/25/26 시작·알림, producer 동시 발행, progress취소·WSburst, Activity 재생성·shortcut 재전달.

**통과:** 기본 로그 raw title/body/신고번호 0, 탭 대상 정확, 기존 channel 사용자 설정 보존, 한 genuine command의 무심코 반복 실행 없음. 실제 merged support 범위는 실행 뒤 보고.

**롤백:** channel ID 전면 교체로 사용자 설정을 잃지 않음. pending command receipt는 삭제하지 않고 호환 가능한 소비 정책 유지.

### PR2D — background owner·FGS 실패·복구

**대상:** SyncForegroundService, MainActivity/application, sync/background hooks·workmanager 경계. N-08.

**변경:** 먼저 engine/task/DB/FGS의 실제 owner 계측. FGS acquire 실패/refcount·timeout 통지와 Dart 상태 연결. checkpoint 기반 복구를 기본안으로 정함.

**선행 회귀:** HOME/resume, Activity recreation, task removal, process kill, FGS reject/timeout, nested acquire/release와 예외.

**통과:** running·DB writer·알림·queue 상태가 거짓으로 남지 않음. 미완료 작업 복구 또는 명시 중단. 연속 실행 지원 범위가 문서·테스트와 일치.

**보류/롤백:** headless engine 소유권 재설계가 필요하면 별도 승인 설계로 분리. “FGS가 있으니 계속 실행” 또는 “force-stop도 계속” 주장은 금지.

### PR3A — DB 읽기·기관 TEMP·지도/날짜 정확성

**대상:** LocalDbService lookup/open/close/query/missing/map accumulator, geocode utils, 통계 parser. DB-03~DB-06.

**변경:** preparation single-flight/atomicity, failed Future identity-safe reset, count/page snapshot, 직접 unknown predicate, strict date/coord 공유.

**선행 회귀:** Adelete/Bdelete/Ainsert/Binsert, retry·취소·registry 교체, one-shot DB open 실패, count/page 사이 mutation, 마지막 preview 삭제, overlap unknown·가중치·invaliddate/DST/좌표경계.

**통과:** 부분 lookup/UNIQUE 오류 은폐 없음, retry 정상 회복, 불가능한 count/page 조합 없음, map/overview/missing의 동일 집합. 저장 원문 불변.

**롤백:** TEMP/조회 cache만 정리 가능. parser 수정이 기존 의미를 바꾸면 성능 PR과 분리하고 벡터로 승인 후 진행.

### PR3B — 최근 답변·첨부·bounded 화면 상태

**대상:** recent_answers_screen/Provider/local recent query, report_detail_sheet media, list/statistics 표시. UI-01/UI-02/UI-03 일부.

**변경:** preview≠total 타입/표시, 로컬 exact recent count/page, 올바른 media identity+완성 게시, loading/empty/error/stale 구분. Client 미지원 count는 C-03 의존으로 남김.

**선행 회귀:** 199/200/201/1,001·자정·override·preview 밖 recent, 동일 filename 다른origin/account/epoch, partial download·취소·회전·back.

**통과:** 로컬 recent page union=전체 oracle; API 미지원 값을 꾸며내지 않음; 잘못된 파일 재사용/미완성 열기 0; 실패 draft·선택·scroll 보존.

**롤백:** 개인 파일은 삭제하지 않음. legacy filename cache는 새 경로에서 신뢰하지 않고 파생 캐시만 정리. 기존 버튼·내비게이션 유지.

### PR4A — cold 통계·준비 비용·view model

**대상:** LocalDbService stats/summary/index, registry, accumulator, statistics_screen, PerformanceTrace. UI-03 및 bounded 성능 과제.

**변경:** §9.1의 단계별 근거에 따라 하나씩 적용. index/CTAS/전달/parse/chart 비용을 섞어 before/after 한 숫자로만 보고하지 않음. 기존 1,000 stream·guard·shared bundle 보존.

**선행 회귀:** 공용 stats 벡터+legacy oracle, high-cardinality/긴 원문·same-count modification·revisioncancel; 0/1/3k/58,388/100k/500k.

**통과:** 모든 값·유효 표본·분모·반올림 동등; cold total 및 주요 병목 absolute time/CPU/bytes 개선을 실제 측정. warm만 개선이면 별도 성과로 제한. 작은 데이터·다른 탭 퇴행도 공개.

**롤백:** 최적화별 switch/작은 commit으로 정확한 이전 calculator 경로 유지. 파생 cache key 충돌 시 cache 비활성으로 복구하며 보호·bounded 원칙은 유지.

### PR4B — 중복·sync 후처리·manifest 작업량

**대상:** bounded duplicate/repository, sync/auto-drain, upload progress·manifest store/wiring. S-07/S-08.

**변경:** source-vs-decision 의존성 검증 후 decision fast path, 좁은 sync staging/progress delta, drain coalescing, 필요 full manifest의 bounded atomic publish. 계약 없는 delta endpoint는 사용 안 함.

**선행 회귀:** 중복0/작은군다수/giant1~2, 긴raw·동률·manual·외부writer, progress ACK 변화, no-change poll·반복cursor·lease만료·clientclose.

**통과:** duplicate oracle와 알림 의미 동등; 전체 examined ID/SQLcall/retainedbytes/staging/최종 publish 측정; 실패 시 이전 정상 manifest/projection 유지. 중복 해시/내구성 비용을 숨기지 않음.

**롤백:** 원본과 user decision은 건드리지 않음. 미완성 staging만 안전 삭제. 신/구 digest 포맷 버전 충돌 시 검증된 bounded rebuild로 복구.

### PR5A — Client 내부 요청·decode·표시 비용

**대상:** api_service/report_provider/local_paged_report_list/필터·통계 UI. UI-03/UI-04.

**변경:** 취소·inflight 공유·scope별 total 재사용·큰 decode 순수 worker 비교·불필요 model 수명 축소. 정확히 구현된 API만 호출.

**선행 회귀:** slow/failing endpoint, 긴 원문fullresponse, 필터burst/페이지순서/계정변경, 기본/복합조건 라벨, native credential origin.

**통과:** 요청·bytes·peak·frame trace 전후, 현재 지원되는 필터 의미 동일. UI 후보 제한을 전체 필터 건수로 바꾸지 않음. 계약 미완료 영역을 완료로 승격하지 않음.

**롤백:** 기존 호환 응답 경로 유지. cached total의 generation 폐기 가능. old server에 무한 재시도/full preload fallback 금지.

### PR5B — 서버 공동 계약과 거대 DB 왕복

**대상:** C-02~08 인계, 실제 승인된 서버/모바일 계약·벡터·변환. **다른 저장소 구현은 별도 승인 전 금지**.

**변경:** 제안→정본 확정→서버 검증→mobile capability 연결. 현재 PC 계획의 DB 보호·query·giant duplicate 과제와 충돌/중복을 조정한다.

**선행 회귀:** 전체 filtered oracle와 page union, API/WS auth/protocol, exact total·revision, 정상/giant 500k 왕복 전체 값 비교.

**통과:** 신/구 조합 호환표, 배포 순서·rollback·blocking gate. normal500k pass로 giant-case pass를 대체하지 않음.

**롤백:** 미지원 capability 안내로 돌아가며 기존 정상 자료 보존. 새 schema를 옛 코드로 파괴적으로 변환하지 않음.

### PR6A — 책임 분리와 사용하지 않는 경로 정리

**대상:** LocalDbService/ReportProvider/SyncEngine의 facade 뒤 query/aggregate/exchange/run responsibility, legacy UI 분기. UI-03·유지보수 전반.

**변경:** 앞선 독립 테스트가 있는 단위부터 이동. read/write/계산/플랫폼을 분리하고 public facade/caller contracts 유지. 두 모드를 모두 처리한 뒤 남는 branch는 실제 호출자와 테스트를 확인 후 제거.

**통과:** behavior-only refactor는 값/오류/순서/side effect 변화 없음. import/global initialization 변화·listener disposal도 검증. 줄수 감소를 속도 향상으로 쓰지 않음.

**롤백:** 기계적 이동과 behavior 수정 commit을 구분. 공유 파일 동시 편집 금지.

### PR6B — CI·실렌더·패키징·최종 검수

**대상:** 기존 tests/Flutter·Kotlin CI/Gradle/manifest/release artifact·docs. N-09와 전체 회귀.

**변경:** signer-free analyze/test/contract/lint를 배포와 분리. failure가 실제로 merge/release 준비를 막는지 검사. R8/리소스/사진 경로는 현재 설정과 실제 artifact부터 확인하며 광범위 업그레이드는 별도 결정. mapping/debug symbol은 build hash·source·지원 기간에 맞춰 보존 계획.

**통과:** 실제 렌더·접근성·시나리오·schema·API·성능 결과의 PASS/FAIL/SKIP/NOT_RUN 분리. 정확한 transport/storage 정책과 문서 일치. LAN HTTP 호환을 말없이 제거하지 않음.

**롤백:** CI 검증과 release trigger를 혼합하지 않음. 서명/키/버전/운영 endpoint는 현재 계획의 수정 대상 아님. 기존 보안/데이터 보호를 제거해 배포를 통과시키지 않음.

---

## 12. 실행 승인 후의 측정 설계

### 12.1 과거 기록과 새 기준선은 분리

첨부 감사는 후속 50만 건 profile에서 다음 수치를 인용한다. 이 문서 작성자가 다시 측정하지 않았다. 특정 API35 emulator/4GB/profile 및 합성 분포에 관한 **과거 보고**다. S24 성능·현재 사용자 환경·새 구현의 목표 달성 증거가 아니다. [A §5]

| 과거 기록의 구간 | cold | warm | 해석 제한 |
|---|---:|---:|---|
| 500k summary | 2,388ms | 1ms | 첫 DB·registry 준비와 별도 |
| 500k stats+overview | 60,585ms | 1ms | warm 숫자로 cold 해결 주장 금지 |
| 500k map | 6,664ms | 1ms | 같은 workload/필터에서만 비교 가능 |
| DB open/준비 | 15,824ms | 해당 없음 | 위 집계와 자동 합산하지 않고 실제 critical path 확인 |
| registry 준비 | 3,565ms | 해당 없음 | 선행/겹침 여부 확인 |
| giant raw 2군 duplicate | 397,384ms | 92,284ms | 일반 중복 분포와 다름; 약0.95/1.02GB RSS 보고 |

R11의 본문에는 다른 시점·2GB/4GB·다른 필터 수치도 있다. 유리한 전후 숫자만 골라 개선율을 계산하지 않는다. normal500k 교환 diff=0과 PC giant restore 미완료는 서로 다른 케이스다. [R04, R11]

### 12.2 cold의 정의

- `C0`: 새 설치/새 DB 또는 인덱스·registry가 아직 준비되지 않은 상태.
- `C1`: 기존 DB로 프로세스 재시작, 결과 캐시 없음. OS 파일 캐시가 cold라고 보장하지 않음.
- `C2`: 같은 프로세스·DB 준비됨, 해당 필터 결과 cache miss.
- `W`: 같은 유효 revision·조건의 cache hit.

이 명칭은 **측정용 제안**이다. 각 기록에 실제 초기조건을 적는다. “cold” 하나로 DB migration·index·첫parse·결과cache miss를 모두 섞지 않는다. cache를 비우기 위해 운영 앱 `pm clear`/uninstall 하지 않는다. 합성 fixture 앱만 별도 승인 환경에서 준비한다.

### 12.3 데이터 행렬

기본 크기는 0/1/3,000/58,388/100,000/500,000건이다. 58,388은 실제 제보 규모 재현 우선순위이며 50만은 성장·stress 사례다.

동일 건수에서도 다음 분포를 분리한다: 긴 raw/body·다수 첨부, NULL/빈 override·선행0 ID, 다년/역전/invalid 날짜, custom 상태·법규, low/high cardinality 기관·담당자·날짜, 중복 없음/작은군 다수/giant1~2군, 감시 밀집, 동일 건수 수정, foreign writer·복원, 큰 Client 응답.

fixture seed·생성기SHA·DB schema/index/journal·Flutter/Dart/Android·profile/release/debug·CPU/RAM·GPU·thermal·배터리·font scale·network 상태를 기록한다. 실데이터는 기본 fixture가 아니며 필요한 경우 별도 승인한 비공개 사본에서만 쓴다.

### 12.4 측정해야 하는 실제 시간

```text
app launch
  first frame
  auth/gate ready
  DB open / schema / index ready
  registry ready
  first useful data
  all requested aggregates ready

interaction
  input accepted
  debounce/admission wait
  native queue wait
  SQL execute + row fetch
  MethodChannel / JSON / model / aggregate
  Provider commit
  widget build / raster / usable result

cancellation
  cancel requested
  queued work removed
  transport/SQL/atomic save actually ends
  resources released / terminal state
```

선행 구간이 겹치면 개별 duration 합계가 end-to-end라고 쓰지 않는다. trace span의 critical path를 따로 보고한다. SQL native 시간을 진단할 수 없으면 queue 포함 앱 관측 latency로 표시한다.

### 12.5 지표와 기록

| 영역 | 필수 지표 |
|---|---|
| 사용자 체감 | first frame, first useful data, complete, filter→usable, p50/p95/max와 표본 수 |
| Flutter | UI build/raster frame, jank, event-loop 긴 작업, 실제 profile 환경 |
| 메모리 | Dart heap/external, native RSS/PSS, peak와 반복 후 plateau, GC/OOM/ANR 오류 구분 |
| SQLite | SQLcall, fetched row/bytes, plan/temp disk, native queue/lock wait, snapshot consistency |
| 네트워크 | 요청·bytes·inflight·retry·latency·취소 뒤 추가요청, 동일 인증 refresh 중복 |
| 작업 | attempted/saved/retryable/permanent/pending/cancelled/list_complete/deleted, ACK 미확인 |
| 큐 | claim/acked/unacked, oldest age, durable retry, overflow·recovery, 이벤트 유실 |
| 비용 | manifest no-change request/SQL, 전체 examined ID, duplicate stage/publish, export disk peak |
| 안정성 | 반복 20회, 계정·모드 전환, HOME/task removal/process death, listener/socket/timer 잔존 |

실기기 profile 측정을 제품 판단의 우선 근거로 두고 emulator/debug·host test는 각각의 용도로 구분한다. Flutter 공식 가이드도 성능을 profile mode 및 실제 장치에서 확인할 것을 설명한다. 60/120Hz의 프레임 주기는 참고 예산이며 네트워크 집계 완료 시간과 다른 지표다. [O03]

### 12.6 표본·실패와 수용 기준

일상 navigation/filter 시나리오는 예열·조건을 명시한 반복을 계획한다. 20회 정도의 작은 표본에서 나온 p95도 경험적 값이며 안정적 SLA 증명으로 쓰지 않는다. 비용이 큰 cold500k/giant 작업은 우선 적은 반복의 원자료·중앙값·범위를 보고하고 충분한 표본 없이는 p95/p99를 꾸며내지 않는다.

실패·timeout·cancel을 빠른 성공 샘플에서 빼고 성공률을 숨기지 않는다. timeout은 censored/failed로 기록한다. 기기가 재부팅되거나 fixture가 달라진 결과를 같은 before/after로 합치지 않는다.

**절대 통과 조건:** 데이터/타입 차이 0, 불완전 inventory 삭제0, pending queue 무통지 유실0, 조기 rebuild complete0, 다른 owner/generation 결과 오반영0, 무한 retry0, 신규 비밀 로그0.

**성능 통과 조건:** 동일 조건에서 목표 병목의 absolute time·CPU·bytes가 줄었음을 보이고, 작은 데이터·사용자 입력·다른 화면의 악화도 함께 비교한다. 무결성을 희생한 성능은 불합격이다. 최초 표시는 빨라졌으나 전체 완료가 그대로라면 그 범위를 분리해 보고한다.

과거 요약 목표 58,388건2초/50만5초를 재사용한다면 ‘순수 집계’인지 ‘DB/registry 포함 첫 유용 데이터’인지 승인된 정의를 붙인다. 이번 계획은 달성을 선언하지 않는다. 목표 수치·허용 회귀 폭은 baseline과 사용자 중요도에 따라 확정하며 아직 없는 측정은 `null / 미측정`으로 둔다.

---

## 13. 테스트·고장 주입과 실행 전제

### 13.1 테스트 단계

**A. 순수 함수/계약:** parser·calendar·좌표·중첩 unknown·typed outcome·eligibility·정확한 숫자·rounding·기관 registry·claim 상태.

**B. SQLite/저장:** 실제 temp DB와 연결로 JOIN/cardinality·count/page snapshot·trigger/revision·open 실패·read/write barrier·WAL·교환·staging publish·disk error. source grep만으로 race를 통과시키지 않는다.

**C. fake API/native 경계:** 실제 sync/rebuild/drain 호출자에 fake HTTP·clock·barrier를 연결한다. 반환 객체만 성공으로 세팅하는 테스트와 구분한다. native/Dart 두 쪽의 generation·inbox·protocol을 검사한다.

**D. widget/golden:** loading/empty/error/stale/partial·200+recent·페이지/selection·테마·큰 글자·IME·회전·뒤로가기. 골든 자동 갱신으로 결함을 승인하지 않는다.

**E. profile/integration:** 합성 데이터를 실제 fixture APK로 렌더하고 trace·native memory·notifications/FGS/process life를 확인한다. 실제 앱/사이트/계정 side effect는 사용하지 않는다.

**F. 교차 저장소:** 실제 호환 서버 fixture와 모바일의 API·WS·DB 왕복. 서버 접근/수정 승인과 준비가 없으면 해당 게이트만 BLOCKED로 남긴다.

### 13.2 기존 테스트·도구 재사용 지도

경로는 첨부 감사 inventory에 존재하는 이름이다. 각각이 모든 아래 조건을 이미 검사한다는 뜻은 아니다. 실제 assertion·tag·환경 전제를 다시 확인한다. [A 부록 C]

| 검증 | 기존 후보 |
|---|---|
| 대용량 query/snapshot | `test/services/large_data_queries_test.dart`, `read_snapshot_test.dart`, `local_db_service_regression_test.dart` |
| 중복 bounded/oracle | `test/services/duplicate_rebuild_bounded_test.dart`, `test/support/legacy_duplicate_rebuild.dart` |
| 교환/원본 | `test/storage/server_import_test.dart`, `backup_restore_test.dart`, `storage_contract_test.dart`, `test/tool/db_roundtrip_harness_test.dart` |
| 통계/법규/모델 | `test/services/stats_overview_vectors_test.dart`, `stats_tables_test.dart`, `stats_law_scope_test.dart` |
| gate/rebuild/upload | `test/community/rebuild_state_test.dart`, `rebuild_hook_test.dart`, `uploader_test.dart`, `gate_state_test.dart`, `sync_upload_boundary_test.dart` |
| queue/auth | `test/services/standalone_pending_queue_store_test.dart`, `standalone_auth_relogin_test.dart`, `test/community/capture_intent_failure_test.dart` |
| Client/첨부 | `test/services/selfhost_compatibility_test.dart`, `client_media_access_test.dart`, `api_service_pagination_test.dart` |
| UI/native | `test/widgets/bounded_screen_entry_test.dart`, `photo_decode_memory_test.dart`, `test/report_navigation_regression_test.dart`, Kotlin `ServerCompatibilityTest.kt` |
| 계측 fixture | `tool/large_data_fixture.dart`, `performance_probe.dart`, `baseline_read_probe.dart`, `large_db_exchange_check.py`, `android_fixture_ui.py` |

### 13.3 실행 명령은 계획으로만 제시

다음은 **현재 실행 금지**다. 후속 검증 승인을 받은 별도 checkout·고정SDK·합성DB·fixture app ID·fake endpoints에서 실제 옵션/태그/경로를 확인한 후 사용한다. build/release wrapper가 서명·VERSION·배포를 건드리는지 확인하기 전 호출하지 않는다.

```sh
# 승인 후: 고정 SDK 및 완전히 격리된 fixture 환경에서만
flutter analyze
flutter test

# 큰 자료 테스트: 기존 SR_LARGE_TEST gate의 실제 사용법 확인 후
SR_LARGE_TEST=1 flutter test test/services/large_data_queries_test.dart
SR_LARGE_TEST=1 flutter test test/services/duplicate_rebuild_bounded_test.dart

# Kotlin task 존재·variant·외부 side effect를 확인한 뒤의 예시
# (실제 프로젝트에서 유효한 task인지 PR0에서 확인)
cd android
./gradlew :app:testDebugUnitTest :app:lintDebug
```

명령 예시는 실행 로그가 아니다. skipped는 passed에 합산하지 않는다. golden font 부재, S24 미확보, 특정 Android API 미준비를 NOT_RUN/BLOCKED로 명시한다. 이미 설치된 운영 앱의 재사용·초기화가 필요한 자동화는 기본 계획에서 배제한다.

### 13.4 최소 고장 주입 묶음

- WAL-only commit, checkpoint failure, orphan/duplicate ID, 0건/부분 DB, unknown column, disk full, publish 직전 취소.
- 목록401건 중 page2누락/중복/동시 이동, detail503·auth/stop, pending/retryable rebuild 마감, failed/busy fallback.
- inbox201/1,000건, 같은 번호 신규 이벤트, 동시 RMW, ACK 전후 crash, community DB 장애 중 retry journal.
- 서버A→B/A→B→A/key-only, gate/status/manifest 지연, old WS event·POST, auth bodystall.
- count/page와 group/preview 사이 writer, TEMP lookup interleave, failed DB open→retry, weighted unknown·invalid calendar·좌표 범위.
- filename충돌/부분 media/다른origin, notification producer 충돌, quick action 재생성, FGS acquire/timeout/engine 종료.
- API24/25/26/28/29/35 및 실제 target에 필요한 추가 API, font1.0/1.3/2.0·가로·IME, 모든5탭·옛native5/6·HOME/resume.
- high-cardinality500k/giant group, revision동시수정, repeatedcursor·leaseexpire·no-change manifest, 느린Clientfullresponse.

---

## 14. 변경관리·롤백·배포 승인 경계

### 14.1 작업 소유권

Sol은 이번 계획의 정적 검토·정리 역할이다. 과거 Opus/Gemini/Muse 문서의 실행·기기 권한을 이번 승인으로 가져오지 않는다. 협업 도구가 실제 준비된 경우에만 독립 검토 범위를 지정한다. 현재 세션에서 호출하지 않은 검수자를 호출했다고 보고하지 않는다.

후속 구현 시에는 별도 worktree·fixture root·port·test app/session을 쓰되 worktree가 보안 격리는 아니라는 점을 전제로 한다. `main.dart`, Provider, LocalDbService, community 공통 store/gate, contracts, Manifest/Gradle/pubspec은 single writer다. 여러 PR이 같은 파일을 넓게 건드리면 코드를 먼저 기계적으로 다 쪼개는 대신 순서를 조정한다.

### 14.2 롤백 분류

| 변경 | 가능한 롤백 | 금지할 롤백 |
|---|---|---|
| view/cache/TEMP 최적화 | 파생 cache 폐기·검증된 계산 경로 복원 | reports/raw/queue까지 삭제 |
| queue/journal 형식 | migration journal·호환 reader 또는 명시 차단 | 이해 못하는 pending을 empty로 취급 |
| sync/rebuild 상태 | active run 정지·checkpoint 보존·안전한 재개 | 불완전 run을 완료로 승격 |
| DB import | 기존 정상본 유지·검증된 backup 복구 | schema 의미를 잃는 자동 downgrade |
| 서버 API 추가 | capability off·구경로의 명시 제한 안내 | protocol/auth 우회 또는 잘린 전체 응답 |
| native configuration | 이전 상태 복원 전 owner 정리·generation 증가 | old context를 새 계정에 재활성화 |

새로운 보호를 배포 실패 때 제거하여 종전 파괴적 경로를 되살리지 않는다. 데이터·queue에 새 의미가 생기는 변경은 이전 binary가 이해하는지 확인하고 이해 못하면 명시적으로 차단한다.

### 14.3 배포 조건

계획 승인, 구현 승인, 검증 승인, 운영 배포 승인은 별개다. main push·tag·release·실제 앱 서명·스토어 업로드·서버배포는 이 문서로 승인되지 않는다.

배포 전에는 정확한 source SHA·SDK·dependency lock·APK/AAB hash·mapping provenance·스키마/계약버전·지원 기기범위·외부 소비자 호환표를 기록한다. mapping 보존 기간은 지원 정책과 맞추되 인증정보가 artifact에 들어가지 않도록 한다. R8/AGP/리소스 shrink는 현재 최종 설정과 경고를 확인해 필요한 좁은 변경만 제안하고 포괄적 upgrade를 자동 실행하지 않는다.

---

## 15. 완료 기준과 Sol의 최종 산출물

### 계획 완료

27개 발견의 현재 상태·근거 수준·선행 테스트·작업 단위·수용/롤백이 모두 연결되어야 한다. 구현 전 필요한 결정은 추천 기본안·결정 근거·보류될 해당 작업만 적는다. 질문만 나열하고 계획을 비우지 않는다.

특히 결정이 필요한 항목은 다음 네 묶음이다.

- **목록 부재 cleanup:** 안정된 전체 목록 증거가 없으면 기본 비파괴 유지. 사이트 계약 증거 확보 후 허용 범위 결정.
- **gate freshness:** 열람과 신규 작업, foreground/background별 정책 확정. 60/600초 문구 충돌을 임의 확대/축소하지 않음.
- **background 지속성:** 중단/재개 보장과 독립 engine 지속 실행 중 요구 수준 결정. 기본은 owner 계측과 복구.
- **Client 서버 계약:** 실제 지원 API와 신규 제안의 공동 범위·호환·배포 순서 결정. 모바일 단독 부분부터 진행 가능.

### 구현 완료로 판정할 때 필요한 것 — 이번에는 모두 미실행

코드 diff, 기능 보존표, 데이터/타입 비교, 테스트 원로그와 skip 사유, 실제 Flutter 렌더, API/WS/DB 계약, 같은 환경 성능 원자료, 실패/취소/복구, native memory/queue plateau, 환경별 NOT_RUN과 blocking 항목이 필요하다.

소스 문자열 검사·빌드 성공·스켈레톤 표시·warm cache1ms·다른 분포500k 성공·HOME 복귀만으로 전체 완료라고 선언하지 않는다.

### Sol 최종 계획 보고 형식

1. 현재 HEAD와 첨부/본 계획의 delta.
2. 확인한 경로·미확인 경로·증거 수준.
3. 기능/데이터/writer/owner/lock·lease/cancellation 지도.
4. DB-01~06, UI-01~04, N-01~09, S-01~08의 확인·반증·해결 상태.
5. PR0~PR6 및 하위 변경의 구체 파일·함수·before/after·dependency·대안.
6. 단위별 선행 fixture·고장 주입·수용 기준·롤백·서버 의존성.
7. baseline/after 측정계획과 빈 기록표, 실제 실행한 것과 NOT_RUN.
8. 계획의 첫 승인 대상과 독립적으로 진행 가능한 범위.
9. **계획 제출 후 종료. 구현·테스트·운영 작업으로 자동 전환하지 않음.**

이 문서는 상세 계획이며 실제 앱·코드 수정·테스트 통과·성능 개선·운영 배포 완료 보고서가 아니다.
