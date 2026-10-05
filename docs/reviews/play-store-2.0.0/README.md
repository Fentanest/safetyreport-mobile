# 나만의 안전신문고 2.0.0 — Play 스토어 변경 점검 및 Console 답변 초안

검토일: 2026-10-05 KST. 비교 기준: 공개 v1.3.5+30 (`c64be69a91999c703bc173fe87aa855fc249e930`) → 2.0.0+31 (`a19aa95049b6659847e2bed029a2bead528d518a`).

## 1. 요약

**Android 권한의 큰 확대보다는, 카카오 계정·필수 공유·백그라운드 전송 도입에 따른 데이터 보안 답변 변경이 핵심이다.**

- 실제 release 병합 결과의 `uses-permission`은 **14개 → 15개, 추가 1개·제거 0개**다. 추가 문자열은 WorkManager 플러그인의 `android.permission.FOREGROUND_SERVICE_SHORT_SERVICE`다. Android 공식 문서는 `shortService`에 별도 유형 권한이 필요 없다고 설명한다. 따라서 이것을 새로운 사용자 승인 권한으로 설명하면 안 된다.
- 기존 `dataSync`·`specialUse` FGS, 알림 접근, 배터리 최적화 제외 요청, 전경 위치, 알림 표시, `CALL_PHONE`, 구형 저장소 권한은 유지된다. `ACCESS_NETWORK_STATE`와 `WAKE_LOCK`도 **기존에 있던 권한**이다. `minSdk 24 / targetSdk 36`은 동일하다.
- 추가 선언은 카카오 OAuth 콜백, WorkManager/Room 구성요소, Play 리뷰용 Activity, `telephony required=false`다. exported=true 구성요소는 3개 → 5개이나 새 2개는 시스템 권한으로 보호된 WorkManager 서비스/리시버다.
- 일반 사용에는 **카카오 인증과 신고내용 공유 동의가 필수**다. 공유 데이터에는 차량번호 **원문**, 신고 지점 주소·좌표, 담당자명, 신고번호, 처분·금액·별점 등이 포함된다. 공개 화면에서 가리는 것과 서버가 수집하는 것은 구분해야 한다.
- 제출 전 우선 해결·확인할 항목: **앱 계정 삭제 경로**, **정본 개인정보처리방침**, **모든 전송 암호화 여부**, **Demo로 검수할 수 없는 기능의 접근 방법**, **FGS 동영상**. 현재 코드만으로 “계정 삭제 제공”, “모든 데이터 암호화”, “아무 데이터도 수집하지 않음”을 답하면 부정확하다.

이 문서는 읽기 전용 조사와 답변 초안이다. Console 입력·배포·운영 로그인·업로드·동의 철회·삭제는 실행하지 않았다. 문서의 ‘확인 필요’는 실제 미확인 사항이며, 승인 여부를 예측한 결과가 아니다.

## 2. 권한·기능 선언 변화

### 2.1 실제 비교 방법과 범위

저장소를 변경하지 않고 `git archive`로 두 커밋을 `/tmp/astra-d-play-audit/{old,new}`에 풀었다. 두 복사본 모두 지정된 **Flutter 3.47.5 / Dart 3.13.4**로 `flutter pub get` 후 **`:app:processReleaseManifest` 성공**을 확인했다. APK 패키징·서명은 필요하지 않았고 릴리즈 스크립트는 실행하지 않았다.

| 항목 | v1.3.5 | 2.0.0 |
|---|---|---|
| 버전 | 1.3.5+30 | 2.0.0+31 |
| AGP / Kotlin Gradle plugin | 8.11.1 / 2.2.20 | 9.1.0 / 2.4.0 |
| Gradle | 8.14 | 9.3.1 |
| 이번 실행 JDK | Android Studio 내장 JBR | 동일 |
| 결과 | BUILD SUCCESSFUL, 53 tasks, 1m 48s | BUILD SUCCESSFUL, 42 tasks, 1m 22s |
| SDK | min 24 / target 36 | min 24 / target 36 |
| Flutter 호환 한계 | 3.47.5에서도 병합 성공. 구 AGP/Kotlin 지원 경고 있음 | 지정 SDK에서 병합 성공 |
| pub lock | SDK 영향으로 matcher/meta/test_api/vector_math 4개만 변경 | 변경 없음 |

Gradle wrapper 실행 파일은 git archive에 없어서, 태그의 wrapper properties가 지정한 **설치된 같은 버전의 Gradle 실행 파일**을 직접 사용했다. `local.properties`에 SDK 경로·release·버전만 기록했다. 서명 파일과 운영 설정은 복사하지 않았다. 구버전의 4개 lock 변경은 [차이 파일](evidence/old-pubspec-lock.diff)에 보존했다. Android 플러그인 버전 변경은 없었다.

재현 명령의 구조:

```sh
/home/better0101/development/flutter-3.47.5/bin/flutter pub get
JAVA_HOME=/home/better0101/development/android-studio/jbr <Gradle-8.14-or-9.3.1>/bin/gradle -p android :app:processReleaseManifest --console=plain
```

