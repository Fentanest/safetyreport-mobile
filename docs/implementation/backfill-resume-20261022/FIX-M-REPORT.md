# FIX-M 보고 · 모바일 출시 전 버그 수정 (2026-10-22)

- 대상: `backfill-resume-ws/mobile`, branch `feat/backfill-resume`, 기준 `87faa2ff`. **커밋하지 않았다**(작업 트리 변경만).
- 정본: 검수 종합 `BUGS.md` 의 "검수자 결정 D1~D11" 중 모바일 해당분과 "M 모바일" 절. 근거: `R1-REPORT.md`, `R5-REPORT.md`.
- 규칙 문서 `map/docs/implementation/backfill-resume-20261022/CLIENT-RULES.md` 는 읽기만 했다(문장 갱신은 S 담당).
- 원격 서버 접속 없음, 비밀값 출력 없음, PC 폴더 쓰기 없음. 버전 번호·`pubspec.yaml`·lock 변경 없음.
- R1 재현 시험(`scratchpad/r1/mobile/test/r1/*`)은 "버그가 있다"를 단언하던 것을 **고쳐졌다를 단언**하도록 바꿔
  `test/regression/fix_m/` 로 옮겼다(파일 이름은 주제별로 묶음).

## 버그별 수정

줄 번호는 이 작업 트리 기준.

