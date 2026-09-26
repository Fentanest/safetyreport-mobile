# 커뮤니티 필수 게이트·온보딩·초기화 (모바일, T5)

`contracts/community-ingest/` 정본(`gate.md`, `account-api.md`, `rebuild.md`,
`local-store.md`, `interfaces.md`)의 모바일 측 구현이다. 계약 사본은 수정하지 않는다.

## 진입 순서 (§6.2)

```
로딩 → [필수] 카카오 인증 + [필수] 신고내용 공유 동의(온보딩)
  → 권한 안내/요청 중 모드와 무관한 항목(PermissionScreen phase: common)
  → 기존 SetupScreen → 모드 의존 권한 보충(phase: mode, 이미 허용됐으면 건너뜀)
  → 초기화 안내·확인(Standalone 로컬 job / Client 서버 job) → 메인
```

- 게이트 셸이 `MaterialApp.home` 결정 맨 앞이다. 검사 중에는 로딩 셸만 보인다
  (기존 신고 화면 flash 금지).
- 기존 사용자(설정 완료)도 게이트 → 초기화 안내(필요 시) → 메인을 거친다.
- prefs·SQLite 의 옛 "완료" 플래그는 게이트 판정에 쓰지 않는다.

## 게이트 (`lib/community/gate/`)

- `gate_state.dart`: 판정 순수 함수 `evaluateGate` (`gate.md` 순서 그대로).
  `datasetKeyForOfficialId` (`account-api.md`), Client fingerprint 비교
  `serverAccountMismatch`.
- `community_account_client.dart`: `community-account` REST
  (`apikey` + Bearer, 10초 타임아웃, `{"protocol":1,…}`).
- `community_gate.dart` (`ChangeNotifier`): 캐시 10분, `requireFresh(60s)`,
  `invalidate(reason)`, 포그라운드 60초 poll + resume 즉시 refresh.
  Standalone 이고 status active 면 `CommunityStore.setContext(...)`,
  상실이면 `deactivateContext`.
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

## iOS 복귀 (실기기 미검증 — Xcode 없음)

- `Info.plist` `CFBundleURLTypes` (scheme `com.fentanest.mysafetyreport`).
- `AppDelegate.swift`: `application(_:open:options:)` + cold start
  `launchOptions[.url]` 을 같은 MethodChannel
  `com.fentanest.mysafetyreport/community_auth` 로 전달
  (`takePendingLink`·`getInitialLink`·`onCommunityAuthLink` — Android 와 동일 이름).
- Dart `CommunityAuthLinkChannel.drainInitial()` 추가.

## T6 연결 자리 (`lib/community/upload_hooks.dart`)

`refreshServerCompleted`·`registerBackgroundJobs`·`catchUp`·`onContributionsDeleted`.
T6 병합 전까지 기본값(no-op/`true`). T6 는 같은 이름·시그니처로 채운다.

## 코드 대조 정정

- `SyncEngine.start` 에는 `rebuildRunId` named 파라미터가 아직 없다(T6 소유).
  rebuild 실행은 `start(fullSync: true)` 로 호출하고 runId 는 checkpoint 기록용이다.
- `assets/community/` 폴더의 pubspec 등록은 T6 소유라 건드리지 않았다 —
  온보딩 화면은 번들 로드 실패 시 파일 경로가 아닌 안내 문구를 보인다.
  (테스트는 파일 경로로 직접 읽는다.)
