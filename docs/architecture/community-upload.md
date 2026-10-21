# 커뮤니티 업로드 데이터 경로 (모바일 T6)

Standalone 모드가 공식 상세 응답을 받은 순간의 값으로 공유 DTO 를 확정해
`community.db` 에 불변 저장하고, 그 사본만으로 실시간·수동·매일 00:00 KST 자동
업로드를 `community-ingest` 로 보낸다. 계약 정본: `contracts/community-ingest/`.
PC(safetyreport) 구현과 같은 벡터(같은 결과)다.

2026-09-28: `Report.reportNumber`를 `report_number` private event 필드로 journal v3에 저장해 업로드한다. Observation 해시는 유지한다. 번호가 뒤늦게 확보되면 같은 해시여도 새 이벤트를 만든다.
2026-09-28 개정2(계정별 기여, 소유 이전 대체): 같은 신고의 타 계정 업로드는 중앙이 `accepted`로 정상 수신한다(각자의 기여로 남고 전체는 고유 1건).
중앙 `transferred`·`cross_account_mismatch`·`report_identity_mismatch`·`ambiguous_existing_owners` ACK는 더 발급되지 않는다
(`durableStatuses`의 `transferred`는 구버전 수신분 호환용으로 유지). 새 Edge·migration 배포가 앱 업데이트보다 먼저여야 한다.
2026-09-28 개정2(계정별 전송 분리): capture prev·reshare 후보·발급은 현 계정(dataset_key·fingerprint) 범위로만 본다.
A의 제출·큐가 B의 제출을 건너뛰게 하거나 B로 rebind되지 않는다. 같은 계정의 두 dataset도 개인 집계에서 1건으로 합친다(중앙 대표 선출과 같은 규칙).

2026-09-28(같은 날 확정): 답변 완료만 중앙에 올린다. 적격 = status ∈ {accepted, partial, rejected, completed_unknown}.
처리중·보완요청·취하·이송·other 관측은 이벤트를 만들지 않는다 — `status_correction` 발급 중단, 로컬 `detail_status` 기록만.
로컬 prev 합성에 `server_completed` 를 쓰지 않는다(표·manifest 신선도 검사는 유지). 구버전 잔여 미전송 `status_correction` 행은
업로드 실행 시작 때 `blockSupersededCorrections` 가 보내지 않고 `blocked:deprecated_status_correction` 으로 보존한다(PC 동일, drop 없음).
서버는 비적격 payload·`status_correction` 이벤트를 이벤트 단위 `rejected:non_final_not_accepted`(durable=false)로 거절하며 배치 나머지는 정상 처리한다.
답변 완료로 올라간 신고가 나중에 비종결 상태로 돌아가면(드묾) 중앙은 마지막 답변 상태를 유지한다.

전체 재동기화는 `SyncEngine`이 `CommunityStore.rotateDataset('full_resync')`으로
새 로컬 공유 데이터셋을 시작한 뒤 모든 신고를 다시 수집한다. 이전 journal·outbox는
미전송 수정 사실을 잃지 않도록 남기며, 중앙 manifest와 Supabase 자료도 지우지 않는다.
동기화 전 manifest 확인에 실패하면 로컬 데이터셋을 바꾸거나 신고를 저장하지 않는다.
manifest 확인 뒤 이전 미전송 공유 자료를 `recovery` 업로드한다. 실행 예산으로 나뉘면 계속 보내며, 아직 남은 자료가 있으면
새 수집을 시작하지 않는다. OS 종료 뒤 남은 업로드 잠금은 최대 125초 기다린다. 그 이유와 건수는 동기화 로그에 표시한다.
알림 큐의 개별 동기화(`StandaloneAutoSyncService.drainIfPending`)도 첫 상세 조회 전에 이 검사를 통과해야 한다.
상세 1건의 개인 DB 저장을 완료하고 `personal_save_state='saved'`를 기록한 뒤에만
업로더를 깨운다. 동기화 완료 때 복구 업로드를 기다리고 전송·확인·재시도 건수와 결과를 로그에 표시한 뒤 완료 신호를 보낸다.
개별 동기화 큐도 작업 끝에 같은 복구 업로드를 기다린다.

