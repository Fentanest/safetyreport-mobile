# 2026-09-27 flutter_secure_storage 9 → 10 (Play H2.h.b 수정 1단계) — GPT-6-Sol 검토 기록

검토자: GPT-6-Sol(읽기 전용). 결정: 사용자 2단계 승인(이번 10, 다음 11 + file_picker 13), 카카오 로그인 필수(로그인 정보 지워 우회하는 경로 없음).

| 차수 | 결과 | 반영 |
|---|---|---|
| 1 | 높음 1(v10 설치만으로 이관 보장 안 됨)·중간 2 | 포그라운드 시작 때 이관 + 표시, 백그라운드는 표시 전 보안 저장소 미사용 |
| 2 | 높음 1(읽기 성공만으로 표시)·중간 1 | 네이티브가 옮겨지지 않은 v9 ESP 항목 0개일 때만 표시 |
| 3 | 높음 없음·중간 1(폴백 중 쓰기) | 쓰기 차단 시도 → 4차에서 문제 |
| 4 | 높음 1(3회 해제)·중간 2 | 설계 변경: 미확인이면 평소 화면 대신 복구 화면 |
| 5 | 높음 없음·중간 2(초기화 버튼 관련) | 사용자 결정으로 초기화 버튼 제거(복구 화면은 재시도만) — 두 지적의 대상이 사라짐 |

실측(에뮬레이터 API 35): 별도 시험 앱으로 v9 쓰기 순서 4가지 × v10 첫 초기화 순서 2가지 + 기본 옵션만 → 값 일치(.agent-runs/upload-r8-20260927/fssmig),
실제 앱 디버그 빌드 v9 → v10 제자리 업데이트(로그인 대기 값 이관·표시), 복구 화면 경로. 미확인: iOS 실기기, 이관 중 강제 종료, Keystore 고장 기기.

## 1차 원문

## 검토 결과

**새 높음/중간 위험이 있습니다.** 정상적인 단일 접근에서는 제공된 에뮬레이터 실측과 소스가 일치합니다. 아래 항목은 그 시험이 다루지 않은 경로입니다.

- **높음 — v10 설치만으로 v11 이관이 보장되지 않습니다.** [data-contracts.md](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/docs/architecture/data-contracts.md:165), [android-runtime.md](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/docs/architecture/android-runtime.md:261): v10 이관은 *첫 보안 저장소 접근 때* 실행됩니다. v9 자료가 있는 사용자가 v10을 설치해도 해당 접근 없이 v11로 업데이트하면 자료가 남습니다. v10을 아예 건너뛰는 업데이트도 가능합니다. **재현:** v9에서 자격증명 저장 → v10 설치 후 보안 저장소 미접근 → v11 업데이트. **방향:** 다음 릴리즈 전에 실제 이관 완료를 확인할 방법과, 미이관 설치본을 위한 v11의 호환 경로 또는 명시적인 재로그인·연결 재설정 절차가 필요합니다. “대부분이 v10을 거침”은 자료 보존 조건이 아닙니다.

- **중간 — 이관 실패 시 ESP 복귀 경로가 읽기를 복구하지 못할 수 있습니다.** [FlutterSecureStorage.java](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:229): 실패하면 ESP를 `preferences`로 선택하고 성공을 반환하지만, [읽기 경로](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:72)는 `migrateOnAlgorithmChange=true`인 한 ESP 평문을 새 cipher로 해독하려 합니다. **재현:** 첫 이관 중 cipher 초기화 또는 항목 암호화를 실패시키고 기존 키를 읽기. 예외가 나거나 값을 읽지 못할 수 있습니다. **방향:** 이관 실패를 성공으로 취급하지 않도록 플러그인 수정 또는 앱의 오류 대응을 확인하고, 장애 주입 시험을 거쳐야 합니다. `resetOnError` 기본값은 false이므로 [오류 처리기](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:1486)가 자동 삭제하지는 않습니다. 이를 true로 바꾸면 삭제 경로가 열리므로 이관 대책으로 권하지 않습니다.

