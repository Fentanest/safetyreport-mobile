# Safetyreport Mobile 전체 리팩터링 계획 작성 프롬프트

이 문서는 Sol에게 전달하는 **계획 작성 지시서**다. 실제 `dev`의 전체 파일 목록과 핵심 실행 경로를 검토한 정적 감사에 기반한다. 파일을 확보했다는 사실과 모든 분기를 검증했다는 주장은 다르다. 발견, 이미 적용된 개선, 저장소의 과거 실행 증거, 이번에 실행하지 않은 검증을 구분한다. 본문과 근거·범위 부록을 함께 읽는다.

## Sol에게 요청할 작업

Fentanest/safetyreport-mobile 전체를 검토하고 기능 정확성, 사용자 체감 속도, 메모리·전력·네트워크 비용, 데이터 안전성과 유지보수성을 개선할 **아주 상세하고 실행 가능한 리팩터링 계획**을 한국어로 작성해 줘.

이번 산출물은 PLAN이다. 코드를 수정하거나 구현을 시작하지 말고, 계획을 제출한 뒤 구현 승인을 기다려. 단순히 파일을 나누거나 패턴을 도입하는 일반론 대신, 현재 코드의 파일·함수·호출자·상태 전이·실패 경계·데이터 계약과 테스트 근거를 제시해. 아래 사전 발견도 현재 HEAD에서 다시 검증하고 반증되면 제외해.

- 저장소: https://github.com/Fentanest/safetyreport-mobile/tree/dev
- 감사 기준 SHA: `ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60`
- 커밋 일시: 2026-10-03 08:23:25 UTC
- 커밋: `fix: remove hidden full report loads and bound duplicate rebuilds`
- 전체 recursive tree: 추적 파일 624개, API 응답 `truncated=false`
- 시작 시 현재 `dev` SHA를 확인하고 위 기준과 diff를 작성해. 파일·함수·줄번호가 이동하거나 수정된 발견은 새 링크로 갱신해. 이미 해결된 문제를 다시 고치려 하지 마.

### 1. 목표와 범위

목표는 정확한 결과와 기존 기능을 유지하면서 최초 준비·화면 진입·필터 변경·동기화·DB 교환의 지연을 줄이고, 실패/취소/재시도/계정 전환을 일관되게 만드는 것이다.

- 첫 프레임, 첫 유용한 데이터, 전체 집계 완료, 사용자 입력 반응을 각각 측정하는 계획
- Dart UI isolate, SQLite native 실행, MethodChannel 복사, JSON/Report 변환, registry, 차트/지도 생성, 파일 I/O, 네트워크 대기를 분리
- 대용량 데이터를 숨기거나 200건 미리보기를 전체 결과로 바꾸지 않고 정확한 COUNT·페이지·필터·드릴다운 유지
- UI 취소와 실제 네트워크/DB 작업 취소를 구분하고, 폐기된 결과뿐 아니라 폐기된 작업 비용도 줄임
- 동기화·알림 큐·업로드·rebuild·로그아웃·DB 교환의 소유권과 재시작 가능성을 정리
- PR마다 안전성, 회귀, 성능 효과, 롤백 경계를 독립 검증

이번에는 소스 수정, 패키지/SDK 설치·업그레이드, 빌드/배포/릴리즈, 운영 API 호출, 실별점 제출, 실계정 로그인·업로드, 기기 운영 앱 제거/초기화, 운영 DB 변경을 하지 않는다. 필요한 실행 검증은 승인 후의 명시적 검증 단계로 계획한다. 현재 환경에서 실행하지 못한 테스트는 `NOT_RUN`으로 남긴다.

Flutter/Provider/Navigator/sqflite를 다른 프레임워크·상태관리·DB로 전면 교체하지 않는다. 기능 삭제, 숫자 잘라내기, 집계 샘플링, largeHeap 설정, 권한 확대를 기본 성능 해법으로 제안하지 않는다. 큰 파일의 분리 자체가 성능 개선이라는 주장도 하지 않는다. 다른 저장소 수정은 이번 범위가 아니다. 서버 계약 변경이 필요하면 현재 모바일 안에서 가능한 부분과 별도 승인·공동 배포가 필요한 의존성을 분리해.

### 2. 먼저 읽을 정본과 구조 지도

`AGENTS.md`, `PROJECT_RULES.md`와 관련 `.agents/skills/`를 먼저 읽어. 과거 에이전트 역할·기기 접근·실행 기록을 이번 실행 권한으로 해석하지 마.

핵심 정본:
- `docs/architecture/overview.md`, `android-runtime.md`, `data-contracts.md`, `bounded-reads.md`, `client-read-handoff.md`
- `docs/architecture/community-gate.md`, `community-upload.md`, `community-account.md` 등 실제 트리에 있는 커뮤니티 계약 문서
- `docs/design/feature-matrix.csv`, `statistics-spec.md`, `ui-renewal-spec.md`
- `docs/testing/ui-test-plan.md`, `docs/reviews/2026-10-03-runtime-validation.md`
- `contracts/`의 저장소 실제 계약·공통 벡터, `shared/agency-region-registry/`의 manifest/schema/resolver/vector
- `pubspec.yaml`, `pubspec.lock`, `tool/flutter-version`, Android Manifest/Gradle, CI와 배포 스크립트

현재 제품은 **이미 접수한 안전신문고 신고를 조회·관리하는 Android 앱**이다. Flutter UI + Provider + SQLite, Kotlin 알림/WS/FGS와 MethodChannel을 사용한다. Client(`AppMode.server`)는 사용자가 운영하는 서버에 연결하고, Standalone은 직접 조회·로컬 동기화한다. Client 크롤링과 Standalone 동기화를 같은 작업으로 취급하지 마.

다음 지도를 먼저 작성해:
1. 앱 bootstrap → 권한/인증/커뮤니티 gate → 모드별 Provider 초기화 → lazy tab/route → 데이터 읽기
2. 화면 → Provider/query/repository → SQLite/HTTP → JSON/model → 집계/차트/지도 흐름과 실행 isolate/thread
3. 신고 목록·상세·별점·감시·중복·편집·최근 답변·파일·알림·지도·통계의 기능 보존 매트릭스
4. full/incremental sync, native 알림 감지, inbox drain, retry queue, community capture/rebuild/upload, workmanager/FGS/WS의 상태 전이
5. report/raw/override/duplicate/sync_meta/community/SharedPreferences/secure storage/cache/export의 소유권과 writer
6. dataset epoch/revision/sequence/lease/write barrier/transaction/cancellation의 적용 범위와 빈틈
7. PC↔모바일 DB·API·WS·protocol 3·registry·통계 벡터의 정본과 버전
8. 각 테스트가 실제로 보장하는 것, 작은 fixture/소스 문자열 검사/과거 측정/실기기 검증의 차이

### 3. 성능보다 우선하는 불변 조건

#### 기능·UI
- 하단 5탭 순서와 인덱스(대시보드/신고내역/신고관리/통계/알림), 신고내역 4분류, 신고관리 4하위 탭, 알림 3하위 탭 유지
- 옛 native nav 5/6, quick_sync/quick_crawl, 알림→신고 상세/카테고리 이동과 뒤로가기, 선택 취소 동작 유지
- 정부 정보 출처·비공식 고지, 한국어 라벨, 다크/라이트·큰 글자·IME·가로 화면 접근성 유지
- 신규 신고 제출, 일반 업로드, 신고 삭제 같은 새 기능을 만들지 않음
- 별점 대상·0점/미평가 구분·사유 1,000 rune/개행·오류 draft·취소 무제출·중복 실행 방지 유지
- 오류를 정상 0건/완료로 표현하지 않음. loading/empty/stale/partial/failed/cancelled/blocked 구분

#### 데이터·통계
- 서버→모바일→서버와 역방향에서 교환 대상 모든 컬럼의 값·타입·NULL/빈 문자열·한글/줄바꿈·날짜·ID/선행 0·정수/실수·raw·override·중복 결정/member·sync_meta·owner 보존
- 새/알 수 없는 컬럼이나 불완전 관계를 조용히 버리지 않음. 검증 실패 시 기존 정상 DB 보존, 외부 DB는 private copy에서 검사
- 스키마/값 의미/변환 변경은 양쪽 정본·이관·왕복 테스트·배포 순서가 같은 작업 단위여야 함. 이번에는 그 의존성만 계획하고 다른 저장소 구현은 시작하지 않음
- 원본 처리상태와 표시 canonical 상태, 중복 raw/canonical, lifecycle와 과태료/경고/불수용의 중첩을 구분
- 확정 과태료 원문과 추정 금액은 별도 필드·합계·계열·라벨. 추정값을 원문에 저장하지 않음
- 수동 대표/동률 우선순위/not_duplicate/review_required, 대표건의 nonrepresentative 감시 계승, 기관 identity, NULL 날짜/법규 없음/분모 의미 유지
- 페이지·총계·필터·드릴다운·지도의 모집단을 일치시키고 원문을 덜 읽는 것과 행을 누락하는 것을 구분

#### 보안·백그라운드
- auth/gate/owner/consent/manager/protocol 검증을 속도 때문에 생략하지 않음
- gate cached-view 허용 시간과 신규 작업 허용 시간을 명시하고 Dart/native/background가 같은 승인된 정책을 따름
- 비밀번호·토큰·API key·알림 본문·개인 신고 원문을 로그/측정/프롬프트/fixture에 남기지 않음
- timeout은 작업 중단이나 side effect 미발생의 증명이 아님. 재시도 가능성·idempotency·부분 성공을 분리
- epoch 변경 후 과거 서버/계정 결과뿐 아니라 진행 중 native side effect도 관리
- 개인 운영 앱 uninstall/pm clear, 실서비스 제출, keystore/VERSION/서명 변경 금지

### 4. 이미 적용된 개선을 회귀시키지 말 것

기준 SHA에는 다음 보호가 실제로 들어 있다. 이것을 아직 미구현이라고 쓰거나 제거 후 다시 도입하지 마.

- 대시보드 전체 category 사전 로딩 제거, Provider legacy category는 200행 preview
- 로컬 COUNT/조건 집계, narrow TEMP GROUP BY snapshot과 1,000행 stream, 200행 page, DISTINCT 필터 메타
- summary/stats/map revision cache, dataset epoch/요청 sequence, 대기 중 취소 재검사와 native 큐 적체 완화
- 지도 전체 메타와 viewport/cell budget 분리, lazy `ListView.builder`, 방문 전 탭 지연 생성/TickerMode
- 중복 재생성 128행 digest isolate·staging·revision 검사 후 publish, group/member 50개 page, 알림 deferred metadata
- 서버 DB 가져오기 native JOIN page, DB file-operation/background guard, 양방향 교환 벡터
- 사진 decode 크기 제한, protocol 3 Dart/Kotlin gate와 same-origin media credential 보호
- MediaStore pending/크기 검증/64KiB publish, background에서 강제 파일앱 실행 금지, 별점 adaptive IME UI

저장소 검증 보고서는 최종 868 passed/15 skipped, analyze 기존 warning 9/info 10, Kotlin 4 tests, 50만 synthetic 양방향 교환 diff=0 등을 기록한다. **이번 감사가 재실행한 결과는 아니다.** 로그·소스 SHA·환경·skip 이유를 대조한 뒤 현 HEAD baseline을 새로 수립하는 검증 계획을 작성해.

### 5. 대용량 문제를 어떻게 다룰지

사용자가 과거 Galaxy S24/58,388건에서 대시보드 지연·통계 종료를 보고했다. 이 사실은 재현 우선순위의 근거이며 현재 dev의 동일 장애나 OOM 원인이 증명된 것은 아니다. 현재 코드가 많은 개선을 포함하므로 과거 main과 혼동하지 마.

저장소의 2026-10-03 profile 보고서에는 후속 50만 건에서 summary cold/warm 2,388/1ms, stats+overview 60,585/1ms, map 6,664/1ms, DB open/준비 15,824ms와 registry 3,565ms가 별도 기록되어 있다. 거대 raw 2군 중복 재생성은 Android cold/warm 397,384/92,284ms, 약 0.95/1.02GB RSS가 기록되어 있다. 이는 특정 API35 emulator/4GB/profile와 fixture의 **과거 기록**이다. S24 수치나 이번 실측으로 인용하지 말고 서로 다른 빌드·분포·메모리·host 부하의 개선률을 계산하지 마. 특히 warm 1ms로 cold 문제가 해결됐다고 쓰지 마.

현재 주요 성능 계획은 이미 bounded해진 코드 위에서 첫 인덱스·registry 준비, high-cardinality CTAS/집계 압축률, native→Dart narrow page 복사, chart/model 누산, giant-group staging과 publish, 취소 대기, Client 잔존 full-response를 각각 측정·최적화하는 것이다. 안전성이 먼저이며 정확한 전체 집계와 legacy oracle 동률을 유지한다.

