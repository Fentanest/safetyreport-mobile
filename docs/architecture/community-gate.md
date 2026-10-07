# 커뮤니티 필수 게이트·온보딩·초기화 (모바일, T5)

`contracts/community-ingest/` 정본(`gate.md`, `account-api.md`, `rebuild.md`,
`local-store.md`, `interfaces.md`)의 모바일 측 구현이다. 계약 사본은 수정하지 않는다.

## 진입 순서 (§6.2)

```
로딩 → 모드 선택(새 설치) → [필수] 카카오 인증 + [필수] 신고내용 공유 동의(온보딩)
  → 권한 안내/요청 중 모드와 무관한 항목(PermissionScreen phase: common)
  → 선택한 모드의 SetupScreen → 모드 의존 권한 보충(phase: mode, 이미 허용됐으면 건너뜀)
  → 초기화 안내·확인(Standalone 로컬 job / Client 서버 job) → 메인
```

- 새 설치의 모드 선택 화면은 게이트 검사 전에 보인다. Client·Standalone을 선택한 뒤 게이트를 검사한다. 검사 중에는 로딩 셸만 보이고 기존 신고 화면 flash 는 없다. `Demo 보기`와 Play 심사용 `demo/demo` 로그인은 모든 게이트·권한·서비스 시작을 건너뛰고 합성 DB를 연다. 새 설치의 Standalone 입력창은 데모 자격을 먼저 판별하고, 일반 자격은 로그인 API 호출 전에 기존 카카오·권한 흐름으로 보낸다.
- 기존 사용자(설정 완료)도 게이트 → 초기화 안내(필요 시) → 메인을 거친다.
- prefs·SQLite 의 옛 "완료" 플래그는 게이트 판정에 쓰지 않는다.

## 게이트 (`lib/community/gate/`)

- `gate_state.dart`: 판정 순수 함수 `evaluateGate` (`gate.md` 순서 그대로, 계약 벡터 `vectors/gate.json` — PC 와 같은 벡터).
  동의는 grant 의 (버전, 동의문 해시)를 중앙 status.policy 와 비교한다 — 앱에 정책 버전·동의문을 넣어 두지 않는다(2026-09-27).
  `datasetKeyForOfficialId` (`account-api.md`), Client fingerprint 비교
  `serverAccountMismatch`(`lib/community/client_account_notice.dart` 가 필수 설정 화면·설정의 서버 계정 카드 아래에 안내).
- 동의문(2026-09-27): 필수 설정 화면은 카카오 인증 뒤 `CommunityAccountClient.policy` 로 중앙 본문을 받아 sha256 을 확인한 뒤 보여 주고,
  그 버전·해시로 `consent` 한다(인증 전에는 "카카오 인증을 마치면 동의 문서를 불러옵니다"). 같은 카카오 계정이 이미 지금 정책에 동의했으면
  (PC·다른 기기 포함) "동의 완료"로 보이고 다시 묻지 않는다. `policy_mismatch` 면 새 본문을 다시 받아 체크를 풀고 다시 묻는다.
  본문 표시(표·링크)는 Sol 작업(`sol/consent-markdown`)에서 고친다.
- 로그인 확정·로그아웃·만료(카카오 상태가 connected/disconnected/reauthRequired 로 바뀜)면 게이트가 곧바로 다시 확인한다
  (예전엔 60초 poll·앱 복귀까지 기다렸다). 브라우저 로그인 중 단계는 건드리지 않는다.
- `community_account_client.dart`: `community-account` REST
  (`apikey` + Bearer, 30초 타임아웃, `{"protocol":1,…}`).
- `community_gate.dart` (`ChangeNotifier`): 캐시 10분, `requireFresh(60s)`,
  `invalidate(reason)`, 포그라운드 5분 poll + resume 즉시 refresh.
  `requireFresh(60s)`는 새 작업의 검증 상한이다. 대조 요청의 네트워크·시간초과·일시 서버 오류는
  `cloud_unavailable`로 공유 업로드를 보류한다. 로컬 접근은 아래 2.0.5 긴급 정책을 따른다.
  Standalone 이고 status active 면 `CommunityStore.setContext(...)`,
  상실이면 `deactivateContext`.
