# 공식 계정 바인딩 릴리스 후보 — 2026-10-06

## 후보와 범위

- 기준 구현: `bbb66d2a`, 브랜치 `fix/official-account-binding`. 로컬 수정만 있으며 커밋·push·태그·워크플로·업로드·운영 로그인은 실행하지 않았다.
- RC 검증 중 확인한 수정: 불일치 화면이 열린 상태에서 `official_account_taken`으로 바뀌어도 예전 안내가 남았다. `SetupScreen.didUpdateWidget`에서 새로운 안내를 반영하며 입력값은 유지한다. 수정 전 위젯 및 Android 재현 로그와 수정 후 회귀 로그를 evidence에 보존했다.
- 다음 후보: **2.0.3+34**. RC는 검토 상태를 뜻한다. 기존 정식 버전 관례처럼 숫자 버전을 사용하며 `-rc` 태그를 만들지 않았다. 근거: 작업 시작 시 `VERSION`/pubspec `2.0.2+33`, 로컬 최신 태그 `v2.0.2`, CHANGELOG의 2.0.1+32 → 2.0.2+33, CI가 `VERSION`을 pubspec에 동기화하고 `v<build_name>`을 사용한다.
- 안전신문고 ID/해시는 개인 DB에 기록하거나 복원 소유권 판정에 사용하지 않는다. 서버 바인딩은 설정 ID와 중앙 status만 대조한다. DB 복원은 카카오 주인만 검사한다.
- 계정 불일치·선점은 로그인 복구 화면, 클라우드 장애는 재시도 화면으로 진입을 막는다. 계정 변경은 경고 → 백업 → 중앙 삭제/바인딩 해제 확인 → 로컬 초기화 → 새로 시작 순서다.
- 서버 배포 상태는 총괄 제공 정보: auth `793aa9d`, map `56168b9`, community-account v8 / community-ingest v9. 이번 시험은 운영 상태를 다시 조회하지 않았다.

## 검사 및 화면 증거

| 검사 | 결과 | 증거 |
|---|---|---|
| `flutter analyze --no-pub` | error 0 / 기존 warning 9, 종료 1 | [로그](evidence/flutter-analyze.log) |
| `flutter test --no-pub --concurrency=2` 전체 | 1,300 passed / 16 skipped / 실패 0, 종료 0 | [로그](evidence/flutter-test.log) |
| `flutter build apk --debug --no-pub` (일반 main) | 성공, 종료 0 | [로그](evidence/debug-build.log), [SHA-256](evidence/debug-apk.sha256) |
| 서명 release APK/AAB | NOT_RUN — 작업 범위 밖, 배포용 키스토어 미접근 | — |

최종 debug 빌드 및 재현 수집기는 Kotlin in-process 컴파일을 환경변수로 지정했다(호스트의 읽기 전용 데몬 경로 회피). 프로젝트 Gradle 설정은 바꾸지 않았다. 최종 APK는 aapt로 기본 applicationId `com.fentanest.mysafetyreport`, versionName `2.0.3`, versionCode `34`를 확인했다. [검사 요약 JSON](evidence/validation-summary.json)과 [스크린샷 해시](evidence/screenshots.sha256)를 함께 보존한다.

스크린샷은 모두 합성 계정/자료이며 `adb -s emulator-5580 exec-out screencap -p` 원본이다.

- SDK: `/home/better0101/development/flutter-3.47.5/bin/flutter`.
- 장치: 이미 실행 중인 `emulator-5580`, `sr_uitest_api35`, Android 15 / API 35, 1080×2400 / 420dpi(약 411dp), font scale 1.0, 기본 라이트 테마. 별도 앱 ID `com.fentanest.mysafetyreport.bindingrc`.
- 테스트 전용 `integration_test/official_binding_rc_test.dart`에서 실제 `SafetyReportApp`, `CommunityGate`, `SetupScreen`, `SettingsScreen`, Android SQLite를 사용한다. 가짜 카카오 세션/HTTP/공식 로그인과 파일 선택 결과만 주입한다. 백그라운드 작업은 시험 provider에서 시작하지 않으며 외부 HTTP 연결은 차단한다.
- 테스트 진입점은 `lib/main.dart`에서 import하지 않는다. `integration_test`는 SDK dev_dependency이며 기존 의존성 버전은 바꾸지 않았다. 일반 debug 빌드와 시험 APK를 구분한다.

재현 명령(지정 AVD가 켜져 있어야 함):

