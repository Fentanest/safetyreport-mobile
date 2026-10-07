# 2.0.5+36 모바일 긴급 오프라인 대응 검증

검증 기준은 dev `d766b289c2fce37ca50bdaa49e31477602438f21`와 시작 시 존재한 Astra 미커밋 변경이다. 원본 파일 848개의 SHA-256을 보관해 추가 변경 충돌 없이 통합할 수 있게 했다. 새 코드 작성·시험은 별도 복사본에서 수행했다. 커밋/푸시/배포는 하지 않는다.

## 검증 결과

- **PASS** 전체 Flutter 단위/위젯 테스트: 1,323 passed / 16 skipped / 0 failed, 종료 0 (`flutter-test.log`). 마지막 변경은 브라우저 OAuth의 공통 cooldown 가드다. HTTP-date/두 본문 필드의 긴 대기시간, 재시작, 단일 probe, none/revoked 로컬 이용, 정지 유지, 같은 계정 재공유, 다른 계정/삭제 제외, 오프라인 full sync scope 유지, inactive headless 복구를 포함한다.
- **PASS (기존 경고)** analyze: 오류 0 / 기존 unnecessary_cast 경고 9 / 새 진단 0, 종료 1 (`flutter-analyze.log`).
- **PASS** Android debug 빌드 및 fixture UI/알림 통합 테스트 1개: 최종 실행에서 라이트/다크 화면, 탭 이동, 정상 PKCE URL, 알림 1001 생성→캐시 만료 후 제거→12초 추가 대기 중 재발 없음 확인. 브라우저 cooldown 가드와 정상 OAuth 허용을 포함해 `EXIT_CODE=0`, `SCENARIOS_PASSED=True`를 확인했다.
- **NOT_RUN** 운영 로그인·실제 브라우저 OAuth 왕복, 운영 동의·공유 업로드, 운영 부하 재현/원인 진단. 에뮬레이터는 fixture 전용 새 AVD/새 앱 sandbox만 사용했다.

## 환경·재현

Flutter 3.47.5 / Dart 3.13.4, Android API 35 x86_64, 전용 AVD `sr_offline_20261007` (`emulator-5564`), package `com.fentanest.mysafetyreport.offlineqa`, 최종 화면 720×1600 / density 280 (약 411dp). 단위 테스트는 모의 HTTP·임시 SQLite만 사용하고 시스템 sqlite3를 지정하는 임시 pubspec hook을 시험 후 제거했다. 의존성 lock은 변경하지 않았다.

- 단위: `flutter test --no-pub --concurrency=4 --reporter expanded` (격리 Flutter SDK, 시스템 sqlite3 LD_LIBRARY_PATH).
- 정적: `flutter analyze --no-pub`.
- Android: `SR_QA_FLUTTER=<isolated flutter> GRADLE_USER_HOME=<isolated gradle> PUB_CACHE=<isolated pub cache> python3 tool/run_emergency_offline.py --device emulator-5564`.
- 실제 screenshot은 `01-cloud-offline-dashboard.png`, `02-cloud-offline-reports.png`, `07-cloud-offline-dark.png`; 네이티브 서비스/알림 근거는 `04-*.txt`→`05-*.txt`→`06-*.txt`. 알림 권한은 fixture 앱에만 부여했다.

## 독립 검수 대응

1. 동의 철회가 suspended를 덮어쓰던 경로: `ConsentHistory`에 contributor 정지를 독립 보존하고 명시적인 active 서버 응답 때만 해제.
2. 오프라인 full sync가 local_dataset_id를 회전해 journal 주인/dataset을 잃던 경로: offline_capture가 있으면 기존 dataset 유지; 실제 SQLite/SyncEngine 회귀 통과.
3. ingest `retry_after_seconds`가 공통 대기시간에 누락되던 경로: camelCase/snake_case/Retry-After의 유효 최댓값을 영속 저장. 900초 후에도 301초의 auth/status 요청은 네트워크에 도달하지 않음.
4. 동의 이력의 병렬 저장/종료 경합: 계정별 직렬화와 DB lease, 종료된 gate의 비동기 정리 예외 격리. 로그아웃 회귀 통과.
5. 추가 경계: 외부 브라우저 시작은 HTTP transport 밖이므로 startLogin에서 동일 cooldown을 확인. 관측된 장애가 없으면 즉시 OAuth 시작.

## 증상별 판정과 한계

- 재시도 화면에 갇힘: **해결(검증한 로컬 경로)**. 같은 로그인·DB 주인의 로컬 조회/수집과 탭 이동을 허용하고 상단 카운트다운으로 공유 대기를 표시한다. 동의 none/revoked/unknown은 업로드에만 적용한다. 로그인 상실/정지/계정 불일치는 차단한다.
- 카카오 동의 확인 알림 반복: **해결(fixture native 검증)**. 기존 Astra의 서비스 종료/알림 제거 변경을 보존하고 반복 알림이 없는 것을 확인했다.
- 브라우저가 Supabase 주소로 감: **잘못된 URL은 확인되지 않음**. `/auth/v1/authorize?provider=kakao`는 정상 PKCE 중간 경로다. 관측 장애 중 앱에서 브라우저 재시도도 대기시간을 준수한다. 실제 카카오/auth 서버 왕복이 disk IO 지연으로 멎었는지는 미검증이다.

공개 완료 manifest는 전체 receipt 목록이 아니다. manifest에 없다고 ACK를 무시하지 않고, 재동의는 같은 계정 자료만 기존 reshare API로 처리한다. 명시적인 삭제 tombstone/삭제 fence를 우회하지 않는다. 서버 수동 삭제나 전체 초기화 이후의 완전한 복구는 기존 클라이언트 API만으로 보장할 수 없다. Android Doze 등에 의해 background 재확인은 정확히 5분에 실행되지 않을 수 있다. 로컬 secure storage 이력은 재설치 소실 가능하며 변조 방지를 보장하지 않는다.

초기 QA 실패도 숨기지 않는다: 플러그인 등록을 생성하지 않은 격리 빌드의 libdartjni 누락을 전용 cache pub get으로 복구했고, 새 AVD System UI ANR 및 알림 권한/표시 지연 문제를 fixture 환경에서 해소한 뒤 재실행했다. 이전 실패나 운영 장애를 최종 코드 통과로 오인하지 않는다.
