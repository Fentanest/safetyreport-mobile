# Android 런타임·권한·FGS·빌드

> 이관 원본: 루트 `CLAUDE.md` (sha256 `32e8f475…9481`, 마지막 변경 커밋 `161b68dc`), 2026-09-24 분할.
> 본문은 원문을 **그대로** 옮겼다. 코드와 달라진 부분은 아래 "코드 대조 정정"에만 적고 원문은 고치지 않았다.
> 원본 전체 사본: [legacy-claude-reference.md](legacy-claude-reference.md) · 제목별 대응표: [README.md](README.md)

## 코드 대조 정정 (2026-09-24, base `c64be69a`)

대용량 SQL/페이지·revision 캐시, protocol 3, 키보드 사유 입력 및 공유 DB 저장의 현재 구조는 [bounded-reads.md](bounded-reads.md)를 우선한다. Client의 추가 서버 계약은 [client-read-handoff.md](client-read-handoff.md), 실행 증거/한계는 [검증 기록](../reviews/2026-10-03-runtime-validation.md)을 따른다.

- 이 파일로 옮긴 절에서 코드와 충돌하는 기술은 이번 대조에서 발견되지 않았다. 다만 부팅 흐름(`overview.md`)의 `enableEdgeToEdge()` 표기는 구버전이다(`MainActivity.kt:46` 은 `WindowCompat.setDecorFitsSystemWindows`).
- 알림 채널/FGS/SharedPreferences 키 표는 이번 단계에서 Kotlin 코드와 줄 단위로 재대조하지 않았다 → **미검증**. UI 리뉴얼로 이 영역을 수정할 때 먼저 대조한다.

### 코드 대조 정정: 알림 기반 백그라운드 처리

아래 원문 2·3절의 «Client 즉시 POST / Standalone 앱 복귀 시 drain» 설명보다 이 절을 우선한다. 기존 Dart `backgroundTaskDispatcher`는 로그인 점검·커뮤니티 업로드 작업만 받았으며 알림 큐를 시작하지 않았다. 새 알림 Worker는 별도의 진입점과 엔진을 사용한다.

| 점검 항목 | 코드상 판정과 적용 경계 |
|---|---|
| 인증·동의 캐시 10분 만료 | 기존 `ClientGateGuard.isOpen`은 600초 뒤 false. 기존 NotificationService는 저장 전 return, WsService는 만료 후 메시지 수신·재접속 때 종료했다. 권한과 독립된 차단 조건이다. 현재 알림을 먼저 저장하고 `refreshGateHeadless(clientMode: true)`가 폰의 세션·동의를 재검증한다. 캐시 유효 기간을 늘리거나 인증을 생략하지 않는다. |
| 화면 꺼짐·Doze·앱 대기 버킷 | 기존 HTTP executor는 OS 작업 수명·wake lock·재시도가 없어 지연/실패 가능. 기기 로그 없이 실제 발생 원인은 확정할 수 없다. 현재 WorkManager 네트워크 제약 + Android 12 이상 expedited 요청, 할당량 소진 시 일반 작업으로 전환한다. 즉시 실행 시간은 보장하지 않는다. |
| FGS 시작 제한·Android 14 유형 | 기존 Client enqueue는 FGS를 시작하지 않아 FGS 시작 예외가 그 POST의 직접 원인은 아니다. WsService `specialUse`, SyncForegroundService `dataSync`와 해당 권한은 Manifest에 있다. 새 Worker는 별도 FGS를 시작하지 않는다(12 미만은 일반 작업). Standalone worker는 `backgroundWorker: true`로 Activity의 `startSyncFgs` 호출을 생략한다. |
| WS 단절/재연결 | 원래 POST와 WS는 독립이므로 WS 단절만으로 POST가 막히지는 않는다. 양쪽이 같은 만료 캐시에 막힐 수 있었다. 기존 WS가 살아 있으면 만료 시 Worker 갱신을 기다렸다 재연결한다(2026-10-17부터 연결 중 만료 3분 전에 미리 갱신 — 아래 '코드 대조 정정: Client 인증 확인 만료와 WebSocket 알림'). Worker가 Activity나 WS를 새로 띄워야 접수할 수 있는 구조는 아니다. 결과 WS를 못 받아도 요청 접수/재시도 알림과 서버 현황으로 확인한다. |
| 프로세스 종료·리스너만 재기동 | `NotificationService → ProcessingInboxStore → NotificationWork → 별도 FlutterEngine → main.notificationBackgroundMain`으로 연결한다. MainActivity 없는 엔진에 inbox·scope·캐시 저장·결과 알림 채널을 제공한다. WorkManager가 재시도 수명을 소유한다. `onStopped`/8분 watchdog에서 엔진을 종료한 후 claim을 반환하고 미완료 이벤트는 ACK하지 않는다. |
| Standalone 큐 | 기존에는 알림 수신 시 저장/탭 안내만 했다. 현재 Worker가 기존 계정/소유권·동의·초기화 게이트와 `personal_sync` lease를 거쳐 drain한다. 개별 fetch/증분 fallback을 재사용하며 성공 뒤에만 ACK한다. 6분 작업 경계와 OS 중단 시 남은 큐를 다음 작업이 처리한다. |
| 패키지·문구·그룹/업데이트 | 허용 패키지는 기존 `kr.go.safepeople`, `com.kakao.talk`만. title/text 외 bigText/textLines도 읽고 SPP 번호를 추출한다. 문구 자체에는 의존하지 않는다. 그룹과 자식이 가리키는 아직 claim하지 않은 동일 신고는 합친다. 실제 공식 앱의 패키지/번호 형식 변경 여부는 알림 원본·기기 관찰 없이는 미확인이다. 번호 없는 알림은 전체 수집으로 확대하지 않는다. |
| 중복·디바운스 | 기존 알림 수신 경로에 영구 디바운스 조건은 없었으며, `auto_enqueue_count`는 결과 표시용이었다. 현재 발신 패키지·신고번호·처리 종류·범위 fingerprint를 SQLite에서 2분만 중복 억제한다. 그룹 전체 본문·요약 건수·알림 게시 시각은 식별자로 쓰지 않는다. 2분이 지나 다시 도착한 알림은 처리 중이라도 새 이벤트로 보존한다. receipt 청소가 처리 큐를 삭제하지 않는다. |
| 재시도·실패 표시 | 한 번의 네트워크 오류를 버리지 않는다. 단발 작업은 30초 시작 지수 백오프, 별도 15분 주기 작업은 KEEP 종료 경합·작업 예약 전 프로세스 종료를 보완한다. OS 지연으로 실제 간격은 더 길 수 있다. 고정 알림으로 대기/재시도를 알리며 성공은 서버 **접수** 또는 로컬 큐 완료로 구분한다. |

Client 새 요청은 `/api/v1/crawl/notification`에 `report_number`, 고유 `request_id`를 보낸다. 같은 ID의 `accepted` 응답을 확인한 뒤에만 ACK한다. 404에서만 기존 `/crawl/enqueue`로 전환하고, 거절·응답 유실은 전환 근거로 삼지 않는다. 구경로 POST 전 미확정 표시를 저장하며 응답 유실·종료 시 pending과 함께 보존하고 자동 재전송하지 않는다. HTTP 200 확인 뒤에만 성공 표시와 ACK를 진행한다. **코드 대조 정정:** 이전 문서의 “404에서도 우회하지 않는다”는 현재 404 호환 경로와 달라 정정했다.

#### 처리 큐 격리와 복구 규칙

