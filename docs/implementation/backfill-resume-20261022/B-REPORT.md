# B(모바일 핵심) 보고서 · 2026-10-22 1회 전송 재개·점검 중지·필수 버전·Client 계정 일치

작업 폴더 `backfill-resume-ws/mobile`(branch `feat/backfill-resume`, 기준 4c9b217b). 커밋·push 하지 않았다. 원격 서버(206·205) 접속 없음.
정본: 지도 `docs/implementation/backfill-resume-20261022/CLIENT-RULES.md`(이하 "규칙"), 작업지시서 2-2·2-3·2-4·2-5·2-9·2-10·2-13.
Flutter 는 `~/development/flutter-3.47.5` 만 썼다.

## 1. 바꾼 파일

### 새 파일
| 파일 | 내용 |
|---|---|
| `lib/community/backfill_errors.dart` | 규칙 1절 분류 `classifyBackfillError`/`transientBackfillReason`(사유 코드), `BackfillTransient`, 일시적 간격 60→300→900→3600, 보류 간격 15분→1시간→6시간→24시간, 30일 상한 |
| `lib/community/raw_backfill_unstick.dart` | 2-3 첫 실행 1회 초기화(`meta.raw_backfill_unstick = "2026-10-22.1"`, 한 트랜잭션) |
| `lib/community/backfill_progress.dart` | 진행 보고·사용자 조치 알림을 **언제** 부를지(start·state_change·periodic 10분·daily KST)와 `backfill`/`optimize`/`official_login`/`pace` 값 만들기, 진행 보고 503 기록 → 중지 처리 |
| `lib/community/upload_pause.dart` | 2-9 업로드 일시 중지 저장(`community.db meta.upload_pause`), status·503 반영, 재개 시각+0~120초 WorkManager 1회 작업(`community-upload-resume`), 배너 문구·KST 시각 |
| `lib/community/update_requirement.dart` | 2-10 버전 비교(`version-vectors.json` 규칙), 6-2 잠금 판정표, 저장(prefs `community_update_requirement_v1`) |
| `lib/community/gate/first_run_mode.dart` | 2-5 첫 실행에 고른 모드(`FirstRunMode.choice`)와 게이트 모드 계산(`unselected` 포함) |
| `lib/services/app_version.dart` | 진입점에서 한 번 읽는 앱 버전(판정·헤더용) |
| `lib/screens/update_required_screen.dart` | 전체 화면 잠금(Play 즉시 업데이트 → `url.mobile`/Play, GitHub 설치본은 releases) |
| `lib/screens/community_upload_screen.dart` | 알림에서 여는 "신고 공유" 화면(기존 `CommunityUploadPanelHost`) |
| `lib/widgets/upload_pause_banner.dart` | 점검 상단 배너(운영자 문구는 평문) |
| `lib/community/report/progress_reporter.dart`, `report/setup_progress_reporter.dart`, `notify/user_action_notifier.dart`, `lib/announcements/announcement_presenter.dart`, `lib/widgets/user_action_banner.dart` | **D 연결용 빈 구현**(같은 경로·시그니처, D 의 실제 파일이 덮어씀). 검수자 전달대로 `ProgressReporter.lastMaintenance/clearMaintenance`, `UserActionNotifier.clear`, `UserActionBanner({onLogin,onRetry})` 포함 |
| `test/community/backfill_resume_test.dart`, `test/community/pause_update_test.dart` | 새 시험(아래 4절) |
| `docs/implementation/backfill-resume-20261022/evidence/*.png` | 에뮬레이터 화면 증거 |

