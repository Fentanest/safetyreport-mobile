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

- 새 설치의 모드 선택 화면은 게이트 검사 전에 보인다. Client·Standalone을 선택한 뒤 게이트를 검사한다. 검사 중에는 로딩 셸만 보이고 기존 신고 화면 flash 는 없다. `Demo 보기`도 카카오 인증·클라우드 게이트를 통과한 뒤 합성 DB를 연다.
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
  성공 캐시의 나이와 관계없이 `cloud_unavailable`로 화면·작업을 차단한다(2026-10-06 확정 계약).
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
  뒤로가기·모드 선택·데모 전환으로 빠져나올 수 없다. taken 문구는 운영자 문의를 안내한다.
- 개인 DB의 안신 계정 비교는 없다. 계정 변경 미완료 상태값만 있으면
  재로그인·경고·백업·초기화 흐름으로 복구한다. 데이터 변경 세대와 별도로 `accountConfigEpoch`를 써서
  차단으로 인한 화면 캐시 초기화가 다시 게이트를 무효화하는 재귀를 피한다.
- 일시 접속 실패 페이지: “클라우드에 연결할 수 없습니다. 잠시 후 이용해 주세요”.
  HTTP 제한 30초, 자동 재시도 2/5/10초(3회), 수동 재시도, 복귀 및 다음 주기에도 재검증한다.
  실패 즉시 context 비활성·게이트 캐시 차단, 동기화/keep-alive/예약 업로드 중단.
- 새 모드 선택 이후 카카오 인증·공유 동의는 기존 앱에서 필수다. 인증되지 않은 사용자는 기존 온보딩에
  머물며, 아직 자기 바인딩을 조회할 토큰이 없어 별도 클라우드 장애 페이지로 치환하지 않는다.
  데모도 인증·클라우드 게이트를 통과해야 하며 장애 시 열린 하위 경로를 닫는다.
  데모는 공식 로그인 계정이 없으므로 바인딩 등록/비교와 업로드는 하지 않는다. 미연동 앱 사용 경로는 없다.
- 구서버가 `official_account` 필드를 생략하면 원격 대조만 생략한다. 필드가 있지만 객체/해시가 잘못되면
  확인 실패로 차단한다. `dataset_key:null`은 미바인딩이다. 새 연결 등록 오류는 구서버 호환 여부와 무관하게 처리한다.
- 공식 계정 변경은 삭제 확인 후에만 새 연결을 등록한다. `contributions-delete`의
  `official_account_released:true`가 없거나 결과가 불명확하면 개인 DB를 지우지 않고 중단한다.
  기존 삭제 fence와 개인 DB의 pending 표시가 앱 재시작 뒤에도 재등록을 막는다.
  성공한 변경은 `새로 시작` 화면을 거쳐 새 계정의 메인/초기화 흐름으로 진입한다.
