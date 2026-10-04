# 발견별 작업 카드와 근거 범위
문서 버전: mobile-refactor-plan-2026-10-04.1
**이 문서는 계획이다. 아래 모든 회귀·고장 주입·성능 검증은 현재 NOT_RUN이다.**
첨부 감사의 DB-01~06, UI-01~04, N-01~09, S-01~08 총27개 ID를 유지한다. 위험도는 운영 피해가 발생했다는 선언이 아니라 검증 우선순위다. 계획의 권장 처리안은 현재 구현과 구분한다.
## 1. 추적표

| ID | 위험도 | 이번 근거 수준 | 변경 단위 | 검증 상태 |
|---|---|---|---|---|
| DB-01 | P1 / P0 안전성 게이트 | RECHECKED_STATIC | PR1B | NOT_RUN |
| DB-02 | P1 / P0 안전성 게이트 | AUDIT_SOURCE | PR1B | NOT_RUN |
| DB-03 | P2 | AUDIT_SOURCE | PR3A | NOT_RUN |
| DB-04 | P2 | AUDIT_SOURCE | PR3A | NOT_RUN |
| DB-05 | P2 | AUDIT_SOURCE | PR3A | NOT_RUN |
| DB-06 | P2 | AUDIT_SOURCE | PR3A | NOT_RUN |
| UI-01 | P1 | BOUNDARY_RECHECKED | PR3B + PR5B(C-03) | NOT_RUN |
| UI-02 | P1 | AUDIT_SOURCE | PR3B | NOT_RUN |
| UI-03 | P2 | AUDIT_SOURCE | PR3B / PR4A / PR5A / PR6A | NOT_RUN |
| UI-04 | P2 | AUDIT_SOURCE | PR5A / PR5B | NOT_RUN |
| N-01 | P1 | AUDIT_SOURCE | PR2C | NOT_RUN |
| N-02 | P1 | AUDIT_SOURCE | PR2B | NOT_RUN |
| N-03 | P1/P2 | AUDIT_SOURCE | PR2B | NOT_RUN |
| N-04 | P1 | RECHECKED_STATIC | PR2A | NOT_RUN |
| N-05 | P1/P2 | RECHECKED_STATIC | PR2C | NOT_RUN |
| N-06 | P2 | RECHECKED_STATIC | PR2B / PR2C | NOT_RUN |
| N-07 | P2 | AUDIT_SOURCE | PR2C | NOT_RUN |
| N-08 | P2 | AUDIT_SOURCE | PR2D | NOT_RUN |
| N-09 | P2 | AUDIT_SOURCE | PR6B | NOT_RUN |
| S-01 | P1 / P0 안전성 게이트 | BOUNDARY_RECHECKED | PR1C | NOT_RUN |
| S-02 | P1 / P0 안전성 게이트 | RECHECKED_STATIC | PR1A | NOT_RUN |
| S-03 | P1 | AUDIT_SOURCE | PR1C / PR2A | NOT_RUN |
| S-04 | P1 위험 | AUDIT_SOURCE | PR2A | NOT_RUN |
| S-05 | P2 | AUDIT_SOURCE | PR2B | NOT_RUN |
| S-06 | P2 | AUDIT_SOURCE | PR2B | NOT_RUN |
| S-07 | P2 | AUDIT_SOURCE | PR4B (중앙 계약 확인) | NOT_RUN |
| S-08 | P2 | BOUNDARY_RECHECKED | PR1A / PR4B | NOT_RUN |

## 2. 상세 작업 카드

### DB-01. 외부 snapshot의 WAL 실패를 무시하고 sidecar 제거

**우선순위:** P1 / P0 안전성 게이트 · **이번 검토 수준:** RECHECKED_STATIC · **작업 단위:** PR1B

**근거 위치:** [A 부록 A / DB-01], `local_db_service.dart / _prepareExternalDbSnapshot`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** sidecar 복사·open·checkpoint 실패 처리와 사본 sidecar 삭제 구조를 이번 지정 구간에서 다시 확인했다. WAL-only commit 유실은 이번에 재현하지 않았다.

**권장 처리안:** 일관된 source export인지 먼저 구분한다. 외부 원본은 수정하지 않고 검증된 private snapshot 하나를 판별·변환에 재사용한다. 실패한 checkpoint를 단일 정상 snapshot으로 간주하지 않는다. 누락 WAL을 main 파일만 보고 언제나 탐지할 수 있다고 약속하지 않는다.

**선행 반례·고장 주입:** WAL에만 존재하는 합성 commit, copy 권한 거절, open/checkpoint 실패, 동시 writer와 불완전 sidecar를 주입한다. 원본·destination·새 snapshot의 값을 각각 검사한다.

**수용 조건:** 필요 sidecar/검증 실패 시 publish 0, 기존 정상 destination 불변. 지원된 snapshot은 모든 commit 보존.

**보존·롤백·의존성:** private 임시본만 정리하고 기존 backup과 원본을 유지한다. checksum/quick_check만으로 값 보존을 대신하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### DB-02. 서버 DB 가져오기에서 원본 모집단 보존을 증명하지 않음

**우선순위:** P1 / P0 안전성 게이트 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR1B

**근거 위치:** [A 부록 A / DB-02], `local_db_service.dart / _readServerReportRows 및 서버 DB import`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 첨부 감사의 JOIN·빈 ID·REPLACE·rowid 경계 발견을 유지한다. 감사의 작은 SQLite 식 점검은 실제 Dart 가져오기 실행과 다르다.

