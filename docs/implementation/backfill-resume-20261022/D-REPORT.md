# D 보고서 (모바일 주변, 2026-10-22)

작업 폴더 `mobile-ui`(branch feat/backfill-resume-ui, 기준 4c9b217b). 커밋·push 하지 않음. 원격 접속 없음. pubspec·lock 변경 없음.

## 1. 만든 파일

| 파일 | 내용 |
|---|---|
| `lib/community/report/progress_reporter.dart` | `ProgressReporter.maybeSend(...)`(약속된 시그니처 그대로) + `buildBody`(스키마 검사)·`lastMaintenance`·`clearMaintenance`·`stateKey` |
| `lib/community/report/setup_progress_reporter.dart` | `SetupProgressReporter.report(...)`(약속된 시그니처) + `buildBody` |
| `lib/community/report/report_env.dart` | 위 두 보고와 공지가 함께 쓰는 환경 읽기(공개 설정·토큰·앱 버전·플랫폼·KST 날짜·시계·HTTP 클라이언트). 시험이 바꿔 끼우는 hook 포함 |
| `lib/community/notify/user_action_notifier.dart` | `UserActionNotifier.evaluate(...)`(약속된 시그니처) + `load`·`clear`·`items`(앱 안 안내 상태) |
| `lib/widgets/user_action_banner.dart` | 상단 안내 위젯 `UserActionBanner({onLogin, onRetry})` |
| `lib/announcements/announcement_presenter.dart` | `AnnouncementPresenter.maybeShow(context, {mode, openModeSwitch})`(약속된 시그니처) |
| `lib/announcements/announcement_model.dart` | 응답 항목 검사 `AnnouncementParser`(응답·항목·`linkAllowed`) |
| `lib/widgets/announcement_popup.dart` | 팝업 위젯 `AnnouncementPopup` + `AnnouncementChoice` |
| `test/community/report/{progress_reporter,setup_progress_reporter}_test.dart`, `report_test_support.dart` | 보고 시험 |
| `test/community/notify_user_action_test.dart` | 알림·상단 안내 시험 |
| `test/announcements/announcement_test.dart` | 공지 시험 |
| `test/fixtures/backfill-resume/{progress_vectors,announcement_links,announcement_response.schema}.json` | 지도 레포 계약 파일 복사본(읽기만 한 원본: 진행 보고 벡터, 링크 허용 벡터, 응답 스키마) |

기존 파일 수정: `lib/services/support_links.dart`, `test/services/support_links_test.dart`. 사진 보조 값은 아래 4절.

## 2. B 가 붙일 곳

1. **진행 보고** — 호출 지점 (a) 앱 시작·게이트 통과 뒤 1회 `trigger:'start'`, (b) marker 가 바뀐 곳마다 `'state_change'`(상태 키가 같으면 내가 거른다), (c) 포그라운드 타이머·WorkManager 실행 때마다 `'periodic'`(10분 간격은 내가 지킨다), (d) `done` 이후 `'daily'`.
   `backfill` 맵은 progress.schema.json 의 `backfill` 객체 그대로(`state` 는 marker 상태 또는 `none`, 시각은 ISO `Z`, 모르는 개수는 null). `optimize` 의 세 키는 반드시 bool. `officialLogin` 은 `ok`/`retry`/`manual_required`. 모바일은 `pace` 를 항상 넘긴다.
   - 중지(5절)·필수 버전 잠금(6절) 중에는 **호출하지 않는다**(이 함수는 그 상태를 모른다).
   - 연결 ID 는 `store.activeContext()['connection_id']`, 토큰은 `CommunityAuthService.instance.getAccessTokenResult()` 에서 읽는다. 연결이 없으면 보내지 않는다.
   - **503 `maintenance`**: 보내다 받으면 `community.db` meta `progress_report.maintenance` 에 `{"at","resume_at","retry_after_s"}` 를 남긴다. B 는 호출 뒤 `await ProgressReporter.lastMaintenance(store)` 를 읽어 5절 중지 처리로 넘기고, 처리 뒤 `ProgressReporter.clearMaintenance(store)`. 마지막 시도 결과 요약은 meta `progress_report.result`(`{at,status,detail}`, 값 없음).
   - 백그라운드 isolate 와의 공유는 `community.db` meta(`progress_report.last`: 마지막 시도 시각·전송 성공한 상태 키·KST 날짜)로 한다. 별도 설정 없음.
