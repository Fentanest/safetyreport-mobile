# Android 런타임·권한·FGS·빌드

> 이관 원본: 루트 `CLAUDE.md` (sha256 `32e8f475…9481`, 마지막 변경 커밋 `161b68dc`), 2026-09-24 분할.
> 본문은 원문을 **그대로** 옮겼다. 코드와 달라진 부분은 아래 "코드 대조 정정"에만 적고 원문은 고치지 않았다.
> 원본 전체 사본: [legacy-claude-reference.md](legacy-claude-reference.md) · 제목별 대응표: [README.md](README.md)

## 코드 대조 정정 (2026-09-24, base `c64be69a`)

- 이 파일로 옮긴 절에서 코드와 충돌하는 기술은 이번 대조에서 발견되지 않았다. 다만 부팅 흐름(`overview.md`)의 `enableEdgeToEdge()` 표기는 구버전이다(`MainActivity.kt:46` 은 `WindowCompat.setDecorFitsSystemWindows`).
- 알림 채널/FGS/SharedPreferences 키 표는 이번 단계에서 Kotlin 코드와 줄 단위로 재대조하지 않았다 → **미검증**. UI 리뉴얼로 이 영역을 수정할 때 먼저 대조한다.

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

감지 알림 탭 → MainActivity.onNewIntent → handleNavIntent → 500ms 지연 후 MethodChannel `navigateToTab` →  
Flutter `_handleNativeCall` → 동기화 탭 이동 + (Standalone) `checkAutoSyncOnResume()` → `_drainAndRefresh()`.
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
  ├─ 각 신고에 대해 MethodChannel showNotification (heads-up):
  │    ├─ ChangeType.newReport         → "🆕 신규 신고"
  │    ├─ ChangeType.statusChanged     → "🔄 처리 변경"
  │    └─ ChangeType.individualConfirm → "✅ 개별 동기화"
  └─ changesEmittedController.add(null) → ReportProvider nonce++ → main.dart 트리거
```

`ChangeType` (sync_engine.dart) 가 모든 식별자의 single source of truth.  
`reportToChangeMap(report, changeType)` 가 표준 Map 형식 생성.

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
| `flutter.inbox.queue.<ms>_<순번>` | String (신고번호 하나) | Standalone 감지 큐. Kotlin·Dart 모두 새 키에만 쓰고 `StandalonePendingQueueStore` 가 읽을 때 중복 제거, 처리한 값의 키만 지움 (G11-5) |
| `flutter.standalone_pending_reports` | **String (CSV)** | (G11-5 이전 큐) 남은 값만 읽고 지움 (아래 함정 주의) |
| `flutter.standalone_last_detected_at` | long | 디버그용 |
| `flutter.foreground_event` | String | WsService → 포그라운드 복귀 SnackBar |
| `flutter.inbox.pending.<ms>_<순번>` | String (JSON 배열) | 카드 시트 표시 대기. Kotlin·Dart 모두 **새 키에만** 쓰고 `PendingChangesStore.readAndClear` 가 합친 키만 지움 |
| `flutter.inbox.history.<ms>_<순번>` | String (JSON 배열) | Kotlin 이 넣는 새 알림. `NotificationHistoryProvider` 가 기록에 합치고 그 키만 지움. Kotlin 쪽 최대 200키 |
| `flutter.notifications_history` | String (JSON) | 알림 히스토리 (최대 200개). **Dart 만 씀** |
| `flutter.pending_crawl_changes` | String (JSON) | (R6 이전 값) 남아 있으면 한 번 읽고 지움 |
| `flutter.auto_enqueue_count` / `flutter.auto_enqueue_last_at` | int / long | Client 자동 enqueue 푸시 억제 |

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
- swipe-away 방어 + OS kill 후순위 격상 (강제종료는 못 막음)

### 알림 채널

| 채널 ID | 중요도 | 용도 |
|---------|--------|------|
| `ws_service` | LOW | WsService 지속 알림 |
| `ws_push_v2` | HIGH | crawl_started/finished/changes heads-up |
| `enqueue_progress` | LOW | "📡 개별 크롤링 지시 중" 임시 |
| `standalone_detected_v2` | HIGH | "📬 신규 신고 감지" heads-up (탭 시 sync 트리거) |
| `sync_fgs` | LOW | "🔄 동기화 진행 중" Standalone FGS |
| `app_push_v2` | HIGH | Standalone 변경 알림 (Flutter → MethodChannel showNotification) |

## 자동 enqueue 알림 억제 로직 (Client 전용)

카카오톡 등 외부 알림 → `NotificationService.sendEnqueue()` 자동 트리거 시,
WsService 가 `crawl_started / crawl_finished` push 알림을 쌓는 게 지저분 → 억제.

1. `sendEnqueue` 호출 → `auto_enqueue_count++` + 타임스탬프 기록 + "📡 개별 크롤링 지시 중" ongoing 알림 표시
2. POST 완료/실패 시 finally 에서 ongoing 알림 소거
3. `WsService.showCrawlStartedNotif` / `showCrawlFinishedNotif`: `isAutoEnqueueActive()` true 면 return
4. `crawl_changes` (실제 결과) 는 억제 안 함 — 단, auto_enqueue 활성 세션이면 "🆕 개별 신규" / "🔄 개별 처리 변경" prefix 부착 (가독성)
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

### 로컬 테스트 빌드 (`build_test_apk.sh`)
CI 와 동일한 Docker 이미지 (`ghcr.io/cirruslabs/flutter:stable`).

```bash
./build_test_apk.sh           # debug
./build_test_apk.sh --release # release (~/mysafetyreport-android/ 키스토어 필요)
```

### 로컬 정식 Android 릴리즈 빌드 (`build_android_release.sh`)
`build-apk.yml` 과 동일한 순서:
- `VERSION` 읽기
- `pubspec.yaml version:` 동기화
- Docker Flutter 이미지에서 `flutter build apk --release`
- 이어서 `flutter build appbundle --release`
- 산출물 복사:
  - `build/app/outputs/flutter-apk/mysafetyreport.apk`
  - `build/app/outputs/bundle/release/mysafetyreport.aab`

```bash
./build_android_release.sh
```

기본 키 경로:
- `~/mysafetyreport-android/key.properties`
- `~/mysafetyreport-android/upload-keystore.jks`