재빌드만으로 과거 공개물을 추정하지 않도록 [GitHub v1.3.5 공개 릴리즈](https://github.com/Fentanest/safetyreport-mobile/releases/tag/v1.3.5)의 `mysafetyreport.apk`도 다운로드하고 `apkanalyzer manifest print`로 추출했다. **공개 APK와 구버전 재병합의 권한·maxSdk·min/targetSdk·queries·컴포넌트 이름 집합이 일치**한다. APK의 FGS 정수값 `0x1 / 0x8 / 0x40000000`은 각각 dataSync/location/specialUse다. Play Console에 실제 등록된 AAB 자체와의 동일성은 미확인이다.

- 공개 APK SHA-256: `a8cea9aaba53915f41d90a1cbf1aa8edc26892adeb6e8776abda0abcfe68d0e4`
- [구버전 공개 APK 매니페스트](evidence/v1.3.5-published-manifest.xml), [구버전 release 병합본](evidence/old-release-merged-manifest.xml), [새 버전 release 병합본](evidence/new-release-merged-manifest.xml)
- [구버전 병합 로그](evidence/old-processReleaseManifest.log), [새 버전 병합 로그](evidence/new-processReleaseManifest.log), [구조화 비교 자료](evidence/manifest-facts.json)

이하 코드의 `파일:줄`은 **a19aa950 고정본** 기준이다. 조사 중 공유 작업 트리에 다른 작업의 변경이 생겼지만 본 비교에는 섞지 않았다.

### 2.2 uses-permission 전수 비교

별도 표시가 없으면 접두사는 `android.permission.`이다. 아래 15행이 두 버전 권한의 전체 합집합이다. 병합 근거: old/new 매니페스트 및 merger report.

| 권한 | v1.3.5 | 2.0.0 | 변화·실제 용도 |
|---|---|---|---|
| INTERNET | 있음 | 있음 | 동일. 공식 안전신문고·사용자 서버·새 커뮤니티 Auth/업로드·지도 타일 통신 |
| ACCESS_FINE_LOCATION | 있음 | 있음 | 동일. 지도 현재 위치 표시, 사용 맥락에서 요청 |
| ACCESS_COARSE_LOCATION | 있음 | 있음 | 동일. 전경 위치 |
| REQUEST_IGNORE_BATTERY_OPTIMIZATIONS | 있음 | 있음 | 동일. OS 배터리 최적화 제외 직접 요청 |
| POST_NOTIFICATIONS | 있음 | 있음 | 동일. Android 13+ 앱 알림 표시 |
| RECEIVE_BOOT_COMPLETED | 있음 | 있음 | 동일한 권한이지만 새 WorkManager의 재예약 receiver가 활용 |
| FOREGROUND_SERVICE | 있음 | 있음 | 동일. FGS 기본 권한 |
| FOREGROUND_SERVICE_DATA_SYNC | 있음 | 있음 | 동일. Standalone 동기화·만족도 제출 작업 |
| FOREGROUND_SERVICE_SPECIAL_USE | 있음 | 있음 | 동일. Client 서버 WebSocket 이벤트 수신 |
| CALL_PHONE | 있음 | 있음 | 동일. 아래 전화 기능 항목 참조 |
| READ_EXTERNAL_STORAGE | 있음, maxSdkVersion=32 | 같음 | open_filex 병합. Android 12L 이하 파일 열기 경로 |
| ACCESS_NETWORK_STATE | 있음 | 있음 | 구버전에도 media3 의존성이 추가. 새 버전은 WorkManager도 병합 근거 |
| WAKE_LOCK | 있음 | 있음 | 구버전에도 media3-exoplayer 의존성이 추가. 새 버전은 WorkManager도 사용 |
| com.fentanest.mysafetyreport.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION | 있음 | 있음 | AndroidX의 앱 전용 signature 권한 선언과 uses-permission 모두 동일 |
| FOREGROUND_SERVICE_SHORT_SERVICE | 없음 | **추가** | workmanager_android 0.10.9 매니페스트가 추가한 문자열. Android 표준 유형별 권한으로 오인 금지 |

**제거된 uses-permission은 없다.** `READ_MEDIA_IMAGES/VIDEO/AUDIO`는 양 버전 소스에 `tools:node="remove"`로 적혀 있으나 최종 병합본에는 모두 없다. 따라서 이번 릴리즈에서 새로 제거한 권한이 아니다.

양 버전 모두 `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE_LOCATION`, `MANAGE_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`, `READ_MEDIA_VISUAL_USER_SELECTED`, `QUERY_ALL_PACKAGES`, `READ_PHONE_STATE`, `READ_CALL_LOG`, `WRITE_CALL_LOG`, `READ_SMS`, `SEND_SMS`, `RECORD_AUDIO`, `CAMERA`, `SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`, `USE_FULL_SCREEN_INTENT`, `com.google.android.gms.permission.AD_ID` 선언이 없다. `BIND_NOTIFICATION_LISTENER_SERVICE`, `BIND_JOB_SERVICE`, `DUMP`는 아래 컴포넌트의 **호출자 보호 권한**이며 앱이 요청한 uses-permission과 다르다.

`shortService`는 유형 전용 권한이 없고 기본 FGS 권한을 사용하는 유형이다. 플러그인 주석보다 [Android 공식 FGS 유형 설명](https://developer.android.com/develop/background-work/services/fgs/service-types)을 우선한다. 이번 앱의 WorkManager 등록에는 expedited/foreground 설정이 없으므로 ‘이 앱이 매 작업마다 shortService를 시작한다’고 단정하지 않는다.

### 2.3 서비스와 exported 구성요소 전수 비교

아래 이름의 `앱.`은 `com.fentanest.mysafetyreport.`다. `false`는 외부 공개 안 함, `true + 권한`은 해당 시스템 권한을 가진 호출자만 접근 가능하다는 뜻이다.

| 컴포넌트 | 종류 | 구버전 → 새 버전 | exported / 보호·유형 |
|---|---|---|---|
| 앱.MainActivity | Activity | 유지, OAuth filter 추가 | true. 런처 + 신규 인증 콜백 |
| 앱.NotificationService | Service | 유지 | true, BIND_NOTIFICATION_LISTENER_SERVICE. FGS type 없음 |
| 앱.WsService | Service | 유지 | false, **specialUse**. subtype 설명 문자열 동일 |
| 앱.SyncForegroundService | Service | 유지 | false, **dataSync** |
| com.baseflow.geolocator.GeolocatorLocationService | Service | 유지 | false, **location**. 플러그인의 선언이며 앱은 단발 위치 요청 사용 |
| com.crazecoder.openfile.FileProvider | Provider | 유지 | false, grantUriPermissions=true |
| dev.fluttercommunity.plus.share.ShareFileProvider | Provider | 유지 | false, grantUriPermissions=true |
| dev.fluttercommunity.plus.share.SharePlusPendingIntent | Receiver | 유지 | false |
| io.flutter.plugins.urllauncher.WebViewActivity | Activity | 유지 | false. OAuth 실제 실행은 외부 브라우저 |
| com.google.android.gms.common.api.GoogleApiActivity | Activity | 유지 | false |
| androidx.startup.InitializationProvider | Provider | 유지, WorkManagerInitializer metadata 추가 | false |
| androidx.profileinstaller.ProfileInstallReceiver | Receiver | 유지 | true, android.permission.DUMP |
| androidx.work.impl.foreground.SystemForegroundService | Service | **추가** | false, **shortService**, directBootAware=false |
| androidx.work.impl.background.systemjob.SystemJobService | Service | **추가** | true, android.permission.BIND_JOB_SERVICE |
| androidx.work.impl.utils.ForceStopRunnable$BroadcastReceiver | Receiver | **추가** | false |
| androidx.work.impl.background.systemalarm.RescheduleReceiver | Receiver | **추가** | false, 초기 enabled=false, BOOT_COMPLETED filter |
| androidx.work.impl.diagnostics.DiagnosticsReceiver | Receiver | **추가** | true, android.permission.DUMP |
| androidx.room.MultiInstanceInvalidationService | Service | **추가** | false, directBootAware=true |
| com.google.android.play.core.common.PlayCoreDialogWrapperActivity | Activity | **추가** | false, Play 리뷰 UI |

합계 **12개 → 19개**, 삭제 없음. exported=true는 MainActivity/NotificationService/ProfileInstallReceiver의 3개에서 SystemJobService/DiagnosticsReceiver가 더해진 5개다. 공개 ContentProvider는 없다. WorkManager enabled 리소스·실행 중 활성화 상태를 실제 기기에서 확인한 것은 아니다.

앱 Application은 `android.app.Application` → `앱.SafetyReportApplication`으로 바뀌었다. WorkManager 백그라운드 로그인 점검 결과를 알림으로 표시하는 SharedPreferences 리스너 등을 등록한다(`android/app/src/main/kotlin/com/fentanest/mysafetyreport/SafetyReportApplication.kt:13`, `:40`). `allowBackup=false`, `usesCleartextTraffic=true`, `extractNativeLibs=false`는 동일하다.

FGS 세부 근거:

- `WsService.kt:71`, `:586`, `:602`: 연결 알림·중지 action·specialUse 시작. `onTimeout`은 `:87`.
- `SyncForegroundService.kt:73`, `:86`: timeout 처리 및 dataSync 시작/종료. `lib/services/sync_engine.dart:150`, `:177`에서 작업 생명주기와 연결한다.
- `lib/services/rating_service.dart:167`도 동일한 동기화 FGS를 사용한다. ‘신고 내려받기에만 쓴다’는 답변은 범위를 누락한다.
- `lib/screens/report_map_screen.dart:52`는 `getCurrentPosition(LocationSettings(...))`이다. background 위치 스트림·foregroundNotificationConfig는 사용하지 않는다. 플러그인의 location 서비스 선언만으로 백그라운드 위치 수집 기능이 있다고 답하지 않는다.

### 2.4 queries·intent-filter·기능·SDK

| 항목 | 비교 결과 | Console에 설명할 의미 |
|---|---|---|
| uses-feature | **android.hardware.telephony required=false 추가** | 전화 기능 없는 기기에서도 설치 가능하도록 명시. 기존 CALL_PHONE의 암묵적 기기 필터 영향을 완화 |
| queries | 두 버전 **완전히 동일**, 총 6개 intent | PROCESS_TEXT + text/plain; VIEW + https; VIEW + http; VIEW + appsafetyreport; DIAL + tel; GET_CONTENT + */*. 마지막은 file_picker 병합 |
| 패키지 전체 조회 | 양쪽 없음 | QUERY_ALL_PACKAGES 없음. 카카오톡/공식앱 알림 package 비교는 전체 설치 앱 목록 수집과 다름 |
| MainActivity 런처 | MAIN + LAUNCHER 유지 | 기존 실행 진입점 |
| OAuth 콜백 | **VIEW + DEFAULT + BROWSABLE**, `com.fentanest.mysafetyreport://auth/callback` 추가 | scheme/host/path 고정. 검증된 https App Link는 아님. Flutter 자동 딥링크 처리는 false로 추가 |
| NotificationService filter | NotificationListenerService action 유지 | OS 알림 접근 설정에서 사용자가 허용 |
| SharePlus receiver filter | EXTRA_CHOSEN_COMPONENT 유지 | 공유 대상 선택 처리 |
| ProfileInstallReceiver filter | INSTALL_PROFILE / SKIP_FILE / SAVE_PROFILE / BENCHMARK_OPERATION 유지 | DUMP 보호 |
| WorkManager filter | BOOT_COMPLETED 및 REQUEST_DIAGNOSTICS **추가** | 각각 재예약·진단. 재부팅 때 앱 dataSync FGS를 직접 켠다는 뜻은 아님 |
| 기타 딥링크 | `appsafetyreport`는 queries의 **외부 공식앱 열기**, `mysafetyreport://notification/...`는 명시적 PendingIntent 식별용 | 일반 외부 딥링크용 수신 intent-filter로 새 등록된 것이 아님 |
| 인터넷/평문 | INTERNET 및 usesCleartextTraffic=true 유지 | Supabase는 release HTTPS 검증. 사용자 서버 HTTP/WS 경로는 여전히 가능 |
| 알림 접근/표시 | 리스너 + POST_NOTIFICATIONS 유지 | 읽기 접근과 앱 알림 표시를 별도 설명해야 함 |
| 전화 | CALL_PHONE 유지, UI는 tel 링크 실행 | `report_detail_sheet.dart:420`의 답변 속 전화번호 → url_launcher. 직접 ACTION_CALL·Permission.phone 요청은 앱 코드에서 찾지 못함. SMS·통화기록 읽기 없음 |
| 저장소 | READ_EXTERNAL_STORAGE max32 유지, 미디어3종 최종 부재 | DB/Excel 선택·내보내기·열기·공유. 모든 파일 접근 권한은 없음 |
| WorkManager | 신규, Dart workmanager **0.10.10**, Android 구현 **0.10.9**, androidx.work **2.11.2** | 로그인 점검 24시간(최초 6시간 후), 업로드 복구 1시간, KST 자정 one-off 예약. 정확 알람 아님 |
| minSdk/targetSdk | **24/36 → 24/36** | Android 7.0 이상. 이번 업데이트의 SDK 상승 없음 |
| compileSdk | 공개 APK 36 / 새 Flutter 기본값 36 | 빌드 도구 변경과 targetSdk 변경을 구분 |
| uses-library | androidx.window.extensions/sidecar optional 유지 | 새 하드웨어 필수 조건 아님 |

WorkManager 일정 근거: `lib/services/background_login_check.dart:134`, `lib/community/upload/community_schedule.dart:70`. OS의 실제 실행은 제약·배터리 정책에 따라 지연될 수 있으므로 “매일 00:00 정각에 반드시 실행”이라고 쓰지 않는다.

## 3. 데이터 보안 변화

### 3.1 수집·보관·전송 경로

| 처리 | v1.3.5 대비 | 새 버전의 코드상 동작 / 근거 |
|---|---|---|
| 카카오 인증·Supabase Auth | **신규** | 외부 브라우저 OAuth/PKCE, 인증 코드 교환·토큰 갱신·user 조회. Supabase user ID·카카오 회원번호·닉네임·이메일 존재 여부를 앱에서 사용. 토큰/세션은 FlutterSecureStorage. `community_auth_service.dart:134`, `:160`, `:308`, `:376`, `:878`, `:901`, `:1009` |
| 일반 이용 조건 | **신규** | 양 모드의 진입 게이트에서 카카오 인증 + 중앙 정책 공유 동의 필요. Demo만 합성 자료로 예외. `main.dart:309`; `community/gate/gate_state.dart:60`, `:96` |
| Client의 계정 | **신규, 이중 역할 주의** | 폰의 앱 게이트 인증과 연결 서버의 카카오 계정 연결은 별개. 서버 연결 세션은 서버가 보관하고 폰은 서버 API의 표시 상태/비교코드를 사용. 구 architecture 문서의 ‘Client 폰에 세션 없음’은 **서버 연결용 세션**에만 적용; 현재 전역 폰 게이트 인증까지 없다는 뜻이 아님. `main.dart:324`; `community/client_account_notice.dart:9`, `:44`; `services/community_server_link_service.dart` |
| 커뮤니티 연결 식별 | **신규** | device_label(기기 이름), platform, source_app/mode, dataset_key, connection_secret 및 동의 버전·해시·accepted 전송. dataset_key는 공식 로그인 ID를 정규화해 SHA-256 처리한 값으로 **익명 데이터라고 단정할 수 없음**. `community_account_client.dart:64`, `:89`; `gate_state.dart:35`; `community_gate.dart:674` |
| 커뮤니티 신고 업로드 | **신규** | Standalone → Supabase `functions/v1/community-ingest`. 수집 직후·수동·자정 예약·복구 실행. Client는 사용자 서버가 업로드하며 폰은 서버에 실행 요청. 아래 payload 전수표 참조 |
| 기기 현재 위치 | 기존 기능 | 지도 이동·마커용 메모리 상태. GPS 좌표를 커뮤니티 업로드 필드로 연결하는 코드 없음. **지도 타일 요청까지 외부 무전송이라는 뜻은 아님**. `report_map_screen.dart:308`, `:315`, `:1028` |
| 외부 알림 | 기존 + 게이트/내구성 보강 | 안전신문고·카카오톡 package의 title/text에서 SPP 신고번호 정규식 추출. Client는 사용자 서버에 신고번호 전송, Standalone은 로컬 대기 큐. 제목/본문 전체 전송 코드 없음. `NotificationService.kt:44`, `:57`, `:107`, `:116`, `:149` |
| 안전신문고 자격 증명 | 기존 + 보안 저장소 이관·재로그인 점검 | HTTPS 공식 사이트로 ID/RSA 처리 비밀번호 전송. 비밀번호는 secure storage, **공식 access token·ID·전화번호는 SharedPreferences** 경로다. 모든 자격 증명이 보안 저장소에 있다는 설명은 틀림. `standalone_auth_service.dart:71`, `:228`, `:356`, `:394`, `:436`; `secure_storage_migration.dart:20` |
| 만족도 별점·사유 | 별점 기존, 자유입력 사유 확대 | 공식 사이트에 신고번호·전화번호·점수·선택 사유 전송. Client는 사용자 서버 API 경유. 커뮤니티 공유에는 숫자 rating만, 사유 원문 제외. `standalone_api_service.dart:371`; `rating_service.dart:55`; `observation_rules.dart:331` |
| Google Play 평가 요청 | **신규** | 설치 경과 7일·사용일 5일·90일 간격·최대 3회, 긍정 처리 결과의 상세를 닫은 뒤 요청. 최근 조건은 실제로 **syncedAt 3일 이내**. 카운트는 로컬 prefs, Google이 리뷰 UI 처리. `review_prompt_service.dart:16`, `:56`, `:63`, `:96` |
| DB/Excel·파일 공유 | 기존 | 로컬 내보내기와 사용자 서버로 DB 복원 업로드는 구분. 사용자 선택 공유 시 해당 파일의 실제 데이터가 외부 앱에 전달될 수 있음. `settings_screen.dart:539`; `file_browser_screen.dart:288`; `api_service.dart` 및 `db_export_location.dart` |
| 문의/버그 제보 | 안내 경로 확대 | 외부 GitHub 양식에 버전·모드·OS 포함, 사용자가 작성/제출. ID·API 키·차량번호를 자동 포함하지 않도록 안내. `support_links.dart:17`, `:32`; `settings_screen.dart:2295` |

카카오 로그인 시 provider가 실제 제공하는 이메일·프로필 사진 및 중앙 보관 범위는 앱 파서만으로 확정할 수 없다. 앱은 이메일 문자열을 세션에 저장하지 않고 has_email만 남기지만 **Supabase가 이메일을 수집하지 않는다는 증거가 아니다**. 운영 카카오 scope, Supabase Auth 설정과 저장 항목을 확인해야 한다. 공개 계정 안내도 이메일·프로필 사진 가능성을 명시한다([안내 페이지](https://safeauth.worklazy.net/privacy.html)).

### 3.2 커뮤니티에 전송되는 항목 — 공개 화면과 분리

`lib/community/capture/observation_rules.dart:313`의 payload는 다음 **15개 최상위 필드**다.

| 필드 | 전송 내용 |
|---|---|
| address | 신고 지점 주소 |
| agency_name | 처리기관명 |
| amount | confirmed_won(확정 금액), kind(구분), penalty_points(벌점) |
| category | 신고 분야 |
| completed_date | 처리완료일 |
| disposition | 처분 구분 |
| location | lat, lng, source. 공식 신고 상세 좌표, 없으면 null |
| manager_name | 담당자 이름 |
| report_date | 신고일 |
| status | 정규화 처리 상태 |
| status_raw | 원문 처리 상태 |
| vehicle_raw | **차량번호 원문** |
| violation_law | 추출된 위반 법규 |
| rating | 공식 상세의 숫자 별점 1~5, 없으면 null |
| source_agency_code | 원문 기관코드 |

추가로 event에 `event_id`, `event_type`, `source_system`, `source_report_id`, **`report_number`**, `source_revision`, `writer_epoch`, `captured_at`, `payload_sha256`가 실린다. envelope에는 protocol/contract, source_app/mode, connection_id, consent_grant_id, policy_version, client_version, parser_version, trigger가 들어간다(`community_uploader.dart:1333`, `:1346`). 전송에는 apikey와 Bearer access token도 사용한다(`community_ingest_client.dart:30`).

사진·동영상·첨부, 신고 본문·처리내용 전체, 별점 사유 원문, 현재 GPS 위치, 추정 금액, 안전신문고 ID/비밀번호 원문은 **이 커뮤니티 payload에 없다**. 단, 공식 ID의 파생 해시(dataset_key), 카카오 회원번호가 존재하므로 ‘계정과 완전히 무관한 익명 통계만 전송’으로 설명하면 안 된다.

공개 안내는 차량번호 일부 마스킹, 신고번호·원문 차량번호·계정·기기 정보 비공개라고 설명한다. 이 검토는 중앙 DB/RLS/공개 projection 실행 검증을 포함하지 않는다. **공개 제외는 수집 제외가 아니다.** 차량 소유자·담당자 등 제3자의 데이터와 세밀한 위치를 공개하는 범위도 실제 중앙 정책·접근제어와 대조해야 한다.

### 3.3 위치·알림·암호화의 주의점

- 현재 위치는 기기에서 지도 중심으로 사용하지만 지도는 `https://tile.openstreetmap.org/{z}/{x}/{y}.png`를 요청한다. 요청 좌표 타일·IP·User-Agent가 외부에 전달된다. **기기 GPS 원문을 개발자 서버에 보내는 경로가 없다는 코드 사실**과 **타일로 표시 지역을 추정할 수 있다는 추론**을 구분한다. 신고 위치는 별도로 커뮤니티에 실제 전송된다. ‘위치 일절 수집 안 함’을 바로 선택할 수 없다.
- 알림 package 필터는 카카오톡의 ‘공식 안전신문고 발신자’까지 검증하지 않는다. 해당 두 앱의 알림 title/text에서 정규식에 맞는 번호를 찾는다. “공식 발신자의 알림만 읽는다”는 표현은 부정확하다. 일반 메시지 전체가 서버로 전송되는 것은 확인되지 않았다.
- HTTPS인 공식 사이트·Supabase와 달리 사용자 서버의 HTTP/WS는 허용된다(`server_contract.dart:108`, 소스 Manifest:28). 저장 시 암호화와 전송 암호화도 별개다. **전체 전송 암호화 ‘예’는 현재 확인 불가**이며, 현재 지원 경로를 모두 포함하면 보수적인 초안은 ‘아니요’다. 사용자 지정 서버가 Play의 외부 서비스 전송 예외에 해당하는지와 실제 배포 설정을 확인한 뒤 최종 판단한다.

### 3.4 삭제와 개인정보 안내 — 현재 확인된 공백

1. `community_account_card.dart:561`, `:685`에서 ‘공유한 자료 삭제 요청’ 함수·버튼이 주석 처리되어 있다. API 메서드의 존재(`community_account_client.dart:131`)는 사용 가능한 UI의 증거가 아니다.
2. 동의 철회는 `consent-revoke`와 공개 제외 확인이다(`community_account_card.dart:479`). Supabase 사용자 계정 삭제가 아니다.
3. 카카오 로그아웃은 조건에 따라 이 기기 신고 자료를 지우고 로컬 세션을 해제한다(`community/kakao_logout.dart:90`). 중앙 계정 및 서버의 업로드 자료를 모두 삭제하는 기능이 아니다. 감시목록 등 일부 로컬 자료도 남는다.
4. 앱의 개인정보 안내 링크는 `https://safeauth.worklazy.net/privacy.html`이다(`community_onboarding_screen.dart:51`, `:304`). 2026-10-05 HTTP GET은 **200**이었으나 본문은 법적 방침을 대신하지 않는 기술 설명이라고 밝힌다. 해당 페이지의 JS가 만드는 ‘정본 개인정보처리방침’ 링크도 **자기 자신**을 가리킨다. [받은 HTML](evidence/privacy.html), [링크 구성 JS](evidence/privacy-doc.js)에 보존했다.
5. 같은 공개 페이지는 공유 자료 삭제를 커뮤니티 지도 GitHub Issues에 요청할 수 있다고 안내한다. 이것은 **자료 삭제 문의 안내**의 증거일 뿐, 앱 계정 자체와 연결 데이터의 삭제를 완료하는 운영 절차/기한/본인확인 구현 증거는 아니다. 공개 게시판에 개인정보를 쓰지 말라는 안내는 있다.
6. 공개 페이지의 공유 정책 표기는 `2026-09-28.1`이며 위반법규·숫자 별점·기관코드 전송을 충분히 설명하지 않는다. 앱이 실제 받아 표시하는 중앙 정책 본문/버전은 로그인하여 확인하지 않았다.

## 4. Play Console 항목별 답변 초안

‘복사 가능’은 코드에 맞는 설명 초안이라는 의미다. `[확인 후 입력]`은 실제 정보가 없으므로 빈칸을 채우기 전 제출하지 않는다. 기존 Console 응답은 열람하지 않았으므로 ‘기존 답변과 동일’ 여부는 운영자가 비교해야 한다.

### 4.1 민감한 권한 / 알림 접근 사용 목적

**답변 초안**

> 나만의 안전신문고는 사용자가 안전신문고에 이미 접수한 신고를 조회·관리하는 비공식 앱입니다. 사용자가 Android 알림 접근 설정에서 허용하면, 안전신문고 및 카카오톡 알림의 제목과 텍스트에서 SPP 형식의 신고번호를 찾아 해당 신고를 갱신할 대상으로 등록합니다. Client 모드에서는 추출한 신고번호를 사용자가 지정한 서버로 보내고, Standalone 모드에서는 기기의 대기 목록에 저장하여 동기화 시 사용합니다. 알림 제목과 본문 전체를 업로드하지 않습니다. 알림 접근은 시스템 설정에서 해제할 수 있습니다. 이 앱이 표시하는 진행·결과 알림에는 별도의 알림 표시 권한을 사용합니다.

현재 권한 카드에는 자동 번호 감지 목적이 있지만 Client의 외부 전송·백그라운드 처리 범위는 위 초안만큼 명시돼 있지 않다(`permission_screen.dart:195`). Console 설명만 고치는 것으로 앱 안 고지를 대신할 수 없다. 알림 접근을 위한 별도의 전용 Console 선언서가 반드시 생긴다고 단정하지 않으며, 업로드 후 실제 노출 항목·검토 요청은 **확인 필요**다. [Google Play User Data 고지·동의 기준](https://support.google.com/googleplay/android-developer/answer/10144311).

### 4.2 포그라운드 서비스 유형

**선택 초안: dataSync, specialUse.** 새로 발명한 유형이 아니라 기존 권한의 현재 사용 사례를 갱신한다. 두 유형 각각의 실행 절차가 보이는 동영상 링크를 준비한다. 선언에는 기능, 지연/중단 영향, 실행 시연이 필요하다. [Google Play FGS 선언 안내](https://support.google.com/googleplay/android-developer/answer/13392821).

**dataSync 설명 초안**

> Standalone 모드에서 사용자가 시작한 기존 신고 내역 동기화와 만족도 조사 제출을 수행하는 동안 사용합니다. 공식 서비스에서 자료를 내려받아 기기 데이터베이스에 반영하거나 사용자가 선택한 점수·사유를 제출하며, 작업 진행 알림을 표시합니다. 처리가 지연되면 사용자가 요청한 최신 신고 내역·만족도 결과를 바로 확인할 수 없고, 중단되면 확인되지 않은 작업을 다시 점검해야 합니다. 작업 종료 시 서비스를 종료합니다. 신고 접수 기능은 아닙니다.

실제 `SyncEngine`은 자동/대기 큐 동기화 진입점도 갖고 있다. 제출 설명의 추가 문장: “사용자가 설정한 자동 동기화 및 감지 대기 신고 처리에도 같은 작업 보호 경로를 사용합니다.” 해당 동작이 백그라운드 시작 제한과 FGS 정책에 부합하는지는 테스트·영상으로 입증해야 한다. 별점 제출까지 dataSync 사용 사례로 인정되는지, 사용자 중단 UI가 해당 모든 경로에 충분한지는 **확인 필요**다. `SyncEngine`은 timeout·중단 시 대기를 보존하므로 ‘중단되면 데이터가 반드시 유실된다’고 과장하지 않는다.

**specialUse 설명 초안**

> Client 모드에서 사용자가 지정한 개인 크롤링 서버와 WebSocket 연결을 유지하여 크롤링 진행·완료 등 신고 관리 이벤트를 앱이 뒤에 있을 때도 받습니다. 연결 상태를 지속 알림으로 표시하고 알림의 중지 동작을 제공합니다. 연결을 늦게 시작하거나 중단하면 서버 이벤트의 실시간 알림이 지연됩니다. 정기 배치 동기화와 구별되는 사용자 설정 서버의 이벤트 수신 연결입니다.

manifest의 subtype과 일치한다. 다만 사용자 지정 서버라는 사정만으로 specialUse가 자동 승인되는 것은 아니다. 지연 가능한 조회가 아니라 지속 연결이 핵심 기능에 필요한 이유, FCM/다른 API를 적용하기 어려운 구체적 근거는 운영 설명과 함께 보완해야 한다. [Android specialUse 설명](https://developer.android.com/develop/background-work/services/fgs/service-types).

**동영상 준비 항목**

| 유형 | 실제 배포 후보에서 촬영할 장면 | 상태 |
|---|---|---|
| dataSync | Standalone 설정 → 동기화 시작 → 진행 알림 → 홈으로 이동 후 진행 → 완료/중지. 만족도 제출 경로는 운영 데이터 변경 없이 심사용 환경에서 추가 입증 | 미촬영 |
| specialUse | Client 서버 설정 → 백그라운드 서버 연결 시작 → 연결 지속 알림 → 서버 테스트 이벤트 수신 → 알림의 중지 | 미촬영 |
| shortService | 플러그인 선언만으로 실행을 주장하지 않음. 현재 앱 예약은 일반 WorkManager 작업 | Console에 추가 항목이 표시되는지 확인 필요 |
| location | geolocator 서비스 선언은 기존부터 존재, 앱은 단발 현재 위치 사용 | 현재 코드로 location FGS 사용을 선택할 근거 없음. 최종 AAB/실기기와 Console 자동 감지 결과 재확인 |

### 4.3 배터리 최적화 제외·위치·전화·저장소

| 항목 | 답변 초안 / 판단 |
|---|---|
| 배터리 최적화 제외 | “사용자가 설정한 서버 이벤트 수신과 알림 기반 신고 갱신을 절전 중에도 이어가기 위한 설정입니다.” **확인 필요:** 제외가 없으면 핵심 기능이 왜 불가능한지 입증해야 함. 앱 이름에 ‘안전’이 들어간다고 생명·신체 보호용 safety app 예외로 답하지 않음. WorkManager 정기 업로드만을 이유로 예외 필요성을 주장하지 않음 |
| 위치 | “신고 지도에서 사용자의 현재 위치로 이동하기 위해 사용 중 위치 권한을 요청합니다. 지속적인 백그라운드 위치 추적 기능은 없습니다.” 신고 지점 공유 및 타일 통신은 데이터 보안 답변에서 별도 공개 |
| 알림 표시 | “감지한 신고, 동기화/크롤링 진행·결과, 로그인 점검 결과를 표시합니다.” 알림 접근 권한과 분리 |
| 전화 | “처리 답변에 포함된 담당 연락처를 사용자가 눌러 전화 앱으로 엽니다.” 직접 발신이 필요하다는 단정은 불가. CALL_PHONE의 필요성 재검토 권고, 이 조사에서 제거하지 않음 |
| 저장소 | “사용자가 선택한 DB 백업/복원, Excel 및 내려받은 파일을 열고 공유합니다.” All files access/사진·동영상 전체 접근 선언의 신규 근거 없음 |

배터리 예외는 [Android의 허용 사용 사례](https://developer.android.com/training/monitoring-device-state/doze-standby)를 기준으로 확인한다. 권한 화면은 ‘나중에 설정하기’를 제공하므로 해당 권한 전부를 앱 이용의 강제 조건이라고 설명하지 않는다(`permission_screen.dart:349`). 카카오 인증·공유 동의 필수 조건과 다르다.

### 4.4 데이터 보안 양식

**상위 답변 초안**

| Console 질문 | 현재 코드에 근거한 초안 |
|---|---|
| 사용자 데이터를 수집 또는 공유하는가? | **예** |
| 계정 생성 방법 | **OAuth**(카카오 → Supabase 앱 계정). 기존 안전신문고 ID/비밀번호 로그인도 존재함을 접근 설명에 기재. 신규 Supabase 사용자 생성 설정 확인 필요 |
| 수집 데이터가 전송 중 모두 암호화되는가? | **보수적으로 아니요 / 확인 필요.** 공식·Supabase는 HTTPS이나 사용자 지정 HTTP/WS 지원이 있음 |
| 사용자에게 데이터 삭제 요청 방법을 제공하는가? | 공개 안내에 공유자료 삭제 문의는 있음. **앱 계정 삭제 및 연결 데이터 전체 삭제 제공으로 ‘예’ 확정 불가** |
| 독립 보안 검토 | 이 조사에서는 검토 인증 근거 없음. 인증받았다고 선택하지 않음 |

아래는 코드의 데이터 흐름을 Console 분류에 대응시킨 **입력 후보**다. ‘공유’ 열은 전송·공개 사실과 Console의 예외 적용을 구분한다. 서비스 제공자 처리·사용자 동작/적절한 고지와 동의 예외가 충족되는지 확인하기 전 일괄 ‘공유 안 함’으로 답하지 않는다. 로컬 처리와 가명 식별자도 구분한다. [Data safety 정의와 양식](https://support.google.com/googleplay/android-developer/answer/10787469).

| 분류 후보 | 수집 답변 초안 | 필수/선택·목적 | 공유 및 확인사항 |
|---|---|---|---|
| 개인정보 — 사용자 ID | 예: Supabase ID, 카카오 회원번호, 공식 계정 ID/파생 dataset_key, 연결 계정 식별 | 일반 사용 필수. 계정 관리·앱 기능·보안 | Supabase의 수탁 처리 관계, 공식 사이트/사용자 서버 전송의 예외 여부 확인. 공개 익명 처리로 수집 제외 불가 |
| 개인정보 — 이름 | 예: 닉네임, 공유 신고의 담당자 이름 | 닉네임 scope 확인, 신고 공유는 필수. 계정 관리·앱 기능 | 담당자명은 제3자 데이터. 공개 범위 확인, “이름을 수집하지 않음” 불가 |
| 개인정보 — 이메일 주소 | **운영 scope 확인 후 결정** | 제공 시 계정 관리, 공개 안내상 이메일 미제공도 연결 가능 | 앱에 원문을 안 저장해도 Auth 서버 수집은 따로 판단 |
| 개인정보 — 전화번호 | 예: 만족도 조회/제출에 사용자 입력 번호 전송 | 해당 기능 사용 시. 앱 기능 | 안전신문고 수신. 자동 전화번호 읽기 권한은 없음 |
| 개인정보 — 기타 정보 | 차량번호 원문·기기 표시 이름 등의 대응 분류 검토 | 신고 공유 필수. 앱 기능 | 번호 원문 수집과 공개 마스킹 구분. 데이터가 신고자 이외 사람을 가리킨다는 점 확인 |
| 위치 — 정확한 위치 | 신고 좌표가 계정과 연결되어 업로드됨을 공개. Console 분류 적용 **확인 필요** | 신고 공유 필수. 지도·공유 기능 | 신고 지점은 현재 기기 위치와 다름. 좌표 공개·단건 노출 확인 |
| 위치 — 대략적 위치 | 현재 위치에 따른 지도 타일/IP 처리의 해당 여부 **확인 필요** | 현재 위치 기능 선택. 지도 기능 | 타일 제공자의 로그·위치 추론 범위 검토. 단순 GPS 비전송만으로 전체 위치 ‘아니요’ 결정 금지 |
| 앱 활동 — 기타 사용자 제작 콘텐츠/기타 활동 | 예: 신고 정보, 만족도 점수·선택 사유, 공유 동의·전송 트리거 | 공유 자료는 필수, 사유/평가 제출은 선택. 앱 기능 | 커뮤니티는 숫자 별점만 수집. 사유 원문은 공식 사이트/사용자 서버로 전송 |
| 금융 정보 — 기타 금융 정보 | 과태료·범칙금 확정 금액의 해당 여부 **확인 필요** | 신고 공유에 포함. 앱 기능 | 결제/계좌/대출 정보는 아님. 제3자 처분금액과 공개 통계의 민감성 검토 |
| 기기 또는 기타 ID | 예: 연결 ID/secret, 기기 연결 식별·dataset 관련 식별자 | writer 연결·계정 관리·보안 | 광고 ID·IMEI 사용과 다름. 정확한 Console 매핑은 확인 |
| 파일 및 문서 | Client DB 복원 업로드·파일 공유 경로 포함해 예 후보 | 사용자 선택, 백업/복원·앱 기능 | 로컬 백업만은 수집 아님. 서버 업로드는 외부 전송. 사용자 선택 공유 예외 검토 |
| 사진/동영상 | 커뮤니티 신고 업로드에는 없음. **카카오 프로필 사진 수집 여부 확인 필요** | 로그인 scope에 따라 결정 | 공식 첨부 다운로드·로컬 열람과 외부 업로드 구분 |
| 메시지 | title/text 로컬 분석, 추출 신고번호만 전송 | 알림 감지 선택, 앱 기능 | 본문 전체를 수집한다고 과장하지 않음. 추출 번호의 콘텐츠 분류는 확인 |
| 앱 정보·성능/진단 | 자동 Crash/Analytics 전송 SDK 근거 없음 | 사용자가 GitHub 제보 시 버전·OS 등 포함 | Supabase/서버 운영 로그·IP·오류정보 보관은 운영 확인 필요 |

보관 성격: Supabase 계정·커뮤니티 공유 자료는 기능상 지속 보관이므로 단순 ‘일시 처리’로 답하지 않는다. 폰의 리뷰 요청 횟수·로컬 알림 기록·로컬 DB만을 이유로 외부 분석 수집을 추가하지 않는다. 정확한 보유기간은 중앙 운영 정책/삭제 실행과 대조해야 한다.

**사용자용 데이터 처리 설명 초안**

> 카카오 계정으로 앱 사용자를 확인하고 신고내용 공유 동의를 관리합니다. 동의한 신고의 원래 처리 결과, 신고 위치, 처리기관·담당자, 차량번호와 신고 식별정보 등을 커뮤니티 서버로 보내 지도와 통계를 제공합니다. 신고 수집 후 및 예약된 백그라운드 작업에서도 전송할 수 있습니다. 차량번호 원문과 신고번호를 서버가 처리하는 범위 및 공개 시 표시 방식은 개인정보처리방침과 공유 동의문에서 안내합니다. 기기의 현재 위치는 지도 이동에 사용하며, 지도 배경을 불러오기 위해 외부 타일 서비스를 이용합니다.

실제 공개 정책·보유기간·수탁사·연락처를 검증한 후 완성해야 한다. 현재 기술 안내를 그대로 정본 방침으로 제출하지 않는다.

### 4.5 계정 삭제 / 삭제 URL

현재 제출 가능한 정직한 설명:

> 앱 설정의 ‘동의 철회’로 공유 자료의 공개를 중단할 수 있습니다. ‘카카오 로그아웃’은 이 기기의 세션과 조건에 따른 로컬 신고 자료를 정리합니다. 현재 앱 안의 공유자료 삭제 버튼은 활성화되어 있지 않습니다. 공개 안내는 공유자료 삭제 문의를 커뮤니티 지도 문의 게시판으로 안내하고 있으나, 앱 계정 삭제 및 연결 데이터 삭제 절차는 확인 중입니다.

**계정 삭제 URL: `[실제로 사용 가능한 계정·연결 데이터 삭제 요청 URL 확인 후 입력]`**. 일반 홈페이지나 자기 자신을 가리키는 개인정보 안내를 삭제 URL로 임의 기입하지 않는다.

카카오로 외부 가입 흐름을 열어 Supabase 앱 계정을 만드는 방식이라면 계정 삭제 요구 범위에 포함된다. Demo 제공만으로 이 의무가 없어지지는 않는다. 앱 안에서 삭제 웹 페이지로 연결하는 경로도 가능하므로 별도 네이티브 삭제 기능만이 유일한 해법은 아니다. 실제 운영 계정 생성 설정과 삭제 지원 범위를 확정해야 한다. [앱 계정 삭제 요구사항](https://support.google.com/googleplay/android-developer/answer/13327111).

### 4.6 앱 액세스 — 심사용 접근 안내

**선택 초안: ‘일부 또는 모든 기능이 제한됨’.** 새 설치의 **첫 연결 방식 선택 화면에 ‘Demo 보기’ 버튼이 보인다. 숨은 제스처가 아니다.** `setup_screen.dart:369`, `main.dart:315`가 근거다.

별도 데모 자격 증명 우회도 존재한다: 안전신문고 로그인/재로그인 입력에서 ID=`demo`, PW=`demo`, 전화번호는 빈칸 또는 `demo` (`local_db_service.dart:106`, `setup_screen.dart:60`, `:168`; `settings_screen.dart:470`). 이는 합성 데이터용 공개 테스트 상수이며 실제 사용자 자격 증명이 아니다. 최초 설치에서 Standalone을 먼저 누르면 카카오 게이트로 이동하므로 **첫 화면의 Demo 버튼을 우선 안내**한다.

**한국어 안내 초안**

> 앱을 처음 실행하면 연결 방식 선택 화면이 표시됩니다. ‘Client 모드’, ‘Standalone 모드’ 아래의 ‘Demo 보기’를 누르세요. 별도의 계정이나 서버 없이 합성 신고 100건으로 대시보드·신고내역·관리·통계·지도·알림 및 설정 화면을 확인할 수 있습니다. 화면 데이터는 실제 민원 자료가 아닙니다. Demo에서는 실제 크롤링/동기화, 만족도 제출, 카카오 인증·공유 업로드와 관련 백그라운드 동작을 실행하지 않습니다.

**Console용 영어 안내 초안**

> On first launch, open the connection mode selection screen and tap “Demo 보기” (View Demo), below the Client and Standalone options. No credentials or server are required. The demo contains 100 synthetic reports for reviewing the dashboard, report lists, management screens, statistics, map, notifications and settings. It does not execute live synchronization/crawling, satisfaction submissions, Kakao sign-in, community uploads or their background services. For these restricted features, use the additional review access instructions and test environment provided below: [verified reusable test access details to be supplied in Play Console].

**Demo만으로 모든 기능 검수가 가능하다고 쓰지 않는다.** 카카오 OAuth·필수 동의·Client 서버·FGS·업로드의 심사용 환경과 재사용 가능한 접근 정보가 별도로 필요하다. 실제 비밀번호는 이 문서에 넣지 않는다. 접근 정보는 영어, 지역 무관·항상 사용 가능, OTP 등 장애 없는 방식으로 준비해야 한다. [심사용 로그인 정보 요구사항](https://support.google.com/googleplay/android-developer/answer/15748846).

### 4.7 광고 ID / 광고 포함 여부 / 평가 요청

- 광고 ID 사용: **아니요 초안**. AD_ID 권한과 광고 SDK/API 사용 근거가 없다. WorkManager 연결 ID나 카카오 계정 ID를 광고 ID로 답하지 않는다. 최종 배포 AAB 및 다른 활성 트랙에 광고 SDK가 없는지도 확인한다. [광고 ID 설명](https://support.google.com/googleplay/android-developer/answer/6048248).
- 광고 포함: 현재 앱 코드 기준 **아니요 초안**. 외부 홈페이지·GitHub 링크를 곧바로 광고로 분류하지 않는다. 실제 스토어/웹 랜딩 페이지의 수익화·광고 노출은 별도 확인한다.
- Play 리뷰 요청: 추가된 in_app_review는 Google UI로 사용자 별점/리뷰를 처리한다. 로컬 요청 횟수와 신고 결과를 개발자 분석 서버에 보내는 코드는 없다. 사용자 리뷰 자체는 Google에 전달되므로 ‘리뷰도 전혀 전송되지 않는다’는 설명은 피한다. Google 리뷰 데이터 처리 내용을 양식 검토에 포함한다. [In-App Reviews 데이터 처리](https://developer.android.com/guide/playcore/in-app-review).
- 코드에 만족도 선질문·리뷰 보상은 없지만 긍정적인 신고 결과 및 오류 없는 세션만 자동 요청 대상으로 고른다. 이 조건의 정책 적합성은 **확인 필요**이며 ‘정책 위반 확정’으로 단정하지 않는다. 수동 ‘Play 스토어에서 평가하기’는 조건 없이 스토어 페이지를 연다.

### 4.8 대상 연령 / 콘텐츠 등급 / 커뮤니티 콘텐츠

**대상 연령 초안(운영자의 대상 확인 전 미확정):** “성인 사용자가 자신의 신고 내역을 조회·관리하는 도구이며 어린이를 주 대상으로 설계하지 않았습니다.” 실제 대상이 성인으로 확정되면 18세 이상 선택을 검토한다. 운전자용 기능이나 개인정보가 있다는 이유만으로 법정 연령 제한·IARC 등급을 임의 확정하지 않는다. 기존 Console 대상 연령과 실제 사용자·스토어 표현을 대조한다. [대상 연령 설정](https://support.google.com/googleplay/android-developer/answer/9867159).

커뮤니티 지도는 앱에서 외부 브라우저로 열지만 사용자의 신고 결과를 서버에 공유하는 기능은 앱 안에 있다. 콘텐츠 등급/UGC 질문에 “사용자 데이터 공유 기능 없음”으로 자동 답하지 않는다. 자유게시판·실시간 채팅 기능은 없으며, 신고 데이터 공개와 외부 사이트의 신고/운영자 조치 경로가 충분한지는 **확인 필요**다. 외부 플랫폼으로 안내하는 클라이언트도 정책 범위에 포함될 수 있으므로 브라우저로 연다는 사실만으로 제외하지 않는다. [UGC 정책](https://support.google.com/googleplay/android-developer/answer/9876937).

### 4.9 금융 기능 / 정부 앱 선언 / 스토어 설명

**금융 기능:** “이 앱은 금융 기능을 제공하지 않습니다.” 초안. 처분 답변의 과태료·범칙금 금액과 통계를 표시할 뿐 결제·납부·송금·대출·투자·금융 조언을 제공하지 않는다. **금융 기능 없음**과 **금액 데이터 처리 없음**은 다른 답이다. [금융 기능 선언 안내](https://support.google.com/googleplay/android-developer/answer/13849271).

**정부 앱 여부:** “정부기관이 개발하거나 정부기관을 대표하는 앱이 아닙니다.” 초안. 공식 서비스 제공 권한을 받았다는 근거가 없는 상태에서 정부 인증 앱으로 표시하지 않는다.

**스토어 설명에 넣을 문장**

> 나만의 안전신문고는 안전신문고에 이미 접수한 신고를 조회·정리하는 개인 개발자의 비공식 앱입니다. 행정안전부 또는 정부기관을 대표하거나 대행하지 않습니다. 신규 신고 접수 기능은 제공하지 않습니다. 정부 정보의 공식 출처는 안전신문고(https://www.safetyreport.go.kr/)이며, 원문과 실제 민원 처리는 공식 서비스를 확인해 주세요.

앱 내부에는 상세 시트와 설정 > 앱 정보에 비공식 고지·공식 링크가 있다(`report_detail_sheet.dart:544`, `settings_screen.dart:2046`, `:2080`). 스토어 상세 설명·이미지·아이콘도 같은 의미여야 한다. [정부 정보를 전달하는 비공식 앱 요구사항](https://support.google.com/googleplay/android-developer/answer/9514050).

## 5. 제출 전 확인 필요 목록

| 우선순위 | 확인할 항목 | 완료를 판단할 증거 |
|---|---|---|
| 높음 | 앱 계정 삭제 및 연결 데이터 삭제 | 앱에서 찾을 수 있는 삭제 요청 경로, 설치 없이 가능한 웹 URL, 본인확인·완료 처리·보유 예외. 동의 철회/로그아웃과 구분. [계정 삭제 정책](https://support.google.com/googleplay/android-developer/answer/13327111) |
| 높음 | 정본 개인정보처리방침 | 현재 안내 페이지의 자기참조 해소, 실제 방침에 앱/운영자·연락처·데이터·수신자·보유/삭제 명시, 앱과 Console 링크 확인. [User Data 정책](https://support.google.com/googleplay/android-developer/answer/10144311) |
| 높음 | 중앙 동의문과 업로드 범위 일치 | 현재 정책 본문/해시, 차량번호 원문·신고번호·법규·별점·기관코드·담당자명·위치·백그라운드 전송의 설명. 공개 정밀도·마스킹·접근제어는 중앙 코드/실행 근거 |
| 높음 | 암호화 답변 | 사용자 서버 HTTP/WS 허용 경로의 실제 운영·예외 판단. “전부 암호화” 체크를 저장소 암호화만으로 결정하지 않음. [Data safety](https://support.google.com/googleplay/android-developer/answer/10787469) |
| 높음 | 심사용 전체 기능 접근 | Demo 외 기능의 재사용 가능한 카카오/서버 테스트 접근, 영문 안내, OTP/지역 제한 처리. Demo 제한을 명시. [심사 접근](https://support.google.com/googleplay/android-developer/answer/15748846) |
| 높음 | FGS 선언·동영상 | dataSync/specialUse 각각 실행·알림·백그라운드·중지/종료 영상. 실제 AAB와 일치. [FGS 요구사항](https://support.google.com/googleplay/android-developer/answer/13392821) |
| 중간 | WorkManager shortService 선언 | 실제 Console 검출 여부, 플러그인의 비표준 권한 문자열 검토. 일반 periodic 작업을 상시 FGS로 설명하지 않음 |
| 중간 | 배터리 예외·알림 접근 고지 | 필수 핵심 기능과 예외 필요성, 권한 직전 데이터/전송 설명. [Doze 예외](https://developer.android.com/training/monitoring-device-state/doze-standby) |
| 중간 | Kakao/Supabase 실제 수집 | nickname/email/profile image scope, 생성되는 앱 계정·IP/운영 로그·보유기간·위탁 관계. 앱 파서와 중앙 수집의 차이 |
| 중간 | 위치·금액·제3자 정보 분류 | 신고 지점 좌표와 기기 현재 위치 구분, OSM 요청 정보, 차량번호·담당자·처분 금액의 Console 분류/공개 적합성 |
| 중간 | 대상 연령·UGC·리뷰 요청 | 실제 제품 대상 및 공개 커뮤니티 데이터 운영 절차, 긍정 결과만 고르는 리뷰 트리거 정책 검토 |
| 최종 산출물 | 제출 AAB 재비교 | 이번 매니페스트와 최종 서명 AAB의 권한/type/SDK/설정 동일성, 기존 Play 활성 트랙의 Data safety 포함 범위. 실제 release 설치·영상은 이번에 미실행 |

## 6. 근거와 검증 기록

### 6.1 산출물

- `evidence/old-release-merged-manifest.xml`, `new-release-merged-manifest.xml`: release 병합본 전체.
- `evidence/v1.3.5-published-manifest.xml`: 공개 APK에서 추출한 설치 선언.
- `evidence/old-manifest-merger-report.txt`, `new-manifest-merger-report.txt`: 각 권한/컴포넌트의 플러그인·AndroidX 출처.
- `evidence/old-processReleaseManifest.log`, `new-processReleaseManifest.log`: 성공 로그.
- `evidence/old-pub-get.log`, `new-pub-get.log`, `old-pubspec-lock.diff`, `new-pubspec-lock.diff`: 의존성 재현 조건.
- `evidence/manifest-facts.json`: 권한·SDK·컴포넌트·queries 추출 자료.
- `evidence/verification.txt`: 권한/SDK/컴포넌트 개수 및 증거 링크 검증 결과.
- `evidence/github-release.json`, `v1.3.5-published-apk.sha256`: 공개 릴리즈 및 APK 식별.
- `evidence/privacy.html`, `privacy-doc.js`: 공개 개인정보 안내와 정본 링크 자기참조 근거. HTTP 200, 2026-10-05 조회.

### 6.2 주요 코드 근거 색인

| 범위 | a19aa950 기준 경로:줄 |
|---|---|
| 앱 권한·서비스·OAuth·queries | `android/app/src/main/AndroidManifest.xml:4`, `:10`, `:50`, `:80`, `:92`, `:103`, `:116` |
| 버전·SDK 상속·서명 분리 | `pubspec.yaml:19`; `android/app/build.gradle.kts:22`, `:32`; `android/settings.gradle.kts:22` |
| 알림 수신·전송 | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt:44`, `:75`, `:107`, `:116`, `:149` |
| 백그라운드 Application | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/SafetyReportApplication.kt:13`, `:40` |
| 권한 사용 설명·나중에 설정 | `lib/screens/permission_screen.dart:195`, `:268`, `:349`; `lib/services/permission_service.dart:70` |
| Auth 세션·scope·필드 | `lib/services/community_auth_service.dart:160`, `:308`, `:376`, `:878`, `:901`, `:1009`; `lib/services/community_auth_config.dart:47` |
| 인증·동의 필수 | `lib/main.dart:309`; `lib/community/gate/gate_state.dart:60`, `:96` |
| 기기/계정 식별·전송 | `lib/community/gate/gate_state.dart:35`; `lib/community/gate/community_account_client.dart:89`; `lib/community/gate/community_gate.dart:674` |
| 신고 payload·envelope | `lib/community/capture/observation_rules.dart:280`; `lib/community/capture/report_adapter.dart:10`; `lib/community/upload/community_uploader.dart:1333`; `lib/community/upload/community_ingest_client.dart:30` |
| 정기 실행 | `lib/community/upload/community_schedule.dart:70`; `lib/services/background_login_check.dart:134`; `lib/providers/report_provider.dart:727` |
| 위치와 외부 타일 | `lib/screens/report_map_screen.dart:52`, `:308`, `:365`, `:1028` |
| 공식 로그인/만족도 | `lib/services/standalone_auth_service.dart:228`, `:356`, `:394`; `lib/services/standalone_api_service.dart:371`; `lib/services/rating_service.dart:167` |
| 삭제·철회·로그아웃 | `lib/widgets/community_account_card.dart:479`, `:561`, `:685`; `lib/community/kakao_logout.dart:90`; `lib/community/gate/community_account_client.dart:131` |
| Demo | `lib/screens/setup_screen.dart:60`, `:99`, `:369`; `lib/services/local_db_service.dart:106`; `lib/main.dart:315` |
| 리뷰 | `lib/services/review_prompt_service.dart:16`, `:56`, `:63`, `:96`, `:111` |
| 개인정보 안내·정부 고지 | `lib/screens/community_onboarding_screen.dart:51`, `:304`; `lib/widgets/report_detail_sheet.dart:544`; `lib/screens/settings_screen.dart:2046`, `:2080` |

보조 자료인 `handoff/mobile-feature-inventory-raw.md` 및 `feature-inventory.csv`는 기능 발견에 사용했으며, 그 자료의 기준 커밋(c61db24f)과 본 검토 기준(a19aa950)이 다르므로 코드·병합본을 우선했다. architecture 문서도 설명용이고, 예전 ‘업로더 없음’·삭제 버튼 설명·Client 세션 일반화처럼 현행 코드와 다른 부분은 본문에서 교정했다.

**실제 검증 완료:** 양 버전 release 매니페스트 병합, 공개 APK 매니페스트 추출 및 핵심 집합 동등성, 정적 데이터 흐름·UI 접근 코드 대조, 공식 정책 웹 문서 조회, 공개 개인정보 안내 HTTP 조회.

**NOT_RUN / 미검증:** 새 APK/AAB 전체 빌드·서명·설치, 실기기 권한/FGS 동작, 실제 Kakao/Supabase 로그인·운영 업로드/삭제, 현재 중앙 동의문 조회, Play Console 기존 답변/제출·심사, 데모 실기기 실행·시연 영상. 저장소 파일·CHANGELOG는 수정하지 않았다.