## 파일

| 파일 | 역할 |
|---|---|
| `lib/community/capture/observation_rules.dart` | DTO 규칙 순수 함수 (observation.md 3절) |
| `lib/community/capture/canonical_json.dart` | 정규 JSON (canonical-json.md) |
| `lib/community/capture/community_capture.dart` | `buildAdapterInput`·`capture`·`markPersonalSave`·`decideEvent` |
| `lib/community/capture/capture_retry_store.dart` | `community_capture_retry.json` + 연속 실패 집계 |
| `lib/community/capture/list_refetch.dart` | 증분 선정 규칙 (list_refetch.json 그대로) |
| `lib/community/capture/report_adapter.dart` | 공식 상세 응답의 위도·경도를 공유 입력으로 전달 (override 금지) |
| `lib/community/capture/report_adapter.dart` | `Report` → 어댑터 입력 |
| `lib/community/capture/rebuild_helpers.dart` | 오류 분류·staging 병합 |
| `lib/community/capture/server_completed.dart` | manifest 교체·`onContributionsDeleted` |
| `lib/community/capture/reshare.dart` | reshare 발급·location_supplement 후보 |
| `lib/community/upload/upload_policy.dart` | 업로드 공통 판정 UC-1(응답 해석·오류 분류·Retry-After·백오프) — PC `community_upload_policy.py` 와 같은 벡터 |
| `lib/community/upload/community_ingest_client.dart` | ingest REST 클라이언트(전송 계층 결과 그대로: 상태·헤더·본문 ≤1MiB, 30초에 요청을 끊음, 리다이렉트 → 502) |
| `lib/community/upload/community_uploader.dart` | `requestCommunityUpload`·`nextDueAt`·`uploadStatus`·`requestReshare`·`blockSupersededCorrections` (UC-1) |
| `lib/community/upload/upload_controller.dart` | 앱 isolate 업로드 제어기(깨우기·재실행 표시·재시도 타이머) |
| `lib/community/upload/community_schedule.dart` | due 키·`registerBackgroundJobs`·`catchUp`·`CacheGateCheck` |
| `lib/community/upload/upload_defaults.dart` | 앱 기본 uploader 조립 (T5 가 gate 주입) |
| `lib/community/upload/upload_background.dart` | 백그라운드 isolate 조립 |
| `lib/widgets/community_upload_panel.dart` | 지도 탭 접이식 카드 |

## 흐름

```
상세 수신 → parseJsonToReport 직후(_augmentRatingCause 전) 어댑터 입력 생성
  → capture (community.db 한 트랜잭션: detail_status + journal [+outbox] +
     report_latest/staging + revision)
  → upsertReport → markPersonalSave → wake
```

- capture 가 실패하면 그 신고의 `upsertReport` 를 하지 않는다(저장 실패로 집계).
  한 동기화에서 연속 3회 실패하면 `community_store_unavailable` 로 멈춘다.
- trigger: 증분·전체 `realtime`, 단건 `realtime`, rebuild `rebuild`,
  수동 `manual`, 자정 `midnight`, 복구 `recovery`, 명시적 재공유 `reshare`.
- 한 요청에 같은 신고의 이벤트는 하나만. 다음 이벤트는 앞 요청 ACK 뒤 다음 요청으로.
- ACK `projection_status` 5종을 journal 에 저장하고 패널 문구에 반영한다
  (published=지도 반영됨, removed=지도에서 빠짐, held=중앙 저장 완료·지도
  반영 대기, not_public=중앙 저장(지도 비표시), not_applicable=변경 없음).