- **중간 — 앱과 WorkManager의 동시 첫 접근은 직렬화되지 않습니다.** [FlutterSecureStoragePlugin.java](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStoragePlugin.java:28): 저장소 캐시와 작업 스레드는 플러그인 인스턴스별입니다. 백그라운드 Flutter 엔진과 앱 엔진이 동시에 처음 열면 각각 이관을 시작할 수 있습니다. 새 AES 키를 읽고 없으면 생성하는 과정에도 [공유 잠금이 없습니다](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/ciphers/StorageCipherImplementationGCM.java:39). **재현:** v9 자료가 있는 앱을 업데이트하고 앱 시작과 WorkManager 작업을 동시에 실행해 첫 읽기를 경쟁시킴. 키 또는 항목 이관 경쟁으로 일부 값이 읽히지 않을 가능성이 있습니다. 이는 소스로부터의 위험 추론이며 제공된 실측으로 재현된 결함은 아닙니다. **방향:** 두 엔진 동시 첫 접근 시험과, 이관 완료 전 백그라운드 접근을 막거나 네이티브 측 이관을 직렬화하는 조치가 필요합니다.

**낮음/관찰:** [이관 루프](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:1437)는 항목마다 새 값 쓰기와 ESP 값 삭제를 따로 수행합니다. 프로세스 종료 뒤 남은 ESP 항목을 재시도할 여지는 있지만, 이관 전체가 원자적이지는 않습니다. `migrateWithBackup`을 켜도 [ESP 경로는 같은 항목별 복사·삭제 루프](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:1390)를 사용하므로 이 위험의 해결책으로 볼 수 없습니다. 두 옵션의 번갈아 사용은 같은 이름의 네이티브 인스턴스를 공유하며, 현재 두 설정 모두 이관 기본값이 같아 실측 범위에서는 별도 문제를 찾지 못했습니다.

**iOS:** 소스상 현재 앱의 기본 옵션으로 저장한 v9 항목은 darwin 0.3.2가 읽습니다. 두 버전의 기본 서비스명은 `flutter_secure_storage_service`, 접근성은 `unlocked`이고([v9 옵션](/home/better0101/.pub-cache/hosted/pub.dev/flutter_secure_storage-9.2.4/lib/options/apple_options.dart:26), [v10 옵션](/home/better0101/.pub-cache/hosted/pub.dev/flutter_secure_storage-10.3.4/lib/options/apple_options.dart:69)), darwin은 같은 서비스명·계정 키로 Keychain을 조회합니다([조회 코드](/home/better0101/.pub-cache/hosted/pub.dev/flutter_secure_storage_darwin-0.3.2/darwin/flutter_secure_storage_darwin/Sources/flutter_secure_storage_darwin/FlutterSecureStorage.swift:459)). iOS 실기기 업데이트 시험은 아직 없으므로 실제 동작까지 확인된 것은 아닙니다.

**v11 전 조건:** 실제 앱에 v9 자격증명을 채운 제자리 업데이트, 동시 첫 접근·이관 중 종료·Keystore 실패 시험을 통과시키고, **v10에서 이관되지 않은 설치본의 v11 진입 경로**를 확정해야 합니다. 파일 수정이나 네트워크 접근은 하지 않았습니다.

## 2차 원문

## 재확인 결과

**새 높음 1건·중간 1건이 있습니다.** 정상 이관 때의 시작 순서와 백그라운드 차단은 의도대로 배치됐습니다.

- **높음 — 이관 표시가 성공을 잘못 인증할 수 있습니다.** [secure_storage_migration.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/secure_storage_migration.dart:39)는 `community_session_v1`과 `community_connection_v1`의 읽기가 *예외 없이 끝나기만* 하면 표시를 남깁니다. 예를 들어 v9에 `standalone_password`만 있고 그 항목의 이관이 실패하면, 플러그인은 [ESP로 복귀하면서 성공을 반환](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:234)할 수 있습니다. 검사하는 두 키는 없으므로 둘 다 `null`로 읽혀 표시가 `true`가 됩니다. ESP 초기화 실패를 삼키고 새 저장소로 진행하는 [경로](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:263)에서도 같은 문제가 가능합니다. **방향:** 두 키의 `read` 성공만으로 이관 완료를 표시하지 말고, 플러그인이 ESP 확인·이관 결과를 오류로 전달하거나 완료 상태를 노출하게 해야 합니다. 현재 표시는 v11의 안전한 판정 근거가 아닙니다.