**권장 처리안:** 교환 entity의 지원 키·관계를 preflight에서 검증한다. orphan을 INNER JOIN으로 조용히 제거하지 않는다. 정상 rowid0/-1 허용 여부는 계약으로 결정하고 허용 입력을 cursor 시작값 때문에 누락하지 않는다. 128행 native JOIN은 보존한다.

**선행 반례·고장 주입:** valid1+title/detail orphan1, category 간 ID 충돌, 빈ID, raw/override/member orphan, 음수/0 rowid, 정상0건, 미래/미지원 컬럼. key 집합과 모든 컬럼 타입·값을 양방향 비교한다.

**수용 조건:** 지원 입력 완전 보존 또는 명확한 거절. count>0 또는 일부 행 검사로 성공 판정 금지.

**보존·롤백·의존성:** 동일 schema의 읽기/검증 개선을 우선한다. 컬럼/변환 의미 변경이면 C-07 공동 작업으로 이동하고 한쪽 배포하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### DB-03. 기관 TEMP lookup 동시 준비 충돌

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR3A

**근거 위치:** [A 부록 A / DB-03], `local_db_service.dart / _ensureAgencyLookup; local_paged_report_list.dart`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 동일 connection의 shared TEMP lookup 준비가 겹치는 정적 interleaving 과제다. 위젯 seq가 DB 작업 자체를 직렬화한다는 가정을 하지 않는다.

**권장 처리안:** connection·source revision·registry identity별 준비 Future를 single-flight로 공유하고 lookup 교체를 원자화한다. 실패 Future는 해당 identity일 때만 해제한다. waiting caller 취소를 검사한다.

**선행 반례·고장 주입:** A-delete/B-delete/A-insert/B-insert를 barrier로 제어한다. registry 변경·실패 뒤 재시도·취소·revision 이동을 추가한다.

**수용 조건:** 부분 lookup 노출/숨긴 UNIQUE 오류0, 정확한 기관/경찰 필터. transaction executor 재진입 deadlock0.

**보존·롤백·의존성:** TEMP만 정리 가능하다. INSERT REPLACE나 catch-empty로 충돌을 숨기는 임시처방을 채택하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### DB-04. 지도 unknown을 중첩 처분 합계의 잔여로 재계산

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR3A

**근거 위치:** [A 부록 A / DB-04], `local_db_service.dart / _MapCellAccumulator.add, toJson`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 첨부 감사는 중첩 fine+rejected와 unknown의 산술 반례를 제시한다. 실제 map Dart 메서드 검증은 후속 단계다.

**권장 처리안:** unknown 직접 누산값 또는 판정된 행의 union을 유지한다. 서로 중첩 가능한 disposition 합을 total에서 빼는 배타 가정을 제거한다. 원래 중첩 분류 자체는 유지한다.

**선행 반례·고장 주입:** 두 행 중 fine+reject 한 행, unknown 한 행; 중첩 삼중, weight>1, multi-cell/viewport. direct predicate oracle와 비교한다.

**수용 조건:** unknown 비음수뿐 아니라 정확한 개수·전체/셀/overview 일치. clamp(0)만으로 반례를 숨기지 않는다.

**보존·롤백·의존성:** 순수 집계 함수 변경으로 분리하며 저장값 수정 없음. 원래 overlap 의미를 바꾸는 taxonomy 개편은 범위 밖이다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### DB-05. 집계 날짜와 좌표 유효성 규칙의 분기

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR3A

**근거 위치:** [A 부록 A / DB-05], `local_db_service.dart / 날짜 집계·missing 조건; geocode_utils.dart`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** strict UTC calendar와 local parse, finite 좌표와 range 검사의 불일치는 첨부 감사 근거다. 실제 시간대별 Dart 실행은 미실행이다.

**권장 처리안:** 날짜 차이는 승인된 calendar-day 규칙으로 한 함수에 모으고 invalid/NULL/역전은 지표별 제외 이유로 남긴다. map/missing은 같은 좌표 유효 predicate를 사용한다.

**선행 반례·고장 주입:** 윤일/2월30일/동일일/역전/UTC·Korea·DST, NULL·문자·경계·범위 밖 좌표. 표·overview·missing drilldown의 합집합 비교.

**수용 조건:** 동일 모집단·유효 표본과 일치, 원본 날짜/좌표 문자열 불변. 유효 자료를 표본 제한으로 버리지 않는다.

**보존·롤백·의존성:** 공유 벡터 변경이 필요하면 PC와 의미를 대조한다. 기존 잘못된 규칙 수정과 성능 이동을 구분한다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### DB-06. 실패한 DB open Future와 다중 조회 snapshot

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR3A

**근거 위치:** [A 부록 A / DB-06], `local_db_service.dart / db getter, _initFuture, _closeDb, count/page/missing`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 실패 Future 잔존과 여러 read 사이 writer 변경은 첨부 감사의 제어흐름 과제다.

**권장 처리안:** identity-safe Future reset과 exception-safe close를 설계한다. count/page·group/preview는 짧은 snapshot 또는 제한된 revision retry를 쓰고 empty preview를 처리한다.

**선행 반례·고장 주입:** 한 번만 open 실패 후 성공, old Future finally와 new open 경쟁, count 직후 삭제/변경, 마지막 preview 행 삭제, close barrier 중 취소.