- manifest: 전 페이지 `manifest_token` 일치해야 교체(최대 3회), 실패 시 수집 중단.
- 삭제(`onContributionsDeleted`): outbox 대기 전부 blocked, 삭제 시각 이전
  journal 표시(reshare·supplement 영구 제외), `server_completed` 비움.
- Client 모드에서는 어떤 업로드·등록도 하지 않는다.

## 업로드 제어 UC-1 (2026-09-27, PC 와 같은 규칙)

계약 `contracts/upload-control/`(vectors.json + MANIFEST, PC 와 바이트 동일). 규칙 서술은 PC
`docs/architecture/community-upload.md` 의 UC-1 절과 같다 — 완료 조건(durable === true + receipt UUID), invalid_ack/ack_missing,
오류 분류와 서비스·계정 cooldown(`upload_control`, community.db v2), Retry-After(초·HTTP-date·본문, 24시간 상한), 백오프,
probing, attempt 집계, 실행별 lease owner + heartbeat, 예산(요청 25·90초 → `more_pending`), 신고별 가장 앞 revision,
UTF-8 크기 계산·413 이분·모호한 422 대조, journal writer_epoch 그대로, 영수증 없는 옛 완료 재확인, 401 실제 강제 갱신,
auth_required 재개, 실행 기록 보관(500행·30일). 결과 코드: sent·partial·no_pending·not_due·cooldown·busy_other_run·needs_auth·
needs_consent·blocked_gate·failed·more_pending(모바일은 서버 API 소비자가 아니어서 옛 값 변환이 없다).

모바일만의 것:
- 토큰: `CommunityAuthService.getAccessTokenResult(rejected:)` — 거절된 토큰이면 만료 전이어도 실제 refresh. 앱·백그라운드 isolate 가
  같은 refresh token 을 동시에 쓰지 않게 community.db lease `auth_refresh`(20초 대기) 안에서 저장소를 다시 읽고 갱신한다
  (회전된 refresh token 을 옛 값으로 덮지 않음).
- Client·데모 모드: uploader 가 `blocked_gate`/`client_mode` 로 끝내고 기록하지 않는다. 게이트는 데모를 writer 로 등록하지 않고
  (`appMode='demo'` → `deactivate('demo_mode')`), `onGatePassed` 는 Standalone(데모 제외)에서만 자정·주기 작업과 제어기를 켠다.
  Client·데모 전환·설정 초기화는 작업과 제어기를 끈다.
- 앱 제어기(`CommunityUploadController`): 수집 직후(`SyncEngine.captureAndSaveDetail` → `CommunityUploadHooks.wakeUploadNow`)·
  앱 복귀(`checkAutoSyncOnResume` → recovery)·게이트 통과가 깨운다. 실행 중 깨우기는 표시만 남겨 끝난 뒤 한 번 더(넓은 트리거 우선).
  끝날 때마다 다음 깨울 시각(`nextDueAt`)에 타이머 하나. needs_auth/needs_consent/blocked_gate 는 시각으로 깨우지 않고,
  busy_other_run 5초, failed 60초, more_pending 은 요청 간격 뒤 곧바로. 네트워크 복구 감지 플러그인은 쓰지 않는다(cooldown 탐색·복귀가 맡음).

## 서비스 쿨다운(CloudAvailability) — PC·모바일 공용 원칙 (2026-10-11, cloud-retry-brief)

Supabase 접속 불가 상태에서 재시도가 몰리는 문제의 공용 수정. 상세 코드·경합 재현은 `docs/architecture/community-gate.md`
"마감 직후 경합(결함 1·2)" 절. PC `services/community_cloud.py` `run()`과 **같은 식**이어야 한다(두 레포 docs/architecture/community-upload.md에
같은 문장):
- 지터: 기준 쿨다운에 ±20% 균등 지터.
- 점증: 연속 실패 n(성공하면 0으로 초기화)에 `300 · 2^(n-1)`초, 상한 1800초(30분).
- 서버 Retry-After(초·HTTP-date·본문 `retryAfterSeconds`/`retry_after_seconds`)가 지터 적용 후 점증값보다 길면 그 값을 따른다(절대 줄이지 않는다). 기존에 저장된 더 긴 deadline도 줄이지 않는다.
- 자정 분산: 설치(기기)별로 한 번 뽑아 영속 저장한 오프셋 0~1800초만큼 다음 자정 one-off 를 늦춰, 모든 기기(PC는 모든 PC)가
  00:00:00에 한꺼번에 기동하지 않게 한다. 기존 misfire/coalesce(또는 Android `existingWorkPolicy.replace`) 의미는 그대로 유지한다.
