# 2.0.4+35 RC — 데모 모드 정상화

## 범위와 원인

- 작업 위치: `/home/better0101/projects/worktree/mobile-demo-fix`, 브랜치 `fix/demo-mode-bypass`.
- 기준: `450938b4` (`origin/dev`, v2.0.3+34). 버전 원본 `VERSION`과 `pubspec.yaml`을 **2.0.4+35**로 변경했다.
- 9552b937은 `main.dart`의 데모 즉시 진입을 게이트/클라우드/계정 복구 화면 뒤로 옮기고, 게이트 상실 시 데모 예외와 `communityNavAllowed`의 데모 예외를 제거했다. `SetupScreen`의 심사 계정 판별에도 `!accountRecovery` 조건을 추가했다.
- 그 결과 합성 자료만 보여야 하는 데모에도 카카오·클라우드 연결이 필수가 됐다. 새 설치에서는 Standalone 선택 직후 카카오 화면으로 이동하여 심사용 로그인 입력 자체에도 도달할 수 없었다.

## 원래 동작 근거

`git show v2.0.2:lib/main.dart`로 확인했다.

- 315행: `if (provider.isStandaloneDemo) return const MainNavigationScreen();`이 게이트 검사보다 앞에 있다.
- 226행: `_gateWasOpen && !canEnter && !provider.isStandaloneDemo`일 때만 실제 자료 화면을 닫는다.
- 647행: 데모는 `communityNavAllowed`에서 직접 허용한다.
- 원래 주석: “데모는 합성 자료만 쓰므로 인증·권한·서비스를 시작하지 않는다.”
- `v2.0.2:lib/screens/setup_screen.dart`의 심사 자격 판별은 계정 복구 여부에 종속되지 않는다. 기존 `demo/demo` + 휴대폰 공란 또는 `demo` 규칙을 유지했다.

## 변경 파일과 동작

| 파일 | 변경 |
|---|---|
| `lib/main.dart` | 게이트보다 앞서 데모 메인 진입. 데모 내비게이션/하위 화면 유지. 저장된 모드를 초기 게이트/인증 링크 처리 전에 로드. 데모에서 인증 링크 처리·계정 확인 팝업·Client 서버 확인 제외. |
| `lib/screens/setup_screen.dart` | 새 설치에서 Standalone 입력창에 먼저 도달. 심사 자격은 합성 DB로 진입하고 실제 로그인은 API/DB 가져오기 전 기존 온보딩·권한 흐름으로 이동. 계정 복구 화면에서도 명시적 심사 자격은 별도 데모 DB로 진입. |
| `lib/community/gate/community_gate.dart` | 데모는 토큰 갱신/status/자료 주인/공식 바인딩/계정 변경 검사를 하지 않는다. poll/retry를 중단하고 context를 비활성화. `demo_mode`, `canEnter=false`로 커뮤니티 작업 권한은 닫고 UI만 우회. 데모 종료 시 실제 모드 재검증·poll 재개, 이전 모드의 늦은 응답 무효화. |
| `test/community/entry_order_test.dart` | 기존 잘못된 기대를 정정. 미인증/클라우드 장애/불일치/선점/계정 변경 미완료 상태별 메인 진입·하위 화면 유지, 권한/서비스 미시작 검사. 일반 계정은 온보딩 전 로그인/가져오기 미실행. |
| `test/community/demo_gate_bypass_test.dart` | 토큰/API/주인/계정/첫 통과 훅 호출 0, 주기·복귀 가드, 실제 모드 복귀와 이전 응답 무효화 검사. |
| `test/community/official_binding_gate_test.dart`, `gate_state_test.dart`, `kakao_logout_test.dart` | 테스트를 삭제하지 않고 데모 작업 권한과 UI 진입의 기대를 바로잡고 이유를 주석으로 기록. 기존 비데모 대조·복구·주인 검사 유지. |
| `VERSION`, `pubspec.yaml`, `CHANGELOG.md` | 2.0.4+35 RC, 사용자용 요약 “데모 모드 정상화”. |
| `docs/architecture/community-gate.md`, 이전 바인딩 `REPORT.md` | 데모 필수 인증이라는 잘못된 서술 정정. 이전 보고서의 실행 건수는 당시 기록으로 보존. |
| `tool/verify_demo_mode_rc.py` | 실제 앱 debug APK를 adb로 조작하는 재현 스크립트. 지정 emulator-5580 및 별도 합성 시험 앱 ID만 사용. 네트워크는 finally에서 복원. |