**수용 조건:** 영구 재시작 요구 없이 정상 retry 회복, 불가능한 total/row 조합·rows.first 예외0, 사용 중 DB 강제close0.

**보존·롤백·의존성:** cache/connection state만 안전하게 정리한다. 오류를 빈 DB로 대체하거나 DB 파일을 지워 복구하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### UI-01. 최근 답변 더보기가 200건 preview를 전체처럼 표시

**우선순위:** P1 · **이번 검토 수준:** BOUNDARY_RECHECKED · **작업 단위:** PR3B + PR5B(C-03)

**근거 위치:** [A 부록 A / UI-01], `recent_answers_screen.dart; report_provider.dart; local recent SQL`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 화면이 Provider 목록 길이와 empty 분기를 사용하며 페이지 UI가 없는 경계는 다시 확인했다. LIMIT200·Provider preview 재조립 전체 경로는 첨부 감사 근거다.

**권장 처리안:** 대시보드 preview 유지, 더보기는 exact recent count/page로 분리한다. 공통 최근3일 경계·정렬·override·projection을 유지한다. Client total 계약이 없으면 제한을 명시하고 숫자를 추측하지 않는다.

**선행 반례·고장 주입:** 199/200/201/1,001, preview 밖 최신 응답, 다른 카테고리 preview 로딩 순서, 자정·NULL·override·중복. 실패/loading·refresh도 widget 검사.

**수용 조건:** 로컬 page union과 전체 query oracle 동일, 정확한 total. 실패를 최근답변 없음으로 표시하지 않음.

**보존·롤백·의존성:** preview를 전체 로딩으로 되돌리지 않는다. Client의 완전한 total은 실제 공동 계약 연결 전 미완료로 남긴다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### UI-02. 외부 첨부 캐시가 filename만으로 재사용

**우선순위:** P1 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR3B

**근거 위치:** [A 부록 A / UI-02], `report_detail_sheet.dart / _openExternal; client_media_access.dart`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 동일 filename의 temp 재사용과 전체 buffer 문제는 첨부 감사 근거다. 실제 다른 사용자 파일 노출을 확인한 것은 아니다.

**권장 처리안:** resource/origin/dataset/account-generation 기반 cache key, 완료 metadata, atomic part→ready, byte/deadline/cancel 경계를 만든다. 자격증명을 filename/log에 쓰지 않고 same-origin credential 보호를 유지한다.

**선행 반례·고장 주입:** A/a.pdf와 B/a.pdf, 키회전·로그아웃, 부분 파일·동시 다운로드·원격내용 변경·large media·Content-Length 없음·취소.

**수용 조건:** 서로 다른 identity 파일 재사용0, 미완성 파일 열기0, 오래된 credential 전송0. 사용자에게 저장한 export와 임시 cache를 구분한다.

**보존·롤백·의존성:** 새 코드에서 legacy filename cache를 신뢰하지 않는다. 사용자 파일을 cache cleanup으로 삭제하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### UI-03. bounded 목록의 요청 비용과 legacy 분기 정리

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR3B / PR4A / PR5A / PR6A

**근거 위치:** [A 부록 A / UI-03], `local_paged_report_list.dart; statistics_screen.dart / _visibleRows; legacy branches`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** Client category별 total/page 직렬 요청, sequence만으로 무효 응답 폐기, build 시 copy/sort 비용과 dead branch 후보는 정적 과제다.

**권장 처리안:** 같은 query/세대의 total과 inflight를 재사용하고 취소를 전파한다. 정렬 view는 result revision·검색·종류·방향으로 memoize한다. dead branch는 caller/모드/테스트 확인 후 별도 삭제한다.

**선행 반례·고장 주입:** 페이지경계·category 전환·20회필터burst·same-count revision·고카디널리티 표·IME/scroll. 요청 수와 build/정렬 실행 수를 계측한다.

**수용 조건:** 구응답 반영0, bounded ListView/선택 의미 유지. 빨라 보이는 대신 마지막 요청까지 오래 대기하게 만들지 않음.

**보존·롤백·의존성:** 정렬 cache/최적화 단위로 되돌릴 수 있어야 한다. 전량 category preload를 fallback으로 복원하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### UI-04. Client full-response와 UI-isolate JSON/모델 비용

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR5A / PR5B

**근거 위치:** [A 부록 A / UI-04], `api_service.dart / JSON·Report decode; report_provider.dart; client-read-handoff.md`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 큰 full-response가 남는 계약 제한은 이번 인계 문서에서도 확인했다. 해당 decode 함수의 모든 분기를 새로 실행한 것은 아니다.

**권장 처리안:** 실제 bytes→UTF8→map→Report peak와 구간 시간을 먼저 측정한다. 큰 순수 decode isolate는 전달/취소 비용을 비교한다. 서버 membership/scoped page는 제안이므로 정본 확정 후에만 사용한다.

**선행 반례·고장 주입:** 대형 watchlist/duplicate/missing·긴원문, slow body, 계정전환·dispose, 동일scope 동시호출. raw 응답과 모델의 동시 보유량 계측.

**수용 조건:** 현재 전체 결과 누락0, UI jank와 memory 전후 제시. 모바일 페이지200만으로 Client 전부 bounded라는 완료 보고 금지.

