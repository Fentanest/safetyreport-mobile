# DB 교환 전 컬럼 검토 인덱스

정본: `contracts/storage-contract.json` (contract2 / server5 / mobile16). 아래는 계획 검수용 생성 인덱스다. 정본 변경·스키마 검증·DB 왕복 실행을 하지 않았다. type은 선언 계약 타입이며 실제 SQLite typeof는 승인 후 별도로 비교한다.

원칙: entity keyed set + 모든 column value/type/NULL을 두 왕복에서 비교. 서버 표이름의 category, watchlist↔sync_meta, entry_value↔report열은 의미 대응을 따로 검사. server-only·legacy 제외를 실제값 누락 허가로 확대하지 않는다.

## report

서버: `{'title': 'mysafety', 'detail': ['mysafetydetail_traffic', 'mysafetydetail_parking', 'mysafetydetail_other'], 'merge': ['mysafetymerge_traffic', 'mysafetymerge_parking', 'mysafetymerge_other']}` / 모바일: `reports`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| ID | text | site | True | True |   |
| 상태 | text | site | True | False |   |
| 신고번호 | text | site | True | False |   |
| 신고명 | text | site | True | False |   |
| 신고일 | text | site | True | False |   |
| 만족도조사여부 | text | site | True | False |  사이트 값 우선, 조회 실패·빈 값이면 기존 유지. '참여 완료'→'참여 가능'은 확정 미참여일 때만(결정 D-2·D-3). |
| 별점 | integer | site | True | False |  사이트 값 우선, 조회 실패면 기존 유지(결정 D-2). |
| 별점사유 | text | site | True | False |  사이트 값 우선, 조회 실패면 기존 유지(결정 D-2). |
| 감시목록 | text | derived | True | False |  감시목록 표(서버 mysafety_watchlist, 모바일 sync_meta 'watchlist')에서 계산하는 표시값. 서버는 merge_final·감시목록 변경 때 다시 계산(refresh_watch_flags). |
| 처리상태 | text | site | True | False |   |
| 차량번호 | text | site | True | False |   |
| 위반법규 | text | site | True | False |   |
| 범칙금_과태료 | text | site | True | False |   |
| 벌점 | text | site | True | False |   |
| 처리기관 | text | site | True | False |   |
| 처리기관코드 | text | site | True | False |   |
| 담당자 | text | site | True | False |   |
| 답변일 | text | site | True | False |   |
| 발생일자 | text | site | True | False |   |
| 발생시각 | text | site | True | False |   |
| 위반장소 | text | site | True | False |   |
| 주소정규화 | text | derived | True | False |   |
| 행정구역 | text | derived | True | False |   |
| 위도 | real | derived | True | False |   |
| 경도 | real | derived | True | False |   |
| 지오코딩상태 | text | derived | True | False |   |
| 종결여부 | text | site | True | False |   |
| 신고내용 | text | site | True | False |   |
| 처리내용 | text | site | True | False |   |
| 지도 | text | site | True | False |   |
| 첨부사진 | text | site | True | False |   |
| 첨부파일 | text | site | True | False |   |
| category | text | derived | True | False | 표 이름(mysafety*_traffic / parking / other) traffic / parking / other. 서버는 merge/detail 표 이름으로 표현. |
| entry_value | text | site | True | False | mysafety_entry_value.entry_value 서버는 mysafety_entry_value 표, 모바일은 reports 열. |
| raw_content | text | legacy | False | False |  모바일 reports 의 옛 열(항상 ''). 원문은 raw_content 엔터티. |
| synced_at | integer | derived | True | False |  epoch ms. 상세 내용이 실제로 바뀐 시각. |
| 보완횟수 | integer | site | True | False |   |
| 보완_미응답 | text | site | True | False |   |
| 보완_요청자 | text | site | True | False |   |
| 보완_요청일시 | text | site | True | False |   |
| 보완_완료일시 | text | site | True | False |   |
| 보완_요청_내용 | text | site | True | False |   |
| 보완_신고자_의견 | text | site | True | False |   |
| 사진_첫촬영 | text | derived | True | False |   |
| 사진_끝촬영 | text | derived | True | False |   |
| 사진_촬영수 | integer | derived | True | False |  NULL=아직 시도 안 함, 0=받았지만 촬영 시각 없음. |

## raw_content

서버: `mysafety_raw_content` / 모바일: `report_raw`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| ID | text | site | True | True |   |
| raw_content | text | site | True | False |   |
| raw_type | text | site | True | False |   |
| saved_at | integer | derived | True | False |   |

## sync_meta

서버: `mysafety_sync_meta` / 모바일: `sync_meta`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| key | text | meta | True | True |   |
| value | text | meta | True | False |   |

키: last_sync(ISO8601), watchlist(모바일 전용 — 서버 원천은 mysafety_watchlist, 서버 sync_meta 에는 두지 않음; 스키마 버전 2 에서 삭제), map_backfill_state(서버 런타임, 교환 제외), kakao_member_id(이 DB 의 주인 카카오 회원번호 원문 — 게이트 통과 때 처음 한 번 기록, 교환 때 그대로 옮김. 가져오기·복원은 이 값이 지금 로그인한 카카오 계정과 같은 DB 만 받고 없거나 다르면 거절, 카카오 로그아웃은 신고 자료와 함께 지움 — 2026-09-27). value 는 양쪽 모두 NULL 허용.

## geocode_cache