`local_db_service.dart`의 `_realDatabaseKey`는 변경하지 않았다. 데모 **종료 후** 실제 계정 변경을 검증할 때 실제 DB를 선택하는 제한된 Zone 예외다. 이를 제거하면 실자료 보호가 약해진다. 데모 진입은 `seedPlayReviewDemo` → 별도 `standalone_reports_demo.db`이고, `setStandaloneConfig(isDemoMode: true)`는 이미 실제 계정 준비를 건너뛰며 keep-alive/예약/업로드를 중단한다.

비데모의 원격 1:1 바인딩, 계정 불일치/선점 차단, 클라우드 실패 차단, 삭제 확인·백업·초기화 보호 코드는 유지했다. 일반 계정의 복구 화면 뒤로가기·모드 선택 버튼도 계속 차단한다.

## 검사

Flutter는 `/home/better0101/development/flutter-3.47.5/bin/flutter`만 사용했다. 새 worktree의 `.dart_tool` 준비는 `flutter pub get --offline`으로 했으며 lockfile/의존성 버전은 바꾸지 않았다. 분석/테스트에는 `--no-pub`을 사용했다.

| 검사 | 결과 |
|---|---|
| 관련 기존 회귀 4개 파일 | PASS, 55개 통과 |
| 추가 데모 게이트 테스트 | PASS, 2개 통과 |
| `flutter analyze --no-pub` | 오류 0 / 기존 warning 9 / 신규 진단 0, 종료 1. [로그](evidence/analyze.log) |
| `flutter test --no-pub` 전체 | PASS, **1,306 passed / 기존 16 skipped / 실패 0**, 종료 0, 1분 55초. [로그](evidence/flutter-test.log) |
| `flutter build apk --debug --no-pub` | PASS, 종료 0. [로그](evidence/debug-build.log) |
| 지정 에뮬레이터 심사 로그인/탭/재실행 | PASS. 온라인 및 네트워크 차단 상태에서 초기화 후 심사 로그인 → 100건 메인 → 5개 탭 → 강제종료/재실행. [온라인](evidence/emulator-online-tabs.log), [오프라인 로그인](evidence/emulator-offline-login.log), [오프라인 탭·재실행](evidence/emulator-offline-tabs.log), 각 단계 종료 0. |
| 오프라인 Demo 보기 버튼 | PASS, 종료 0. [로그](evidence/emulator-offline-button.log) |

초기 추가 테스트에는 기기 이름 MethodChannel을 주입하지 않아 가상 시간 timeout을 기다리는 문제가 있었다. 기기 이름을 명시적으로 주입하고 테스트 종료 시 poll을 정리한 후 2개 모두 통과했다. 전체 테스트의 최종 재실행 결과만 완료 결과에 사용한다.

빌드는 Kotlin 데몬의 기본 임시 디렉터리(`/home/better0101/.local/share/kotlin/daemon`) 쓰기 제한 경고 후 fallback으로 성공했다. 프로젝트/SDK 버전이나 빌드 설정을 바꾸지 않았다. `android/key.properties`가 없는 것을 확인했으며 배포 서명키·키스토어를 열지 않았다.

## 에뮬레이터 증거