- Client 자동 재시도의 대상은 현재 scope의 미완료 `inbox.enqueue.native.notification.*`뿐이다. Worker의 시작/종료 판정과 native batch claim에 같은 조건을 적용한다. 구형 `native.<timestamp>…`·`native.legacy_*`는 SQLite와 기존 prefs에 보존하지만 재시도/200개 batch를 점유하지 않는다. Standalone의 정상 `inbox.queue.native.<timestamp>…` 작업은 계속 처리한다.
- 비멱등 구경로의 `crawl_legacy_enqueue_uncertain.<알림 키>`도 native 조회 **200건 제한 전**, `hasPending`, 같은 신고의 미처리 알림 합치기에서 제외한다. 각 판정 때 영속 prefs로 SQLite TEMP 제외 목록을 재구성하므로 프로세스 재시작에도 적용되고 원본 행·scope·미완료 상태·미확정 표시는 보존한다. HTTP 200 성공 영수증이 함께 남은 경우는 ACK 복구 대상으로 포함한다(SharedPreferences의 기존 직렬화/JSON 목록 모두 지원). 미확정 항목만 남으면 WorkManager는 성공 종료하며, 알림은 접수 확인 필요·자동 재전송 안 함·크롤링 현황 확인 후 필요 시 직접 요청을 안내한다. 안전하게 재시도할 다른 작업이 남은 경우에만 그 작업의 재시도를 안내한다. 별도 15분 복구 작업은 유지되지만 미확정 항목만으로 Flutter 엔진을 시작하지 않는다.
- `접수 확인 필요` 안내는 실행할 작업이 있던 Worker가 현재 scope의 미확정 **이벤트 키 집합**이 마지막 게시와 다를 때만 게시한다. 게시 성공 뒤 `NotificationWork` prefs의 scope별 receipt에 집합을 저장하므로 사용자가 알림을 지워도 같은 집합은 재게시하지 않는다. 건수가 같은 새 이벤트도 집합 변경으로 구분하며, 미확정 집합이 비면 해당 scope의 receipt를 지운다. 작업 없는 정기 실행은 새 집합도 게시·알림 완료 처리하지 않는다. 다른 계정·서버로 전환해도 원래 scope의 receipt는 유지하며, admission을 얻지 못했거나 처리 중 scope가 바뀐 Worker는 게시하지 않는다. 이 receipt는 안내 중복 방지용이며 서버 접수 성공·큐 ACK 또는 원본 삭제를 뜻하지 않는다.
- scope가 다른 행은 원래 `scope`, `event_key`, `value`, 미완료 상태를 그대로 보존한다. Dart에는 현재 scope claim만 내보내고 다른 scope의 prefs mirror만 정리한다. 이는 원본 삭제나 성공 ACK가 아니다. 소유권 미확인 단일 prefs 원본도 유지한다.
- 소유자가 확인된 이전 scope의 알림은 원래 계정·모드·서버 주소·API 키뿐 아니라 **설정 세대(`native_config_generation`)까지 동일한 scope**일 때만 기존 claim 경로에서 다시 처리할 수 있다. 앱에서 설정을 재저장하면 세대가 증가하므로 단순 재로그인/주소 복원으로 복구된다고 보장하지 않는다. 세대 값을 인위적으로 되돌려 격리를 해제해서는 안 된다. 현재 계정으로 scope를 덮어쓰는 자동 이관은 하지 않는다. `standaloneUsername`도 Standalone scope에 포함된다.
- 인증/설정 전 생성된 scope, `legacy-unverified`, 접수 여부 미확정 구형 Client 요청은 현재 계정 소유라고 추정하지 않는다. 현 버전에는 이를 재귀속하거나 삭제하는 UI/API가 없고, 자동 보존에는 만료 기간을 두지 않는다. 복구 담당자가 원래 계정/서버와 신고 소유권을 별도로 확인하고 해당 서버의 접수·처리 기록 또는 그 계정의 수동 동기화 결과로 미완료 의무가 없음을 검증하기 전에는 폐기할 수 없다. 검증 후에도 원본/접수 근거를 보관하고 사용자가 명시 승인한 별도 복구 절차에서만 정리한다. 재설치·앱 데이터 초기화는 복구 경로가 아니다.
- 그룹 요약 `[A] → [A, B]`와 자식 알림의 다른 본문은 동일 패키지의 A 식별자를 바꾸지 않는다. 공식 알림에 신고별 답변 revision ID가 없으므로 2분 안의 같은 패키지·같은 신고 알림은 하나로 합친다. 서로 다른 답변이 이 짧은 구간에 연달아 오면 별도 이벤트로 구분하지 못하는 한계가 있다. 2분 뒤 새 알림은 다시 처리하며 영구 중복 억제는 하지 않는다.

설정·계정 stamp는 엔진 시작 때 고정하고 채널 호출과 POST 전후 및 Standalone 쓰기 소유권 검사에서 재확인한다. 성공한 인증 캐시의 게시도 네이티브 stamp 확인과 같은 main-thread 구간에서 한다. 다른 계정/서버의 큐는 자동 이관하지 않는다. 결과 알림의 `nav_tab`, `nav_subtab`, `nav_event_type`, `nav_payload_json`을 유지한다.

실기기 확인: 두 모드 각각 앱을 설정한 뒤 화면을 11분 이상 꺼둔 상태에서 실제 답변 알림을 수신한다. Client는 PC 현황/로그에서 접수→대기 큐 크롤링 시작을 확인하고, Standalone은 화면을 열기 전에 처리 결과 알림이 오는지 확인한다. 연결을 잠시 끊었다 복구했을 때 대기가 유지되고 같은 알림 재전송이 중복 크롤을 만들지 않는지도 본다. 별도 시험 에뮬레이터에서는 `adb shell dumpsys deviceidle force-idle` 후 확인하고 `adb shell dumpsys deviceidle unforce`로 복구한다. 개인 운영 앱의 강제 종료·데이터 삭제로 시험하지 않는다.

OS 기준: [Doze와 App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby), [백그라운드 FGS 시작 제한](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start). 강제 종료된 앱·제조사 절전·알림 접근 해제·OS quota에서는 즉시 실행을 보장하지 않는다. 사용자 수신 사례의 실제 기기 재현은 별도 검증이 필요하다.

---

## Android 15 / Play Console wider-screen 메모

- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - `WindowCompat.setDecorFitsSystemWindows(window, false)` 를 `super.onCreate()` 전에 호출해 edge-to-edge 인셋만 연다.
  - 그 이후에는 `WindowInsetsControllerCompat` 로 status/navigation icon appearance 만 조정한다.
  - Android 15+ 대응이라고 해서 `setStatusBarColor()`, `setNavigationBarColor()` 같은 직접 호출을 앱 코드에 다시 추가하지 않는다.
- `android/app/proguard-rules.pro`
  - release 에서는 `Window.setStatusBarColor()`, `setNavigationBarColor()`, `setNavigationBarDividerColor()` 호출을 R8 에서 제거한다.
  - Flutter embedding / 라이브러리 정적 참조 때문에 Play Console wider-screen 권장사항 2번이 재발하지 않도록 유지하는 규칙이다.
- `lib/main.dart`
  - 앱 시작 시 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)` 를 적용한다.
  - `AppBarTheme.systemOverlayStyle` 는 아이콘 밝기 위주로만 주고 `statusBarColor` 는 실어 보내지 않는 쪽을 유지한다.
- 2026-05-20 release AAB 재점검 결과:
  - 앱 리소스/테마 쪽 `windowLayoutInDisplayCutoutMode` 문자열은 남지 않았다.
  - `enableEdgeToEdge()` 제거 후 AndroidX `EdgeToEdgeApi23/26/29` 경로의
    `setStatusBarColor`, `setNavigationBarColor` 참조는 release `classes.dex` 에서 빠졌다.
  - release R8 규칙까지 적용한 뒤에는 `setStatusBarColor`, `setNavigationBarColor`,
    `setNavigationBarDividerColor`, `SHORT_EDGES` 가 raw dex 문자열과 `dexdump` 기준 모두 매치되지 않았다.
  - Flutter engine enum 문자열로 `SystemUiMode.immersiveSticky` 는 남을 수 있지만,
    현재 Play Console 이 지목한 deprecated API / cutout 파라미터 목록에는 포함되지 않는다.
- 해석:
  - 앱 코드에서 줄일 수 있는 Android 15 edge-to-edge / wider-screen 대응은 먼저 정리한다.
  - 그 뒤에도 Play Console 권장조치 2번이 남으면, 먼저 실제 업로드 AAB 기준으로
    `dexdump` / raw strings / manifest 를 재점검하고 나서 upstream 이슈를 본다.
  - 특히 `FlutterFragmentActivity` 와 Flutter platform overlay bridge 가 release 산출물에 어떤 심볼을 남기는지
    AAB/APK 빌드 후 `dexdump` 로 확인하는 편이 빠르다.

### 2. 알림 감지 → 동기화 (모드 분기)

```
Kotlin NotificationService.onNotificationPosted(sbn)
  └─ if package = kr.go.safepeople | com.kakao.talk → SPP 신고번호 추출
       └─ sendEnqueue(reportNumber)
            ├─ Client  → POST /api/v1/crawl/enqueue + "📡 개별 크롤링 지시 중" 알림
            │           (서버가 처리 후 WS crawl_changes → WsService.showCrawlChangesNotif)
            └─ Standalone → handleStandaloneDetection
                              ├─ appendPendingReport (CSV 형식 큐)
                              └─ "📬 신규 신고 감지" heads-up 알림 (탭 시 nav_tab=6)