- **중간 — 이관 실패 후에도 포그라운드의 일반 보안 저장소 사용이 시작됩니다.** [main.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/main.dart:50)는 `ensureMigrated()`의 `false`를 확인하지 않고 계속 진행합니다. 이후 로그인 복귀 링크 처리나 게이트가 보안 저장소를 열 수 있습니다. **재현:** 첫 이관 읽기에 예외를 발생시킨 뒤 앱 시작을 계속 진행. **방향:** 실패 상태에서는 보안 저장소를 사용하는 흐름을 보류하고 재시도·오류 안내 경로를 마련해야 합니다. “다음 시작에 재시도”만으로는 현재 실행 중의 접근을 막지 못합니다.

**순서 확인:** `main()`의 이관은 `Workmanager().initialize`, `CommunityAuthLinkChannel.start`, `ReportProvider.init`, 게이트 생성, `runApp`보다 앞섭니다. Android 로그인 링크는 네이티브에서 보관했다가 Dart의 채널 등록 뒤 전달됩니다. 확인한 프로덕션 WorkManager 진입점은 업로드와 하루 1회 로그인 점검뿐이며, 둘 다 표시를 확인한 뒤 보안 저장소 사용 경로로 갑니다([background_login_check.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/background_login_check.dart:59)). **정상적으로 이관이 끝나는 경우**, 그 전에 다른 코드가 보안 저장소를 여는 경로는 찾지 못했습니다.

v11의 표시 없는 설치본 안내는 현재 [문서상의 릴리즈 조건](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/docs/architecture/data-contracts.md:170)입니다. v11 구현 때 별도로 확인해야 합니다. 이번에는 읽기 전용 요청에 따라 시험 명령을 실행하지 않았습니다.

## 3차 원문

## 3차 검토 결과

**새 높음은 없습니다. 중간 위험 1건은 남아 있습니다.** 접두사 없는 항목을 세는 방식은 일반적인 ESP 이관 실패와 부분 이관을 잡습니다. 제공한 실제 앱의 제자리 업데이트 결과도 이 정상 경로와 일치합니다.

- **중간 — 이관 실패 뒤 자격증명 쓰기를 허용하는 판단은 받아들이기 어렵습니다.** [main.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/main.dart:50)는 이관 실패 뒤에도 앱을 진행합니다. 플러그인이 [ESP로 폴백](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:234)했지만 새 cipher는 초기화된 상태라면, 이후 [쓰기 경로](/tmp/claude-1000/-home-better0101-projects-safetyreport/aa9d30e6-e7a5-4376-8fce-c9fb26682fbe/scratchpad/plugins/fss-10.3.4/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java:125)는 값을 새 cipher로 암호화해 **ESP 안에** 씁니다. 다음 시작의 이관은 그 암호문을 평문 값처럼 다시 옮길 수 있습니다. 예를 들어 실패 뒤 사용자가 [다시 로그인해 비밀번호를 저장](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/standalone_auth_service.dart:268)하면 재시도 후 읽는 값이 원래 비밀번호가 아닐 수 있습니다. **방향:** 표시가 없는 동안 앱 전체를 막을 필요는 없지만, 로그인·커뮤니티 연결 등 보안 저장소를 쓰거나 지우는 흐름은 보류하거나 플러그인의 폴백 읽기·쓰기를 수정해야 합니다. “기존 ESP 항목이 남고 다음 시작에 재시도한다”는 새 쓰기의 안전성까지 보장하지 않습니다.

