# 27개 발견 현행 재분류와 회귀 카드

현재 확인은 정적 코드 경로 확인이다. 운영 피해·실행 재현·테스트 PASS를 뜻하지 않는다. N-01은 최종 지원API 추가 근거 필요, N-08은 lifecycle 미재현이다. 모든 runtime 검증은 NOT_RUN. 구현 시 정확성 PR와 성능 PR를 분리한다. 각 위치는 현재 HEAD이며 전체 경로는 review-scope.csv에 있다.

| ID | 분류 | 단계 |
|---|---|---|
| DB-01 | 현재 확인 | PR1B1/3 |
| DB-02 | 현재 확인 | PR1B2/3 |
| DB-03 | 현재 확인 | PR3A1 |
| DB-04 | 현재 확인 | PR3A2 |
| DB-05 | 현재 확인 | PR3A2 |
| DB-06 | 현재 확인 | PR3A1 |
| UI-01 | 현재 확인 | PR3B1+PR5B(C03) |
| UI-02 | 현재 확인 | PR3B2 |
| UI-03 | 현재 확인 | PR3B/PR4A2/PR5A/PR6A |
| UI-04 | 현재 확인 | PR5A/5B |
| N-01 | 추가 근거 필요 | PR2C2 |
| N-02 | 현재 확인 | PR2B1 |
| N-03 | 현재 확인 | PR2B1 |
| N-04 | 현재 확인 | PR2A1 |
| N-05 | 현재 확인 | PR2C1 |
| N-06 | 현재 확인 | PR2B2/2C2 |
| N-07 | 현재 확인 | PR2C2 |
| N-08 | 미재현 | PR2D |
| N-09 | 현재 확인 | PR6B1/2 |
| S-01 | 현재 확인 | PR1C |
| S-02 | 현재 확인 | PR1A |
| S-03 | 현재 확인 | PR2A2+PR1C |
| S-04 | 현재 확인 | PR2A1/2 |
| S-05 | 현재 확인 | PR2B2 |
| S-06 | 현재 확인 | PR2B1 |
| S-07 | 현재 확인 | PR4B3 |
| S-08 | 현재 확인 | PR1A+PR4B1/2 |