```

감지 알림 탭 → MainActivity.onNewIntent → handleNavIntent → 요청을 `pendingNav` 에 보관 → MethodChannel `navigateToTab` →  
Flutter `NativeCallRouter`(앱 루트, `main()` 에서 시작) → 메인 화면(`MainNavigationScreen.handleNativeNavigation`)이 붙어 있으면 전달, 없으면 최신 요청 하나를 보관했다가 붙을 때 한 번 전달 → 동기화 탭 이동 + (Standalone) `checkAutoSyncOnResume()` → `_drainAndRefresh()`.
- 2026-10-04(SQ-B05): Dart 가 루트 처리기를 건 뒤 `dartReady` 를 보내면 Kotlin 이 보관한 요청을 보낸다. 예전 500ms 지연 전송은 예비로 남았고, Dart 처리기가 없으면(`notImplemented`) 요청을 지우지 않는다. Dart 가 받았을 때(success/error)만 지운다.
- `syncFgsStopped` 는 화면과 무관하게 `NativeCallRouter` → `SyncEngine.onNativeFgsStopped` 로 간다(초기 재구성 중에도 전달).
단, `standaloneDemoMode=true` 이면 resume 시 refreshAll 만 수행하고 실제 drain/sync 는 생략.

### 3. Standalone drainIfPending (`StandaloneAutoSyncService`)

큐 영속성 보장을 위해 **항목당 처리 → 결정 후 제거** 방식:

```
while (queue not empty):
  spp = queue.first
  ok = _tryFetchSingle(spp)            ── DB 조회 + 상세 API + upsert
  if !ok and !didIncremental:
    didIncremental = true (drain 당 1회만)
    SyncEngine.start(fullSync: false)  ── 증분 sync fallback
    ok = _tryFetchSingle(spp)          ── 증분 후 재시도
  _removeFromQueue(spp)                ── 성공/포기 무관 제거 (3회 retry 안 함)

→ FGS acquireFgs("개별 동기화 진행 중") wrapped (ref counting)
→ 종료 시 emitChanges(_singleFetchChanges) + emitDone
```

**앱 죽임 → 다음 launch 자동 재시도 보장**: 처리 도중 앱이 죽으면 항목이 큐에 남아 있어 다음 init drain 이 처리.  
**과거 버그**: drain 진입 즉시 큐를 비웠던 옛 코드는 처리 도중 죽으면 항목 영구 손실 → 현재 per-item 제거로 해결.

### 4. 변경사항 emit (SyncEngine)

```
SyncEngine.emitChanges(List<Map>)
  ├─ 대기 변경 수신함 `inbox.pending.*` 에 새 키로 추가 (main.dart 가 카드 시트로 표시)
  ├─ 20건 이하: 각 신고에 대해 MethodChannel showNotification (heads-up):
  │    ├─ ChangeType.newReport         → "🆕 신규 신고"
  │    ├─ ChangeType.statusChanged     → "🔄 처리 변경"
  │    └─ ChangeType.individualConfirm → "✅ 개별 동기화"
  ├─ 21건 이상: "n건의 변경사항이 있습니다" 알림 한 건 (개별 payload 없음)
  └─ changesEmittedController.add(null) → ReportProvider nonce++ → main.dart 트리거
```

`ChangeType` (sync_engine.dart) 가 모든 식별자의 single source of truth.  
`reportToChangeMap(report, changeType)` 가 표준 Map 형식 생성.
Client `WsService.showCrawlChangesNotif` 도 같은 20건 경계로 알림을 묶는다. 상세 변경은 대기 변경 수신함에 보존하고,
Android 알림 기록 수신함에는 기존 표시 한도인 최대 200건만 넣는다.

### 5. 커뮤니티 계정 로그인 복귀 딥링크 (2026-09-25)

```
Supabase Auth → com.fentanest.mysafetyreport://auth/callback?code=…   (MainActivity intent-filter VIEW/DEFAULT/BROWSABLE, path 정확히 일치)
  └─ MainActivity.captureCommunityAuthLink (onCreate·onNewIntent 에서 super 전에)
       ├ scheme/host/path/userInfo/port 정확히 일치할 때만, 프로세스 복원·최근 앱 재실행 intent 는 무시
       ├ companion 보관함(한 칸)에 넣고 intent.data = null
       └ Dart 준비됨이면 MethodChannel community_auth "onCommunityAuthLink"(신호만)