```bash
export DASH__SUPPRESS_ANALYTICS=true
export FLUTTER_SUPPRESS_ANALYTICS=true
/home/better0101/development/flutter-3.47.5/bin/flutter pub get
/home/better0101/development/flutter-3.47.5/bin/flutter analyze --no-pub
/home/better0101/development/flutter-3.47.5/bin/flutter test --no-pub --concurrency=2 --reporter expanded
/home/better0101/development/flutter-3.47.5/bin/flutter build apk --debug --no-pub
python3 tool/run_official_binding_rc.py
```

호스트 분석 로그 디렉터리가 읽기 전용이므로 Dart/Flutter 자식 프로세스에도 분석 비활성화 환경변수를 전달한다. 배포용 키스토어는 접근하지 않고 release 빌드는 실행하지 않는다.

## 실화면 시나리오

**6개 모두 PASS**, Android integration test 1 passed / 종료 0. [실행 로그](evidence/integration-test.log), adb 원본 PNG **11장**. 각 캡처 직전에 위젯 예외를 검사하고 호스트가 테스트 앱의 실제 포커스를 확인했다. 아래 안내·버튼에서 잘림이나 겹침은 관찰되지 않았다.

| 항목 | 기대 및 실제 확인 | 증거 |
|---|---|---|
| ① 서버 대조 일치 | 정규화한 설정 ID와 status 바인딩 일치 → 실제 대시보드/5탭 진입 | [대시보드](evidence/01-match-dashboard.png) |
| ② 불일치 | 열린 설정 route 폐쇄 → 로그인 복구 화면, 탭 없음, adb Android BACK 후에도 같은 화면 | [로그인](evidence/02-mismatch-login.png), [BACK 이후](evidence/02-mismatch-back.png) |
| ③ 계정 변경 | 공식 세션 제거 → 다른 ID 로그인 → 경고 확인 → Documents의 실제 백업(`integrity_check=ok`, 기존 신고 1건, 안신 키 없음) 확인 후 중앙 해제 → 신고·감시 목록 초기화 → 새로 시작 화면 | [경고](evidence/03-account-change-warning.png), [새로 시작](evidence/03-account-change-new-start.png) |
| ④ 선점 | connections 409 `official_account_taken` → 운영자 문의 안내 | [선점 안내](evidence/04-official-account-taken.png) |
| ⑤ 클라우드 장애 | 503 → 오프라인 화면, 자동 status 재시도 정확히 3회, 응답 복구 후 재시도 버튼으로 메인 복귀 | [장애](evidence/05-cloud-offline.png), [자동 재시도 후](evidence/05-cloud-auto-retried.png), [수동 복귀](evidence/05-cloud-manual-recovered.png) |
| ⑥ 카카오 소유권 복원 | 다른 카카오 DB는 실제 설정 화면에서 거절하고 현재 행 보존. 같은 카카오의 account-a 시절 백업은 account-c 설정에서도 복원 성공, 원래 fixture 행 재확인 | [다른 카카오 거절](evidence/06-foreign-kakao-rejected.png), [같은 카카오 허용](evidence/06-same-kakao-accepted.png) |

[logcat](evidence/logcat.txt): Flutter 미처리 예외·RenderFlex overflow·FATAL/ANR는 발견하지 않았다. **네이티브 SQLite E 로그 1건**은 복원 임시 DB의 `PRAGMA journal_mode=TRUNCATE` 잠금 경고이며, 뒤의 `SQLiteConnection` 로그는 journal mode를 바꾸지 않고 계속 진행한다고 명시한다. 실제 복원 코드의 `integrity_check`와 복원 결과 단언은 통과했다. 이를 ‘logcat 오류 0’으로 간주하지 않는다. 소프트웨어 렌더러의 프레임 지연 및 Android Back callback 경고도 있어 실기기 성능 보장은 하지 않는다.

## 총괄 릴리스 절차 — 사용자 최종 승인 후에만 실행

정본: `.github/workflows/build-apk.yml`, `build_android_release.sh`, `docs/architecture/android-runtime.md`.

1. 이번 diff·증거·미확인을 검토한다. `VERSION`과 pubspec `2.0.3+34`를 함께 커밋하고 PR로 통합한다. 승인 전 main/dev push 및 원격 VERSION 반영은 금지다.
2. 승인된 후보 브랜치를 원격에 반영한 뒤 먼저 서명 검증 전용 CI를 실행할 수 있다:

   ```bash
   gh workflow run build-apk.yml --ref fix/official-account-binding -f verify_only=true
   ```

   이 명령도 서명키를 사용하고 APK/AAB/mapping artifact를 업로드한다. 로컬 dry run이 아니다. `verify` 선행 검사를 통과해야 build job이 실행된다. runner의 `FLUTTER_BIN`은 3.47.5 절대 경로인지 확인한다.
