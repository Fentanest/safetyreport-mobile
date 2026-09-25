# 커뮤니티 계정 연결 (safeauth.worklazy.net · Supabase Auth · 카카오)

2026-09-25 추가. 커뮤니티 지도(`safetyreport-community-map`)에 쓰는 **카카오 계정**을 앱/서버에 연결한다.
안전신문고 계정(`standalone_auth_service.dart`)과는 완전히 별개다. 계정 연결만으로 신고 데이터가 업로드되지는 않는다
(업로드·동의는 이번 범위 밖 — 세션 공급 인터페이스까지만).

프로토콜 정본: `safetyreport-community-auth` 레포 `docs/protocol.md`(§6 Supabase Auth REST, GoTrue v2.197.0 기준).
인수 기준: 인계 키트 `04_TESTS_AND_ACCEPTANCE.md` M01–M10.

## 1. 두 모드, 두 주인

| | Standalone | Client(`AppMode.server`) |
|---|---|---|
| 인증·세션 주인 | **이 앱** | **연결된 safetyreport 서버** |
| 폰이 부르는 곳 | Supabase Auth REST 직접(`/auth/v1/*`) | 서버 API `/api/v1/community-auth/*` (`X-API-Key`)만 |
| 폰에 저장되는 것 | 세션(access/refresh token)·대기 로그인 — `flutter_secure_storage` 만 | **없음**(토큰을 받지도 저장하지도 않음, M06) |
| 브라우저 | 카카오 authorize 주소를 외부 브라우저로 | 서버가 만든 1회용 `bootstrap_url`(safeauth.worklazy.net)을 외부 브라우저로 |
| 중계(relay) | 쓰지 않음 | 서버가 씀 |
| 코드 | `lib/services/community_auth_service.dart`, `lib/widgets/community_account_card.dart` | `lib/services/community_server_link_service.dart`, `lib/widgets/community_server_account_card.dart` |

모드 분리(M05): 두 쪽은 코드·저장소를 공유하지 않는다. `ReportProvider.resetConfig()`(실제 모드 변경)는
`CommunityAuthService.clearForModeChange()` 로 Standalone 세션·대기 로그인·소비 표시를 지우고(서버 로그아웃은 best effort, 기다리지 않음),
서버의 커뮤니티 계정은 건드리지 않는다. `setConfig`/`setStandaloneConfig` 는 토큰을 어디로도 복사하지 않는다.
Client 에서 서버에 닿지 못하면 오류만 보이고 Standalone 로그인으로 바꾸지 않는다(M07).

## 2. Standalone 흐름

```
설정 > 커뮤니티 계정 > "카카오 계정으로 연결"
  CommunityAuthService.startLogin()
    ├ verifier = base64url(Random.secure 32바이트) 43자, challenge = base64url(SHA-256(verifier))
    ├ 대기 로그인 {v, attempt_id, verifier, started_at} → secure storage `community_pending_login_v1`  (브라우저 열기 **전**)
    └ launchUrl(externalApplication):
        {SUPABASE}/auth/v1/authorize?provider=kakao
          &redirect_to=com.fentanest.mysafetyreport%3A%2F%2Fauth%2Fcallback
          &code_challenge=<S256>&code_challenge_method=s256
카카오 로그인(외부 브라우저 — 앱 WebView 에서 비밀번호를 받지 않는다, RFC 8252)
Supabase → com.fentanest.mysafetyreport://auth/callback?code=<uuid>   (실패: error/error_code/error_description, query 또는 fragment)
MainActivity(onCreate/onNewIntent) → 보관함 → MethodChannel community_auth → CommunityAuthService.handleCallbackLink
    ├ scheme/host/path 정확히 일치 아니면 무시(M10)
    ├ 소비 표시(`community_consumed_callback_v1` = SHA-256(kind|code))와 같으면 무시 — 새 대기 로그인이 있어도 (M02)
    ├ 대기 로그인 없음 / 10분 지남 → 무시 + "로그인을 다시 시작해 주세요"
    ├ 교환 **전에** 소비 표시 쓰고 대기 로그인 삭제 (어떤 경로로 다시 와도 두 번 교환하지 않음)
    ├ access_denied → 취소 안내 / 그 밖의 error → 다시 시작 안내
    ├ POST /auth/v1/token?grant_type=pkce {auth_code, code_verifier}
    │    bad_code_verifier·flow_state_not_found·flow_state_expired·네트워크 → 실패(같은 코드 재교환 안 함)
    ├ GET /auth/v1/user (Bearer) → id, user_metadata 닉네임(없으면 "카카오 사용자"), email 유무
    │    실패 → 새 세션 logout?scope=local 후 실패
    └ 후보를 **메모리에만** 두고 상태 confirmRequired
전역 확인 창(CommunityAuthPrompt, 어느 화면에서든) / 카드 버튼
    ├ "이 계정으로 연결" → secure storage `community_session_v1` 한 키에 한 번 쓰기. 옛 세션은 logout?scope=local(best effort)
    └ "취소" → 새 세션 logout?scope=local 후 버림. 기존 연결 그대로
```