- 로컬에서 합성한 `cloud_cooldown` 503(probe lease 충돌, 실제 서버 응답 아님)은 쿨다운을 새로 쓰거나 늘리지 않는다 — 서버 장애의
  새 신호가 아니기 때문이다.

## 스케줄·백그라운드

- Workmanager unique periodic `community-upload-periodic`(1시간·network) +
  unique one-off `community-midnight`(다음 KST 자정 + 설치별 분산 오프셋 0~1800초 — 자정 작업이 끝날 때마다 백그라운드에서 다음 날 것을 다시 예약).
  복구 one-off(`scheduleCloudRecovery`)는 이미 지난 deadline을 받아도 최소 지연(`cloudRecoveryMinDelay`=30초)을 두어 즉시 재등록 루프를 막는다.
  dispatcher 분기는 `background_login_check.dart runCommunityUploadTask` — Standalone(데모 제외)+context active 일 때만.
  게이트 캐시(600초 이내 ok)가 오래됐으면 `refreshGateHeadless` 로 중앙 status 를 한 번 다시 확인한다(토큰 갱신 포함):
  ok(포그라운드와 같은 `evaluateGate` + 저장 연결 active·현재 세션에 묶임·context 일치)면 캐시 갱신 후 업로드,
  일시 장애면 아무 것도 바꾸지 않고 끝, 명시적 거절이면 캐시에 기록하고 context 를 끈다. rebind·등록은 하지 않는다(포그라운드 몫).
- 자정 작업: `catchUp('os')`(그날 key — PC `run_midnight` 와 같이 한 트랜잭션에서 확인·선점, 실행별 owner, owner 일치일 때만 결과 기록). 주기 작업: 누락 자정 보충 뒤, 재시도 시각이 된 행이 있으면 `recovery` — 자정 성공과 별개.
  자정 key 는 `sent`/`no_pending` 만 succeeded, 보류 사유는 오류 코드 또는 결과 코드(`midnightState`, PC `run_midnight` 와 같음).
- WorkManager 결과: 상태를 저장했거나 할 일이 없으면 true, community.db 를 못 여는 등 저장 전 예기치 못한 실패면 false(OS 재시도).
- `CacheGateCheck.invalidate` 는 캐시에 `invalidated:<사유>` 를 기록해 다른 isolate 도 보게 한다.
- iOS `Info.plist`: `UIBackgroundModes`(fetch, processing) +
  `BGTaskSchedulerPermittedIdentifiers`(workmanager-apple 소스에서 확인한 unique
  이름). **실기기 미검증.**
- 정확 알람·상시 FGS·배터리 예외 요구 없음.

## 빌드 주입

`build_android_common.sh` `prepare_community_public_config` 가
`COMMUNITY_SUPABASE_URL`·`COMMUNITY_SUPABASE_PUBLISHABLE_KEY` 환경변수로
`build/community_public.json`(2키만)을 만들고 `--dart-define-from-file` 로 넘긴다.
release 에서 비었거나 자리표시자(`<`·`...`·`PROJECT_REF`·`example.`)·
`sb_secret_`·service_role JWT 이면 실패. CI 는 GitHub Repository Variables의
`LOCAL_SUPABASE_URL`·`LOCAL_SUPABASE_PUBLISHABLE_KEY`를 각각 위의
`COMMUNITY_SUPABASE_*` 환경변수로 매핑한다(값 하드코딩 금지).
GitHub의 값은 앱에서 접근할 수 있는 셀프호스트 HTTPS 기본 URL(`/auth/v1`·`/rest/v1` 등의 경로 제외)과
해당 서버의 공개 publishable/anon 키다. 로컬 빌드 환경변수와 Dart define 이름은 기존 이름을 유지한다.
debug/test 는 값 없이도 빌드되지만 앱은 config_invalid
게이트로 잠긴다.