**판정의 한계:** [네이티브 계수기](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:305)는 ESP 항목이 하나라도 남으면 표시를 거부하므로 부분 이관에 대해 보수적입니다. 반면 v9가 알고리즘 변경 때 같은 파일에 쓸 수 있는 `FlutterSecureSAlgorithmKey/Storage` 같은 일반 메타 키도 ESP 잔여 항목으로 셉니다([v9 저장 코드](/home/better0101/.pub-cache/hosted/pub.dev/flutter_secure_storage-9.2.4/android/src/main/java/com/it_nomads/fluttersecurestorage/ciphers/StorageCipherFactory.java:86)). 그런 설치본에서는 자료가 읽혀도 표시가 계속 없는 **거짓 음성**이 가능합니다. 현재 앱의 기본 옵션만 사용한 실측에서는 확인되지 않은 조건부 위험입니다. 또한 계수기는 `SharedPreferences`의 메모리 상태를 읽으므로, 이관 중 강제 종료에 따른 디스크 기록 순서는 별도 시험이 필요합니다.

표시가 이미 `true`가 된 설치본은 다음 시작에 계수기를 다시 실행하지 않습니다. 따라서 v11의 “표시 없음 → 재로그인 안내” 조건은 유지하되, 위 중간 위험과 종료 시험을 해결한 뒤 표시를 이관 완료 근거로 사용해야 합니다. 이번 검토는 읽기 전용으로 수행했고 시험은 실행하지 않았습니다.

## 4차 원문

## 4차 검토 결과

**앞 중간 지적은 아직 해소되지 않았습니다. 새 높음 1건·중간 2건이 있습니다.**

- **높음 — 3회 실패 뒤 차단 해제가 같은 자료 손상 경로를 다시 엽니다.** [secure_storage_migration.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/secure_storage_migration.dart:85)는 실패 원인을 구분하지 않고 세 번째 시작에서 `writesBlocked=false`로 바꿉니다. **재현:** ESP 항목이 남아 계수가 계속 0이 아닌 상태로 세 번 시작 → 다시 로그인해 쓰기. 플러그인이 ESP 폴백 중이면 새 cipher 값이 ESP에 저장되고, 나중에 이관될 때 값이 이중 암호화될 수 있습니다. 표시가 없어서 v11이 재로그인을 안내하더라도 v10에서 생기는 손상은 막지 못합니다. **방향:** ESP 잔여 항목이 있거나 상태를 확인하지 못한 경우 횟수만으로 쓰기를 풀지 않아야 합니다.

- **중간 — 차단보다 서버 변경이 먼저 일어납니다.** 읽을 수 있는 커뮤니티 세션이 남아 있으면 [토큰 갱신](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/community_auth_service.dart:503)은 서버에서 refresh token을 회전시킨 뒤 Guarded 저장소에 쓰려다 실패할 수 있습니다. 새 토큰을 잃습니다. [writer 연결 등록](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/community/gate/community_gate.dart:430)도 서버 등록 뒤 비밀 저장에서 실패할 수 있습니다. 첫 게이트 검사에서 이 예외가 나면 `_checked`가 설정되지 않아 로딩 화면에 머무를 수 있습니다. **방향:** 이관 미확인 시 토큰 회전·연결 등록을 서버 호출 전에 막고 일시 장애 상태로 돌려야 합니다.

- **중간 — 차단된 삭제보다 일반 설정 삭제가 앞섭니다.** [report_provider.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/providers/report_provider.dart:939)의 `resetConfig()`는 모드·사용자명 등을 지운 뒤 `StandaloneAuthService.clearToken()`을 호출합니다. [clearToken()](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/standalone_auth_service.dart:324)은 토큰을 먼저 지우고 마지막 보안 저장소 삭제에서 차단 예외를 던집니다. **재현:** `writesBlocked=true`에서 설정 초기화. 결과는 설정·토큰만 지워진 부분 초기화입니다. **방향:** 차단 여부를 초기화 전에 확인하거나, 보안 저장소 삭제 가능 여부를 확인한 뒤 일반 설정을 변경해야 합니다.