**보존·롤백·의존성:** 정확한 기존 계약과 명시 한계를 유지한다. API 미지원 때 전체 필터 total을 부분 수치로 대체하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-01. Android24–25의 API26 notification 무조건 호출

**우선순위:** P1 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2C

**근거 위치:** [A 부록 A / N-01], `MainActivity.kt / createAppNotifChannel 및 모든 producer; Gradle/Manifest`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** API24~25 채널 호출은 첨부 감사의 고정 SDK·소스 근거다. 이번 merged APK/minSdk를 빌드 검증하지 않았다.

**권장 처리안:** 모든 NotificationChannel/getNotificationChannel 사용을 찾아 API26 guard 또는 지원 compat 경로를 둔다. 기존 channel ID/사용자 설정·FGS 동작을 보존한다. 지원 최소 버전은 묵시 변경 금지.

**선행 반례·고장 주입:** API24/25/26 시작·각 알림·FGS와 NewApi lint, 실제 merged manifest. 더 높은 지원 API는 현 target/manifest 확인 후 추가.

**수용 조건:** 실제 지원하는 낮은 API에서 startup/알림 정상. 단순 lint annotation으로 runtime 경로 문제를 숨기지 않음.

**보존·롤백·의존성:** SDK 전면 업그레이드나 minSdk상향으로 처리하지 않는다. 채널 재생성으로 사용자 설정을 초기화하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-02. 서버 변경 뒤 기존 WS와 native side effect 세대 불일치

**우선순위:** P1 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2B

**근거 위치:** [A 부록 A / N-02], `settings_screen / ReportProvider.setConfig; WsService; NotificationService`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** old socket·captured config의 전체 race 경로는 첨부 감사 근거다. native enqueue가 config를 포착하여 thread에서 쓰는 구간만 이번에 재열람했다.

**권장 처리안:** 연결 supervisor가 설정 publish·기존 work admission종료·새 세대 시작을 책임진다. config/key-only 변화도 native WS 재검증·재연결하며 send/callback/local commit에 generation fence를 둔다.

**선행 반례·고장 주입:** A WS열림+B변경, A→B→A, key-only, delayed version probe중 logout, old event/POST latecallback. 원격에 이미 접수된 경우도 별도로 모델링.

**수용 조건:** 새 세대에 old 결과/알림 반영0, 변경 뒤 stale work 신규 dispatch0. 이미 접수 가능한 요청을 취소성공으로 위장하지 않음.

**보존·롤백·의존성:** 옛 scope journal을 보존하고 새 서버로 자동 이전/재전송하지 않는다. Client→Standalone의 기존 stop 방어 유지.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-03. native gate freshness와 concurrent compatibility 결과

**우선순위:** P1/P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2B

**근거 위치:** [A 부록 A / N-03], `ClientGateGuard.kt; ServerVersionCompatibility.kt; community gate contract`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** state==ok만 검사하는 freshness 및 전역 volatile failure 결과 혼합은 첨부 감사의 정적 과제다.

**권장 처리안:** foreground/background와 열람/작업 정책표를 확정한다. per-call immutable probe 결과와 generation cache로 바꾸고 timestamp/재부팅/시각역행을 처리한다. 600초 허용 자체를 무조건 결함으로 보지 않는다.

**선행 반례·고장 주입:** 599/600/601초·60초 action경계·future/malformed clock, valid/invalid/auth/network probe를 barrier로 섞는다.

**수용 조건:** 권한 거절을 다른 probe의 성공이 덮지 않음. 승인 정책과 native/Dart 결과 일치. timeout시 무한한 stale 허용 없음.

**보존·롤백·의존성:** 보수적 block과 기존 데이터 유지. 제품 offline 열람 허용을 임의로 없애거나 신규write에 확대하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-04. 알림 processing inbox의 200개 eviction

**우선순위:** P1 · **이번 검토 수준:** RECHECKED_STATIC · **작업 단위:** PR2A

**근거 위치:** [A 부록 A / N-04], `PrefsInbox.kt / put; standalone_pending_queue_store.dart`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** HISTORY/PENDING/QUEUE에 동일 MAX_KEYS200 eviction이 적용되는 코드는 다시 확인했다. 실제 사용자 처리 누락은 재현하지 않았다.

**권장 처리안:** history 보관과 미처리 obligation을 분리한다. unique native event key를 durable 저장하고 claim단위 ACK 후 제거한다. RAM상한과 disk quota를 별도로 두고 overflow는 명시 상태로 처리한다.

**선행 반례·고장 주입:** 199/200/201/1,000 unique·동일번호 반복·동시 append/drain·process death·storage failure. legacy CSV migration도 검사한다.

**수용 조건:** ack 전 unique pending 유실0. storage 거절/overflow를 성공처리로 보고하지 않음. 오래된 이력 정리와 작업 삭제가 독립적.

**보존·롤백·의존성:** 새 queue 형식이 읽히지 않으면 차단·보존한다. 상한만 키우거나 무제한 List로 옮기는 안은 기각.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-05. 무관한 앱 알림 본문까지 필터 전에 로그

**우선순위:** P1/P2 · **이번 검토 수준:** RECHECKED_STATIC · **작업 단위:** PR2C

**근거 위치:** [A 부록 A / N-05], `NotificationService.kt / onNotificationPosted, extractAndEnqueue`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** package allowlist 전에 title/body를 로그에 쓰고 신고번호도 로그에 남기는 구조를 다시 확인했다. 실제 외부 유출을 조사한 것은 아니다.