## 코드 대조 정정

- 2026-09-27 UC-1: 이전 모바일 업로더는 본문 `httpStatus` 가 실제 상태를 덮고, durable 을 보지 않고, 빈 results 에서 즉시 재전송
  루프, 400/413/422·HTML 404 를 통째 dead_letter, Retry-After 헤더 무시, owner 고정 lease, `wake()` 호출처 없음,
  게이트 캐시가 오래되면 백그라운드가 매번 그냥 끝났다 — 위 규칙으로 바꿨다(재현 표: PC `docs/plans/2026-09-27-upload-hardening-android.md` §0).

- 위치 좌표는 상세 응답의 `C_A_W/E`와 완료된 보완의 `SPLMNT_C_A_W/E`에서 가져온다. `geocode_cache`는 구 DB 교환 호환용으로만 남고 공유 위치에는 사용하지 않는다.
  (source='kakao', 공식 주소 해석). 사용자 수정 쓰기 경로 없음 — capture 는
  상태·source 를 걸러 공식 결과만 읽는다.
- event 결정 벡터는 `vectors/observations.json` 의 `event_decisions`(10건)다(별도 파일 아님) —
  `test/community/integration_contract_test.dart` 가 전부 검사한다(2026-09-26 통합).

## 통합 연결 (2026-09-26, `lib/community/community_wiring.dart`)
- `main.dart` 가 게이트 생성 직후 `CommunityWiring.wire()` 를 부른다: manifest 갱신(`refreshManifest` — upload lease 안에서
  `POST community-ingest/manifest` 전 페이지, 형식·total·중복·dataset/epoch·토큰 검사), `SyncEngine.ensureManifestFresh`
  (연결이 없으면 수집하지 않음), 자정·주기 작업 등록, 보충 실행, 삭제 뒤 대기 행 차단.
- namespace 는 capture·uploader·자정 스케줄 모두 **공개 설정 URL** 로 계산한다(`projectNamespace(supabaseUrl)`).
  `meta.project_namespace` 는 쓰지 않는다(통합 전에는 업로더가 이 미설정 값과 비교해 아무것도 올리지 못했다).
- 포그라운드 업로드(지도 패널)는 게이트 60초 재검증(`LiveGateCheck`), 백그라운드 isolate 는 게이트 캐시
  `community_gate_cache_v1`(게이트가 기록, ok·600초 이내만)를 쓴다.
- 실제 로컬 스택 확인: `COMMUNITY_STACK=1 COMMUNITY_PUBLISHABLE_KEY=… flutter test --no-pub test/community/live_stack_test.dart`.

## 원문 기관코드 수집 (observation-v3, 2026-09-28)

- Standalone 파서가 선택 답변의 `C_MANAGE_ORG` 원문을 `Report.agencyCode`(TEXT, reports `처리기관코드`·교환·백업 동일)로 저장한다.
  7자리 영숫자·선행 0 보존, 정수 변환 금지, 없으면 빈 값(NULL). `처리기관`(원문 기관명)은 덮어쓰지 않는다.
- payload `source_agency_code`(v3, null 가능): 같은 답변의 코드·기관명·담당자를 함께 보낸다. 서버는 저장만 하고 공개 projection에 내보내지 않는다(동의 범위 미확정 — 보고).
  v1/v2 payload 도 계속 받는다. 코드가 새로 확보되면 같은 해시여도 새 이벤트를 발급한다.