2. **설정 단계 보고** — 단계가 바뀌는 곳에서 `SetupProgressReporter.report(stage, reason, mode, client)`. 순서 `kakao_ok → consent_ok → official_login_started → official_login_failed(+reason)/official_login_ok → connection_registered`, Client 는 `consent_ok` 대신 `client_server_checked`(+`client` 6키). `mode` 는 `standalone`/`client`/`demo`/`unselected`. 같은 내용 반복은 내가 거르고 `connection_registered` 성공 뒤에는 멈춘다(새 로그인 흐름의 `kakao_ok` 가 오면 다시 시작). 호출은 `await` 해도 되고 안 해도 된다(예외 없음).
3. **사용자 조치 알림** — 1회 전송 상태가 바뀔 때와 앱 시작·백그라운드 실행 끝에 `UserActionNotifier.evaluate(...)` 를 부른다. 화면 상단에는 `const UserActionBanner(onLogin: 공식 로그인 화면 열기, onRetry: 올리지 못한 신고 다시 시도)` 를 메인 화면 맨 위에 넣는다(조치가 없으면 높이 0). 조치가 끝났을 때(로그인 성공 등) 바로 안 보이게 하려면 `UserActionNotifier.clear()` 후 `evaluate`.
   - **알림을 누르면**: 기존 `showNotification` 채널을 쓰고 `nav_tab: 0`, `nav_event_type = user_action_<사유>`(`user_action_official_login_required`, `user_action_optimize_blocked_background`, `user_action_stale_holds`, `user_action_update_required`)로 열린다. B 가 `main.dart` `_handleNavigationEvent` 의 `switch (eventType)` 에 이 이름들을 추가해 공식 로그인 화면 / 업로드 화면(커뮤니티 업로드 패널이 있는 화면) / 잠금 화면으로 보내야 한다(탭 0 으로 먼저 이동하고 그 뒤 이벤트가 불린다). 이 이름 이외의 이동은 만들지 않았다(`main.dart` 는 안 건드림).
4. **공지** — 메인 화면 진입 때 `AnnouncementPresenter.maybeShow(context, mode: 'standalone'|'client'|'demo', openModeSwitch: _confirmModeReset 을 여는 콜백)`. 게이트·잠금 중에는 호출하지 않는다(그 판단은 B). 호출 중에 다시 호출하면 바로 돌아온다.
5. **문의 링크** — `SupportLinks.bugReport(...)` 시그니처는 그대로(기존 호출 변경 불필요). 새 선택 인자 `deviceModel`(기기 모델명)이 있다: 설정 화면에서 안드로이드 `Build.MODEL` 을 알면 넘기면 칸이 채워진다. `_osLabel` 이 `Platform.operatingSystemVersion`(긴 커널 문자열)이라 `os-version` 이 길다 — 80자에서 자르지만 B 가 `Android 14` 같은 짧은 값을 주면 더 낫다.

## 3. 새 문구 표 (2-13, 위치 포함)

| 위치 | 문구 |
|---|---|
| 알림(`user_action_notifier.dart`)·상단 안내 `official_login_required` | 안전신문고 로그인이 필요합니다. 앱에서 다시 로그인해 주세요. / 버튼 "로그인" |
| 알림 `optimize_blocked_background` | 신고 공유를 이어 가려면 앱을 한 번 열어 주세요. |
| 상단 안내 `optimize_blocked_background`(`user_action_banner.dart`) | 앱을 열어 두면 신고 정리를 마치고 공유를 이어 갑니다. (버튼 없음) |
| 알림·상단 안내 `stale_holds` | 30일 넘게 올리지 못한 신고가 {N}건 있습니다. 앱에서 확인해 주세요. / 버튼 "다시 시도" |
| 알림 `update_required` | 앱을 업데이트해 주세요. 업데이트하면 신고 공유를 이어 갑니다. (상단 안내는 그리지 않음, 잠금 화면이 맡음) |
| 알림 제목(`user_action_notifier.dart`) | 나만의 안전신문고 |
| 공지 버튼(`announcement_popup.dart`) | 일주일 동안 보지 않기(7일) / {N}일 동안 보지 않기 / 닫기 |
| 공지 `primary_action` 버튼 | 서버가 준 `label`(그대로, 20자 이하) |