Dart CommunityAuthLinkChannel (main() 에서 등록) → "takePendingLink"(꺼내며 비움) → CommunityAuthService.handleCallbackLink
```

- 같은 activity 에 `flutter_deeplinking_enabled=false`: Flutter 기본 딥링크(기본값 true)가 intent data 를 Navigator 라우트로 보내지 않게.
- 기존 `handleNavIntent`(알림·바로가기 extras)는 그대로. `<queries>` 의 `appsafetyreport` 는 공식 앱 실행용 outbound 로, 이 수신 필터와 무관.
- 상세·보안 메모: [community-account.md](community-account.md).

## SharedPreferences 키 (Kotlin ↔ Flutter 공유)

저장소: `FlutterSharedPreferences` (Android XML)

| 키 | 타입 | 용도 |
|----|------|------|
| `flutter.appMode` | String | "server" / "standalone" |
| `flutter.baseUrl` / `flutter.apiKey` | String | Client 모드 서버 |
| `flutter.standaloneUsername` | String | Standalone ID |
| `flutter.standalonePhoneNumber` | String | Standalone 휴대폰번호 (또는 demo) |
| `flutter.standaloneDemoMode` | bool | Play review 데모 모드 여부 |
| `flutter.standaloneToken` / `flutter.standaloneTokenExpiresAt` | String / int | OAuth 토큰 |
| `flutter.standaloneTokenUsername` | String | 토큰을 받은 안전신문고 아이디. `standaloneUsername` 과 다르거나 없으면 토큰 무효(계정 변경 뒤 이전 계정 토큰 사용 방지). 백그라운드 재로그인은 저장 직전 디스크의 아이디를 다시 확인(2026-10-04 서버 기술일지 A2-01) |
| `flutter.inbox.queue.<ms>_<순번>` | String (신고번호 하나) | Standalone 감지 큐. Kotlin·Dart 모두 새 키에만 쓰고 `StandalonePendingQueueStore` 가 읽을 때 중복 제거, 처리한 값의 키만 지움 (G11-5) |
| `flutter.standalone_pending_reports` | **String (CSV)** | (G11-5 이전 큐) 남은 값만 읽고 지움 (아래 함정 주의) |
| `flutter.standalone_last_detected_at` | long | 디버그용 |
| `flutter.foreground_event` | String | WsService → 포그라운드 복귀 SnackBar |
| `flutter.inbox.pending.<ms>_<순번>` | String (JSON 배열) | 카드 시트 표시 대기. Kotlin·Dart 모두 **새 키에만** 쓰고 `PendingChangesStore.readAndClear` 가 합친 키만 지움 |
| `flutter.inbox.history.<ms>_<순번>` | String (JSON 배열) | Kotlin 이 넣는 새 알림. `NotificationHistoryProvider` 가 기록에 합치고 그 키만 지움. Kotlin 쪽 최대 200키 |
| `flutter.notifications_history` | String (JSON) | 알림 히스토리 (최대 200개). **Dart 만 씀** |
| `flutter.pending_crawl_changes` | String (JSON) | (R6 이전 값) 남아 있으면 한 번 읽고 지움 |
| `flutter.auto_enqueue_count` / `flutter.auto_enqueue_last_at` | int / long | Client 자동 enqueue 푸시 억제 |
| `flutter.standalone_auth_last_at` / `_outcome` / `_message` | long / String / String | 마지막 자동·수동 로그인 결과 (2026-09-24) |
| `flutter.standalone_auth_alert` | String | 백그라운드 로그인 점검 → Kotlin 알림 트리거 (`<epoch ms>|메시지`) |
| `flutter.review_*` | int / String | 스토어 별점 요청 조건(설치 시각·사용한 날·요청 횟수·마지막 요청) |

### FlutterSecureStorage 키 (Dart 만, Kotlin 은 읽지 않음)

`encryptedSharedPreferences: true`(Android Keystore). SharedPreferences 표와 별개 저장소이며 `allowBackup="false"`.

| 키 | 용도 |
|----|------|
| `standalone_password` | 안전신문고 재로그인용 비밀번호 |
| `community_session_v1` | Standalone 커뮤니티 계정 세션(Supabase access/refresh token·만료·표시 이름) — [community-account.md](community-account.md) |
| `community_pending_login_v1` | 브라우저로 보낸 커뮤니티 로그인(PKCE verifier·시작 시각) |
| `community_consumed_callback_v1` | 마지막으로 소비한 복귀 링크의 SHA-256(중복 교환 방지) |

### 같은 키를 두 쪽이 쓰지 않는다 (R6, M-29/M-31)
앱과 WsService 는 같은 프로세스의 같은 SharedPreferences 를 쓴다. 한 키를 둘 다 읽고-고쳐-쓰면 거의 동시에 쓸 때 한쪽이 사라진다.
그래서 서비스 → 앱 전달은 수신함(`lib/services/prefs_inbox.dart`, `WsService.putInbox`)으로: 넣는 쪽은 매번 고유한 새 키, 합치기·지우기는 앱이 하고 합친 키만 이름으로 지운다.
키 접두어는 두 파일에서 같아야 한다.

### ⚠️ Flutter SharedPreferences 큐 형식 함정

**문제**: 초기 Kotlin 코드는 큐를 `LIST_PREFIX (VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu) + JSON 배열` 로 저장했는데, Flutter 의 `LegacySharedPreferencesPlugin` 은 `LIST_PREFIX` 가 붙은 값을 Java `ObjectInputStream` 으로 디코딩 시도 → JSON 데이터에서 `StreamCorruptedException` → `getAll()` 전체 실패 → **모든 prefs 읽기 실패 → 로그인 풀림**.

**해결**:
- Kotlin `appendPendingReport`: 큐를 **CSV 문자열** (LIST_PREFIX 없음) 로 저장 → Flutter 가 일반 String 으로 읽음, deserialize 시도 안 함.
- `MainActivity.cleanupCorruptedPrefs()`: super.onCreate 전에 v1 (LIST_PREFIX+JSON) 데이터를 CSV 로 마이그레이션 (Kotlin 에서는 JSON 파싱 가능).
- Flutter `StandaloneAutoSyncService.readPendingQueue()` / `_writeQueue()`: CSV split/join.

## Foreground Service 정책

### `WsService` (Client 모드)
- 게이트 캐시가 `ok`이고 `/api/v1/server/version`이 v3 이상으로 확인된 뒤에만 WebSocket을 연다. 재연결 때도 다시 확인한다. `MainActivity` 자동 시작과 `NotificationService` 신고번호 전송에도 같은 게이트·버전 검사를 적용한다.
- WebSocket URL 은 `ServerContract.wsEventsUrl(baseUrl, apiKey)` 로 생성
- 지수 백오프 재연결 (3→6→12→24→60초)
- START_STICKY (OS 가 죽여도 자동 재시작)
- `connected`, `ping`, `crawl_started`, `crawl_finished`, `crawl_changes` 이벤트는 `ServerContract` 상수 기준으로 처리
- crawl_started/finished/changes 이벤트 수신 → push 알림
- `crawl_changes` 의 일반 신고 payload는 서버가 `notification_kind=report`, `synced_at`,
  `category` 를 포함해 준다는 계약을 전제로 한다.
  WsService / pending changes / 알림 히스토리 / 상세 시트는 이 값을 그대로 유지해야 한다.

### `SyncForegroundService` (Standalone 모드)
- `SyncEngine.start()` 또는 `drainIfPending()` 실행 동안 가동
- `SyncEngine.acquireFgs / releaseFgs` 가 ref counting (drain → SyncEngine.start 중첩 안전)
- "🔄 동기화 진행 중" 알림 (LOW priority)
- START_NOT_STICKY (작업 끝나면 정지)
- FGS는 프로세스 우선순위를 높이지만 FlutterEngine 생존·작업 완료를 보장하지 않는다. Activity 소유 엔진 파괴 시 작업 중단과 서비스 종료를 요청한다.
- 신고 내역 다시 불러오기(Standalone 1회 초기화, 2026-10-11 백그라운드 진행)의 수집 단계도 같은 FGS 를 쓴다
  (`SyncEngine.start(rebuildRunId:)`, 시작 문구 "신고 내역 다시 불러오기 진행 중..."). `StandaloneRebuildRunner` 가
  MethodChannel `updateSyncFgs`(owner·title·message·current·total)로 **이미 떠 있는** FGS 알림의 제목·문구·진행률만 바꾼다 —
  owner 가 다르거나 서비스가 없으면 아무것도 하지 않고, 서비스를 새로 시작하지 않는다(백그라운드 FGS 시작 제한과 무관).
  끝났을 때(완료·일부 누락·누락 확인 필요·중단)는 기존 `showNotification`(`app_push_v2`, 탭 → 대시보드)으로 한 번 알린다.
  사용자 일시정지는 알리지 않는다.
- `SyncEngine.runningListenable`은 전체 동기화와 개별 자동 동기화의 FGS 참조 수를 함께 반영한다. `SyncExitGuard`가 실행 화면과 앱 루트의 Android 뒤로 가기를 막아 Activity 종료를 방지한다. 작업이 끝나면 뒤로 가기가 다시 동작한다.

### 알림 채널

| 채널 ID | 중요도 | 용도 |
|---------|--------|------|
| `ws_service` | LOW | WsService 지속 알림 |
| `ws_push_v2` | HIGH | crawl_started/finished/changes heads-up |
| `enqueue_progress` | LOW | "📡 개별 크롤링 지시 중" 임시 |
| `standalone_detected_v2` | HIGH | "📬 신규 신고 감지" heads-up (탭 시 sync 트리거) |
| `sync_fgs` | LOW | "🔄 동기화 진행 중" Standalone FGS |
| `app_push_v2` | HIGH | Standalone 변경 알림 (Flutter → MethodChannel showNotification), 하루 1회 로그인 점검의 "🔐 재로그인 필요" 알림(id 7301) |

### 앱 아이콘 / 알림 아이콘 (2026-09-24)
- 앱 아이콘은 서버와 같은 카메라 아이콘. 원본 `assets/branding/app_icon.png`, Android 8+ 는 적응형 아이콘
  (`mipmap-anydpi-v26/ic_launcher.xml`, 전경 `drawable-*/ic_launcher_foreground.png`, 배경 `@color/ic_launcher_background` #0035B9).
  모두 `flutter_launcher_icons.yaml` 로 생성하므로 손으로 고치지 말고 원본을 바꾼 뒤 `dart run flutter_launcher_icons`.
- 코드 대조 정정: 알림 표시줄 `R.drawable.ic_stat_logo`는 사용자 원본 PNG(`drawable/ic_stat_logo.png`, `7aedf8d498a39291510543a96be5d802131389ab`의 파일)다. 같은 이름의 카메라 XML은 제거한다. 런처 아이콘은 카메라를 유지한다.

### `SafetyReportApplication` (2026-09-24)
- 매니페스트 `android:name` 을 Flutter 기본(`${applicationName}`)에서 `.SafetyReportApplication` 으로 바꿨다.
- WorkManager 백그라운드 Flutter 엔진(`workmanager` 플러그인)에는 MainActivity 의 MethodChannel 이 없어 Dart 가 직접 알림을 못 띄운다.
  그래서 Dart `BackgroundLoginCheck` 가 `flutter.standalone_auth_alert`(`<epoch ms>|메시지`) 를 쓰면,
  같은 프로세스의 `OnSharedPreferenceChangeListener`(Application.onCreate 에서 등록, 필드로 강한 참조 유지)가 알림을 띄운다.
- 에뮬레이터 확인(2026-09-24): 키 쓰기 → 알림 표시, 일회성 작업 강제 실행 → 백그라운드 엔진에서 Dart 작업 실행·`SUCCESS`(데모라 로그인은 건너뜀).
  주기 작업은 WorkManager 가 예정 시각 전 강제 실행을 막으므로 `cmd jobscheduler run` 으로는 확인되지 않는다.

## 자동 enqueue 알림 억제 로직 (Client 전용)

카카오톡 등 외부 알림 → `NotificationService.sendEnqueue()` 자동 트리거 시,
WsService 가 `crawl_started / crawl_finished` push 알림을 쌓는 게 지저분 → 억제.

1. `sendEnqueue` 호출 → `auto_enqueue_count++` + 타임스탬프 기록 + "📡 개별 크롤링 지시 중" ongoing 알림 표시
2. POST 완료/실패 시 finally 에서 ongoing 알림 소거
3. `WsService.showCrawlStartedNotif` / `showCrawlFinishedNotif`: `isAutoEnqueueActive()` true 면 return
4. `crawl_changes` (실제 결과) 는 억제 안 함 — 20건 이하면 auto_enqueue 활성 세션에 "🆕 개별 신규" / "🔄 개별 처리 변경" prefix 부착,
   21건 이상이면 신고별 푸시 대신 총건수 알림 한 건.
5. `auto_enqueue_count > 0` 이어도 `auto_enqueue_last_at` 10분 초과 시 만료 (서버 미응답 대비)

## ChangeType 상수 (sync_engine.dart)

모든 변경 종류 식별자의 single source of truth — magic string 금지.

```dart
class ChangeType {
  static const newReport = '신규';            // DB 에 없던 ID
  static const statusChanged = '처리변경';     // 처리상태 변동
  static const individualConfirm = '개별확인'; // 알림 탭 단건 fetch + 변동 없음
}
```

사용처: `sync_engine.dart`, `standalone_auto_sync_service.dart`, `main.dart` (카드 시트), `notification_history_provider.dart` (히스토리 아이콘).

## 버전 관리

**단일 소스: `VERSION` 파일** (예: `1.0.6+8`)

- `build-apk.yml` CI: `sed` 로 `pubspec.yaml` 의 `version:` 줄 자동 교체
- Flutter 빌드: `--build-name` / `--build-number` 플래그
- 런타임 표시: `package_info_plus` (settings_screen.dart)

### Android 빌드 도구 (2026-09-27)
- **Flutter 3.47.5 고정**(`tool/flutter-version`). 빌드 스크립트 `resolve_pinned_flutter` 가 `FLUTTER_BIN`(기본 `flutter`) 또는
  `~/development/flutter-<버전>/bin/flutter` 중 고정 버전을 찾고, 없으면 실패한다(전역 SDK 는 바꾸지 않는다). CI 는 저장소 변수 `FLUTTER_BIN` 으로 지정 가능.
- **AGP 9.1.0 · Gradle 9.3.1 · KGP 2.4.0 · JDK 17+**(Flutter 3.47.5 앱 템플릿 조합, Flutter 3.47 지원 상한 AGP 9.2). 앱은 kotlin-android 를
  적용하지 않고 `kotlin { compilerOptions { jvmTarget = JVM_17 } }` 를 쓴다.
- `android/gradle.properties` 의 `android.newDsl=false`·`android.builtInKotlin=false` 는 Flutter 공식 임시 opt-out 이다. 근거·제거 조건은 그 파일 주석
  (KGP 를 적용하는 플러그인 7개, 최신판도 4개가 아직 적용). AGP 10 에서 opt-out 이 없어진다.
- `android/build.gradle.kts` 는 file_picker 11.0.2 에만 kotlin-android 를 붙인다(그 플러그인은 AGP 9 이면 built-in Kotlin 을 가정해 KGP 를 빼는데,
  이 앱은 builtInKotlin=false 라 그대로면 `FilePickerPlugin` 이 컴파일되지 않는다). builtInKotlin=true 로 바꾸거나 file_picker 를 올리면 지운다.
- AGP 9 는 필요한 Build-Tools 36 을 SDK 에 자동 설치한다(2026-09-27 이 기계에 설치됨 — 기존 패키지는 바꾸지 않음).

### R8·리소스 축소·서명
- release: `isMinifyEnabled = true`, `isShrinkResources = true` 명시(Flutter Gradle Plugin 기본값과 같음, AGP 9 optimized resource shrinking).
  끄거나 전체 keep·광범위 dontwarn 으로 우회하지 않는다. keep 규칙은 `proguard-rules.pro` 의 `-assumenosideeffects Window.set*Color` 하나뿐(위 절).
- 서명: `android/key.properties` 가 없으면 release 패키징(`packageRelease`·`signReleaseBundle`)이 실패한다 — debug 키로 조용히 대체하지 않는다.
  검증 전용 빌드만 `ALLOW_DEBUG_SIGNED_RELEASE=1`(산출물 이름 `-DEBUG-SIGNED`, 메타 `signing=debug` — 배포·업로드에 쓰지 않는다).

### 이미지 디코딩·Play `H2.h.b` / `je0.d`

- 신고 상세 사진은 기존 `ResizeImage`·`photoDecodeSize` 제한을 유지한다.
- 2.1.3 AAB의 `je0.d`는 file_picker 11.0.2 `FileUtils.compressImage`의 옵션 없는 `BitmapFactory.decodeStream`이다.
- BL-1 구현은 file_picker 13.1.0(Android 구현 android_file_picker 2.0.1)을 쓴다. 업스트림 코드는
  `inJustDecodeBounds`로 크기를 조사한 뒤 `inSampleSize`를 설정해 다시 연 스트림을 디코딩한다.
  앱의 파일 선택은 압축 기본값 0을 유지한다. `pickFiles`는 이제 `List<PlatformFile>`과 취소 시 빈 목록을 반환하며,
  DB·WAL·SHM 다중 선택을 유지한다. 공유는 `SharePlus.instance.share(ShareParams(...))`를 쓴다.
- 앱 Kotlin 및 현재 Android Flutter 플러그인 소스에서 다른 `BitmapFactory.decode*` 호출은 발견하지 않았다.
  release DEX에는 전이 의존성 Media3의 옵션 없는 `decodeByteArray([BII)` 두 곳이 남는다:
  `Cue.fromBundle`(R8 `rb.apply`)와 `TtmlNode.getCues`/`TtmlSubtitle.getCues`(R8 `i30.p`).
  앱 자체 코드가 아니므로 이 작업에서 영상 의존성을 추가 업그레이드하거나 바이트코드를 수정하지 않았다.
- 로컬 debug 서명 release의 `FileUtils.compressImage`는 R8 `f90.h`에 인라인된다.
  DEX의 `decodeStream(InputStream)` 호출은 0개, `decodeStream(InputStream, Rect, Options)`는 2개다.
  변경 전 같은 SDK/ABI 빌드에는 `je0.d`의 옵션 없는 호출이 있었다.
- 로컬 mapping/DEX 검사는 Play Console 경고 해소의 증거가 아니다. 업로드 후 Console에서 따로 확인해야 한다.

### Android SQLite 번들 (BL-1)

- Android의 Dart DB 연결은 `BundledSqlite.initialize()`로 `sqflite_common_ffi 2.4.3`로 바꾼다.
  `sqflite 2.4.4+1`의 API와 기존 파일을 유지하며, **교체 전에** Android plugin의 `getDatabasesPath()`를 읽어
  FFI factory에 지정한다. FFI 기본 경로로 이동하거나 새 빈 DB를 만들지 않는다.
- 포그라운드 `main`과 WorkManager `backgroundTaskDispatcher` 각각 첫 DB 접근 전에 초기화한다.
  `resetLegacyDatabase`, 개인 DB·community.db, 스냅샷·가져오기·백업/복원은 같은 isolate의 global factory를 사용한다.
  SQL 실행은 FFI worker isolate에서 수행하며, WorkManager 엔진도 별도 FFI worker/연결로 같은 파일을 연다.
- 엔진은 `sqlite3 3.7.0` native-assets hook과 공식 SQLite **3.53.4** amalgamation이다.
  `third_party/sqlite/README.md`에 출처·SHA3-256·public-domain 근거를 둔다. 원문은 변경하지 않는다.
  hook 진입 소스는 `sqlite3_flutter.c`이며, 원문을 include하는 작은 POSIX sleep 래퍼다.
  SQLite `unixSleep`의 `nanosleep`이 Dart 프로파일러 `SIGPROF`로 중단되면 남은 시간을 이어서 잔다.
  원문의 sleep은 EINTR을 무시하여 debug/profile에서 5초 busy_timeout이 수십 ms 만에 소진될 수 있다.
  Windows의 sleep은 바꾸지 않으며, SQLite 원문·FTS 옵션·DB 파일 형식은 그대로다.
  `sqlite3_flutter_libs >=0.6.0`은 더 이상 라이브러리를 제공하지 않으므로 채택하지 않는다.
- sqlite3의 기본 precompiled binary는 FTS5만 제공한다. 기존 Android FTS3/4 가상 표가 열리지 않는 것을 테스트로 확인하여
  소스 빌드에 `SQLITE_ENABLE_FTS3`와 `SQLITE_ENABLE_FTS3_PARENTHESIS`를 추가했다(FTS4도 활성화).
  기본 FTS5 옵션은 유지한다. 별도 DB 암호화나 스키마·파일 형식 변환은 도입하지 않는다.
- 앱 Dart SQL의 최소 엔진은 Android 번들 **3.53.4**로 고정한다. 새 SQL은 이 엔진으로 검사하며,
  서버와 교환하는 DB의 스키마·값 계약은 `data-contracts.md`를 계속 따른다.
  Kotlin `ProcessingInboxStore`의 **별도** `processing_inbox.db`는 Android SQLite를 계속 쓴다.
  Kotlin은 Dart의 개인 DB·community.db를 직접 열지 않는다. 이 네이티브 inbox의 SQL은 기존 3.9 호환 구문을 유지한다.
- 잠금 대기 래퍼 반영 전 측정한 동일 SDK·세 ABI·debug 서명 release APK는 75,525,411 → 81,450,707바이트,
  +5,925,296바이트(+5.65 MiB, +7.85%)다. SQLite .so 세 개의 합은 5,763,560바이트이며 APK에 비압축 저장된다.
  이 차이는 모든 패키지 업그레이드와 번들의 **합계**이고 엔진만 바꾼 A/B 측정은 아니다.
  arm64-v8a·armeabi-v7a·x86_64 모두 SQLite 3.53.4, FTS3/FTS5 및 ELF LOAD 0x4000 정렬을 산출물에서 확인했다.
- 선택 근거: [sqflite_common_ffi](https://pub.dev/packages/sqflite_common_ffi),
  [sqlite3 hook 설정](https://pub.dev/documentation/sqlite3/latest/topics/hook-topic.html),
  [폐기된 sqlite3_flutter_libs](https://pub.dev/packages/sqlite3_flutter_libs),
  [SQLite 3.53.4/소스 해시](https://sqlite.org/releaselog/3_53_4.html).
- 패키지 변경과 엔진 교체는 별도 커밋으로 검토할 수 있다. 엔진 변경 묶음은 `bundled_sqlite.dart`, main/WorkManager 초기화,
  pubspec의 sqflite/FFI/sqlite3·hook 설정, `third_party/sqlite/`, SQLite 검증 파일이다.
  기존 FTS와 별도 엔진 간 잠금·백업 무결성이 걸려 있어 단순 패키지 버전 변경보다 위험이 높다.

### 로컬 테스트 빌드 (`build_test_apk.sh`)
고정 Flutter 로컬 CLI.

```bash
./build_test_apk.sh           # debug
./build_test_apk.sh --release # release (~/mysafetyreport-android/ 키스토어 필요)
```

### 로컬 정식 Android 릴리즈 빌드 (`build_android_release.sh`)
`build-apk.yml` 과 같은 순서:
- 고정 Flutter 확인, `VERSION` 읽기, `pubspec.yaml version:` 동기화, 서명키 임시 배치
- `flutter build apk --release` → **곧바로** APK 와 그 빌드의 R8 출력(mapping·configuration·usage·seeds·resources)을 `dist/<버전>-<커밋>/apk/` 에 보존
- `flutter build appbundle --release` → 같은 방식으로 `dist/…/aab/` (AAB 빌드가 `build/…/mapping` 을 덮어쓰기 전에 APK 것을 따로 둔다)
- 산출물별 서명 인증서(공개 지문 — 배포용인데 Android Debug 인증서면 실패)·SHA256SUMS, `dist/…/build-meta.json`(버전·커밋·작업트리 변경 여부·서명 종류·
  Flutter/Dart/AGP/KGP/Gradle/JDK·파일 해시·pg_map_id)
- 산출물 복사: `build/app/outputs/flutter-apk/mysafetyreport.apk`, `build/app/outputs/bundle/release/mysafetyreport.aab`

```bash
./build_android_release.sh                                # 배포용(서명키 필요, APK+AAB 둘 다)
ALLOW_DEBUG_SIGNED_RELEASE=1 ./build_android_release.sh   # 검증 전용(debug 서명, 배포 불가)
SKIP_APK_BUILD=1 ./build_android_release.sh               # AAB 만(build-apk.yml alpha 경로와 동일)
ANDROID_VERSION_CODE=171 ./build_android_release.sh       # versionCode 를 VERSION 파일의 +N 대신 이 값으로
ANDROID_VERSION_NAME=2.3.0 ./build_android_release.sh     # versionName 을 VERSION 파일의 이름 대신 이 값으로(production.yml 이 씀)
```

### CI `build-apk.yml` — alpha 전용 수동 실행 (2026-10-13 재개정: push 트리거 제거)

`push(main)` 트리거는 없앴다 — main 에 push 해도 이 워크플로는 아무것도 하지 않는다. `workflow_dispatch` 로만
실행하며, 입력 `action`(alpha/release 선택)도 없앴다 — 항상 alpha 다. 순서: `verify` → `next-version-code`(Play
최대 versionCode+1) → `build-aab`(AAB만, `SKIP_APK_BUILD=1`, APK 빌드 없음, artifact 1일) →
`play-upload`(Google Play 비공개 테스트 alpha 트랙). 태그·GitHub Release·Play production 업로드는 이 파일에서
하지 않는다(아래 `production.yml`).

- versionCode(빌드 번호)는 VERSION 파일의 `+N` 이 아니라 **Play 에 이미 올라간 최대 versionCode + 1**(`next-version-code`
  job 이 Play Developer API 로 번들·APK 전체를 조회)로 계산해 `ANDROID_VERSION_CODE` 로 `build_android_release.sh` 에
  전달한다(GitHub run_number 에 기대지 않으므로 워크플로 이름 변경·재생성에도 번호가 내려가지 않는다. 연속 실행은
  `concurrency` 로 직렬화 — `production.yml` 과 같은 group 을 써서 두 워크플로도 서로 직렬화된다). **VERSION 파일의
  `+N` 은 이 경로에서 더 이상 실제 빌드 번호로 쓰이지 않는다**(파일 형식은 유지하므로 다른 파싱 스크립트는 그대로
  동작한다).
- `play-upload`는 같은 태그 존재로 건너뛰지 않는다 — 매 실행이 Play 최대+1 을 쓰므로 항상 새 versionCode다.
  Play "새로운 기능" 문구는 실행 때 입력한 `whatsnew` → `docs/releases/unreleased.md`(비었으면 건너뜀) →
  (`WHATSNEW_ALLOW_MISSING=1`) `scripts/generate_whatsnew.mjs` 가 실패하지 않고 "테스트 빌드 <이름> (<versionCode>) ·
  <커밋>" 으로 대체하는 순서로 정해진다. 버전별 노트(`v<이름>.md`)는 alpha 에 쓰지 않는다.
- 이전(2026-10-13 이전 개정)의 `action=release`(`create-release` job — 태그+릴리스 노트+소스 zip)는
  `production.yml` 로 옮겼다. 그보다 더 이전의 입력 `verify_only`도 이미 정리된 상태였다.

### CI `production.yml` — 정식 릴리즈 (2026-10-13 신설)

`workflow_dispatch`(입력 `version`, SemVer `x.y.z`), `github.ref == 'refs/heads/main'` 인 job 만 돈다.
`build-apk.yml` 과 같은 concurrency group 을 써서 alpha 실행과 직렬화한다. group 은 2026-10-16 부터 브랜치와 무관한 고정값
`mobile-play-version-code` 다(예전 `mobile-build-${{ github.ref }}` 는 다른 브랜치의 alpha 와 main 정식 릴리스가 같은
'Play 최대 versionCode + 1' 을 동시에 읽을 수 있었다). GitHub concurrency 는 group 당 실행 1 + 대기 1 이라 대기 중 새 실행이
들어오면 앞 대기 실행은 취소된다 — 다시 실행한다.
앞 단계가 실패하면 뒤 단계는 건너뛴다:

1. **prepare**: `version` 형식(`^[0-9]+\.[0-9]+\.[0-9]+$`) 검사, 태그 `v<version>` 중복 검사(있으면 실패),
   `docs/releases/unreleased.md` 가 HTML 주석을 빼고 비어 있으면 실패("미출시 노트가 비어 있습니다"), 직전
   릴리스 태그(가장 큰 semver `v*`, `sort -V`)를 구해 Full Changelog 비교 링크에 쓴다. unreleased.md 본문은
   base64 로 job output 에 실어 `finalize` 로 넘긴다.
2. **next-version-code**(environment: play): `build-apk.yml` 과 같은 로직(Play 최대 versionCode+1) — 의도적
   중복이며 재사용 워크플로로 묶지 않았다(두 파일을 독립적으로 검증할 수 있게).
3. **verify**: `./.github/workflows/verify.yml` 재사용.
4. **build-aab**(self-hosted): AAB만 빌드(`SKIP_APK_BUILD=1`). versionName 은 VERSION 파일이 아니라 입력
   `version`을 `ANDROID_VERSION_NAME` 으로, versionCode 는 2단계 값을 `ANDROID_VERSION_CODE` 로 전달한다 —
   VERSION 파일은 아직 건드리지 않는다(6단계가 마지막에 갱신). artifact(AAB·mapping) 보관 1일.
5. **play-production**(environment: play): Google Play **production** 트랙에 업로드(alpha 가 아니다).
   "새로운 기능"은 `docs/releases/unreleased.md` 본문을 `scripts/generate_whatsnew.mjs`(`WHATSNEW_UNRELEASED=1`,
   `WHATSNEW_ALLOW_MISSING` 미설정 — 비어 있으면 그대로 실패)로 변환한다. 스토어 안내 줄·Full Changelog 는
   unreleased.md 에 없으므로 Play 노트에 섞이지 않는다. 500자 초과 시 기존 규칙(문장 단위로 자름, 말줄임표
   없음)을 그대로 따른다.
6. **finalize**(permissions: contents: write): 실행 커밋(`github.sha`) 위에 커밋 하나를 만들어 main 에 push한다 —
   `docs/releases/v<version>.md`(1단계 직전 태그로 Full Changelog 링크를 채운 최종 노트: 제목+빌드 번호 → unreleased
   본문 → 스토어 안내 → Full Changelog), `docs/releases/unreleased.md`(안내 주석 한 줄만 남기고 비움),
   `VERSION`(`<version>+<versionCode>`). 커밋 메시지 `chore(release): <version>+<code> — 프로덕션 출시 노트 확정`.
   push 가 fast-forward 가 아니면 실패하고 안내만 하고 끝낸다(태그·Release 는 만들지 않는다). dev 가 같은 커밋으로
   fast-forward 가능하면 push, 아니면 경고만 하고 계속한다(실패시키지 않음). 그 다음 태그 `v<version>` 을
   **빌드한 커밋(`github.sha`, finalize 커밋이 아니다)**에 만들고, `softprops/action-gh-release`로 GitHub Release
   를 만든다(`body_path`=최종 노트, `generate_release_notes: false`, `prerelease: false`, `files:` 미지정 —
   소스 zip/tar.gz 만 붙는다. APK/AAB 는 Play 로만 배포한다).

빌드 전 검증은 `build-dev-apk.yml`(dev, 수동) 또는 `build-apk.yml`/`production.yml` 의 `verify` job 으로 한다.

CI `build-dev-apk.yml`(2026-09-27): `dev` push(문서만 바뀐 push 제외)·수동 실행 때 같은 셀프호스트 러너에서 `build_test_apk.sh --release` 로
릴리즈 모드 APK 를 만들어 artifact `mysafetyreport-dev-<VERSION>-<sha8>`(APK·mapping·SHA-256, 30일)로만 올린다. 서명은 러너의 업로드 키
(GitHub Release APK 와 같은 서명이라 그 위에 덮어 설치된다), 태그·Release·AAB 없음 — 시험용이며 배포에 쓰지 않는다.

기본 키 경로:
- `~/mysafetyreport-android/key.properties`
- `~/mysafetyreport-android/upload-keystore.jks`


### 코드 대조 정정: Client 인증 확인 만료와 WebSocket 알림

(2026-10-17 다시 정정 — 아래 첫 문단은 4e4e41eb 이전 동작이었다.) 인증·동의 캐시(`community_gate_cache_v1`)는 10분(`ClientGateGuard.VALID_MS`) 동안만 열려 있고,
화면의 게이트는 앱이 앞에 있을 때만 5분마다 다시 확인한다. 그래서 앱을 백그라운드에 두면 10분 뒤 캐시가 만료되고, 연결된 WebSocket 은 다음 서버 메시지(30초 ping)에서
스스로 끊긴다(`onMessage` 의 `current()`). 만료는 철회가 아니므로(`canRenew`: state ok + owner) 서비스는 멈추지 않고 화면 없는 갱신(`NotificationWork` → `refreshGateHeadless(clientMode: true)`)을 기다렸다 다시 연결한다.
철회(state ≠ ok)·owner 없음이면 서비스를 종료하고 지속 알림을 지운다.

2026-10-17 사용자 제보("서버 연결 중 #0 #1 #2" 뒤 "인증 확인 후 서버에 다시 연결합니다", 서버는 항상 켜져 있음)로 고친 것:
- **만료 전 갱신**: 연결 중(그리고 연결 직전) 30초마다 캐시 나이를 보고 7분(`RENEW_AFTER_MS`)을 넘으면 갱신을 요청한다. 유효 시간은 늘리지 않는다.
  갱신이 제때 끝나면 연결이 끊기지 않는다. 요청 간격은 2분, 만료된 채 갱신이 안 되면 30분까지 두 배씩 늘린다(실패가 이어질 때 화면 없는 엔진을 계속 띄우지 않게). 캐시가 다시 열리면 되돌린다.
- **KEEP 대기 회피**: 갱신은 `NotificationWork.scheduleGateRenewal`(`scheduleFresh` 규칙: 대기 중이면 REPLACE, 실행 중이면 APPEND_OR_REPLACE)로 예약한다.
  예전 `schedule(renewGate=true)` 는 KEEP 이라 앞선 실패의 지수 대기(최대 5시간) 뒤에 묶여 그동안 '인증 확인 후…' 에서 멈췄다.
- 만료 대기 중에는 네트워크 없이 로컬 캐시만 5초마다 다시 보고, 화면 문구는 "로그인 확인 중입니다. 확인되면 서버에 다시 연결합니다", 재시도 번호를 0으로 되돌린다.
  연결 문구는 첫 시도 "서버 연결 중...", 실패 뒤 "서버 연결 재시도 중... (N회째)", 성공 "서버 연결됨 ✓". 실패 로그에 HTTP 상태를 남긴다.
- `MainActivity.onResume` 은 만료만 된 캐시(`canRenew`)로 서비스를 멈추지 않는다(예전에는 앱을 열 때마다 멈췄다 Flutter 확인 뒤 처음부터 다시 연결했다).
  `startWsService`(Flutter 호출)는 여전히 열린 캐시만 받는다.
- 서비스가 멈춘 뒤 루프 스레드가 늦게 지속 알림을 다시 올려 서비스 없는 알림이 남던 경로를 막았다(`updateForegroundNotif` 가 `running` 확인, 종료·`onDestroy` 에서 알림 취소).
- 남은 한계: 화면 없는 갱신이 실패하면(카카오 세션·네트워크·서버 5xx) 그동안은 연결하지 않는다. 실패 원인은 기기 로그로 확인해야 한다.
  `ServerContract.wsEventsUrl` 은 baseUrl 의 하위 경로를 버린다(역방향 프록시 하위 경로를 쓰면 WS 만 404) — 계약 파일이라 이번에 바꾸지 않았다.

`MainActivity.startWsService`는 닫힌 캐시로 시작을 거부한다. Flutter는 캐시 저장 완료 뒤 서비스를 시작하며, 메인 화면 복귀 때 다시 검증하고
Client 연결을 재개한다. 지속 알림 갱신은 `setOnlyAlertOnce(true)`로 반복 알림음을 막는다.

### DB 완료 알림의 파일 앱 fallback

`DbExportLocation.notifyCompleted`는 finalize한 실제 content URI·파일명·위치를 PendingIntent에 넣는다. foreground 완료는 Dart에서 위치를 열고, background 완료는 알림 탭의 MainActivity만 위치 앱을 연다. location intent를 처리할 앱이 없으면 native Activity dialog로 정확한 파일명/위치와 파일 열기·공유·닫기를 제공한다. 파일 열기/공유도 실패하면 dialog를 유지한다. 오래된 알림 metadata는 content provider에서 조회하며 SAF URI나 document ID를 조립하지 않는다. intent extras는 한 번 소비해 회전/재생성에서 자동 반복 실행하지 않는다.

## 코드 대조 정정: 처리 큐와 실행 수명

- `ProcessingInboxStore`는 앱 전용 SQLite이며 교환 DB 스키마와 독립적이다. 새 이벤트마다 UUID를 사용하고 ACK는 처리 전에 claim한 event key와 owner·lease에 한정한다. 보관 상한 200은 알림 이력에만 적용하며 미완료 의도를 자르지 않는다. 한 번 읽는 native batch는 200개다.
- 기존 prefs 이벤트는 복사·영수증 확인 후에도 원본을 남긴다. 소유권을 알 수 없는 기존 작업은 `legacy-unverified`로 격리하고 개수를 반환한다. 격리 항목의 존재는 현재 scope 처리의 오류가 아니며 정상 작업은 계속 처리한다. Android의 구형 단일 prefs 큐도 native claim을 우회해 소비하지 않는다. 계정 변경으로 기존 작업을 새 계정에 넘기지 않는다. 네이티브 이관의 종료 지점별 기기 검증 전에는 legacy 삭제를 활성화하지 않는다.
- 새 private processing DB와 capture retry `.events-v1`는 이전 바이너리가 읽지 못한다. 코드 롤백만으로 미완료 의무를 이전 prefs/JSON로 되돌릴 수 없다. 미완료 작업이 있는 상태의 바이너리 다운그레이드는 지원하지 않으며, 동일 reader를 유지한 수정 배포 또는 검증된 역이관이 필요하다. 재설치·앱 데이터 초기화로 복구하지 않는다.
- 잘못된 Flutter List 원문은 앱 전용 quarantine 파일에 flush·sync·rename으로 보존한 뒤에만 원래 키를 정리한다. 해석 실패나 저장 실패는 recovery flag를 남기며 빈 큐로 완료시키지 않는다. 이 flag와 격리 자료의 복구·소유권 확인은 검증된 별도 복구 경로가 필요하다.
- native FGS 시작은 `startForeground` 성공 receipt 이후 true다. Flutter의 작업 실행 상태와 실제 FGS 상태를 별도로 표시하고 native timeout·종료를 owner에 전달한다. 새 headless 엔진은 만들지 않는다. 서비스가 Activity 소유 엔진보다 오래 살아 동기화를 이어 간다고 가정하지 않는다.
- 알림 builder·channel·device name은 실제 최소 API24/25에서 사용할 수 있는 분기로 나눈다. producer별 notification tag와 PendingIntent data URI를 쓰고 기존 nav5/6 매핑은 보존한다.
- `verify.yml`/`tool/verify_refactoring.sh`는 고정 Flutter 버전·lockfile, 분석·fixture 테스트·Kotlin 단위 테스트·Android lint를 서명/패키징 전에 검사한다. 외부 fork PR은 개인 self-hosted runner에서 실행하지 않는다. 정식 mapping 보관은 90일이며 APK/AAB 보관 1일, dev 산출물 30일과 구분한다. CI를 새로 실행하거나 릴리즈를 발행했다는 뜻은 아니다.

### 보안 저장소 미이관 설치의 확인형 복구

`SecureStorageRecoveryScreen`의 초기화 버튼 → 삭제·보존 범위를 설명하는 확인창 → 명시적 동의 순서로만
`com.fentanest.mysafetyreport/secure_storage`의 `resetSecureStorageForReauthentication`을 호출한다.
`SecureStorageRecovery.reset`은 플러그인 전용 **FlutterSecureStorage**, **FlutterSecureKeyStorage**,
**FlutterSecureStorageConfiguration**, **FlutterSecureStorageConfiguration:FlutterSecureStorage**만
`clear().commit()`한다. 구형 암호화 설정과 wrapped AES key까지 비워 v11 초기화를 막지 않도록 한다.
v9 암호문·ESP keyset을 읽거나 v11 플러그인을 먼저 초기화하지 않는다. FlutterSharedPreferences,
신고 DB, 커뮤니티 DB 및 서버 자료는 변경하지 않는다. commit 실패는 false로 반환하며 자동 초기화하지 않는다.
Dart가 빈 보안 저장소를 확인하고 v11 준비 표시를 저장한 뒤 정상 시작(기존 로그인·연결 게이트)으로 돌아간다.
미이관 설치용 경로이며, 일반 Keystore 읽기 오류 화면에는 초기화 버튼을 노출하지 않는다.

### Play alpha 업로드 / 정식 릴리즈 절차 (2026-10-13 재개정)
- main push 는 아무것도 하지 않는다(트리거 없음). Play alpha 업로드는 `build-apk.yml` 수동 실행(`workflow_dispatch`,
  입력은 `whatsnew` 뿐 — `action` 선택은 없앴다, 항상 alpha)으로만 한다.
- alpha 출시 노트: 실행 때 입력한 `whatsnew` → `docs/releases/unreleased.md`(미출시 누적 노트, 비었으면 건너뜀) →
  `테스트 빌드 <이름> (<versionCode>) · <커밋>` 순. 버전별 노트(`v<이름>.md`)는 alpha 에 쓰지 않는다.
- 다음 버전 번호는 정식 릴리스 때 정한다(버그 수정/기능 추가 판단). 그 사이 사용자에게 보이는 변경은
  `docs/releases/unreleased.md` 한 파일에 쌓는다. **정식 릴리스 절차는 `production.yml` workflow_dispatch 실행
  하나로 끝난다**: 버전(SemVer) 입력 → 그 워크플로가 빌드·Play production 업로드·`docs/releases/v<버전>.md` 확정
  (unreleased.md 본문 + 직전 태그 Full Changelog 링크)·`unreleased.md` 비우기·`VERSION` 갱신·main(+가능하면 dev)
  커밋·태그·GitHub Release 를 전부 한다. 사람이 미리 `docs/releases/v<버전>.md` 를 직접 쓰거나 `VERSION` 을 손으로
  올릴 필요가 없다 — `unreleased.md` 만 사실대로 채워 두면 된다. alpha 를 몇 번 올렸든 노트가 `unreleased.md`
  한 파일에 모여 있으므로 릴리스 노트에서 빠지지 않는다.