### 6. 사전 감사 발견을 바탕으로 할 우선 작업

아래 근거 부록의 각 항목에 대해 현재 HEAD 재확인 → 반례/최소 fixture → 근본 원인 → 변경 경계 → 테스트 → acceptance/rollback 순으로 계획해. 위험도는 실제 사용자 피해가 이미 일어났다는 선언이 아니다.

- **P0 선행 안전성 게이트**: fullSync 삭제 권한의 완전성 증명, import 관계·카디널리티/sidecar 오류 fail-closed, rebuild terminal-state 완전성. 보존 계약이 불확실한 상태에서 성능 PR을 먼저 내지 않음
- **P1**: native/Dart 큐 유실 방지, timeout/재시도/ack, 개인정보 로그, 서버 변경·로그아웃 generation, Android24–25 채널 호환, media cache identity, 최근 답변 전체 조회 누락
- **P1/P2**: map unknown 중첩 집계, concurrent TEMP lookup, gate freshness 문서/실행 계약, background engine 소유권 검증
- **P2**: 기존 bounded 구조의 cold 비용, Client read 계약 의존성, hot-path JSON/정렬/manifest 갱신, API retry/idempotency와 UI 상태 분리, dead legacy 분기·거대 static service의 책임 분리

서버에 없는 page/filter/lookup API를 이미 존재하는 것처럼 계획하지 마. `client-read-handoff.md`의 제안은 제안이다. 모바일 단독으로 가능한 투명한 제한 표시·메모리/취소·상태 개선과 서버 협업 후 가능한 완전한 filtered COUNT/paging을 나눈다.

### 7. 권장 PR 단계와 의존성

계획은 아래 흐름을 검증한 뒤 조정하되, 단일 대형 PR을 제안하지 마. 각 단계에 대상 파일/함수, 책임 경계, 기존 public facade 유지 여부, schema/API 변화 여부, invariants, 테스트, 관측 지표, 롤백을 써.

1. **PR0 관측·계약·회귀 fixture**: 실패/취소/partial typed result와 현 상태 전이 명세, trace ID/epoch/revision만 기록하는 개인정보 없는 측정, deterministic fake clock/network/DB fixture. 기존 성공·기존 실패·NOT_RUN baseline 구분
2. **PR1 데이터 안전성**: fullSync list completeness와 delete barrier, rebuild 모든 item terminal 검사와 중단/재개, import preflight/integrity/sidecar fail-closed. 원본·기존 projection을 유지하고 불완전 작업은 publish 금지
3. **PR2 큐·native 생명주기**: 알림 처리 queue와 history retention 분리, ack 후 제거/retry classification, bounded worker·network deadlines·generation, old-server WS 중단, API24–25 호환. background engine/work ownership은 조사 결과에 따라 별도 승인 설계
4. **PR3 조회 정확성**: 최근 답변 full COUNT/page, map unknown, TEMP agency lookup single-flight/snapshot, stale drilldown·loading/partial 표시, cache-key identity
5. **PR4 cold 통계·중복 성능**: profile 근거에 따라 projection/aggregate cache key·invalidation, CTAS/index·chart 누산·isolate 경계·staging I/O 최적화. eager all-report 구조 복귀 금지
6. **PR5 Client 네트워크·계약**: 모바일 내부 취소/요청 재사용/response decode 경계와 full-response 관측을 먼저; 추가 서버 계약은 별도 의존 PR·벡터·배포 호환표·capability fallback
7. **PR6 책임 분리와 마무리**: behavior-preserving facade 뒤로 query/import/export/aggregate/sync execution을 작은 단위로 분리, unreachable legacy 화면 분기 정리, 실제 기능표·테스트·문서와 사용하지 않는 코드 교차 확인. 정리와 의미 변경을 같은 PR에 섞지 않음

단계별로 변경 전 상태로 돌아갈 때 새 DB를 이전 코드가 읽을 수 있는지, pending queue/lease/staging을 어떻게 보존하는지, cache만 안전하게 폐기할 수 있는지를 명시한다. 데이터 손실을 동반하는 schema downgrade나 단순 앱 제거를 롤백이라고 부르지 마.

### 8. 측정·테스트·수용 기준

#### baseline와 데이터 행렬
- 0/1/3,000/58,388/100,000/500,000건. 동일 seed와 데이터 분포, SHA, SDK/OS, profile/release/debug, CPU/RAM, thermal/battery, 화면 크기/폰트, cold 정의 기록
- 긴 raw/body/media, NULL/빈 문자열/override, 다년·날짜 역전, custom status/law, 중복 0/다수 작은 군/1~2 giant 군, high-cardinality 기관·담당자·날짜, watchlist 밀집, stale cursor와 같은 건수 수정
- 대시보드→목록→통계→지도→뒤로가기 20회, 필터 20회 burst, 화면 dispose/reopen, 회전/IME, HOME/resume와 task removal/process death를 구별
- 모바일 58,388건을 대신해서 PC 3,082건 DB로 성능 완료를 선언하지 않음. 비식별 synthetic fixture 우선, 실데이터 사용이 필요하면 사본·동의·비공개 경계를 별도 명시

#### 수집할 지표
- cold boot→first frame, app ready, DB open/migration/index, registry init, first meaningful data와 total data-ready p50/p95/max
- frame build/raster 지연과 jank, main isolate longest task/event-loop lag, Dart heap/external/native RSS/PSS peak, 반복 후 plateau, GC와 OOM/ANR/native/Dart 오류 분류
- SQL별 시간/반환 행·bytes/plan/temp disk/lock 대기, native queue 대기, count/page snapshot 일관성, CTAS 중 취소 지연
- HTTP request 수/bytes/latency/retry/in-flight, decode/model 생성/중복 buffer, disk peak/staging cleanup와 DB 크기
- sync attempted/succeeded/retryable/permanent/pending/cancelled/list-complete/deleted, rebuild publish 조건, queue age와 acked/unacked, upload manifest 요청 빈도

수치는 먼저 동일 환경 baseline을 측정한 뒤 승인할 예산과 연결해. 예를 들어 58,388건 요약 2초/50만 요약 5초 같은 기존 목표가 있다면 DB 준비 포함 여부를 분리하고 현재 목표를 충족했다고 미리 쓰지 마. 60/120Hz frame budget과 입력 반응도 실제 장치별 기준으로 제시한다. raw 측정값을 임의로 추정하거나 '10배 빨라짐'을 약속하지 않는다.

#### 필수 회귀·고장 주입
- DB 모든 컬럼 양방향 값/타입 비교 + unknown columns + orphan detail/title + duplicate IDs + 0건 정상/부분 목록 + disk full + corrupt DB + WAL failure + 중도 취소; 성공하면 `quick_check`와 원본 보존까지 검증
- fullSync count mismatch/중복 page/짧은 page/offset 이동/401/429/503/timeout/cancel에서 기존 행 삭제 0, complete inventory만 deletion 허용
- rebuild pending/failed_retryable/failed_permanent 각각에서 승인 없는 complete/publish 금지, retry/resume/abort/dispose/process death 후 상태 일치
- native inbox 199/200/201/1,000건·동시 drain/중복 알림·기기 재시작·offline, ack 전 unprocessed 번호 누락 0
- old server A 응답 지연 중 B 전환/로그아웃/gate block, A WS event와 POST가 새 세대에 반영·실행되지 않음
- recent answers 199/200/201/1,001, 3일 경계·NULL·중복·날짜 override와 full count/page union, empty와 error 구분
- map fine+rejection/penalty 중첩+unknown fixture, whole metadata와 cell sum·viewport parity
- 동일 filename 다른 URL/origin/계정/cache epoch, 부분 파일·재다운로드·대형 media·취소·권한 차단
- protocol3와 401/409/WS4001/4403/4406, origin별 credential, HTTP LAN 호환과 보안 문서의 승인된 정책
- Android24/25/26/28/29/35+ 실제 지원행렬; notification channels/FGS/permissions/SAF/MediaStore/OEM Files. S24 재현은 로그 없는 원인 추정으로 대체하지 않음

기존 `flutter analyze`, 전체 `flutter test`, gated `SR_LARGE_TEST=1`, Kotlin unit, 계약/통계 parity/DB roundtrip, golden/widget와 profile 실렌더를 분리해 계획한다. skip을 pass로 세지 않고 source grep 테스트만으로 runtime 동작을 증명하지 않는다. 테스트 삭제·assert 완화·golden 자동 갱신으로 실패를 숨기지 않는다. 운영 crawl/rating/upload는 실행하지 않는 fake 경로를 사용한다.

### 9. Sol의 최종 계획 산출물 형식

1. 요약: 가장 큰 correctness 위험 5개, 체감 성능 병목 5개, 이미 해결된 점, 먼저 할 일
2. 전체 구조·기능/데이터/비동기 소유권 지도와 전 파일 검토 범위표
3. 발견별 표: ID/위험도/증거 종류/현재 SHA/파일·함수·라인/trigger/실패 영향/현재 방어/반증 조건/검증법
4. 목표 구조와 대안 비교: 현재 구조 안 최소 개선안 vs 더 큰 분리, 장점·복잡도·호환성·측정 전제
5. 단계별 PR 계획과 dependency DAG, 단독 모바일/서버 공동 작업 구분
6. 기능·데이터 invariants → 변경 → test → acceptance 추적표
7. 동일 조건 baseline/실험 설계, 목표 예산과 중단 기준, 테스트 명령의 사전조건/예상 시간·환경·권한
8. migration/rollout/feature switch/rollback과 failure recovery, 미결정 사항/blocked 검증
9. 완료 정의와 구현 승인 요청. **계획 제출 후 멈춤**

계획이 길더라도 중요 근거와 구체적 실패 시나리오를 생략하지 마. 확정 코드 사실, 문서에 보고된 과거 실행, 아직 재현하지 않은 가설을 섞지 말고, 각 P0/P1에는 최소 회귀 fixture와 명시적 수용 기준을 붙여 줘.

---

## 부록 A. 사전 정적 감사 근거

위험도 정의: P0는 데이터 보존·작업 완료 판정처럼 후속 리팩터링에 앞서 증명해야 할 안전성 게이트, P1은 특정 조건에서 중요한 유실·오동작·보안/호환 문제, P2는 성능·설계·검증 부채다. 이번 감사는 정적 코드 검토이며 운영 피해나 장치 재현을 주장하지 않는다. 링크는 기준 SHA에 고정한다.

### DB-01. 외부 snapshot의 WAL 실패를 무시하고 sidecar 제거

- 우선순위/증거: **P1 / P0 안전성 게이트 · 소스 확인, 장치 재현 안 함**
- 코드: [lib/services/local_db_service.dart:3305–3345](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L3305-L3345)
- 발생 조건: WAL에만 commit된 행이 있고 sidecar 복사 또는 snapshot open/checkpoint가 실패
- 현재 동작/영향: _prepareExternalDbSnapshot은 복사/open/checkpoint 오류를 삼킨 뒤 복사된 WAL/SHM을 삭제하고 main snapshot을 반환한다. 뒤의 schema/owner/integrity 검사만으로 최신 commit 보존을 증명할 수 없다.
- 계획 요구: consistent snapshot 획득·checkpoint 결과 검증·오류 fail-closed를 먼저 설계. 검증된 snapshot 하나를 판별/변환에 재사용하고 기존 staging/rollback/file lock 유지.
- 최소 회귀/수용 기준: WAL-only 행, 복사 거절, checkpoint/open 실패, 동시 writer, 손상 sidecar에서 성공으로 보고하지 않고 기존 destination을 보존

### DB-02. 서버 DB 가져오기에서 원본 모집단 보존을 증명하지 않음

- 우선순위/증거: **P1 / P0 안전성 게이트 · 소스 + 작은 SQLite JOIN 식 재현**
- 코드: [lib/services/local_db_service.dart:3508–3552](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L3508-L3552), [lib/services/local_db_service.dart:3597–3632](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L3597-L3632), [lib/services/local_db_service.dart:3801–3819](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L3801-L3819), [lib/services/local_db_service.dart:3916–3922](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L3916-L3922)
- 발생 조건: schema/owner는 맞지만 title/detail orphan, category 간 동일 ID, 빈 ID 또는 nonpositive rowid가 있는 입력
- 현재 동작/영향: _readServerReportRows의 INNER JOIN은 관계가 없는 행을 제외한다. 빈 ID skip, INSERT REPLACE 충돌, rowid>0 cursor도 누락/덮어쓰기 가능성을 만든다. 마지막 reports count>0 검사는 전체 보존 검사가 아니다. 최소 JOIN에서 title_only/detail_only는 빠지고 good 한 행만 남았다.
- 계획 요구: 지원 원본 모집단과 관계 불변조건을 preflight에서 검증하고 모든 교환 entity를 keyed reconciliation. 미지원/모호한 입력은 교환 계약대로 명확히 거절. 128행 JOIN page·NULL/entry 의미·owner/백업/rollback 유지.
- 최소 회귀/수용 기준: valid 1+orphan 1, cross-category ID, rowid0/-1, raw/override orphan에서 조용한 부분 성공 금지. 정상 0건 정책도 별도 명세