## DB-01. 외부 snapshot의 WAL 실패를 무시하고 sidecar 제거

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_db_service.dart:3305 _prepareExternalDbSnapshot; 3735 importFromServerDb; 3967 replaceFromBackup
- **확인 사실:** WAL copy와 open/checkpoint catch가 비어 있고 결과행 검증 없이 sidecar 삭제 후 snapshot 반환.
- **기존 방어/하위 정정:** private copy·version/owner·staging·교체백업은 이미 있다. 원본에는 checkpoint하지 않는다.
- **발생 조건:** WAL-only commit 또는 필요한 WAL 복사/복구 실패. 단일 portable 백업 정상경로는 별도.
- **반증/추가 근거:** 실제 입력 producer가 오직 검증된 closed portable 파일만 공급한다는 모든 caller 증거가 있으면 적용범위를 축소한다. quick_check만으로 최신 commit을 반증하지 못한다.
- **변경 경계:** PR1B1/3; snapshot kind·WAL recovery 성공증거·copy/open failure 중단·publish 복구journal. SHM 재생성 가능 여부와 필요한 WAL 실패를 구분한다.
- **선행 fixture(승인 후):** WAL에만 존재하는 합성 commit, copy 권한 거절, open/checkpoint 실패, 동시 writer와 불완전 sidecar를 주입한다. 원본·destination·새 snapshot의 값을 각각 검사한다.
- **통과:** 필요 sidecar/검증 실패 시 publish 0, 기존 정상 destination 불변. 지원된 snapshot은 모든 commit 보존.
- **롤백/공동 의존:** private 임시본만 정리하고 기존 backup과 원본을 유지한다. checksum/quick_check만으로 값 보존을 대신하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## DB-02. 서버 DB 가져오기에서 원본 모집단 보존을 증명하지 않음

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_db_service.dart:3508 _validateServerDbSchema; 3569 _readServerTablePages; 3589 _readServerReportRows; 3801 put; 3816 reportId; 3916 report count
- **확인 사실:** INNER JOIN·cursor0·빈ID skip·REPLACE 및 count>0으로 전체 입력 보존을 입증하지 않는다.
- **기존 방어/하위 정정:** 정확한 version/owner 검사, unknown nonNULL 컬럼 거절, 128 JOIN·500 insert batch·private target은 보존. allNULL unknown 허용을 무조건 실패로 바꾸지 않는다.
- **발생 조건:** valid1+title/detail orphan1, category간 ID동일, rowid0/-1, numeric coercion·raw/member 관계와 정상0건.
- **반증/추가 근거:** 지원 contract가 이러한 입력을 금지하고 현 preflight가 모두 거절함을 입증하면 반증. 현재 validator는 그 검사 전체를 하지 않는다.
- **변경 경계:** PR1B2/3; 계약 entity별 키·관계·타입 preflight와 bounded keyed reconciliation. 기존 count검사는 보조로만 쓴다.
- **선행 fixture(승인 후):** valid1+title/detail orphan1, category 간 ID 충돌, 빈ID, raw/override/member orphan, 음수/0 rowid, 정상0건, 미래/미지원 컬럼. key 집합과 모든 컬럼 타입·값을 양방향 비교한다.
- **통과:** 지원 입력 완전 보존 또는 명확한 거절. count>0 또는 일부 행 검사로 성공 판정 금지.
- **롤백/공동 의존:** 동일 schema의 읽기/검증 개선을 우선한다. 컬럼/변환 의미 변경이면 C-07 공동 작업으로 이동하고 한쪽 배포하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## DB-03. 기관 TEMP lookup 동시 준비 충돌

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_db_service.dart:1598 _ensureAgencyLookup; 1636 getReportPage; local_paged_report_list.dart:85 _load
- **확인 사실:** lookup key 확인 뒤 CREATE/DELETE/DISTINCT/batch INSERT가 여러 await로 분리돼 있다.
- **기존 방어/하위 정정:** widget seq/epoch는 stale UI 적용을 막는다. runBackgroundWork는 close를 막지만 lookup 준비를 배제하지 않는다.
- **발생 조건:** 동일 connection 미캐시 agency/police query A/B interleave.
- **반증/추가 근거:** 모든 caller의 준비 admission이 단일 transaction/직렬 queue임을 강제 barrier로 입증하면 재분류. sqflite statement 직렬화만으로 여러 statement 준비 원자성은 아니다.
- **변경 경계:** PR3A1; connection/revision/registry별 준비Future+TEMP replacement transaction. 취소한 대기자는 publish/UI 적용만 중단, shared owner 취소와 구분.
- **선행 fixture(승인 후):** A-delete/B-delete/A-insert/B-insert를 barrier로 제어한다. registry 변경·실패 뒤 재시도·취소·revision 이동을 추가한다.
- **통과:** 부분 lookup 노출/숨긴 UNIQUE 오류0, 정확한 기관/경찰 필터. transaction executor 재진입 deadlock0.
- **롤백/공동 의존:** TEMP만 정리 가능하다. INSERT REPLACE나 catch-empty로 충돌을 숨기는 임시처방을 채택하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## DB-04. 지도 unknown을 중첩 처분 합계의 잔여로 재계산

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_db_service.dart:4513 _MapCellAccumulator; 4549 add; 4596 toJson
- **확인 사실:** add는 decided union으로 미확인을 직접 세지만 toJson이 remove후 처분합 잔여로 덮는다.
- **기존 방어/하위 정정:** 가중치와 셀 cluster 누산은 이미 있다. 중첩 분류를 유지한다.
- **발생 조건:** fine+reject 한 행과 unknown 한 행, weight2 및 multi-cell.
- **반증/추가 근거:** 실제 query가 모든 중첩 입력을 배제한다는 predicate 증거 없이는 배타 enum 가정 금지. 직접 union oracle로 반증한다.
- **변경 경계:** PR3A2; 직접 미확인값을 반환, overlap 표/overview 모집단 대조. clamp만 적용하는 안 기각.
- **선행 fixture(승인 후):** 두 행 중 fine+reject 한 행, unknown 한 행; 중첩 삼중, weight>1, multi-cell/viewport. direct predicate oracle와 비교한다.
- **통과:** unknown 비음수뿐 아니라 정확한 개수·전체/셀/overview 일치. clamp(0)만으로 반례를 숨기지 않는다.
- **롤백/공동 의존:** 순수 집계 함수 변경으로 분리하며 저장값 수정 없음. 원래 overlap 의미를 바꾸는 taxonomy 개편은 범위 밖이다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## DB-05. 집계 날짜와 좌표 유효성 규칙의 분기

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_db_service.dart:2260 _parseOverviewDate; 4266 _AgencyAgg.add; 2507 map valid SQL; 2693 _ensureMissingLookup; geocode_utils.dart:2 parseGeoDouble/officialGeoPayload
- **확인 사실:** overview는 strict UTC, 기관 평균은 local parse/difference. missing은 finite만, map은 world range+SQLite numeric typeof.
- **기존 방어/하위 정정:** officialGeoPayload는 별도의 한국 공식수집 범위32~39.5/124~132를 사용한다. 저장원문/공식쓰기정책 유지.
- **발생 조건:** invalid calendar/DST·역전, finite123/456·numeric string·NULL·world/Korea 경계.
- **반증/추가 근거:** 지원 입력에 invaliddate/범위밖/문자좌표가 없다는 추정만으로 반증하지 않는다. 공통 vector의 집합·표본수 대조 필요.
- **변경 경계:** PR3A2; calendar-day helper 공유. 읽기 map/missing은 world numeric 유효성을 맞추고 공식수집 Korean predicate는 별개 유지. numeric string 수용 확대는 교환계약 결정 전 보류.
- **선행 fixture(승인 후):** 윤일/2월30일/동일일/역전/UTC·Korea·DST, NULL·문자·경계·범위 밖 좌표. 표·overview·missing drilldown의 합집합 비교.
- **통과:** 동일 모집단·유효 표본과 일치, 원본 날짜/좌표 문자열 불변. 유효 자료를 표본 제한으로 버리지 않는다.
- **롤백/공동 의존:** 공유 벡터 변경이 필요하면 PC와 의미를 대조한다. 기존 잘못된 규칙 수정과 성능 이동을 구분한다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## DB-06. 실패한 DB open Future와 다중 조회 snapshot

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_db_service.dart:113 db; 205 _closeDb; 1708 getReportPage count/page; 2744 computeReportMapMissingGroups
- **확인 사실:** rejected initFuture reset이 await뒤여서 close/retry도 실패할 수 있다. count/page와 group/preview는 단일 snapshot이 아니고 rows.first 가정.
- **기존 방어/하위 정정:** summary/map native snapshot·stats CTAS snapshot·close/file barrier는 이미 구현됐다. 그 경로를 전체 미구현이라고 하지 않는다.
- **발생 조건:** one-shot open error·count와page 사이writer·마지막 preview행 삭제.
- **반증/추가 근거:** 외부 reset이 모든 실패를 항상 복구하고 read마다 같은 snapshot을 유지한다는 caller 근거로만 반증.
- **변경 경계:** PR3A1; identity-safe reset+exception-safe close, TransactionExecutor count/page/preview, empty group 처리와 bounded revision restart.
- **선행 fixture(승인 후):** 한 번만 open 실패 후 성공, old Future finally와 new open 경쟁, count 직후 삭제/변경, 마지막 preview 행 삭제, close barrier 중 취소.
- **통과:** 영구 재시작 요구 없이 정상 retry 회복, 불가능한 total/row 조합·rows.first 예외0, 사용 중 DB 강제close0.
- **롤백/공동 의존:** cache/connection state만 안전하게 정리한다. 오류를 빈 DB로 대체하거나 DB 파일을 지워 복구하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## UI-01. 최근 답변 더보기가 200건 preview를 전체처럼 표시

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_db_service.dart:1944 summary recent LIMIT200; report_provider.dart:160 recentAnswerReports/1194 refreshSummaryAndRecentAnswers; recent_answers_screen.dart:9/30 build
- **확인 사실:** 더보기는 summary 또는 category preview 목록 길이를 total처럼 사용하며 페이지/오류 상태가 없다.
- **기존 방어/하위 정정:** dashboard preview200·recent card lazy render·epoch 유지.
- **발생 조건:** recent201/1001, preview밖 recent, 모든category preview 로드 후 결과 변경·HTTP실패.
- **반증/추가 근거:** 화면의 모든caller가 별도 exact recent query로 재공급한다는 증거 있으면 반증. 현재 refresh는 summary만.
- **변경 경계:** PR3B1+PR5B(C03); recent query는 today snapshot·3일 양끝·정렬·번호dedupe·override·projection 일치. Client total API 제안은 보류.
- **선행 fixture(승인 후):** 199/200/201/1,001, preview 밖 최신 응답, 다른 카테고리 preview 로딩 순서, 자정·NULL·override·중복. 실패/loading·refresh도 widget 검사.
- **통과:** 로컬 page union과 전체 query oracle 동일, 정확한 total. 실패를 최근답변 없음으로 표시하지 않음.
- **롤백/공동 의존:** preview를 전체 로딩으로 되돌리지 않는다. Client의 완전한 total은 실제 공동 계약 연결 전 미완료로 남긴다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## UI-02. 외부 첨부 캐시가 filename만으로 재사용

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** report_detail_sheet.dart:563 _openExternal; client_media_access.dart:6/17
- **확인 사실:** temp 마지막filename 존재로 download를 생략하고 buffered http.get·writeAsBytes 후 외부열기.
- **기존 방어/하위 정정:** same-origin credential/protocol 검사와 이미지 decode 제한은 이미 구현. 정부/CDN 키전송 금지.
- **발생 조건:** 같은filename 다른resource/origin/계정·partial file·동시 download·epoch변경.
- **반증/추가 근거:** 모든 producer가 origin/account까지 포함한 globally unique immutable filename과 완성보장을 제공함을 입증하면 범위 축소. 현재 cache metadata 없음.
- **변경 경계:** PR3B2; keyed cache·part/ready metadata·stream budget/deadline/owned cancel. key확인 await뒤 owner/gen 재검사.
- **선행 fixture(승인 후):** A/a.pdf와 B/a.pdf, 키회전·로그아웃, 부분 파일·동시 다운로드·원격내용 변경·large media·Content-Length 없음·취소.
- **통과:** 서로 다른 identity 파일 재사용0, 미완성 파일 열기0, 오래된 credential 전송0. 사용자에게 저장한 export와 임시 cache를 구분한다.
- **롤백/공동 의존:** 새 코드에서 legacy filename cache를 신뢰하지 않는다. 사용자 파일을 cache cleanup으로 삭제하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## UI-03. bounded 목록의 요청 비용과 legacy 분기 정리

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** local_paged_report_list.dart:85~166 _load; statistics_screen.dart:253 _visibleRows/492 _buildBody
- **확인 사실:** Client category별 limit1 total후page 직렬요청, seq는 결과폐기. build마다 filter/toList/sort.
- **기존 방어/하위 정정:** 200 후보·ListView builder·sequence/epoch·현재페이지선택 보호 유지. enum deadbranch 후보는 제거 확정 아님.
- **발생 조건:** category all·page/filter burst·high-cardinality table·same-count수정.
- **반증/추가 근거:** 성능 저하는 미측정. trace가 요청/정렬비용을 보여주지 않으면 최적화 채택 보류. branch는 실제caller·enum 범위 대조후만 제거.
- **변경 경계:** PR3B/PR4A2/PR5A/PR6A; inflight/cancel·query세션total·revision view cache를 별도 변경, 파일정리는 마지막.
- **선행 fixture(승인 후):** 페이지경계·category 전환·20회필터burst·same-count revision·고카디널리티 표·IME/scroll. 요청 수와 build/정렬 실행 수를 계측한다.
- **통과:** 구응답 반영0, bounded ListView/선택 의미 유지. 빨라 보이는 대신 마지막 요청까지 오래 대기하게 만들지 않음.
- **롤백/공동 의존:** 정렬 cache/최적화 단위로 되돌릴 수 있어야 한다. 전량 category preload를 fallback으로 복원하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## UI-04. Client full-response와 UI-isolate JSON/모델 비용

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** api_service.dart:164 _decodeResponse/687 getWatchlist; report_provider.dart:1130 _fetchWatchlistNumbersImpl; client-read-handoff.md:5~13
- **확인 사실:** bytes→UTF8→JSON→Report 동기변환과 watchlist/fullendpoint가 남는다.
- **기존 방어/하위 정정:** 일반 category page와 viewportmap은 실제 연결돼 있고 full fallback을 하지 않는다.
- **발생 조건:** 긴원문·대형watchlist/duplicate/missing·slowbody·모드변경.
- **반증/추가 근거:** 전체bounded 주장을 입증하려면 서버 실제scoped page/total/membership 정본이 필요. decode jank/peak는 실행 전 미측정.
- **변경 경계:** PR5A/5B; 큰 순수decode offload는 transfer peak와 cancel을 포함한 실험. 기존full자료를 몰래 자르지 않는다.
- **선행 fixture(승인 후):** 대형 watchlist/duplicate/missing·긴원문, slow body, 계정전환·dispose, 동일scope 동시호출. raw 응답과 모델의 동시 보유량 계측.
- **통과:** 현재 전체 결과 누락0, UI jank와 memory 전후 제시. 모바일 페이지200만으로 Client 전부 bounded라는 완료 보고 금지.
- **롤백/공동 의존:** 정확한 기존 계약과 명시 한계를 유지한다. API 미지원 때 전체 필터 total을 부분 수치로 대체하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-01. Android24–25의 API26 notification 무조건 호출