서버: `mysafety_geocode_cache` / 모바일: `geocode_cache`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| 주소정규화 | text | derived | True | True |   |
| 원본주소 | text | derived | True | False |   |
| 행정구역 | text | derived | True | False |   |
| 위도 | real | derived | True | False |   |
| 경도 | real | derived | True | False |   |
| 상태 | text | derived | True | False |   |
| source | text | derived | True | False |   |
| error_message | text | derived | True | False |   |
| updated_at | integer | derived | True | False |   |

## duplicate_group

서버: `mysafety_duplicate_group` / 모바일: `duplicate_group`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| group_id | text | derived | True | True |   |
| fingerprint | text | derived | True | False |   |
| match_type | text | derived | True | False |   |
| status | text | user | True | False |   |
| representative_mode | text | user | True | False |   |
| representative_id | text | user | True | False |   |
| member_count | integer | derived | True | False |   |
| apply_globally | integer | user | True | False |   |
| note | text | user | True | False |   |
| created_at | integer | derived | True | False |   |
| updated_at | integer | derived | True | False |   |

status·대표건·메모는 사용자 판단 — R1 에서 duplicate_decision 으로 분리(결정 D-6).

## duplicate_member

서버: `mysafety_duplicate_member` / 모바일: `duplicate_member`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| group_id | text | derived | True | True |   |
| report_id | text | derived | True | True |   |
| report_number | text | derived | True | False |   |
| category | text | derived | True | False |   |
| is_representative | integer | derived | True | False |   |
| priority_score | integer | derived | True | False |   |
| raw_match | integer | derived | True | False |   |
| field_match | integer | derived | True | False |   |
| created_at | integer | derived | True | False |   |
| updated_at | integer | derived | True | False |   |

## watchlist

서버: `mysafety_watchlist` / 모바일: `None`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| 신고번호 | text | user | False | True |   |

모바일은 sync_meta 키 'watchlist'(쉼표 구분 신고번호)로 표현. 교환은 변환기가 담당.

## entry_value

서버: `mysafety_entry_value` / 모바일: `None`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| ID | text | site | False | True |   |
| entry_value | text | site | False | False |   |

모바일은 reports.entry_value 열.

## admin_users

서버: `admin_users` / 모바일: `None`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| username | text | server_only | False | True |   |
| password_hash | text | server_only | False | False |   |
| salt | text | server_only | False | False |   |

## api_keys

서버: `api_keys` / 모바일: `None`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| key | text | server_only | False | True |   |
| name | text | server_only | False | False |   |
| created_at | text | server_only | False | False |   |

## report_override

서버: `mysafety_report_override` / 모바일: `report_override`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| ID | text | user | True | True |   |
| column_name | text | user | True | True |  report 엔터티의 site 열 이름만 허용 |
| value | text | user | True | False |   |
| updated_at | integer | user | True | False |  epoch ms |

사용자 수정값(결정 D-1). 화면용 값 = 사이트 원본 위에 이 값을 덮은 것. 재크롤링이 지우지 않는다. value NULL = 빈 값으로 고침이 아니라 '' 로 저장(NULL 은 쓰지 않음).

## duplicate_decision

서버: `mysafety_duplicate_decision` / 모바일: `duplicate_decision`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| group_id | text | user | True | True |   |
| status | text | user | True | False |   |
| representative_mode | text | user | True | False |   |
| representative_id | text | user | True | False |   |
| apply_globally | integer | user | True | False |   |
| note | text | user | True | False |   |
| updated_at | integer | user | True | False |  epoch ms |

중복군 사용자 판단(결정 D-6). group_id = 본문 sha256. 그룹 재생성은 멤버만 다시 계산하고 이 표는 보존한다.

## change_log

서버: `mysafety_change_log` / 모바일: `None`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| seq | integer | server_only | False | True |   |
| created_at | integer | server_only | False | False |   |
| kind | text | server_only | False | False |   |
| report_id | text | server_only | False | False |   |
| payload | text | server_only | False | False |   |

변경 기록(결정 D-5). 서버 전용.

## change_cursor

서버: `mysafety_change_cursor` / 모바일: `None`

| 컬럼 | 타입 | writer 의미 | 직접 교환 | PK | 대응/주의 |
|---|---|---|---|---|---|
| device_id | text | server_only | False | True |   |
| last_seq | integer | server_only | False | False |   |
| updated_at | integer | server_only | False | False |   |

기기별 읽은 위치. 식별자 없는 구앱은 device_id='legacy'.

## 추가 검증 경계

- 사용자 override의 NULL은 쓰기 시 빈값으로 저장한다는 현재 계약과 백업에서 NULL을 조용히 변형하지 않는 교환 보장을 구분한다. 지원되지 않는 값은 명시 거절한다.
- raw의 ID·raw_content·raw_type·saved_at, duplicate decision/group/member 전 필드, sync_meta의 owner원문을 source/effective/derived의 다른 층과 별도로 비교한다.
- sync_meta watchlist/map_backfill_state의 명시 예외, report category/entry_value의 재표현, legacy reports.raw_content 비교 제외 사유를 harness에 기록한다.
- 현재 _coerceForColumn의 숫자문자열/빈문자열 변환과 last_sync 자동생성은 보존 oracle와 대조할 대상이다. 기본은 지원 타입만 무손실 변환 또는 거절이다.
- unknown nonNULL 값은 보존 또는 거절. 현행 allNULL unknown 허용은 계약 확인 없이 무조건 새 거절로 바꾸지 않는다.
- 지연/취소/디스크부족·WAL복구실패·publish crash마다 입력파일과 destination의 전체 cell/type 비교를 수행할 계획이다. quick_check/integrity_check는 보조 확인이다.