- 앱 DB 스키마 16, 서버 스키마 5(레거시 거부·초기화 후 재수집은 기존 정책 유지). 교환 계약 `storage-contract.json` 동일.
- parser_version `mobile-parser-3`/`pc-parser-3`.

## 위반법규 공유 (observation-v2, 2026-09-28)
- payload 에 `violation_law` 를 추가했다: 파서가 처리내용에서 뽑아 저장하는 위반법규 열(법 이름·조항, 60자 이내)만 보내고 처리내용 원문은 보내지 않는다. 비어 있으면 null.
- 계약 `observation-v2`(`contracts/community-ingest`, 지도 레포 정본 사본), 필수 동의 정책 `2026-09-28.2`(위반법규 공개 항목 추가). 당시 parser_version `pc-parser-2`/`mobile-parser-2`(현행 v3는 위 절).
- 중앙은 v1(12키) payload 도 받는다. 기존 공유 자료에는 위반법규가 없으므로, 배포 때 사용자 결정으로 중앙 공유 자료를 초기화하고 다시 올린다(초기화는 배포 절차, 코드에서 자동 실행하지 않음).
- 배포 순서: 중앙 SQL·auth 정책 migration → Edge Function → 앱. 앱이 먼저 나가면 중앙이 v2 를 몰라 422 로 보류된다(잃지 않음).

## 숫자 별점 공유 (observation-v4, 2026-09-28)
- 상세에서 확인한 별점 정수 1..5만 `rating`으로 캡처하고, 없거나 범위 밖이면 null로 보낸다. 별점사유 자유 텍스트는 전송하지 않는다. Standalone에서 사이트 별점 확인 뒤 capture 재조회 의도(rating_confirmed_refetch)를 기록해 다음 증분 동기화의 공식 상세를 다시 읽는다. 점수가 바뀌면 payload SHA-256이 달라져 `completed_observation`이 발급된다.
- 동의 정책 2026-09-28.3에서 별점 평균·건수를 공개한다. 기존 .1/.2 계보는 별점을 공개하지 않는다. DB 교환 스키마는 그대로다.


## 원본 JSON 전환 후보 (미출시, 2026-10-21)

계획: `../plans/raw-json-ingest-20261021.md`, 계약: `contracts/community-ingest-v2`.
동의 active + 새 원본 정책 일치 + status.ingest.contracts의 2를 모두 확인한 capture만 원본 스냅숏을 journal에 고정한다.
community.db 스키마 4는 source_journal.raw_event_json을 추가한다. 개인 신고 DB·원본 표와 PC↔모바일 교환 형식은 바꾸지 않는다.
업로더는 v1·v2를 섞지 않고 20건·압축 전 1MiB·gzip 전송 512KiB를 적용한다. stored와 parse_pending을 구분한다.
확인 불가 상태의 로컬 사용은 같은 계정·DB의 마지막 G1 뒤 72시간뿐이며, 시계 되돌림·동의 없음·outdated는 잠근다.
확인된 철회·기존 계정의 카카오 연결/기여자 삭제는 신고 DB와 주인을 보존한 소프트 리셋을 한다.
전송 거부를 먼저 기록하고 writer/context를 해제하며 outbox를 blocked로 만들고 raw_backfill 표시를 지운다.
철회 요청 실패 시 토큰과 `revoke_pending`을 남겨 잠근 채 재시도한다. 원본 일괄 전송과 보충 호출 지점은 아래 후속 구현 규칙을 따른다.
실제 브라우저·AVD·소켓 기반 검수는 릴리스 전에 별도로 통과해야 한다.


## 원본 일괄 전송·철회 후속 규칙 (미출시, 2026-10-21)