### DB-03. 기관 TEMP lookup 동시 준비 충돌

- 우선순위/증거: **P2 · 소스 호출흐름 + 최소 SQLite interleaving**
- 코드: [lib/services/local_db_service.dart:1598–1618](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L1598-L1618), [lib/services/local_db_service.dart:1658–1665](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L1658-L1665), [lib/widgets/local_paged_report_list.dart:55–107](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/widgets/local_paged_report_list.dart#L55-L107)
- 발생 조건: 같은 connection에서 미캐시 agency/police 필터 조회가 겹침
- 현재 동작/영향: _ensureAgencyLookup에 single-flight/transaction이 없어 두 호출이 shared sr_agencies를 DELETE 후 각각 같은 PK를 INSERT할 수 있다. widget seq는 반환 뒤 stale 결과만 버린다. 최소 SQL 중복 insert는 UNIQUE constraint failure를 만든다.
- 계획 요구: revision/registry key별 preparation을 single-flight·원자 publish. REPLACE나 catch로 부분 lookup을 숨기지 말고 대기 취소도 설계.
- 최소 회귀/수용 기준: A-delete/B-delete/A-insert/B-insert 강제, 다른 revision/registry, 취소·실패·재시도에서 정확한 결과와 부분 lookup 미노출

### DB-04. 지도 unknown을 중첩 처분 합계의 잔여로 재계산

- 우선순위/증거: **P2 · 소스 + 산술 재현**
- 코드: [lib/services/local_db_service.dart:4549–4569](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L4549-L4569), [lib/services/local_db_service.dart:4596–4598](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L4596-L4598)
- 발생 조건: 동일 cell에 과태료+불수용 같은 중첩 행과 unknown 행이 함께 존재
- 현재 동작/영향: _MapCellAccumulator.add는 unknown을 직접 세지만 toJson이 지우고 total-처분별합으로 다시 계산한다. 두 행 중 하나 fine+reject, 하나 unknown이면 실제 unknown 1이 0이 된다.
- 계획 요구: 직접 센 unknown 또는 결정 여부 union을 사용. 중첩 처분의 기존 의미를 배타적 분류로 바꾸지 말고 overview와 일치시켜야 함.
- 최소 회귀/수용 기준: 중첩 쌍/삼중·_weight>1·multi-cell에서 direct predicate와 동일, unknown 비음수·누락 0

### DB-05. 집계 날짜와 좌표 유효성 규칙의 분기

- 우선순위/증거: **P2 · 소스 확인; 좌표 SQL 식 점검, Dart 재현 안 함**
- 코드: [lib/services/local_db_service.dart:2260–2273](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L2260-L2273), [lib/services/local_db_service.dart:4266–4278](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L4266-L4278), [lib/services/local_db_service.dart:2507–2522](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L2507-L2522), [lib/services/local_db_service.dart:2693–2706](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L2693-L2706), [lib/services/geocode_utils.dart:2–15](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/geocode_utils.dart#L2-L15)
- 발생 조건: 2026-02-30 같은 overflow 날짜, DST 지역 또는 범위 밖 finite 좌표
- 현재 동작/영향: overview는 strict UTC calendar 검증, _AgencyAgg는 local DateTime.parse/difference.inDays를 사용한다. map metadata는 lat/lon 범위를 검사하지만 missing lookup은 finite이면 제외하여 missing 수치와 drilldown이 어긋날 수 있다.
- 계획 요구: strict calendar-day parser와 valid-coordinate predicate를 공유하되 원본 DB 값을 정정/손실시키지 않음. completed scope·sample weighting·음수 제외 유지.
- 최소 회귀/수용 기준: leap/invalid/same/reversed dates·UTC/Korea/DST, NULL/텍스트/범위경계/123,456 좌표에서 표·overview·map/missing reconciliation

### DB-06. 실패한 DB open Future와 다중 조회 snapshot

- 우선순위/증거: **P2 · 소스 제어흐름, 고장 주입 안 함**
- 코드: [lib/services/local_db_service.dart:113–118](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L113-L118), [lib/services/local_db_service.dart:218–222](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L218-L222), [lib/services/local_db_service.dart:1708–1727](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L1708-L1727), [lib/services/local_db_service.dart:2744–2758](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L2744-L2758)
- 발생 조건: 일회성 _open 실패 또는 count/group/preview 사이 동시 writer
- 현재 동작/영향: rejected _initFuture가 남고 _closeDb도 그것을 await한 뒤 reset하므로 retry가 막힐 수 있다. count/page 및 missing group/preview는 단일 snapshot이 아니며 마지막 행이 사라지면 rows.first 가정도 깨질 수 있다.
- 계획 요구: identity-safe 실패 Future reset/exception-safe close. 짧은 read snapshot 또는 bounded revision retry, 빈 preview 안전 처리와 page revision 정책.
- 최소 회귀/수용 기준: one-shot open failure→retry success; count/page·group/preview 사이 mutation에서 불가능한 total/StateError 금지

### UI-01. 최근 답변 더보기가 200건 preview를 전체처럼 표시

- 우선순위/증거: **P1 · 소스 호출흐름, widget 재현 안 함**
- 코드: [lib/services/local_db_service.dart:1944–1954](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L1944-L1954), [lib/providers/report_provider.dart:160–199](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/providers/report_provider.dart#L160-L199), [lib/providers/report_provider.dart:1194–1197](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/providers/report_provider.dart#L1194-L1197), [lib/screens/recent_answers_screen.dart:9–72](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/screens/recent_answers_screen.dart#L9-L72)
- 발생 조건: 최근 3일 완료 신고가 200건 초과; 또는 legacy category preview가 모두 로드된 상태
- 현재 동작/영향: SQL recent는 LIMIT200, refreshSummaryAndRecentAnswers는 summary만 갱신한다. 화면은 모두 보여준다는 주석/단순 건수와 페이지 없는 목록을 사용한다. Provider는 category가 로드되면 각각의 200행 preview로 최근 답변을 재구성할 수도 있다.
- 계획 요구: 정확한 recent total+page와 공통 날짜/정렬 계약. 기존 bounded summary preview는 유지하되 더보기의 full-result 기능 복원, Client 계약 부족은 별도 의존. empty/loading/error도 구분.
- 최소 회귀/수용 기준: 199/200/201/1001, 200행 밖 최근 답변, 날짜 override/3일 경계/중복에서 full union과 total 일치. 오류를 최근 답변 없음으로 오인시키지 않음

### UI-02. 외부 첨부 캐시가 filename만으로 재사용

- 우선순위/증거: **P1 · 소스 직접 확인, 실제 파일 오노출 재현 안 함**
- 코드: [lib/widgets/report_detail_sheet.dart:563–620](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/widgets/report_detail_sheet.dart#L563-L620)
- 발생 조건: 서로 다른 신고/URL/origin/계정에서 같은 마지막 filename으로 첨부 열기
- 현재 동작/영향: _openExternal은 temp/fileName이 존재하면 다운로드를 생략한다. URL·보고서·dataset identity·완성 여부를 캐시 key에 포함하지 않으므로 이전 파일을 열 수 있다. 전체 http.get buffer와 무제한 대기도 별도 비용이다.
- 계획 요구: origin+resource+dataset/generation 기반 안전 cache identity, atomic staging/완성 검증·expiry·logout 정책. same-origin credential 검증 유지. stream/deadline/cancel은 별도 설계.
- 최소 회귀/수용 기준: A/a.pdf와 B/a.pdf, key 회전/계정 변경, 부분 파일·동시 다운로드·large media에서 다른 파일 재사용 0, 미완성 파일 열기 0

### UI-03. bounded 목록의 요청 비용과 legacy 분기 정리

- 우선순위/증거: **P2 · 소스 구조 확인, 성능 미측정**
- 코드: [lib/widgets/local_paged_report_list.dart:85–166](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/widgets/local_paged_report_list.dart#L85-L166), [lib/screens/statistics_screen.dart:253–297](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/screens/statistics_screen.dart#L253-L297), [lib/screens/statistics_screen.dart:492–531](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/screens/statistics_screen.dart#L492-L531), [lib/screens/rating_management_panel.dart:64–94](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/screens/rating_management_panel.dart#L64-L94), [lib/screens/filtered_list_screen.dart:62–79](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/screens/filtered_list_screen.dart#L62-L79), [lib/models/app_mode.dart:1–10](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/models/app_mode.dart#L1-L10)
- 발생 조건: Client all-category 페이지, 빠른 필터 변경, high-cardinality 기관/담당자 검색
- 현재 동작/영향: Client는 category마다 total 확인을 위해 limit1 요청 후 실제 page를 직렬 요청한다. _seq는 늦은 결과만 버리고 진행 중 호출 취소를 하지 않는다. 통계 _visibleRows는 build마다 filter/copy/sort한다. enum의 두 모드를 모두 처리하고 남는 legacy branch도 유지된다.
- 계획 요구: 요청 snapshot/total 재사용·취소·동일 query single-flight를 계측 후 설계; 정렬 cache를 dataset/filter/type/sort에 묶고 입력 debounce는 UX 보존. dead branch는 실제 caller/테스트 확인 후 별도 cleanup.
- 최소 회귀/수용 기준: 페이지 경계·category 변경·rapid filter에서 구응답 미반영/불필요 요청 상한. high-cardinality frame trace 전후 비교, ListView 가상화 유지

### UI-04. Client full-response와 UI-isolate JSON/모델 비용

- 우선순위/증거: **P2 · 소스 + 저장소 인계 문서; 실측 안 함**
- 코드: [lib/services/api_service.dart:164–188](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/api_service.dart#L164-L188), [lib/services/api_service.dart:687–711](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/api_service.dart#L687-L711), [lib/providers/report_provider.dart:1130–1143](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/providers/report_provider.dart#L1130-L1143), [docs/architecture/client-read-handoff.md:1–15](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/docs/architecture/client-read-handoff.md#L1-L15)
- 발생 조건: Client summary watchlist/감시·중복·missing 응답이 대형
- 현재 동작/영향: http bytes→UTF8 string→decoded map→Report를 동기 변환한다. 현재 서버 계약에 전량 endpoint가 남아 있어 로컬 200행 paging만으로 Client 메모리가 bounded해지는 것은 아니다.
- 계획 요구: response bytes/decode/model peak를 계측. 원문 없는 ID membership/preview total/scoped filter page는 서버 공동 계약으로 분리하고 없는 API를 호출하지 않음. 큰 decode isolate는 복사비용과 cancellation 포함 비교.
- 최소 회귀/수용 기준: 긴 원문·대형 감시/중복 응답, 느린 네트워크/계정 변경에서 frame/memory/cancel budget; 전체 결과를 몰래 자르지 않음

### N-01. Android24–25의 API26 notification 무조건 호출

- 우선순위/증거: **P1 · 소스 + 고정 Flutter SDK upstream; 장치/merged APK 확인 안 함**
- 코드: [android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:77–80](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt#L77-L80), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:204–214](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt#L204-L214), [android/app/build.gradle.kts:30–33](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/build.gradle.kts#L30-L33), [tool/flutter-version:1](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/tool/flutter-version#L1), [README.md:54](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/README.md#L54)
- 발생 조건: 광고된 Android 7.0/7.1에서 앱/서비스 시작
- 현재 동작/영향: Flutter 3.47.5 upstream minSdk 24를 상속하지만 createAppNotifChannel은 API26 getNotificationChannel/NotificationChannel을 무조건 호출한다. 다른 producer도 같은 패턴이다.
- 계획 요구: API guard/compat notification adapter와 전체 producer 검사. 제품 지원 범위를 몰래 높이지 말고 merged manifest도 확인.
- 최소 회귀/수용 기준: API24/25/26 startup+각 알림+FGS, lint NewApi. 채널 ID/기존 사용자 설정 보존

외부 1차 근거: [고정 Flutter 3.47.5 minSdk 기본값](https://raw.githubusercontent.com/flutter/flutter/3.47.5/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt), [Android NotificationChannel API26](https://developer.android.com/reference/android/app/NotificationChannel).

### N-02. 서버 변경 뒤 기존 WS와 native side effect 세대 불일치

- 우선순위/증거: **P1 · 소스 완전 호출흐름, race 재현 안 함**
- 코드: [lib/screens/settings_screen.dart:310–355](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/screens/settings_screen.dart#L310-L355), [lib/providers/report_provider.dart:768–795](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/providers/report_provider.dart#L768-L795), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt:76–80](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt#L76-L80), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt:107–140](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt#L107-L140), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt:66–125](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt#L66-L125)
- 발생 조건: A WS 연결 중 B/키 변경 또는 version 검사 대기 중 로그아웃/모드 변경
- 현재 동작/영향: setConfig는 Dart 데이터만 reset하고 native WS를 재연결하지 않는다. start는 running이면 무시하고 old socket이 끝날 때까지 prefs를 다시 안 읽는다. enqueue raw thread도 captured mode/키로 늦게 POST할 수 있다.
- 계획 요구: immutable connection/auth generation supervisor, old work 취소 후 새 설정 publish, dispatch/callback generation 비교. Client→Standalone/reset은 이미 stop하므로 그 방어는 보존.
- 최소 회귀/수용 기준: A의 열린 socket+지연 event 중 B 전환, key-only/A→B→A, delayed version/logout에서 old event/inbox/POST 경계 차단

### N-03. native gate freshness와 concurrent compatibility 결과

- 우선순위/증거: **P1/P2 · 소스 interleaving·계약 대조; exploit 재현 안 함**
- 코드: [android/app/src/main/kotlin/com/fentanest/mysafetyreport/ClientGateGuard.kt:8–12](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/ClientGateGuard.kt#L8-L12), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerVersionCompatibility.kt:10–75](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerVersionCompatibility.kt#L10-L75), [contracts/community-ingest/gate.md:8–22](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/contracts/community-ingest/gate.md#L8-L22)
- 발생 조건: 오래된 cached ok 또는 여러 native compatibility probe 동시 실행
- 현재 동작/영향: native guard는 verified_at 없이 state==ok만 허용한다. compatibility check는 전역 volatile failure를 결과로 사용하여 valid/invalid probe가 서로 결과를 덮을 수 있다. volatile만으로 check 전체가 atomic이 아니다.
- 계획 요구: 승인된 TTL/background 정책을 Dart/native 공통화; per-call immutable 결과와 connection-generation cache. foreground 60초와 offline 600초 문서 차이는 정책 결정으로 분리.
- 최소 회귀/수용 기준: 599/600/601초·malformed/future clock·cold start, valid/invalid/auth/network probe barrier interleave에서 거절이 성공으로 바뀌지 않음

### N-04. 알림 processing inbox의 200개 eviction

- 우선순위/증거: **P1 · 소스 알고리즘 확인**
- 코드: [android/app/src/main/kotlin/com/fentanest/mysafetyreport/PrefsInbox.kt:15–26](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/PrefsInbox.kt#L15-L26), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt:154–156](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt#L154-L156), [lib/services/standalone_pending_queue_store.dart:13–21](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_pending_queue_store.dart#L13-L21)
- 발생 조건: Flutter drain 전에 201개 알림 entry, 중복 재게시 포함
- 현재 동작/영향: 모든 prefix에 MAX_KEYS 200을 적용해 가장 오래된 processing QUEUE도 제거한다. report dedupe는 Dart read 때 하므로 같은 번호 반복이 다른 미처리 번호를 밀어낼 수 있다.
- 계획 요구: history retention과 processing ack를 분리. durable unacked work는 명시적 결과 없이 버리지 않음. unique-key inbox와 legacy CSV migration·동시 append 보호 유지.
- 최소 회귀/수용 기준: 199/200/201/1000·중복·동시 drain·kill/restart에서 unique pending 누락 0; overflow가 있으면 durable 명시 상태

### N-05. 무관한 앱 알림 본문까지 필터 전에 로그

- 우선순위/증거: **P1/P2 · 소스 직접 확인, 외부 유출 증거 없음**
- 코드: [android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt:42–53](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt#L42-L53), [android/app/proguard-rules.pro:1–8](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/proguard-rules.pro#L1-L8)
- 발생 조건: 알림 접근 권한이 켜지고 어떤 앱이든 알림 게시
- 현재 동작/영향: package allowlist보다 먼저 title/body를 Log에 기록한다. private notification 내용이 진단 로그/버그리포트 표면에 불필요하게 남을 수 있다. 임의 앱이 log를 읽는다는 주장은 하지 않는다.
- 계획 요구: 필터 이전 raw content 수집/로그 제거, 허용 이벤트도 redacted counters/error class만. opt-in 권한/정상 번호 검출 유지.
- 최소 회귀/수용 기준: 무관한 앱과 허용된 앱 fake 알림에서 raw title/body/번호가 기본 로그에 0건, 정상 enqueue는 유지

### N-06. native enqueue fan-out·deadline·알림 correlation

- 우선순위/증거: **P2 · 소스 직접 확인**
- 코드: [android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt:91–125](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt#L91-L125), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt:279–307](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt#L279-L307)
- 발생 조건: 알림 burst, POST stall/실패, 그 뒤 수동 crawl
- 현재 동작/영향: 매 match마다 raw thread, POST connect/read timeout 없음, finally disconnect/지속 retry 없음. auto_enqueue_count는 POST 전 증가하므로 실패가 이후 수동 작업 알림을 억제할 수 있다.
- 계획 요구: bounded executor·deadline·finally cleanup·ack/retry/idempotency. 가능한 기존 계약 내 correlation을 보존하고 새 server field는 공동 계약 없이는 가정하지 않음.
- 최소 회귀/수용 기준: blackhole/stalled body/401/429/5xx/burst/process death-after-accept; thread 상한·notification lifetime·실패 뒤 수동 crawl 알림 정상

### N-07. notification/PendingIntent ID 충돌과 shortcut 재실행

- 우선순위/증거: **P2 · 소스 경로 확인; 장치 재현 안 함**
- 코드: [android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt:28–28](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt#L28-L28), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:24–24](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt#L24-L24), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:187–201](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt#L187-L201), [lib/main.dart:655–704](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/main.dart#L655-L704)
- 발생 조건: native와 Dart 알림의 첫 발행 또는 실행 shortcut intent로 Activity 재생성
- 현재 동작/영향: 여러 producer가 3000부터 같은 untagged ID를 사용하여 덮어쓰기/cancel/PendingIntent 혼동이 가능하다. nav extras는 auth/export와 달리 소비되지 않아 완료 후 복원 때 quick action이 다시 실행될 수 있다.
- 계획 요구: semantic tag/ID·PendingIntent action/data와 reserved FGS identity를 설계한다. passive navigation과 one-shot command를 분리하고 ack/복원 정책을 명세한다.
- 최소 회귀/수용 기준: 서로 다른 producer의 동시 발행·progress cancel·1000건 WS·activity restart에서 각 tap 대상 일치; 한 genuine shortcut의 명령은 최대 1회

### N-08. FGS와 실제 Dart 실행 소유권은 별개

- 우선순위/증거: **P2 · 구조 확인, lifecycle 검증 필요**
- 코드: [android/app/src/main/kotlin/com/fentanest/mysafetyreport/SyncForegroundService.kt:27–112](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/SyncForegroundService.kt#L27-L112), [android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:22–22](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt#L22-L22), [lib/services/sync_engine.dart:120–145](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L120-L145), [lib/services/sync_engine.dart:185–230](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L185-L230)
- 발생 조건: Activity/engine 파괴, FGS 시작 거절 또는 timeout
- 현재 동작/영향: native FGS는 알림/우선순위 wrapper이고 engine/work queue를 소유하지 않는다. acquireFgs는 시작 실패를 무시하며 refcount를 증가시키고, native timeout과 Dart 상태가 연결되지 않는다. HOME/resume 통과가 task-removal 연속성을 증명하지는 않는다.
- 계획 요구: 우선 fixture로 실행 소유권을 계측한다. durable owner+checkpoint 또는 명확한 중단/재개 계약을 요구에 맞게 설계한다. force-stop 이후에도 작업이 유지된다고 약속하지 않는다.
- 최소 회귀/수용 기준: HOME/task removal/Activity recreation/process kill/FGS rejection/timeout·nested refcount에서 queue/DB/알림/실제 running 상태 일치

### N-09. CI 검증·release 진단 보존과 보안 문서 불일치

- 우선순위/증거: **P2 · workflow/script/policy 소스 대조**
- 코드: [.github/workflows/build-apk.yml:69–117](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/.github/workflows/build-apk.yml#L69-L117), [.github/workflows/build-dev-apk.yml:33–57](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/.github/workflows/build-dev-apk.yml#L33-L57), [PRIVACY_POLICY.md:60–61](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/PRIVACY_POLICY.md#L60-L61), [lib/providers/report_provider.dart:788–791](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/providers/report_provider.dart#L788-L791), [lib/services/standalone_auth_service.dart:281–294](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auth_service.dart#L281-L294), [android/app/src/main/AndroidManifest.xml:27–27](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/AndroidManifest.xml#L27-L27)
- 발생 조건: refactor release 또는 지원 기간 뒤 crash 조사, 보안 보장 해석
- 현재 동작/영향: checked-in workflows는 build/publish 중심이고 analyze/Flutter/Kotlin/contract gate가 없다. mapping 보존 기간은 1일이다. 정책은 key/token의 Keystore 저장·전송 시 TLS 사용을 말하지만, 일부 일반 prefs 저장과 LAN HTTP 지원이 있다.
- 계획 요구: signer-free 검증과 승인 배포를 분리하고, 정확한 artifact mapping/hash/provenance를 지원 기간 동안 보존한다. 저장소/transport 보장은 승인된 threat model과 migration 계획에 맞춘다. LAN HTTP를 몰래 금지하지 않는다.
- 최소 회귀/수용 기준: 실패한 test가 release를 차단하는지, mapping retrieval이 가능한지 검증. v9/v10 upgrade interruption·headless/foreground·logout/rotation·HTTP/HTTPS fake endpoint 검증. 취약점/침해 발생을 주장하지 않음

### S-01. rebuild가 pending/retryable 상세를 남긴 채 완료

- 우선순위/증거: **P1 / P0 안전성 게이트 · 소스 호출흐름 확인; 실제 엔진 재현 안 함**
- 코드: [lib/services/sync_engine.dart:471–477](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L471-L477), [lib/services/sync_engine.dart:564–569](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L564-L569), [lib/community/rebuild/community_rebuild.dart:73–86](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/rebuild/community_rebuild.dart#L73-L86), [lib/community/rebuild/community_rebuild.dart:363–395](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/rebuild/community_rebuild.dart#L363-L395), [lib/community/capture/rebuild_helpers.dart:32–54](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/capture/rebuild_helpers.dart#L32-L54)
- 발생 조건: 목록 등록 성공 뒤 상세 503, 상세 대기 중 stop 또는 item 상태 저장 실패
- 현재 동작/영향: _run은 errors와 failed_retryable을 기록하지만 failed=false 결과를 반환한다. RebuildEngine은 list_complete/permanentFailures만 보고 pending/retryable/result.errors를 확인하지 않는다. merge도 terminal 상태를 재검증하지 않아 baseline completed와 guard 해제가 가능하다.
- 계획 요구: job-scoped persisted item 상태로 완료를 판정한다. list complete와 pending/retryable 0건을 확인하고, permanent gap은 명시적 승인을 받는다. cancelled/busy/partial typed outcome과 commit 직전 원자 검증을 설계한다. 기존 no-delete staging merge는 유지한다.
- 최소 회귀/수용 기준: 실제 engine+fake HTTP에서 first 503/stop/상태 쓰기 실패/5회 승격/resume 검증. 어떤 경우도 조기 completed 금지. 기존 fake RebuildRunOutcome 테스트만으로 통과 선언 금지

### S-02. 불완전한 HTTP 성공 목록으로 fullSync 삭제

- 우선순위/증거: **P1 / P0 안전성 게이트 · 조건부 파괴 경로의 소스 확인; 실제 서버 목록 의미 미검증**
- 코드: [lib/services/sync_engine.dart:305–329](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L305-L329), [lib/services/sync_engine.dart:501–510](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L501-L510), [lib/services/standalone_api_service.dart:218–249](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_api_service.dart#L218-L249), [lib/services/local_db_service.dart:3103–3120](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L3103-L3120)
- 발생 조건: total N 뒤 짧은/중복/반복 page, result:null, offset 이동 또는 count 변경
- 현재 동작/영향: 예외가 없고 allItems가 비어 있지 않으면 수집 set에 없는 reports/report_raw/report_override를 삭제한다. 처음 total과 unique ID/page 완전성·stable snapshot을 증명하지 않는다. HTTP 예외/stop 때의 기존 삭제 방어는 이미 있다.
- 계획 요구: narrow ID staging, 응답 shape/page/unique/count 검증과 source snapshot/cursor 보장을 확인한다. 보장이 없으면 absence를 비파괴 재검증 대상으로 두는 계약을 검토한다. 단순 count 일치만으로 안전을 단정하지 않는다.
- 최소 회귀/수용 기준: 401건의 중간 page 누락/중복/empty ID/동시 추가·삭제에서 원본·raw·override의 모든 값 보존. 검증된 전체 목록만 승인된 cleanup 허용

### S-03. 실패·busy fallback과 일시 HTTP 오류가 큐에서 제거

- 우선순위/증거: **P1 · 소스 결과/오류 분류 호출 흐름 확인**
- 코드: [lib/services/standalone_auto_sync_service.dart:111–136](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auto_sync_service.dart#L111-L136), [lib/services/standalone_auto_sync_service.dart:229–257](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auto_sync_service.dart#L229-L257), [lib/services/sync_engine.dart:182–215](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L182-L215), [lib/services/standalone_api_service.dart:149–165](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_api_service.dart#L149-L165), [lib/services/standalone_api_service.dart:235–239](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_api_service.dart#L235-L239)
- 발생 조건: 미등록 신고의 fallback sync 실패/busy 또는 상세 429/500/503
- 현재 동작/영향: drain은 SyncEngine.start가 반환한 failed/busy를 검사하지 않고 재조회 결과가 notInDb이면 queue를 제거한다. 상세 HTTP 오류는 untyped Exception→otherError로 분류되어 일시적 upstream 오류도 큐에서 제거된다.
- 계획 요구: API/sync/drain/rebuild의 typed taxonomy와 authoritative absence, explicit ack를 설계한다. failed/blocked/cancelled/partial은 유지하고, busy는 join/defer로 처리한다. Retry-After/backoff는 idempotent 읽기에 적용하고 별점 POST의 자동 재시도는 금지한다.
- 최소 회귀/수용 기준: failed/busy fallback, 503→200/429→200/malformed 200/404/auth/DB 쓰기 실패에서 임시 작업 보존·명시적 영구 처리·요청 폭주 0

### S-04. sync/drain 소유권과 retry journal·queue ack 경쟁

- 우선순위/증거: **P1 위험 · 정적 interleaving; race 실행 안 함**
- 코드: [lib/services/sync_engine.dart:180–209](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L180-L209), [lib/services/standalone_auto_sync_service.dart:58–77](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auto_sync_service.dart#L58-L77), [lib/services/local_db_service.dart:144–158](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart#L144-L158), [lib/community/capture/capture_retry_store.dart:29–90](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/capture/capture_retry_store.dart#L29-L90), [lib/services/standalone_pending_queue_store.dart:37–58](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_pending_queue_store.dart#L37-L58)
- 발생 조건: manual sync와 resume drain의 동시 실행 또는 capture/rating intent add/remove 중첩
- 현재 동작/영향: 각각의 running flag는 상호 배제를 보장하지 않고, runBackgroundWork는 close를 막는 보호 refcount다. retry JSON의 atomic rename은 read-modify-write lost update를 막지 않는다. report 번호로 현재 키를 전부 ack하면 fetch 중 도착한 같은 번호의 새 알림도 소비할 수 있다.
- 계획 요구: dataset/account별 coordinator와 run ID, drain→fallback 재진입 규칙을 설계한다. ack는 claim token 단위로 수행한다. retry journal은 community DB가 고장 나도 필요하므로 복구 가능한 직렬화/버전 쓰기를 설계한다.
- 최소 회귀/수용 기준: A/B 동시 add의 합집합 보존, add/remove, 같은 번호의 새 알림, manual+resume, logout/close barrier에서 누락 0·정확한 ack·deadlock 0

### S-05. 전체 인증 body deadline과 실제 취소 경계 부족

- 우선순위/증거: **P2 · 소스 확인; timeout 재현 안 함**
- 코드: [lib/services/standalone_auth_service.dart:109–124](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auth_service.dart#L109-L124), [lib/services/standalone_auth_service.dart:186–203](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auth_service.dart#L186-L203), [lib/services/standalone_auth_service.dart:373–425](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auth_service.dart#L373-L425), [lib/services/standalone_api_service.dart:145–188](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_api_service.dart#L145-L188), [lib/services/sync_engine.dart:187–204](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L187-L204), [lib/services/sync_engine.dart:1167–1169](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L1167-L1169)
- 발생 조건: 인증 headers 뒤 body 정지 또는 gate/retry/detail/auto-drain 중 stop
- 현재 동작/영향: 15초 close/header timeout 뒤 body join에는 deadline이 없어 single-flight relogin 전체가 멈춰 있을 수 있다. Future.timeout은 transport abort가 아니며, stop은 중간 save/보조 작업/후속 projection을 즉시 중단하지 않는다. gate await 뒤 stop flag reset도 경쟁이 발생하는 경계다.
- 계획 요구: whole-operation/body byte/deadline, owned abortable transport를 설계하고 cancellation token을 외부 await 사이에 전파한다. cancel-requested와 terminal cancelled를 구분한다. atomic save는 끝내고, close를 금지하는 보호는 유지한다.
- 최소 회귀/수용 기준: headers-only/chunk stall/shared refresh·gate 대기/retry delay/auto-drain 취소, cancellation-to-idle p95/p99와 이후 request 수

### S-06. uploader·gate의 나중 await에서 세대 검증 누락

- 우선순위/증거: **P2 · 정적 context/mode race; 중앙의 무단 수락 증거 없음**
- 코드: [lib/community/upload/community_uploader.dart:611–644](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/upload/community_uploader.dart#L611-L644), [lib/community/upload/community_uploader.dart:714–774](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/upload/community_uploader.dart#L714-L774), [lib/community/upload/community_uploader.dart:1448–1462](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/upload/community_uploader.dart#L1448-L1462), [lib/community/gate/community_gate.dart:349–403](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/gate/community_gate.dart#L349-L403), [lib/community/gate/community_gate.dart:494–548](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/gate/community_gate.dart#L494-L548)
- 발생 조건: run 중 mode/account/consent/context 변경 또는 status 응답 뒤 owner/register/manifest 대기 중 logout
- 현재 동작/영향: uploader는 start 경계 검사 후 나중 batch가 old ctx를 유지하거나, new ctx로 선택한 행을 old envelope로 보낼 수 있다. gate에 이미 존재하는 status 응답 generation 검사는 이후 writer/context await까지 보호하지 않아 old OK가 재적용될 여지가 있다. 중앙 서버의 authority 재검증은 별도로 필요한 방어다.
- 계획 요구: immutable auth+mode+config/context generation, claim/send/local commit 직전 fence와 state/owner 조건부 claim을 설계한다. dispose 후 side effect를 금지한다. immutable event ID/payload/revision/lease/ACK를 보존한다.
- 최소 회귀/수용 기준: status뿐 아니라 owner/register/manifest/secure write 지연 중 logout; batch 도중 mode/context 변경 시 다음 request 없음·old ctx 활성화 없음

### S-07. 정기 gate poll의 full manifest와 lease/client 소유권

- 우선순위/증거: **P2 · 소스 기반 작업량 추론, elapsed 성능 미측정**
- 코드: [lib/community/gate/community_gate.dart:232–237](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/gate/community_gate.dart#L232-L237), [lib/community/gate/community_gate.dart:543](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/gate/community_gate.dart#L543), [lib/community/community_wiring.dart:79–105](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/community_wiring.dart#L79-L105), [lib/community/capture/server_completed.dart:54–99](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/capture/server_completed.dart#L54-L99), [lib/community/community_store.dart:268–277](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/community_store.dart#L268-L277)
- 발생 조건: 변경 없는 active writer에서 60초 foreground poll, 중첩 refresh 또는 반복 cursor
- 현재 동작/영향: manifest를 전량 list/set으로 모아 DELETE 후 행별로 insert한다. 58,388키라면 5,000키 page 최소 12개와 58,388회 insert가 코드상 작업량이다. 생성한 ingest client의 close 누락, 고정 lease owner의 manifest 재획득/해제와 반복 cursor에 대한 보호 부재도 있다.
- 계획 요구: unchanged version/delta 가능성은 정본 계약에서 확인한다. full이 필요하면 bounded staging+검증 후 atomic publish를 설계한다. per-run lease owner/renewal, owned client의 finally close, non-advancing cursor 차단을 설계한다.
- 최소 회귀/수용 기준: no-change poll의 bytes/SQL/latency, 58k/500k, lease expire/동시 refresh/repeated cursor에서 기존 manifest 보존·정확한 client close

### S-08. UI bounded 개선 뒤에도 sync 전량 상태와 반복 재집계

- 우선순위/증거: **P2 · 소스 복잡도 확인, 제품 실행 시간 미측정**
- 코드: [lib/services/sync_engine.dart:281–320](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L281-L320), [lib/services/sync_engine.dart:378–404](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L378-L404), [lib/services/sync_engine.dart:457–459](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L457-L459), [lib/services/sync_engine.dart:641–662](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart#L641-L662), [lib/services/standalone_auto_sync_service.dart:211–224](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/standalone_auto_sync_service.dart#L211-L224), [lib/services/repositories/duplicate_repository.dart:84–93](https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/repositories/duplicate_repository.dart#L84-L93)
- 발생 조건: 대형 full sync/긴 알림 queue/단건 중복 결정 변경
- 현재 동작/영향: existingStatus/allItems/toSync/account-sized state가 남아 있다. 10건을 저장할 때마다 누적 captured ID 전체를 다시 count하면 대략 N²/20회의 ID 위치 조회가 발생한다. auto-drain은 각 건마다 duplicate refresh를 하고, 단건 group 수정도 full rebuild를 기다린다.
- 계획 요구: narrow run staging/크기를 제한한 batch/SQL join, progress delta·throttle·run index, 정확한 알림을 보존하는 drain checkpoint coalescing을 설계한다. decision-only fast path/source-vs-projection revision 분리는 legacy oracle 검증 후 도입한다.
- 최소 회귀/수용 기준: 행 수뿐 아니라 총 examined ID·SQL call·retained bytes·publish 시간을 측정. 같은 건수의 수정/foreign writer/manual 대표/동률/queue 공지의 정확성 유지


### 추가 계약·유지보수 체크

- gate의 foreground 신규 작업 60초와 장애 시 성공 cache 600초 허용은 현재 문서에 함께 있다. background의 600초 허용 자체를 결함이라고 쓰지 말고, `requireFresh`가 무엇을 보장하는지 결정한 뒤 이름·정책·테스트를 맞춘다
- sync 마지막 시각은 목록 성공과 상세 완전 성공을 구분한다. attempted/partial/completed timestamp를 분리할지 현재 UI 약속과 함께 검토한다
- `personal_save_state`는 현재 local-store 계약상 표시용이며 sendability 필터가 아니다. 이를 무조건 업로드 차단 결함으로 오인하지 않는다
- 현재 uploader의 20 event/256KiB UTF-8 envelope, 1.1초 spacing, lease/heartbeat, scoped cooldown, immutable retry, ACK 불확실성 보존, one-shot rating과 capture-before-personal-save를 유지한다
- parser/rating/body-source 공통 벡터 전체 의미와 모든 platform별 패키징은 이번에 완전한 줄별/실행 검증을 하지 않았다. Sol 계획에서 미검토 부분을 먼저 확장하고 근거 없이 모두 안전하다고 쓰지 않는다

## 부록 B. 검증 상태와 정적 감사 한계

- **실행됨:** 기준 SHA/tree와 파일 목록 확인, 핵심 코드/호출자/계약/테스트 소스 정적 검토, 파일 내용의 Git blob 대조, 네 가지 작은 Python/메모리 SQLite 식 점검(JOIN 누락, TEMP UNIQUE interleaving, 중첩 unknown 산술, 좌표 predicate)
- 위 작은 식은 실제 Flutter/Dart 메서드 실행·API·모바일 DB 이관·race 통합 재현이 아니다
- **NOT_RUN:** Flutter analyze/test, Kotlin/Gradle tests/lint, APK/merged manifest, emulator/S24, 실제 sync/crawl/login/rating/upload, 성능 프로파일, 실제 DB 왕복, 메모리/전력/ANR/OOM 재현
- 개인 PC DB 3,082건은 이 감사의 모바일 성능 fixture로 사용하지 않았다. 개인 신고 행·키·토큰·원문을 산출물에 포함하지 않았다
- 저장소 runtime-validation의 868/15 및 대용량 수치는 과거 작성자의 기록이다. 이번 pass나 현재 S24 측정이 아니며 소스에서 고쳐진 경로와 남은 한계를 구분해서 인용했다
- 운영 crash 원인·실제 침해·vulnerability advisory·누수 크기·배터리 회귀·Play 정책 위반은 확정하지 않았다
- 필수 후속 검증이 안 되면 `BLOCKED` 또는 `NOT_RUN`으로 남기고 “전체 검증 완료”라고 하지 않는다

## 부록 C. 전체 파일별 조사 범위

전 파일 inventory는 완료했으나 전 파일의 모든 분기·플랫폼·제품 의미를 심층 검증한 것은 아니다. 아래 수준은 **개별 파일에 실제 수행한 범위의 상한**이며 실행 통과를 의미하지 않는다.

- **핵심 경로 검토:** 파일 전체 또는 관련 주요 함수와 호출자·계약을 문맥으로 읽음. 모든 분기 증명 아님
- **부분 검토:** 관련 섹션/인터페이스/테스트 assertion/설정만 읽음
- **구조 스캔:** 런타임 Dart 파일의 주요 class/enum, 파일 규모와 HTTP/JSON/transaction/compute/dispose 등 경계 표식을 확인. 함수 의미·모든 호출자·분기는 미검증
- **확보만:** 기준 SHA의 텍스트를 확보했으나 의미상 검토 완료라고 주장하지 않음
- **목록만:** 트리의 path/type/size 확인. 바이너리·generated 대형 registry 자료·과거 검수/계획 자료 등 내용 검토 제외
- **링크 목록:** symlink 자체 inventory. 정본 `.agents/skills` 문서는 별도로 확보/검토, 링크를 일반 파일로 해석하지 않음

파일 수: **624개**. 텍스트 확보 447개, 해당 내용은 447개 모두 Git blob과 대조했다(텍스트 저장 과정의 마지막 개행/CRLF 차이는 정규화). 확보된 자료도 미검토이면 ‘확보만’으로 표시했다. 모든 lib/ 런타임 Dart 파일은 최소한 구조 스캔으로 분류했으며, 이는 심층 검토를 뜻하지 않는다. 대형 generated registry JSON과 이미지/폰트 등 바이너리는 주로 목록만 확인했다.

검토 수준 집계: 핵심 경로 검토 91개, 부분 검토 33개, 구조 스캔 87개, 확보만 236개, 목록만 174개, 링크 목록 3개

| 파일 | 범위 |
|---|---|
| `.agents/mcp_config.json` | 확보만 |
| `.agents/skills/sr-flutter-visual-qa/SKILL.md` | 확보만 |
| `.agents/skills/sr-statistics-semantics/SKILL.md` | 확보만 |
| `.agents/skills/sr-ui-contract-audit/SKILL.md` | 확보만 |
| `.claude/skills/sr-flutter-visual-qa` | 링크 목록 |
| `.claude/skills/sr-statistics-semantics` | 링크 목록 |
| `.claude/skills/sr-ui-contract-audit` | 링크 목록 |
| `.github/workflows/build-apk.yml` | 핵심 경로 검토 |
| `.github/workflows/build-dev-apk.yml` | 핵심 경로 검토 |
| `.gitignore` | 확보만 |
| `.metadata` | 확보만 |
| `AGENTS.md` | 핵심 경로 검토 |
| `CHANGELOG.md` | 확보만 |
| `CLAUDE.md` | 확보만 |
| `GEMINI.md` | 확보만 |
| `LICENSE` | 확보만 |
| `PRIVACY_POLICY.md` | 부분 검토 |
| `PROJECT_RULES.md` | 핵심 경로 검토 |
| `README.md` | 부분 검토 |
| `VERSION` | 확보만 |
| `analysis_options.yaml` | 확보만 |
| `android/.gitignore` | 확보만 |
| `android/app/build.gradle.kts` | 핵심 경로 검토 |
| `android/app/proguard-rules.pro` | 핵심 경로 검토 |
| `android/app/src/debug/AndroidManifest.xml` | 핵심 경로 검토 |
| `android/app/src/main/AndroidManifest.xml` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ClientGateGuard.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/DbExportLocation.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/PrefsInbox.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/SafetyReportApplication.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerContract.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerVersionCompatibility.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/SyncForegroundService.kt` | 핵심 경로 검토 |
| `android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt` | 핵심 경로 검토 |
| `android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png` | 목록만 |
| `android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png` | 목록만 |
| `android/app/src/main/res/drawable-v21/launch_background.xml` | 확보만 |
| `android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png` | 목록만 |
| `android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png` | 목록만 |
| `android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png` | 목록만 |
| `android/app/src/main/res/drawable/ic_stat_logo.xml` | 확보만 |
| `android/app/src/main/res/drawable/launch_background.xml` | 확보만 |
| `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` | 확보만 |
| `android/app/src/main/res/mipmap-hdpi/ic_launcher.png` | 목록만 |
| `android/app/src/main/res/mipmap-mdpi/ic_launcher.png` | 목록만 |
| `android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` | 목록만 |
| `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` | 목록만 |
| `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` | 목록만 |
| `android/app/src/main/res/values-night/styles.xml` | 확보만 |
| `android/app/src/main/res/values/colors.xml` | 확보만 |
| `android/app/src/main/res/values/styles.xml` | 확보만 |
| `android/app/src/profile/AndroidManifest.xml` | 핵심 경로 검토 |
| `android/app/src/test/kotlin/com/fentanest/mysafetyreport/ServerCompatibilityTest.kt` | 핵심 경로 검토 |
| `android/build.gradle.kts` | 핵심 경로 검토 |
| `android/gradle.properties` | 핵심 경로 검토 |
| `android/gradle/wrapper/gradle-wrapper.properties` | 핵심 경로 검토 |
| `android/settings.gradle.kts` | 핵심 경로 검토 |
| `assets/branding/app_icon.png` | 목록만 |
| `assets/branding/app_icon_adaptive_fg.png` | 목록만 |
| `assets/branding/logo_lockup_dark.png` | 목록만 |
| `assets/branding/logo_lockup_light.png` | 목록만 |
| `assets/branding/play_store_icon_512.png` | 목록만 |
| `build_android_common.sh` | 핵심 경로 검토 |
| `build_android_release.sh` | 핵심 경로 검토 |
| `build_test_apk.sh` | 핵심 경로 검토 |
| `contracts/community-ingest/MANIFEST.sha256` | 확보만 |
| `contracts/community-ingest/README.md` | 확보만 |
| `contracts/community-ingest/account-api.md` | 확보만 |
| `contracts/community-ingest/ack.schema.json` | 확보만 |
| `contracts/community-ingest/canonical-json.md` | 확보만 |
| `contracts/community-ingest/envelope.schema.json` | 확보만 |
| `contracts/community-ingest/errors.md` | 확보만 |
| `contracts/community-ingest/gate.md` | 핵심 경로 검토 |
| `contracts/community-ingest/interfaces.md` | 확보만 |
| `contracts/community-ingest/local-store.md` | 확보만 |
| `contracts/community-ingest/observation.md` | 확보만 |
| `contracts/community-ingest/observation.schema.json` | 확보만 |
| `contracts/community-ingest/rebuild.md` | 확보만 |
| `contracts/community-ingest/schedule.md` | 확보만 |
| `contracts/community-ingest/vectors/canonical-json.json` | 확보만 |
| `contracts/community-ingest/vectors/gate.json` | 확보만 |
| `contracts/community-ingest/vectors/list_refetch.json` | 확보만 |
| `contracts/community-ingest/vectors/observations.json` | 확보만 |
| `contracts/community-ingest/vectors/schedule.json` | 확보만 |
| `contracts/dark-palette.json` | 확보만 |
| `contracts/exif-vectors.json` | 확보만 |
| `contracts/parser-vectors.json` | 확보만 |
| `contracts/rating-eligibility-vectors.json` | 확보만 |
| `contracts/selfhost-compat/README.md` | 확보만 |
| `contracts/selfhost-compat/vectors.json` | 확보만 |
| `contracts/stats-overview-vectors.json` | 확보만 |
| `contracts/storage-contract.json` | 핵심 경로 검토 |
| `contracts/upload-control/MANIFEST.sha256` | 확보만 |
| `contracts/upload-control/vectors.json` | 확보만 |
| `dart_test.yaml` | 확보만 |
| `docs/agent-dispatch-runbook.md` | 목록만 |
| `docs/architecture/README.md` | 확보만 |
| `docs/architecture/android-runtime.md` | 핵심 경로 검토 |
| `docs/architecture/bounded-reads.md` | 핵심 경로 검토 |
| `docs/architecture/client-read-handoff.md` | 핵심 경로 검토 |
| `docs/architecture/client-read-proposed-vectors.json` | 확보만 |
| `docs/architecture/community-account.md` | 확보만 |
| `docs/architecture/community-gate.md` | 확보만 |
| `docs/architecture/community-upload.md` | 확보만 |
| `docs/architecture/data-contracts.md` | 핵심 경로 검토 |
| `docs/architecture/legacy-claude-reference.md` | 확보만 |
| `docs/architecture/overview.md` | 확보만 |
| `docs/design/asset-manifest.csv` | 확보만 |
| `docs/design/dark-palette.md` | 확보만 |
| `docs/design/feature-matrix.csv` | 확보만 |
| `docs/design/statistics-spec.md` | 확보만 |
| `docs/design/ui-renewal-spec.md` | 확보만 |
| `docs/images/readme/screen-dashboard.png` | 목록만 |
| `docs/images/readme/screen-detail.png` | 목록만 |
| `docs/images/readme/screen-list.png` | 목록만 |
| `docs/images/readme/screen-map.png` | 목록만 |
| `docs/images/readme/screen-settings.png` | 목록만 |
| `docs/images/readme/screen-stats.png` | 목록만 |
| `docs/plans/backlog.md` | 목록만 |
| `docs/plans/storage-refactor-plan.md` | 목록만 |
| `docs/reviews/2026-05-23-client-startup-timeout-analysis.md` | 목록만 |
| `docs/reviews/2026-05-23-rating-management-review.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap-review.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-A-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-B-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-C-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-C2-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-G1-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-G2-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-R1-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-R1-review_report.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/gemini-task-R2-response.md` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-A-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-B-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-C-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-C2-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-G1-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-G2-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-R1-pilot-review-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-R2-final-review-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-common-elevated-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-common-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-bootstrap/task-unify-common-packet.txt` | 목록만 |
| `docs/reviews/2026-09-24-gemini-g8-stats-review.md` | 목록만 |
| `docs/reviews/2026-09-27-consent-markdown-sol.md` | 목록만 |
| `docs/reviews/2026-09-27-secure-storage-10-sol.md` | 목록만 |
| `docs/reviews/2026-09-27-upload-hardening-sol.md` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation.md` | 핵심 경로 검토 |
| `docs/reviews/2026-10-03-runtime-validation/500k-default-filter-before-cover.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/500k_opt.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/500k_preopt.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/analyze.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/baseline-58388.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/before-preload-removal-dbinfo.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/concurrent-snapshot-500k.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/concurrent-snapshot.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/dart-heap-4gb.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/dart_heap_final.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/db-roundtrip.json` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/downloads-fallback.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/duplicate-android-profile.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/duplicate-avd-lastanr.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/duplicate-navigation-preload-timeout.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/duplicate-navigation-systemui-failure.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/earlier-profile.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/emulator-gnss-watchdog.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/exchange-500k-actual-transfer.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/exchange-500k-final-verification.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/export-file-visible.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/filter-burst-rotation-oracle.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/final-profile-4gb.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/final-profile-concurrent-host-fixtures.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/final-profile-epoch-4gb.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/final-profile-retry.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/flutter-test.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-analyze.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-android-profile.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-background-export.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-dart-heap.json` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-editor-page-test.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-export-sql-check.json` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-file-folder.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-file-location.json` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-filter-burst.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-filter-metadata-test.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-flutter-test.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-large-fixtures.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-multiline.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-native-memory.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-native-test.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-navigation-20.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-navigation-dbinfo.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-no-files-fallback.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-no-files-fallback.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-profile-build.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-real-keyboard.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-reason-ime-1.0.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-reason-ime-1.3.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-reason-ime-2.0.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-reason-landscape-multiline.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/followup-rotation-automation-failure.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/kotlin-test.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/large-fixtures-before-final-query.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/large-fixtures.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/logic-parity.json` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/native-memory-4gb.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/native_memory_final.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/navigation-data-ready-2gb-failure.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/navigation20-data-ready-4gb.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/pc-giant-restore-stack.txt` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/reason-landscape-before-adaptive.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/reason-landscape-ime-scale1.3.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/reason-landscape-ime-scale2.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/reason-portrait-ime.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/rotation-corrected.jsonl` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/statistics-landscape-4gb.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/statistics-landscape-details-4gb.png` | 목록만 |
| `docs/reviews/2026-10-03-runtime-validation/statistics-portrait-4gb.png` | 목록만 |
| `docs/reviews/screenshots/consent-markdown/mobile-390-dark.png` | 목록만 |
| `docs/reviews/screenshots/consent-markdown/mobile-390-light.png` | 목록만 |
| `docs/testing/renders/2026-09-24/emulator_dark_contact.png` | 목록만 |
| `docs/testing/renders/2026-09-24/emulator_light_contact.png` | 목록만 |
| `docs/testing/ui-test-plan.md` | 핵심 경로 검토 |
| `example-dark.png` | 목록만 |
| `example.png` | 목록만 |
| `flutter_launcher_icons.yaml` | 확보만 |
| `ios/.gitignore` | 확보만 |
| `ios/Flutter/AppFrameworkInfo.plist` | 확보만 |
| `ios/Flutter/Debug.xcconfig` | 확보만 |
| `ios/Flutter/Release.xcconfig` | 확보만 |
| `ios/Runner.xcodeproj/project.pbxproj` | 확보만 |
| `ios/Runner.xcodeproj/project.xcworkspace/contents.xcworkspacedata` | 확보만 |
| `ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 확보만 |
| `ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | 확보만 |
| `ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` | 확보만 |
| `ios/Runner.xcworkspace/contents.xcworkspacedata` | 확보만 |
| `ios/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 확보만 |
| `ios/Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | 확보만 |
| `ios/Runner/AppDelegate.swift` | 확보만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` | 확보만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-50x50@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-50x50@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-57x57@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-57x57@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-72x72@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-72x72@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json` | 확보만 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png` | 목록만 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png` | 목록만 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md` | 확보만 |
| `ios/Runner/Base.lproj/LaunchScreen.storyboard` | 확보만 |
| `ios/Runner/Base.lproj/Main.storyboard` | 확보만 |
| `ios/Runner/Info.plist` | 확보만 |
| `ios/Runner/Runner-Bridging-Header.h` | 확보만 |
| `ios/Runner/SceneDelegate.swift` | 확보만 |
| `ios/RunnerTests/RunnerTests.swift` | 확보만 |
| `lib/community/capture/canonical_json.dart` | 구조 스캔 |
| `lib/community/capture/capture_retry_store.dart` | 핵심 경로 검토 |
| `lib/community/capture/community_capture.dart` | 핵심 경로 검토 |
| `lib/community/capture/list_refetch.dart` | 구조 스캔 |
| `lib/community/capture/observation_rules.dart` | 구조 스캔 |
| `lib/community/capture/rebuild_helpers.dart` | 핵심 경로 검토 |
| `lib/community/capture/report_adapter.dart` | 구조 스캔 |
| `lib/community/capture/reshare.dart` | 구조 스캔 |
| `lib/community/capture/server_completed.dart` | 핵심 경로 검토 |
| `lib/community/client_account_notice.dart` | 구조 스캔 |
| `lib/community/community_store.dart` | 핵심 경로 검토 |
| `lib/community/community_wiring.dart` | 핵심 경로 검토 |
| `lib/community/gate/community_account_client.dart` | 구조 스캔 |
| `lib/community/gate/community_device_label.dart` | 구조 스캔 |
| `lib/community/gate/community_gate.dart` | 핵심 경로 검토 |
| `lib/community/gate/gate_state.dart` | 핵심 경로 검토 |
| `lib/community/kakao_logout.dart` | 구조 스캔 |
| `lib/community/rebuild/community_rebuild.dart` | 핵심 경로 검토 |
| `lib/community/upload/community_ingest_client.dart` | 핵심 경로 검토 |
| `lib/community/upload/community_schedule.dart` | 핵심 경로 검토 |
| `lib/community/upload/community_uploader.dart` | 핵심 경로 검토 |
| `lib/community/upload/upload_background.dart` | 핵심 경로 검토 |
| `lib/community/upload/upload_controller.dart` | 핵심 경로 검토 |
| `lib/community/upload/upload_defaults.dart` | 구조 스캔 |
| `lib/community/upload/upload_policy.dart` | 핵심 경로 검토 |
| `lib/community/upload_hooks.dart` | 핵심 경로 검토 |
| `lib/main.dart` | 부분 검토 |
| `lib/models/agency_stats.dart` | 구조 스캔 |
| `lib/models/app_mode.dart` | 핵심 경로 검토 |
| `lib/models/app_theme_mode.dart` | 구조 스캔 |
| `lib/models/duplicate_group.dart` | 구조 스캔 |
| `lib/models/editor_schema.dart` | 구조 스캔 |
| `lib/models/file_item.dart` | 구조 스캔 |
| `lib/models/notification_item.dart` | 구조 스캔 |
| `lib/models/rating_batch_result.dart` | 구조 스캔 |
| `lib/models/rating_lookup.dart` | 구조 스캔 |
| `lib/models/report.dart` | 구조 스캔 |
| `lib/models/report_filter.dart` | 핵심 경로 검토 |
| `lib/models/report_map.dart` | 구조 스캔 |
| `lib/models/stats_overview.dart` | 구조 스캔 |
| `lib/models/sunwi.dart` | 구조 스캔 |
| `lib/navigation/app_routes.dart` | 핵심 경로 검토 |
| `lib/providers/notification_history_provider.dart` | 구조 스캔 |
| `lib/providers/report_provider.dart` | 부분 검토 |
| `lib/screens/community_onboarding_screen.dart` | 구조 스캔 |
| `lib/screens/community_rebuild_screen.dart` | 구조 스캔 |
| `lib/screens/crawl_screen.dart` | 부분 검토 |
| `lib/screens/dashboard_screen.dart` | 부분 검토 |
| `lib/screens/data_editor_screen.dart` | 구조 스캔 |
| `lib/screens/duplicate_management_screen.dart` | 구조 스캔 |
| `lib/screens/file_browser_screen.dart` | 구조 스캔 |
| `lib/screens/filtered_list_screen.dart` | 핵심 경로 검토 |
| `lib/screens/notifications_screen.dart` | 구조 스캔 |
| `lib/screens/permission_screen.dart` | 구조 스캔 |
| `lib/screens/rating_management_panel.dart` | 핵심 경로 검토 |
| `lib/screens/recent_answers_screen.dart` | 핵심 경로 검토 |
| `lib/screens/report_list_screen.dart` | 부분 검토 |
| `lib/screens/report_management_screen.dart` | 구조 스캔 |
| `lib/screens/report_map_screen.dart` | 구조 스캔 |
| `lib/screens/search_screen.dart` | 구조 스캔 |
| `lib/screens/secure_storage_recovery_screen.dart` | 구조 스캔 |
| `lib/screens/settings_screen.dart` | 부분 검토 |
| `lib/screens/setup_screen.dart` | 부분 검토 |
| `lib/screens/statistics_screen.dart` | 핵심 경로 검토 |
| `lib/screens/sunwi_screen.dart` | 구조 스캔 |
| `lib/screens/watchlist_screen.dart` | 구조 스캔 |
| `lib/server_palette.dart` | 구조 스캔 |
| `lib/services/agency_registry.dart` | 구조 스캔 |
| `lib/services/api_service.dart` | 부분 검토 |
| `lib/services/app_prefs_keys.dart` | 구조 스캔 |
| `lib/services/app_storage_paths.dart` | 구조 스캔 |
| `lib/services/attachment_policy.dart` | 구조 스캔 |
| `lib/services/background_login_check.dart` | 핵심 경로 검토 |
| `lib/services/bounded_duplicate_rebuild.dart` | 핵심 경로 검토 |
| `lib/services/client_compatibility.dart` | 구조 스캔 |
| `lib/services/client_media_access.dart` | 구조 스캔 |
| `lib/services/community_auth_config.dart` | 구조 스캔 |
| `lib/services/community_auth_link.dart` | 구조 스캔 |
| `lib/services/community_auth_link_channel.dart` | 구조 스캔 |
| `lib/services/community_auth_pkce.dart` | 구조 스캔 |
| `lib/services/community_auth_service.dart` | 구조 스캔 |
| `lib/services/community_server_link_service.dart` | 구조 스캔 |
| `lib/services/crawl_unresolved.dart` | 구조 스캔 |
| `lib/services/db_export_location.dart` | 구조 스캔 |
| `lib/services/duplicate_projection_service.dart` | 핵심 경로 검토 |
| `lib/services/fine_estimate.dart` | 부분 검토 |
| `lib/services/geocode_utils.dart` | 핵심 경로 검토 |
| `lib/services/local_db_service.dart` | 핵심 경로 검토 |
| `lib/services/maintenance_service.dart` | 구조 스캔 |
| `lib/services/map_presentation.dart` | 구조 스캔 |
| `lib/services/network_retry_config.dart` | 핵심 경로 검토 |
| `lib/services/pending_changes_store.dart` | 핵심 경로 검토 |
| `lib/services/pending_db_import_action.dart` | 구조 스캔 |
| `lib/services/performance_trace.dart` | 구조 스캔 |
| `lib/services/permission_service.dart` | 핵심 경로 검토 |
| `lib/services/photo_capture_time.dart` | 구조 스캔 |
| `lib/services/prefs_inbox.dart` | 핵심 경로 검토 |
| `lib/services/rating_service.dart` | 구조 스캔 |
| `lib/services/report_query.dart` | 핵심 경로 검토 |
| `lib/services/repositories/duplicate_repository.dart` | 핵심 경로 검토 |
| `lib/services/repositories/editor_repository.dart` | 구조 스캔 |
| `lib/services/repositories/sunwi_repository.dart` | 구조 스캔 |
| `lib/services/repositories/watchlist_repository.dart` | 구조 스캔 |
| `lib/services/review_prompt_service.dart` | 구조 스캔 |
| `lib/services/secure_storage_migration.dart` | 핵심 경로 검토 |
| `lib/services/server_connection_service.dart` | 부분 검토 |
| `lib/services/server_contract.dart` | 부분 검토 |
| `lib/services/standalone_api_service.dart` | 핵심 경로 검토 |
| `lib/services/standalone_auth_service.dart` | 핵심 경로 검토 |
| `lib/services/standalone_auto_sync_service.dart` | 핵심 경로 검토 |
| `lib/services/standalone_parser.dart` | 구조 스캔 |
| `lib/services/standalone_pending_queue_store.dart` | 핵심 경로 검토 |
| `lib/services/sunwi_service.dart` | 구조 스캔 |
| `lib/services/support_links.dart` | 구조 스캔 |
| `lib/services/sync_engine.dart` | 핵심 경로 검토 |
| `lib/storage/schema_utils.dart` | 구조 스캔 |
| `lib/theme/app_theme.dart` | 구조 스캔 |
| `lib/theme/sr_colors.dart` | 구조 스캔 |
| `lib/widgets/auth_status_notice.dart` | 구조 스캔 |
| `lib/widgets/community_account_card.dart` | 구조 스캔 |
| `lib/widgets/community_card_parts.dart` | 구조 스캔 |
| `lib/widgets/community_server_account_card.dart` | 구조 스캔 |
| `lib/widgets/community_upload_panel.dart` | 구조 스캔 |
| `lib/widgets/consent_markdown.dart` | 구조 스캔 |
| `lib/widgets/duplicate_group_detail_sheet.dart` | 구조 스캔 |
| `lib/widgets/local_paged_report_list.dart` | 핵심 경로 검토 |
| `lib/widgets/maintenance_status_bar.dart` | 구조 스캔 |
| `lib/widgets/mode_badge.dart` | 구조 스캔 |
| `lib/widgets/rating_dialog.dart` | 구조 스캔 |
| `lib/widgets/report_detail_sheet.dart` | 부분 검토 |
| `lib/widgets/report_list_card.dart` | 구조 스캔 |
| `lib/widgets/search_filter_sheet.dart` | 구조 스캔 |
| `lib/widgets/selection_action_bar.dart` | 구조 스캔 |
| `lib/widgets/selection_back_scope.dart` | 구조 스캔 |
| `lib/widgets/sr_tab_bar.dart` | 구조 스캔 |
| `lib/widgets/stats_fine_breakdown.dart` | 구조 스캔 |
| `lib/widgets/stats_overview_section.dart` | 구조 스캔 |
| `lib/widgets/status_badge.dart` | 구조 스캔 |
| `lib/widgets/sync_exit_guard.dart` | 구조 스캔 |
| `lib/widgets/sync_status_card.dart` | 구조 스캔 |
| `linux/.gitignore` | 확보만 |
| `linux/CMakeLists.txt` | 확보만 |
| `linux/flutter/CMakeLists.txt` | 확보만 |
| `linux/flutter/generated_plugin_registrant.cc` | 확보만 |
| `linux/flutter/generated_plugin_registrant.h` | 확보만 |
| `linux/flutter/generated_plugins.cmake` | 확보만 |
| `linux/runner/CMakeLists.txt` | 확보만 |
| `linux/runner/main.cc` | 확보만 |
| `linux/runner/my_application.cc` | 확보만 |
| `linux/runner/my_application.h` | 확보만 |
| `macos/.gitignore` | 확보만 |
| `macos/Flutter/Flutter-Debug.xcconfig` | 확보만 |
| `macos/Flutter/Flutter-Release.xcconfig` | 확보만 |
| `macos/Flutter/GeneratedPluginRegistrant.swift` | 확보만 |
| `macos/Runner.xcodeproj/project.pbxproj` | 확보만 |
| `macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 확보만 |
| `macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` | 확보만 |
| `macos/Runner.xcworkspace/contents.xcworkspacedata` | 확보만 |
| `macos/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 확보만 |
| `macos/Runner/AppDelegate.swift` | 확보만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` | 확보만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png` | 목록만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png` | 목록만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png` | 목록만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png` | 목록만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png` | 목록만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png` | 목록만 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png` | 목록만 |
| `macos/Runner/Base.lproj/MainMenu.xib` | 확보만 |
| `macos/Runner/Configs/AppInfo.xcconfig` | 확보만 |
| `macos/Runner/Configs/Debug.xcconfig` | 확보만 |
| `macos/Runner/Configs/Release.xcconfig` | 확보만 |
| `macos/Runner/Configs/Warnings.xcconfig` | 확보만 |
| `macos/Runner/DebugProfile.entitlements` | 확보만 |
| `macos/Runner/Info.plist` | 확보만 |
| `macos/Runner/MainFlutterWindow.swift` | 확보만 |
| `macos/Runner/Release.entitlements` | 확보만 |
| `macos/RunnerTests/RunnerTests.swift` | 확보만 |
| `mysafetyreport-mobile.png` | 목록만 |
| `pubspec.lock` | 부분 검토 |
| `pubspec.yaml` | 핵심 경로 검토 |
| `shared/agency-region-registry/data-sources/administrative-region-lineage-2014.csv` | 확보만 |
| `shared/agency-region-registry/data-sources/administrative-region-notices-2014.csv` | 확보만 |
| `shared/agency-region-registry/data/agency_index.json` | 목록만 |
| `shared/agency-region-registry/data/agency_institutions.json` | 목록만 |
| `shared/agency-region-registry/data/agency_legacy.json` | 목록만 |
| `shared/agency-region-registry/data/agency_links.json` | 목록만 |
| `shared/agency-region-registry/data/region_events.json` | 목록만 |
| `shared/agency-region-registry/manifest.json` | 확보만 |
| `shared/agency-region-registry/provenance.json` | 확보만 |
| `shared/agency-region-registry/resolvers/README.md` | 확보만 |
| `shared/agency-region-registry/resolvers/resolve.dart` | 확보만 |
| `shared/agency-region-registry/resolvers/resolve.py` | 확보만 |
| `shared/agency-region-registry/resolvers/resolve.ts` | 확보만 |
| `shared/agency-region-registry/schema.md` | 확보만 |
| `shared/agency-region-registry/vectors/resolve_cases.json` | 확보만 |
| `test/community/capture_intent_failure_test.dart` | 부분 검토 |
| `test/community/capture_test.dart` | 부분 검토 |
| `test/community/change_notification_batch_test.dart` | 확보만 |
| `test/community/client_account_notice_test.dart` | 확보만 |
| `test/community/community_store_test.dart` | 부분 검토 |
| `test/community/consent_copy_test.dart` | 확보만 |
| `test/community/contract_vectors_test.dart` | 확보만 |
| `test/community/device_label_test.dart` | 확보만 |
| `test/community/entry_order_test.dart` | 확보만 |
| `test/community/fake_account.dart` | 확보만 |
| `test/community/gate_client_test.dart` | 확보만 |
| `test/community/gate_evaluate_test.dart` | 부분 검토 |
| `test/community/gate_passed_hooks_test.dart` | 핵심 경로 검토 |
| `test/community/gate_state_test.dart` | 부분 검토 |
| `test/community/integration_contract_test.dart` | 부분 검토 |
| `test/community/ios_gate_test.dart` | 확보만 |
| `test/community/kakao_logout_test.dart` | 확보만 |
| `test/community/list_refetch_test.dart` | 확보만 |
| `test/community/live_stack_test.dart` | 확보만 |
| `test/community/rebuild_fresh_install_test.dart` | 부분 검토 |
| `test/community/rebuild_hook_test.dart` | 부분 검토 |
| `test/community/rebuild_state_test.dart` | 부분 검토 |
| `test/community/schedule_test.dart` | 부분 검토 |
| `test/community/sync_upload_boundary_test.dart` | 부분 검토 |
| `test/community/sync_upload_progress_log_test.dart` | 부분 검토 |
| `test/community/upload_background_test.dart` | 부분 검토 |
| `test/community/upload_control_test.dart` | 부분 검토 |
| `test/community/upload_panel_test.dart` | 확보만 |
| `test/community/upload_policy_vectors_test.dart` | 확보만 |
| `test/community/uploader_test.dart` | 부분 검토 |
| `test/community/violation_law_payload_test.dart` | 확보만 |
| `test/fixtures/fine_estimate_vectors.json` | 확보만 |
| `test/fixtures/share-consent-2026-09-28.1.md` | 확보만 |
| `test/golden/goldens/report_list_card_dark.png` | 목록만 |
| `test/golden/goldens/report_list_card_light.png` | 목록만 |
| `test/golden/goldens/stats_overview_dark.png` | 목록만 |
| `test/golden/goldens/stats_overview_light.png` | 목록만 |
| `test/golden/renewal_golden_test.dart` | 확보만 |
| `test/models/agency_stats_estimate_test.dart` | 확보만 |
| `test/providers/notification_history_merge_test.dart` | 핵심 경로 검토 |
| `test/report_navigation_regression_test.dart` | 확보만 |
| `test/services/api_service_db_download_test.dart` | 확보만 |
| `test/services/api_service_pagination_test.dart` | 확보만 |
| `test/services/attachment_policy_test.dart` | 확보만 |
| `test/services/background_login_check_test.dart` | 핵심 경로 검토 |
| `test/services/client_media_access_test.dart` | 확보만 |
| `test/services/community_auth_pkce_link_test.dart` | 확보만 |
| `test/services/community_auth_service_test.dart` | 확보만 |
| `test/services/community_server_gate_test.dart` | 확보만 |
| `test/services/community_server_link_service_test.dart` | 확보만 |
| `test/services/crawl_unresolved_test.dart` | 확보만 |
| `test/services/db_export_location_test.dart` | 확보만 |
| `test/services/duplicate_rebuild_bounded_test.dart` | 핵심 경로 검토 |
| `test/services/fine_estimate_test.dart` | 확보만 |
| `test/services/large_data_queries_test.dart` | 핵심 경로 검토 |
| `test/services/local_db_service_regression_test.dart` | 확보만 |
| `test/services/maintenance_service_test.dart` | 확보만 |
| `test/services/map_presentation_test.dart` | 확보만 |
| `test/services/pending_changes_store_test.dart` | 핵심 경로 검토 |
| `test/services/pending_db_import_action_test.dart` | 확보만 |
| `test/services/photo_capture_columns_test.dart` | 확보만 |
| `test/services/photo_capture_time_test.dart` | 확보만 |
| `test/services/rating_cause_test.dart` | 확보만 |
| `test/services/rating_eligibility_vectors_test.dart` | 확보만 |
| `test/services/rating_service_test.dart` | 확보만 |
| `test/services/read_snapshot_test.dart` | 확보만 |
| `test/services/review_prompt_service_test.dart` | 확보만 |
| `test/services/secure_storage_migration_test.dart` | 핵심 경로 검토 |
| `test/services/selfhost_compatibility_test.dart` | 확보만 |
| `test/services/server_connection_service_test.dart` | 확보만 |
| `test/services/standalone_auth_relogin_test.dart` | 확보만 |
| `test/services/standalone_pending_queue_store_test.dart` | 핵심 경로 검토 |
| `test/services/stats_law_scope_test.dart` | 확보만 |
| `test/services/stats_overview_test.dart` | 핵심 경로 검토 |
| `test/services/stats_overview_vectors_test.dart` | 확보만 |
| `test/services/stats_tables_test.dart` | 부분 검토 |
| `test/services/support_links_test.dart` | 확보만 |
| `test/storage/account_owner_test.dart` | 확보만 |
| `test/storage/agency_registry_wiring_test.dart` | 확보만 |
| `test/storage/backup_restore_test.dart` | 핵심 경로 검토 |
| `test/storage/connection_test.dart` | 핵심 경로 검토 |
| `test/storage/crawl_parity_test.dart` | 확보만 |
| `test/storage/db_copy_test.dart` | 확보만 |
| `test/storage/known_defects_test.dart` | 확보만 |
| `test/storage/migration_test.dart` | 확보만 |
| `test/storage/override_geo_test.dart` | 확보만 |
| `test/storage/parity_audit_test.dart` | 확보만 |
| `test/storage/parser_vectors_test.dart` | 확보만 |
| `test/storage/registry_vectors_test.dart` | 확보만 |
| `test/storage/server_import_test.dart` | 핵심 경로 검토 |
| `test/storage/storage_contract_test.dart` | 확보만 |
| `test/storage/user_data_test.dart` | 확보만 |
| `test/support/kakao_owner.dart` | 확보만 |
| `test/support/legacy_duplicate_rebuild.dart` | 확보만 |
| `test/support/selfhost_client_fixture.dart` | 확보만 |
| `test/support/ui_harness.dart` | 확보만 |
| `test/theme/dark_palette_contract_test.dart` | 확보만 |
| `test/theme/theme_contrast_test.dart` | 확보만 |
| `test/tool/db_roundtrip_harness_test.dart` | 핵심 경로 검토 |
| `test/tool/large_exchange_fixture_test.dart` | 확보만 |
| `test/tool/logic_parity_harness_test.dart` | 확보만 |
| `test/tool/stats_screen_render_test.dart` | 확보만 |
| `test/widget_test.dart` | 확보만 |
| `test/widgets/auth_status_notice_test.dart` | 확보만 |
| `test/widgets/bounded_screen_entry_test.dart` | 부분 검토 |
| `test/widgets/community_account_cards_test.dart` | 확보만 |
| `test/widgets/community_onboarding_flow_test.dart` | 확보만 |
| `test/widgets/community_rebuild_screen_test.dart` | 확보만 |
| `test/widgets/consent_markdown_screenshot_test.dart` | 확보만 |
| `test/widgets/consent_markdown_test.dart` | 확보만 |
| `test/widgets/duplicate_editor_radio_test.dart` | 확보만 |
| `test/widgets/photo_decode_memory_test.dart` | 부분 검토 |
| `test/widgets/photo_decode_size_test.dart` | 확보만 |
| `test/widgets/rebuild_applies_test.dart` | 확보만 |
| `test/widgets/report_detail_video_test.dart` | 확보만 |
| `test/widgets/report_list_card_test.dart` | 확보만 |
| `test/widgets/search_filter_sheet_order_keyboard_test.dart` | 확보만 |
| `test/widgets/selection_back_scope_test.dart` | 확보만 |
| `test/widgets/settings_revert_button_test.dart` | 확보만 |
| `test/widgets/stats_fine_breakdown_test.dart` | 확보만 |
| `test/widgets/stats_overview_section_test.dart` | 확보만 |
| `test/widgets/sync_exit_guard_test.dart` | 핵심 경로 검토 |
| `test/widgets_rating_dialog_test.dart` | 확보만 |
| `tool/android_fixture_ui.py` | 확보만 |
| `tool/baseline_read_probe.dart` | 확보만 |
| `tool/flutter-version` | 확보만 |
| `tool/large_data_fixture.dart` | 확보만 |
| `tool/large_db_exchange_check.py` | 확보만 |
| `tool/performance_probe.dart` | 확보만 |
| `web/favicon.png` | 목록만 |
| `web/icons/Icon-192.png` | 목록만 |
| `web/icons/Icon-512.png` | 목록만 |
| `web/icons/Icon-maskable-192.png` | 목록만 |
| `web/icons/Icon-maskable-512.png` | 목록만 |
| `web/index.html` | 확보만 |
| `web/manifest.json` | 확보만 |
| `windows/.gitignore` | 확보만 |
| `windows/CMakeLists.txt` | 확보만 |
| `windows/flutter/CMakeLists.txt` | 확보만 |
| `windows/flutter/generated_plugin_registrant.cc` | 확보만 |
| `windows/flutter/generated_plugin_registrant.h` | 확보만 |
| `windows/flutter/generated_plugins.cmake` | 확보만 |
| `windows/runner/CMakeLists.txt` | 확보만 |
| `windows/runner/Runner.rc` | 확보만 |
| `windows/runner/flutter_window.cpp` | 확보만 |
| `windows/runner/flutter_window.h` | 확보만 |
| `windows/runner/main.cpp` | 확보만 |
| `windows/runner/resource.h` | 확보만 |
| `windows/runner/resources/app_icon.ico` | 목록만 |
| `windows/runner/runner.exe.manifest` | 확보만 |
| `windows/runner/utils.cpp` | 확보만 |
| `windows/runner/utils.h` | 확보만 |
| `windows/runner/win32_window.cpp` | 확보만 |
| `windows/runner/win32_window.h` | 확보만 |


## 부록 D. 인계 시점 검증

- 2026-10-03 14:56 UTC에 원격 `refs/heads/dev`를 다시 읽어 기준 SHA `ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60`와 동일함을 확인했다. 이 시점 HEAD delta는 없다
- 모든 파일·라인 근거는 이 SHA의 source다. 시간이 지난 뒤 사용할 때는 Sol이 다시 HEAD delta를 확인해야 한다
- 이 문서는 검토와 계획 지시서다. 구현·테스트 통과·배포 완료 보고서가 아니다