3. artifact의 versionCode 34, versionName 2.0.3, 커밋 SHA, release 서명 인증서, APK/AAB별 SHA-256 및 R8 mapping을 확인한다. APK/AAB artifact 보관은 1일, mapping 포함 dist는 90일이므로 즉시 장기 보존한다. 스토어 배포 전 해당 서명 후보의 설치/업데이트 검사를 별도로 수행한다.
4. 정식 공개 승인 뒤 검토한 동일 코드를 main에 병합한다. **main push가 정식 `build-apk.yml`을 자동 실행한다.** 자동 실행과 수동 실행을 중복시키지 않는다. 자동 실행이 없었던 경우에만:

   ```bash
   gh workflow run build-apk.yml --ref main -f verify_only=false
   ```

   **`v2.0.3` 태그를 먼저 생성하거나 push하면 안 된다.** 워크플로는 태그가 이미 있으면 빌드와 업로드를 건너뛴다. 성공 시 `softprops/action-gh-release` 단계가 `v2.0.3` 태그와 공개 정식 GitHub Release를 만든다(`draft: false`, `prerelease: false`). workflow에는 `target_commitish`가 명시되지 않았으므로 정식 실행은 승인된 main에서만 하고, 생성 태그가 실제 빌드 SHA를 가리키는지 반드시 확인한다. 불일치면 배포를 중단해 총괄이 처리한다.
5. GitHub Release에는 `mysafetyreport.apk`만 공개된다. Play에는 같은 실행의 `mysafetyreport.aab`를 사용한다. Play Console 내부 테스트에서 업데이트·로그인·바인딩·백업/복원 결과를 검토한 후 승인된 트랙으로 단계적 배포한다. versionCode 34가 이미 사용됐으면 번호를 높이고 양쪽 버전을 다시 맞춰 새 후보로 검증한다.
6. 로컬 서명 빌드가 필요한 경우 승인된 키 보유 환경에서만 아래를 실행한다. 스크립트가 APK → APK mapping 보존 → AAB → AAB mapping 보존 순서로 처리한다.

   ```bash
   FLUTTER_BIN=/home/better0101/development/flutter-3.47.5/bin/flutter bash ./build_android_release.sh
   ```

   `ALLOW_DEBUG_SIGNED_RELEASE=1` 결과는 배포하지 않는다. 산출물은 `dist/<버전>-<커밋>/` 및 `build/app/outputs/`에 생성된다.

## 배포 중단·롤백

- 승인 전이면 로컬 후보를 보류하면 된다. 태그/배포는 아직 없다.
- 공개 후 문제 발생 시 Play 단계적 배포를 중단하고 GitHub 공개 경로를 총괄이 관리한다. 앱 데이터를 삭제하거나 구 APK 강제 다운그레이드로 복구하지 않는다.
- 중앙 바인딩은 이미 배포됐고 클라이언트 DB/커뮤니티 처리 DB에는 과거 바이너리와 비호환인 상태가 있을 수 있다. 서버 삭제·바인딩 해제 및 사용자 초기화는 코드 롤백으로 되돌아가지 않는다. 자동 생성 백업을 보존하고 같은 카카오 인증 후 검증된 복원을 사용한다.
- 복구 배포는 현재 reader/서버 계약을 유지한 수정본을 더 높은 versionCode로 내는 것을 우선한다. 기존 태그를 덮거나 이전 AAB를 재업로드하지 않는다. `android-runtime.md`의 private processing DB/미완료 작업 다운그레이드 제한을 적용한다.

## 미확인 및 적용 범위

- 이 화면 검증은 지정 AVD의 Standalone 라이트 화면이다. Client 실화면, 다크·360dp·큰 글꼴 전체 매트릭스, 물리 기기 성능 및 서명 릴리스의 업데이트 설치는 이번 범위에서 검증하지 않았다. Client/Standalone/데모의 게이트 조건은 전체 위젯·단위 테스트에 포함된다.
- 카카오 브라우저 OAuth 및 안전신문고 비밀번호 검증은 합성 응답이다. 계정 변경 시험은 기존 공식 세션 토큰을 지운 뒤 실제 복구 로그인 화면에서 다른 ID를 입력한다. 실제 외부 로그인은 실행하지 않는다.
- DB 선택기는 합성 백업 파일 경로를 반환하도록 주입한다. 실제 SettingsScreen의 복원 확인·실패/성공 안내와 Android SQLite 교체를 검사하며 DocumentsUI 조작 자체는 이번 검증 대상이 아니다.
- release 서명·R8·Play 업로드는 NOT_RUN이다. debug 통과만으로 이 단계의 성공을 보장하지 않는다.