- 다른 계정이 이미 연결돼 있으면(저장된 `user_id` ≠ 새 `id`) 확인 창·카드에 "지금 연결된 X 계정이 이 계정으로 바뀝니다" 경고.
- 후보는 메모리에만 있다. 확인 전에 프로세스가 죽으면 후보 세션은 저장되지 않고 서버 쪽에서 자연 만료된다(로그아웃 호출은 못 함).
- Supabase PKCE flow state 는 authorize 호출부터 300초. 앱의 10분 창은 늦게 온 링크에 "다시 시작" 안내를 하기 위한 것이고, 교환 자체는 Supabase 가 거부한다.

### 세션 공급 (`getAccessToken` / `getAccessTokenResult`)

- 만료 60초 전부터 `POST /auth/v1/token?grant_type=refresh_token {refresh_token}`. 동시 호출은 `Future` 하나를 공유(single-flight) → 갱신 한 번.
- 성공: **회전된 access+refresh 를 한 번에** 저장. 갱신 중 저장된 refresh token 이 바뀌었으면(연결 해제·교체·다른 isolate 의 갱신) 덮어쓰지 않고 현재 값을 쓴다.
- `refresh_token_not_found` / `refresh_token_already_used` / `session_not_found` / `session_expired`(또는 400 `invalid_grant`) → 토큰을 지우고 계정 표시 정보만 남긴 채 `reauth_required`("다시 로그인 필요").
  단, 그 사이 다른 isolate 가 이미 회전했으면(저장값이 바뀜) 재로그인 상태로 바꾸지 않는다.
- 네트워크·5xx·429 → 세션 유지. access 가 아직 유효하면 그대로 주고, 만료됐으면 `temporarilyUnavailable`.
- 백그라운드 isolate(예: workmanager)에서도 보안 저장소를 읽어 쓸 수 있다. single-flight 는 isolate 안에서만 유효하므로
  isolate 사이 동시 갱신은 위 "저장값 비교"와 GoTrue 의 refresh token 재사용 허용 간격으로 완화한다(완전한 프로세스 락은 아님).
- **세션이 있다고 백그라운드 실행 권한이 생기지 않는다**(M09). 실행 시점은 Android 스케줄러·기존 서비스가 정한다. 아직 이 세션을 쓰는 업로더는 없다.

### 연결 해제

`disconnect()`: 진행 중 갱신을 기다린 뒤 `POST /auth/v1/logout?scope=local`(Bearer, best effort; access 가 만료됐으면 먼저 갱신) →
로컬 세션 삭제. 결과에 서버 로그아웃 확인 여부(204/200)를 돌려주고 안내 문구를 나눈다.
**scope 를 빼면 GoTrue 기본값이 global(모든 기기 로그아웃)이므로 항상 `scope=local`.**

## 3. Android 딥링크

- `AndroidManifest.xml` MainActivity 에 intent-filter `VIEW`/`DEFAULT`/`BROWSABLE`,
  `scheme="com.fentanest.mysafetyreport" host="auth" path="/callback"`(path 는 정확히 일치).
  `<queries>` 의 `appsafetyreport`(공식 안전신문고 앱 실행, outbound)와 별개다.
- 같은 activity 에 `flutter_deeplinking_enabled=false` meta-data. Flutter 3.27+ 는 기본으로 intent data 를 Navigator 라우트로 밀어 넣는데,
  이 앱은 named route 가 없어 오류가 나고 인가 코드가 라우트 이름으로 새므로 끈다. 기존 알림·바로가기 intent 는 data 가 없어 영향 없음.
