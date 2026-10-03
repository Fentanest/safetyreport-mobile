# 서버 담당자 인계: 남은 bounded 조회 계약

서버 저장소는 이 작업에서 수정하지 않았다. 모바일의 protocol 3 사본은 서버 `contracts/selfhost-compat/`와 바이트 동일하다. 아래 **현재 계약**과 **제안**을 구분한다. 제안 API를 호출 가능한 것으로 가정하지 않는다.

## 현재 구현과 제한

현재 서버 코드/정본에 있는 `/reports/{category}/page`(offset/limit/dedupe)와 `/stats/map/points`(viewport/zoom/max_points)는 모바일에서 연결했다. 일반 신고 페이지는 full API로 되돌아가지 않는다. API가 없으면 PC 업데이트 안내다. Client 대시보드/통계는 요약·통계 API를 사용하며 표시를 위해 전체 신고를 별도로 가져오지 않는다.

현재 category/page에 복합 검색/별점 eligible/감시/중복/주소 missing scope가 없다. Client 복합 조건은 현재 200개 후보 페이지에서 적용하며 UI를 `전체 대상 N · 페이지 조건 일치 M`로 표시한다. N을 필터 전체 일치 건수로 주장하지 않는다. 모든 후보 페이지를 넘길 수 있지만 전체 필터 결과의 COUNT·정렬·연속 목록은 서버 추가 계약이 필요하다. 중복 차량과 감시 목록의 기존 별도 API는 유지되어 해당 명시적 화면은 여전히 큰 응답을 받을 수 있다.

현재 `/summary`는 recent_answers 200개를 제한하지만 watchlist는 전량이다(`report_stats_service.py`). `/watchlist`도 원문을 포함하는 전량 자료다. Provider가 감시 번호를 얻기 위해 이 API를 호출하는 비용은 서버 측 bounded/ID projection 계약 없이는 제거할 수 없다. 모바일 summary parser에서 임의로 잘라 전체 건수를 위장하지 않았다. 지도 missing API도 서버 주소 그룹 전체 반환 가능성이 남아 있다. HTTP bytes/string/decoded map/Report의 순간 중복은 이 기존 전량 응답에서 특히 위험하다.

## 제안 요청·응답 (아직 정본 미확정)

1. summary: 전체 `watchlist_total`, `recent_answers_total` 추가, 목록은 최대 200개 preview임을 문서화. 기존 고객과의 계약 변경은 서버 담당자가 결정한다. 예:

```json
{"status":"success","data":{"total":500000,"watchlist_total":5155,"watchlist":[{"ID":"fixture-000499938"}],"recent_answers_total":158,"recent_answers":[],"dataset_id":"fixture-account","data_revision":"r101","dedupe_mode":"canonical"}}
```

2. category/page 확장 또는 별도 정본 scoped page. 기존 offset/limit/dedupe에 현재 ReportFilter의 필드를 전달한다. `name`, `agency`, `manager`, `id`, `reportNumber`, `carNumber`, `location`, `reportContent`, `processContent`, `ratingCause`, `fine`, `supplementCount`는 comma OR / `&` AND, `ratings`, `statuses`, `pollStatus`, 답변/신고/발생 날짜·시각 양끝, lawExact/`__없음__`, police 조건, excludeWithdraw를 동일 의미로 적용한다. 대상은 `all|traffic|parking|other` 및 `reports|rating|watchlist|duplicates|missing` scope. ID순 기본 계약과 기존 중복 정렬을 구분한다. 예:

```http
GET /api/v1/reports/traffic/page?offset=0&limit=1&dedupe=canonical&statuses=수용,일부수용&responseDateStart=2026-01-01&responseDateEnd=2026-12-31&law=도로교통법%20제5조&lawExact=true
X-SafetyReport-Client: mobile
X-SafetyReport-Version: 2.0.0+31
X-SafetyReport-Protocol: 3
```

```json
{"status":"success","category":"traffic","total":827,"offset":0,"limit":1,"count":1,"next_offset":1,"dataset_id":"fixture-account","data_revision":"r101","dedupe_mode":"canonical","data":[{"ID":"fixture-000000405","신고번호":"SPP-000000405","category":"traffic","처리상태":"수용","답변일":"2026-10-08"}]}
```

`data`는 기존 Report DTO의 일부 필드를 보여 준 예시다. 실제 응답은 모든 기존 원문·수정값·중복 메타 필드를 유지하고 count와 길이가 같아야 한다. count/page는 같은 read snapshot; data_revision이 바뀐 다음 페이지는 재시작 또는 명확한 충돌 응답(정본 결정 필요). 문자열 원문/NULL·숫자·중복 메타/사용자 수정값은 기존 필드를 유지한다.

3. watchlist 번호 membership: 원문/Report 전량 대신 ID·신고번호·watch flag의 bounded projection 또는 페이지 행의 watch flag와 전체 해제 mutation. 대표건은 확정군 어느 구성원의 Y도 계승해야 한다. 전체 해제는 클라이언트가 50만 번호를 모아 보내는 구조 대신 서버에서 정확한 dataset/scope를 대상으로 수행하도록 정본 결정이 필요하다. 기존 기능 보존 필수.

4. missing: `/stats/map/missing`에 offset/limit(예: 100그룹)와 groupTotal 및 각 주소 reportTotal을 제공하고 상세는 category/page의 missingAddress 또는 실제 정본 address-group ID로 200건 조회한다. geocode preview limit(예: 10)은 전체 건수와 분리한다. year와 NULL 날짜 적용 의미를 서버·모바일 같은 벡터로 고정한다.