### 고친 파일
| 파일 | 내용 |
|---|---|
| `lib/community/raw_backfill.dart` | 오류 분류 적용(일시적 → run `paused`·`transient_failures`, 신고 횟수·커서 그대로), 고정적 3회 → `holdItem`(hold_count·next_attempt_at·first_held_at·stale), slice 시작 때 때가 된 보류 자동 `pending`(attempts 2), 버튼 retry 는 전부 0부터, 업로드 확인 retry 3회 → 보류(`upload_retry`), 업로드 단계에 `pending` 이 남으면 채우기로 복귀, 채우기 slice 끝 업로더 깨우기 1회, 점검 중 `paused/maintenance`(일 안 함), marker `run_started_at`·`updated_at`, summary 에 `pending`·`queued` |
| `lib/community/backfill_store.dart` | SQLite 보류 처리(`retry`·`releaseDueHolds`·`nextHoldAt`·`stateCounts`), summary `pending`·`queued` |
| `lib/community/raw_backfill_runtime.dart` | 첫 실행 1회 초기화 호출, 잠금 중 실행 안 함, 점검 hook, 보류만 남은 run 의 `nextDelay`(max(15초, 최소 보류 시각−지금), 상한 24시간)와 WorkManager 1회 작업(`community-raw-backfill-wake`), 점검 중 타이머 없음, `result` 없는 상세 응답 → `no_result`, pace 집계, 진행 보고·알림 판단 호출, 중지·잠금 중 업로더 깨우지 않음, `wake()` |
| `lib/community/upload/community_uploader.dart` | 잠금(`update_required`)·중지(`maintenance`) 중 요청 0회, 503 maintenance → 중지 저장·행 `retry_wait`(다음 시도 = 재개 시각+지터, 없으면 max(Retry-After,600)초)·attempt 되돌림·남은 배치 안 보냄 |
| `lib/community/upload/community_ingest_client.dart` | manifest 503 maintenance 를 알리는 `onMaintenance` |
| `lib/community/community_wiring.dart` | 중지 중 manifest 요청 안 함, 503 기록, 게이트 통과 뒤 진행 보고 start, 중지·잠금이 풀리면 업로더·1회 전송 깨우기 |
| `lib/community/upload/upload_background.dart` | 헤드리스 status 에서 중지·필수 버전 반영 |
| `lib/services/background_login_check.dart` | 새 작업 이름 2개 연결, 잠금 중 아무것도 안 함, 중지 중 업로드 0회·재개 깨우기 예약, 재개 작업도 복구 업로드, `AppVersion.load()` |
| `lib/services/notification_background.dart` | 잠금 중 백그라운드 동기화 안 함, `AppVersion.load()` |
| `lib/community/gate/community_gate.dart` | `unselected` → `mode_unselected`(status 안 물음), status 정상 응답에서 중지·필수 버전 반영, Client 계정 판정(7절 표, 동의 판정보다 먼저 잠금, PC 주소·키 범위로 저장), 미설정·온보딩 플래그, 중지 중 manifest 생략, 설정 단계 보고(`kakao_ok`·`connection_registered`·`client_server_checked` 6키) |
| `lib/community/gate/gate_state.dart` | `serverAccountMismatch` 를 32자리 16진 둘이 다를 때만으로, `clientAccountVerdict`·`isAccountFingerprint` |
| `lib/community/client_server_consent.dart` | PC 응답을 함께 돌려주는 `check`(요청 1번으로 동의·계정·미설정 판정) |
| `lib/community/gate/community_account_client.dart` | 모든 요청에 `X-Client-Version`·`X-Client-App`(`mobile/android`|`mobile/ios`), 형식 틀린 버전은 생략 |
| `lib/community/client_account_notice.dart` | **삭제**(잠금 화면으로 대체, 규칙 7절) |
| `lib/screens/community_onboarding_screen.dart` | 계정 불일치 잠금 카드("로그아웃 후 다시 로그인", 휴대폰 세션만), 잠금 중 동의 카드 숨김·저장 거부, 서버 로그인 전 잠금에 "서버의 커뮤니티 계정 열기", 미선택/잠금 동의 차단, `consent_ok` 보고(Standalone 만) |
| `lib/screens/setup_screen.dart` | `official_login_started/failed(reason)/ok` 보고 |
| `lib/screens/settings_screen.dart` | `openModeSwitchOnStart`(공지 `open_mode_switch` → `_confirmModeReset`), 안내 카드 제거 |
| `lib/main.dart` | 게이트 모드 = `FirstRunMode.gateMode`, 앱 버전·잠금·중지 초기 읽기, 잠금 시 전체 화면 `UpdateRequiredScreen`·쌓인 화면 닫기·동기화 정지, 동기화 허용 판정에 잠금, 메인 화면 점검 배너·`UserActionBanner`, 공지 호출(진입·복귀, 게이트 미통과·잠금 중 제외), 알림 이동 `user_action_*` 4종, 앱 시작 보고·알림 판단 |
| `lib/widgets/cloud_delay_banner.dart` | Client 미설정 서버 안내(잠금 아님) |
| `lib/services/server_connection_service.dart` | `SERVER_UPGRADE_REQUIRED` 문구 → 규칙 11절 "서버 프로그램 업데이트가 필요합니다…" |
| `pubspec.yaml`·`pubspec.lock` | `in_app_update: ^5.0.0` 추가(이 레포 single writer). 버전 번호는 그대로 |
| `contracts/community-ingest-v2/` | 지도 사본과 같은 바이트(새 4·바뀐 4 파일) |
| 시험 갱신: `test/community/client_account_notice_test.dart`(잠금 시험으로 교체), `gate_evaluate_test.dart`, `raw_backfill_review_test.dart`, `gate_review_test.dart`(대기 방식, 5절), `test/services/selfhost_compatibility_test.dart` | 바뀐 규칙에 맞춘 기대값(아래 판단 9·10) |
| `CHANGELOG.md`, `docs/architecture/community-account.md`(1절·코드 대조 정정 "Client 는 서버와 같은 계정만"), `community-gate.md`, `community-upload.md` | 미출시 항목·설계 |