| ID | 고친 곳(파일:줄) | 회귀 시험 | 판단 |
|---|---|---|---|
| **D1** 신고별 일시적 오류 상한 | `lib/community/raw_backfill.dart:209-222`(상수·제외 사유), `:474-497`(연속 5번이면 그 신고만 `holdItem`·커서 넘김, 그 전에는 `transient_attempts` 저장 뒤 run 쉼), `:458`·`:503`(성공·고정 보류 때 0). `lib/community/raw_backfill_runtime.dart:700-712`(공식 상세 응답이 JSON 이 아니면 `BackfillTransient('no_result')`) | `m_backfill_holds_test.dart`: "같은 신고가 연속 5번 일시적 오류면 그 신고만 보류하고 뒤 신고를 처리한다", "다른 작업의 잠금·DB 잠김·로그인 사유는 신고 탓이 아니라 세지 않는다", "성공하면 그 신고의 연속 횟수는 0 부터 다시 센다" | 보류 사유 `error='transient_<사유>'`, hold_count 규칙은 그대로. `sync_busy`·`db_locked`·`maintenance`·공식 로그인 2종은 세지 않는다. 다른 신고가 성공하면 run 의 `transient_failures=0`(기존 코드). 보류에서 풀린 신고(attempts=2)도 일시적 오류는 다시 5번까지 센다(일시적 오류는 attempts 와 별개) |
| **D2** 보류 횟수 유지 | `raw_backfill.dart:224-235`(`clearHoldHistory`), `:541-543`(업로드 확인 `stored` 때만 hold_count·first_held_at·next_attempt_at·stale 삭제) | `m_backfill_holds_test.dart`: "업로드 확인 retry 로 생긴 보류도 hold_count 를 이어 올리고 first_held_at 은 고정, stored 때만 지운다"(1→2→3→4), "보류에서 풀린 신고가 채우기에 성공해도 hold_count 를 지우지 않는다" | 모바일은 채우기 성공 때 지우지는 않았지만 `stored` 때도 지우지 않았다. '다시 시도' 버튼·첫 실행 초기화(`resetHold`)는 규칙대로 0 으로 되돌린다 |
| **R1-1 / D4** 점검 재개 뒤 업로더 지연 0 반복 | `lib/community/upload/community_uploader.dart:648-670`(재개 시각이 지났으면 `UploadPause.probeResume` 으로 status 한 번, 풀렸으면 그대로 업로드, 아니면 `nextAttemptAt = 지금+60초`), `lib/community/upload_pause.dart:186-214`(`statusProbe`·60초 간격 `probeResume`), `lib/community/community_wiring.dart:99-104`(포그라운드 확인 = 조용한 게이트 갱신), `lib/community/upload/upload_controller.dart:36-37,111-114`(쿨다운이 지난 시각을 주면 60초 뒤) | `m_pause_resume_test.dart`: "R1-1: 재개 시각이 지났는데 중지가 남아도 업로더가 쉬지 않고 돌지 않는다(다음 시도 ≥ 60초)"(예전 2초 1004회 → 1회), "D4: 재개 시각이 지났으면 status 를 한 번 불러 보고, 풀렸으면 그대로 이어서 올린다", "D4: 확인 결과가 없거나 아직 중지면 status 는 60초에 한 번만, 다음 시도는 지금+60초" | 백그라운드 isolate 에는 확인 경로를 두지 않았다(`statusProbe=null`) — 백그라운드는 루프가 없고 재개 확인은 WorkManager 1회 작업·주기 작업의 status 가 맡는다 |
| **R1-2 / D3** 필수 버전 잠금이 업데이트 뒤에도 남음 | `lib/community/update_requirement.dart:107-131`(`load()` 가 읽을 때마다 `cmp(지금, min) >= 0` 이면 잠금 아님 + 저장값 삭제, 해석 불가·버전 모름은 유지), `lib/screens/update_required_screen.dart:16-23`(로그인 인자), `:85-145`(로그인 동작·버튼 구역), `:243`(잠금 화면에 카카오 로그인·다시 로그인·다시 열기 버튼) | `m_locks_test.dart`: "업데이트해서 min 이상이면 읽자마자 풀리고 저장값도 지운다", "아직 min 미만이면 잠금 유지, 버전을 모르면(해석 불가) 마지막 판정 유지", "잠금 화면: 카카오 세션이 없으면 카카오 로그인 버튼이 있고 누르면 로그인을 연다", "잠금 화면: 재인증이 필요하면 \"카카오 다시 로그인\", 연결돼 있으면 버튼 없음" | 로그인 버튼은 세션이 없음(`disconnected`)·재인증 필요·브라우저 대기일 때만 보인다. 로그인을 마치면 게이트가 auth 변경으로 status 를 다시 받아 풀린다(기존 경로). 새 문구: "업데이트를 마쳤다면 카카오 로그인을 해 주세요. 로그인하면 바로 다시 확인합니다.", 버튼 "카카오 로그인"/"카카오 다시 로그인"/"카카오 로그인 다시 열기", 실패 "카카오 로그인 화면을 열지 못했습니다. 잠시 뒤 다시 눌러 주세요." |
| **R1-3** 보류+queued 공존 시 15초마다 WorkManager·status | `lib/community/raw_backfill_runtime.dart:159-161,183-199`(`holds` 상태에서 진행할 채우기(pending)가 없으면 다음 깨움 = min(가장 이른 보류 시각, 10분), 15초 하한) | `m_backfill_holds_test.dart`: "보류 1건 + queued 만 남으면 15초가 아니라 min(보류 시각, 10분)" | 포그라운드 타이머와 WorkManager 1회 작업이 같은 값을 쓴다. 확인 대기 항목은 업로더가 ACK 를 받아 오므로 10분이면 충분하다고 봤다(업로드 단계 60초보다 길지만 `holds` 는 보류가 있는 경우뿐) |
| **R1-4 / D4** 일찍 재개해도 503 행이 원래 시각까지 묶임 | `lib/community/upload_pause.dart:130-138`(status `paused=false` 면 저장된 중지가 없어도 먼저 행을 되돌림), `:165-184`(`releaseMaintenanceRows`: `retry_wait` + `last_error_code='maintenance'` 이고 미래 시각인 행의 `next_retry_at` = 지금) | `m_pause_resume_test.dart`: "R1-4: 운영자가 일찍 재개하면 503 maintenance 로 묶인 행이 곧바로 올라간다", "R1-4: 재개 확인은 maintenance 로 미룬 행만 되돌린다(426 등 다른 대기 행은 그대로)" | 중지 해제 알림(`UploadPause.current`)이 업로더를 깨우므로 행이 바로 올라간다 |
| **R1-5** Client 계정 불일치 잠금이 메모리에 남음 | `lib/community/gate/community_gate.dart:666-670`(모드가 바뀌면 메모리 잠금 버림, 서버 주소·키가 바뀌었으면 비동기 재확인), `:1401-1430`(범위 필드·`clientAccountLocked` 는 Client 모드에서만·`_revalidateClientAccountLock`), `:1454-1474`(저장 기록의 휴대폰 계정이 다르면 무시), `:1486-1496`(판정 때 서버 범위·휴대폰 계정이 바뀌었으면 저장값을 다시 읽음), `:1513-1520`(저장 기록에 휴대폰 카카오 계정 지문 `phone`) | `m_locks_test.dart`: "Client 에서 잠긴 뒤 Standalone 으로 바꾸면 메모리 잠금이 남지 않는다(동의 저장 가능)", "서버 주소를 바꾸면(새 서버와 비교 전) 이전 서버의 잠금이 남지 않는다" | 같은 서버로 Client 에 돌아오면 그 서버 범위의 저장된 잠금이 다시 적용된다(시험 포함). 다른 휴대폰 계정으로 잠근 기록은 무시하고 새로 비교한다. 온보딩 `consent_blocked` 조건은 getter 가 Client 모드로 좁혀져 그대로 둠 |
| **R1-6** WorkManager 엔진에서 사용자 조치 알림이 안 뜸 | `lib/community/notify/user_action_notifier.dart:76-101`(채널 호출이 `MissingPluginException` 이면 `user_action_alert` 키에 내용·시각 저장), `android/app/src/main/kotlin/com/fentanest/mysafetyreport/SafetyReportApplication.kt:26,43-51,61-62,64-105`(같은 프로세스 리스너가 키 변경을 듣고 `app_push_v2` 채널로 알림, 누르면 `nav_event_type` 으로 해당 화면) | `m_reports_test.dart`: "알림 채널이 없으면(WorkManager 엔진) 공용 저장소 키로 Kotlin 에 넘기고 오늘 알린 것으로 친다", "Kotlin 리스너가 같은 키 이름을 듣는다" | 기존 `standalone_auth_alert` 방식과 같다. Kotlin 쪽은 `areNotificationsEnabled()` 가 false 면 띄우지 않는다(Android 13 권한·사용자 끔). 사유별 알림 하나(태그 `user_action`) |
| **R1-7 / D5** 60초 억제된 상태 변화 유실 | `lib/community/report/progress_reporter.dart:41-61`(`maybeSend` 가 "보냈는가"를 돌려줌: 실제 요청을 했거나 서버가 이미 같은 상태를 받았으면 true, 60초 간격·토큰 없음 등 건너뜀은 false), `:105-221`(건너뜀은 `_skip` 로 false, `:272-275`); `lib/community/backfill_progress.dart:240-265`(보낸 경우에만 마지막 상태 키·start 표시 갱신) | `m_reports_test.dart`: "start 뒤 60초 안에 done 이 되어도 done 은 다음 tick 에 나간다"(예전 5시간 동안 `['uploading']` → 지금 `['uploading','done']`, 그 뒤 같은 날 재전송 없음) | "보냄" = 요청을 실제로 보냄(결과 무관). 실패한 요청은 규칙 4-1 "재시도하지 않는다"대로 다음 주기에 보낸다 |
| **R1-8** `AppVersion.load()` 를 바인딩 전에 | `lib/services/notification_background.dart:26-29`(순서 바꿈) | `m_reports_test.dart`: "R1-8: 알림 엔진은 바인딩을 먼저 만들고 앱 버전을 읽는다"(소스 순서 검사) | WorkManager 디스패처(`background_login_check.dart:34-36`)는 `DartPluginRegistrant` 뒤에 읽어 원래 문제 없음 |
| **R1-9 / D6** 옛 서버에서 설정 단계 보고 반복 | `lib/community/report/setup_progress_reporter.dart:18-23,63-75,168,189-206`(400·404 는 `{sig, at}` 기록, 같은 내용 24시간 억제. 200 이면 기록 지움. 429·5xx·네트워크·그 밖은 기록 안 함) | `m_reports_test.dart`: "404(옛 서버)는 보낸 것으로 치고 24시간 동안 같은 내용을 다시 보내지 않는다", "400 도 같다. 내용이 바뀌면 바로 보낸다", "429·5xx·네트워크는 기록하지 않고 다음 호출에 다시 보낸다" | 401·403·422 는 결정에 없어 지금처럼(기록 안 함) 두었다 |
| **R1-10** 503 반영 때 `pause_message` 를 null 로 덮음 | `lib/community/upload_pause.dart:152-163`(503 쪽 문구가 없으면 저장된 문구 유지), `progress_reporter.dart:240-268`(진행 보고 503 의 `pause_message` 도 기록), `backfill_progress.dart:266-275`(그 문구를 넘김) | `m_pause_resume_test.dart`: "R1-10: 503 쪽 문구가 없으면 status 로 받은 운영자 문구를 지우지 않는다"; `m_reports_test.dart`: "R1-10: 진행 보고가 받은 503 maintenance 의 운영자 문구를 버리지 않고 저장한다" | 업로더·manifest 503 도 같은 `applyMaintenance` 를 지나므로 함께 고쳐졌다 |
| **R5-6** 모바일 `contracts/app-announcements/` 사본 | `contracts/app-announcements/`(지도 작업 폴더에서 **마지막에** 다시 복사, 같은 바이트), `test/announcements/announcement_test.dart:43-79`(MANIFEST 해시·파일 목록 검사, 링크 벡터를 사본에서 읽음), `test/fixtures/backfill-resume/announcement_links.json`·`announcement_response.schema.json` 삭제 | `announcement_test.dart`: "사본이 MANIFEST.sha256 과 같다(지도 정본과 어긋나면 실패)", "벡터와 같은 결과" | `.gitignore` 에 걸리지 않음을 `git check-ignore` 로 확인(PC 의 R5-1 문제 없음). D-REPORT 의 fixture 표 줄은 지난 보고라 고치지 않았다 |
| **R5-5** 링크 허용 경계 | `lib/announcements/announcement_model.dart:182-201`(서버 SQL·Edge 와 같은 세 정규식으로 교체, 500자·공백/제어문자/`<>"\` 거부) | `m_announcements_test.dart`: "링크 허용은 서버(SQL·Edge) 정규식과 같다: 벡터 밖 경계 경우"(R5 표 14건 + 4건) | 예전 모바일은 대문자 호스트·`?`/`#` 바로 뒤 worklazy·특수문자를 서버와 다르게 판정했다 |
| **의심** 공지 팝업이 떠 있을 때 게이트 막힘 | `lib/announcements/announcement_presenter.dart:46-92`(`stillAllowed`·`watch`: 떠 있는 동안 막히면 팝업을 닫고 멈춤, "닫기"로 치지 않음), `lib/main.dart:1307-1320`(게이트 `canBrowse`·필수 버전 잠금을 넘김) | `m_announcements_test.dart`: "팝업이 떠 있는 동안 막히면 닫히고, \"닫기\"로 치지 않아 다음에 다시 보인다" | 막힘 = 둘러보기도 못 함(온보딩 화면으로 바뀜) 또는 필수 버전 잠금. 잠깐의 `canEnter` 흔들림으로 닫히지 않게 `canBrowse` 를 썼다 |

D7~D11 은 서버·콘솔 쪽(S·C 담당)이라 모바일 코드 변경 없음. D9(`v` 허용)는 모바일 `parseAppVersion` 이 이미 `^v?` 를 받는다.

## 검사 (Flutter 3.47.5, `~/development/flutter-3.47.5/bin/flutter`)

| 검사 | 결과 |
|---|---|
| `flutter analyze` | No issues found |
| 전체 `flutter test` | **2,645 통과, 19 건너뜀, 실패 0**(약 5분 10초). 성능 예산 시험도 이번에는 함께 통과 |
| 회귀 시험 `test/regression/fix_m/`(5개 파일 28건) + `test/announcements/` | 42 통과(계약 사본 마지막 재복사 뒤 다시 돌림) |
| `flutter build apk --debug` | 통과(Kotlin `SafetyReportApplication.kt` 컴파일 확인). `pubspec.yaml`·lock 변경 없음 |
| 계약 사본 | 지도 `contracts/app-announcements/` 를 마지막에 다시 복사 → `diff -r` 같음, `sha256sum -c MANIFEST.sha256` 모두 OK(links.json 52건) |

회귀 시험 파일:
- `test/regression/fix_m/m_backfill_holds_test.dart` — D1·D2·R1-3
- `test/regression/fix_m/m_pause_resume_test.dart` — R1-1·D4·R1-4·R1-10
- `test/regression/fix_m/m_locks_test.dart` — R1-2/D3·R1-5
- `test/regression/fix_m/m_reports_test.dart` — R1-7/D5·R1-9/D6·R1-10·R1-6·R1-8
- `test/regression/fix_m/m_announcements_test.dart` — 공지 팝업 의심 항목·R5-5

## 남은 것 · 확인하지 못한 것
- 실제 기기의 WorkManager 엔진에서 `user_action_alert` 알림이 뜨는 것(Kotlin 리스너)은 에뮬레이터·실기로 확인하지 않았다(트리거에 게이트 통과·백그라운드 작업 시점이 필요).
- 에뮬레이터(`sr_uitest_api35`)는 쓰지 않았다. 잠금 화면 카카오 로그인 → 복귀 → status 로 해제의 실제 왕복은 커뮤니티 설정(dart-define)이 있는 빌드와 서버가 필요해 위젯 시험으로만 확인했다.
- `CLIENT-RULES.md` 문장(D1~D11)은 S 담당이 갱신 중이며, 이 보고의 숫자(연속 5번, 10분, 60초, 24시간)는 BUGS.md 결정 그대로다.