- **분류/실행:** 추가 근거 필요 / NOT_RUN
- **현재 파일·함수·행:** MainActivity.kt:77/204 createAppNotifChannel; NotificationService.kt create*Channel/show*; SyncForegroundService.kt:98 createChannel; build.gradle.kts:32 minSdk
- **확인 사실:** API26 channel/builder 호출에 guard 없는 구조는 확인. Gradle은 flutter.minSdkVersion 상속.
- **기존 방어/하위 정정:** API24/25에서 실제 실행 가능한 APK인지 이번에 SDK upstream/merged manifest·APK를 검증하지 않았다. 입력의 minSdk24는 과거감사 근거.
- **발생 조건:** 최종minSdk≤25이고 onCreate/producer 호출되는 경우.
- **반증/추가 근거:** 고정 SDK 실제소스/merged manifest가 minSdk≥26임을 보여주면 하위API crash발견은 반증, 제품지원문구 문제는 별도. annotation으로 runtime경계를 숨기지 않음.
- **변경 경계:** PR2C2; APIguard+하위compat 기본안, minSdk상향은 기각. source static 검사후승인 fixture24/25/26 필요.
- **선행 fixture(승인 후):** API24/25/26 시작·각 알림·FGS와 NewApi lint, 실제 merged manifest. 더 높은 지원 API는 현 target/manifest 확인 후 추가.
- **통과:** 실제 지원하는 낮은 API에서 startup/알림 정상. 단순 lint annotation으로 runtime 경로 문제를 숨기지 않음.
- **롤백/공동 의존:** SDK 전면 업그레이드나 minSdk상향으로 처리하지 않는다. 채널 재생성으로 사용자 설정을 초기화하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-02. 서버 변경 뒤 기존 WS와 native side effect 세대 불일치

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** report_provider.dart:768 setConfig/795 setStandaloneConfig; WsService.kt:76 onStartCommand/107 startWsLoop; NotificationService.kt:66 sendEnqueue
- **확인 사실:** setConfig는 nativeoldsocket을 재연결하지 않고 running start가 무시된다. thread는 config를 capture해 await뒤POST.
- **기존 방어/하위 정정:** datasetEpoch·Dart compatibility invalidation, Standalone 전환 stopWs 방어는 유지.
- **발생 조건:** A socket열림→B/key-only→old event; probe 대기중logout·A→B→A.
- **반증/추가 근거:** 모든settingcaller가 반드시 stop/rebind하고 captured thread fence를 강제함을 증명하면 반증. 현재 setConfig 자체엔 없다.
- **변경 경계:** PR2B1; persistent configgeneration supervisor와 callback/dispatch/publish fence, oldscopecaptureunknown 보존.
- **선행 fixture(승인 후):** A WS열림+B변경, A→B→A, key-only, delayed version probe중 logout, old event/POST latecallback. 원격에 이미 접수된 경우도 별도로 모델링.
- **통과:** 새 세대에 old 결과/알림 반영0, 변경 뒤 stale work 신규 dispatch0. 이미 접수 가능한 요청을 취소성공으로 위장하지 않음.
- **롤백/공동 의존:** 옛 scope journal을 보존하고 새 서버로 자동 이전/재전송하지 않는다. Client→Standalone의 기존 stop 방어 유지.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-03. native gate freshness와 concurrent compatibility 결과

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** ClientGateGuard.kt:8 isOpen; ServerVersionCompatibility.kt:10/38 check; community_gate.dart requireFresh; contracts/community-ingest/gate.md
- **확인 사실:** native는 cache stateok만, timestamp/invalidated 미검사. shared volatile failure가 per-call result로 사용됨.
- **기존 방어/하위 정정:** probe timeout/finallydisconnect/protocol3/auth 거절은 있다. 600초fallback 허용자체는 반증대상이 아닌 승인정책.
- **발생 조건:** TTL초과·미래시각·재부팅·동시valid/invalid/auth probe.
- **반증/추가 근거:** 모든nativecaller가별도freshness/generation 검사한다면 해당부분 반증. 현재guard입력은cachedstate뿐.
- **변경 경계:** PR2B1; immutable probe result, gen별cache; 현60재확인/600fallback 의미보존·upperbound. stricterwrite60 변경은 공동결정전 보류.
- **선행 fixture(승인 후):** 599/600/601초·60초 action경계·future/malformed clock, valid/invalid/auth/network probe를 barrier로 섞는다.
- **통과:** 권한 거절을 다른 probe의 성공이 덮지 않음. 승인 정책과 native/Dart 결과 일치. timeout시 무한한 stale 허용 없음.
- **롤백/공동 의존:** 보수적 block과 기존 데이터 유지. 제품 offline 열람 허용을 임의로 없애거나 신규write에 확대하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-04. 알림 processing inbox의 200개 eviction

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** PrefsInbox.kt:15/20 put; NotificationService.kt:154 appendPendingReport; standalone_pending_queue_store.dart:13 read
- **확인 사실:** 모든prefix에MAX200 eviction. Dart번호dedupe는 이미eviction뒤이다.
- **기존 방어/하위 정정:** 고유키append가CSVlostupdate를 줄인다. history200 보관은 제품상 허용, processing과 분리.
- **발생 조건:** drain전201unique 또는 동일번호burst가다른번호를밀어냄.
- **반증/추가 근거:** nativequeue의producer가절대로200을넘지않는보장/내구handoff가선행됨을입증하면범위축소. 이력한도는그증거아님.
- **변경 경계:** PR2A1; durableevent 저장+claim·ACK, quota/overflow 명시, disk failure 성공표시 금지.
- **선행 fixture(승인 후):** 199/200/201/1,000 unique·동일번호 반복·동시 append/drain·process death·storage failure. legacy CSV migration도 검사한다.
- **통과:** ack 전 unique pending 유실0. storage 거절/overflow를 성공처리로 보고하지 않음. 오래된 이력 정리와 작업 삭제가 독립적.
- **롤백/공동 의존:** 새 queue 형식이 읽히지 않으면 차단·보존한다. 상한만 키우거나 무제한 List로 옮기는 안은 기각.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-05. 무관한 앱 알림 본문까지 필터 전에 로그

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** NotificationService.kt:42~63 onNotificationPosted/extractAndEnqueue; 139 standalone log
- **확인 사실:** allowlist전rawtitle/body로그, 허용이벤트신고번호로그가있다.
- **기존 방어/하위 정정:** 권한opt-in·allowlist·번호추출기능유지. 외부침해/임의앱log접근은확인하지않음.
- **발생 조건:** 무관앱알림또는허용알림수신.
- **반증/추가 근거:** 기본debug/release 모든빌드에서코드자체제거됨을증명하면반증. 현재R8rules는systembar API관련이고raw로그제거증거없음.
- **변경 경계:** PR2C1; 원문로그삭제와비식별분류계측. 실제원문을fixture로사용하지않음.
- **선행 fixture(승인 후):** 무관앱/허용앱 fake notification, 번호검출성공/실패, logcapture. debug/release 설정 모두 검사한다.
- **통과:** 기본 로그의 raw 알림/신고번호0, 정상 enqueue 유지. 단순 release logstrip에만 의존하지 않음.
- **롤백/공동 의존:** 진단을 위해 원문 logging을 기본 복구하지 않는다. 필요 분석은 별도 승인된 합성자료/비식별 계측을 사용한다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-06. native enqueue fan-out·deadline·알림 correlation

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** NotificationService.kt:91~125 sendEnqueue; WsService.kt:279~307 isAutoEnqueueActive/decrement
- **확인 사실:** match마다Thread·POSTtimeout없음·disconnect가finally밖, POST전auto_count증가.
- **기존 방어/하위 정정:** compatibilityprobe10초timeout/finally는이미있으나enqueuePOST수명과별개. 진행알림cancel finally는있다.
- **발생 조건:** burst/blackhole/headerbodystall·접수후응답유실·실패뒤수동crawl.
- **반증/추가 근거:** enqueue전반에상위deadline/correlation이적용됨을입증하면반증. counter10분만료는완전correlation아님.
- **변경 경계:** PR2B2/2C2; worker1·대기diskqueue·connect/read/overall deadline, unknown과accepted분리. C08전새멱등필드안보냄.
- **선행 fixture(승인 후):** blackhole/header-body stall/401/409/429/5xx, burst, accept후응답유실, 실패후수동crawl. worker최대/queueage/cleanup 관측.
- **통과:** 무한 thread/대기0, 실패한 auto시도가 이후 수동알림 억제하지 않음, unknown POST 자동중복전송0.
- **롤백/공동 의존:** raw thread로 되돌리는 대신 worker admission차단으로 안전복구. 신규 idempotency field는 C-08 승인 전 가정하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-07. notification/PendingIntent ID 충돌과 shortcut 재실행

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** NotificationService.kt:28 progressNotifId; MainActivity.kt:24 notifIdGen/187 handleNavIntent; main.dart:655~704 native route
- **확인 사실:** NS와MainActivity가같은untagged3000을쓸수있고navextras소비안함.
- **기존 방어/하위 정정:** auth/exportextras소비보호는이미있다. WS는2000부터이며감사표현처럼모든producer첫ID3000은아니다. 충분한burst시namespace충돌은남음.
- **발생 조건:** producer동시발행·progresscancel·quickintentActivity재생성.
- **반증/추가 근거:** 실제notificationtag/PI action/data가서로분리되고commandreceipt가소비된다면반증. 현재source경로엔보장없음.
- **변경 경계:** PR2C2; semanticnamespace/PIidentity·one-shotreceipt. PROJECT_RULES의Kotlin옛nav5/6보존과충돌않게mapping숫자는그대로.
- **선행 fixture(승인 후):** producer동시발행·progresscancel·WS1000건, Activity재생성·의도된 새shortcut/같은intent재전달, auth완료후재진입.
- **통과:** 서로 다른 알림 tap이 올바른 대상, 다른 progress를 cancel하지 않음. 소비된 command의 무심코 반복실행0.
- **롤백/공동 의존:** receipt/완료상태를 보존한다. 외부접수 exactly-once를 로컬 bool만으로 주장하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-08. FGS와 실제 Dart 실행 소유권은 별개