"보류"·"backfill" 등 금지어는 쓰지 않았다. 느낌표·이모지 없음.

## 4. 판단

- **사진 보조 값 `expired` (2-6)**: `raw_backfill_runtime.dart` photo 블록은 이미 맞다. 보관 기간이 지난 신고는 시도하지 않고 `photoUnavailable = 'expired'`, marker 결과는 `'unavailable'`(성공 아님)으로 남긴다(702~706행). **고치지 않았다.**
- **GitHub 양식 드롭다운 채우기**: 이 환경에서는 GitHub 에 접속하지 않아 `platform`·`mode` 드롭다운이 쿼리로 채워지는지 **확인하지 못했다**(NOT RUN). GitHub 문서상 이슈 양식은 칸 id 쿼리(`?template=…&<id>=<값>`)를 받고 드롭다운은 보기 글자와 정확히 같을 때 채워진다고 알고 있어 `platform=Android|iOS`, `mode=Standalone 모드|Client 모드|데모` 를 넣었다. 값이 다르면 GitHub 이 무시하므로 해는 없다. 검수자가 실제 링크를 열어 확인하고, 안 채워지면 두 줄(`'platform': ?platform`, `'mode': ?mode`)을 지우면 된다. 본문(`body`) 쿼리는 양식에서 무시되므로 제거했다.
- **진행 보고 60초**: "마지막 시도"를 기준으로 막는다(성공/실패 무관). 실패 뒤 같은 상태도 다음 호출에서 다시 보낼 수 있게 `state_change` 비교 키는 **성공했을 때만** 갱신한다. 서버가 429 를 주는 기준과 맞추려면 시도 기준이 안전하다.
- **`trigger` 이름**: 지시의 세 값(`state_change`·`periodic`·`daily`)에 앱 시작용 `start` 를 더했다. 알 수 없는 값은 보내지 않는다. `daily` 는 `done`·`none` 에서만, 진행 중 상태에서는 `periodic` 이 맡는다.
- **설정 단계 보고 저장소**: 시그니처에 `CommunityStore` 가 없어 SharedPreferences(`setup_progress.last`, `setup_progress.done`)에 둔다. 실패(429 포함)는 "보낸 것"으로 기록하지 않아 같은 단계를 다음 호출에 다시 보낸다. `reason` 이 코드 형식이 아니면 값을 버리고 `other` 로 보낸다(문장·주소가 새지 않게). `client` 는 `client_server_checked` 이고 `mode=='client'` 일 때만 보내고 6키·값 형식이 틀리면 아예 보내지 않는다.
- **공지 캐시**: "닫기"는 이번 실행만이라 다음 실행에서는 다시 떠야 한다. 그런데 6시간 안에는 다시 가져오지 않으므로 마지막 정상 응답을 `app_announcement_cache`(SharedPreferences, 항목별 재검사)에 두고 쓴다. 마지막 시도 시각은 `app_announcement_attempt`. 가져오기가 실패하면 캐시를 지우고 아무것도 띄우지 않는다. 기기 시계로 `starts_at`/`ends_at` 를 다시 비교하지 않는다(서버가 이미 걸렀고 기기 시계 문제 방지).
- **공지 항목 검사**: 응답에 4개 이상·`protocol`≠1·모르는 최상위 키면 응답 전체를 버린다. 항목은 id 규칙·제목 40자·본문 600자(코드 포인트 기준)·제어문자(LF 만 허용)·키 집합이 틀리면 그 항목만 버린다. `primary_action` 은 모양이 틀리면 항목을 버리되, 허용 목록 밖 링크·모르는 `app_action` 은 규칙대로 **항목은 두고 버튼만** 숨긴다. 버튼을 누르는 순간에도 링크를 한 번 더 검사한다.
- **버튼 동작**: 본 동작 버튼을 누르면 그 공지는 이번 실행에서 닫힌 것으로 치고 다음 공지는 이번엔 띄우지 않는다(사용자가 다른 화면으로 갔다).
- **알림 권한**: `PermissionService.isNotificationPermissionGranted` 만 확인하고 요청하지 않는다. 권한이 없으면 알림을 보내지 않고 날짜도 기록하지 않아, 나중에 권한이 생기면 그날 처음으로 알린다. 표시가 실패해도 날짜를 기록하지 않는다.