- 자료 주인(2026-09-27, Standalone writer 만 — Client·데모는 확인하지 않음): 중앙 status 가 진입 허용이면
  `CommunityAuthService.currentKakaoId()` 로 `LocalDbService.checkOwner` 를 부른다. 처음(주인 표시 없음)이면 적고 통과,
  다르면 `db_owner_mismatch`(writer 연결·context 없음), 번호를 못 받으면 `verification_required`(`data_owner_unverified` + 오류 코드).
  온보딩 화면이 "신고 내역 지우고 이 계정으로 시작"(`KakaoLogout.adopt` → `wipeReportData(thenOwner:)`)과
  "로그아웃(신고 내역 유지)"을 보인다. PC `services/community_gate.py` 8번과 같은 규칙.
  통과는 그때의 실행 모드에만 유효하다(`canEnter`·`requireFresh`): Client·데모에서 통과한 뒤 실제 Standalone 으로 바꾸면
  `ReportProvider` 변경 알림 → `onAppModeChanged` 가 검사 중 화면을 보이고 그 기기 DB 의 주인을 다시 확인한다.
- writer 연결(Standalone 만): 저장된 connection 이 있으면 `connections-rebind`,
  없으면 `connections` 등록, 409 `writer_conflict` 면 안내 + "이 기기로 업로드 전환"
  (takeover). 연결 등록·rebind·takeover 직후 T6 `refreshServerCompleted()` 호출,
  false 면 `중앙 공유 목록을 확인하지 못했습니다` 재시도 안내.
- 연결 비밀은 `flutter_secure_storage` 키 `community_connection_v1` 에만 둔다
  (namespace 포함). `community.db` 에 비밀을 두지 않는다.
- `ReportProvider.onGatePassed()`: 게이트 ok 첫 전환 때 1회 —
  `BackgroundLoginCheck.schedule`·drain·자동 동기화·WsService 시작 + T6
  `registerBackgroundJobs()`·`catchUp('resume')`.
- 알림 탭 이동·payload 상세·pending 변경·foreground 이벤트는 게이트 미충족이면 무시.
  딥링크(`CommunityAuthLinkChannel`)는 게이트 중에도 수신한다.
  온보딩 화면 Android back = `SystemNavigator.pop()`.

## 권한 분리 (`permission_service.dart`, `permission_screen.dart`)

- Android 전용(알림 리스너·배터리 최적화·WsService)은 iOS 에서 표시·요청하지 않는다.
- MethodChannel 호출은 `MissingPluginException`·`PlatformException` 을 잡아
  "해당 없음"으로 처리한다 (iOS 에 핸들러가 없어 멈추던 문제).
- `PermissionScreen(phase: common|mode)`: common 은 모드 무관 항목,
  mode 는 서버 WsService 보충만(이미 허용됐으면 건너뜀).

## 초기화 (`lib/community/rebuild/`, `community_rebuild_screen.dart`)

- 범위 키 `(source-rebuild-2026-09-26.1, local_dataset_id, source_account_namespace)`.
- 상태기계 `rebuild.md` 그대로. 백업 `VACUUM INTO .../backups/pre-rebuild-<run>.db`
  + `integrity_check`, 실패면 failed·무변경.
- 실행은 `SyncEngine.start(fullSync: true)` (T6 가 `rebuildRunId` 시그니처를
  제공하면 그 호출로 교체 — `.agent-runs/T5/REQUESTS.md`).
- 목록 부재 행 삭제 없음(orphan 보존·건수 표시), item checkpoint, 영구 누락 수락
  (`completed_with_gaps`), 철회·로그아웃 시 paused, 재시작 시 같은 run 재개.
- 시작 전 manifest 전 페이지 확인, 실패면 `manifest_unavailable` 로 머물고 시작 안 함.
- 초기화 필요·진행 중 자동 동기화 시작 차단(`CommunityRebuildGuard`,
  `COMMUNITY_REBUILD_REQUIRED` 안내). 조회·설정·도움말은 허용.