**권장 처리안:** 필터 이전 원문 로그 제거. 허용 앱도 raw title/body/번호 대신 비식별 개수·유형·에러분류만 기록한다. 정상 검출과 사용자 동의/권한 흐름은 유지한다.

**선행 반례·고장 주입:** 무관앱/허용앱 fake notification, 번호검출성공/실패, logcapture. debug/release 설정 모두 검사한다.

**수용 조건:** 기본 로그의 raw 알림/신고번호0, 정상 enqueue 유지. 단순 release logstrip에만 의존하지 않음.

**보존·롤백·의존성:** 진단을 위해 원문 logging을 기본 복구하지 않는다. 필요 분석은 별도 승인된 합성자료/비식별 계측을 사용한다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-06. native enqueue fan-out·deadline·알림 correlation

**우선순위:** P2 · **이번 검토 수준:** RECHECKED_STATIC · **작업 단위:** PR2B / PR2C

**근거 위치:** [A 부록 A / N-06], `NotificationService.kt / sendEnqueue; WsService notification correlation`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** match별 Thread, POST 전 count증가, 해당 구간의 deadline/finally disconnect 부족은 다시 확인했다. WsService 전체 correlation은 첨부 감사 근거다.

**권장 처리안:** 제한된 worker·큐·owned connection deadline과 finallycleanup, 승인/시도/unknown outcome을 구분한다. 재시도는 endpoint 멱등 계약에 맞게만 한다. 알림 수명은 run결과에 묶는다.

**선행 반례·고장 주입:** blackhole/header-body stall/401/409/429/5xx, burst, accept후응답유실, 실패후수동crawl. worker최대/queueage/cleanup 관측.

**수용 조건:** 무한 thread/대기0, 실패한 auto시도가 이후 수동알림 억제하지 않음, unknown POST 자동중복전송0.

**보존·롤백·의존성:** raw thread로 되돌리는 대신 worker admission차단으로 안전복구. 신규 idempotency field는 C-08 승인 전 가정하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-07. notification/PendingIntent ID 충돌과 shortcut 재실행

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2C

**근거 위치:** [A 부록 A / N-07], `NotificationService/MainActivity/WsService; main.dart navigation intent`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** ID3000 충돌과 quick intent 재소비는 첨부 감사의 경로 과제다. 실제 notification tap이나 Activity재생성을 이번에 실행하지 않았다.

**권장 처리안:** semantic notification tag/ID와 PendingIntent action/data를 구분한다. FGS reserved namespace를 유지하며 passive route와 commandreceipt를 분리한다.

**선행 반례·고장 주입:** producer동시발행·progresscancel·WS1000건, Activity재생성·의도된 새shortcut/같은intent재전달, auth완료후재진입.

**수용 조건:** 서로 다른 알림 tap이 올바른 대상, 다른 progress를 cancel하지 않음. 소비된 command의 무심코 반복실행0.

**보존·롤백·의존성:** receipt/완료상태를 보존한다. 외부접수 exactly-once를 로컬 bool만으로 주장하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-08. FGS와 실제 Dart 실행 소유권은 별개

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2D

**근거 위치:** [A 부록 A / N-08], `SyncForegroundService.kt; MainActivity; sync_engine acquire/release`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** FGS가 알림 wrapper이고 실제 engine owner가 별개라는 감사의 구조 해석을 출발점으로 한다. 실제 lifecycle은 미검증이다.

**권장 처리안:** FGS/engine/run/journal/DB owner를 먼저 계측한다. 시작실패와 refcount/timeout을 연결하고 checkpoint복구를 기본안으로 둔다. headless 소유권 변경은 별도 승인한다.

**선행 반례·고장 주입:** HOME/resume·Activity재생성·taskremoval·processkill·FGS거절/timeout·nestedrefcount. force-stop은 별도 중단정책 검증.

**수용 조건:** 실제 일은 끝났는데 running알림만 남는 등 상태 불일치0, 미완료 작업 복구 또는 명시중단. 지원범위 증거와 일치.

**보존·롤백·의존성:** engine전면 재설계가 불필요하면 도입하지 않는다. 운영 앱 제거/force-stop을 일상 rollback으로 쓰지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### N-09. CI 검증·release 진단 보존과 보안 문서 불일치

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR6B

**근거 위치:** [A 부록 A / N-09], `build-apk/build-dev workflows; proguard/manifest; prefs/secure storage/정책문서`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 검증gate·mapping보존·저장/전송 문서 불일치는 감사 출발점이다. 현재 릴리즈 artifact나 침해를 검증한 것은 아니다.

**권장 처리안:** 서명없는 analyze/Flutter/Kotlin/contract 검증과 release를 분리한다. mapping/source/artifact hash를 지원기간에 맞게 보존한다. native/background까지 포함한 secret migration과 LAN HTTP 호환 설명을 대조한다.

**선행 반례·고장 주입:** 실패test가검증gate를차단, mapping검색, credential회전/로그아웃/중도migration, HTTP LAN/HTTPS fakeendpoint. R8/최종manifest조건도 실제artifact로 확인.

**수용 조건:** 빌드성공이 테스트성공으로 보고되지 않음. 문서와 실제 보장 일치, 서명/secret유출0. 미검증 플랫폼 NOT_RUN.