## 5. 시험

실행: `cd mobile-ui && ~/development/flutter-3.47.5/bin/flutter test`(전체), `flutter analyze`.

- `flutter analyze`: **No issues found**(새 파일·수정 파일 포함 전체).
- 새 시험(전부 통과): 진행 보고(60초 억제·59초/61초, 상태 키 변경만, periodic 10분, daily KST 날짜, 연결 없음, 토큰 없음, 실패 5종 조용히 무시, 503 maintenance 기록, 계약 벡터 3), 설정 단계(같은 단계 반복 억제, `connection_registered` 뒤 중단·`kakao_ok` 재시작, 429 뒤 재전송, client 6키 검사 7가지, reason 정리, 금지 키 없음, 버전 헤더), 알림(사유별 문구·이벤트 이름, 하루 1번·KST 날짜 경계, 수동 표시 조건, 권한 없음, 표시 실패, 상단 안내 위젯), 공지(링크 벡터 18건, 응답 검사, 요청 쿼리 4개·`apikey` 만, 실패 4종 팝업 없음·6시간 간격, 한 번에 하나, HTML 평문, 7일 숨김·7일 뒤 다시·닫기, 버튼 문구, 모르는 `app_action`·허용 밖 링크, 허용 링크 열기, 모르는 모드), 문의 링크.
- 전체 `flutter test`: `+2511 ~19 -1`. 실패 1건은 `test/services/plate_group_performance_test.dart`(50k건 시간 예산) — 전체를 한꺼번에 돌릴 때 부하로 시간이 넘은 것이고, **단독 실행하면 통과**한다(이번 변경과 무관한 성능 시험).
- 계약 복사본: `test/fixtures/backfill-resume/` 3개 파일은 지도 작업 폴더 `contracts/` 의 현재 파일 복사다. 지도 쪽이 바뀌면 다시 복사해야 한다.

## 6. NOT RUN

- 실제 서버(206)·Edge 에 보내는 통합 시험, 실제 Android 기기/에뮬레이터에서 알림 표시·누르기·WorkManager isolate 동작, GitHub 새 이슈 화면에서 드롭다운 채움 확인, 공지 팝업의 실제 화면 캡처. 모두 가짜 HTTP·가짜 채널 시험만 했다.
- `AnnouncementPresenter`/`UserActionNotifier` 가 백그라운드 isolate 에서 `CommunityAuthService.instance` 를 쓰는 경로는 B 가 호출 지점을 정한 뒤 확인이 필요하다(`ReportEnv.accessToken` 은 포그라운드와 같은 서비스를 쓴다. 백그라운드 isolate 에서 인스턴스가 준비돼 있는지는 B 의 `upload_background.dart` 흐름 기준).

## 7. 요청 (다른 담당)

- **B**: 2절의 호출 지점 연결, `_handleNavigationEvent` 에 `user_action_*` 이벤트 추가, 설정 화면에서 `deviceModel`(선택)과 짧은 `osLabel` 전달, 5절(중지) 처리에서 `ProgressReporter.lastMaintenance` 사용. 새 패키지는 필요 없었다.
- **검수자**: GitHub 양식 드롭다운 채움 확인(4절), 합친 뒤 `flutter test` 전체 재실행.