- Client: 서버 `GET /api/v1/community/rebuild`,
  `POST /api/v1/community/rebuild/start|resume`
  (헤더 `X-Community-User-Token`), 같은 화면 의미로 표시. 모바일 전수 수집 금지.
- Client 서버 게이트 `GET /api/v1/community/gate`: fingerprint 불일치 시
  `서버에 연결된 커뮤니티 계정이 이 앱 계정과 다릅니다` + 해결 경로.
  403 `COMMUNITY_ONBOARDING_REQUIRED`·409 `COMMUNITY_REBUILD_REQUIRED` 처리.

## 설정 카드 (`community_account_card.dart` 하단 섹션)

동의 상태·정책 버전·철회(확인 대화상자 → `consent-revoke` → `lineage_active:false`
확인 뒤 "철회됨" + 즉시 게이트 복귀; 409 `stale_grant` 면 status 재조회 뒤 현재
grant 로 재요청), `공유한 자료 삭제 요청`(확인 문구 입력 → `contributions-delete`
→ T6 `onContributionsDeleted()` + 연결 폐기), 연결 기기(writer) 상태·전환.

연결 기기에는 내부 `writer_epoch` 대신 Android 설정의 기기 이름을 표시한다.
`MainActivity.getDeviceName`은 `Settings.Global.DEVICE_NAME`을 읽고 없으면 모델명을 쓴다.
새 Standalone writer 등록 때도 이 이름을 `device_label`로 보낸다. 이미 등록된
연결의 중앙 `device_label`은 바뀌지 않지만, 이 기기의 설정 화면은 현재 기기명을
표시한다. 기기명은 표시용이며 연결 판정은 `connection_id`와 비밀로 한다.

## iOS 복귀 (실기기 미검증 — Xcode 없음)

- `Info.plist` `CFBundleURLTypes` (scheme `com.fentanest.mysafetyreport`).
- `AppDelegate.swift`: `application(_:open:options:)` + cold start
  `launchOptions[.url]` 을 같은 MethodChannel
  `com.fentanest.mysafetyreport/community_auth` 로 전달
  (`takePendingLink`·`getInitialLink`·`onCommunityAuthLink` — Android 와 동일 이름).
- Dart `CommunityAuthLinkChannel.drainInitial()` 추가.

## T6 연결 자리 (`lib/community/upload_hooks.dart`)

`refreshServerCompleted`·`registerBackgroundJobs`·`catchUp`·`onContributionsDeleted`.
기본 hook은 테스트·미연결 진입점용이다. 앱의 `CommunityWiring`이 gate·manifest·upload hook을 실제로 연결한다. hook 기본값만으로 운영 연결의 검증을 대신하지 않는다.

## 코드 대조 정정

- v2.0.3의 “데모도 카카오·클라우드 필수” 서술은 제품 요구와 달랐다. 데모 진입은 v2.0.2의 게이트 전 분기를 기준으로 복구했다. `LocalDbService.getDbPath`의 `_realDatabaseKey`는 데모 종료 후 실제 계정 변경 검증 전용이며 유지한다.

- `SyncEngine.start(fullSync: true, rebuildRunId: runId)`가 실제 초기화 run과 연결된다. 완료 표시는 list_complete, item terminal 상태, 명시적 gap 승인 집합, 활성 scope·owner·lease를 같은 community transaction에서 검사한 뒤 merge와 함께 기록한다.
- UI 연결의 rebuild는 Provider.datasetEpoch를 scope 조회 전에 캡처하고 작업 등록·최종 merge transaction 안에서 재확인한다. 이전 세대의 run은 현재 dataset의 완료 표시를 갱신하지 않는다. 검사 실패와 pending/retryable/unknown 상태는 완료로 승격하지 않는다.
- (2026-09-27) 동의문 번들 `assets/community/` 는 없앴다 — 동의문은 중앙에서 받는다.