**보존·롤백·의존성:** LAN HTTP를 말없이 금지하거나 광범위SDK상향하지 않는다. 서명/배포 경계 변경 별도승인.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-01. rebuild가 pending/retryable 상세를 남긴 채 완료

**우선순위:** P1 / P0 안전성 게이트 · **이번 검토 수준:** BOUNDARY_RECHECKED · **작업 단위:** PR1C

**근거 위치:** [A 부록 A / S-01], `sync_engine run result; community_rebuild / _runToCompletion,_commit; rebuild_helpers`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** rebuild controller가 listComplete/permanentFailures 뒤 commit하는 경계는 다시 확인했다. engine/merge 모든 branch와 실제 실패 재현은 첨부 감사 범위다.

**권장 처리안:** run별 영속 item상태를 commit 직전 검사하고 pending/retryable0을 요구한다. permanent gap은 승인한 현재run목록만 허용한다. cancelled/busy/partial을 success와 구분한다.

**선행 반례·고장 주입:** 실제engine+fakeHTTP detail503/stop/itemstate쓰기실패/retry승격/resume; 검증직후상태변경. 성공객체만 주입하는 테스트와 구분.

**수용 조건:** 미처리item이 남은 completed0; no-delete merge유지; local완료와 중앙ACK구분; publish직전owner/lease/gen일치.

**보존·롤백·의존성:** staging/journal과 이전정상projection보존. 실패run을 완료로 승격하여 gate를 해제하지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-02. 불완전한 HTTP 성공 목록으로 fullSync 삭제

**우선순위:** P1 / P0 안전성 게이트 · **이번 검토 수준:** RECHECKED_STATIC · **작업 단위:** PR1A

**근거 위치:** [A 부록 A / S-02], `sync_engine.dart / 목록 loop, removeReportsNotIn 호출`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 목록 예외0·stop아님·nonempty조건 후 absence삭제 호출을 다시 확인했다. 실제 upstream목록 snapshot 의미·유실은 미검증이다.

**권장 처리안:** 형태/page/uniqueID/total/전진/동시변경을 검증한 inventory결과를 만든다. count일치만으로 완전성선언금지. 안정된근거없으면 부재행을 유지하고 비파괴재확인 대상으로 둔다.

**선행 반례·고장 주입:** 401건중short/duplicate/resultnull/emptyID/page이동/동시추가삭제/HTTP예외/stop. 값보존과 원격완전성 판정을 함께 검사.

**수용 조건:** 불완전 inventory의 reports/raw/override 삭제0, 정상 cleanup은 계약상 증거 있는 경우만. 기존 예외/stop 방어 유지.

**보존·롤백·의존성:** rollback도 검증안된삭제를 부활시키지 않는다. full inventory 대신 pagepreview를 삭제근거로 쓰지 않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-03. 실패·busy fallback과 일시 HTTP 오류가 큐에서 제거

**우선순위:** P1 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR1C / PR2A

**근거 위치:** [A 부록 A / S-03], `standalone_auto_sync_service drain/fallback; SyncRunResult; standalone API errors`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** failed/busy후notInDb·일시HTTP오류의 queue소비는 첨부 감사의 반환/오류분류 흐름이다.

**권장 처리안:** API→sync→drain→rebuild에 typedtaxonomy를 전파한다. failed/blocked/cancelled/partial은pending유지, busy는join/defer, 확정absence만 명시영구결과. Retry-After는 멱등읽기 중심 적용.

**선행 반례·고장 주입:** failed/busyfallback,503→200,429→200,malformed200,404/auth/DB쓰기실패. 각 분류별 queue상태/재시도횟수 검사.

**수용 조건:** 일시실패로 pending제거0, unknown을notfound로축소하지 않음, retry폭주0. 별점POST자동재시도금지.

**보존·롤백·의존성:** old/newtaxonomy어댑터를 남기고 미해석오류는보존/차단. empty성공으로fallback금지.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-04. sync/drain 소유권과 retry journal·queue ack 경쟁

**우선순위:** P1 위험 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2A

**근거 위치:** [A 부록 A / S-04], `sync_engine/start; auto_sync/drain; LocalDbService.runBackgroundWork; retry journal; queue ack`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 개별 flag/refcount·atomicrename만으로 업무상호배제와RMW를보장하지 못한다는 정적interleaving과제다.

**권장 처리안:** account/dataset coordinator와runID,drain→fallback재진입규칙을 정의한다. claimtoken별ACK, journalRMW직렬화/CAS로합집합보존. communityDB고장때도복구경로존속.

**선행 반례·고장 주입:** A/Badd동시,add/remove,동일번호새event,manual+resume,logout/DBclose,commit후ACK전crash를barrier로강제.

**수용 조건:** pending/retryintent합집합보존,새event잘못ACK0,deadlock0,atomic저장결과일치.

**보존·롤백·의존성:** 새journal이읽히지않으면보존·차단. 파일rename성공만으로동시쓰기해결이라보고하지 않음.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-05. 전체 인증 body deadline과 실제 취소 경계 부족

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2B

**근거 위치:** [A 부록 A / S-05], `standalone_auth_service / relogin body; standalone API; sync stop`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** headers뒤body무한대기·Future.timeout과실제abort차이는첨부감사및공식Dart설명이다. 장치취소시간은미측정이다.

**권장 처리안:** wholeoperation/bodybyte/deadline과ownedabort를 설계한다. await사이취소검사,sharedrefresh의대기자소유권,atomic저장완료와후속예약금지를구분한다.