- 디바이스: **emulator-5580**, AVD **sr_uitest_api35**, 1080×2400, density 420(약 411dp), 라이트 테마, 기본 글꼴.
- 실제 `lib/main.dart` debug APK를 설치했다. 시험 앱 ID만 `SR_TEST_APPLICATION_ID=com.fentanest.mysafetyreport.demorc`로 분리했다. 진입/게이트/HTTP fixture, 테스트용 앱 엔트리포인트 또는 운영 로그인은 사용하지 않았다.
- 각 로그인 시나리오 전 **시험 앱만 `pm clear`**. 기존 설치된 운영 앱의 데이터는 건드리지 않았다.
- 최초 증거 수집 프로세스가 종료 코드 143으로 중단되어 완료된 캡처/로그를 보존하고 login/tabs/button 단계별로 나눠 재개했다. 단계별 종료 결과로 검증하며 수집 스크립트에는 SIGTERM 시 네트워크 복원도 추가했다.
- 최초 설치 직후 Android **System UI** ANR 안내 1회. “Wait” 선택 후 정상 표시됐다. 앱 프로세스의 fatal/Flutter 오류 여부는 별도 logcat으로 판정한다.
- 온라인 `demo/demo` + 휴대폰 공란, 오프라인 `demo/demo/demo`, 저장된 데모 재실행을 확인했다. `Demo 보기`도 오프라인 초기화 상태에서 메인 진입을 확인했다. 오프라인은 Wi-Fi·모바일 데이터를 `svc ... disable`로 끈 뒤 앱 데이터를 초기화한 상태에서 시작했다.
- 각 화면의 실제 PNG 및 UI hierarchy XML을 함께 보존했으며 카카오/클라우드 화면이 없음을 검사했다. 서비스 덤프에서는 동기화·WebSocket·알림 리스너와 foreground 서비스 미실행을 확인했다. keep-alive/예약/업로드 미시작은 회귀 테스트의 호출 검사와 기존 데모 가드로 검증했다. Flutter Geolocator 플러그인의 엔진 초기화 시 로컬 bind만 존재하고 `startForegroundCount=0`이다.
- [온라인 앱 logcat](evidence/online-logcat.txt), [오프라인 앱 logcat](evidence/offline-logcat.txt), 두 재실행 logcat에서 `FATAL EXCEPTION`, `Unhandled Exception`, `EXCEPTION CAUGHT`, `E/flutter`는 0건이다. 에뮬레이터 렌더 초기화/프레임 지연 및 UI hierarchy 준비 전 null-root 경고는 앱 예외와 구분했다.
- **SQLite journal 로그는 별도 존재한다.** 신규 데모 진입 3회(온라인 로그인/오프라인 로그인/Demo 보기)에서 각각 `E SQLiteLog: PRAGMA journal_mode=TRUNCATE database is locked` 1건과 “WAL을 바꾸지 않고 계속 진행” 안내가 있었다. fatal/Flutter 예외 0건을 모든 error 로그 0건으로 해석하지 않는다. 최종 시험 앱을 중지하고 합성 DB·community DB와 WAL/SHM을 임시 사본으로 읽어 `PRAGMA integrity_check=ok`, 합성 신고 **100건**을 확인한 뒤 시험 앱을 다시 열었다. [무결성 결과](evidence/db-integrity.json). DB 열기 경로의 journal 전환 시도 자체는 이번 게이트 복구에서 변경하지 않았다.
- [설치 버전](evidence/installed-version.txt)은 `versionName=2.0.4`, `versionCode=35`다.

### 캡처 인덱스

PNG 옆의 같은 이름 `.xml`은 해당 캡처의 UI hierarchy다.

| 시나리오 | 온라인 | 오프라인 |
|---|---|---|
| 초기화 후 모드 선택 | [화면](evidence/online-01-mode.png) | [화면](evidence/offline-01-mode.png) |
| 심사 계정 입력 | [demo/demo, 휴대폰 공란](evidence/online-02-review-login.png) | [demo/demo/demo](evidence/offline-02-review-login.png) |
| 합성 100건 메인 | [대시보드](evidence/online-03-dashboard.png) | [대시보드](evidence/offline-03-dashboard.png) |
| 신고내역 | [화면](evidence/online-04-tab.png) | [화면](evidence/offline-04-tab.png) |
| 신고관리 | [화면](evidence/online-05-tab.png) | [화면](evidence/offline-05-tab.png) |
| 통계 | [화면](evidence/online-06-tab.png) | [화면](evidence/offline-06-tab.png) |
| 알림 | [화면](evidence/online-07-tab.png) | [화면](evidence/offline-07-tab.png) |
| 저장된 데모 강제종료 후 재실행 | [화면](evidence/online-08-relaunch.png) | [화면](evidence/offline-08-relaunch.png) |
| 별도 Demo 보기 버튼 | 해당 없음 | [화면](evidence/offline-09-demo-button.png) |

[네트워크 차단 상태](evidence/offline-network.txt): Wi-Fi 0, mobile_data 0, Active default network none.
[복원 상태](evidence/network-restored.json): 두 설정 모두 1.

재현 명령(설치된 시험 앱만 초기화):

```sh
python3 tool/verify_demo_mode_rc.py login
python3 tool/verify_demo_mode_rc.py tabs
python3 tool/verify_demo_mode_rc.py login --offline
python3 tool/verify_demo_mode_rc.py tabs --offline
python3 tool/verify_demo_mode_rc.py button --offline
```

## 미확인 및 제한

- 서명 release/AAB, Play Console 업로드·심사, 업데이트 설치, 개인 실기기, iOS는 실행하지 않았다.
- 비데모의 운영 서버·실계정 로그인은 금지에 따라 실행하지 않았다. 비데모 회귀는 합성 HTTP/SQLite·위젯 전체 테스트로 검증한다.
- 다크·좁은 폭·큰 글꼴·Client 실화면 전체 디자인 매트릭스 및 실기기 성능은 이번 데모 복구 검증 범위 밖이다.
- 과거 커밋 메시지는 이력을 수정하지 않고 CHANGELOG/구조 문서/본 보고서로 정정했다.

**커밋·push·태그·워크플로·스토어 배포를 하지 않았다.** 지정 에뮬레이터를 종료/재시작하거나 다른 AVD를 실행하지 않았다.