## 업로드 연결 자동 전환 (2026-09-28)
이 기기에서 카카오 로그인을 직접 마치면(로그인 단계가 awaitingBrowser·exchanging·confirmRequired → connected) 또는 온보딩에서 공유 동의를 저장하면
`CommunityGate._claimRequested` 가 서고, 다음 writer 확인 한 번에서 `superseded` 연결·`writer_conflict` 를 takeover 로 등록한다.
앱 시작(세션 복원)·주기 확인만으로는 세우지 않는다(기기끼리 서로 뺏지 않게). `suspended` 는 가져오지 않는다. PC `community_gate.claim_for_this_device` 와 같은 규칙.
설정의 '이 기기로 업로드 전환' 버튼은 그대로 둔다.

## 공식 계정 1:1 대조와 복구

- 앱 시작, 포그라운드 복귀, 포그라운드 5분 주기에 `status.official_account.dataset_key`를 읽는다.
  Standalone은 현재 로그인 ID의 정규화 해시와 비교한다. Client의 공식 로그인은 PC 설정 소유이므로
  모바일의 잔여 Standalone ID와 비교하지 않으며 PC가 대조·계정 변경을 담당한다.
- 원격 계정 불일치 또는 `connections`의 `official_account_mismatch`/`official_account_taken`은
  writer만 중단하는 오류가 아니다. 앱 진입을 막고 기존 push 경로를 닫아 공식 로그인 화면으로 보낸다.
  일반 계정의 뒤로가기·모드 선택은 계속 차단한다. 명시적인 Play 심사용 `demo/demo` 입력만 별도 합성 DB로 전환하며 실제 DB의 계정 변경 보호는 유지한다. taken 문구는 운영자 문의를 안내한다.
- 개인 DB의 안신 계정 비교는 없다. 계정 변경 미완료 상태값만 있으면
  재로그인·경고·백업·초기화 흐름으로 복구한다. 데이터 변경 세대와 별도로 `accountConfigEpoch`를 써서
  차단으로 인한 화면 캐시 초기화가 다시 게이트를 무효화하는 재귀를 피한다.
- 일시 접속 실패 상태: “클라우드에 연결할 수 없습니다. 잠시 후 이용해 주세요”.
  HTTP 제한 약 30초, 프로젝트 공통 영속 `next_attempt_at` 이전에는 재요청하지 않는다.
  실패 시 context·공유 게이트 캐시는 비활성화하고 로컬 동기화 권한은 별도로 판정한다.
  **코드 대조 정정 — 임시 장애 화면 차단 해제:** `canBrowse`는 클라우드 장애 중에도
  일반 화면과 탭 이동을 허용한다. 설정된 앱은 재시도 전용 화면 대신 메인 화면을 연다.
  `canEnter`/`requireFresh`는 계속 닫혀 있어 작업·업로드 권한으로 사용하지 않는다.
  로컬 DB 주인 불일치, 계정 변경 미완료, 이미 확인한 원격 계정 불일치는 우회하지 않는다.
  정상 응답을 받으면 기존 설정·초기화·작업 흐름으로 복구한다.
- 새 모드 선택 이후 카카오 인증·공유 동의는 기존 앱에서 필수다. 인증되지 않은 사용자는 기존 온보딩에
  머물며, 아직 자기 바인딩을 조회할 토큰이 없어 별도 클라우드 장애 페이지로 치환하지 않는다.
  데모는 예외다. 카카오 미로그인·클라우드 장애·바인딩 불일치·계정 변경 미완료와 무관하게 합성 화면을 연다.
  데모의 게이트는 `demo_mode`(canEnter=false)로 작업 권한을 닫고 context를 비활성화한다. UI에서만 직접 허용하며
  토큰 갱신·status·바인딩·poll·업로드·권한/서비스 시작을 하지 않는다. 실제 모드로 돌아가면 다시 검증한다.
- 구서버가 `official_account` 필드를 생략하면 원격 대조만 생략한다. 필드가 있지만 객체/해시가 잘못되면
  확인 실패로 차단한다. `dataset_key:null`은 미바인딩이다. 새 연결 등록 오류는 구서버 호환 여부와 무관하게 처리한다.