## 2. 판단 (규칙에 없거나 해석이 필요했던 것)

1. **2-3 `paused` 행 해석**: "marker paused + 로그인 아님 → 대기 0" 과 "official_login_required + 수동 표시 → 그대로" 사이(공식 로그인 사유인데 수동 표시 없음)는 **대기 0** 으로 했다(사용자 조치가 필요한 경우만 유지).
2. **업로드 단계에 남은 pending**: 예전 코드는 `uploading` 단계에서 `pending` 항목을 다시 채우지 않아(영수증 retry 가 아니면) 멈출 수 있었다. 규칙 2-3 표의 "uploading 그대로(되돌린 항목은 다음 slice 가 처리)"가 실제로 성립하도록, 업로드 단계 끝에 `pending` 이 있으면 채우기(cursor 0)로 돌아가게 했다.
3. **2-4 깨우기 1회**: 채우기 slice 가 같은 실행에서 업로드 확인 단계로 넘어가면 그 단계의 기존 깨우기가 이미 부르므로 채우기 쪽은 부르지 않는다(중복 없음). 멈춤(paused)으로 끝나도 새 queued 가 있으면 1회 깨운다.
4. **공식 사이트 5xx/429 판별**: `StandaloneApiService` 가 일반 `Exception('상세 조회 실패 (id, 503)')` 을 던져, 문구의 HTTP 상태와 `네트워크 오류` 문구로 판별했다(API 서비스 예외 형은 바꾸지 않음). `result` 없는 상세 응답은 `prepare` 에서 `no_result` 로 확정했다.
5. **DB 잠김**: sqflite 에 잠김 전용 판별이 없어 `database is locked`·`(code 5)` 문구로 본다. `DatabaseException` 의 그 밖 오류는 고정적.
6. **점검 중 1회 전송 타이머**: `paused/maintenance` 는 자기 타이머를 걸지 않는다. 재개는 ① 평소 status(게이트 5분 poll·앱 복귀·백그라운드 주기 작업)가 `paused=false` 를 보면 `CommunityWiring` 이 깨우고 ② 재개 시각이 있으면 `community-upload-resume` 1회 작업이 status 를 한 번 본다. 포그라운드에 같은 시각 타이머를 따로 두지 않았다(같은 기기에서 status 를 두 번 부르지 않으려고).
7. **보류 깨우기 WorkManager**: `holds` 상태에서만 1회 작업을 건다(규칙 1절). 일시적 `paused` 는 기존 앱 타이머·1시간 주기 작업으로 충분해 따로 걸지 않았다. 재개 시각이 이미 지났는데 중지가 남은 경우(서버가 키를 안 줌)는 곧바로 다시 예약하지 않는다(루프 방지).
8. **저장 위치**: 중지 = `community.db meta`(PC 와 같음, 두 isolate 공유), 필수 버전 = SharedPreferences(루트 화면이 store 없이도 읽어야 함, 백그라운드는 `reload()`).
9. **`serverAccountMismatch` 의미 변경**: 규칙대로 32자리 16진 둘이 다를 때만 true. 예전 시험(`'aa','bb'` → true)을 갱신했다. 안내 카드 시험 파일은 같은 이름으로 잠금 시험으로 바꿨다(기존 시나리오의 기대 자체가 규칙으로 바뀜).
10. **Client 서버 잠김 문구**: PC 잠금의 `SERVER_UPGRADE_REQUIRED` 409 를 "PC 서버를 v3 이상으로…" 로 보이던 것을 규칙 11절 문구로 바꿨다(3.6.2 요구에서 "v3 이상"은 틀린 안내). 시험 기대값도 갱신.
11. **계정 불일치는 동의 판정보다 먼저**: 휴대폰 동의가 없거나 outdated 여도 계정이 다르면 잠금(동의 카드를 보이면 엉뚱한 계정 동의가 저장된다). 잠금은 PC 주소·키 범위로 저장해 재시작 뒤 PC 에 닿지 못해도 유지, 해제는 같은 지문 확인 또는 `account: null` 만.
12. **`client_server_checked.server_version`**: PC 게이트 응답에 버전이 없어 null(버전을 따로 묻는 요청을 늘리지 않음).
13. **첫 실행 모드 판정 기준**: "prefs `appMode` 비어 있음" 대신 `ReportProvider.isConfigured == false` 를 썼다(설정 화면의 모드 전환도 prefs 를 지우고 같은 상태가 된다). 고른 모드가 없으면 게이트 `mode_unselected` 이고 status 를 묻지 않는다.
14. **진행 보고 호출 판단**: D 도 상태 키·10분·하루 1번을 거르지만, 나도 호출 기록(`meta.raw_backfill_progress_call`)으로 같은 판단을 한 번 더 한다(불필요한 호출 감소). `start` 는 실제로 보낼 수 있을 때(연결 있음·중지/잠금 아님)만 소모한다. 진행 보고 뒤 `ProgressReporter.lastMaintenance` 가 있으면 `UploadPause.applyMaintenance` 로 넘기고 `clearMaintenance`.
15. **앱 버전 읽기**: 라이브러리 안에서 `PackageInfo` 를 부르면 위젯 시험의 가짜 시간에서 파일 읽기가 끝나지 않아 기존 게이트 시험이 시간 초과했다. 진입점(main·WorkManager 디스패처·알림 백그라운드)에서 `AppVersion.load()` 로 한 번 읽고, 모르면 헤더 생략·판정 안 함(먹통 방지).
16. **점검 중 백그라운드**: 업로드·동의 후 전체 수집(ConsentCatchup)을 건너뛰고 1회 전송 marker 만 `paused/maintenance` 로 둔다. 재개 1회 작업은 복구 업로드까지 한다.
17. **잠금 화면**: 데모는 잠그지 않는다(서버를 묻지 않음). 잠금 중 Android 뒤로 = 앱 종료. 업데이트 실패 안내는 설치 경로와 무관한 문장으로 했다.
18. **사용자 조치 배너·공지**: Standalone(데모 제외)에서만 배너, 공지는 게이트 통과(`canEnter`) 뒤·잠금 아님일 때 메인 진입과 앱 복귀에 부른다(6시간 간격은 D).
19. **`in_app_update` 5.0.0**: Play Core `app-update:2.1.0`. 디버그 APK 빌드로 Gradle 호환을 확인했다(릴리스 빌드는 NOT RUN).