**선행 반례·고장 주입:** headers-only/chunkstall/sharedrefresh/gate대기/retrydelay/auto-drainstop,stop후nativeSQL종료. requested와idle시각둘다계측.

**수용 조건:** 무한body대기0,폐기작업추가예약상한검증. 취소되지않은SQL을취소완료라표시하지않음.

**보존·롤백·의존성:** timeout늘리기·sharedclient무조건close금지. 기존background/filebarrier를유지한다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-06. uploader·gate의 나중 await에서 세대 검증 누락

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR2B

**근거 위치:** [A 부록 A / S-06], `community_uploader run/batch/context; community_gate 후속 await`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 후속await generation보호빈틈은감사의context/mode race과제다. 중앙의무단수락을증명한것은아니다.

**권장 처리안:** immutableauth/mode/contextgeneration과조건부claim,send·localcommit전fence를둔다. owner/register/manifest/securewrite후에도검사하고staleactivation을막는다.

**선행 반례·고장 주입:** status외owner/register/manifest/securewrite지연중logout, batch중context/consentmode전환,oldACKcallback.

**수용 조건:** 새세대oldcontext활성화0,oldbatch신규dispatch0,불확실ACK보존. eventID/payload/revision/lease규칙유지.

**보존·롤백·의존성:** outbox를cache로보고삭제하지않는다. personal_save_state를새sendability조건으로임의추가하지않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-07. 정기 gate poll의 full manifest와 lease/client 소유권

**우선순위:** P2 · **이번 검토 수준:** AUDIT_SOURCE · **작업 단위:** PR4B (중앙 계약 확인)

**근거 위치:** [A 부록 A / S-07], `community_gate poll; community_wiring; server_completed; community_store manifest`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 60초poll의fullmanifest작업량·lease/client/cursor과제는소스기반추론이다.운영latency를실측하지않았다.

**권장 처리안:** 변경없음/version/delta지원은실제정본에서확인한다. full필요시boundedstaging·cursor전진·유일키·owner검증뒤atomicpublish. per-runlease/renewal·ownedclientfinallyclose.

**선행 반례·고장 주입:** 58k/500k unchangedpoll, repeatcursor,leaseexpire/overlaprefresh,partialpage·mode전환·clientclose 실패.

**수용 조건:** 실패시기존manifest보존,반복cursor무한루프0,정확한client수명. bytes/SQL/작업시간각각계측.

**보존·롤백·의존성:** 권한확인poll을성능때문에무조건생략하지않음. 계약없는deltaAPI·임의TTL연장금지.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

### S-08. UI bounded 개선 뒤에도 sync 전량 상태와 반복 재집계

**우선순위:** P2 · **이번 검토 수준:** BOUNDARY_RECHECKED · **작업 단위:** PR1A / PR4B

**근거 위치:** [A 부록 A / S-08], `sync_engine allItems/existingStatus/progress; auto-drain; duplicate_repository`. 첨부 원문의 SHA 고정 링크·함수 구간을 보존해서 추적한다. 아래 테스트명은 실행 결과가 아니라 검증 시나리오다.

**확인 범위와 한계:** 전량목록상태와누적capturedID진행조회일부를이번에재열람했다.건별duplicaterefresh의전체호출자와실제복잡도는첨부감사근거다.

**권장 처리안:** 좁은runstaging/SQLjoin·batch,progressdelta/checkpoint재계산,drain후처리결합,decision-onlyfastpath를각각독립검증한다.정확한변경알림과수동대표/동률보존.

**선행 반례·고장 주입:** 계정규모증가,같은건수수정,긴queue,manual대표·giantgroup,동시foreignwriter. 총examinedID·SQLcall·retainedbytes·publish시간측정.

**수용 조건:** 단순최대batch뿐아니라누적작업량감소확인.legacyoracle동등·ACK/progress정확·cancel후추가작업상한.

**보존·롤백·의존성:** 기존boundedfullrebuild를검증된fallback으로유지.원문전체물질화·fsync생략·알림누락으로가속하지않는다.

**반증 조건:** 현재 HEAD의 실제 호출자 또는 선행 보호가 위 trigger를 차단하는지 확인한다. 차단이 증명되면 버그 수정 항목을 제거하거나 회귀 보호만 남긴다. 단지 테스트가 없다는 이유로 버그 확정, 기존 테스트가 있다는 이유로 안전 확정을 하지 않는다.

## 3. 이번 저장소 재열람 범위

원격 branch 응답을 직접 읽어 `dev=ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60`을 확인했다. 첨부 기준과 동일하다. 새 조회 시점이 달라지면 HEAD delta를 다시 확인한다. 로컬 checkout/reset 지시가 아니다.

12개 파일의 전체 또는 아래 지정 구간을 재열람했다. 내용 확보와 모든 branch 검증·실행 통과는 다르다. 첨부 감사의624파일 inventory를 이번의전파일재검토로표시하지 않는다.

