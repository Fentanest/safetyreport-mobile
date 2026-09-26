# 커뮤니티 업로드 데이터 경로 (모바일 T6)

Standalone 모드가 공식 상세 응답을 받은 순간의 값으로 공유 DTO 를 확정해
`community.db` 에 불변 저장하고, 그 사본만으로 실시간·수동·매일 00:00 KST 자동
업로드를 `community-ingest` 로 보낸다. 계약 정본: `contracts/community-ingest/`.
PC(safetyreport) 구현과 같은 벡터(같은 결과)다.

## 파일

| 파일 | 역할 |
|---|---|
| `lib/community/capture/observation_rules.dart` | DTO 규칙 순수 함수 (observation.md 3절) |
| `lib/community/capture/canonical_json.dart` | 정규 JSON (canonical-json.md) |
| `lib/community/capture/community_capture.dart` | `buildAdapterInput`·`capture`·`markPersonalSave`·`decideEvent` |
| `lib/community/capture/capture_retry_store.dart` | `community_capture_retry.json` + 연속 실패 집계 |
| `lib/community/capture/list_refetch.dart` | 증분 선정 규칙 (list_refetch.json 그대로) |
| `lib/community/capture/geocode_lookup.dart` | 공식 주소 `geocode_cache` 조회 (override 금지) |
| `lib/community/capture/report_adapter.dart` | `Report` → 어댑터 입력 |
| `lib/community/capture/rebuild_helpers.dart` | 오류 분류·staging 병합 |
| `lib/community/capture/server_completed.dart` | manifest 교체·`onContributionsDeleted` |
| `lib/community/capture/reshare.dart` | reshare 발급·location_supplement 후보 |
| `lib/community/upload/community_ingest_client.dart` | ingest REST 클라이언트 |
| `lib/community/upload/community_uploader.dart` | `requestCommunityUpload`·`uploadStatus`·`requestReshare` |
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
  (published=지도 반영됨, removed=지도에서 빠짐(정정), held=중앙 저장 완료·지도
  반영 대기, not_public=중앙 저장(지도 비표시), not_applicable=변경 없음).
- manifest: 전 페이지 `manifest_token` 일치해야 교체(최대 3회), 실패 시 수집 중단.
- 삭제(`onContributionsDeleted`): outbox 대기 전부 blocked, 삭제 시각 이전
  journal 표시(reshare·supplement 영구 제외), `server_completed` 비움.
- Client 모드에서는 어떤 업로드·등록도 하지 않는다.

## 스케줄·백그라운드

- Workmanager unique periodic `community-upload-periodic`(1시간·network) +
  unique one-off `community-midnight`(다음 KST 자정). dispatcher 분기는
  `background_login_check.dart` — 게이트 캐시(600초 이내 성공)+Standalone+
  context active 일 때만 `catchUp('os')`, 아니면 전송 없이 성공 반환.
- iOS `Info.plist`: `UIBackgroundModes`(fetch, processing) +
  `BGTaskSchedulerPermittedIdentifiers`(workmanager-apple 소스에서 확인한 unique
  이름). **실기기 미검증.**
- 정확 알람·상시 FGS·배터리 예외 요구 없음.

## 빌드 주입

`build_android_common.sh` `prepare_community_public_config` 가
`COMMUNITY_SUPABASE_URL`·`COMMUNITY_SUPABASE_PUBLISHABLE_KEY` 환경변수로
`build/community_public.json`(2키만)을 만들고 `--dart-define-from-file` 로 넘긴다.
release 에서 비었거나 자리표시자(`<`·`...`·`PROJECT_REF`·`example.`)·
`sb_secret_`·service_role JWT 이면 실패. CI 는 Variables 를 env 로 넘긴다
(값 하드코딩 금지). debug/test 는 값 없이도 빌드되지만 앱은 config_invalid
게이트로 잠긴다.

## 코드 대조 정정

- `geocode_cache` 쓰기 경로는 `LocalGeocodeService._persistCacheRecord` 하나뿐
  (source='kakao', 공식 주소 해석). 사용자 수정 쓰기 경로 없음 — capture 는
  상태·source 를 걸러 공식 결과만 읽는다.
- 계약 벡터에 `event_decisions` 파일이 없다. event 결정은 observation.md 4절
  문장으로 구현하고 `capture_test.dart` 로 검증했다 (T0 확인 요청 — REQUESTS.md).