- 공식 계정 변경은 삭제 확인 후에만 새 연결을 등록한다. `contributions-delete`의
  `official_account_released:true`가 없거나 결과가 불명확하면 개인 DB를 지우지 않고 중단한다.
  기존 삭제 fence와 개인 DB의 pending 표시가 앱 재시작 뒤에도 재등록을 막는다.
  성공한 변경은 `새로 시작` 화면을 거쳐 새 계정의 메인/초기화 흐름으로 진입한다.


## 코드 대조 정정 — 2.0.5 긴급 장애 정책

`canEnter`는 서버가 확인한 현재 공유 권한이고 `canBrowse`/`requireLocalAccess`는 로컬 이용 권한이다. 기존 로그인과 같은 자료 주인을 확인한 사용자는 동의 none/revoked/unknown이어도 로컬 조회·수집을 계속한다. 신규 인증이 없거나 DB 주인·공식 계정이 다르거나 이용정지가 확인되면 우회하지 않는다. 로컬에서는 누락된 DB 주인을 임의로 찍지 않는다. 동의가 필요하면 설정의 공유 동의 확인 화면에서 처리한다.

`CloudAvailability`는 community.db meta의 프로젝트별 deadline과 probe lease로 auth, status, writer, manifest, ingest 요청을 함께 제한한다. 429/408/5xx와 연결/본문 timeout에 최소 300초, Retry-After(초·HTTP-date), error.retryAfterSeconds/error.retry_after_seconds의 최대 유효값을 보존한다. foreground timer와 WorkManager가 같은 deadline을 읽으며 카운트다운은 화면만 갱신한다. 정상 OAuth 시작은 장애가 관측되지 않았다면 지연시키지 않는다. Supabase `/auth/v1/authorize?provider=kakao`는 정상 중간 경로다.

`ConsentHistory`는 기존 flutter_secure_storage의 `community_consent_history_v1:<fingerprint>`에 상태 전환만 기록한다. 네트워크 실패는 unknown 이력으로 추가하지 않는다. 동의 철회와 contributor 이용정지는 독립 상태이며 정지는 명시적 server active 응답 때만 해제한다. 재설치 시 이력이 없어질 수 있고 변조 방지를 보장하지 않는다. 개인 신고 DB/내보내기 스키마를 변경하지 않는다.

공유 context가 닫히면 검증된 같은 계정·dataset을 offline_capture meta로 보존한다. 기존 유효 grant는 원래 이벤트를 유지하고, 미동의/철회 수집은 consent_unknown/consent_denied로 보관한다. 일반 오프라인 전체수집과 동의 catch-up은 local_dataset_id를 회전하지 않는다. 전송 전에 현재 계정의 서버 동의를 다시 확인한다.

실제 동의 전환/명시적 동의 완료는 계정·grant·dataset별 durable catch-up 한 건을 예약한다. 단순 초기 active 조회와 반복 poll은 새 전체수집을 만들지 않는다. manifest를 한 번 완전히 읽고 같은 계정의 재공유 가능한 원본을 기존 reshare 이벤트로 전송하며, 전체수집은 상세 완료 표식을 남겨 중단 뒤 이어간다. 공개 완료 manifest는 전체 ingest receipt 목록이 아니다. manifest에서 안 보인다는 이유만으로 기존 ACK를 무시해 새 이벤트를 만들지 않으며 명시적인 삭제 tombstone을 우회하지 않는다. 서버 수동 초기화/receipt 소실의 완전 복원은 별도 서버 조치가 필요하다.

백그라운드는 inactive context도 복구를 시도하되 현재 세션·DB 주인·bound writer를 검증한다. 복구 one-off는 deadline 이후 네트워크 조건을 만족할 때 실행하며 Android Doze/배터리 정책 때문에 정확한 5분 실행은 보장하지 않는다. 전체수집 worker는 약 5분 작업 예산 후 미완료 job을 남긴다.