- **분류/실행:** 미재현 / NOT_RUN
- **현재 파일·함수·행:** SyncForegroundService.kt:27~112; sync_engine.dart:125 acquireFgs/138 releaseFgs; MainActivity FlutterFragmentActivity
- **확인 사실:** nativeFGS는engine/run을소유하지않고acquire실패catch무시·refcount는증가. timeoutDart통지는없음.
- **기존 방어/하위 정정:** backgroundcloseguard·refcount와FGS알림은이미있다. 실제Activity재생성/kill에서작업생존은이번실행금지로미재현.
- **발생 조건:** FGS시작거절/timeout·Activity재생성/taskremoval/processdeath.
- **반증/추가 근거:** HOME통과가아니라actualengine/run/DBwritercheckpoint관측이필요. embeddingengine생존정책에따라영향범위재분류.
- **변경 경계:** PR2D; acquireack/owner계측·checkpoint복구기본. headless재설계·force-stop지속약속은안함.
- **선행 fixture(승인 후):** HOME/resume·Activity재생성·taskremoval·processkill·FGS거절/timeout·nestedrefcount. force-stop은 별도 중단정책 검증.
- **통과:** 실제 일은 끝났는데 running알림만 남는 등 상태 불일치0, 미완료 작업 복구 또는 명시중단. 지원범위 증거와 일치.
- **롤백/공동 의존:** engine전면 재설계가 불필요하면 도입하지 않는다. 운영 앱 제거/force-stop을 일상 rollback으로 쓰지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## N-09. CI 검증·release 진단 보존과 보안 문서 불일치

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** .github/workflows/build-apk.yml:69~117/build-dev-apk.yml:33~57; PRIVACY_POLICY.md:60; report_provider.dart:788; AndroidManifest.xml:26
- **확인 사실:** 현재workflow는build/artifact/release중심,analyze/testgate없음·mappingretention1일. prefsAPIkey/cleartext지원이일괄Keystore/TLS문구와다름.
- **기존 방어/하위 정정:** mapping파일자체는이미보존한다. 서명없으면release실패·R8/shrink·fixtureappId보호도존재. 보안침해는미확인.
- **발생 조건:** refactorrelease검증누락·지원기간뒤crash분석·저장/전송보장해석.
- **반증/추가 근거:** 외부requiredcheck/장기mapping보관이존재하면CI영향축소;이번외부조회안함. secretmigration전readerinventory필요.
- **변경 경계:** PR6B1/2; signer-free검증gate/지원기간mapping·hash/source보존·문구정정. secure이전은native/background호환단위분리.
- **선행 fixture(승인 후):** 실패test가검증gate를차단, mapping검색, credential회전/로그아웃/중도migration, HTTP LAN/HTTPS fakeendpoint. R8/최종manifest조건도 실제artifact로 확인.
- **통과:** 빌드성공이 테스트성공으로 보고되지 않음. 문서와 실제 보장 일치, 서명/secret유출0. 미검증 플랫폼 NOT_RUN.
- **롤백/공동 의존:** LAN HTTP를 말없이 금지하거나 광범위SDK상향하지 않는다. 서명/배포 경계 변경 별도승인.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-01. rebuild가 pending/retryable 상세를 남긴 채 완료

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** sync_engine.dart:471~477/564~569 _run; community_rebuild.dart:73 RebuildEngine.run/363~395; rebuild_helpers.dart:32 mergeRebuildStaging
- **확인 사실:** detailerror누산후failed=false반환가능; engine은list/permanent만확인,commit/merge에서pending/retryable재검사없음.
- **기존 방어/하위 정정:** runId checkpoint·no-delete merge·list_complete·영구gap승인UI·backup은있다.
- **발생 조건:** first503·stop·item상태쓰기실패·validation직후newpending.
- **반증/추가 근거:** 실제engine에서전runitems가terminal일때만merge되는상위보장을입증해야반증. fake outcome테스트만으로닫지않음.
- **변경 경계:** PR1C; 영속run/item/owner/lease/list/gap집합검사와merge/완료표시같은communitytransaction. 개인DB와는checkpoint로연결.
- **선행 fixture(승인 후):** 실제engine+fakeHTTP detail503/stop/itemstate쓰기실패/retry승격/resume; 검증직후상태변경. 성공객체만 주입하는 테스트와 구분.
- **통과:** 미처리item이 남은 completed0; no-delete merge유지; local완료와 중앙ACK구분; publish직전owner/lease/gen일치.
- **롤백/공동 의존:** staging/journal과 이전정상projection보존. 실패run을 완료로 승격하여 gate를 해제하지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-02. 불완전한 HTTP 성공 목록으로 fullSync 삭제

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** sync_engine.dart:305~329 list loop/501~510 cleanup; standalone_api_service.dart:218~249; local_db_service.dart:3103 removeReportsNotIn
- **확인 사실:** HTTP200 resultnull/short/duplicate가예외없이수집되면nonempty+error0로부재reports/raw/override삭제가능.
- **기존 방어/하위 정정:** HTTP예외·stop·empty·rebuildno-delete보호는이미있다. firsttotal≠stableinventory.
- **발생 조건:** 401행page2누락/중복·동일total신규/삭제·emptyID·page이동.
- **반증/추가 근거:** upstreamactualstable snapshot/cursor 계약과collectedunique전부검사가증명돼야반증. total일치만으로아님.
- **변경 경계:** PR1A; conservativeupsert·보존·partial, stableevidence없는absencecleanup차단. localuserdelete신기능추가아님.
- **선행 fixture(승인 후):** 401건중short/duplicate/resultnull/emptyID/page이동/동시추가삭제/HTTP예외/stop. 값보존과 원격완전성 판정을 함께 검사.
- **통과:** 불완전 inventory의 reports/raw/override 삭제0, 정상 cleanup은 계약상 증거 있는 경우만. 기존 예외/stop 방어 유지.
- **롤백/공동 의존:** rollback도 검증안된삭제를 부활시키지 않는다. full inventory 대신 pagepreview를 삭제근거로 쓰지 않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-03. 실패·busy fallback과 일시 HTTP 오류가 큐에서 제거

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** standalone_auto_sync_service.dart:111~136 fallback/remove, 229~257 error; sync_engine.dart:182~215 start; standalone_api_service.dart:235 HTTP error
- **확인 사실:** start의busy는done0/errors0,failed결과는throw없이반환;drain무시후notInDb/otherError를remove.503도untypedotherError가능.
- **기존 방어/하위 정정:** Socket/timeout/token/auth/capturestore실패는큐보존하며fallback1회로폭주막음.
- **발생 조건:** busy/failedfallback·503→200·429→200·malformed200.
- **반증/추가 근거:** 모든오류가유형화되고fallback실패가remove전중단됨을입증하면반증. 현재일반Exception분기는남음.
- **변경 경계:** PR2A2+PR1C; typedtransport/outcome→drainACK. confirmedabsence/영구거절만명시terminal,unknown은보존.
- **선행 fixture(승인 후):** failed/busyfallback,503→200,429→200,malformed200,404/auth/DB쓰기실패. 각 분류별 queue상태/재시도횟수 검사.
- **통과:** 일시실패로 pending제거0, unknown을notfound로축소하지 않음, retry폭주0. 별점POST자동재시도금지.
- **롤백/공동 의존:** old/newtaxonomy어댑터를 남기고 미해석오류는보존/차단. empty성공으로fallback금지.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-04. sync/drain 소유권과 retry journal·queue ack 경쟁

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** sync_engine.dart:180 start; standalone_auto_sync_service.dart:58 drain; LocalDb:144 runBackgroundWork; capture_retry_store.dart:29~90 add/remove; pending_queue_store.dart:37 remove
- **확인 사실:** manual/drain별flag와refcount는상호배제아님. retryJSON RMWlostupdate,numberremove는reload후같은번호모든event삭제.
- **기존 방어/하위 정정:** uniqueappend·atomicflushrename·communityDB독립retry파일·closeguard유지.
- **발생 조건:** A/Badd·add/remove·fetch중same번호newevent·manual+resume.
- **반증/추가 근거:** 모든writer가하나의coordinator/RMW직렬영역을통과하고remove가claimkey만ACK함을입증하면반증.
- **변경 경계:** PR2A1/2; owner단일화·fallback재진입규칙·eventclaim·journalversion/lock. corruptretry를empty로덮어쓰는것도거절.
- **선행 fixture(승인 후):** A/Badd동시,add/remove,동일번호새event,manual+resume,logout/DBclose,commit후ACK전crash를barrier로강제.
- **통과:** pending/retryintent합집합보존,새event잘못ACK0,deadlock0,atomic저장결과일치.
- **롤백/공동 의존:** 새journal이읽히지않으면보존·차단. 파일rename성공만으로동시쓰기해결이라보고하지 않음.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-05. 전체 인증 body deadline과 실제 취소 경계 부족

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** standalone_auth_service.dart:109~124/186~203 login,373~425 relogin; standalone_api_service.dart:145~188 retry; sync_engine.dart:187~204/1168 stop
- **확인 사실:** headersclose15초timeout후bodyjoin은deadline없음;get.timeout은실제abort없음.stop가gateawait뒤reset될수있음.
- **기존 방어/하위 정정:** reloginisolate singleflight·auth/transient분리·ownedloginclientfinally·native큐취소방어는이미있다.
- **발생 조건:** headers-only/chunkstall·sharedrefreshwaiter중1취소·gate대기stop·atomic save도중UI이탈.
- **반증/추가 근거:** transport/body전체에상위deadline/abort가실제전달됨을입증해야반증. Futuretimeout만은아님.
- **변경 경계:** PR2B2; cancellableownedtransport·bodybudget·wholedeadline·cancelrequested/idle분리,atomic save일관완료와후속예약차단.
- **선행 fixture(승인 후):** headers-only/chunkstall/sharedrefresh/gate대기/retrydelay/auto-drainstop,stop후nativeSQL종료. requested와idle시각둘다계측.
- **통과:** 무한body대기0,폐기작업추가예약상한검증. 취소되지않은SQL을취소완료라표시하지않음.
- **롤백/공동 의존:** timeout늘리기·sharedclient무조건close금지. 기존background/filebarrier를유지한다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-06. uploader·gate의 나중 await에서 세대 검증 누락

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** community_uploader.dart:611~644 start/714~774 drain/1448 markInFlight; community_gate.dart:349~403/494~548
- **확인 사실:** startctx와laterfrontRowsactivectx가섞일수있고claim조건은eventid만. gateauthGencheck뒤owner/register/manifest/secureawait후최종fence없음.
- **기존 방어/하위 정정:** gate의status응답authGencheck·uploadleaseheartbeat·immutableevent/payload/revision은이미있다.
- **발생 조건:** 나중owner/register/manifest/securewrite중logout·batch중mode/context전환·oldACK.
- **반증/추가 근거:** 모든후속await의send/activate/ACKapply앞immutablegeneration·owner조건부commit이있으면반증. 중앙authority재검증은별도.
- **변경 경계:** PR2B1; samectxfrontRows/envelope·conditionalclaim·dispatch/localpublishfence. unknownACK옛scope에보존·personal_save_state필터추가안함.
- **선행 fixture(승인 후):** status외owner/register/manifest/securewrite지연중logout, batch중context/consentmode전환,oldACKcallback.
- **통과:** 새세대oldcontext활성화0,oldbatch신규dispatch0,불확실ACK보존. eventID/payload/revision/lease규칙유지.
- **롤백/공동 의존:** outbox를cache로보고삭제하지않는다. personal_save_state를새sendability조건으로임의추가하지않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-07. 정기 gate poll의 full manifest와 lease/client 소유권

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** community_gate.dart:232~237 poll/543 writer manifest; community_wiring.dart:79~105 refreshManifest; server_completed.dart:54~99; community_store.dart:268
- **확인 사실:** fullmanifestList/Set·행별insert·fixedowner manifest·clientclose누락·cursor전진검사없음.
- **기존 방어/하위 정정:** token/total/scope/unique검사와transaction DELETE+INSERT로실패시이전manifest보존은이미구현. 부분page때old먼저지움이라는하위해석은반증.
- **발생 조건:** unchangedpoll58k/500k·repeatedcursor·5분leaseexpiry/overlap·mode전환.
- **반증/추가 근거:** delta/unchanged정본과상위client수명/cursor/lease보호입증되면해당부분재분류.작업량은소스사실,latency는미측정.
- **변경 경계:** PR4B3; boundedstage+검증+atomicpublish·perrunowner/renew/finallyclientclose. 기존snapshot검증유지·deltaAPI안가정.
- **선행 fixture(승인 후):** 58k/500k unchangedpoll, repeatcursor,leaseexpire/overlaprefresh,partialpage·mode전환·clientclose 실패.
- **통과:** 실패시기존manifest보존,반복cursor무한루프0,정확한client수명. bytes/SQL/작업시간각각계측.
- **롤백/공동 의존:** 권한확인poll을성능때문에무조건생략하지않음. 계약없는deltaAPI·임의TTL연장금지.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.