추가로 [연결 비밀 삭제](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/community/gate/community_gate.dart:521)는 차단 예외를 삼켜 공유 자료 삭제 후 비밀이 남아도 정리 성공으로 처리할 수 있습니다. 이 삭제 결과도 완료 판정에 반영해야 합니다.

**백그라운드:** 확인한 프로덕션 WorkManager 두 작업은 이관 표시를 확인한 뒤 보안 저장소 경로로 진입합니다. 백그라운드 isolate의 `writesBlocked` 기본값은 `false`지만, 표시 전 접근을 막는 현재 진입점 검사 때문에 이번 범위에서 추가 경로는 찾지 못했습니다. v9 알고리즘 메타 키 두 개를 계수에서 제외한 변경도 소스와 맞습니다.

읽기 전용 요청에 따라 시험은 실행하지 않았습니다.

## 5차 원문

**판정:** 이전의 3회 실패 뒤 차단 해제, 이관 미확인 상태의 일반 앱 진입, 그에 따른 서버 변경·연결 비밀 삭제 경로는 해소됐습니다. [main.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/main.dart:52)는 복구 화면을 띄운 뒤 반환하므로 Workmanager 초기화와 링크 채널은 시작하지 않습니다. 이미 예약된 백그라운드 작업도 [background_login_check.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/background_login_check.dart:58)에서 표시를 확인한 뒤 보안 저장소에 접근합니다.

**새 높음 없음. 새 중간 2건입니다.**

- **중간 — 초기화 뒤에도 로그인 토큰이 남음.** [secure_storage_migration.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/secure_storage_migration.dart:66)의 초기화는 보안 저장소 파일만 비우지만, 유효한 Standalone 토큰과 만료 시각은 일반 SharedPreferences에 남습니다([standalone_auth_service.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/standalone_auth_service.dart:283)). 유효한 토큰을 둔 채 복구 화면에서 지우고 다시 열면 재로그인 없이 일시적으로 인증된 상태가 되고, 만료 후에는 삭제된 비밀번호로 자동 재로그인을 시도합니다. 표시를 남기기 전에 토큰·만료 시각도 지워야 합니다. 기존 `clearToken()`은 보안 저장소 삭제까지 수행하므로 그대로 호출하기보다 일반 prefs 항목만 지우는 경로가 적합합니다.

- **중간 — Keystore 별칭 자체가 고장 난 경우 복구 완료를 잘못 표시할 수 있음.** [MainActivity.kt](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:324)는 prefs 세 파일만 비웁니다. 정상 별칭이라면 플러그인이 새 AES 키를 만들어 감쌀 수 있어 실측 결과와 맞습니다. 그러나 남은 RSA/Keystore 별칭이 사용 불능인 경우 플러그인은 이를 재사용하려다 다시 실패할 수 있습니다. 그럼에도 [secure_storage_migration.dart](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/lib/services/secure_storage_migration.dart:68)는 즉시 표시를 남기고, 다음 시작은 표시만 보고 검증을 건너뜁니다. 플러그인 소유 별칭까지 초기화하거나, 새 엔진에서 읽기·쓰기 확인을 마친 뒤 완료 표시를 남기는 방향이 필요합니다.

**낮음:** [MainActivity.kt](/home/better0101/projects/worktree/fss10-20260927/safetyreport-mobile/android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt:325)의 세 `commit()`은 원자적이지 않습니다. 뒤쪽 파일의 삭제가 실패하면 앞쪽 파일은 이미 비워졌는데 화면에는 실패로 표시됩니다. 재시도는 가능하지만 실패 문구가 실제 상태를 정확히 설명하지는 못합니다.

`SystemNavigator.pop()` 뒤 같은 OS 프로세스가 살아 있어도, 확인한 일반 실행 경로에서는 복구 화면이 평소 앱으로 전환되지 않습니다. 재실행 시 새 플러그인 상태를 쓰는 경로이며, 실측도 이를 뒷받침합니다. 파일 수정이나 추가 실행 시험은 하지 않았습니다.