5. 중복 관리: 기존 group/member API에 group offset/limit(50), group_total/status_counts, member offset/limit(50)/member_total, 대표 메타를 포함하는 정본이 필요하다. 대표가 첫 페이지 밖에 있어도 선택 상태를 보존하고 대표 membership은 서버에서 확인한다. 예:

```http
GET /api/v1/duplicates/groups?offset=0&limit=50&status=review_required
GET /api/v1/duplicates/groups/{canonical_group_id}/members?offset=50&limit=50
```

```json
{"status":"success","total":461538,"offset":50,"limit":50,"count":50,"data_revision":"r101","data":[{"report_id":"fixture-000000051","is_representative":0}]}
```

경로·필드는 **제안**이다. 현 group/member API에는 페이지 계약이 없으므로 모바일은 이를 호출 가능한 새 API로 가정하지 않는다.

6. 필터 메타·알림 단건: 전체 DISTINCT 상태·법규와 missing/blank를 원문 없이 반환하고, ID/신고번호로 category/단건을 찾는 정본이 필요하다. 현재 Client 법규는 `/stats/overview`의 `violation_laws`를 사용하지만 이 overview에는 custom status DISTINCT가 없다. 표준 상태/기존 preview 발견 상태만으로 전체 사용자 상태를 보장할 수 없다. 미상 카테고리 알림은 기존 raw page를 순차 탐색하며 전량 객체를 보관하지 않지만 늦을 수 있다. 제안 응답:

```json
{"status":"success","data":{"statuses":["수용","일부수용","사용자 상태"],"laws":["도로교통법","__없음__"],"dataset_id":"fixture-account","data_revision":"r101"}}
```

## PC 복원 거대 중복군 계산 인계

50만 건·원문 2개 거대군 fixture의 실제 PC `restore_from_mobile_db`는 20분 이상 완료되지 않았다. own synthetic 프로세스의 stack은 `services/duplicate_group_service.py:299`에 있었고 다음 계산을 확인했다:

```python
majority_field_fingerprint = max(set(field_fingerprints), key=field_fingerprints.count)
```

해시마다 전체 리스트를 다시 count하여 O(N × distinct fields)다. source는 reports 500,000, 중복 멤버 499,999(동시 수정 fixture 1건은 독립 원문), 군 크기 461,538/38,461, 전체 field hash 60,000개다. PC 프로세스 RSS는 관찰 중 약 6.9GB였으며 own fixture 작업만 중단했다. PC 저장소를 수정하지 않았다. 일반 분포의 50만 건(2,000쌍 중복군) 실제 양방향 교환은 완료해 모든 교환 컬럼·원문·수정값·중복/메타 diff=0을 확인했다. 거대군 PC 복원이 통과했다고 주장하지 않는다.

서버 수정 제안은 Counter 등으로 한 번 count한 뒤 `max(set(field_fingerprints), key=counts.get)`를 사용해 현재 set 동률 결정도 유지하는 것이다. 정규화/field_match/수동 대표/기존 결정의 parity와 0/1/3천/58,388/10만/50만, 1개 및 2개 거대군의 restore 시간을 테스트해야 한다. `tool/large_data_fixture.dart`의 `giantRawGroups:true`, `test/services/duplicate_rebuild_bounded_test.dart`의 `SR_DUPLICATE_DB_OUT`로 동일 재현 source를 만들 수 있다. API 차단·운영 성능 완료와 별개의 PC 담당 항목이다.

## 추가해야 할 공통 벡터

| 입력/동작 | 필요한 단언 |
|---|---|
| 500,000건, canonical 제외 1,000건, 감시 5,155건 | summary total은 정확한 모집단, preview ≤200, watchlist_total 정확, 원문 전량 응답 없음 |
| 58,388건·긴 원문·같은 건수 상태 변경 | COUNT의 수용/일부수용/미상 이동과 data_revision 변경 |
| 수정값 NULL/빈값·과태료 원문/추정값 | effective projection·결측/처분/금액 기존 통계 벡터 일치 |
| 복합 OR/AND·lawExact·NULL 답변일·별점 eligible | 페이지 합집합이 기존 full predicate 결과와 같고 total=그 합집합 길이 |
| 감시가 nonrepresentative에만 Y인 확정군 | canonical 대표 감시 계승·review/not_duplicate는 원래 모집단 유지 |
| 200/201/500,000건 페이지 경계 | 중복/누락 없음, next_offset 종결, 불안정 snapshot 재시작 규칙 |
| 데이터 복원/계정 전환/동시 수집 | 같은 total이어도 dataset/revision으로 캐시 무효화, 과거 계정 응답 폐기 |
| 지역 bounds/줌 연속 변경 | marker budget와 viewport sum 정확, full meta는 viewport·point limit와 독립 |
| auth401 / old2.x / missing metadata / HTTP409 / WS4406 | 네트워크·인증과 업데이트 오류 구분, 이벤트/본문 전송 전 차단 |

모바일은 위 계약이 확정되면 동일 사본·벡터를 받아 현재 candidate page 제한과 명시적 전량 endpoint를 대체해야 한다. 운영 서버 연동·1.5.3 차단 검증은 이 작업에서 수행하지 않았다.

정본 확정 전 인계용 기계 판독 사례: [client-read-proposed-vectors.json](client-read-proposed-vectors.json). 이 파일은 서버 정본 사본 또는 실행된 서버 테스트가 아니다.