- `MainActivity.captureCommunityAuthLink()`: `onCreate`(super 전)와 `onNewIntent`(super 전)에서 scheme/host/path/userInfo/port 가 정확히 맞을 때만
  링크를 companion 보관함(한 칸, 프로세스 범위)에 넣고 `intent.data = null` 로 지운다. `savedInstanceState != null`(프로세스 복원)이나
  `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`(최근 앱에서 다시 열기)면 받지 않는다 — 시스템이 옛 intent 를 다시 주는 경우라서.
  기존 `handleNavIntent`(extras `nav_tab` 등)는 그대로 이어서 불린다.
- MethodChannel `com.fentanest.mysafetyreport/community_auth`:
  - Dart → Kotlin `takePendingLink`: 보관함 링크를 돌려주고 비운다. 첫 호출 때 Kotlin 이 "Dart 준비됨" 표시.
  - Kotlin → Dart `onCommunityAuthLink`(인자 없음): 준비된 뒤 새 링크가 오면 신호만. Dart 는 다시 `takePendingLink`.
  - 링크 원문은 `takePendingLink` 한 경로로만 전달된다. 로그에 남기지 않는다.
- Dart 핸들러는 `main()` 에서 `CommunityAuthLinkChannel.start` 로 등록 → SetupScreen·설정 등 어느 화면에서든 콜드 스타트 링크를 받는다
  (기존 `permissions` 채널 핸들러는 MainNavigationScreen 에서만 등록됨).
- 확인 창·안내는 `MaterialApp.navigatorKey/scaffoldMessengerKey`(`communityAuthNavigatorKey`/`communityAuthMessengerKey`) +
  `MaterialApp.builder` 의 `CommunityAuthPrompt` 로 띄운다.
- `launchMode="singleTop"`, `taskAffinity=""` 는 바꾸지 않았다. 브라우저가 새 task 로 액티비티를 하나 더 만들더라도
  대기 로그인·소비 표시가 보안 저장소에 있어 새 엔진에서도 한 번만 교환된다(두 엔진이 **동시에** 같은 링크를 받는 경우의 완전한 원자성은 없음 — 실기기 미검증).

### 보안 메모

- 커스텀 스킴은 다른 앱도 등록할 수 있다. PKCE(verifier 는 이 기기 밖으로 나가지 않음)가 가로챈 코드의 교환을 막는다.
  향후 강화: 검증된 Android App Links(https 복귀 주소, `assetlinks.json`)로 바꾸기. redirect 는 `CommunityAuthConfig.redirectUri` 한 곳에 있다.
  운영 도메인 없이 App Links 를 완료라고 하지 않는다.
- `allowBackup="false"` 그대로. `flutter_secure_storage` 는 `encryptedSharedPreferences: true`(Keystore) — 안전신문고 비밀번호와 같은 설정, 다른 키.
- 비밀 키 방지: `sb_secret_` 키와 role 이 `service_role` 인 JWT 는 설정 단계에서 거부.

## 4. 빌드 설정

```sh
flutter build apk --dart-define=COMMUNITY_SUPABASE_URL=https://<project>.supabase.co \
                  --dart-define=COMMUNITY_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

- 둘 중 하나라도 없으면 "설정되지 않음"(로그인 버튼 없음). URL 은 https 만. 디버그 빌드에서만 `http://127.0.0.1`·`http://10.0.2.2`(로컬 Supabase) 허용.
- 기존 릴리즈 스크립트(`build_android_*.sh`)에는 아직 넣지 않았다(서명·릴리즈 경로는 승인 범위 밖). 넣을 때 공개값만 넣는다.
- **Supabase 대시보드 Auth > URL Configuration > Redirect URLs 에 `com.fentanest.mysafetyreport://auth/callback` 을 정확히 등록해야 한다.**
  (웹 중계 콜백 `https://safeauth.worklazy.net/callback.html` 과 별개 항목.) Kakao provider 활성화도 필요.

## 5. Client: 서버의 커뮤니티 계정

- 서버 `/api/v1/app/config` 의 `capabilities` 에 `community_account` 가 있을 때만 설정 > "서버 연결" 아래 카드를 보인다
  (`ReportProvider.communityAccountSupported`). 없으면 카드 없음. 있는데 404 면 "서버가 이 기능을 아직 지원하지 않습니다".