## 3. 새 문구 (2-13)

| 위치 | 문구 |
|---|---|
| 점검 배너(재개 시각 있음) | 서버 점검 중입니다. 신고 업로드를 잠시 멈췄고, {오후 3시 30분 / 10월 23일 오전 9시}에 자동으로 다시 올립니다. |
| 점검 배너(재개 시각 없음) | 서버 점검 중입니다. 신고 업로드를 잠시 멈췄고, 점검이 끝나면 자동으로 다시 올립니다. |
| 점검 배너 둘째 줄 | {운영자 pause_message 평문} |
| 업데이트 잠금 제목 | 앱을 업데이트해 주세요 |
| 업데이트 잠금 본문 | 이 버전은 더 이상 신고를 공유할 수 없습니다. 최신 버전으로 업데이트하면 이어서 쓸 수 있습니다. 기기에 있는 신고 자료는 그대로 남아 있습니다. |
| 업데이트 잠금 버전 줄 | 필요한 버전: {2.5.1} 이상 |
| 업데이트 잠금 서버 문구 | {서버 message 평문} |
| 업데이트 버튼 | 업데이트 |
| 업데이트 화면 열기 실패 | 업데이트 화면을 열지 못했습니다. 잠시 뒤 다시 눌러 주세요. |
| Client: 서버가 잠김(PC 409) | 서버 프로그램 업데이트가 필요합니다. 서버 관리자에게 업데이트를 요청해 주세요. |
| Client 계정 불일치(이름 있음/없음) | 서버에 연결된 카카오 계정({서버 표시 이름})으로 다시 로그인해 주세요. / 서버에 연결된 카카오 계정으로 다시 로그인해 주세요. |
| Client 계정 불일치 버튼 | 로그아웃 후 다시 로그인 |
| Client 계정 불일치 로그아웃 실패 | 로그아웃하지 못했습니다. 다시 시도해 주세요. |
| 동의 저장 차단(모드 미선택·계정 불일치) | 지금은 동의를 저장할 수 없습니다. 안내에 따라 먼저 계정을 맞춰 주세요. |
| 서버 로그인 전 잠금 버튼 / 열린 화면 제목 | 서버의 커뮤니티 계정 열기 / 서버의 커뮤니티 계정 |
| 커뮤니티 미설정 서버(Client 상단) | 서버 관리자가 커뮤니티 설정을 마쳐야 공유됩니다. |
| 알림에서 여는 업로드 화면 제목 | 신고 공유 |