## S-08. UI bounded 개선 뒤에도 sync 전량 상태와 반복 재집계

- **분류/실행:** 현재 확인 / NOT_RUN
- **현재 파일·함수·행:** sync_engine.dart:281~320/378~404/457~459/641~662; standalone_auto_sync_service.dart:211~224; duplicate_repository.dart:84~93
- **확인 사실:** accountsizeexisting/allItems/toSync·captureID보관,10건마다누적IDcount.단건drain/group결정뒤rebuild호출.
- **기존 방어/하위 정정:** rebuild는이미128digest·staging·boundedpublish·revisionretry이며raw전체Report물질화없음.
- **발생 조건:** 대형fullsync·긴queue·decisiononly·giant·foreignwriter.
- **반증/추가 근거:** 실제revisioncachehit로작업이없을수있는case는분리;호출횟수만으로매번fullcost단정안함. trace로examined/SQL/digestmiss입증필요.
- **변경 경계:** PR1A+PR4B1/2; narrowrunstaging·delta/reconcile·checkpointduplicatecoalesce·decisionfastpathlegacy동등. 정확한알림/ACK/pace보존.
- **선행 fixture(승인 후):** 계정규모증가,같은건수수정,긴queue,manual대표·giantgroup,동시foreignwriter. 총examinedID·SQLcall·retainedbytes·publish시간측정.
- **통과:** 단순최대batch뿐아니라누적작업량감소확인.legacyoracle동등·ACK/progress정확·cancel후추가작업상한.
- **롤백/공동 의존:** 기존boundedfullrebuild를검증된fallback으로유지.원문전체물질화·fsync생략·알림누락으로가속하지않는다.

**공통 추가 합격선:** baseline/after 모두 동일 synthetic seed와 같은 mode/owner/projection을 사용한다. 데이터·타입 차이0, 무통지 의무 유실0, 조기 완료0, stale-generation 반영0이다. 보호를 되돌리는 rollback은 허용하지 않는다. 성능은 plan.md §5의 미측정/원자료 정책을 따른다.