- 경로(`ServerContract.communityAuth*Path`): `GET status`, `POST start {device_label?}`, `POST confirm {request_id}`,
  `POST cancel {request_id?}`, `POST disconnect {}`. 성공 `{"data": STATUS}`.
  Kotlin `ServerContract.kt` 에는 넣지 않았다 — Kotlin 은 이 API 를 부르지 않고, 그 파일은 Kotlin 이 쓰는 경로만 둔다.
- 오류: 403(`permission_required`) → "서버 관리자 화면에서 이 기기의 커뮤니티 계정 관리 권한을 허용해야 합니다." / 404 → 미지원 /
  503 `community_disabled`·`community_unconfigured` / 409 `no_pending`·`request_mismatch`·`invalid_state` / 410 `expired` /
  429 `rate_limited` / 502 `relay_unavailable` / 네트워크 → "서버에 연결할 수 없어 요청을 시작하지 못했습니다"(시작 때).
  `code` 는 최상위·`detail.code`·`error.code` 어디서든 읽는다.
- start/confirm/cancel/disconnect 는 자동 재시도하지 않는다(중복 부작용 방지). 상태 조회만 카드가 보이고 앱이 앞에 있으며
  상태가 `pending`/`confirm_required` 일 때 3초마다.
- `bootstrap_url` 은 1회용 민감 링크: https 일 때만 외부 브라우저로 열고, 화면에 글자로 보이거나 복사·로그·저장하지 않는다.
  화면에는 비교코드(`display_code`)를 크게 보이고 "브라우저에서 비교코드가 같은지 확인하세요".
- 로그인 뒤 "연결된 서버를 확인해 주세요" + 서버가 검증한 표시 이름 + "이 계정으로 연결"/"취소"(`is_different_account` 면 교체 경고).
- `can_manage=false` 면 조작 버튼 대신 권한 안내.

## 6. 왜 supabase_flutter 를 쓰지 않았나

- `PROJECT_RULES.md` §1: 광범위 SDK/패키지 추가는 별도 승인 없이 하지 않는다. supabase_flutter 는 app_links·gotrue·realtime 등을 함께 끌어오고,
  기본 세션 저장소가 SharedPreferences 라 토큰 정책(M08)에 맞추려면 저장 adapter 를 따로 검증해야 한다. 자동 딥링크 처리와 MainActivity 처리의
  중복 교환(M02) 위험도 생긴다.
- 필요한 것은 REST 네 개(authorize URL, pkce 교환, user, refresh, logout)뿐이라 기존 의존성(`http`, `crypto`, `url_launcher`,
  `flutter_secure_storage`)으로 좁은 어댑터를 만들었다. 계약 기준: GoTrue v2.197.0(protocol.md §6). Supabase Auth 가 응답 모양을 바꾸면 이 파일을 고친다.
  오류 코드는 `error_code` → 문자열 `code` → `error` 순으로 읽는다.

## 7. 저장 키 (모두 FlutterSecureStorage)

| 키 | 내용 | 지우는 때 |
|---|---|---|
| `community_session_v1` | JSON `{v, access_token, refresh_token, expires_at(초), user_id, display_name, has_email, connected_at, state}` | 연결 해제, 모드 변경. 재로그인 필요 시 토큰만 비움 |
| `community_pending_login_v1` | JSON `{v, attempt_id, verifier, started_at(ms)}` | 복귀 링크 처리(모든 결과), 취소, 모드 변경, 브라우저 열기 실패 |
| `community_consumed_callback_v1` | 마지막으로 소비한 복귀 링크의 SHA-256 hex(코드 원문 아님) | 모드 변경 |

SharedPreferences·sqflite 에는 아무것도 넣지 않는다(DB 스키마 변경 없음). 백업·DB 내보내기 대상 아님.

## 8. 검증 상태 (2026-09-25)

- 단위/위젯 테스트: `test/services/community_auth_pkce_link_test.dart`, `community_auth_service_test.dart`,
  `community_server_link_service_test.dart`, `test/widgets/community_account_cards_test.dart` — MockClient·보안 저장소 mock 만 사용.
- **미검증(NOT RUN)**: 실기기/에뮬레이터 콜드 스타트·onNewIntent 복귀(M01), 실제 hosted Supabase + 카카오 로그인, 두 액티비티 인스턴스 경합,
  백그라운드 isolate 에서의 실제 갱신(M09), 실서버(safetyreport) 커뮤니티 API 연동. **iOS 는 구현·검증하지 않았다**(URL scheme 등록 없음).