`community.db`의 `meta.raw_backfill`은 contract, parser_target, local_dataset_id,
계정·grant·dataset·writer 범위, run_id, state, phase, cursor, holds, stats와 건별 상태를 보존한다.
DB 최적화 뒤 목록 전체가 list_ok일 때만 누락 판정을 시작한다. 없는 신고와 손상 원본을 공식 상세 저장 경로로 채우고,
404/410은 raw_unavailable로 남긴다. 참여 완료 별점·사유와 첨부사진 EXIF를 보충하며 6개월 보관기간 밖 사진은 expired로 남긴다.
개별 실패 3회는 holds, 로그인 실패는 시도 횟수를 소모하지 않는 휴지, 연속 실패 5회는 300초 휴지다.
동일 문맥이면 커서부터 이어 가며 데이터셋·grant·parser·writer 범위가 바뀌면 새 run을 만든다.

N은 답변 완료 대상, N′=N−raw_unavailable이다. 모든 N′건의 stored 영수증만 done을 만든다.
parse_pending은 원본 저장 성공이고 파싱 대기는 별도 표시한다. duplicate는 original_status가 stored/no_change일 때만 저장 영수증이다.
stale_ignored·거절은 완료로 세지 않는다. 지도 카드에 전송 n/N′, 원본 없음, 채움/못 채움, holds와 수동 다시 시도를 보인다.
건별 원본·보충값은 캡처 시 journal에 고정하며 업로드 중 개인 DB에서 재구성하지 않는다.

전환은 새 원본 정책 동의 active와 ingest.contracts의 2를 모두 확인할 때다.
한 번 전환한 계정·dataset·grant는 raw_contract_scope로 고정해 capability가 잠시 사라져도 v1을 새로 만들지 않는다.
원본이 없는 보충 이벤트는 raw_required로 보류하고 raw_backfill에서 복구한다. 전환 전은 기존 v1을 유지한다.
사진 보충·금액 재전송·재공유·재파싱·일반 수집/알림 수집도 동일 capture 규칙을 따른다.

ACK의 client_notice는 영속 저장하고 어느 화면에서나 표시한다. 426은 본문 형태와 관계없이 필수 업데이트 안내로 저장한다.
최소 버전 기본값은 PC 3.6.0/모바일 2.5.0이며 서버 안내 설정으로 바꾼다. 앱 자체 버전은 변경하지 않는다.

철회는 로컬 거부를 먼저 저장하고 작업을 중단한다. revoke_pending은 서버 확인 전까지 로그인 토큰과 함께 남으며
로컬 화면과 새 동의를 잠근다. 서버 확인 뒤 writer·문맥·일괄 전송 표식을 비우고 카카오 로그인부터 재시작한다.
개인 신고 DB·원본·DB 주인·동의 이력은 보존한다. 같은 계정 재동의는 기존 DB에서 새 raw_backfill을 시작하고 다른 계정은 db_owner_mismatch로 간다.
서버 확인 실패는 성공으로 표시하지 않는다. 재시도는 서버 확인을 마칠 때까지 영속 대기한다.


## 검수 결함 수정 (2026-10-21, 미출시)

- v2 는 현재 status(`ingest.contracts` 에 2)로만 고른다(고정 없음). 2 가 빠지면 v2 행은 `v2_unavailable` 로 보류하고 v1 이벤트를 다시 만든다. raw 없는 기존 행은 v2 모드에서도 v1 로 보낸다. 503 `service_unavailable` 은 재시도이며 2 를 잃으면 그 쿨다운을 푼다.
- 원본 일괄 전송: run identity 는 `local_dataset_id` 하나. 건별 상태는 `raw_backfill_items`, 보충 시도는 `raw_backfill_supplements`, meta 에는 요약만. 보충 실패는 marker 만 남기고 원본은 보낸다. 삭제·보낼 수 없는 신고는 `not_eligible`. B 경로는 이벤트 하나(상세 저장이 만든 이벤트를 enqueue 가 채택). ACK 된 journal 의 원본은 해시만 남기고 축약. `personal_sync` 는 로컬 쓰기 구간에만 잡고 slice(20초/4분)마다 양보, 끝나면 타이머 정지.