| 근거 | 저장소 경로 | 재열람 범위 | 사용 범위·한계 |
|---|---|---|---|
| R01 | `AGENTS.md` | 전체 | 제품/구조/문서 지도. 과거 test 수치는 현baseline으로 사용하지 않음 |
| R02 | `PROJECT_RULES.md` | 전체 | 기능·권한·DB교환·금액 분리·5탭 불변 조건 |
| R03 | `docs/architecture/bounded-reads.md` | 반환된 핵심 구간; 긴 응답 일부 잘림 | 기존 bounded read/cache/cancel/duplicate/import 보호. 문서 설명과 모든 런타임 분기 동등은 미검증 |
| R04 | `docs/architecture/client-read-handoff.md` | 전체 | 현재서버계약과제안 구분. giant PC복원 과거보고는 서버현재실행증거 아님 |
| R05 | `lib/services/sync_engine.dart` | 270–335, 450–583 | 목록수집/cleanup/후처리/결과 반환 경계 |
| R06 | `lib/services/local_db_service.dart` | 3290–3355 | 외부 snapshot 복사·checkpoint·sidecar 제거. 거대파일 전체 재감사 아님 |
| R07 | `lib/community/rebuild/community_rebuild.dart` | 330–402 | _runToCompletion / _commit 경계 |
| R08 | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/PrefsInbox.kt` | 전체 | unique key append와 공통MAX200 eviction |
| R09 | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt` | 25–163 | prefilter로그·native enqueue·thread/connection 구간 |
| R10 | `lib/screens/recent_answers_screen.dart` | 1–110 | Provider목록·empty/건수·화면페이지 경계 |
| R11 | `docs/reviews/2026-10-03-runtime-validation.md` | 1–100 요청의 실제 반환구간; 긴 응답 일부 잘림 | 역사적 환경/검수/혼합 성능수치. 후속60585ms등은 첨부감사[A] 인용 |
| R12 | `contracts/storage-contract.json` | 1–70 | contract_version2, schema5/16, NULL/owner/change추적 일부. 모든entity본문 신규검토 아님 |

### SHA 고정 출처

[A] `03_source_audit_original.md`: 사용자 첨부 원문, 각 ID와 부록 B/C/D를 함께 읽는다. 파일은 byte-for-byte 사본이다.

[R01] `AGENTS.md`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/AGENTS.md`

[R02] `PROJECT_RULES.md`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/PROJECT_RULES.md`

[R03] `docs/architecture/bounded-reads.md`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/docs/architecture/bounded-reads.md`

[R04] `docs/architecture/client-read-handoff.md`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/docs/architecture/client-read-handoff.md`

[R05] `lib/services/sync_engine.dart`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/sync_engine.dart`

[R06] `lib/services/local_db_service.dart`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/services/local_db_service.dart`

[R07] `lib/community/rebuild/community_rebuild.dart`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/community/rebuild/community_rebuild.dart`

[R08] `android/app/src/main/kotlin/com/fentanest/mysafetyreport/PrefsInbox.kt`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/PrefsInbox.kt`

[R09] `android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt`

[R10] `lib/screens/recent_answers_screen.dart`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/lib/screens/recent_answers_screen.dart`

[R11] `docs/reviews/2026-10-03-runtime-validation.md`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/docs/reviews/2026-10-03-runtime-validation.md`

[R12] `contracts/storage-contract.json`

`https://github.com/Fentanest/safetyreport-mobile/blob/ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60/contracts/storage-contract.json`


## 4. 공식 기술 문서 확인 — 제품 결정을 대체하지 않음

[O01] SQLite Write-Ahead Logging, §4 The WAL File.

`https://www.sqlite.org/wal.html`

WAL은 main DB 외부에 있는 영속 상태를 담을 수 있으므로 복사/이동 시 이를 분리하면 commit을 잃을 수 있다는 전제만 사용했다. 이것이 현재 앱의 실제 자료 손실 증거는 아니다. journal mode를 WAL로 바꾸거나 동시 connection을 늘리라는 지시가 아니다.

[O02] Dart Future.timeout.

`https://api.dart.dev/dart-async/Future/timeout.html`

대기 제한 뒤 원래 Future가 나중에 완료될 수 있다는 취소 경계 확인에 사용했다. 개별 네트워크 라이브러리의 실제 abort 동작은 후속 검증이 필요하다.

[O03] Flutter performance profiling.

`https://docs.flutter.dev/perf/ui-performance`

제품 성능은 profile mode/실제 기기에서 판단하고 UI/raster 구간을 구분하는 측정 설계에 참고했다. emulator·debug·host test의 수치를 실기기 수치로 변환하지 않았다.

[O04] Android Create and manage notification channels.

`https://developer.android.com/develop/ui/compose/notifications/channels`

NotificationChannel의 API26 경계와 하위 API guard 필요성을 확인했다. 링크 경로에 Compose가 포함돼도 Flutter를 Compose로 바꾸라는 권고가 아니다. 앱의 실제 minSdk/최종 merged manifest는 이번에 빌드 확인하지 않았다.

## 5. 증거를 읽을 때 금지하는 결론

- [A]의 작은 Python/SQLite 식을 실제 Flutter 메서드/DB 교환/race 통합 재현으로 부르지 않는다.
- 기존868passed/15skipped·Kotlin4·500k수치를 이번 테스트 통과로 보고하지 않는다.
- normal500k왕복diff0을 giant group이나 모든컬럼미지원 입력의 통과로 확장하지 않는다.
- S24종료 원인을 실기기로그 없이 OOM/ANR/native오류 중 하나로 확정하지 않는다.
- 운영알림유출·권한우회·DB자료유실을 실제발생으로 쓰지 않는다.
- 이 계획의 새모듈/새API/새상태를 현재구현된 기능으로 표시하지 않는다.