알림 4종·공지 버튼 문구는 D 보고서. 내부 용어(backfill·hold·run 등)는 화면 문구에 없다(코드 주석·로그 코드에만).

## 4. 시험

| 명령 | 결과 |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test test/community/backfill_resume_test.dart` | **38 통과**: 분류 벡터 20(표의 모바일 예 전부), 일시적 오류 40초 연속 → 보류 0·run `paused`·attempts 0·커서 그대로·간격 60→300·회복 시 0, 고정적 3회 → `hold`+`next_attempt_at`(+900)·시각 경과 → 자동 `pending`→다시 보류(hold_count 2, +3600)→오류 해소 뒤 queued, 30일 → `stale`·24시간 간격 유지, 버튼 즉시 재시도, 영수증 retry 3회 → 보류(`upload_retry`)·`blocked` → `not_eligible`, 채우기 slice queued → 업로더 wake 1회(새 queued 없으면 0), 점검 중 일 0·`maintenance`·조기 재개, 보류만 남은 `nextDelay`(900초·15초 하한·24시간 상한)·점검 중 null, SQLite 보류 처리·개수, 2-3 초기화 7종(보류·upload_rejected·다른 사유 유지·done 재개·done 유지·holds 재개·paused 대기 0·수동 로그인 유지·진행 상태 유지·run 없음) + **두 번째 실행 무변경**, 업로드 단계 pending 복귀 |
| `flutter test test/community/pause_update_test.dart` | **51 통과**: `version-vectors.json` 24건, 6-2 판정표(명시 잠금·null 해제·플랫폼 null·같거나 높음·키 없음 유지·해석 불가 유지·모양 틀림 유지), 게이트 연동(정상 응답 잠금 → 재시작 유지 → 5xx 유지 → 키 없음 유지 → null 해제), **먹통 회귀**(503·JSON 아님·배열 → 잠그지 않음), 잠금 화면 문구·평문 서버 문구·업데이트 버튼 주소, 업데이트 주소(Play/GitHub/잘못된 주소), 버전 헤더 2종, 중지 저장(지터 0~120·재시작 유지·키 없음 유지·연장 재예약·조기 재개)·재개 시각 없음 타이머 0·503 본문, **중지 동안 업로드 요청 0회**, 503 maintenance → 행 `retry_wait`·attempt 0·다음 시도 = 재개 시각, 백그라운드(중지 → 업로드 0·재개 1회 예약·재개 작업 업로드·잠금 → 업로드 0), 배너 문구 2종·평문, KST 시각, 첫 실행 모드(게이트 모드·`unselected` 는 status 0회·Standalone 선택 → `via=mobile_standalone`·Client 선택 → `via=mobile_client`) |
| `flutter test test/community/client_account_notice_test.dart` | **17 통과**(새 시험 3파일 합계 106 통과): 판정 함수·표, 같은 지문 통과, 다른 지문 잠금(서버 이름)·재시작 뒤 PC 미도달에도 유지·같은 계정 → 해제, `account: null` → 해제, **먹통 회귀 7종**(닿지 못함·예외/시간 초과·5xx·형식 이상·account 키 없음·빈 지문·형식 틀린 지문) 잠그지 않음, 503 미설정 → 잠그지 않고 안내만, 온보딩 필요 → 기존 잠금, 불일치가 동의 단계보다 먼저, 잠금 화면(문구·버튼·동의 카드 없음), 서버 계정 카드 버튼 |
| `flutter test`(전체) | 아래 5절 결과 |
| `python3 map/scripts/raw-ingest/check_contract.py --copies ../pc ../mobile` | 처음 실행 때 모바일 쪽 실패 0(실패 줄은 전부 `../pc`). 마지막 실행은 `PASS: 15 contract files; generator output reproduced; 2 copies`(C 가 PC 사본을 맞춘 뒤) |
| 공유 1회 전송 사례(`test/fixtures/raw_backfill_cases.json`, PC 와 같은 파일) | 바꾸지 않고 통과(`raw_backfill_test.dart`) |
| 디버그 APK 빌드 `SR_TEST_APPLICATION_ID=com.fentanest.mysafetyreport.brresume flutter build apk --debug` | 성공(`in_app_update` Gradle 포함) |
| 에뮬레이터 `sr_uitest_api35`(emulator-5580) 실제 앱 | ① 새 설치 첫 화면(모드 선택) — 게이트 캐시 `mode_unselected` 확인 ② prefs 에 잠금 판정을 넣고 실행 → 전체 화면 잠금(제목·본문·"필요한 버전: 2.5.1 이상"·`<b>` 가 글자 그대로 보이는 서버 문구·업데이트 버튼) ③ 업데이트 누름 → 사이드로드 설치본이라 즉시 업데이트 불가 → Play 주소를 브라우저로 엶, 뒤로 → 잠금 유지 ④ 판정 삭제 → 모드 선택 화면 ⑤ Client 선택 → 온보딩으로 진행(이 디버그 빌드는 커뮤니티 설정 dart-define 이 없어 `config_invalid` 안내). Flutter 오류 로그 0. 증거 `evidence/01~06*.png`. 끝난 뒤 에뮬레이터는 종료했다(시험 앱 ID `…brresume` 는 설치된 채로 둠) |

## 5. 전체 `flutter test`

- 최종: `flutter test -r expanded --timeout 120s` → **2572 통과, 19 건너뜀(골든 등 기존 skip), 실패 0** (`All tests passed!`).
- 중간에 고친 것(기록):
  - 1차 전체 실행: 게이트를 쓰는 위젯 시험 여러 개가 시간 초과 — 라이브러리 안의 `PackageInfo.fromPlatform()`(가짜 시간에서 파일 읽기가 끝나지 않음). → 판단 15(진입점에서 한 번 읽기)로 고침.
  - `single_login_test`·`entry_order_test` 실패 — `FirstRunMode.choice` 가 정적 값이라 시험 사이에 남음. → 앱 루트 `initState` 에서 비움(예전 State 필드 초기값과 같은 의미).
  - 규칙 변경에 따른 기대값 갱신 3곳(판단 9·10, `raw_backfill_review_test` 의 "보류만 남으면 null" → 보류 시각 깨우기).
  - `gate_review_test` "re-login after a server-confirmed revoke…": 로그인 뒤 고정 100ms 대기가 부하 큰 전체 실행에서 모자람(기준 커밋 단독 측정 42~49ms, 변경 뒤 57~63ms). 단언은 그대로 두고 대기를 "상태가 바뀔 때까지(최대 2초) + 진행 중 확인 합류"로 바꿨다(`test/community/gate_review_test.dart`).
  - `plate_group_performance_test`(5만 건 시간 예산 5초)가 한 번의 전체 실행에서 8초로 실패 — 병렬 부하 탓, 단독 실행 통과, 이번 변경과 무관한 코드. 최종 전체 실행에서는 통과.

## 6. NOT RUN
- 실제 카카오·안전신문고 로그인, 로컬/원격 Supabase 와의 왕복(진행 보고·status 실제 응답), 실제 PC 게이트와의 Client 계정 비교 — 합성 응답 시험만.
- Play 스토어 설치본의 In-App Updates 즉시 업데이트 실제 동작(에뮬레이터 사이드로드라 대체 경로만 확인), GitHub APK 설치본(`installerStore=com.google.android.packageinstaller`) 실기 확인.
- WorkManager 1회 작업(`community-upload-resume`·`community-raw-backfill-wake`)의 실제 OS 실행 시점(Doze) — 예약 호출·지연 계산만 시험.
- 점검 배너·계정 불일치 잠금·사용자 조치 배너의 실제 앱 화면(게이트 통과가 필요해 에뮬레이터에서는 못 띄움, 위젯 시험만). 에뮬레이터 APK 는 `AppVersion` 정리 전 빌드다(잠금 화면 코드는 같음).
- 릴리스 빌드·골든(폰트 없는 환경에서 자동 skip).
- D 의 실제 구현과 합친 상태의 시험(합치기는 검수자).

## 7. 남은 위험
- 일시적 판별이 문구에 기대는 부분(공식 사이트 HTTP 상태·DB 잠김)은 `StandaloneApiService` 문구가 바뀌면 고정적으로 떨어진다(그래도 보류 자동 재시도가 있어 영구 정지는 아님).
- 점검이 끝났는데 기기가 status 를 못 받으면(오프라인) 다음 성공 status 까지 업로드가 멈춘다(규칙대로 status 가 정본).
- 업로드 단계의 pending 복귀(판단 2)는 PC 와 같아야 한다 — C 에 알릴 것(아래 요청).
- 잠금 판정은 prefs 라 앱 데이터 삭제 시 풀린다(다음 status 에서 다시 잠김).
- 계정 불일치 잠금은 PC 주소·키가 바뀌면 저장값을 쓰지 않는다(다른 서버를 잠그지 않으려는 의도).

## 8. 요청
- **D(합칠 때)**: 진행 보고 503 은 지금처럼 `progress_report.maintenance` 기록 → 내가 읽어 `UploadPause.applyMaintenance` 로 넘긴다(`pause_message` 는 기록에 없어 null). setup-progress 요청에도 버전 헤더가 필요하면 `CommunityAccountClient.versionHeaders()` 를 쓰면 된다(규칙 4-2 "6-3 의 버전 헤더").
- **검수자**: 설정 화면의 버그 제보 호출에 D 의 새 인자 `deviceModel`(Android `Build.MODEL`)·짧은 OS 문자열(`Android 14`)을 붙여 달라 — 지금 내 폴더의 `support_links.dart` 시그니처에 없어 호출을 넣지 않았다. 기기 모델은 현재 앱이 MethodChannel 로 읽는 곳이 없어(내가 확인한 범위) 네이티브 한 줄이 필요할 수 있다.
- **C(PC)**: 판단 2(업로드 단계에 pending 이 남으면 채우기로 복귀)와 판단 1(공식 로그인 사유인데 수동 표시 없음 → 대기 0)을 PC 이행에도 같게 맞춰 달라. 공유 사례 파일 `raw_backfill_cases.json` 은 바꾸지 않았다.
- **A**: 없음. 규칙 문서와 다르게 구현한 곳 없음.
