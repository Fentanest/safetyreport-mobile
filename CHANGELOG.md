# Changelog

작업, 버그 수정, 세션 기록용 문서.

- 구조/운영 컨텍스트는 `CLAUDE.md`에 유지
- 2026-05-01에 `CLAUDE.md`의 작업 이력 섹션과 최근 검색 기능 변경을 이 파일로 이관 시작
- 2026-09-24부터 구조/운영 컨텍스트는 `docs/architecture/`로 옮겼다(루트 `CLAUDE.md`는 공통 문서 import + 역할만)

---

## 2026-10-06 (업데이트 첫 실행 게이트·로그아웃 복구)

- 테스트 AVD에서 1.3.5 스키마 10 DB를 2.0.1 debug 앱으로 연 첫 실행에 `ATTACH DATABASE`의 `database is locked (SQLITE_BUSY)`를 재현했다. 초기화 백업은 원본 잠금을 가진 트랜잭션에서 읽도록 고쳐, 백업 검증과 원본 초기화 사이 쓰기 차단을 유지하면서 Android의 두 연결 잠금 충돌을 없앴다. 합성 자료로 수정 후 DB 열기·게이트 통과·다음 버튼 콜백을 확인했다.
- SQLite 3.22 실라이브러리에서 재현한 업로드 제어 UPSERT 문법 오류를 같은 트랜잭션 안 INSERT/UPDATE로 수정했다. 커뮤니티 DB 열기 실패 후 실패 Future가 캐시에 남는 재시도 장애도 수정했다.
- 자료 주인 검사의 DB 오류와 인증 오류를 구분해 안내한다. DB 주인을 확인하지 못하면 자료 보호 표시를 먼저 영속 저장한 뒤 세션만 로그아웃할 수 있다. 다음 계정의 자동 자료 인수와 공유는 차단하며, 기존 소유자 검사 및 명시적인 자료 비우기 규칙을 유지한다.
- 1.3.5 원본 스키마·DELETE/WAL 업데이트, 배타 잠금 중 백업·값/타입 보존, 실패 후 DB 재열기, 보호 상태의 재로그인·계정 교체·명시적 인수 및 로그아웃 확인창 회귀 테스트를 추가했다. VERSION과 배포 설정은 바꾸지 않았다.
- 검증: Flutter 3.47.5 전체 1,261 passed / 기존 skip 16(`--concurrency=2`), analyze 기존 warning 9 외 신규 0. SQLite 3.22.0 실라이브러리 회귀 56 passed. 전체 병렬 1차의 기존 50ms 로그인 테스트 타이밍 실패는 기대값을 바꾸지 않고 단독 및 전체 재검증으로 확인했다.

## 2026-10-06 (v2.0.1 — 목록 검색·페이지 전환·첨부 수정)

- Client 검색·상세 필터·별점 후보를 첫 200건 안에서만 걸러 누락하던 문제를 수정했다. 기존 서버 페이지 API를 끝까지 순회해 전체 일치 건수를 계산하며, 전체 분류 검색은 신고번호·ID 내림차순 스트림을 병합한다. PC 목록 페이지의 같은 정렬 수정과 함께 적용한다.
- Client/Standalone 목록은 다음 페이지를 미리 받고 최대 3페이지를 캐시한다. 같은 페이지 요청은 공유하고 자료 revision·epoch·검색 조건·새로고침 때 폐기한다. 미리 받기 오류는 현재 목록을 유지하고 실제 이동에서 재시도한다.
- 일반 동영상의 컨트롤 바를 프레임 하단에 고정했다. 전체화면 코드는 유지했다.
- 안전신문고 사진은 토큰 없이 먼저 요청하고 401/403일 때만 저장 토큰으로 1회 재시도한다. Client 서버의 인증·protocol 헤더는 유지한다.
- 알림 `ic_stat_logo.xml` 카메라 벡터를 제거하고 `5a78a8f1` 직전 `7aedf8d4`의 사용자 원본 `ic_stat_logo.png`를 복원했다. 앱 런처 카메라 아이콘은 유지한다.
- 버전 원본 `VERSION`을 기존 pubspec과 같은 `2.0.1+32`로 맞췄다. 날짜·본문 검색의 SQL 일치, 전체 분류 정렬, 캐시·무효화, 영상 하단 배치, 공개/인증 실패 사진 재시도 회귀 시험을 추가했다.
- 검증: `flutter test` 1,251 passed / 기존 skip 16, `flutter analyze` 기존 warning 9 외 신규 0. 실DB 읽기 전용 사본의 재사본에서 교통 2,888건·9월 이후 73건을 확인했고, 기존 ID 오름차순 첫 200건에는 그 조건이 0건이었다. 원본은 변경하지 않았다.

- 대시보드 `처리 현황` 범례에서 이름이 긴 `일부수용` 줄만 건수·비율이 다음 줄로 내려가 두 줄이 되던 배치를 고쳤다. 이름과 건수·비율을 항상 한 줄에 두고, 폭이 모자라면 건수·비율 글자만 줄인다(`dashboard_screen.dart`).
- 회귀 시험: 360dp, 글꼴 배율 전부에서 범례 줄 높이가 모두 같은지 검사한다(예전 배치는 큰 글꼴 배율 2개에서 실패하는 것을 확인).
- 버전 2.0.1+32. dev push 때 자동으로 돌던 `Build dev APK` 는 끄고 수동 실행만 남겼다(사용자 결정).

---

## 2026-10-05 (릴리스 촬영에서 확인한 백업 안내·Client 권한 오류 수정)

- 설정의 DB 백업 안내를 Android 10 이상 `Download/mysafetyreport/`, Android 7~9 저장 위치 직접 선택으로 정정했다. 실제 저장 동작은 유지했다.
- 별도 경로를 쓰는 Standalone→Client 모드 전환 백업 안내에는 Documents 저장이 불가능할 때 Download로 대체하는 기존 동작을 명시했다.
- 구 서버가 초기화 상태 조회에 `permission_required`를 반환하면 초기화 크롤링 시작 안내 대신 PC 앱 설정 > 4. 커뮤니티 계정의 API 키 관리 권한 해결 방법과 상태 재확인을 표시한다. 권한 허용 후 초기화가 필요 없으면 기존 진입 흐름으로 복귀한다.
- 권한 오류 HTTP 파싱·안내/재시도 위젯·설정 백업 위치 문구의 회귀 검증을 추가했다.

---

## 2026-10-05 (사용 안내 글 공개에 맞춘 README·사용 가이드 링크)

- 서버 레포 기록과 같은 PC·Android 통합 사용 안내 글: <https://hb.worklazy.net/mysafetyreport-pc-android-guide/>.
- 설정의 `사용 가이드`와 `홈페이지 바로가기`가 새 글을 열도록 바꿨다. 홈페이지 링크에 따로 적혀 있던 주소 문자열은 `SupportLinks.userGuide` 상수 하나로 합쳤다.
  디버그 빌드를 에뮬레이터에 설치해 두 버튼 모두 크롬(기본 브라우저 앱)으로 그 주소가 열리는 것을 확인했다.
- README: 대표 이미지(`example.png`, `example-dark.png`)와 화면 갤러리 6장을 현재 dev 화면(Client 모드, 실DB 사본·차량번호/담당자 치환)으로 다시 만들었다. 버전 안내(공개판 v1.3.x 와 이번 2.0.0 차이), 상세 안내 글 링크, 핀 기준 신고 지도·커뮤니티 지도, 카카오 로그아웃 주의, PC 와 자료 옮기기 FAQ 를 추가했다.
  사실 정정: Standalone 은 앱을 열 때 자동으로 새 답변을 확인하지 않는다(동기화·알림 감지), 전국 안전신고 현황은 통계 탭 맨 아래, 동기화 중에는 뒤로 가기로 앱을 닫지 못하게 막는다.

---

## 2026-10-05 (신고 지도 — 커뮤니티 지도 바로가기, 로컬 미배포)

- 신고 지도 화면 지도 오른쪽 위에 '커뮤니티 지도' 버튼(`MapCommunityMapButton`, 범례와 같은 반투명 표면·테두리·높이 44, 지구 아이콘 + 이름 + 외부 열기 표시).
  폭 360 미만에서는 범례와 겹치지 않게 둥근 아이콘만. 누르면 `https://safemap.worklazy.net/`(`SupportLinks.communityMap`)을 **폰의 기본 브라우저 앱**으로 연다
  (`LaunchMode.externalApplication`, 앱 안 웹뷰 금지 — 카카오 로그인·세션 문제). 열지 못하면 안내 스낵바.

## 2026-10-05 (신고 지도 핀 기준 — Sol 3차 검수 반영·실DB 대조, 로컬 미배포)

- 대표 좌표 선택을 주소별로 한 번만 계산한다: (주소키, 좌표)별 건수 표 → 주소별 최대 건수 → 그중 최소 위도 → 그중 최소 경도(GROUP BY 세 단계) → 고유 인덱스로 각 신고에 적용.
  예전 UPDATE 는 신고마다 같은 주소 후보를 다시 훑어 한 주소에 좌표 2천 개면 2초, 5만 건은 끝나지 않았다(Sol 3차). 한 주소 5천 좌표 시험 추가.
- 칸 묶음 판정의 장소 문구 비교를 hex 로 하고 빈 문구도 하나의 값으로 본다(빈 장소와 장소가 같은 좌표에 섞이면 묶음, BOM 만 다른 문구도 다른 장소).
- 주소 모드 '이 주소의 전체 신고 보기' 키를 기존 목록과 같은 계산(첫 행의 주소)으로 넘긴다(U+001C 주소에서 빈 목록이 열리던 문제).
- 핀 기준 값 정규화·strip 규칙을 `lib/services/map_pin_basis.dart` 로 모아 Client 요청(`ApiService`)도 같은 규칙을 쓴다. 묶음 이름에 비교용 hex 키가 나오지 않게 했다.
- ID 가 NULL 인 신고의 주소 모드 좌표 없는 목록 누락은 고치지 않았다(크롤러가 항상 ID 를 채우고, 기존 목록도 ID 로 조인한다 — 사용자 확인).
- 실DB(사용자 PC dev DB 사본, 2,960건)를 서버 DB 가져오기로 옮겨 서버와 대조: meta·신고별 effective (위도, 경도, 주소키 바이트, 건수) 2,353 / 781개 모두 같음,
  가져온 DB 에 주인 `kakao_member_id` 유지, 첫 조회 위도·경도 162ms·주소 93ms. 실데이터는 커밋하지 않았다.

## 2026-10-05 (신고 지도 핀 기준 — Sol 2차 검수 반영, 로컬 미배포)

- 신고별 effective 표(temp `sr_map_effective`)를 SQLite 안에서 만든다: `CREATE TABLE AS SELECT` 로 지도 칸 집계에 쓰는 열과 주소키·장소 문구·자기 좌표를 담고,
  주소 모드는 (주소키, 좌표)별 건수 표에서 window 함수 없이 대표 좌표를 골라 `UPDATE` 한다. 행을 Dart 로 올리지 않는다(1차 반영 때의 전량 적재 회귀 제거).
  칸 집계·meta 는 이 표만 읽어 ID 가 NULL·빈 신고도 빠지지 않는다(1차 반영 때의 ID 조인 회귀 제거).
- 주소키·문구 strip 집합을 서버 Python `str.strip()` 기본 집합(29자, 공용 벡터 `strip_code_points`)으로 명시: SQLite `trim(x, char(...))` 와 Dart `stripMapText`. BOM 은 남기고 U+001C~U+001F 는 지운다.
- Dart UTF-8 디코더가 문자열 맨 앞 BOM 을 지우는 것을 확인했다(`utf8.decode`). 칸 묶음 이름의 주소키 구분·비교와 좌표 없는 목록의 그룹 재조회는 `hex()` 값으로 한다
  (BOM 주소 그룹을 열면 `missing_group_snapshot_changed` 로 실패하던 경로 포함).
- 주소 모드 좌표 없는 목록은 지도와 같은 주소키(strip 만)로 묶는다. 위도·경도 모드 목록은 그대로. `pin_basis` 값은 앞뒤 공백·대소문자를 무시(서버와 같음).
- 시험: 공용 벡터 effective 좌표를 DB 경로로 비교(`debugMapEffectiveRows`), strip 집합·주소키 경계 7사례(Dart·SQLite), NULL·빈 ID, 내부 이중 공백 목록, BOM·U+001C 대표 좌표, BOM 주소 목록·묶음 이름.

## 2026-10-05 (신고 지도 핀 기준 — Sol 1차 검수 반영, 로컬 미배포)

- 근거: [핀 기준 명세](docs/plans/2026-10-05-map-pin-basis.md) §7, 서버 레포 검수 기록 `docs/reviews/2026-10-05-map-pin-basis-sol.md`.
- 신고별 effective 좌표 표(temp `sr_map_effective`): ID → effective 위도·경도·주소키·장소 문구를 Dart 에서 만든다(주소키·문구는 Dart `trim()` = 서버 `str.strip()`).
  SQLite `trim()` 은 탭·줄바꿈·NBSP 를 남겨 주소 모드에서 좌표 있는 신고가 빠지던 문제(M1)를 고쳤다. DB revision·모집단·핀 기준이 같으면 다시 만들지 않고, 스냅샷 rowid 키셋으로 읽는다(M6, OFFSET 순회 제거).
  지도 칸 집계·meta 건수·좌표 없는 목록(주소 모드)이 이 표를 ID 로 조인한다. 트랜잭션이 되돌려지면 다음 조회가 다시 만든다.
- `address_groups` 는 숫자 좌표 그대로 `SELECT DISTINCT lat, lng, addr_key` 로 센다(M3, 실수 문자열 변환 제거).
- 묶음 판정은 칸 전체 좌표 범위와 장소 문구로 한다(M2). 주소키로 SQL 그룹이 나뉘어 다른 좌표가 일반 핀이 되던 회귀를 고쳤고,
  기존에도 처리상태 등이 달라 그룹이 갈리면 다른 좌표가 묶음이 아니던 점도 함께 바로잡았다. 같은 좌표·같은 문구는 기존처럼 일반 핀.
- 구 서버가 `pin_basis` 를 무시하면(응답 `meta.pin_basis` 가 address 아님) 토글을 위도·경도로 되돌리고 "서버를 업데이트해야 주소 기준을 쓸 수 있습니다." 안내(M4).
- 동률 문자열 비교를 코드포인트 순서로(`LocalDbService.compareCodePoints`, 서버·SQLite BINARY 와 같음)(L1).
- 시험: 공용 벡터 점 집합을 `debugMapEffectivePoints` 한 번의 조회로 비교(M5, 점마다 좁은 bounds 조회 우회 제거). Sol 이 든 입력마다 재현 시험 추가
  (탭·NBSP 주소, 같은 칸 다른 주소키·다른 처리상태 묶음, 같은 좌표 비묶음 유지, 37.5 vs 37.50000000000001, revision 변경 시 재계산, U+F900 vs U+20000, 구 서버 위젯).
  묶음 판정 수정을 빼면 M2 시험 2건이 실패함을 확인했다.

## 2026-10-05 (신고 지도 핀 기준 후속 A·B: 주소 그룹 수·묶음 원 이름, 로컬 미배포)

- 근거: [핀 기준 명세](docs/plans/2026-10-05-map-pin-basis.md) §5·§6(모바일 범위만, 서버는 별도 담당). 계약 벡터 2종(`contracts/map-pin-basis-vectors.json`, `contracts/map-cluster-label-vectors.json`)은 수정 없이 서버와 바이트 동일 유지.
- §5: `computeReportMapStats` meta `address_groups` 를 서버 정의로 — effective 좌표가 있는 신고의 서로 다른 (위도, 경도, 주소키) 조합 수(주소키 빈 신고도 `(lat,lng,'')` 로 셈, `pin_basis=address` 면 effective 좌표 기준). 벡터 expected(coords 6, address 4)를 `test/map_pin_basis_test.dart` 에서 확인.
- §6: Standalone 칸 점(`_MapCellAccumulator.toJson`)의 `address`/`address_count`/`region` 을 클러스터 라벨 벡터 규칙대로(칸 이름 계산을 `resolveMapClusterLabel`/`clusterLabelFromKeyStats` 순수 함수로 분리, `test/map_cluster_label_test.dart` 에서 벡터 5셀 직접 + 실제 `computeReportMapStats` 2칸 대조). `ReportMapPoint.addressCount` 추가(없으면 0, 하위호환). 칸 `cluster` 판정·묶음 점 탭=확대·마커 라벨 `'N건 묶음'` 유지: 실제 주소 보유 묶음 점은 `mapPointRegionName` 이 `''`을 돌리고 `'주소 정보 없음'`은 일반 문구로 취급(위젯/단위 테스트로 확인).
- 검증: `flutter analyze` error 0 / warning 9(기존). `flutter test` 1216 passed / 16 skipped / 0 failed(작업 전 1210 + 신규 6: 클러스터 벡터 5·라벨 유지 1, pin 기준 address_groups 단언은 기존 테스트 내 추가).

## 2026-10-05 (신고 지도 핀 기준 위도·경도/주소, 로컬 미배포)

- 근거: [핀 기준 명세](docs/plans/2026-10-05-map-pin-basis.md) §1·§3(서버 명세 사본). 정본 벡터 `contracts/map-pin-basis-vectors.json`(서버와 바이트 동일)으로 Standalone 계산을 검증한다. DB 스키마·저장 좌표·교환 형식·pubspec 변경 없음.
- Standalone: `LocalDbService.computeReportMapStats`/`computeReportMapMissingGroups`에 `pinBasis`(기본 coords, address 외 모두 coords). address 모드는 같은 주소키(`trim(주소정규화)`, 비면 `trim(위반장소)`) 신고들의 유효 공식 좌표 중 가장 많이 나온 (위도,경도) 쌍(동률이면 위도 작은 것→경도 작은 것)을 effective 좌표로 쓰고, meta geocoded/missing 건수·bounds 거르기·셀 묶기·좌표 없는 목록이 이를 따른다. 유효 좌표 판정은 기존 그대로, DB 원값은 바꾸지 않는다. 캐시 키·meta에 `pin_basis` 포함. 대표 좌표는 Dart(`resolveMapPinBasis`)에서 계산해 TEMP 표로 조인한다(기기 SQLite window 함수 미사용).
- Client: `ApiService.getReportMapStats`/`getReportMapMissingGroups`에 `pinBasis`(기본 coords). address일 때만 `pin_basis=address` 쿼리를 붙인다(구 서버는 무시하므로 하위호환, coords는 기존 요청과 동일). 서버 경로 상수는 그대로.
- 지도 화면: 필터 바에 "핀 기준" 토글(위도·경도/주소, 분류 선택과 같은 유지 방식) + 주소 모드 안내 "같은 주소의 신고를 한 핀으로 묶고, 그 주소에서 가장 많이 신고된 공식 좌표에 표시합니다." 바꾸면 지도·좌표 없는 신고 목록을 다시 읽는다. `ReportMapMeta.pinBasis`(구 응답에 없으면 coords).
- 검증: `flutter analyze` error 0 / warning 9(기존). `flutter test` 1210 passed / 16 skipped / 0 failed(작업 전 기준선 1205 + 신규 5: 벡터 4·위젯 토글 1).

## 2026-10-05 (서버 기술일지 EO 구조 개선 중 모바일 해당분, refactor/eo-2026-10-05)

- 근거: 서버 레포 기술일지 EO(구조 개선). 서버와 같은 규칙을 같은 벡터로 검사하도록 맞춘다. 기능·DB 교환 형식은 바꾸지 않는다.
- R-01 상태·처분 정책 정본: `lib/services/report_policy.dart`(서버 `services/report_policy.py`·웹 `report-policy.js` 와 같은 정책 이름)를 두고 통계표 8분류(`_AgencyAgg`), 요약 카드, 지도 상태·4분류, 대시보드 요약 SQL·드릴다운 조건, 목록 취하 제외, 별점 대상 상태, 상태 색이 이를 쓴다. `contracts/report-policy-vectors.json`(서버와 바이트 동일)으로 순수 판정·SQL 조각을 검사한다. 정정: 대시보드 요약 SQL·드릴다운이 공백 붙은 상태를 다르게 세던 것, '교통 불수용' 드릴다운이 '불수용'을 포함 검색하던 것, 상태 색이 포함 검색('처리'·'완료' 포함 여부)이던 것을 정본 규칙으로 맞췄다.
- R-02 목록 필터 사양: `lib/services/report_filter_spec.dart` 가 검색어(AND/OR)·날짜/시각 범위·법규의 의미를 맡고 SQL 목록(`ReportQuery`)과 메모리 목록(`ReportProvider`)이 이를 쓴다. 서버·웹과 같은 `contracts/report-filter-vectors.json` 으로 검사한다. 정정: 날짜 원문을 그대로 비교해 끝 날짜 당일의 시각 붙은 신고(예 '2026-01-01 10:00:00' ≤ '2026-01-01' 거짓)가 빠지고 날짜 없는 신고가 범위에 들어가던 것, 없는 날짜·잘못된 시각도 비교하던 것, ' , & ' 처럼 빈 항목뿐인 검색어가 모든 신고를 지우던 것.
- D2-10 커뮤니티 클라이언트 규칙: 서버 정본 `contracts/community-client/` 사본(MANIFEST 해시 확인)과 `lib/community/gate/community_client_rules.dart` 로 status 정규화·오류 분류·재시도 대기·늦은 응답 판정을 서버·auth 와 같게 한다. 정정: status 조회가 일시 오류가 아닌 차단 오류(카카오 필요·정지·형식 오류 등)를 받아도 인증 오류가 아니면 게이트 캐시를 10분까지 유지하던 것(서버처럼 무효화), HTTP 200 에 `error` 가 담긴 응답을 성공으로 읽던 것, 재시도 대기(본문 `retryAfterSeconds`·`Retry-After`)를 읽지 않던 것, 늦은 응답 판정에서 세션이 유효한지 보지 않던 것.

## 2026-10-05 (서버 기술일지 2026-10-04 결함 중 모바일 해당분 수정, 로컬 미배포)

- 근거: 서버 레포 기술일지(서버·auth·모바일 정밀 점검, 결함 74건·SB 권고 3건). 서버·모바일 동작을 같게 맞추는 항목만 이 레포에서 고쳤다.
- A2-01: 안전신문고 토큰에 받은 아이디(`standaloneTokenUsername`)를 함께 저장하고, 지금 아이디와 다르거나 기록이 없으면 무효로 본다. 백그라운드(WorkManager isolate) 재로그인은 저장 직전 디스크의 아이디를 다시 읽어 같을 때만 저장한다(세대 번호는 isolate 마다 따로라 막지 못하던 경로, CHANGELOG 2026-10-04 S-05 의 "cross-isolate 인증 원자성" 경계). 업그레이드 뒤 첫 사용 때 한 번 다시 로그인한다.
- A2-06: 만족도 점수 응답은 `result` 키가 있고 null/빈 객체일 때만 미참여로 확정한다. 키 없음·`error`·객체 아님은 확인 실패로 보고 저장된 별점·사유를 지우지 않는다(`classifyScorePayload`, 서버 `_classify_score_payload` 와 같은 벡터).
- A2-08: Sunwi 지역 응답의 `result` 가 목록이 아니면 0건이 아니라 실패로 재시도한다(`resultListOrThrow`, 서버와 같음).
- D2-03: `requireFresh` 는 재검증 실패 뒤 10분 캐시로 새 작업을 허용하지 않는다(`status_stale`, 서버와 같음).
- D2-05: 커뮤니티 "이 계정으로 연결"은 저장 성공 뒤에만 후보를 지우고, 실패하면 확인 화면을 유지한다. 확정은 한 번에 하나, 확정 중 취소는 결과를 기다린다.
- D2-06·D2-08: Client 서버 계정 카드가 `is_different_data_owner` 경고를 보이고, 연결됨 상태에 "다른 계정으로 다시 연결"을 둔다.
- O-01: 대시보드 '전체' 타일에 취하를 숨기는 설정이면 "취하 N건 포함"을 표시한다(서버 웹 대시보드와 같은 표기).
- 검증: `flutter analyze` error 0 / 기존 warning 9. `flutter test` 1188 passed / 16 skipped / 0 failed(이번 실행 기준선 1170 + 신규 18). 서버↔모바일 실제 DB 왕복(`db_roundtrip_check.py`, 실제 Dart importer·서버 restore) 양방향 컬럼 차이 0.

## 2026-10-04 (UI·코드 점검 55건 수정, 로컬 미배포)

- 근거: [점검 보고서](docs/reviews/2026-10-04-ui-code-review/index.html), 추적표 [docs/plans/2026-10-04-ui-code-review-fixes.md](docs/plans/2026-10-04-ui-code-review-fixes.md). 사용자 결정으로 메이저 버전 출시 전 55건 전부 수정. 브랜치 `fix/ui-code-review-2026-10-04`.
- 기준선(Flutter 3.47.5): test 914 passed / 16 skipped / 0 failed, analyze error 0 / warning 9 / info 0.

### WP1 알림 경로 (SQ-B01 B02 B04 B12 P08 U08)
- 읽음·중복 판정을 신고 단위에서 변경 단위 키(신고번호+변경종류+처리상태+synced_at+답변일, 중복군은 group_id+변경종류+상태+대표+구성수)로 바꿨다. 상세 시트를 열어 읽음 처리한 신고의 다음 처리 결과가 걸러진 뒤 ack되어 사라지던 결함을 고쳤다. 판정·추가·저장을 한 번에 끝낸 뒤에만 pending claim을 ack한다.
- 알림 기록 provider의 모든 읽기·쓰기를 하나의 큐로 직렬화하고, reload가 저장 전 메모리 항목을 덮지 않게 했다. 저장 실패 시 다음 작업에서 다시 쓴다.
- Client 알림 화면은 결과(per-device cursor)를 먼저 받아 저장한 뒤 서버의 일회성 완료 신호를 소비한다. 실패는 로그와 재시도 안내로 남긴다. 서버 변경 없음. 결과 조회가 화면 진입·복귀·새로고침마다 일어나므로 cursor가 이전보다 일찍 전진한다(첫 방문 기기는 최신 묶음을 미읽음으로 받음).
- 알림 ID에 순번과 임의 꼬리를 붙여 한 묶음 안 충돌을 없앴다(Dart·WsService.kt). 옛 충돌 ID는 읽을 때 `_dupN`으로 구분한다.
- 변하지 않은 기록은 다시 해석·알림하지 않고, 읽음 저장을 몰아서 한다. 하단 배지는 unreadCount 변경에만 다시 그린다.
- Standalone의 "크롤링 현황"·"신고 결과" 빈 상태 문구를 동기화 기준으로 바꿨다(탭 이름은 불변 항목이라 유지).
- 검증: analyze error 0 / warning 9 / info 0, test **934 passed / 16 skipped / 0 failed**(신규 20). WsService.kt는 WP9 병합 뒤 Gradle `:app:testDebugUnitTest`로 컴파일·Kotlin 테스트 12 passed 확인.

### WP2 DB 가져오기·설정 화면 결함 (SQ-B03 B06 B08 B14, B09 일부)
- 서버 DB 변환·백업 사용 대기 작업을 적용 전에 지우던 것을 고쳤다. 안전신문고 로그인 뒤 **Standalone 모드를 켜기 전에** 가져오고, 성공했을 때만 키를 지운다. 실패하면 받은 파일 경로와 함께 "다시 시도 / 버리고 빈 DB로 시작"을 묻고, 결정이 없으면 키를 남긴 채 모드를 켜지 않는다(`docs/architecture/data-contracts.md` 갱신). 모드를 먼저 켜면 게이트 흐름이 빈 DB에 먼저 쓰거나 가져오기를 거절할 수 있었다.
- 서버 DB 다운로드 진행 창: 뒤로가기는 다운로드 취소로 연결하고, 창은 자기 route만 닫는다(설정 화면이 같이 닫히던 결함). 다운로드 뒤 대기 작업 저장과 모드 초기화를 반쪽 없이 처리한다.
- 서버 주소·모드가 바뀌면 이전 서버의 기능 목록을 비우고 "알 수 없음"으로 둔다(조회 실패 로그). 설정 저장·연결 테스트에 진행 중 잠금을 걸었다.
- 재로그인 대화상자의 비밀번호를 지운 뒤 컨트롤러를 해제하고(`DisposeOnUnmount`), 중복 메모 컨트롤러도 해제한다. 설정·설정 마법사의 await 뒤 mounted 확인을 보강했다.
- 검증: analyze error 0 / warning 9 / info 0, test **954 passed / 16 skipped / 0 failed**(신규 20). 다운로드 성공 경로는 저장 경로가 기기 고정이라 자동 테스트 없음, 에뮬레이터 확인은 통합 검증 때.

### WP5 지도 (SQ-U03 U10 U11 P05 U24 지도)
- 지역 라벨: 지도 타일이 늘 밝으므로 라벨 글자를 어두운 고정색(약 17:1)·11pt로 바꾸고, "지도 구역 집계 …" 대신 시·군·구 이름(묶음은 "강남구 외", 이름 없으면 "N건 묶음")을 보인다. 표시용 묶음(`visibleMapCells`)이 대표 지역 이름을 채운다(개수·분포·좌표 불변).
- 지도 왼쪽 아래에 "© OpenStreetMap contributors" 출처를 표시하고 저작권 페이지로 연결한다(타일 URL·UA 불변).
- 위치 권한: 화면 진입 때는 조용히 확인만 하고, "현재 위치"를 누르면 안내 대화상자 뒤 시스템 권한을 요청한다. 영구 거부 시 기존 설정 안내 유지.
- 마커·클러스터 목록을 자료가 바뀔 때만 만들고, Provider 구독을 쓰는 값 4개로 좁혀 무관한 갱신에 재조회·재클러스터하지 않는다.
- 과태료율 색 범례(접이식)와 마커 스크린리더 라벨을 추가했다(색 경계 60%/50% 불변).
- 검증: 신규 테스트 21개. WP7과 합친 상태에서 analyze error 0 / warning 9 / info 0, test **988 passed / 16 skipped / 0 failed**. 에뮬레이터 확인은 통합 검증 때.

### WP7 크롤링/동기화 화면·타이머 (SQ-B07 U18 P04 P10, B09 일부)
- 크롤링 화면: 앱 복귀 때 5초 상태 확인을 다시 시작하고(Client·mounted), 백그라운드에서는 멈춘다. 초기화 await마다 mounted를 확인하고, 화면이 닫힌 뒤 연결이 끝난 WebSocket은 바로 닫는다. 화면이 닫힌 뒤 시작 실패·중지 성공 시에도 대시보드 실행 표시를 내린다. Standalone은 복귀 때 크롤링 상태를 조회하지 않는다.
- 로그 패널 글자색을 앱 테마가 아닌 어두운 패널 기준으로 계산하고 12pt로 키웠다. 로그가 없으면 패널을 한 줄로 접는다.
- 서버 유지보수 상태 확인은 앱이 백그라운드면 멈추고 복귀 즉시 한 번 확인한다. 상태가 바뀔 때만 다시 그리고, 조회 예외로 폴링이 멈추지 않는다.
- 전국 신고현황 자동 넘김은 화면이 보이고 앱이 전경일 때만 돈다.
- 검증: 신규 테스트 13개, 합친 상태 test 988 passed / 16 skipped / 0 failed, analyze error 0 / warning 9.

### WP3 루트·내비게이션·테마 (SQ-P01 U05 U06 B05 B13 U07 U04 탭 막대)
- 테마를 한 번만 만들어 재사용하고, 루트를 Selector로 좁혀 `themeMode`가 바뀔 때만 MaterialApp을, 초기화·모드·설정·게이트 값이 바뀔 때만 홈을 다시 그린다. 매 알림마다 테마 보간(약 200ms)으로 숨은 탭까지 다시 그리던 문제를 없앴다. 커뮤니티 게이트는 화면이 읽는 상태가 실제로 바뀔 때만 알린다.
- 뒤로가기: 선택 모드 해제 → 대시보드가 아닌 탭이면 대시보드로 → 대시보드에서 동기화 중이면 안내 → 종료. 탭 인덱스 0~4는 불변.
- 대시보드 "감시 목록 › 관리"·"더 보기"는 하단 신고관리 탭의 감시 목록 하위 탭으로 전환한다(중복 화면 push 제거, 48dp, chevron).
- 네이티브 MethodChannel 처리기를 앱 루트(`NativeCallRouter`)에 한 번 걸고, 알림 탭 이동 요청은 메인 화면이 붙을 때까지 보관한다. Kotlin은 `dartReady` 뒤 보관 요청을 보내고 Dart가 받았을 때만 지운다(500ms 예비 경로 유지). `syncFgsStopped`는 화면과 무관하게 SyncEngine으로 간다. `docs/architecture/android-runtime.md` 갱신.
- Standalone 초기 재구성 게이트의 onDone을 한 번만, mounted일 때만 부른다.
- 바텀시트 손잡이: 수동 손잡이 9곳을 지우고 테마 손잡이·모서리만 쓴다. 높은 시트는 `useSafeArea`(상세 검색 시트가 상태 표시줄 아래로 가던 문제).
- 하위 탭 막대: 높이를 글자 배율에 맞추고, 라벨이 칸에 안 들어가면 가로 스크롤 탭으로 바꾼다(개수·순서·스와이프 불변). 알림 미읽음 배지를 탭 막대 안으로 옮겼다.
- 검증: analyze error 0 / warning 9 / info 0, test **1025 passed / 16 skipped / 0 failed**(신규 37), 골든 변경 없음. MainActivity.kt는 WP9 병합 뒤 Gradle `:app:testDebugUnitTest`로 컴파일·Kotlin 테스트 12 passed 확인.

### WP9 파일·엑셀 내보내기 (SQ-P03 P11)
- 엑셀 내보내기: 필요한 26개 열만 ID keyset 1,000행 페이지로 읽고(기존 필터·순서·`_rowToReport` 동일), 각 페이지를 작업자 isolate로 보내 정렬·시트 작성·인코딩을 UI 밖에서 한다. UI isolate는 한 페이지만 들고 있다. 진행률·취소를 붙였고 `.part`로 쓴 뒤 완료 시에만 이름을 바꿔 부분 파일을 남기지 않는다. 저장 위치·파일명·열기/공유 동작 불변.
- 동등성: 이전 경로(기존 코드 그대로)와 새 경로가 같은 fixture(1,400+57+5행, NULL/빈 문자열, 한글·줄바꿈·이모지, 수정값·취하, 중복군, 감시 목록)에서 인코딩 바이트 길이·시트·모든 셀의 값/타입/스타일이 같음을 확인(취하 포함/제외). 확정 과태료 열만 있고 추정 열은 없음을 확인.
- 파일 목록: 디렉터리를 비동기로 한 번 읽고 항목마다 stat 한 번, `ListView.builder`·정적 DateFormat, build에서 동기 파일시스템 호출 제거. Provider 구독을 `filesRefreshNonce`로 좁혔다. 정렬(폴더 먼저, 이름 내림차순)·삭제/공유/열기 동작 불변.
- 검증: analyze error 0 / warning 9 / info 0, test **1034 passed / 16 skipped / 0 failed**(신규 9). Kotlin 단위 테스트 12 passed(Gradle, 데몬 없이).

### WP4 목록·드릴다운·상세 (SQ-U01 U02 P09 U12 U13 U14, U20 상세 시트)
- 신고내역 앱바 배지가 Standalone에서 늘 "0건"이던 결함: 페이지 목록이 받은 실제 전체 건수(탭별, 천 단위 쉼표)를 보인다. Client에서 필터가 걸려 전체를 모르면 배지를 숨긴다. 옛 메모리 목록 기반 계수·선택 코드를 지우고, 화면 단위 선택은 Client 중복차량 탭에만 남겼다(중복 카드 선택 시 빈 목록이 넘어가던 결함·늘 꺼져 있던 일괄 선택도 고침).
- 통계·지도·상세 시트의 드릴다운은 앱 전체 필터를 바꾸지 않고 그 화면만의 필터로 연다(`pushReportDrillDown`). 제목에 조건을 보인다("예시 교통 담당 기관 · 신고"). 돌아온 뒤 하단 신고내역 탭에 조건이 남던 결함을 고쳤다. 드릴다운 화면의 검색/필터도 그 화면 필터만 바꾼다.
- 상세 시트 "같은 조건으로 검색"은 분류만 판정하고 200행을 읽거나 이후 refreshAll 대상에 넣지 않는다.
- 상세 시트 라벨 칸 폭을 가장 긴 라벨로 계산하고, 좁은 폭·큰 글자에서는 라벨을 값 위로 올린다.
- 상세 시트·알림·지도의 상태 칩을 공용 `StatusBadge`로 바꿔 라이트에서도 대비 4.5:1 이상(이전 일부수용 1.96:1).
- 전체화면 동영상을 닫으면 방향을 시스템 기본으로 되돌리고(세로 고정 해제), 조작 막대를 SafeArea 안에 둔다. 동영상 버튼에 툴팁과 48dp 터치 영역.
- 검증: analyze error 0 / warning 9 / info 0, test **1063 passed / 16 skipped / 0 failed**(신규 29), 골든 변경 없음.

### WP6 대시보드·통계 표시 (SQ-U15 U04 대시보드 U09 U24 당월 U25 U22)
- 대시보드: "전체 N건" 머리 줄 + 상태 6종을 3열×2행(글자 1.5배 이상·좁은 폭은 2열×3행) 타일로 줄였다. 고정 비율 대신 내용 높이를 따르므로 2.0배에서도 넘치지 않는다. 0건 타일은 같은 배치로 흐리게(누를 수 없음), 화살표 위치를 맞췄다. 동기화 상태 카드가 첫 화면 약 y=500 → 320으로 올라왔다. 동기화 카드 문구 줄바꿈, 교통위반·처리 현황 카드 머리·범례·도넛 가운데·앱바 모드 배지의 2.0배 넘침도 고쳤다.
- 대시보드 감시 목록은 최대 3건 한 줄 행(신고명·상태·신고일)과 "+N건 더 보기"로 줄였다. 세부 항목은 상세 시트·감시 목록 탭에서 그대로 볼 수 있다.
- 월별 추이: 세로축 최상단 눈금을 그리지 않아 잘림을 없애고 축 글자 10→11, 쉼표 표기. 이번 달(집계 중) 막대와 범례를 빗금+테두리로 구분(색만으로 구분하지 않음).
- 기관 행 과태료: 확정은 기존 색·굵기, 추정은 보조 글자색과 점선 "추정" 배지. 합산하지 않음.
- 숫자 표기 통일: `lib/utils/format.dart`(`formatNumber`·`formatCount`·`formatWon`). 금액은 "9만 5,000원" 대신 전체 쉼표 표기. 대시보드·통계·기관 행·중복 관리·신고내역 배지/본문에 적용.
- 골든: `stats_overview_light/dark.png`를 의도한 변경(축 글자 11, 당월 범례 빗금 견본)으로 갱신(픽셀 차 약 0.75%). 기존 기관 행 테스트의 "12만원" 단언은 쉼표 표기로 바꿨다(목적 동일).
- 병합: WP3의 "관리" 탭 전환과 충돌을 수동 해결. 신고내역 본문 건수 쉼표 표기에 맞춰 WP4 테스트의 본문 파싱을 쉼표 허용으로 바꿨다.
- 검증: analyze error 0 / warning 9 / info 0, test **1092 passed / 16 skipped / 0 failed**(신규 29).

### WP8 Provider·조회 비용 (SQ-P02 P06 P07 P12 P13 B10 B11, B09 나머지)
- "자료 변경" 신호를 `dataRevision`으로 분리했다. Standalone은 DB 쓰기 stamp(연결·TEMP 쓰기 revision·`PRAGMA data_version`)가 바뀔 때, Client는 refreshAll·서버 변경 수신 때만 오른다. `statsRefreshNonce`는 통계 탭 진입 신호로만 쓴다. 숨은 탭(목록·지도·통계)은 표시만 해 두고 보일 때 한 번 읽는다. 같은 조건의 자료 변경은 지금 수치를 보인 채 다시 읽는다. 측정(Client, 탭 왕복): 목록 요청 1→4가 1→1, 통계 HTTP 3→7이 2→2.
- 보완: Client 통계는 마지막으로 받은 지 60초가 지났으면 탭 재진입 때 지금 수치를 보인 채 다시 받는다(PC 쪽에서 변경 알림 없이 바뀐 자료를 놓치지 않게).
- Standalone 목록 페이지는 카드에 쓰는 28개 열만 읽고(신고내용·처리내용·첨부 등 제외, 3천 행 합성 기준 페이지 JSON 약 48% 감소), 상세 시트를 열 때 한 건을 다시 읽어 전체 내용을 보인다(`Report.detailLoaded`).
- `context.watch`를 쓰는 값만 `context.select`로 좁히고, 설정 조회·감시 목록·필터 setter는 값이 바뀔 때만 알린다. 대시보드·신고내역은 무관한 알림에 다시 그리지 않는다(4→0, 2→0).
- 로딩 표시를 진행 중 카운터로 바꿔 먼저 끝난 조회가 스피너를 끄지 않게 했다. 감시 목록 추가·해제는 데이터셋 세대를 확인하고 새 Set을 대입한다.
- 앱 시작: 보안 저장소 이관 뒤 서로 무관한 초기화 4개를 함께 기다린다. 기관 registry는 바이트를 isolate에 넘겨 디코딩·파싱을 한 번에 한다(결과 스냅숏 동일 테스트).
- 쓰지 않던 `cached_network_image` 의존성 제거(`pubspec.lock`은 그 패키지와 전이 의존 5개 삭제만, 업그레이드 없음).
- await 뒤 mounted 확인 4곳 추가(main 호환성 실패 처리, 감시 목록 삭제, 커뮤니티 계정 해지, 권한 화면).
- 검증: analyze error 0 / warning 9 / info 0, test **1107 passed / 16 skipped / 0 failed**(신규 15).

### WP10b 화면 구조 일관성 (SQ-U16 U17 U21 U26 U27 U20 U28)
- 앱바: 5개 탭 모두 오른쪽 끝에 같은 설정 버튼, 탭별 동작은 그 왼쪽. 제목을 하단 라벨에 맞췄다("신고 내역"→"신고내역", "알림 기록"→"알림"). 검색은 앱바 필터 아이콘 + 조건 칩 줄(칩마다 ×로 그 조건만 해제, "초기화")로 통일(신고내역·신고관리 별점·데이터 수정, 드릴다운은 그 화면 필터만). 통계의 지도 진입은 앱바 한 곳.
- 설정 순서: 연결·계정(연결 방식 카드 바로 아래 도움·문의 — 2026-09-24 결정대로 버그 제보를 맨 위에 유지) → 데이터 관리(파일·백업·복원, Client 크롤링 자동 저장) → 표시(테마 3칸 세그먼트 버튼) → 목록·통계 기준(옛 "기타 데이터 필터 세팅") → 권한 → 정보(앱 정보: 정부 출처 링크·비공식 고지 유지, 홈페이지). 앱 정보 카드의 중복 버그 제보 버튼 제거. 기능·모드별 표시 조건 불변. 2.0배 넘침(카드 제목·정보 행·모드 배지)도 고쳤다.
- 공용 빈/오류 상태 `SrEmptyState`(오류는 오류 톤 + 다시 시도): 페이지 목록(오류와 빈 목록 구분, 조건 없음/자료 없음 구분), 최근 답변, 필터 목록, 알림, 감시 목록, 중복 신고, 별점 패널.
- 시스템 바 여백 `srPagePadding`: 설정·권한·최근 답변·필터 목록·페이지 목록·파일·통계·대시보드(가로).
- 상세 검색 시트: 차량번호·신고번호·처리상태·처리기관만 펼치고 나머지는 "조건 더 보기"(값이 있으면 자동으로 펼침). ID 아이콘 구분. 필드·의미 불변.
- 툴팁 없는 아이콘 버튼을 모두 고치고 `lib/` 전체를 검사하는 테스트를 추가했다. 상세 시트 링크 행·하위 탭 터치 영역 48dp.
- 문서: `ui-renewal-spec.md` 다크 팔레트를 코드(B안 #0B0B0C)와 맞추고 코드 대조 정정을 남겼다. 동의 화면 스크린숏을 앱 테마로 다시 렌더(라이트 배경 라벤더 → 흰색). `feature-matrix.csv`(STAT-01·NOTI-01·SET-10)·`statistics-spec.md` 갱신.
- 검증: analyze error 0 / warning 9 / info 0, test **1133 passed / 16 skipped / 0 failed**(신규 26), 골든 변경 없음.

### WP10a 디자인 토큰 정리 (SQ-U19 U23)
- 의미색 토큰(`SrColors.success/warning/info`, 채움색 3종, 분류색 3종, 로그 패널색)과 `context.tone(SrTone)` 헬퍼를 추가했다. 이중 `StatusTone.of(StatusTone.of(...))` 17곳 → 0, theme 밖의 Material 기본색 48곳 → 0(흰/검정 고정색은 이유 주석). 대비: 라이트 success 5.02, warning 5.02, info 5.93(카드 기준), 다크 모두 8.6 이상, 채움색 위 흰 글자 5.02 이상.
- 모서리 반경 `SrRadius`(4/8/12/16/24/999)로 규격 밖 값 49곳 → 3(차트 막대 끝, 이유 주석). 바텀시트 20→24, 입력창 10→12.
- 글자 크기: 12 미만 리터럴 73곳 → 0(차트 축만 11). 하단 내비 라벨·`bodySmall`·`labelSmall`·상태 배지 기본값 11→12.
- SnackBar 헬퍼 `showSrSnack`(info/success/warning/error) 76곳 적용. 다크에서 오류·성공 SnackBar 글자가 어두운 채움 위에 어둡게 그려지던 것을 흰 글자로 고쳤다. 실패 문구는 오류 종류로 통일.
- 별점 탭 분류 칩 색을 통계와 같은 분류색(교통 파랑·주정차 주황·기타 초록)으로 맞췄다.
- 재발 방지 검사 테스트: 이중 StatusTone·theme 밖 기본색·`Color(0x..)`·12 미만 글자·규격 밖 반경·자체 배경 SnackBar가 `lib/`에 생기면 실패(의도한 예외는 `// sr-allow`).
- 골든: `report_list_card`·`stats_overview` 라이트/다크 4장을 의도한 변경(배지·캡션 11→12, 번호판 칩 반경 6→8, 통계 카드 반경 14→12)으로 갱신. `ui-renewal-spec.md` §2·§3·§4에 토큰·최소 글자·반경 결정을 날짜와 함께 기록.
- 검증: analyze error 0 / warning 9 / info 0, test **1151 passed / 16 skipped / 0 failed**(신규 18).

### WP11 점검 보고서 밖 추가 표시 결함 (UI 검토 L-3 L-7 L-8 L-9)
- 점검 과정에서 찾았으나 55건 문서에 넣지 않았던 표시 결함 4건을 함께 고쳤다(추적표 WP11).
- 신고 카드 차량번호 칩: 40% 고정 칸에서 "서울31바584…"처럼 잘리던 것을, 칩 실제 폭을 재어 절반 이하면 오른쪽에 전체 표시, 넘치면 메타 아래 줄로 내린다. 12자 번호판까지 360dp에서 잘리지 않는다.
- 통계 요약 값: "123,456,780"과 "원"이 줄바꿈으로 갈라지던 것을 한 줄로 유지(필요할 때만 축소).
- 알림 카드의 신고번호·시각 줄이 2.0배에서 최대 347px 넘치던 것을 줄바꿈 배치로 고쳤다.
- 별점 사유 대화상자: 세로·키보드·큰 글자에서 입력칸이 한 줄만 보이던 것을, 키보드가 열려 공간이 부족하면 설명 줄을 접고 입력칸 3줄·글자 수를 보이게 했다. 선택된 점수 칩의 체크 표시가 별 아이콘에 겹치던 것을 없앴다. 제출 동작 불변.
- 골든: `report_list_card`(번호판 칩 위치, 메타 줄이 넓어짐)·`stats_overview`(확정 과태료 한 줄, 아래 요소가 약 30px 위로) 라이트/다크 4장을 의도한 변경으로 갱신.
- 검증: analyze error 0 / warning 9 / info 0, test **1169 passed / 16 skipped / 0 failed**(신규 18).

### 통합 검증 (에뮬레이터 작동점검)
- 전용 AVD `sr_uitest_api35`(API 35, 1080×2400)에 운영 앱과 분리된 패키지(`…mysafetyreport.uireview`, debug)를 새로 설치해 Standalone 데모로 점검했다. 라이트/다크, 글꼴 1.0/1.3/2.0배. 글꼴·다크 설정은 원복, 에뮬레이터 종료.
- 재현했던 결함이 모두 고쳐진 것을 확인: 신고내역 배지 "0건"→"34건", 알림 탭 뒤로가기 → 대시보드(대시보드에서만 종료), "관리" → 하단 신고관리 탭의 감시 목록, 통계 기관 드릴다운 뒤 신고내역 탭에 조건 없음(드릴다운 제목에 조건 표시), 상세 시트 손잡이 1개·라벨 간격, 다크 지도 라벨 판독·범례·OSM 출처, 지도 진입 때 권한 요청 없음, 2.0배에서 넘침 띠 없음(대시보드 2열×3행, 하위 탭 스크롤), Standalone 알림 빈 문구 "동기화", 설정 순서·버그 제보 맨 위·테마 세그먼트, 빈 로그 패널 한 줄.
- 작동점검 중 새로 찾아 고친 것: 대시보드 상태 칸이 `excludeSemantics`로 InkWell의 탭 동작을 가려 TalkBack으로 열 수 없었다(uiautomator `clickable=false`). 칸의 Semantics에 `onTap`을 주었고, 같은 형태의 동영상 불러오기·위반법규 선택·지도 범례·OSM 출처 4곳도 고쳤다. 0건 칸은 계속 누를 수 없다. 재빌드 후 `clickable=true` 확인, 회귀 테스트 추가(수정 전 실패 확인).
- 통계 기관 카드 "총 27건"과 그 드릴다운 목록 "34건" 차이: 기관 표는 답변 완료 신고만 세는데(2026-09-28 결정) 드릴다운은 처리상태를 거르지 않는다. 사용자 확인(2026-10-04): 실제 자료의 처리중 신고에는 처리기관이 붙지 않으므로 데모 자료만의 문제이고, 보완요청 신고에 기관이 붙어 생기는 작은 차이는 허용한다. 그래서 드릴다운 규칙은 바꾸지 않고, 데모 자료의 처리중 신고에서 처리기관·담당자를 비웠다(`seedPlayReviewDemo`, 회귀 검사 추가). 표 아래 각주를 "답변 전이거나 처리기관이 없는 N건은 기관 목록에 없음"으로 정확히 했다. backlog BL-2는 이 결정으로 닫았다.
- 최종: analyze error 0 / warning 9 / info 0, test **1170 passed / 16 skipped / 0 failed**(기준선 914 대비 신규 256), Kotlin 단위 테스트 12 passed(WP9 시점, 이후 Kotlin 변경 없음), debug APK 빌드 성공(의존성 제거 반영).
- 실행하지 않은 것: Client 모드(실서버·운영 로그인 금지), 실제 동기화·별점 제출·업로드, profile 빌드 성능 계측, 실기기, 가로 모드·3버튼 내비게이션 실화면(위젯 테스트로만 확인).

## 2026-10-04 (서버 dev 리팩터링 WS 소비자 연동, 로컬 미배포)

- 서버의 optional terminal event_id/after/replay_gap/cursor_reset을 Android WsService에 연결했다. 서버 설정별 cursor를 분리하고 같은 event_id의 완료 알림 중복을 막는다. PrefsInbox가 알림 history와 cursor를 한 Editor.commit에 저장하며 실패하면 메모리의 실패 history/cursor/trim만 복구한 뒤 reconnect한다. rollback disk 실패에서도 메모리 cursor를 되돌리는 회귀를 확인했다.
- crawl outcome failed/cancelled/unknown/partial을 기존 succeeded/구버전 알림과 구분했다. 기존 compatibility7·outcome2·저장 실패 회귀3개(총12 passed)와 debug assemble을 실행했고 전용 Android35 x86_64 emulator의 정상 protocol3 gate에서 live/offline 실패·취소·unknown 세 알림, cursor3, 재연결 중복0을 확인했다. Flutter 전체 UI·물리 기기·실제 운영 서버 검사는 하지 않았다.
- 서버/실제 Dart DB converter 양방향 all-exchange-column 왕복 diff0을 확인했다. DB schema/converter/공동 계약·pubspec.lock·Gradle/Manifest·VERSION은 변경하지 않았다. 서버와 같은 배포 단위로 검토하며 원래 미추적 사용자 파일은 보존했다. 운영 계정/서명/릴리즈/push는 실행하지 않았다.

## 2026-10-04 (리팩터링 구현, 로컬 미배포)

- 계획 제출 이후 사용자의 `계획대로 구현` 요청으로 모바일 독립 변경을 구현했다. 기준과 현재 HEAD는 `ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60`이며, 격리 worktree에서 검증한 74개 파일을 바이트 대조 후 원래 폴더에 반영했다. 이전 계획 기록과 사용자 기존 파일을 보존했다. commit/push/릴리즈/서명/APK 생성/앱·기기 조작/운영 계정·서버 작업은 하지 않았다. VERSION·패키지 잠금·서버/모바일 교환 스키마5/16·protocol3·공동 정본은 변경하지 않았다.
- 동기화 목록의 shape·total·page·ID 유일성을 검증하고 불완전 목록은 상세 저장·full_resync dataset 선회전 전에 중단한다. 순회 완료를 부재 삭제 권한으로 취급하지 않는다. 목록·이전 상태·capture event 연결은 200행 TEMP staging과 실제 journal/outbox JOIN으로 처리한다. 상세 간격·건별 bounded 중복 계산과 공개 변경 알림의 의미를 유지했다.
- 외부 DB는 read-only 일관 snapshot에서 128행씩 복사하고 값·타입을 대조한다. 서버 import의 충돌·orphan·빈ID·정수 손실을 사전 거절하며 모든 교환 컬럼을 비교한다. private 교환 journal로 이전 정상본·dataset·이력을 복구하고 목적지/계정 세대를 다시 검사한다. 기존 원본 WAL/sidecar를 지우지 않는다. 실패한 open 재시도와 COUNT/page/기관/missing 조회의 동일 snapshot을 보강했다.
- 동기화/drain admission, immutable retry add/ACK, native private processing inbox·claim owner·정확한 event ACK, 손상 자료 격리를 구현했다. 일시 오류·busy·취소·unknown은 의무를 남긴다. rebuild는 list_complete와 모든 item terminal·명시적 gap·활성 scope/lease/세대를 같은 transaction에서 검사한 뒤 merge·완료를 기록한다. uploader·gate·manifest의 후속 await와 최종 publish에도 소유권 검사를 추가했다.
- Android API24/25 알림 경로, 알림 tag·PendingIntent·바로가기 소비를 보강하고 필터 전 원문 로그를 제거했다. native enqueue는 직렬 실행·30초 deadline·요청별 완료 알림 정리를 사용하며 응답 유실을 자동 재POST하지 않는다. 인증 body·요청 Client 수명을 제한하고 FGS의 실제 시작 응답·소유자 종료를 Dart와 연결했다. 이 변경만으로 task removal/process death 뒤 Dart 실행 지속을 보장하지 않는다.
- 최근 답변은 Standalone의 정확한 조건·total과 200행 페이지를 사용하고 Client는 미리보기임을 표시한다. 첨부 cache는 scope+전체 URI·content hash·검증 메타로 식별하고 stream·취소·deadline을 적용한다. 통계 표의 동일 결과 계산을 재사용하며 private 누산기를 같은 library part로 분리했다. Client 단일 분류는 page의 total을 사용하고 동일 진행 요청만 공유한다. 모든 소비자의 취소/epoch 변경은 해당 transport를 닫고 한 소비자 취소는 다른 소비자의 요청을 유지한다.
- 고정 SDK 검증 스크립트·CI 선행 gate와 mapping 90일 보존을 추가했다. 기존 Kotlin plugin 버전을 명시 적용하여 Flutter assemble 없이 native 검증이 가능하게 했다. 개인정보 방침과 architecture 문서의 저장소·LAN HTTP·FGS·manifest hook·recent 설명을 실제 코드에 맞췄다.

### 실제 실행 증거와 제한

- 고정 Flutter **3.47.5 / Dart 3.13.4**에서 변경 전 HEAD를 별도 실행했다: 전체 **868 passed / 15 skipped / 0 failed**, analyze **error0 / warning9 / info10**. 변경 후 최종 `bash tool/verify_refactoring.sh` 종료코드0: 전체 **914 passed / 16 skipped / 0 failed**, analyze **error0 / 기존 warning9 / info0**, Kotlin 단위 테스트 **7 passed / 0 failed**, Android lint 오류0. 마지막 native gate는 이번 작업 중 이미 컴파일·통과한 동일 소스의 Gradle 결과를 재사용했다. 기존 9개 경고는 두 storage 테스트의 unnecessary_cast다.
- 추가 반례를 실제 검사했다: live WAL 원본 불변·음수/0 rowid·opaque 컬럼/BLOB, 손상/중도 교환 복구, malformed/401행 중복 inventory, stop/busy/admission 실패, retry journal의 isolate 동시 add/ACK와 잘못된 ACK, 날짜·좌표·중첩 처분, 1,001행 최근 답변, 세대 변경 후 rebuild/manifest commit 거절, 인증 늦은 결과, 공유 Client 취소. 원래 목적의 테스트를 삭제하거나 golden을 갱신하지 않았다.
- 기본 suite의 16 skip은 미준비 선택 fixture/환경 및 별도 `SR_LARGE_TEST=1` staging 검사다. 50만 staging은 별도 실행해 **1 passed**, 0/1/3천/58,388/10만/50만 조회·집계 합성 suite는 변경 전후 각각 **7 passed**다. 이 성공을 서버 양방향 왕복이나 기기 검증으로 대체하지 않는다.
- 호스트 단일 실행의 합성 조회·수정·집계 시나리오 시간(ms, seed 준비 제외)은 아래와 같다. 순수 통계 cold 시간이나 Android 성능이 아니다. baseline 일부와 native Gradle 작업이 겹쳤으므로 통제된 개선율·p50/p95로 해석하지 않는다. generator는 동일 SHA256이며 RSS는 Dart heap이 아니다.

| 건수 | 변경 전 ms | 변경 후 ms |
|---|---:|---:|
| 0 | 89 | 80 |
| 1 | 145 | 120 |
| 3,000 | 1,282 | 856 |
| 58,388 | 20,945 | 12,186 |
| 100,000 | 35,731 | 21,151 |
| 500,000 | 175,671 | 105,428 |

- 50만 동기화 TEMP staging은 준비15,744ms / 전체18,615ms / 최대 반환페이지200을 기록했다. 공개 변경 결과 목록까지 고정 메모리라고 주장하지 않는다. 모든 raw log·native XML·lint·파일 hash·환경·실패 후 수정 기록은 [.agent-runs/mobile-refactoring-20261004/](.agent-runs/mobile-refactoring-20261004/provenance.json)에 로컬 보존했다. 초기에 잘못 선택한 SDK3.41.6 결과는 최종 수치에서 제외하고, SDK 잠금과 JDK compiler 선택을 바로잡은 뒤 위 검증을 실행했다. 과거 보고서의 수치를 이번 결과로 쓰지 않았다.

### 27개 발견의 구현 후 상태

`구현·host 검증`은 기기/서버 통합 완료와 다르다. 최초 계획의 재분류는 당시 정적 검토 기록으로 그대로 보존한다.

| ID | 반영 내용 | 남은 통과 조건 |
|---|---|---|
| DB-01 | readonly snapshot·전 셀 타입 대조·오류 중단, host 검증 | Android readonly transaction/live WAL 검증 |
| DB-02 | 키/관계/타입 preflight·bounded 전 컬럼 reconcile, host 검증 | C-06/07 양쪽 실제 왕복·giant 자료 |
| DB-03 | 기관 TEMP 준비와 page/count의 동일 transaction | native 동시 writer·계정 전환 검증 |
| DB-04 | unknown 직접 union 개수, host 반례 통과 | 실제 지도 렌더 모집단 검수 |
| DB-05 | 엄격한 UTC 달력·finite 세계 좌표, host 반례 통과 | 기기 지도/상세 검수 |
| DB-06 | open Future 실패 재시도·같은 snapshot | Android 연결/복원 동시 수명 검증 |
| UI-01 | Standalone exact recent paging·Client preview 라벨 | C-03 Client exact total·page |
| UI-02 | URI/scope/hash cache·취소/stream·검증 메타 | 기기 외부 앱 열기·disk quota 측정 |
| UI-03 | 단일 분류 total 재사용·inflight 공유·실제 취소 | all-category metadata·기기 탐색 비용 |
| UI-04 | page 요청 수명/동일 요청 비용 개선 | C-02/04 full endpoint 제거·decode worker 측정 보류 |
| N-01 | 고정 SDK의 min24 확인·26 API guard·lint 통과 | API24/25 실제 알림 |
| N-02 | config stamp·WS 중지/교체·늦은 callback 거절 | native 계정 A→B→A/키만 변경 검증 |
| N-03 | owner/freshness fence·immutable probe·bounded body, JVM 검증 | 기기 wallclock/백그라운드 gate |
| N-04 | private native SQLite·미완료 무삭제·200행 claim | 종료 지점별 이관/claim crash 검증·legacy 소유권 복구 |
| N-05 | package filter 전 이동·원문/번호 로그 제거 | native 실제 알림 로그 확인 |
| N-06 | 직렬 enqueue·whole deadline·request별 알림 | C-08 unknown 접수 조회/멱등·native 네트워크 장애 |
| N-07 | 알림 tag·URI identity·shortcut one-shot | 실제 알림 탭/바로가기 재실행 |
| N-08 | actual FGS 시작/종료 owner 연결·실패 중단 | HOME/task removal/process death/API timeout 미재현 |
| N-09 | signer-free CI gate·mapping90일·privacy 정정 | CI remote 실행·실제 release 진단 미실행 |
| S-01 | terminal·gap·scope/lease/세대와 merge/완료 한 transaction | 서버/기기 recovery 통합 |
| S-02 | 불완전 inventory 중단·부재 삭제 비활성, host 검증 | upstream authoritative snapshot 제공 전 삭제 금지 |
| S-03 | 실패/busy/cancel/일시 오류 queue 유지·exact ACK | native drain crash/end-to-end |
| S-04 | durable sync admission·immutable retry/claim owner, host 검증 | native 다중 writer·lease 만료/재시작 |
| S-05 | 인증 단계 body/deadline·owned client·세대 fence | cross-isolate 인증 원자성·느린 실네트워크 |
| S-06 | gate/uploader 후속 await·transaction claim 세대 보호 | 중앙 늦은 ACK·기기 계정 전환 통합 |
| S-07 | manifest page TEMP·lease/renew·cursor 검증·원자 publish | 중앙 unchanged/version/delta 계약 전 full poll 유지 |
| S-08 | sync 전량 상태 제거·실제 진행 JOIN·표 memo·누산기 분리 | cold index/RowMetrics/giant fast path/coalescing 측정 보류 |

- **미완료 게이트:** C-02~08의 실제 서버 공동 계약/왕복, Android native SQLite·legacy 복구·FGS 종료/재시작·API24/25·외부 파일 앱, 두 모드/테마/폭/글꼴/IME의 실제 렌더, 통제된 device 성능·배터리 검수는 NOT_RUN이다. RowMetrics·cold 준비 지연·giant fast path·중복 checkpoint 결합·multipart의 owned abort·Client full-response decode worker는 정확성/측정 근거 전 채택하지 않고 기존 bounded 동작을 유지했다. 27개 전체나 모든 성능 목표를 완료로 표시하지 않는다.
- **복구/배포 제한:** private processing inbox와 retry `.events-v1`를 이전 바이너리가 읽지 못하므로 미완료 의무가 있을 때 코드만 내려서 롤백하지 않는다. 동일 reader 유지 수정 또는 검증된 역이관이 필요하다. legacy 소유권 미확정·다른 scope의 미완료 작업은 보존하며 명시적으로 차단한다. legacy 삭제와 손상 자료 자동 폐기는 활성화하지 않았다. 배포 전 해당 기기/복구 게이트를 통과해야 한다.

## 2026-10-04 (계획 문서만)

- 전달된 리팩터링 계획 패키지를 지정 순서로 읽고 현재 dev HEAD의 코드·계약과 대조했다. [상세 계획](docs/plans/2026-10-04-mobile-refactoring/plan.md), 27개 발견 재분류·회귀 카드, 검토 범위와 전 컬럼 교환 인덱스, 미측정 기록 양식을 작성했다.
- 입력 원문을 계획 폴더에 바이트 그대로 보존하고 체크섬을 기록했다. 제품 코드 수정과 앱·테스트·벤치마크·빌드·기기·실제 외부 작업은 수행하지 않았다. 계획 제출 뒤 구현으로 전환하지 않는다.
- 보존 원문과 ZIP/manifest의 바이트·체크섬 일치를 확인한 뒤 요청된 루트 압축 파일과 이번 임시 해제 폴더를 정리했다. 사용자 기존 미추적 파일은 유지했다.

## 2026-10-03 (로컬 작업, 미배포)

### 대용량 조회·사유 입력·self-host protocol 3·DB 저장 위치

- dev의 기관 registry compute/캐시가 실제 호출 경로에 적용됨을 확인했다. 남아 있던 요약/통계 전체 Report·행 리스트와 반복 계산을 SQL COUNT/조건 집계, 원문 제외 TEMP GROUP BY, 1,000행 소비로 바꿨다. 전체 건수와 200개 미리보기를 분리하고 Standalone 목록/감시/중복/별점/주소 상세는 페이지 조회한다. 지도는 전체 메타와 현재 화면의 최대 1,024셀을 구분한다. 캐시는 쓰기 revision·DB 연결·계정 epoch·필터·중복 모드·registry에 따라 갱신한다.
- 빠른 통계 진입/취소 때 폐기된 CTAS가 native 실행 큐에 누적되는 문제를 검증 중 발견해 Dart 조회 진입을 직렬화하고 대기 후 취소를 재확인했다. 공통 필터 변경은 dataset epoch를 증가시키고 요약도 대기 후 취소한다. 변경 후 refresh는 진행 중이던 이전 요약 다음에 현재 revision을 다시 조회한다. 상태/감시 건수와 미리보기 ID 선택은 covering index로 원문 읽기를 피한다. 인덱스 준비 비용은 별도 기록한다. SQL/JSON/Report/registry/차트/Provider/마커/build·RSS 계측과 0/1/3천/58,388/10만/50만 합성 fixture를 추가했다.
- 별점 사유 dialog 내용과 actions를 분리하고 가로/큰 글꼴/IME에서는 입력과 버튼을 좌우 배치한다. 입력 포커스·draft·기존 1,000 rune/개행 규칙을 보존한다. 취소/중복 확인/오류 보존을 fixture로 검사했다. Android profile에서 실제 키보드 1.0/1.3/2.0를 확인했다.
- PC `contracts/selfhost-compat/` 정본/벡터를 동일하게 복사했다. Dart HTTP/WS·첨부 미디어·DB 다운로드와 Kotlin native HTTP/WS/background에 실제 제품 버전 2.0.0+31과 독립된 protocol 3을 전달한다. 실제 서버 major≥3/프로토콜 필드 확인 전 Client 기능을 차단하고 409/4406은 정확한 업데이트 안내와 재시도 중단으로 처리한다. Standalone은 이 검사로 막지 않는다. 서버 측 기존 1.5.3 차단/운영 서버 연동은 이 작업에서 검증하지 않았다.
- Client 다운로드/Standalone 정상 내보내기를 공유 Downloads 또는 SAF 문서에 스트리밍 저장한다. MediaStore pending·실패 삭제·크기 확인 뒤 파일명/실제 위치/완료 및 저장 위치 열기·파일 열기·공유를 제공한다. 포그라운드는 기본 Files 위치 안내, 백그라운드는 완료 알림 탭으로 안내한다. Android 15에서 50만 건 769,716,224 bytes 내보내기와 파일 앱 전환·파일명·quick_check를 확인했다. 삼성 내 파일/SAF28/백그라운드 실제 탭은 미검증이다.
- 검증: 전체 Flutter 860 passed/14 skipped, analyze error 0/warning 9/info 10(기존 진단, dev 24→19), Kotlin 4 passed, 50만 건 포함 host fixture 7 passed, 동시 snapshot/취소 burst/대기 요약 취소/수정값 감시 건수/year NULL 6 passed, DB 양방향 교환 diff 0, 공통 통계 44조합 diff 0. 4GB profile에서 데이터 준비·뒤로가기를 매번 확인한 대시보드↔통계↔지도 20회와 백그라운드 복귀, 연도 필터 연속 변경 후 복귀도 통과했다. 회전의 스크롤 위치를 보존하는 UI는 화면 밖 차트 oracle 실패와 실제 표시 확인을 검증 기록에서 구분했다. profile 에뮬레이터의 58,388건 요약은 dev 10,496 ms→SQL 전환 557 ms였다. 최종 4GB Android profile의 50만 건 요약 cold/warm 972/1 ms, 통계 35,194/3 ms였고 DB/인덱스 준비 13,633 ms는 별도다. 2GB 이전 cold 목표는 안정적으로 충족하지 못했으며 같은 환경의 개선률로 계산하지 않는다. 50만 건 cold와 최초 인덱스 준비는 여전히 부하 영향을 받는다. 실기기 S24 종료 원인은 미확정이며 실기기 성능 확인으로 주장하지 않는다.
- 상세 측정·실제 화면 증거·제한은 [검증 기록](docs/reviews/2026-10-03-runtime-validation.md), 현재 구조는 [bounded reads](docs/architecture/bounded-reads.md), 서버의 summary watchlist/복합 필터·감시·중복·주소 페이지 계약 인계는 [client read handoff](docs/architecture/client-read-handoff.md)에 있다. 서버 계약이 부족한 Client 전량 경로와 50만 건 cold 목표의 미달을 완료로 위장하지 않았다. 제품 VERSION 변경/push/배포/실제 제출은 하지 않았다.

### 완료 범위 재점검·실제 전량 경로 제거와 50만 건 왕복

- 첫 완료 보고에서 놓친 Dashboard summary 후 전체 category 사전 로딩을 제거했다. 검색/데이터 수정은 200건 페이지와 전체 COUNT, 필터 선택지는 로컬 DISTINCT 또는 기존 Client overview 메타를 사용한다. 서버 custom status/단건 lookup 부족은 계약 인계로 명시했다. 2페이지 편집·취소, 계정 전환 중 늦은 결과를 검증했다.
- 동기화 중복 재생성은 128행 digest/isolate, SQL staging과 revision 확인 publish로 전환했다. 50그룹/50멤버 페이지, 알림 metadata/deferred, 사진 유지보수 cursor, 서버 가져오기 JOIN 페이지로 raw 전량 보관을 제거했다. 별도 legacy oracle로 원문·다수 동률·수동 결정/대표·NULL 의미를 대조했다. 복원 backup sidecar도 정리했다.
- 일반 분포 500,000건 DB를 실제 PC restore→mobile import→PC restore→mobile import하고 모든 교환 컬럼/타입/NULL/원문/수정값/결정 비교 diff=0을 확인했다. 거대 중복 2군 PC restore는 반복 list.count에서 20분 이상 지연돼 own fixture 프로세스만 중단했다. PC 저장소는 수정하지 않고 재현/동률 보존 개선안을 인계했다.
- 최종 Flutter 868 passed/15 skipped, analyze 오류0/기존 warning9/info10, 6종 건수·filter parity·bounded duplicate 11 passed. Android15/4GB/profile 50만 건 실제 데이터 대시보드↔통계↔지도/뒤로가기 20회(검사 총368.51초)와 background/resume를 통과했다. 요약 cold/warm 2,388/1ms, 통계60,585/1ms, 지도6,664/1ms이며 DB 초기 준비15,824ms/registry3,565ms는 별도다. 통계 cold·초기 준비·거대군 재생성 비용은 여전히 크며 실기기 S24 원인/성능은 미확정이다.
- 실제 IME 글꼴1.0/1.3/2.0 및 세 줄 입력→키보드 닫기→가로회전→스크롤→재열기의 내용/버튼 보존을 확인했다. 실제 별점은 제출하지 않았다.
- 백그라운드 50만 건 1,143,455,744bytes DB 저장 중 Launcher 유지, 완료 알림 탭의 Files 전환/정확한 파일명/quick_check를 확인했다. native 알림 탭에서 파일 앱이 없을 때도 완료 파일명·위치와 열기/공유 대안을 유지하도록 보완했다. 최종 profile 빌드에서 DocumentsUI 일시 disable로 실제 dialog/열기 실패 시 유지·앱 생존을 확인하고 원복했다. 삼성 내 파일/SAF28/운영 서버는 미검증이며 VERSION/push/배포는 없다.

## 2026-09-30 (dev 미배포)

### 공유 resolver(resolve.ts·resolve.dart) 링크 색인 캐시 반영

- 앱 벤더 복사본과 같은 결함을 공유 정본 `resolve.ts`·`resolve.dart` 에서도 고쳤다(커뮤니티 지도 ingest 에서 `resolveAgency` 3,000회 12,622ms → 3ms). 스냅샷별 링크 색인 캐시(TS `WeakMap`, Dart `Expando`). `shared/agency-region-registry` 의 manifest 해시 2개·resolver 2개를 PC·지도와 바이트 동일로 받았다. registry 데이터·버전(`2026-09-29.3`) 변경 없음. `test/storage` registry 테스트 50건 통과.

### 기관 registry 해석 성능: 신고 3천 건에서 앱 무응답(ANR) 수정

- 결함: 사용자 실기기(dev 빌드, 신고 약 3,000건)에서 화면 반응이 멈추고 "앱이 응답하지 않음" 팝업이 반복됐다. 원인은 registry 벤더 복사본 `_walkChain` 이 호출마다 links 9,185건 전체로 `byFrom`/`byTo` 색인을 새로 만든 것. 신고 행마다(`_rowToReport`·`Report.fromJson`·통계 기관 키) UI isolate 에서 불려 목록·대시보드·통계를 열 때마다 수 초~수십 초 멈췄다.
- 수정(`lib/services/agency_registry.dart`, 결과 불변): 링크 색인을 스냅샷에 한 번만 만들고, `displayCurrentAgency`·`resolveKeyedAgency` 결과를 (코드, 이름)별로 스냅샷 객체에 캐시한다. 스냅샷은 번들 asset 이라 실행 중 바뀌지 않고, 새 registry 는 새 앱 빌드 = 새 스냅샷 객체라 캐시도 같이 새로 만들어진다. DB 에는 원문만 저장되므로 계산 결과가 굳지 않는다.
- 앱 시작 때 registry JSON(약 11.7MB) 해석·색인 구축을 `compute` 로 UI isolate 밖에서 한다.
- 정본 `resolve.dart`·`resolve.ts` 는 같은 날 별도 변경(위 항목)으로 고쳤다. PC `resolve.py` 는 이미 한 번만 색인한다.
- 측정(`flutter test`, 호스트 VM): 실제 스냅샷으로 `displayCurrentAgency` 3,000회(기관 60곳 반복) 25,436ms → 30ms.
- 테스트: 실제 스냅샷의 링크 양끝 코드 전건 + 색인·압축·legacy 표본을 정본 resolver 와 대조하고 캐시된 공개 API 의 재호출 일치를 검사하는 테스트 추가. `flutter test` 813 통과(18 skip), `flutter analyze` warning 10 → 9 · info 15(변경 전과 같음). 실기기 확인은 NOT_RUN.

## 2026-09-29 (dev 미배포)

### 폐지 하위조직 코드 색인 포함·registry 2026-09-29.3

- 검수 수정: 파주시 도시경관과 `4060425`는 파주시 `4060000`, 종로구 총무과 `3000188`은 종로구 `3000000`으로 집계한다. 기존 현존 지자체 코드도 새 경계에 맞춰 조회 시 재계산한다.
- 앱 시작 때 읽는 색인은 336,139행·20,435,472바이트에서 일반 94,339행+`[code,agg]` 압축 80,464행·7,754,427바이트로 줄었다. 앱 로더·공유/앱 리더가 압축 행을 해석하고 벡터·통계 테스트가 이를 검증한다.

- 결함(PC와 동일): registry 2026-09-29.2로 운영 2,868건을 재계산했더니 기관코드가 있는데도 86건(3%)이 미확정으로 남았다. 폐지된 부서 코드를 색인에 넣어 답변 당시 소속 집계기관(경찰은 경찰서 단위)으로 연결한다.
- 공통 자료 `shared/agency-region-registry`(registry `2026-09-29.3`)를 PC와 같은 바이트로 받아 asset으로 번들한다. 위 검수 수정으로 지자체 내부 국의 통계 키가 바뀐다.
- 공용 벡터 31건 → 36건(대표 5건 추가). 벤더 parity 테스트가 공유 포트와 앱 복사본을 전 agency 벡터로 비교한다. 버전 핀을 `2026-09-29.3`으로 올렸다.
- 옛 신고 통계 테스트: 실제 스냅샷으로 폐지 부서 코드 9건이 8개 확정 키로 묶이고 `src:` 행이 없음을 고정했다(재크롤링 없이 파생 재계산).

### 현행 기관 표시명 '경찰청 ' 접두어 제거·registry 2026-09-29.2

- 2026-09-29 사용자 결정(PC와 동일): 기관코드로 찾은 현행 기관 표시명은 공식 '전체기관명'에서 맨 앞의 '경찰청 ' 접두어만 한 번 뗀다('경찰청 광주경찰청 광주동부경찰서' → '광주경찰청 광주동부경찰서', 본청 '경찰청'·비경찰 그대로). 원문 `처리기관`·코드는 건드리지 않는다.
- 공통 자료 `shared/agency-region-registry`(registry `2026-09-29.2`)를 PC와 같은 바이트로 받아 asset으로 번들한다. 중간 검수에서 발견한 코드 없는 신고의 공식 전체기관명 조회 문제를 해결하도록 Dart resolver와 앱 벤더 복사본이 표시명·공식 전체기관명을 모두 조회한다. 원문 `처리기관`은 유지한다.
- 공용 벡터 31건에 코드 없는 신고의 공식 전체기관명·표시명·비경찰 이름을 추가했다. 벤더 parity 테스트는 공유 포트와 앱 복사본을 비교한다.
- 후속 검증: `flutter test --no-pub test/storage` 142건 통과.

### 경찰기관명 정규화 옵션 폐지

- 설정 토글과 Provider·로컬 DB·지도·파일·감시목록의 옵션 전달을 제거했다. 기관코드 registry를 항상 사용하며 미확정 기관명은 원문 그대로 표시한다. 예전 Standalone 저장 키와 Client 서버 응답의 호환 필드는 무시한다.
- 서버와 공유하는 parity 하네스에서 정규화 옵션 축을 제거했다.



### 기관코드 전체자료 대조: registry 2026-09-29.1과 통계 키 전환

- 공통 자료 `shared/agency-region-registry`(registry `2026-09-29.1`, 스키마 v2: 현존 색인·폐지 전달·경계 링크·기관 ID 맵)를 PC와 같은 바이트로 받아 asset 으로 번들한다(pubspec에 index/legacy/institutions 추가, vectors·provenance·data-sources는 제외).
- 통계(기관·담당자 표, 지도 브레이크다운·기관수)의 묶음 기준을 표시 이름에서 `agency_stat_key` 로 바꿨다(서버와 같은 규칙·같은 정렬). 출력 행·breakdown 항목에 `agency_key` 를 추가한다. 원문 `처리기관` 은 덮어쓰지 않는다. 과거 신고는 조회 시 새 registry 로 다시 계산된다(재크롤링 없음).
- `lib/services/agency_registry.dart` 벤더 리졸버를 새 포트에 맞게 갱신하고, parity 하네스가 asset 번들 registry 를 로드하도록 했다(`AgencyRegistry.ensureLoaded`).
- 검증: `flutter test` 802건 통과(skip 14, 골든 자동 skip 포함), 공용 벡터 25건·벤더 parity 통과, 서버 `logic_parity_check` 48조합 diff 0.

---

## 2026-09-28 (dev 미배포)

### 커뮤니티 공유: 답변 완료만, 계정별 기여, 원문 기관코드, 숫자 별점 (observation-v4)

- 답변 완료(수용·일부수용·불수용·답변완료/기타) 관측만 업로드한다. 처리중·보완요청·취하·이송은 이벤트를 만들지 않고(`status_correction` 발급 중단) 로컬 `detail_status`만 기록한다. 구버전이 남긴 미전송 `status_correction` 은 `blockSupersededCorrections` 가 보내지 않고 `blocked:deprecated_status_correction` 으로 보존한다(PC 동일). 중앙은 비종결 payload 를 이벤트별 `non_final_not_accepted` 로 거절하며, 답변 완료 뒤 비종결로 돌아간 신고는 마지막 답변 상태를 유지한다.
- 같은 신고를 다른 카카오 계정이 올리면 두 계정 모두의 내 신고에 연결하고, 전체 지도·기관·담당자 통계는 고유 신고 1건(가장 최근 답변을 대표)으로 센다. capture·reshare 는 현 계정 범위만 본다. Standalone 신고번호를 private 이벤트 필드로 함께 보낸다(Observation 해시 제외, 공개 안 함). 개발 중 두었던 계정 간 '소유 이전' 규칙은 이 규칙으로 대체했다.
- Standalone 파서가 선택 답변의 `C_MANAGE_ORG` 를 `Report.agencyCode`(reports `처리기관코드`)로 저장하고 payload `source_agency_code` 로 보낸다(선행 0 보존, 없으면 NULL, 33자 이상은 명시적으로 차단). `처리기관` 원문은 덮어쓰지 않는다.
- `Report.rating` 정수 1..5 만 공유한다(`ratingCause` 는 보내지 않음). 별점을 매긴 뒤 재조회하면 새 완료 관측이 된다. 필수 동의 정책 `2026-09-28.3`. parser_version `mobile-parser-4`, 계약 사본을 지도 정본에서 동기화했다.
- 앱 DB 스키마 16(서버 5): `처리기관코드` 열 추가. 이전 버전 DB 는 이전 릴리스와 같이 백업 뒤 비우고 초기화 크롤링으로 다시 수집한다(업데이트 로직은 만들지 않음, 사용자 결정). 서버↔모바일 교환·백업 경로에 새 열을 반영했다.
- 중앙이 새 계약을 받도록 배포된 뒤에 앱을 배포해야 한다.

### 기관·행정구역 코드 레지스트리

- 공통 자료 `shared/agency-region-registry`(registry `2026-09-28.1`)와 Dart resolver 를 앱 asset 으로 번들한다(PC·지도와 같은 바이트). 통계는 기준일의 현행 기관명을 보여 주고, 추적할 수 없는 옛 기관·지역은 `(구)` 로 보존한다. 갱신·전파는 PC 스킬 `sr-agency-registry` 가 맡는다.
- 검증: `flutter test` 789건 통과(골든 포함).

### 커뮤니티 공유에 위반법규 추가 (observation-v2)

- 공유 payload 에 `violation_law`(위반법규: 법 이름·조항)를 넣는다. 처리내용 원문은 보내지 않는다. 계약 사본 `contracts/community-ingest` 를 v2 로 갱신했다(필수 동의 정책 `2026-09-28.2`). 중앙(커뮤니티 지도)이 v2 를 받도록 배포된 뒤에 앱을 배포해야 한다.
- 검증: 공용 계약 벡터 35건(위반법규 3건 추가) 통과, 수집 단위 테스트 추가.

### 통계 표는 답변 완료 신고만, '과태료 미확인', 주정차·버스·쓰레기 일부수용

- 기관·담당자 표(모바일 카드)에는 답변이 완료된 신고만 넣는다. 처리중·보완요청·이송·취하는 기관·담당자가 있어도 빠지고, '처리중' 열·칸을 없앴다. 처분 분포는 답변된 신고를 분모로 하고 처리중 건수는 따로 적는다.
- '처분 미확인'을 '과태료 미확인'으로 바꿨다(대시보드 교통위반 카드 포함). 주정차·버스전용차로·쓰레기 메뉴의 '일부수용'은 파서가 금액 없는 '과태료' 대신 '미확인'을 저장하고, 이미 저장된 건도 통계에서 과태료 미확인으로 센다.
- 근거: 실제 DB 조사(Muse, 3,071건 — 처리중 83건 전부 기관 없음, 기타·미분류 10건 전부 주정차 일부수용). 검증: 서버 단위·공용 벡터(요약·파서) 통과, 모바일 비골든 740건·골든 4건 통과, 서버↔모바일 동등성 48개 조합 차이 0, PC 통계 브라우저 스펙 36건 통과(Chromium).

### 로그인·동의한 기기로 업로드 연결 자동 전환

- 이 기기에서 카카오 로그인을 직접 마치거나(브라우저·계정 확인 단계를 거친 연결) 공유 동의를 저장하면, 업로드 연결이 다른 기기에 있어도 설정의 '이 기기로 전환'을 누르지 않고 이 기기로 가져온다. 앱 시작·주기 확인만으로는 가져오지 않아 기기끼리 서로 뺏지 않는다. 계정 공유 중지(suspended)는 가져오지 않는다.
- 검증: 모바일 `gate_state_test` 3건(일반 확인은 전환 안 함·동의 후 전환·로그인 확정 후 전환), 서버 `test_community_gate` 2건. 커뮤니티 테스트 모바일 292건·서버 38건 통과.

### 동기화·크롤링 로그 창 하단 잘림, 공유 전송 로그 10건 단위

- 로그 창 마지막 줄이 시스템 내비게이션 바에 가려지던 문제를 고쳤다. 앱이 edge-to-edge 인데 동기화/크롤링 화면 본문에 하단 안전 영역이 없었다.
  본문을 `SafeArea(top: false)` 로 감싸 로그 창이 내비게이션 바 위에서 끝난다.
- 상단 제어 영역은 내용 높이만 차지하고(상한 Standalone 50%, Client 대기 60%·크롤링 중 40%, 넘치면 스크롤) 남은 높이는 모두 로그 창이 쓴다.
  Standalone 에서 상태 카드 아래 비던 공간만큼 로그 창이 올라온다.
- 동기화 로그에 업로더 배치마다 찍히던 `[Supabase] 진행: …` 줄을 없앴다. 10건마다 `130/2469건 완료` 바로 아래에 `N/M건 전송`
  (이번 실행에서 캡처한 공유 이벤트 중 서버 확인 수 / 업로드 대상 수)을 적고, 끝난 뒤 한 번 더 적는다. 나머지 공유 안내 문구의 `[Supabase]` 접두어도 뺐다.
- 검증: 신규 `sync_upload_progress_log_test` 3건 포함 전체 739건 통과·14건 건너뜀(Flutter 3.47.5), 변경 파일 정적 분석 0건.
  화면 확인은 사용자가 직접 한다(에뮬레이터 확인 not-run).

### 통계 화면 개편 — 요약 카드·월별 처리 추이·차트 펼치기, 여섯 보기 두 줄, 전국 안전신고 현황 이동

- 통계 탭을 조건(연도·분류·검색 가능한 위반법규 선택 줄) → 접을 수 있는 요약(2열 카드 6개: 총·답변 완료·과태료·경고/범칙금·평균 처리기간·확정 과태료+금액 미확인+추정) → 월별 처리 추이(답변일 기준, 그중 과태료, 이번 달 집계 중) → 처분 분포·위반 유형 펼치기 → 신고 지도 열기 → 상세 통계 순서로 바꿨다.
- 여섯 보기를 3+3 두 줄로 모두 보이게 하고 상세 목록에 이름 검색·정렬(총 건수·과태료·확정 과태료·처리기간·별점·이름)을 넣었다. 카드는 이름·총 건수, 평균 처리(표본)·별점(평가 수)·금액, 처분 일곱 칸 그리드 순이며 순위 메달은 없앴다. 카드 탭 → 목록 이동은 그대로.
- 요약만 실패하면 요약 자리에 '다시 시도'. 조건을 빠르게 바꿀 때 늦게 온 이전 응답을 버린다. 위반법규 떠 있는 버튼 → 조건 줄의 선택창(검색).
- 상단 '교통위반 과태료 합계'는 선택 분류의 확정 과태료 카드로 대체했다(PC 와 같음, 확정·추정 분리 유지).
- Standalone 요약에 서버와 같은 `disposition`·`fine_amount`·`report_types`·`monthly_answered_fine`, 기관 행 `avg_days_count` 를 추가했다. 공용 벡터 `contracts/stats-overview-vectors.json`.
- 대시보드의 전국 신고현황을 통계 탭 하단으로 옮겼다(제목 '전국 안전신고 현황').
- 화면 파일의 고정 색(`Color(0x…)`: 교통 분류색·별점색·메달색)을 테마·기존 상태색으로 바꿨다.
- 검증: 비골든 732건 통과·14건 건너뜀(신규 `stats_overview_vectors_test` 7건, 요약 위젯 18건 — 360/430dp × 글자 1.0/1.3/2.0 × 두 테마 overflow 0), 정적 분석 기존 info 7건. 서버↔모바일 동등성 48개 조합 차이 0.
  실제 폰트 전체 화면 렌더(`test/tool/stats_screen_render_test.dart`): Standalone(서버 fixture 를 가져온 DB)·Client(fixture 서버) 각 360/390/430dp 두 테마 + 큰 글자 1.3·2.0, 렌더 예외 0.
  통계 요약 골든 2건은 사용자 승인(2026-09-28) 뒤 새 화면으로 기준을 갱신했다(검토한 후보와 픽셀 동일, 골든 4건 통과). 에뮬레이터 실기 확인은 not-run.

### 상세 검색 순서와 Enter 검색

- PC `main` 통계표에서 공통으로 검색할 수 있는 열의 순서에 맞춰 `차량번호 → 신고번호 → ID → 처리기관 → 담당자 → 과태료/범칙금 → 처리상태 → 별점`을 먼저 배치했다. 그 밖의 조건은 동일한 순서로 뒤에 두며, 별점이 없는 관리 화면에서는 해당 항목을 생략한다.
- ID 검색을 추가했다. 체크 항목·드롭다운·경찰기관 조건을 터치로 고른 뒤에도 Enter를 누르면 현재 선택값으로 검색한다.
- 검증: 상세 검색 순서·체크 후 Enter·키보드로 체크 후 Enter·ID 검색 위젯 테스트 4건 통과, 비골든 전체 719건 통과·6건 건너뜀. 전체 정적 분석은 기존 정보 메시지 7건이며 변경 파일에는 오류·경고가 없다.

## 2026-09-27 (v2.0.0+31, dev 미배포)

### 통계 과태료 표시

- 기관·담당자 카드의 확정액·금액 미확인·추정액을 줄바꿈 가능한 별도 항목으로 표시하고, 확정액과 추정액 모두 해당 건수를 붙였다. 좁은 화면에서 뒷부분이 `…`으로 잘리던 문제를 고쳤다.
- 통계 상단에 PC와 같은 교통위반 확정 과태료 합계와 별도의 `추정금액합계`를 추가했다. 현재 통계의 답변 연도·법규·취하 제외·대표건 조건을 따르고, 추정 필드가 없는 서버는 `미지원`으로 표시한다.
- 검증: 좁은 화면·큰 글꼴의 금액 표시, 추정 0건·미지원 구분, 기관 없는 신고의 카테고리 합계 포함. 비골든 테스트 715건 통과·6건 건너뜀, 변경 파일 정적 분석 이상 없음.

### 대량 신고 변경 알림 묶기

- Client 크롤링 결과와 Standalone 동기화 결과가 20건을 넘으면 신고별 Android 푸시를 보내지 않고 `n건의 변경사항이 있습니다` 알림 한 건만 표시한다. 20건 이하는 기존 개별 알림을 유지한다.
- 변경 상세는 앱의 대기 변경 목록에 보존한다. 알림 기록은 기존 최대 200건 범위에서만 객체를 만들어 대량 결과 처리 부담을 줄였다.

### 이전 공유 자료 우선 업로드와 동기화 로그

- Standalone 동기화 전 이전 미전송 공유 자료를 `recovery` 업로드하고, 다 보냈을 때만 새 신고 수집을 시작한다. 네트워크·인증·재시도 대기로 자료가 남으면 건수와 이유를 알리고 시작하지 않는다.
- 동기화 중 실시간 공유 업로드와 완료 뒤 복구 업로드의 전송·확인·재시도 건수 및 결과를 동기화 로그에 표시한다. 완료 신호는 업로드 확인 뒤 보낸다. Client 크롤링 로그는 PC 서버 로그를 받는다.

### 동기화 중 종료 방지·로컬 공유 사본·자동 업로드

- 동기화 중 Android 뒤로 가기로 실행 화면이나 앱을 닫지 못하게 했다. 기존 동기화 알림 서비스를 유지하며, 중지는 화면의 중지 버튼으로 요청한다.
- 전체 재동기화는 로컬 공유 데이터셋을 새로 시작한다. 이전 미전송 기록과 Supabase 자료, 사용자가 수정한 신고값은 유지한다. 공유 연결 확인이 안 되면 신고 저장을 시작하지 않는 보호 규칙은 유지한다.
- 공유 이벤트의 개인 DB 저장 완료 표시 뒤 업로더를 깨우고, 동기화 완료 뒤 누락 전송도 다시 확인한다. 빠른 실행의 동기화에도 같은 경로가 적용된다.

### 공유 연결 기기 이름 표시

- 설정의 신고내용 공유 카드에서 내부 업로드 연결 순번(`epoch`) 대신 Android에 설정된 기기 이름과 연결 상태를 표시한다. 새 연결을 등록할 때도 해당 이름을 보낸다. 기기 이름을 읽을 수 없으면 모델명 또는 일반 이름을 쓴다.

### 위반법규 파싱과 동기화 화면

- Standalone 동기화에서 `「자동차관리법」제29조`처럼 꺾쇠 안에 적힌 법 이름과 조·항을 위반법규로 저장한다. 띄어쓰기가 섞여도 읽고, 기존 도로교통법 표기도 유지한다. 서버와 같은 합성 입력으로 검증했다.
- 데이터 동기화 화면의 로그 영역 높이를 줄여 상태와 실행 버튼을 볼 공간을 넓혔다. 로그는 계속 스크롤할 수 있다.

### 앱 재실행 때 카카오 연결 화면이 반복되는 문제

- 앱 시작 시 보안 저장소에 남은 카카오 세션을 게이트 검사 전에 복원한다. 유효한 세션과 현재 공유 동의가 있으면 연결을 다시 묻지 않는다. 토큰 갱신이 일시 실패하면 로그인 요청 대신 확인 대기 화면을 보여 준다. 세션이 없거나 실제 재인증이 필요하면 기존 안내 화면을 보여 준다.

### 신고 공식 좌표 저장과 지도 반영

- Standalone 동기화에서 안전신문고 상세 응답의 위도·경도를 기존 DB 열에 저장한다. 보완 완료로 신고 주소나 좌표가 바뀌면 다음 동기화에서 갱신하고, 커뮤니티 지도에도 새 좌표를 보낸다.
- 카카오 REST API 주소 변환과 키 입력·자동 백필을 제거했다. 신고 지도는 저장된 공식 좌표로 표시하며, 좌표가 없으면 이전 주소 변환 결과를 대신 쓰지 않는다.
- Client는 서버가 제공하는 공식 좌표를 사용한다. 앱 버전·Google 빌드 번호·DB 스키마 버전은 변경하지 않았다.

### GitHub Actions artifact 보관 기간

- 개발 APK, 릴리스 검증용 mapping·APK·AAB artifact의 보관 기간을 1일로 설정했다.

### Demo 보기·첫 실행 순서·Standalone 동기화 오류 수정

- 첫 설치에서 Client/Standalone 모드를 먼저 고르고 카카오 로그인·공유 동의, 공통 권한, 해당 모드 설정으로 이어진다. 모드 선택 아래 `Demo 보기`를 추가해 로그인·권한 없이 가상 신고 100건을 실제 화면에서 볼 수 있게 했다. 기존 demo/demo 경로도 유지한다.
- 데모 DB의 기존 3건을 모두 합성 자료 100건으로 바꾸고 실제 신고 원문·첨부 URL을 제거했다. 데모는 안전신문고 동기화·별점 제출·커뮤니티 업로드를 하지 않는다.
- Android Standalone 동기화 중 `PathUtils` ClassNotFoundException을 없애는 `path_provider_android` 2.3.1로 lockfile을 갱신했다.
- 검증: 진입·데모 DB·백그라운드 로그인 관련 테스트 21건 통과. 정적 분석 오류·경고 0(기존 형식 info 7건). 전체 테스트는 Flutter 테스트 엔진의 `shaders/ink_sparkle.frag` 디코딩 오류로 일부 위젯 테스트가 실패했다. Android 릴리스 빌드는 실행하지 않았다.


### 사용자·유지보수 문서 현행화

- README의 첫 실행 순서, 필수 카카오 로그인·공유 동의, Client 연결 버튼·PC v3 이상 검사와 기존 설정 차단 안내를 실제 화면에 맞췄다. `docs/architecture/overview.md`에 현재 진입·권한·WebSocket 순서를 적었다. 문서만 변경했으며 앱 버전·빌드 번호는 그대로다.

### 기존 Client 설정의 구버전 PC 서버 연결 차단

- 저장된 서버 주소·API 키로 앱을 다시 열 때도 PC 서버 버전을 먼저 확인한다. 카카오 로그인·공유 동의 게이트는 그대로 우선하며, 게이트 통과 뒤 서버가 v3 미만이거나 버전 확인에 실패하면 신고 화면을 열지 않고 업데이트·재확인·서버 설정 변경 화면을 보인다. 이때 WebSocket 서비스를 멈춘다.
- 게이트가 다시 닫히면 열린 하위 화면을 닫고 Client WebSocket을 중지한다. Android의 WebSocket 재연결과 알림 신고번호 전송도 게이트 상태 및 PC 서버 v3 이상을 확인한 뒤 수행한다.
- 새 서버 설정의 버전 검사도 요약 API보다 먼저 수행한다.
- 검증: Client 저장 설정의 차단·재확인·동의 게이트 우선·화면 복귀 테스트 포함 `test/community` 278 통과·3 skip, 연결 서비스/진입 순서 테스트 24 통과, `flutter analyze` 오류 0, 고정 Flutter 3.47.5·Java 17로 `:app:compileDebugKotlin` 성공. Google 빌드 번호는 31로 유지한다.

### 첫 설정 권한 화면 중복·Client 서버 버전 검사

- 첫 실행 공통 권한 화면 이후 설정을 저장할 때 권한 화면을 다시 쌓지 않는다. WebSocket은 권한이 아니라 백그라운드 서비스이므로 Client 설정 완료 뒤 시작하고 화면 진입을 계속한다. 설정의 권한 관리 화면에서는 실행 상태를 계속 확인·제어할 수 있다.
- Client 서버 연결과 설정 저장 전에 `/api/v1/server/version`을 확인하고 PC 버전 3 미만 또는 버전을 알 수 없는 서버는 거절하며 PC v3 이상 업데이트를 안내한다.
- `VERSION`을 `2.0.0+31`로 올리고 공통 Android 빌드 스크립트의 버전 동기화 함수로 `pubspec.yaml`을 맞췄다.

### 동의문 복제본 정리

- 동의문을 중앙에서 받게 되어 이 저장소의 사본(`contracts/community-ingest/consent/`)을 지웠다. 정본은 지도 저장소 `contracts/consent/`(복사하지 않음)와 중앙 DB 다.
  실제 스택 시험도 동의문 파일 대신 중앙 `policy` 로 받은 버전·해시로 동의한다.

### 공유 동의문을 중앙에서 받는다, 이미 한 동의는 바로 인정 (PC 와 같은 규칙)

- 동의 정책 버전·동의문을 앱에 넣어 두지 않는다(`communityRequiredPolicyVersion`·`assets/community/` 제거). 필수 설정 화면은 카카오 인증 뒤
  중앙 `policy` 로 본문을 받아 sha256 을 확인한 뒤 보여 주고, **보인 본문의 해시**로 동의한다(예전엔 서버가 알려 준 해시를 그대로 보내,
  옛 문구를 보여 주고 새 문구에 동의한 것으로 남을 수 있었다). 게이트는 grant 의 (버전, 해시)를 중앙의 지금 정책과 비교한다 — PC 와 같은 계약 벡터.
  동의문이 바뀌어도 앱을 새로 배포할 필요가 없고, 바뀐 뒤 기존 동의는 새 본문으로 다시 묻는다.
- 카카오 로그인을 확정하면 게이트가 곧바로 다시 확인하고, 같은 카카오 계정이 이미 동의했으면(PC 포함) "동의 완료"로 보여 다시 묻지 않는다
  (예전엔 60초 poll 까지 기다렸고, 기존 동의를 화면이 몰랐다).
- Client 모드에서 이 앱과 서버의 카카오 계정이 다르면 필수 설정 화면과 설정(서버 계정 카드 아래)에 알린다.
- 동의문 표시(표·링크)는 따로 고친다(Sol).

### 실제 앱에서 공유 동의를 저장하지 못하던 문제

- 앱 조립부(`main.dart`)가 필수 설정 화면에 커뮤니티 계정 API 클라이언트를 넘기지 않아, 체크하고 "동의하고 계속"을 눌러도
  "커뮤니티 서버 설정이 없어 동의를 저장할 수 없습니다"가 나왔다(dev 빌드 실기기에서 발견 — 시험은 클라이언트를 직접 넣어 통과하고 있었다).
  게이트와 같은 설정의 클라이언트(`gate.accountClient`)를 넘긴다. 설정 화면의 커뮤니티 카드도 게이트·클라이언트를 받지 못해
  공유 동의 상태·철회·업로드 연결 전환 섹션이 보이지 않던 것을 함께 고쳤다.
- 시험: 앱과 같은 방식으로 넘긴 클라이언트로 동의가 서버에 저장되는지, `main.dart` 가 클라이언트를 넘기는지.

### Client 모드 DB 백업(다운로드)이 스피너만 도는 문제

- 원인(1.3.5): 서버 DB 를 한 요청에 통째로 2분 안에 받아야 했고, 넘기면 이전 요청을 끊지 않은 채 처음부터 다시(최대 5회 — 주석은 3회) 받았다.
  폰에서 서버까지 느린 경로(약 2Mbps 미만, 31.6MB 기준 2분 초과)면 같은 파일을 여럿 동시에 받다 모두 시간 초과되어 최대 약 10분 동안 스피너만 보였다.
  서버 쪽 DB 추출은 웹 백업과 같은 함수이고 0.09초라 원인이 아니다.
- 이제 파일로 흘려 받고(`<파일>.part` → 끝까지 받고 크기가 맞을 때만 이름 변경), 30초 동안 한 바이트도 오지 않으면 요청을 실제로 닫고 멈춘다.
  큰 파일이라 자동으로 처음부터 다시 받지 않는다. 설정의 DB 백업과 "Standalone 으로 전환 → 서버 DB 받아 변환" 모두 받은 크기/전체 크기와 취소 버튼을 보인다.
- 시험: 흘려 받기·진행률, 무응답 멈춤(재시도 없음), 크기 부족, 서버 오류, 취소, 실제 소켓에서 멈춘 서버를 끊는지(`test/services/api_service_db_download_test.dart`).

### dev 시험용 APK 자동 빌드

- `dev` 브랜치에 push 하면(문서만 바뀐 경우 제외, 수동 실행 가능) 릴리즈와 같은 셀프호스트 러너·고정 Flutter·업로드 키로 릴리즈 모드 APK 를 만들어
  GitHub Actions artifact(APK·mapping·SHA-256, 30일 보관)로 올린다(`.github/workflows/build-dev-apk.yml`). 태그·GitHub Release·AAB 는 만들지 않는다.

### 커뮤니티 동의 정책 2026-09-28.1 (과태료 금액 통계 공개)

- 사용자 승인(2026-09-27)으로 신고 지도가 답변에 적힌 과태료 금액의 통계를 공개한다. 동의문 `assets/community/share-consent-2026-09-28.1.md`(지도 저장소 정본과 같은 바이트), 필수 버전 `communityRequiredPolicyVersion` 변경. 2026-09-26.1 동의자는 다음 상태 확인에서 새 동의 화면을 본다(철회 아님).
- 계약 사본 `contracts/community-ingest/` 동기화(MANIFEST 검사 통과). `flutter test test/community` 262 통과. 전체 실행의 골든 4건 실패는 dev 원본(82efd333)에서도 같게 실패하는 기존 문제.

### 카카오 로그인 필수 — 카카오 로그아웃은 신고 내역 삭제, 다른 계정의 DB 가져오기 차단 (PC 와 같은 규칙)

- 로그인만 푸는 "연결 해제"(설정 카드, Client 카드의 서버 연결 해제와 그 API 호출)를 주석 처리했다. 설정 카드·온보딩에 "카카오 로그아웃"을 두고,
  "로그아웃하면 이 기기에 저장된 신고 내역이 모두 지워집니다…" 확인 뒤 신고 자료를 비우고 로그아웃한다(감시 목록·지오코딩 캐시는 남김,
  동기화·지도 변환 중이면 아무것도 지우지 않고 거절). Client·데모 모드는 지울 이 계정 자료가 없어 로그아웃만 한다.
- 신고 자료의 주인: 게이트(Standalone)를 처음 통과할 때 로그인한 카카오 회원번호를 개인 DB `sync_meta['kakao_member_id']` 에 적는다.
  다른 카카오 계정으로 로그인하면 `db_owner_mismatch` 로 막고 온보딩에 "신고 내역 지우고 이 계정으로 시작"/"로그아웃(신고 내역 유지)"을 보인다.
- 서버 DB 가져오기·백업 복원·직전 DB 되돌리기는 주인이 지금 로그인한 계정과 같은 DB 만 받는다(주인 표시가 없는 이전 DB·다른 계정 DB 는 바꾸기 전에 거절).
- Codex 독립 검수(서버 레포 `docs/reviews/2026-09-27-kakao-logout-owner-codex.md`) 반영: Client·데모에서 받은 게이트 통과로 실제 Standalone DB 에 들어가지 않게 통과를 실행 모드에 묶고 모드 전환 때 다시 확인, 삭제를 백업·복원과 같은 파일 배타 구간에서 실행(막 시작한 동기화가 지운 뒤에 신고를 다시 쓰지 않게), 주인 표시를 읽지 못하면 로그아웃하지 않음.
- 기존 교환 시험은 fixture 계정(910001)의 DB 로 바꿨고, 주인·삭제·거절·게이트·화면 시험을 추가했다. 서버 레포 왕복 검사(주인 표시 포함) 차이 0.

### 보안 저장소 flutter_secure_storage 9 → 10 (Play `H2.h.b` 수정 1단계)

- file_picker 수정판이 요구하는 flutter_secure_storage 11 은 v10 이전 방식으로 저장한 자료를 읽지 못해, 먼저 10 으로 올려 자료를 새 cipher 로 옮긴다
  (다음 릴리즈에서 11 + file_picker 13). 저장 옵션은 v9 와 같게 두었다. 이관은 앱을 여는 즉시 포그라운드에서 끝내고 표시(`secureStorageV10Migrated`)를
  남기며(Android 는 자료 파일에 옮겨지지 않은 v9 항목이 0개일 때만). 확인되지 않으면 평소 화면 대신 복구 화면을 띄워 앱을 다시 열어 재시도하게 한다
  (로그인 정보를 지워 우회하는 경로는 두지 않음 — 카카오 로그인 필수), 백그라운드 작업은 그 표시 전에는 보안 저장소를 열지 않는다(두 엔진 동시 이관 방지).
  실제 앱: v9 디버그 빌드에서 카카오 연결을 눌러 쓴 로그인 대기 값이 v10 제자리 업데이트 때 새 형식으로 옮겨지고 표시가 남는 것을 확인. v11 은 표시 없는 설치본을 재로그인 안내로 보내야 한다(data-contracts).
- 에뮬레이터(API 35)에서 v9.2.4 로 쓴 값을 10.3.4 로 제자리 업데이트해 확인: 두 옵션의 쓰기 순서 4가지 × 첫 초기화 순서 2가지와 기본 옵션만 쓴 경우 모두
  값이 같게 읽히고, 이관 뒤 쓰기·재시작도 정상(별도 시험 앱, 앱과 같은 옵션). 실제 앱은 v9 빌드 위 제자리 업데이트 뒤 시작 때 보안 저장소를 열어
  이관 검사를 도는 것까지 확인했다(검증 빌드라 저장된 로그인 자료가 없어 실제 자료 이관은 이 앱에서 미확인). iOS 실기기는 미확인.

### 공유한 자료 전체 삭제 기능 보류(주석 처리)

- 커뮤니티 설정 카드의 `공유한 자료 삭제 요청` 버튼과 확인 창(`_delete`)을 주석 처리했다. 이 기능은 아직 구현하지 않는다(2026-09-27 결정).
  동의 철회는 그대로다. 중앙 호출(`deleteContributions`)과 로컬 삭제 표시 처리(`requestDeletion`)·테스트는 남겨 두었고, 이를 부르는 화면은 없다.
- 확인: `flutter analyze` 이상 없음. `flutter test` 628 통과·3 skip·4 실패 — 실패 4건은 `test/golden/renewal_golden_test.dart`의
  골든 비교로, 변경 전 dev 에서도 같은 4건이 실패한다(이번 변경과 무관).

### 커뮤니티 업로드 장애 대응 UC-1 (서버와 같은 규칙, 계약 `contracts/upload-control/`)

- 업로더를 서버와 같은 규칙으로 다시 만들었다. 예전 결함: 오류 본문의 `httpStatus` 가 실제 상태를 덮음, durable 미확인, 빈 응답에 즉시 무한 재전송,
  HTML 404·400·413·422 를 통째 전송 불가 처리, Retry-After 헤더 무시, 영속 cooldown 없음, 두 isolate 가 같은 lease 이름으로 동시 업로드, 실시간 깨우기 호출처 없음.
  지금: 영수증 있는 durable ACK 만 완료, 형식 오류는 재시도, 서비스·계정 cooldown(재시작에도 유지), 신고별 가장 앞 revision, UTF-8 크기·413 이분,
  실행별 lease + 요청 전 연장, 요청 간격 1.1초·예산, 응답 1MiB·30초에 요청을 끊음, 저장된 writer_epoch 그대로 재전송.
- 401 은 실제 강제 갱신 뒤 재전송. 앱·백그라운드 isolate 가 같은 refresh token 을 동시에 쓰지 않게 `community.db` 잠금 안에서 저장소를 다시 읽는다.
- 앱 업로드 제어기: 수집 직후·앱 복귀·재시도 시각에 깨우고, 실행 중 깨우기는 끝난 뒤 한 번 더 돈다.
- 백그라운드: 게이트 캐시(10분)가 오래됐으면 중앙 상태를 한 번 다시 확인해 보낸다(예전엔 매번 그냥 끝나 예약 업로드가 사실상 없었다).
  자정 작업이 끝나면 다음 자정을 다시 예약하고, 1시간 주기 작업은 자정 성공과 별개로 재시도 시각이 된 행을 보낸다. WorkManager 는 저장 전 실패만 재시도 요청.
- 데모·Client 모드는 업로드·자정 작업·공유 writer 연결 등록을 하지 않는다(예전엔 데모도 게이트 통과 뒤 작업을 등록하고 연결을 등록할 수 있었다).
- 지도 공유 패널: 인증 필요·서버 대기 사유와 시각·가장 오래된 미전송·다음 재시도·마지막 중앙 저장 확인·중앙 저장/지도 반영 건수(한국 시간).
- GPT-6-Sol 구현 검토(높음 6·중간 4·낮음 2) 반영: 영수증 UUID 재확인, ACK 타입 검사(벡터 4건 추가), 동시 이관 재확인, 자정 선점 owner, 401 재전송 heartbeat·간격,
  합류 호출의 자기 실행, 413 이분 성공은 sent, 백그라운드 무효화 기록 대기, 주기 복구 독립, 빌드 인증서 검사 실패 처리(계획 문서 §7 표). 재검토 반영: lease 를 잃은 재전송은 자기 행만 되돌림, 합류 호출은
  도착 뒤 시작한 실행 하나로 합침, 영수증 재확인은 SQL GLOB 한 문장, 자정 실행 예외는 failed 로 기록. 3차: 보류 행 정리도 자기 행만,
  PC 영수증 완전 일치 판정(벡터 추가), 기다리는 enqueue 호출이 있으면 realtime 시작을 그 트리거로 올림.
- `community.db` 스키마 2(서버와 같음, 기존 행 보존). 테스트: 공통 벡터, 서버와 같은 시나리오 32건 + 404/리다이렉트·데모 2건(`upload_control_test.dart`),
  백그라운드·제어기 9건, 강제 갱신·잠금 4건, v1→v2 이관.

### Android: Flutter 3.47.5 고정 · AGP 9 · R8 명시 · 서명 차단 · 산출물 보존 · 사진 디코딩 크기

- Flutter 3.47.5 고정(`tool/flutter-version`, 빌드 스크립트가 확인 — 전역 SDK 는 그대로). AGP 9.1.0·Gradle 9.3.1·KGP 2.4.0, 앱은 kotlin-android 제거 +
  `kotlin { compilerOptions }`. KGP 를 쓰는 플러그인 때문에 Flutter 공식 임시 opt-out(`newDsl=false`·`builtInKotlin=false`)을 근거·제거 조건과 함께 둔다.
  file_picker 11.0.2 는 AGP 9 에서 Kotlin 을 빼버려 그 프로젝트에만 kotlin-android 를 붙였다.
- release 에 R8 축소·리소스 축소 명시. 서명키가 없으면 release 빌드가 실패한다(예전엔 조용히 debug 키로 서명). 검증용만 `ALLOW_DEBUG_SIGNED_RELEASE=1`(이름 `-DEBUG-SIGNED`).
- 빌드 스크립트가 APK·AAB 마다 그 빌드 직후 mapping·R8 출력·서명 인증서·SHA-256·도구 버전(`dist/…/build-meta.json`)을 보존한다. CI 에 검증 전용 실행(`verify_only`)과 mapping artifact 추가.
- 신고 상세 사진을 화면 폭×픽셀 비율로 줄여 디코딩(세로로 긴 이미지는 높이 상한). 호스트 측정: 4000×3000 사진 48,000,000 → 3,491,644 바이트.
- Play 경고 `H2.h.b` 를 CI AAB mapping 으로 file_picker `FileUtils.compressImage` 의 옵션 없는 `BitmapFactory.decodeStream` 으로 확인했다(앱은 압축을 쓰지 않아 실행되지는 않음).
  수정판 file_picker 는 flutter_secure_storage 11(v10 이전 저장 데이터를 읽지 못함)을 요구해 이번에 올리지 않았다 — 보류.
- Flutter 3.47.5 엔진에서 둥근 테두리 안티앨리어싱이 달라져 골든 4개(신고 카드·통계 요약 라이트/다크, 0.37~0.68%·모서리만)를 다시 만들었다. 차이 이미지는 `.agent-runs` 에 보관.
- AGP 9 가 Android SDK 에 Build-Tools 36 을 자동 설치했다(기존 패키지 변경 없음).

### 초기화 크롤링 릴리스: 이전 DB 업데이트 로직 비활성, 이전 DB 는 백업 뒤 비움(서버·map 계약과 함께)

- 이번 업데이트는 초기화 크롤링을 한 번 무조건 하므로 이전 DB 를 새 구조로 옮기지 않는다. `onUpgrade: _migrateLocalDatabase`·`backupBeforeUpgrade` 호출을
  주석으로 남겨 껐다. 기존 DB 가 이전 버전이면 앱이 DB 를 처음 열 때 `<db>.legacy_v<옛 버전>.<시각>.bak` 로 통째로 백업하고 무결성 검사 → 커뮤니티 데이터셋 선회전 →
  그 자리에서 한 트랜잭션으로 비우고 감시목록·지오코딩 캐시만 남긴다(파일 교체 없음). 예전에 직접 고친 값·중복 판단·메모와 신고는 옮기지 않고, 초기화 크롤링 화면이 이 사실과 백업 경로를 안내한다.
- 처음 실행(신고 0건, 비운 기록 없음)은 초기화 크롤링 화면 없이 평소대로. Client 는 서버가 초기화 필요 없다고 하면 화면을 바로 지나간다(예전엔 매번 시작 버튼).
- 이전(또는 더 새) 버전 DB 가져오기 거절: 서버 DB 가져오기는 서버 스키마 4, 앱 백업 복원·직전 DB 되돌리기는 앱 스키마 15 만 받는다(바꾸기 전에 멈춤).
- 초기화 크롤링이 필요하거나 진행 중이면 일반 동기화(수동·공유 대기열 처리)를 시작하지 않는다(서버 크롤 409 와 같음, 판정 실패도 막음).
- GPT-6-Sol 검토 반영: 이전 DB 백업을 파일 복사 대신 한 읽기 트랜잭션의 일관된 사본으로 만든다(다른 연결 때문에 체크포인트가 끝나지 못하면 WAL 에만 있던 쓰기가 빠질 수 있었다).
  `VACUUM INTO` 는 SQLite 3.27 부터라 Android 7~10 에서 실패하므로 쓰지 않는다 — 초기화 크롤링 사전 백업도 같은 방식으로 바꿨다(예전엔 그 기기들에서 초기화를 시작할 수 없었다).
  사본은 가상 표(FTS)와 그 보조 표, 보기에 달린 트리거가 있는 DB 도 그대로 옮긴다.
  데모(심사용) 계정은 첫 로그인이 시드한 신고 때문에 초기화 화면이 나오지 않는다. 재검증 반영: 새 DB 를 옆에 만들어 이름을 바꾸던 방식을 버리고
  (열린 DB 의 WAL 삭제·파일 교체는 SQLite 손상 경로) 쓰기 잠금을 잡은 한 트랜잭션 안에서 버전 재확인·백업·선회전·그 자리 비우기를 한다 — 그 사이 다른 연결의 쓰기는
  잠김으로 실패하고 먼저 열어 둔 연결도 새 DB 를 본다. 이전 버전 데모 DB 를 비울 때 실제 계정의 커뮤니티 데이터셋을 회전하지 않는다.
- 함께 고친 초기화 결함: 신고 0건 계정도 초기화를 끝낼 수 있다, 실패·일시정지 뒤 같은 run 재시도의 사전 백업이 기존 사본 때문에 실패하던 문제,
  백업 무결성 검사가 사본이 아니라 원본을 보던 문제.
- 테스트: `test/storage/migration_test.dart` 를 새 동작 기준으로 다시 씀(v9·v10·v14 백업 뒤 비우기, 되돌림, 새 설치), 복원·가져오기 거절, 새 테스트
  `test/community/rebuild_fresh_install_test.dart`, 초기화 화면 위젯 4건, WAL 백업·잠금·제자리 비우기·데모 제외, `test/storage/db_copy_test.dart`(사본 전체 비교·`VACUUM INTO` 재사용 금지). 대조 실험 15건. 전체 562 passed(3 skipped) 2회, analyze 0건,
  서버↔모바일 왕복 검사 차이 0. `backup_restore_test` 의 임시 폴더 검사는 병렬로 도는 다른 테스트 파일의 복원이 잠깐 만든 폴더를 세지 않도록
  (테스트 전부터 있던 것 제외, 잠시 뒤에도 남은 것만 실패) 고쳤다 — 정리 코드를 빼면 여전히 실패한다.

## 2026-09-26 (버전 변경 없음)

### 커뮤니티 통합 검수 2 — Sol 1차 통합 검토 반영

- **H-01** 공유 사본을 만들 수 없으면(커뮤니티 저장소·manifest 준비 실패) 개인 상세도 저장하지 않고 수집을 멈춘다(이전: 개인 동기화만 진행 → 그 신고의 공유가 영구 누락될 수 있었음). 단건 경로도 같은 함수로 막힌다.
- **H-02** 개인 DB 복원·서버 DB 가져오기 전 커뮤니티 dataset 회전이 실패하면 교체하지 않는다(이전: 실패를 삼키고 교체).
- **H-03** 공유 자료 삭제 뒤: 그 시점까지의 journal 을 **행 순번 경계**로 막는다(앞선 시계의 captured_at 도 막힘). 영속 표시(`community_deletion_pending_v1`)를 먼저 쓰고 적용 뒤 지우며,
  표시가 남아 있으면 업로드·reshare 를 보내지 않는다. 적용 실패는 설정 화면에 안내.
- 테스트: 실패 주입(저장소 없음·회전 실패·삭제 표시 적용 실패·손상 표시), 전체 509 passed / 3 skipped, 실스택 라이브 1 passed.
- **H-03a/b(Sol 2차)** 삭제 대기 표시를 prefs 가 아니라 journal 과 같은 `community.db` 에(삭제별 행) **중앙 삭제 요청 전에** 트랜잭션으로 남긴다. 못 남기면 중앙 삭제를 요청하지 않고, 중앙 실패 때는 자기 표시만 지우며, 적용은 한 트랜잭션이라 동시 삭제가 서로를 지우지 않는다.
- **H-03c/d(Sol 3차)** 표시를 prepared/confirmed 로 나눴다. 중앙 응답 전(prepared)에는 업로드·reshare 를 막기만 하고 적용·삭제하지 않는다. 중앙 성공 뒤에만 확정·적용(앞선 prepared 포함). 4xx 거절이면 자기 표시만 취소, 응답 불명(타임아웃·5xx)이면 표시를 유지하고 다시 요청하도록 안내(삭제는 여러 번 요청해도 안전).
- **Sol 4차** 중앙 삭제 뒤 로컬 정리가 끝나지 않으면(`local_pending`·표시 남음) 성공 문구 대신 "정리를 끝내지 못했습니다 — 삭제 요청을 다시 눌러 주세요"와 게이트 알림을 보인다(정리 훅이 남은 표시 여부를 돌려줌). 테스트: 실제 게이트·community.db·업로더로 이 경로(전송 0), capture 의도 파일 쓰기 실패 시 개인 DB 미변경(`captureAndSaveDetail` 전체 경로, 양성 대조 포함). 전체 515 pass.
- **7일 감사(GPT-6-Sol) 반영** SOL-01: 수동·자정·복구 업로드가 이미 ACK 받은 공유 이벤트를 다시 보내던 것을 고쳤다(PC 와 같은 미ACK 조건, 잘못 생긴 대기 행 정리).
  SOL-02·03(서버와 함께): 서버 DB 가져오기가 모르는 열의 값을 조용히 버리지 않고 교체 전에 멈춘다. entry_value 는 서버 행이 없으면 NULL(예전엔 '').
  SOL-05: 가져오기·복원이 성공해도 직전 DB 사본을 최근 3개 남긴다(예전엔 성공하면 지웠다). `flutter analyze` 0건(설정 화면 async 뒤 context 확인 등). 전체 521 pass.

### 커뮤니티 통합 검수 (Opus, T5 ↔ T6 연결)

- **서버 대기 큐 결과 표시(서버 감사 R8-02)** 크롤 화면이 서버 `/crawl/status` 의 `unresolved`(처리하지 못한 번호 — 목록에 없음·여러 신고에 걸림)를 보여 주고, 크롤 대기열 요청이 거부되면 서버가 준 이유를 그대로 보인다.
- `lib/community/community_wiring.dart`: 게이트(T5)와 데이터 경로(T6)를 실제로 연결 — manifest 갱신·자정/주기 작업 등록·보충 실행·삭제 후 대기 행 차단,
  포그라운드 업로드는 게이트 60초 재검증(`LiveGateCheck`). `main.dart` 가 게이트 생성 직후 호출한다.
- **업로드가 실제로는 아무것도 보내지 않던 결함 수정**: 수집은 공개 설정 URL 로 만든 namespace 를 journal 에 쓰는데 업로더·자정 스케줄은
  아무도 쓰지 않는 `meta.project_namespace`('unconfigured')와 비교했다 → 같은 규칙(설정 URL)으로 계산.
- manifest 를 계약대로: `POST {protocol, connection_id, after, limit}`(이전 GET 쿼리), 페이지 형식 검증, total·중복·dataset/epoch·토큰 3회 규칙,
  받는 동안 upload lease. 연결이 없으면 수집 전 검사를 건너뛰던 경로(fail-open)를 막음.
- 게이트: writer 충돌·공식 계정 없음·superseded 연결이면 진입은 허용하되 업로드 context 를 끈다(이전엔 연결 없이 활성화). 충돌한 다른 기기 정보 표시.
  Client 모드 폰은 업로드 context 를 켜지 않는다. 백그라운드 작업이 읽는 게이트 캐시(`community_gate_cache_v1`)를 게이트가 기록한다(이전엔 아무도 쓰지 않아
  백그라운드 업로드가 항상 건너뜀). 마지막 수락 revision 으로 로컬 revision 하한을 올린다.
- **연결 비밀을 암호학적 난수 32바이트로**(이전: 시각 해시). 계정·수집 응답을 UTF-8 로 해독(한글 깨짐 방지).
- 초기화: rebuild 모드 수집(`rebuildRunId`)·목록 완료 표시·실패 전파, 병합은 T6 함수 하나로(source_generation 증가 — PC 와 같음).
- 크롤 로그 WS 에 `api_key` 를 붙인다(서버가 인증·게이트를 요구).
- 테스트: `integration_contract_test.dart`(event_decisions 10건, manifest 계약, 게이트 writer 규칙·비밀 난수), 실제 로컬 스택 `live_stack_test.dart`(선택 실행) 통과.
  전체 `flutter test` 502 passed / 3 skipped(골든 2 + 라이브 1, 라이브는 `COMMUNITY_STACK=1` 로 따로 1 passed), `flutter analyze` error 0 / warning 2(기존).

### 커뮤니티 필수 게이트·온보딩·초기화 (T5)

앱이 기존 권한 안내보다 먼저 `[필수] 카카오 인증` + `[필수] 신고내용 공유 동의` 를 요구한다(신규·기존 사용자 모두).
설계: `docs/architecture/community-gate.md`, 계약: `contracts/community-ingest/`(사본, 수정 없음).

- **게이트** (`lib/community/gate/`): `gate.md` 판정 순서 그대로(순수 함수 + 벡터 테스트),
  `community-account/status` (apikey + Bearer, 10초 타임아웃), 캐시 10분·`requireFresh(60s)`·`invalidate`,
  포그라운드 60초 poll + resume 즉시 refresh. Standalone 은 통과 때 `CommunityStore.setContext`,
  상실 때 `deactivateContext`. writer 연결 등록·rebind·takeover(409 `writer_conflict` → "이 기기로 업로드 전환"),
  연결 비밀은 `flutter_secure_storage` `community_connection_v1` 에만.
- **온보딩** (`community_onboarding_screen.dart`): 제목·설명·두 카드·동의문 전문 펼침(번들 사본
  `assets/community/share-consent-2026-09-26.1.md`, 계약과 sha256 동일)·체크 기본 해제·`동의하고 계속`
  성공 응답 뒤에만 완료·`다음` 조건부 활성·복구 화면·도움말/개인정보/로그아웃/종료 상시·건너뛰기 없음·Android back 종료.
- **진입 순서** (`main.dart`): 로딩 → 온보딩 → 권한 common → Setup → 권한 mode 보충(허용됨은 건너뜀)
  → 초기화(필요 시) → 메인. `ReportProvider.init()` 은 설정 로드만, 예약·drain·자동 동기화·WsService 는
  `onGatePassed()` 로 이동(1회). 알림 탭·payload·pending 변경은 게이트 미충족이면 무시, 딥링크는 게이트 중 수신.
- **권한** (`permission_service.dart`): Android 전용 항목 iOS 제외, MethodChannel 은
  `MissingPluginException`·`PlatformException` → "해당 없음", 확인 호출 5초 fail-closed.
  `PermissionScreen(phase: common|mode)`.
- **초기화** (`lib/community/rebuild/`, `community_rebuild_screen.dart`): `rebuild.md` 상태기계,
  `VACUUM INTO` 백업 + 무결성 검사, `SyncEngine.start(fullSync: true)` 실행(orphan 보존),
  영구 누락 수락·일시정지·같은 run 재개, 시작 전 manifest 확인, 진행 중 자동 동기화 차단.
  Client 는 서버 job 화면 + `GET /api/v1/community/gate` fingerprint 비교
  (`server_contract.dart` 경로·`X-Community-User-Token` 추가).
- **설정 카드**: 동의 상태·정책 버전·철회(`stale_grant` 재요청·`lineage_active:false` 확인 뒤 게이트 복귀),
  공유 자료 삭제 요청(확인 문구), 연결 기기 상태·전환.
- **iOS 복귀** (`Info.plist` CFBundleURLTypes 만 + `AppDelegate.swift`): Android 와 같은 채널·메서드명,
  cold start 보관(`getInitialLink`). Xcode 없어 빌드 미검증.
- T6 연결 자리 `lib/community/upload_hooks.dart` (기본값; `.agent-runs/T5/REQUESTS.md` 참고).

### 커뮤니티 데이터 경로 T6 (모바일 업로드)

Standalone 모드가 공식 상세 응답 순간의 값으로 공유 DTO 를 확정해 `community.db` 에
불변 저장하고, 그 사본만으로 실시간·수동·자정 업로드를 `community-ingest` 로 보낸다.
계약 정본 `contracts/community-ingest/`, 설계 `docs/architecture/community-upload.md`.

- capture(`lib/community/capture/`): 어댑터·DTO·정규 JSON·event 결정·한 트랜잭션 저장·
  재시도 파일·연속 3회 중단·manifest 교체·삭제 처리·reshare. 벡터 전부 통과
  (observations ·canonical-json ·schedule ·list_refetch).
- 수집 연결: `SyncEngine.start(fullSync, rebuildRunId)` — 상세 루프·단건이 같은
  capture+저장 함수를 쓰고, rebuild 는 부재 행 삭제 없이 orphan 수만 결과에 담는다.
  `replaceFromBackup`·`importFromServerDb` 전에 `rotateDataset` 호출.
- 업로드(`lib/community/upload/`): 게이트·lease·drain(≤20건·≤256KiB·같은 신고 하나)·
  오류 분기·durable ACK·upload_runs. Client 모드 전송 금지.
- 스케줄: 1시간 periodic + 다음 자정 one-off, dispatcher 분기, iOS plist 항목
  (실기기 미검증). 지도 탭 접이식 패널. 빌드 공개 설정 dart-define 주입 + 자리표시자 거부.
- T5 연결점·벡터 확인 요청: `.agent-runs/T6/REQUESTS.md`.

## 2026-09-25 (버전 변경 없음)

### 커뮤니티 계정 연결 (safeauth.worklazy.net)

커뮤니티 지도에 쓰는 **카카오 계정**(Supabase Auth)을 연결한다. 안전신문고 계정과 별개이고, 계정 연결만으로 신고 데이터가 업로드되지는 않는다.
설계·흐름·저장 키·보안 메모: `docs/architecture/community-account.md`.

- **Standalone (앱이 인증·세션 주인)**: 설정 > "커뮤니티 계정" 카드(설정되지 않음 / 연결 안 됨 / 브라우저 대기 / 계정 확인 / 연결됨 / 다시 로그인 필요).
  PKCE(S256)로 카카오 authorize 주소를 외부 브라우저에서 열고, `com.fentanest.mysafetyreport://auth/callback` 으로 돌아오면 코드 교환 →
  계정 확인 창("이 계정으로 연결"/"취소", 다른 계정이면 교체 경고) → 확인할 때만 세션을 `flutter_secure_storage` 에 저장. 취소·연결 해제는 `logout?scope=local`.
  세션 공급 `getAccessToken()`: 만료 60초 전 갱신, 동시 호출은 갱신 한 번, 회전된 access+refresh 함께 저장, 만료·철회는 "다시 로그인 필요", 네트워크 오류는 세션 유지.
- 중복 링크(onNewIntent·콜드 스타트 재전달·최근 앱 복원)에도 교환은 한 번(교환 전 대기 로그인 소비 + 소비 표시). 대기 로그인 없음·10분 지남·다른 scheme/host/path 는 무시.
- **Android**: MainActivity 에 복귀 intent-filter(VIEW/DEFAULT/BROWSABLE, path 정확히 일치)와 `flutter_deeplinking_enabled=false`.
  링크는 super 전에 꺼내 intent 에서 지우고 새 MethodChannel `com.fentanest.mysafetyreport/community_auth`(`takePendingLink`/`onCommunityAuthLink`)로만 넘긴다.
  Dart 핸들러는 `main()` 에서 등록해 SetupScreen 에서도 받는다. 기존 알림·바로가기 intent 라우팅은 그대로.
- **Client (서버가 인증·세션 주인)**: 서버가 `capabilities` 에 `community_account` 를 알리면 설정 > "서버 연결" 아래 "서버의 커뮤니티 계정" 카드.
  서버 API `/api/v1/community-auth/{status,start,confirm,cancel,disconnect}` 만 부르고 폰은 토큰을 받거나 저장하지 않는다. 1회용 연결 링크는 외부 브라우저로만 열고
  비교코드를 크게 보인다. 403 은 서버 관리자 화면 권한 안내, 404 는 "서버가 이 기능을 아직 지원하지 않습니다", 서버가 꺼져 있으면 오류만(Standalone 로그인으로 바꾸지 않음).
  pending/확인 대기일 때만 3초마다 상태 조회, POST 는 자동 재시도 없음.
- 모드 변경(`resetConfig`)은 Standalone 커뮤니티 세션·대기 로그인을 지운다(서버 계정은 건드리지 않음). SharedPreferences·SQLite 에는 아무것도 저장하지 않는다.
- 빌드 설정 `--dart-define=COMMUNITY_SUPABASE_URL=…`, `COMMUNITY_SUPABASE_PUBLISHABLE_KEY=…`(공개값). 없으면 "설정되지 않음". https 만(디버그에서만 127.0.0.1·10.0.2.2), `sb_secret_`·service_role 키 거부.
  Supabase Redirect URLs 에 `com.fentanest.mysafetyreport://auth/callback` 등록 필요. supabase_flutter 등 새 패키지는 추가하지 않았다(GoTrue v2.197.0 REST 계약 기준 좁은 어댑터).
- 테스트 추가: PKCE(RFC 7636 벡터)·복귀 링크 해석·설정 검사, 서비스(MockClient + 보안 저장소 mock: 중복 링크 1회 교환, 만료 무시, 보안 저장소에만 저장, scope=local,
  갱신 single-flight·회전 저장, invalid grant, resetConfig), Client 서비스(상태·오류 대응·오프라인), 두 카드 라이트/다크·글자 2.0배·320폭 + 전역 확인 창.
- 결과: flutter test 313 통과 / 2 skip(이전 218 / 2). flutter analyze error 0 / warning 2 / info 36(변화 없음). `flutter build apk --debug`(dart-define 없음) 성공, 병합 매니페스트에 복귀 필터·`flutter_deeplinking_enabled=false` 확인.
- 미검증: 실기기·에뮬레이터 복귀(콜드 스타트/onNewIntent), 실제 Supabase·카카오 로그인, 실서버 커뮤니티 API 연동, 백그라운드 isolate 갱신. iOS 미구현.

### 서버↔모바일 DB·로직 동등성 검수 반영 (G17, DB v15)

- 6Sol·Gemini 교차 검수와 같은 데이터로 양쪽 계산을 비교하는 새 검사(서버 `scripts/dev/logic_parity_check.py` + `test/tool/logic_parity_harness_test.dart`)에서 찾은 차이를 서버 규칙에 맞춤.
- 파서: 빈 주소면 다음 주소 후보로, `C_NOW` 소수 표기("10.0")를 0 으로 읽던 버그(`as num?` 형변환 예외를 삼킴).
- 저장: 본문 원문 종류 `report_body` 로 저장, 빈 원문이면 기존 유지(예전엔 삭제), 원문 종류 변경도 변경으로.
- 변경 알림: 신규·처리상태 변경만 알리던 것을 서버처럼 과태료·답변 등 추적 열 변경도 알림('변경'), payload 에 보완 사유·`synced_at`, 순서도 서버와 같게.
- DB v15: 옛 상태 보정이 NULL 행을 건너뛰던 것을 서버와 같게 다시 적용 + 옛 서버 DB 에서 들어온 차량번호(`*` 섞임) 복구.
- 통계 법규 선택지 범위, 옛 중복군 상태 변환, 재동기화 때 정리→중복군 재계산 순서를 서버와 같게.
- 결과: 서버↔모바일 왕복·계산 동등성 모두 fixture·운영 사본 차이 0. flutter test 217 통과.

### 다크 모드 B안 "딥 다크" — 서버 웹과 같은 배색 (G16 W5)

- 다크 바탕·표면·테두리를 채도 거의 없는 검정 계단으로(`#0b0b0c`/`#131314`/`#1b1b1c`/`#232324`/`#2d2d2f`). 예전 슬레이트(푸른 기) 대체.
- 글자·아이콘 강조 `#60a5fa`, 채움 버튼·선택 탭은 웹과 같은 `#2563eb` + 흰 글자(5.17:1). 보조 글자 `#9ea0a4`.
- 웹과 같은 값은 공용 `contracts/dark-palette.json` 으로 확인(`test/theme/dark_palette_contract_test.dart`). 대응표 `docs/design/dark-palette.md`. 다크 골든 2장 갱신.

### 별점 제출 검수(6Sol) 반영

- 별점 제출 POST 는 한 번만(내부 재시도 제거 — 응답만 끊겨도 중복 제출이 됐다). 제출 뒤 점수가 아직 안 보이면 다시 제출하지 않고 확인만 되풀이. 서버와 같음.
- 사이트가 이 신고·번호를 모르면 제출하지 않고 실패(서버와 같음).
- 만족도 팝업 사유의 HTML 엔터티를 서버와 같은 순서(해독 → 태그 제거 → 공백 제거)·범위(숫자 엔터티 포함)로. 공용 벡터 `popup_cases`.

### 레거시(웹) 크롤링 선택지 제거 (G16 W4)

- 서버가 레거시(Selenium HTML) 크롤링과 최소 크롤링(레거시 전용)을 없앴다. Client 크롤링 화면에서 "크롤링 방식" 표시와 "최소 크롤링"·"탐색 페이지 한도"를 없앴다. 예전 설정의 min 은 전체로 본다.
- `startCrawl` 은 `crawl_mode`·`queue_list` 만 보낸다(구서버는 `crawl_type` 기본값 api). 쓰이지 않던 `saveCrawlType` 삭제. 선택 신고 재크롤링은 full 로 보낸다.

### 비회원(수동) 로그인 제거 (G16 W3)

- Client 크롤링 화면에서 "로그인 모드"(회원/비회원) 선택과 "재개" 버튼을 없앴다. 서버도 비회원 모드를 없앴고 크롤링은 늘 회원 로그인으로 진행한다.
- `startCrawl` 이 `login_mode` 를 보내지 않는다(구서버는 기본값 회원). `resumeCrawl`·`crawlResumePath` 삭제.

### 별점 공통 사유 입력 (G16 W2)

- 별점 다이얼로그에 "공통 사유(선택)" 칸. 입력하면 선택한 모든 건에 같은 사유를 사이트 `STSFDG_CAUSE` 로 함께 보낸다(예전엔 늘 빈 값). 비우면 예전과 같다.
- 길이·공백 규칙은 서버와 같다(유니코드 코드포인트 1000자, 앞뒤 공백 제거, 줄바꿈 유지) — 공용 `contracts/rating-eligibility-vectors.json` 의 `cause_cases`.
- Standalone 성공 판정 강화: 제출 뒤 사이트에서 점수를 다시 읽어 보일 때만 성공으로 기록하고, 사이트가 돌려준 점수·사유를 저장한다(보낸 사유와 다르면 결과에 표시). 확인이 안 되면 최대 3회 다시 확인하고, 그래도 안 되면 실패. 서버와 같은 흐름.
- Client: 서버가 `app/config` 의 `capabilities` 에 `rating_cause` 를 알릴 때만 사유 칸을 보여 준다(구서버면 "서버를 업데이트하면…" 안내).
- 테스트 `test/services/rating_cause_test.dart`. flutter test 205 통과.

### 별점 대상 규칙 공용 벡터 (G16 W1)

- 서버가 목록·제출 모두 이 앱의 `RatingService.ineligibleReason` 규칙을 쓰도록 통일했다. 같은 판정은 두 레포 공용 `contracts/rating-eligibility-vectors.json` 으로 확인(`test/services/rating_eligibility_vectors_test.dart`). 앱 동작 변화 없음.
- Client: 서버가 사전 확인으로 거른 신고도 이제 `스킵: [SPP-…] 사유` 로 결과에 보인다(예전엔 "결과를 확인하지 못했습니다").

### 사진 촬영 시각을 서버와 같은 세 시점에 채움 + 6개월 기준일 말일 보정

- 서버와 동작을 맞춤: 동기화로 상세를 저장할 때 바로 읽고(주정차, 아직 없는 신고), 동기화가 끝날 때 못 읽은 것 30건 재시도, 앱을 열 때 남은 것 한 번 훑기. 예전엔 마지막 것만 했다.
- 6개월 기준일을 서버와 같게: 그 달에 없는 날이면 말일로(8월 31일 → 2월 28일, 예전 앱은 3월 3일). 첨부 가림과 사진 대상이 서버와 하루~사흘 어긋날 수 있었다.
- flutter test 198 통과.

### 업데이트 뒤 한 번 훑기 + 하단 진행 표시줄 (서버와 같은 기능)

- Standalone: 촬영 시각을 아직 못 읽은 주정차 신고(신고일 6개월 이내, 첨부 URL 만료 전)의 사진 앞부분만 받아 EXIF 촬영 시각을 채운다. 추정 과태료의 2시간 초과·밤샘주차 판정에 쓰인다. 앱을 열거나 동기화가 끝날 때마다 남은 것만, 0.4초 간격으로, 동기화 중이면 기다렸다 이어 간다.
- 탭 바 위에 한 줄 박스로 진행 상황(작업명 · 몇/몇 · 지금 신고번호)과 비스타풍 회전 링을 보여 준다. 끝나면 "완료"를 잠깐 보여 주고 사라진다. 지도 좌표 채우기 진행도 같은 줄에.
- Client: 서버가 같은 작업을 하므로 서버 진행 상태(`/api/v1/maintenance/status`)를 읽어 같은 박스로 보여 준다. 이 엔드포인트가 없는 구서버면 표시하지 않는다.
- EXIF 판독 규칙은 서버와 같은 합성 벡터(`contracts/exif-vectors.json`)로 양쪽 테스트. flutter test 194 통과.

### 서버·모바일 파서 통일(모바일 쪽) + DB v14

- 서버 레포와 같은 `contracts/parser-vectors.json`(합성 응답 13건) → `test/storage/parser_vectors_test.dart`. 고치기 전 앱 파서는 4건에서 틀리거나 멈췄다.
- 신고내용: 안내 문장("본 신고는 안전신문고 … 신고입니다")을 지우지 않고 서버와 같게(사용자 결정). 예전 앱이 지운 행은 DB v14 마이그레이션이 저장된 원문으로 되살림(그 행만, 네트워크 없음).
- 차량번호는 같은 줄 안에서만(`(위` 에서도 끊음), 발생일자 `.` `-` `/`, 본문이 빈 문자열이면 C_A_BODY 로, 값이 null 인 키는 없음으로, 보완 횟수(요청 번호 없이 완료만 있어도 1회), 본문 원문 저장은 서버와 같은 정규화.
- 동기화: 목록으로 받은 값으로 저장된 신고의 상태·신고명·신고일·만족도를 갱신(종결 신고도 나중에 매긴 별점이 반영, '참여 완료' 는 되돌리지 않음). 만족도 조회가 미참여를 확정하면 '참여 가능'으로 되돌리고 별점·사유를 지움(조회 실패와 구분).
- 테스트 176 통과, 서버↔앱 왕복 차이 0.

### 업데이트 전 자동 DB 백업

- 앱을 새 버전으로 올린 뒤 처음 DB 를 열 때, 구조를 바꾸기 전에 DB 파일을 `<db>.pre_v<옛 버전>.<시각>.bak` 로 복사해 둔다(최근 3개). 새 설치·이미 최신이면 건너뜀.
- 이전 버전 앱으로 되돌리면 새 DB 를 열 수 없다는 점과 되돌리는 방법을 `docs/architecture/data-contracts.md` 에 적음.
- 테스트: `test/storage/migration_test.dart`(옛 버전 그대로 복사, 한 번만, 개수 제한). flutter test 160 통과.

## 2026-09-24 (버전 변경 없음, 브랜치 `feature/storage-refactor`)

### 저장 계층 Gemini 교차 검토(G11) 반영

- 백업·복원이 DB 파일을 복사·교체하는 동안 다른 화면·자동 작업이 연결을 다시 열지 못하게 잠금(끝날 때까지 기다림).
- Standalone 알림 감지 큐도 백그라운드 서비스와 앱이 같은 키를 고쳐 쓰지 않도록 수신함 방식으로(감지한 신고번호 유실 방지).
- 테스트 143 통과, 디버그 빌드 성공. 검토 기록은 서버 레포 `docs/reviews/2026-09-24-gemini-g11-storage-review.md`.

### 저장 계층 재설계 R6 (동기화 중지, DB 연결 보호)

상태: 완료(테스트).

- 동기화 "중지"가 실제로 멈춤: 진행 중인 요청 하나가 끝나면 빠져나가고, 그때까지 새 동기화가 겹쳐 시작되지 않음. 중지된 동기화는 사라진 신고 정리·마지막 동기화 시각 기록을 하지 않음.
- 백업·복원·데모 전환·로그아웃이 DB 를 닫을 때 동기화·자동 동기화·지도 좌표 변환이 멈출 때까지 기다림(예전엔 진행 중 쓰기가 깨질 수 있었음). 작업 중 백업·복원·서버 DB 가져오기는 안내 메시지로 거절, 모드 전환 백업은 기다렸다 진행.
- 서버 DB 가져오기를 500행씩 묶어 저장(행마다 왕복하던 것). 안 쓰던 설정 사본(`standaloneSyncTime`) 삭제.
- 알림 기록·카드 시트 대기 변경: 백그라운드 서비스는 항목마다 새 키(수신함)에만 쓰고 앱이 합친 키만 지움 → 서비스와 앱이 동시에 써도 알림이 사라지지 않음.
- 데이터 수정에서 주소를 고치면 지도 좌표도 고친 주소 기준(좌표 캐시에서, 없으면 좌표 변환 대기 → 백필이 채움). 원본 좌표는 그대로.
- 테스트 141 통과, 서버↔모바일 왕복 차이 0.

### 저장 계층 재설계 R4·R5 (편집 표시, 알림 기록 보존)

상태: 완료(테스트 + 에뮬레이터 확인).

- 데이터 수정 시트: 고친 칸에 "수정됨" 배지, 사이트 원본값, 되돌리기 버튼(Standalone 은 로컬 수정값, Client 는 서버 `site_values`).
- `/crawl/results` 에 설치 식별자를 보내 기기별로 변경을 받음. 알림 기록·대기 변경은 저장 직전에 설정을 다시 읽어 백그라운드 서비스가 넣은 항목을 덮지 않음(M-29·31).
- 에뮬레이터(API 35) 데모 계정: 데모 DB 3건 표시, 편집 → 배지·원본·되돌리기 → 되돌린 뒤 원본만 남음 확인. 앞선 R2·R3 의 "에뮬레이터 확인 전"도 이것으로 해소.
- 테스트 135 통과.

### 저장 계층 재설계 R2·R3 (모바일 저장 경로)

상태: 완료(테스트). 에뮬레이터 확인 전.

- 서버 DB 가져오기는 원본(목록+상세)을 읽는다(서버 화면용 표를 원본으로 저장하면 되돌려 보낼 때 원본이 사라짐). 6개월 지난 첨부는 상세 화면에서 신고일 기준으로 가림.
- 신고 저장은 제자리 UPDATE(REPLACE 없음), 식별 정보 보존, 별점·사유는 조회 결과에 따라(사이트 값 우선, 실패 시 유지, '참여 완료' 되돌림 금지).
- 편집은 수정값 표(`report_override`)에, 화면은 보기 `reports_effective` 로 읽음 → 재조회가 편집을 되돌리지 않음.
- 전체 재동기화가 먼저 지우지 않음(감시목록·중복 판단·지오코딩 캐시·수정값 유지), 데모 계정은 별도 DB 파일, 감시목록 변경은 DB 최신 목록 기준 한 트랜잭션, 중복 판단 보존.
- DB v13(옛 상태 정규화 1회). 테스트 133 통과.

### 저장 계층 재설계 R0·R1 (서버 레포 계획 docs/plans/storage-refactor-plan.md)

상태: 완료(테스트). 화면 변화 없음, 에뮬레이터 확인 없음.

- R0: 저장 계약 파일·스키마 일치 테스트, 알려진 결함 고정 테스트, v9·v10 → 현재 업그레이드 테스트, 왕복 하네스가 임시 DB 를 지우도록 수정.
- R1: DB v12(수정값·중복 판단 표), 엄격한 열 추가 마이그레이션, 서버 DB 가져오기 규칙(NULL 유지·숫자 형 맞춤·감시목록 서버 표 기준·새 표 복사·읽기 오류 전파), 앱 백업 복원 교체 방식(종류·버전 확인, 임시 사본 검사, .bak 롤백).
- 테스트: 전체 flutter test 129 통과. 테스트가 /tmp 에 남기던 임시 폴더 정리.

## 2026-09-24 (버전 변경 없음, 브랜치 `feature/stats-estimate-photo`)

### DB v11: 주정차 사진 촬영 시각 3컬럼, 서버↔모바일 왕복 검사

상태: 완료(테스트). 에뮬레이터 확인 없음(화면 변화 없음).

- 서버가 추가한 `사진_첫촬영`·`사진_끝촬영`·`사진_촬영수` 를 `reports` 에 추가(v10→v11 마이그레이션, 새 DB 생성, 서버 DB 가져오기 대상 DB 모두 v11).
- `upsertReport` 가 REPLACE 로 행을 다시 쓰면서 모델에 없는 이 컬럼들을 지우던 문제를 막으려 기존 값을 이어받는다.
- 서버 레포 `scripts/dev/db_roundtrip_check.py` 용 하네스 `test/tool/db_roundtrip_harness_test.dart`(평소 skip). 양방향 차이 0, 일부러 넣은 손상 5종 모두 감지.
- 테스트: `test/services/photo_capture_columns_test.dart` 3건(재저장 보존 — 보존 코드를 빼면 실패 확인, 새 신고 NULL, v10→v11). 전체 flutter test 통과.

### 통계: 처분 미확인·처분 대상 아님·기타·미분류 분리, 추정 과태료 따로 표시

- 커밋 `4f714249`. 서버와 같은 `fine_estimate` 규칙·검사 벡터, 통계 화면에 확정/추정 금액과 분리 배지(구서버 응답이면 기존 표시).

## 2026-09-24 (버전 변경 없음, 브랜치 `docs/ui-renewal-bootstrap`)

### 앱 아이콘·로고를 서버와 같은 새 디자인으로

상태: 완료 (에뮬레이터 확인)

- 서버가 사용자 제공 파일로 파비콘·앱 아이콘(카메라)과 로고(방패+글자, 라이트/다크)를 바꾼 것에 맞췄다(서버 커밋 `cea0752`, `f442759`).
- 앱 아이콘: `assets/branding/app_icon.png`(서버 원본에서 투명 여백 제거) → `flutter_launcher_icons` 로 Android·iOS·웹·Windows·macOS 아이콘 재생성.
  Android 8+ 적응형 아이콘 추가(전경은 72dp 안전 영역, 배경 #0035B9) — 예전엔 적응형이 없어 흰 원 안에 작게 들어갔다. 설정 파일 키도 `flutter_launcher_icons:` 로 갱신, 원본 경로를 저장소 안으로.
- 알림 표시줄 아이콘 `ic_stat_logo`: 알아보기 어려운 PNG → 흰 카메라 실루엣 벡터.
- 첫 연결 화면(연결 방식 선택): 방패 아이콘+제목 글자 → 서버 로그인 화면과 같은 로고 이미지(테마에 따라 라이트/다크).
- README 맨 위 로고(`mysafetyreport-mobile.png`)도 새 아이콘으로(1.5MB → 314KB).
- 확인: 에뮬레이터에서 홈 화면 아이콘(원형 마스크), Android 12+ 시작 화면 아이콘, 첫 연결 화면 로고 라이트/다크.
  알림 표시줄 아이콘은 빌드(리소스 컴파일)만 확인 — 실제 알림 표시는 NOT_RUN. `flutter test` 121 passed, 골든 4 통과, analyze 기준선 유지.

### README 사용자용으로 새로 쓰기 + 실제 화면 예시 이미지

상태: 완료

- README 를 엔드유저 눈높이로 다시 썼다: 할 수 있는 것, 두 가지 사용 방식, 시작하기, 로그인 안내(재로그인 필요 vs 연결 실패), 화면 둘러보기, 방식별 기능 비교, 자주 묻는 질문, 버그 제보 위치(설정 맨 위 도움·문의).
  내부 용어(EncryptedSharedPreferences, canonical/raw 등)는 빼고 개발 문서는 AGENTS.md·docs/ 로 연결.
- 예시 이미지를 사용자 실데이터(사용자 허락, 가림 없음)로 새로 만들었다: `example.png`(라이트)·`example-dark.png`(다크, `<picture>` 로 GitHub 테마에 맞춰 표시),
  `docs/images/readme/screen-*.png` 6장(화면 둘러보기 표).
  - 촬영: 테스트 에뮬레이터 `sr_uitest_api35`, Client 모드, 로컬에서만 띄운 서버(`fef44d8` 코드, api/ws 라우터만, 실데이터 DB 사본, 테스트 API 키) — 실서버·운영 로그인 사용 안 함.
    상태표시줄은 데모 모드(9:41), 전국 신고현황은 공개 통계 API 로 1회 수집.
  - 합성: 둥근 모서리·얇은 테두리·그림자, 계단식 겹침, 투명 배경, 256색 팔레트 압축(합계 약 1.1MB, 기존 example.png 6MB).
  - 사용자 요청으로 대표 이미지 2·3번째(신고내역·신고 상세)와 갤러리의 같은 화면을 2026년 6월 신고(수용·과태료, 답변 완료)로 다시 찍었다.
    9월 신고는 대부분 처리중이라 결과가 보이지 않았다.
  - 원본 캡처와 촬영·합성 스크립트(`shoot_readme.py`, `compose_readme.py`, `ui.py`)는 `docs/images/readme/raw/` 에 두고 git 에서 제외(`.gitignore`) — 실데이터라 로컬 보관만.
    몇 장만 바꿀 때는 그 장만 다시 찍고 `python3 compose_readme.py ../../../..` 로 다시 합성하면 된다.

### 신고 상세 첨부 동영상: 탭해서 불러오기 → 자동으로 하나씩 불러오기

상태: 완료 (위젯 테스트 + 에뮬레이터 실데이터 확인)

- 사용자 피드백: 동영상은 알아서 불러와야 한다. 앞선 수정(`bff762f8`)은 스크롤 멈춤을 막으려고 탭해야 불러오게 했었다.
- 멈춤 원인 셋을 각각 막으면서 자동으로 불러오도록 바꿨다(`_VideoPlayer`):
  - 화면에 보이고 **스크롤이 멈췄을 때만** 시작(`isScrollingNotifier` + 뷰포트 겹침 확인). 스크롤 중엔 시작하지 않는다.
  - **한 번에 하나씩** 불러온다(`_VideoLoadQueue`, 응답 없는 동영상이 뒤를 막지 않게 30초 타임아웃).
  - 자리표시·로딩·오류·재생 모두 **같은 16:9 칸** — 로딩이 끝나도 높이가 바뀌지 않는다(세로 동영상은 좌우 여백). 자리표시를 누르면 즉시 불러온다.
- 테스트: `test/widgets/report_detail_video_test.dart` 를 새 동작으로 교체(가짜 컨트롤러로 스크롤 중 미시작·순차 로딩·높이 불변 확인).
- 에뮬레이터(실데이터 Client, 동영상 2개 신고): 동영상 위치에서 멈추면 자동 로드·재생 컨트롤 표시, 로딩 중 위로 스크롤 후 대기 → 스크롤 정상.
- `flutter analyze` error 0 / warning 2(기존) / info 36, `flutter test` 121 passed, 골든 4 통과.

### Standalone 자동 재로그인 정리 + 하루 1회 로그인 점검 + 스토어 별점 요청

상태: 완료 (단위·위젯 테스트, 에뮬레이터로 알림·백그라운드 실행 확인). 실제 안전신문고 로그인·Play 리뷰 창은 NOT_RUN

배경:
- 제보: Standalone 에서 동기화하려는데 "토큰 만료"가 떴다.
- 원인(코드): 자동 재로그인의 모든 실패(네트워크 끊김·점검·5xx 포함)를 "토큰 만료, 재로그인하세요"로 알렸다.
  또 앱 복귀 때 재로그인이 진행 중이면 `refreshSessionIfNeeded()` 가 기다리지 않고 돌아와, 뒤따르는 drain/동기화가 만료 토큰으로 시작해 로그인이 겹쳤다.
  (`allowBackup=false` 라 백업 복원으로 비밀번호가 깨지는 경우는 아님. 토큰은 1시간짜리라 하루 1회 미리 갱신은 의미 없음 — 사용자와 합의)
- 추가 발견: drain 중 인증 실패는 otherError 로 처리돼 **큐에서 지워졌다** → 그 신고를 영영 놓칠 수 있었다.

변경:
- `StandaloneAuthService`: `relogin()` single-flight, 결과 `success/noCredentials/rejected/transient`, 일시 오류 1회 재시도, 결과 기록(`standalone_auth_last_*`, `status` ValueNotifier).
  `login()` 은 `LoginRejectedException`(400/401, RSA 세션 오류 제외) / `AuthTemporarilyUnavailableException`(네트워크·점검·5xx·비정상 응답)을 던진다.
  `ensureValidToken()`·API 401 경로: 재로그인 필요 → `TokenExpiredException`, 일시 오류 → `AuthTemporarilyUnavailableException`.
- `SyncEngine`: 인증 예외는 메시지 그대로 올려 동기화를 멈춘다(상세 조회 루프의 중복 재로그인 제거). `StandaloneAutoSyncService`: 인증 실패 시 큐 보존.
- UI: 대시보드·동기화 화면 맨 위 '재로그인 필요' 경고(재로그인 필요할 때만, `재로그인` → 설정 재로그인 창 바로 열림), 설정 계정 카드 '마지막 로그인' 줄.
- 하루 1회 백그라운드 로그인 점검(`workmanager` 추가, `BackgroundLoginCheck`): 비밀번호 거부·로그인 정보 없음일 때만 알림(72시간에 1회), 일시 오류는 조용히.
  백그라운드 엔진엔 MainActivity 채널이 없어 Kotlin `SafetyReportApplication`(신규, 매니페스트 `android:name` 변경)이 `standalone_auth_alert` 키 변경을 듣고 알림.
- 스토어 별점(`in_app_review` 추가, `ReviewPromptService`): 구글 API 는 별점 여부를 알려 주지 않으므로 요청 횟수로 조절.
  최근 3일 안에 받은 수용·과태료·범칙금 결과 상세를 닫은 뒤, 설치 7일·사용한 날 5일 이상, 90일 간격, 평생 3회, 이번 실행 오류 없음, 데모 제외.
  만족도를 먼저 묻는 방식(구글 정책 위반)은 쓰지 않는다. 설정 도움·문의 카드에 'Play 스토어에서 평가하기'(조건 없음) 추가.

검증:
- 테스트 추가: `standalone_auth_relogin_test`(5), `background_login_check_test`(4), `review_prompt_service_test`(5), `auth_status_notice_test`(2). 실제 로그인 호출 없음(`loginOverride`).
- 에뮬레이터(`sr_uitest_api35`, 데모, 임시 검증 코드는 커밋 안 함): 알림 키 쓰기 → '🔐 안전신문고 재로그인 필요' 알림 표시, 주기 작업 등록(네트워크·배터리 조건, 6시간 지연) 확인,
  일회성 작업 강제 실행 → 백그라운드 엔진에서 점검 실행·`SUCCESS`(데모라 로그인 건너뜀). 설정 화면 평가 버튼 렌더 확인.
- `flutter analyze` error 0 / warning 2(기존) / info 36, `flutter test` 121 passed, 골든 4 통과.

### 설정: 버그 제보를 맨 위 '도움·문의' 카드로

상태: 완료 (에뮬레이터 화면 확인, 링크 열기는 실행 안 함)

- 제보: 사용자들이 버그 제보 위치를 모른다. 기존 버튼은 '앱 정보' 카드 맨 아래(비공식 고지 문단 뒤)에 있었다.
- 설정 맨 위(연결 방식 카드 바로 아래)에 `_SupportCard` 추가: '버그 제보하기'(강조 버튼) / '기능 요청' / '사용 가이드'.
- 버그 제보·기능 요청은 GitHub 새 이슈 화면을 양식으로 연다(`lib/services/support_links.dart`). 앱 버전·모드(Client/Standalone/데모)·OS 만 채우고,
  아이디·API 키·서버 주소·차량번호는 넣지 않는다. 카드와 양식에 "공개 게시판, GitHub 계정 필요, 개인정보 적지 말 것"을 적었다.
- '앱 정보' 카드의 버튼은 같은 동작의 '버그 제보하기'로 남겼다.
- 테스트: `test/services/support_links_test.dart` 2건.

### 신고 상세: 첨부 동영상은 탭해야 불러온다 (스크롤 멈춤 수정)

상태: 완료 (위젯 테스트 + 에뮬레이터 재현·확인)

- 제보: 상세 시트를 열고 아래로 내려 동영상 로딩이 걸린 뒤 위로 올라가는 도중 로딩이 끝나면 상하 스크롤이 멈춘다.
- 재현(`sr_uitest_api35`, Standalone 데모 `SPP-2604-2344496`, 동영상 3개): 시트를 열면 모든 동영상이 자동으로 `initialize` 되고,
  로딩이 끝나면 자리표시(160px)가 실제 비율 높이로 바뀌며 플레이어 여러 개가 동시에 버퍼링한다. 이 시점에 스와이프가 화면에 반영되지 않았고 프레임이 130~800ms 로 느려졌다.
  (에뮬레이터는 동영상이 없어도 프레임이 ~100ms 라 기기 수준의 정확한 기전은 확정하지 못함)
- 수정: `_VideoPlayer` 는 '탭하여 동영상 불러오기' 자리표시를 먼저 보여 주고, 탭했을 때만 컨트롤러를 만든다. 불러온 뒤에만 keep-alive.
  스크롤 중 로딩 완료가 생기지 않고, 시트를 열 때 동영상을 모두 내려받던 데이터 사용도 없어진다.
- 확인: 같은 시나리오에서 스크롤 정상·ExoPlayer 스레드 0개, 탭한 동영상만 로드·재생 컨트롤 표시, 로드 후 스크롤 정상.
  `test/widgets/report_detail_video_test.dart`(수정 전 코드에서는 실패함을 확인).

### 통계 기관/담당자 표 규칙 정리 (S-10) + 서버와 금액·반올림 일치 (S-11·S-12)

상태: 완료. 서버 레포 `feature/stats-overview-api` 커밋 `fef44d8` 과 짝

- 사용자 결정: 나중에 처리기관도 붙이고 이송 시 담당자가 나오므로, 표 포함은 처리상태가 아니라 처리기관·담당자 값으로 정한다. 배정된 처리중도 들어가고 따로 센다. 행 탭 drilldown 은 그대로.
- `LocalDbService.buildStatsCategory`(옛 `_buildCategory`, 테스트용 공개): 담당자표의 "담당자 없음 + 처리중/취하" 규칙 → "처리기관·담당자가 있어야 함(`미지정` 제외)".
  `_AgencyAgg` 에 `in_progress`(완료도 취하도 아닌 상태) 추가, `unconfirmed` 에서 뺌. 평균 처리일은 완료 신고만(요약 `summarizeOverviewRows` 도 동일).
- `AgencyStatRow.inProgress/inProgressPct`(구서버 null). 통계 행 카드에 '처리중' 배지·막대, '총 처리 N건' → '총 N건'.
- 서버도 같은 규칙으로 수정(`in_progress` 필드 추가, '알수없음' 행 폐지, 웹 표 처리중 컬럼). 대조 중 서버만 다른 두 가지도 서버를 모바일 쪽으로 맞춤:
  `과태료: 40.000원` 금액 읽기(S-11), 반올림 x.x5 올림(S-12).
- 검증:
  - `test/services/stats_tables_test.dart` 3건(서버와 같은 입력·기대값, 구서버 null 처리).
  - `local_db_service_regression_test` 의 "처리중 = 기타·미분류" 단언을 결정에 맞게 `unconfirmed 0 / inProgress 1` 로 바꿈(목적인 불수용 버킷 분리는 유지, 지도 분포는 그대로).
  - 5월 서버 DB 사본을 서버 새 코드와 Standalone import 양쪽에 넣어 기관·담당자 표 16개 필드·요약 평균 처리일 대조 → 전부 일치(임시 테스트·사본은 삭제).
  - `flutter analyze` error 0 / warning 2(기존) / info 36, `flutter test` 102 passed, 골든 4 통과. 에뮬레이터 확인 NOT_RUN.

### 다중 선택 중 뒤로가기 = 선택 취소

상태: 완료 (위젯 테스트), 에뮬레이터 확인 NOT_RUN

- 사용자 결정: 다중 선택 모드에서 안드로이드 뒤로가기는 선택을 취소해야 한다. 이전에는 `PopScope` 가 없어 앱이 나갔다(기존 동작).
- `lib/widgets/selection_back_scope.dart` 신설 → 신고내역(`report_list_screen.dart`)·별점 패널(`rating_management_panel.dart`)에 적용.
  선택이 없으면 원래대로(루트면 앱 종료, push 된 화면이면 닫기).
- 하단 탭은 `IndexedStack` 으로 살아 있어 숨은 탭의 선택이 다른 탭의 뒤로가기를 가로챌 수 있다 →
  `main.dart` 가 비활성 탭을 `TickerMode(enabled: false)` 로 감싸고, scope 는 활성 탭에서만 가로챈다(숨은 탭 애니메이션도 멈춘다).
- 신고내역 선택 AppBar X 버튼에 tooltip `선택 취소` 추가(액션 바와 같은 문구).
- 테스트: `test/widgets/selection_back_scope_test.dart` 4건(루트/ push / 숨은 탭 / 실제 ReportListScreen 길게 눌러 선택 → 뒤로가기).
- `flutter analyze` error 0 / warning 2(기존) / info 36, `flutter test` 99 passed, 골든 4 통과.

### Gemini 최종 검수(R2) 반영 — 분석기 경고 정리

상태: 완료

- Gemini R2(데모 데이터 전 화면 라이트/다크 38장 + c64be69a 이후 전체 diff): 신규 치명/중요 결함 없음, S-10(기존 발견) 재확인.
- R2 가 지적한 "analyze warning 11건"은 **사실**이었다. Opus 가 이전 항목에 "warning 0"으로 잘못 적었다(검사 명령 오류).
  G2 반영분의 unused import 5·duplicate import 1·unused local 3 을 제거 → error 0 / **warning 2(기존 setup_screen 그대로)** / info 36.
- `flutter test` 95 passed.

### 실데이터(Client) 검증에서 나온 보정

상태: 완료

배경: 실서버에서 DB 사본을 읽기 전용 API 로 받아, 새 서버 코드를 로컬(스케줄러·크롤링 없는 최소 API)로 띄우고
에뮬레이터 Client 모드로 라이트/다크 전 화면을 확인했다(실데이터 캡처는 레포에 넣지 않음).

변경:
- 테마: `secondaryContainer`/`tertiaryContainer`/`errorContainer` 를 명시 — 토널 버튼("파일 관리")이 원색 청록/시안으로 튀던 문제
- 글자에 쓰인 `textDisabled`(AA 미달) 6곳을 `textSecondary` 로(알림·동기화·선택 액션바)
- 통계 요약 각주: 취하 데이터 숨기기가 켜져 있으면 "취하 건 제외(대시보드 '전체'는 취하 포함)" 안내 — 실데이터에서
  대시보드 전체 3,054건 vs 통계 총 신고 2,941건(취하 113건 차이)이 설명 없이 달라 보이던 점
- `test/theme/theme_contrast_test.dart`: 컨테이너 색·SnackBar 대비 테스트 추가

### 하단 탭 5개 개편(D-06) + 전 화면 디자인 통일

상태: 완료 (사용자 결정: D-05 아이콘 유지, D-06 하단 5탭, D-07 알림 분리 안 함, D-08 배너 없음, D-09 썸네일 없음, 로그 패널 어두운 터미널 유지)

변경:
- 하단 탭 7 → 5(대시보드·신고내역·신고관리·통계·알림, 인덱스 0~4 유지). `lib/navigation/app_routes.dart` 신설
  - 동기화/크롤링: 대시보드 앱바 버튼(진행 중 회전) + 상태 카드(`lib/widgets/sync_status_card.dart`)
  - 파일: 설정 > 데이터 관리 > 파일 관리 (카드 제목 "데이터 관리")
  - 네이티브 딥링크 옛 인덱스 5·6 은 해당 화면을 연다(Kotlin 무변경). 런처 바로가기는 화면을 연 뒤 명령 전달
  - 설정 연결 방식 카드에 ModeBadge
- 디자인 통일: 알림·파일·동기화/크롤링·지도(주변 UI)·권한·설정 마법사·신고현황·신고관리 패널·최근 답변·필터 목록·
  상세/검색/선택/중복 시트·설정·통계·신고내역·검색·변경 결과 시트를 토큰/StatusBadge/StatusTone 으로
  - 성공/실패 SnackBar 는 AA 색(`srSnackSuccess`/`srSnackError`), 변경 종류 색은 `server_palette.dart` 상수로
  - 남긴 색: 토큰·팔레트 정의, 지도 마커(항상 밝은 타일 위), 동영상 오버레이, 터미널 로그 패널, StatusTone 입력 기준색
- 기존 버그 수정: 별점 패널 머리 '검색 $reports.length건' 문자열 보간 → 건수 표시
- 구현 위임: Gemini G1·G2(파일 분담 병렬) — 담당 파일만 반영, 범위 위반·허위 보고·다크 순위 배지 버그는 Opus 가 바로잡음(`docs/reviews/2026-09-24-gemini-bootstrap-review.md`)

검증:
- 에뮬레이터 E2E: 하단 탭 5개, 동기화 카드/앱바 → 동기화 화면, 딥링크 nav_tab 6/5/4, 런처 바로가기 quick_sync(데모 차단 안내),
  설정 > 파일 관리, 각 경로 뒤로가기 → 대시보드 — 전부 통과
  - 이 과정에서 바로가기가 동기화 화면을 두 번 쌓아 뒤로가기 1회에 빈 화면이 되던 문제를 발견·수정(동기 open 플래그)
- `flutter analyze` ~~error 0 / warning 0 / info 47~~ → **정정: 실제로는 warning 11 / info 36** (Opus 의 grep 필터가 줄 형식과 맞지 않아 경고를 놓쳤다. Gemini R2 가 지적, 아래 항목에서 수정), `flutter test` 91 passed

### 통계 의미 정정 S-01·S-03·S-04·S-05·S-08·S-09 (사용자 결정: 권고대로, S-08 은 답변일)

상태: 완료

변경:
- `local_db_service.dart`
  - S-01: 기관표 평균 처리일에서 날짜 역전(음수) 제외, 소수 1자리(서버와 동일)
  - S-03: 취하 제외 SQL 9곳 `IFNULL(처리상태,'') != '취하'` — 처리상태 NULL 행이 같이 사라지던 버그 수정(목록·요약·통계·지도·중복차량)
  - S-05: 행별 `fine_amount_unknown`(과태료인데 금액 미확인, 0원과 구분)
  - S-08: 통계·지도 연도 필터와 연도 목록을 답변일 기준으로(서버와 동일). 요약 `year_basis` = 답변일
- `statistics_screen.dart`: 행 drilldown 을 답변일 범위로(S-08, Client 기존 불일치 해소), 과태료 합계 옆 "금액 미확인 N건", 배지 "기타·미분류"(S-04)
- `dashboard_screen.dart`: 교통 처리 현황 "처분 미확인"(S-04)
- `models/agency_stats.dart`: `fineAmountUnknown`(구서버 응답은 0)
- 서버(`feature/stats-overview-api`): `/stats` 행에 `fine_amount_unknown`, 법규 필터 완전 일치(S-09)

검증: `test/services/stats_overview_test.dart` 에 기관표 정정 테스트 추가, 요약 연도 테스트를 답변일 기준으로 갱신 → 전체 통과. 서버 테스트 통과.
신규 발견 S-10(기관표 행 포함 규칙의 모드 차이)은 미변경 — statistics-spec 참조.

### UI 리뉴얼 시범 구현: 테마·신고 카드·대시보드·상단 탭·통계 요약

상태: 시범 범위 구현·테스트·에뮬레이터 실렌더 완료 / 커밋·배포 안 함 / 골든은 사용자 승인 대기 후보

사용자 결정: D-01 다크=슬레이트, D-02 상태색 모바일 먼저(웹은 별도), D-03 primary 통합+모드 별도 표시, D-04 기기 기본 글꼴,
S-02 평균 처리일 직접 계산(Standalone 로컬, Client 서버 API), Client 월별 추이=서버 신규 API, 과태료 월별 차트 없음.

변경:
- 테마: `lib/theme/sr_colors.dart`(토큰·`contrastRatio`·`StatusTone`), `lib/theme/app_theme.dart`. `main.dart` 는 공통 테마 사용(모드별 파랑/초록 primary 폐지). 앱바는 배경색
- `lib/server_palette.dart`: 토큰 상태색으로 교체. 흰 글자 채움은 8/10 상태가 AA 미달이라 배지·카드는 `StatusTone` 틴트로 그림
- 신규 위젯: `StatusBadge`, `ModeBadge`(대시보드 앱바), `SrTabBar`(신고내역·신고관리·알림 상단 탭), `StatsOverviewSection`
- `report_list_card.dart`: 긴 신고명·차량번호 overflow 수정(차량번호 칩 40% 상한+말줄임, 신고명 2줄). 표시 필드·콜백 동일
- `dashboard_screen.dart`: 토큰/틴트 색, 도넛 조각 흰 % 제거 → 범례에 비율, 중앙 총 N건. 하드코딩 색 0개
- 통계: `LocalDbService.computeStatsOverview`/`summarizeOverviewRows`(행 조회는 `_queryStatsRows` 로 분리, `computeStats` 동작 동일),
  `ApiService.getStatsOverview`(구서버 404 → 미지원 안내), `ServerContract.statsOverviewPath`, `models/stats_overview.dart`,
  통계 화면 기관표 위에 요약 카드+월별 추이(신고일/답변일 기준 분리)+기준 각주
- 앱바 안 `Colors.white` 제거: 통계 '지도' 버튼, 알림 '모두 읽음', 검색 '초기화'
- README 배지 색·통계 설명 갱신, 설계·통계·보존표·아키텍처 문서 갱신

테스트:
- `test/report_navigation_regression_test.dart`: 탭 고정 색 단언 → 실제 렌더 색의 AA 대비·선택 구분·표시선·탭 이동을 라이트/다크 검사
- 신규: `test/theme/theme_contrast_test.dart`, `test/widgets/report_list_card_test.dart`(360dp × 1.0/1.3/2.0 × 라이트/다크 overflow 0 + Guideline 3종),
  `test/widgets/stats_overview_section_test.dart`, `test/services/stats_overview_test.dart`(서버 테스트와 같은 입력·기대값),
  `test/golden/renewal_golden_test.dart`(`golden` 태그, 폰트 없으면 skip, `dart_test.yaml`), 공용 `test/support/ui_harness.dart`
- 옛 카드 코드로 돌려 overflow 테스트가 실제로 실패(79/109px)하는 것 확인 후 복구
- DB 테스트 두 파일이 병렬 실행 시 같은 sqflite 경로를 공유해 간헐 실패(Gemini R1 지적, 재현) → 파일별 임시 DB 경로로 수정, 전체 6회 연속 통과

검증:
- `flutter analyze`: error 0 / warning 2(기존 setup_screen) / info 65 (시작 baseline info 73)
- `flutter test`: 90 passed (6회 연속)
- 에뮬레이터 `sr_uitest_api35`(Android 15) debug APK, Standalone 데모 모드 라이트/다크 실렌더 → `docs/testing/renders/2026-09-24/`. 실렌더에서 통계 차트 y축 라벨 중복 발견·수정
- Gemini(agy) 독립 검수 R1: `docs/reviews/2026-09-24-gemini-bootstrap-review.md`

남은 것: Client 모드 실렌더(가짜 서버 fixture 필요), 범위 밖 화면 잔여 하드코딩 색, S-01·S-03~S-06·S-08·S-09 결정, 골든 기준 승인

### UI 리뉴얼 준비 1단계: 문서 체계화·도구 연결·기능/에셋 대조

상태: 문서·도구 연결 완료 / 앱 코드 무변경 / 시범 구현 미착수

변경:
- 루트 문서: `AGENTS.md`, `PROJECT_RULES.md`, `GEMINI.md` 추가. `CLAUDE.md` 를 `@AGENTS.md` `@PROJECT_RULES.md` import + Opus 역할로 교체
- 기존 `CLAUDE.md` 원문을 `docs/architecture/legacy-claude-reference.md` 에 바이트 동일 보관,
  본문을 `overview.md` / `android-runtime.md` / `data-contracts.md` 로 분할(원문 10~823행 누락 0줄 검사), 제목별 대응표 `docs/architecture/README.md`
- 코드 대조로 원문 정정 사항 기록(원문은 수정하지 않음): 신고관리 하위 탭 4개, SQLite version 10·보완 컬럼 7개,
  재시도 5회, 부팅 흐름 edge-to-edge 방식, 누락 파일 목록, 다크 테마 존재
- `docs/design/`: `ui-renewal-spec.md`(시각 정본·토큰 제안·결정 필요 D-01~09), `feature-matrix.csv`(기존 기능 158행 + 개선/제외/결정 14행),
  `asset-manifest.csv`(시안 14장 sha256·알파·사용 제한), `statistics-spec.md`(지표 정의·발견 이슈 S-01~07)
- `docs/testing/ui-test-plan.md`(환경 실측·baseline·fixture·디바이스 규칙), `docs/agent-dispatch-runbook.md`(agy 호출·권한 실측)
- `docs/reviews/2026-09-24-gemini-bootstrap-review.md` + 원문 응답/작업서 보관
- 프로젝트 스킬 3종 `.agents/skills/` 원문 + `.claude/skills/` 심볼릭 링크, agy 용 Dart MCP `.agents/mcp_config.json`
- `.gitignore`: `docs/design/reference/*.png`(시안 원본 ~20MB, 해시로 추적), `.agent-runs/`
- 로컬 전용(커밋 대상 아님): Flutter 공식 Claude 플러그인 `dart-flutter@dart-flutter` 1.0.5 를 local scope 로 설치,
  Android cmdline-tools 23.0 설치, SDK 라이선스 수락 실행, 테스트 전용 AVD `sr_uitest_api35` 생성·부팅 확인

발견(코드 미수정):
- `ReportListCard` 360dp·긴 차량번호에서 RenderFlex overflow(1.0배 48px, 2.0배 334px)
- `rating_management_panel.dart:138` `'검색 $reports.length건'` 문자열 보간 오류
- 중복차량 탭 선택 목록 구성 누락 가능성(`report_list_screen.dart:122-129`, 미검증)
- 통계: 평균 처리일 모드 간 계산 차이, 표본수 미노출, 취하 제외 SQL 의 NULL 처리, '미확인' 이중 정의, Client 통계 `dedupe` 미전달

검증:
- `flutter analyze` baseline: error 0 / warning 2 / info 73 (종료코드 1), `flutter test` 34 passed — 이번 변경은 앱 코드를 건드리지 않음
- Gemini(agy `gemini-3.1-pro-high`) 독립 검토 3건 실행, 수용/반박 기록

## 2026-08-16 (1.3.5+30)

### 신고 상세 시트 동영상 스크롤 재다운로드 수정

상태: 완료

배경:
- 신고 상세 시트에서 맨 아래 동영상까지 내려 재생 → 위로 올려 본문을 읽다가
  다시 내려오면 동영상이 처음부터 다시 버퍼링(재다운로드)된다는 보고
- 원인: 상세 시트 본문이 `ListView` 라서 뷰포트 + cacheExtent 밖으로 나간 자식의
  Element 가 파기됨 → `_VideoPlayerState.dispose()` 가 `VideoPlayerController` 를 dispose,
  다시 진입할 때 `initState → _initController()` 로 새 컨트롤러를 만들어 재버퍼링
- `ListView` 의 `addAutomaticKeepAlives` 기본값은 true 지만,
  `_VideoPlayerState` 가 `AutomaticKeepAliveClientMixin` 을 쓰지 않아 keep-alive 통지가 없었음

변경:
- `lib/widgets/report_detail_sheet.dart`
  - `_VideoPlayerState` 에 `AutomaticKeepAliveClientMixin` 적용 (`wantKeepAlive => true`,
    `build()` 최상단 `super.build(context)`)
  - `_VideoPlayer` 에 `super.key` 추가 + 호출부 두 곳(`첨부 동영상`, `첨부파일`)에
    URL 기반 `ValueKey` 부여 → 목록 순서가 바뀌어도 State 가 URL 에 고정
- 부수 효과: 동영상이 아닌 첨부파일(`otherFiles`)도 인라인 재생을 시도하므로
  스크롤할 때마다 반복되던 헛다운로드/실패 재시도가 함께 사라짐
- 시트를 닫으면 라우트가 사라지면서 기존대로 정상 dispose

검증:
- `flutter analyze lib/widgets/report_detail_sheet.dart` → 기존 `unnecessary_underscores`
  info 4건 외 신규 이슈 없음

## 2026-07-01

### Standalone 대량 신고 로드 OOM(sqflite DirectByteBuffer) 수정

상태: 완료

배경:
- 신고가 수천~수만 건 쌓인 기기에서 `java.lang.OutOfMemoryError`
  (`ByteBuffer.allocateDirect` → `StandardMethodCodec.encodeSuccessEnvelope`) 크래시 보고
- 원인: sqflite 가 쿼리 결과 전체를 **하나의 연속 DirectByteBuffer** 로 직렬화해
  MethodChannel 로 넘기는데, 리스트/요약 쿼리가 `reports` 테이블을 all-columns·무제한으로
  통짜 로드 → 단일 버퍼 할당 실패
- 실측(traffic 2,735건): `처리내용` 평균 508자로 압도적 1위지만 `신고내용`·`처리내용`은
  클라이언트 상세검색 대상이라 컬럼 제외는 불가 → 버퍼 분할이 정답

변경:
- `lib/services/local_db_service.dart`
  - `_queryReportsChunked()` 추가: `reports` 를 ID(PK) 기준 keyset 페이지네이션(1000건 단위)으로
    나눠 읽어 Dart 리스트로 누적 → per-query 버퍼를 작게 유지
  - `computeSummary`, `getReportsByCategory`, `getAllReports` 를 청크 로드로 전환
  - `getDuplicateVehicleReports` 는 `신고번호 DESC` 유니크 정렬을 유지하며 `LIMIT/OFFSET` 청크로 전환
  - 컬럼/검색/UI/상세 시트는 그대로 (동작 불변, 단일 대형 버퍼만 제거)

검증:
- keyset 페이지네이션이 전체 조회와 동일 집합 반환(4,321행, 필터별 무중복·무누락) 실측
- `dart analyze lib/services/local_db_service.dart` → No issues found

### 신고 지도 현재 위치(GPS) 표시

상태: 완료

변경:
- `lib/screens/report_map_screen.dart`
  - `geolocator` 로 현재 위치를 조회해 신고 지도에 현재 위치 마커 표시
  - 지도 진입 시 현재 위치로 카메라 이동, 우측 하단 현재 위치 버튼(`FloatingActionButton`)으로 재요청/재중심
  - 위치 서비스 꺼짐 / 권한 영구 거부 / 12초 타임아웃 시 `getLastKnownPosition` fallback + 안내 SnackBar
  - 신고 포인트가 없어도 현재 위치만으로 지도를 그리도록 빈 마커일 때 클러스터 레이어 가드
- `lib/services/permission_service.dart`
  - 위치 권한 확인/요청/설정 이동을 `geolocator` 스택으로 통일 (permission_handler 이중 요청 제거)
- `lib/screens/permission_screen.dart`
  - 위치를 선택 권한으로 분리해 `_allGranted`(필수 판정)과 일괄 허용에서 제외
  - 위치는 지도 진입/현재 위치 버튼에서 실사용 맥락으로만 요청 (온보딩 이중 프롬프트 제거)
- `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`
  - `ACCESS_FINE/COARSE_LOCATION`, `NSLocationWhenInUseUsageDescription` 추가
- `pubspec.yaml` / `pubspec.lock`, macos/windows 플러그인 등록부
  - `geolocator ^14.0.2` 의존성 추가 및 자동 생성 등록부 반영

검증:
- 변경 파일 참조 정리: `report_map_screen.dart`에 `permission_handler`/`PermissionStatus` 잔여 참조 없음, `permission_service.dart`는 알림/배터리 권한에만 `permission_handler` 유지
- geolocator API 심볼 존재 확인 (`geolocator_platform_interface 4.2.8`): `LocationPermission.{always,whileInUse,deniedForever}`, `checkPermission/requestPermission/openAppSettings/getCurrentPosition/getLastKnownPosition/isLocationServiceEnabled`
- (로컬 `dart analyze`는 이 환경에서 응답 지연으로 완료하지 못함)

### 빌드 스크립트 JAVA_HOME 자동 설정 (self-hosted CI Java 미탐색 수정)

상태: 완료

배경:
- self-hosted GitHub Actions 러너는 대화형 셸 PATH 를 물려받지 못해 `flutter build apk`
  단계에서 `JAVA_HOME is not set and no 'java' command could be found` 로 gradle 실패

변경:
- `build_android_common.sh`
  - `ensure_java_available()` 추가: 유효한 `JAVA_HOME` 이 있으면 존중, 없으면 Android Studio
    번들 JBR → 시스템 JDK 17 → 21 순으로 탐색해 `JAVA_HOME`/`PATH` 설정
- `build_android_release.sh`, `build_test_apk.sh`
  - `ensure_flutter_available` 직후 `ensure_java_available` 호출

검증:
- `bash -n` 구문 검사 통과
- 최소 PATH(`env -i PATH=/usr/bin:/bin`) 환경에서 `JAVA_HOME` 이 JBR(JDK 21)로 설정됨 확인

## 2026-05-23

### Client 첫 실행 서버 응답 지연 완화

상태: 완료

변경:
- `lib/main.dart`
  - 메인 하단 탭을 eager build 하던 `IndexedStack` 구조를 lazy build 캐시 방식으로 변경
  - 첫 실행에 보이지 않는 탭까지 동시에 네트워크를 시작하던 패턴을 줄임
- `lib/screens/dashboard_screen.dart`
  - 대시보드 첫 진입 시 `summary`를 먼저 로드하고, 카테고리 preload는 이후 백그라운드로 넘기도록 순서 조정
- `lib/screens/report_list_screen.dart`
  - 첫 빌드에서 교통/주정차/기타/중복 목록을 무조건 재요청하던 흐름을 `ensureCategoryReportsLoaded()` 중심으로 완화
- `lib/providers/report_provider.dart`
  - summary / 카테고리 목록 / 중복 목록 / 감시목록 / 앱 설정 로드에 in-flight dedupe 추가
  - 같은 요청이 이미 진행 중이면 기존 Future를 재사용해 중복 API 호출을 막도록 정리
- `docs/reviews/2026-05-23-client-startup-timeout-analysis.md`
  - 서버 레포와 대조한 원인 분석 및 수정 근거 문서 추가

분석:
- 서버 `../safetyreport/web/routers/api_route.py` 의 `/api/v1/summary`, `/api/v1/reports/{category}` 는 얇은 래퍼이며 첫 호출 전용 지연 로직은 없음
- 이번 증상은 서버 단일 API 오류보다 모바일 Client 의 초기 요청 폭주와 중복 호출 구조에 더 가깝다고 판단

검증:
- `dart analyze lib/providers/report_provider.dart lib/main.dart lib/screens/dashboard_screen.dart lib/screens/report_list_screen.dart`
  - 새 error / warning 없음, 기존 info 레벨 lint 만 잔존

### 다크 모드 상세 가독성 + 선택 모드 일괄 선택 정리

상태: 완료

변경:
- `lib/widgets/report_detail_sheet.dart`
  - 다크 모드에서 `신고내용`, `처리내용` 같은 멀티라인 텍스트 박스가 밝은 배경과 옅은 글자로 보여 가독성이 떨어지던 문제 수정
  - 상세 시트의 본문 박스, 안내 박스, 드래그 핸들을 테마 기반 색상(`surfaceContainerLow`, `onSurface`, `outlineVariant`)으로 전환
- `lib/screens/report_list_screen.dart`, `lib/screens/rating_management_panel.dart`
  - 선택 모드 진입 시 우측 상단에 `일괄 선택` 버튼 추가
  - 이미 전부 선택된 경우 버튼을 비활성화해 중복 액션을 줄이고, `신고 내역`과 `신고관리 > 별점` 화면의 선택 동작 위치/문구를 통일

검증:
- `dart analyze lib/widgets/report_detail_sheet.dart lib/screens/report_list_screen.dart lib/screens/rating_management_panel.dart`
  - 새 error / warning 없음, 기존 info 레벨 lint 만 잔존

### 신고관리 별점 탭 추가 + 서버 기준 별점 대상 정렬

상태: 완료

변경:
- `VERSION`
  - 앱 버전을 `1.3.2+27` 로 갱신
- `lib/screens/report_management_screen.dart`, `lib/screens/rating_management_panel.dart`, `lib/screens/dashboard_screen.dart`
  - 신고관리 첫 탭에 `별점` 패널 추가
  - 교통/주정차/기타 전체 카테고리에서 별점 대상 신고를 한 화면에 모아 보고, 기존 카드/상세시트/다중선택 액션 바로 별점 주기를 실행할 수 있게 연결
  - 감시 목록 섹션의 `관리` / `더 보기` 진입 인덱스를 새 탭 순서에 맞게 보정
- `lib/services/rating_service.dart`, `lib/providers/report_provider.dart`
  - 모바일 별점 대상 목록 기준을 서버 `get_unrated_records` 와 맞추도록 조정
  - `만족도조사여부` 가 `참여 완료/참여 불가` 가 아닌 신고 중, `취하/답변 대기/처리중(진행/진행중/검토중 포함)` 만 제외하도록 정리
  - 별점 탭 전용 집계/정렬 경로 추가
- `lib/widgets/search_filter_sheet.dart`
  - 별점 탭에서 결과를 구조적으로 0건으로 만드는 `별점/별점사유/만족도 조사 여부` 필터를 숨기고, 기존 전역 필터에 남아 있어도 별점 탭 결과에는 영향이 없도록 분리
- `lib/screens/rating_management_panel.dart`
  - 새로고침/동기화 후 목록에서 빠진 신고가 기존 선택 집합에 남아 있을 때 자동으로 정리되도록 stale selection 보정 추가
- `test/services/rating_service_test.dart`
  - 서버 parity 기준 회귀 테스트 추가
  - `pollStatus == ''` 허용, `참여 완료` 제외, `검토중` 제외, `답변 대기 + 답변완료` 허용 시나리오 확인
- `docs/reviews/2026-05-23-rating-management-review.md`
  - 별점 관리 탭 1차 리뷰 및 후속 정리 근거 문서 추가

검증:
- `dart analyze lib/services/rating_service.dart lib/providers/report_provider.dart lib/widgets/search_filter_sheet.dart lib/screens/rating_management_panel.dart test/services/rating_service_test.dart`
- `flutter test test/services/rating_service_test.dart`

## 2026-05-20

### 신고 결과 알림 읽음 상태 통합 + 지도 상단 요약 1줄 정리

상태: 완료

변경:
- `lib/providers/notification_history_provider.dart`, `lib/main.dart`, `lib/widgets/report_detail_sheet.dart`
  - 일반 신고 결과 알림의 읽음 상태를 알림 `id` 가 아니라 정규화된 `신고번호` 기준으로 묶음
  - 푸시 알림, 앱 하단 검은 SnackBar 알림, `신고 결과` 탭 목록이 모두 같은 `report_detail` 진입 시 같은 읽음 상태를 공유하도록 정리
  - 이미 읽은 신고번호는 foreground SnackBar 와 `pending_crawl_changes` 카드 시트에서 다시 띄우지 않도록 중복 노출 억제
- `lib/screens/report_map_screen.dart`
  - 지도 상단 `전체 / 좌표화 / 미변환 / 처리기관` 요약을 개별 박스 `Wrap` 대신 단일 요약 패널로 재구성
  - 좁은 해상도에서도 두 줄로 내려가지 않도록 `Row + FittedBox` 기반으로 정리

검증:
- `dart format lib/providers/notification_history_provider.dart lib/widgets/report_detail_sheet.dart lib/main.dart lib/screens/report_map_screen.dart`
- `flutter analyze lib/providers/notification_history_provider.dart lib/widgets/report_detail_sheet.dart lib/main.dart lib/screens/report_map_screen.dart --no-fatal-infos`
  - 새 error / warning 없음, 기존 info 레벨 lint 만 잔존

### 설정 화면 앱 테마 추가 + Android 15 edge-to-edge / cutout 후속 정리

상태: 완료

변경:
- `lib/models/app_theme_mode.dart`, `lib/services/app_prefs_keys.dart`, `lib/providers/report_provider.dart`
  - 앱 전역 테마 설정용 `system / light / dark` 모드를 추가하고 `SharedPreferences` 에 영속화
  - 앱 재실행 후에도 사용자가 직접 고른 테마가 유지되도록 `ReportProvider.init()` 경로에 로드/저장 연결
- `lib/main.dart`
  - light/dark `ThemeData` 를 정식으로 분리 재구성
  - dark surface / card / dialog / input / navigation bar / bottom sheet / button 스타일을 한 번에 맞추고 `MaterialApp.themeMode` 에 사용자 설정을 연결
  - 앱 시작 시 `SystemUiMode.edgeToEdge` 를 유지하면서 상태바/내비게이션바 아이콘 대비만 조정
- `lib/screens/settings_screen.dart`
  - 설정 상단에 `화면 테마` 카드 추가
  - `시스템 설정 사용 / 라이트 모드 / 다크 모드` 를 앱 내에서 직접 선택 가능
  - 설정 화면의 안내 문구, 정보 박스, 상태 배지, 결과 박스 색상을 테마 기반으로 바꿔 다크 모드 가독성을 정리
- `lib/widgets/report_detail_sheet.dart`
  - 전체화면 동영상 페이지에서 `SystemUiMode.immersiveSticky` 사용을 제거하고 `edgeToEdge` 로 통일
  - Android 15+ 의 `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES` 관련 Play Console deprecated 경고를 유발할 가능성이 큰 경로를 앱 코드에서 제거
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - `enableEdgeToEdge()` 대신 `WindowCompat.setDecorFitsSystemWindows(window, false)` 를 `super.onCreate()` 전에 적용
  - AndroidX edge-to-edge 백포트가 release AAB 에 남기던 `setStatusBarColor` / `setNavigationBarColor` 계열 deprecated 경로를 앱 코드에서 더 줄이고,
    이후 시스템 바 아이콘 대비는 기존처럼 `WindowInsetsControllerCompat` 로만 조정
- `android/app/build.gradle.kts`, `android/app/proguard-rules.pro`
  - release R8 단계에서 Android 15 deprecated system bar color API 호출을 no-op 처리하는 규칙 추가
  - Flutter embedding / 라이브러리가 남기던 `setStatusBarColor` / `setNavigationBarColor` / `setNavigationBarDividerColor` 참조까지
    release 산출물에서 제거되도록 보강

검증:
- `flutter test`
- `flutter analyze lib/main.dart lib/screens/settings_screen.dart lib/widgets/report_detail_sheet.dart lib/providers/report_provider.dart lib/models/app_theme_mode.dart --no-fatal-infos`
  - 새 error / warning 없음, 기존 info 레벨 lint 만 잔존
- `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 ./gradlew :app:stripReleaseDebugSymbols --stacktrace --info`
  - 성공
- `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 ./gradlew :app:bundleRelease -q`
  - release AAB 생성 확인
- release AAB `classes.dex` 재점검
  - AndroidX `EdgeToEdgeApi23/26/29` 쪽 deprecated 호출은 더 이상 보이지 않음
  - `setStatusBarColor` / `setNavigationBarColor` / `setNavigationBarDividerColor` / `SHORT_EDGES` 는 raw dex 문자열과 `dexdump` 기준 모두 매치 없음
  - AAB manifest 쪽 `windowLayoutInDisplayCutoutMode` / `cutout` / `SHORT_EDGES` 도 매치 없음

### 신고 내역 탭 현재 건수 / 검색 결과 건수 표시

상태: 완료

변경:
- `lib/screens/report_list_screen.dart`
  - 신고 내역 AppBar 우측 검색/필터 아이콘 옆에 현재 탭에서 실제로 보이는 리스트 건수를 표시
  - 검색/필터가 없을 때는 `12건`, 검색/필터가 적용된 상태에서는 `검색 12건` 형식으로 표시
  - 교통/주정차/기타/중복차량 탭 전환 시 현재 탭 기준 건수가 즉시 갱신되도록 `TabController` 변경도 화면에 반영

검증:
- `flutter analyze lib/screens/report_list_screen.dart`

### Standalone 지오코딩 queued 대기 + 다음 실행 자동 재시도

상태: 완료

변경:
- `lib/services/local_geocode_service.dart`, `lib/providers/report_provider.dart`
  - Standalone 지도 백필 진행률에 `queued` 상태를 추가
  - `SyncEngine` 또는 `StandaloneAutoSyncService` 가 동작 중이면 지오코딩 백필을 즉시 돌리지 않고 대기 상태로 전환
  - `refreshAll()` 끝에서 저장된 카카오 REST API 키 기준으로 queued/pending/error 지오코딩을 자동 재시도하도록 연결
- `lib/screens/report_map_screen.dart`, `lib/models/report_map.dart`
  - Client/Standalone 공통 지도 UI가 `queued` 상태를 인식하고 진행 카드/빈 상태 문구/polling 을 계속 유지하도록 수정
  - 서버가 `queued` 진행률을 내려주는 경우에도 모바일 Client 화면이 정상적으로 대기 상태를 표시
- `lib/services/local_db_service.dart`, `lib/screens/setup_screen.dart`, `lib/screens/crawl_screen.dart`
  - 서버 DB import 와 모바일 백업 복원 시 stale `map_backfill_state` 를 버리고, 모드 전환 import 직후와 standalone sync 완료 직후 `refreshAll()` 을 다시 태워 백필을 재개
- `test/services/local_db_service_regression_test.dart`
  - stale `map_backfill_state` 제거, stored key 기반 다음 실행 재시도, queued 흐름 회귀 테스트 추가

검증:
- `flutter test test/services/local_db_service_regression_test.dart test/services/pending_db_import_action_test.dart`
- `flutter analyze lib/services/local_geocode_service.dart lib/models/report_map.dart lib/providers/report_provider.dart lib/services/local_db_service.dart lib/screens/report_map_screen.dart lib/screens/setup_screen.dart lib/screens/crawl_screen.dart`
  - 새 오류 없음, 기존 deprecation/unused 경고만 잔존

## 2026-05-18

### 신고 지도 지점 색상 구분 + 주소별 신고 내역 바로가기

상태: 완료

변경:
- `lib/screens/report_map_screen.dart`, `lib/models/report_map.dart`
  - 지도 최종 지점 원형 마커 색상을 `과태료` 처분 비중에 따라 구분
  - 과태료 비중 `60% 이상`은 초록, `50% 이상`은 주황, `50% 미만`은 빨강으로 표시
  - 지점 상세 바텀시트 아래 `리스트 보기` 버튼을 추가
  - `리스트 보기`를 누르면 주소 필터가 적용된 `신고 내역` 화면으로 이동하고, 전체 지도에서 들어간 경우 해당 주소의 주된 카테고리 탭으로 먼저 진입

검증:
- `flutter test test/services/local_db_service_regression_test.dart`
- `flutter analyze lib/models/report_map.dart lib/screens/report_map_screen.dart`
  - 새 오류 없음, 기존 `withOpacity` info만 잔존

## 2026-05-17

### 신고 지도 화면, 좌표 백필, 서버/Standalone 지도 연동 추가

상태: 완료

변경:
- `lib/screens/statistics_screen.dart`, `lib/screens/report_map_screen.dart`
  - 통계 탭 우측 상단에 설정 아이콘을 유지하고, 그 왼쪽에 `지도` 진입 버튼 추가
  - 모바일 전용 신고 지도 화면 추가. 클러스터/개별 원 탭 시 바텀시트로 행정구역, 기관, 처리상태, 처분 비중 표시
- `lib/services/api_service.dart`, `lib/services/server_contract.dart`, `lib/models/report_map.dart`
  - client 모드에서 서버 `/api/v1/stats/map` 및 진행률 API 를 읽어 지도 payload 와 백필 진행률을 사용
- `lib/services/local_db_service.dart`, `lib/services/local_geocode_service.dart`, `lib/services/geocode_utils.dart`
  - standalone `reports` 테이블에 `주소정규화`, `행정구역`, `위도`, `경도`, `지오코딩상태` 컬럼 추가
  - `geocode_cache` 테이블과 주소 정규화 헬퍼 추가
  - 지도 첫 진입 시 누락 좌표만 백그라운드 백필하고 진행률을 화면에 노출
- `lib/screens/settings_screen.dart`, `lib/services/app_prefs_keys.dart`
  - standalone 설정에 Kakao REST API 키 입력란 추가

검증:
- `flutter test`
- `flutter analyze lib/models/report_map.dart lib/services/local_db_service.dart test/services/local_db_service_regression_test.dart`

### DB import/export 좌표 보존 + 대시보드/지도 안정화

상태: 완료

변경:
- `lib/services/local_db_service.dart`
  - `importFromServerDb()` 를 staging DB 기반으로 재구성하고, 서버 DB 필수 테이블/컬럼을 사전 검증
  - 서버→모바일 import 시 geocode cache, duplicate projection, sync meta, 좌표/행정구역/지오코딩상태를 함께 보존
  - 모바일 DB 교체 실패 시 기존 backup 으로 복구를 시도하고, 복구 실패 시 backup 경로를 포함한 에러를 유지
  - 감시목록 변경 시 projection cache 를 무효화하고 cache key 에 `감시목록` 상태를 반영
- `lib/models/report.dart`, `lib/providers/report_provider.dart`, `lib/screens/dashboard_screen.dart`
  - `취하 데이터 숨기기` 옵션이 켜져 있어도 취하 카드에는 실제 건수를 유지하고, 그래프 반영용 값만 분리
- `lib/models/report_map.dart`
  - 사용하지 않는 `top_agency` 필드 제거

검증:
- `flutter test`
  - standalone watchlist projection cache 회귀 테스트 추가
  - invalid server DB import 실패 시 기존 standalone data 보존 테스트 추가

### 구조 정리와 테스트 보강

상태: 완료

변경:
- `pubspec.yaml`, `pubspec.lock`
  - `sqflite_common_ffi` dev dependency 추가
- `test/services/local_db_service_regression_test.dart`
  - standalone DB 기반 회귀 테스트 추가
  - watchlist cache invalidation, import preserve 시나리오 자동화

### 지도 경고 상태 세분화 + 모드별 앱 아이콘 퀵 메뉴

상태: 완료

변경:
- `lib/services/local_geocode_service.dart`, `lib/models/report_map.dart`, `lib/screens/report_map_screen.dart`
  - standalone 지도에서 카카오 REST API 키가 한 번 등록돼 일부 좌표가 저장된 뒤 키가 제거되면, 기존 `reports` 좌표와 `geocode_cache` 로 채울 수 있는 신고는 계속 지도에 표시
  - DB/캐시에 없는 새 주소만 더 이상 좌표 변환을 못 하는 경우 `config_warning` 상태와 별도 경고 문구를 노출
  - 처음부터 키가 없어 지도가 비활성화된 `config_required` 와, 저장 좌표는 계속 쓰되 신규 변환만 막히는 `config_warning` 을 분리
- `lib/models/agency_stats.dart`, `lib/services/local_db_service.dart`, `lib/screens/statistics_screen.dart`, `lib/screens/report_map_screen.dart`
  - 모바일 통계/지도 처분 현황에서 `불수용/기타` 묶음은 유지하고, `미확인` 을 별도 bucket 으로 분리
  - 지도 요약 상단의 `지점` 표기를 `처리기관` 으로 교체하고 서버 지도 meta 와 같은 기준을 따르도록 정리
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`, `ios/Runner/SceneDelegate.swift`, `lib/main.dart`, `lib/screens/crawl_screen.dart`
  - 앱 아이콘 꾹 누르기 퀵 메뉴 추가
  - standalone 구성 완료 시 `동기화`, client/server 구성 완료 시 `크롤링` 단일 shortcut 을 동적으로 노출
  - shortcut 진입 시 크롤링/동기화 탭으로 이동한 뒤 해당 동작을 즉시 시도
- `test/services/local_db_service_regression_test.dart`
  - API 키 제거 후에도 저장 좌표/캐시 기반 지도 표시가 유지되고, 새 주소가 남으면 경고 상태로 전환되는 회귀 테스트 추가

검증:
- `flutter test`
- `flutter analyze lib/models/report_map.dart lib/screens/report_map_screen.dart lib/services/local_geocode_service.dart test/services/local_db_service_regression_test.dart`
- `flutter analyze lib/main.dart lib/screens/crawl_screen.dart`

### 신고 지도 미변환 주소 시트 + 지도 안정화 후속 조정

상태: 완료

변경:
- `lib/screens/statistics_screen.dart`, `lib/screens/report_map_screen.dart`
  - `통계 -> 지도` 진입 시 기본 카테고리를 `교통`이 아니라 `전체`로 열도록 변경
  - 신고 지도 상단 `새로고침` 옆에 `미변환 주소 보기` 아이콘 추가
  - 아이콘 탭 시 주소별 미변환 신고 그룹을 바텀시트로 열고, 내부 신고는 `ReportListCard` 카드 형태로 나열
- `lib/services/local_db_service.dart`, `lib/services/api_service.dart`, `lib/services/server_contract.dart`, `lib/models/report_map.dart`
  - standalone 에서 로컬 DB 기준 `미변환 주소 그룹` payload 생성 추가
  - client 에서 서버 `/api/v1/stats/map/missing` 를 읽어 같은 시트를 구성하도록 연동
  - 주소 그룹별 `report_count` 와 신고 리스트 모델 추가
- `lib/services/geocode_utils.dart`, `lib/models/report_map.dart`, `lib/screens/report_map_screen.dart`
  - `NaN/Infinity` 좌표를 파서/모델/화면에서 모두 걸러 지도 확대 중 `LatLng is not finite` 예외가 나지 않도록 보강
  - 회전 제스처는 비활성화한 상태를 유지
- `test/services/local_db_service_regression_test.dart`
  - `NaN` 좌표가 지도 payload 에서 제외되는지, 미변환 주소가 주소별 그룹으로 묶이는지 회귀 테스트 추가

검증:
- `flutter test test/services/local_db_service_regression_test.dart`
- `flutter analyze lib/models/report_map.dart lib/services/api_service.dart lib/services/local_db_service.dart lib/services/server_contract.dart lib/screens/report_map_screen.dart lib/screens/statistics_screen.dart test/services/local_db_service_regression_test.dart`

## 2026-05-13

### Android 15 더 넓은 화면 권장조치 1차 대응 + Play Console 잔여 경고 원인 분리

상태: 완료

변경:
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - `enableEdgeToEdge()` 를 `super.onCreate()` 전에 호출해 AndroidX 공식 edge-to-edge 진입 순서로 정리.
  - 이후에는 `WindowInsetsControllerCompat` 로 status/navigation icon appearance 만 조정하고, 수동 시스템 바 색상 설정 경로는 두지 않음.
- `lib/main.dart`
  - 앱 시작 시 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)` 를 명시.
  - light/dark `AppBarTheme.systemOverlayStyle` 를 직접 지정해 상태바 아이콘 밝기만 넘기고 `statusBarColor` 는 보내지 않도록 정리.

조사 결과:
- release APK 기준으로 앱 리소스/테마 쪽 `windowLayoutInDisplayCutoutMode` 문자열은 남지 않음을 확인.
- 하지만 APK 내부 DEX 에는 여전히 `setStatusBarColor`, `setNavigationBarColor`, `setNavigationBarDividerColor` 가 남아 있었고,
  Play Console 이 지목한 obfuscated 시작 지점(`A1.o.o`, `A1.o.p`, `X0.k.a`, `b.n.y`, `b.o.y`, `b.q.y`)도 release 산출물에서 재현됨.
- 이 잔여 호출은 앱 코드보다는 Flutter embedding (`FlutterFragmentActivity`, platform overlay bridge) 과 AndroidX `activity` edge-to-edge 구현의 정적 참조 영향으로 판단.
- 따라서 1번 권장조치(더 넓은 화면 / edge-to-edge 기본 대응)는 앱 쪽에서 정리했지만,
  2번 권장조치의 일부 경고는 Flutter/AndroidX 업스트림 변경 전까지 Play Console 에 계속 남을 수 있음.

검증:
- `flutter analyze lib/main.dart`
  - 새 에러 없음
  - 기존 `withOpacity` / style info 만 잔존
- `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 ./gradlew :app:compileDebugKotlin`
  - 성공
- `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 flutter build apk --release`
  - 성공
- release APK `classes.dex` 를 `dexdump` 로 확인해 Play Console 지목 API/심볼 존재 여부 점검

### 취하 숨김 대시보드 기준 서버/client/standalone 일치화

상태: 완료

변경:
- `lib/services/local_db_service.dart`
  - standalone `computeSummary(excludeWithdraw: true)` 가 `withdrawCount` 를 0 으로 내려 서버 `/summary` 와 같은 그래프 기준을 사용하도록 수정.
  - 실제 원본 취하 건수는 `withdrawRawCount` 로 함께 보존.
- `lib/models/report.dart`
  - `DashboardStats` 에 `withdrawRawCount`, `excludeWithdraw`, `copyWith()` 추가.
- `lib/providers/report_provider.dart`
  - Client 모드가 서버 `/summary` 를 받았을 때도 `exclude_withdraw=true` payload 면 `withdrawCount=0` / recent answers / watchlist 취하 제거를 한 번 더 적용.
  - 서버가 먼저 배포되지 않았거나 구버전 응답이 와도 모바일 화면 기준이 흔들리지 않도록 보정.
- `lib/screens/dashboard_screen.dart`
  - 파이 차트의 `총 N건` 라벨을 `stats.total` 대신 실제 표시 section 합계로 계산해, 취하 숨김 시 원형 그래프 비중과 총합이 어긋나지 않게 수정.

검증:
- `dart analyze lib/models/report.dart lib/providers/report_provider.dart lib/services/local_db_service.dart lib/screens/dashboard_screen.dart`
  - 새 에러 없음
  - 기존 `dashboard_screen.dart` 의 `withOpacity` deprecation info 6건만 잔존

### 최근 답변 전체 목록 진입 시 1회 자동 새로고침

상태: 완료

변경:
- `lib/screens/recent_answers_screen.dart`
  - 대시보드의 `최근 답변 완료 (3일)`에서 `모두 보기` 화면을 열면 `refreshSummaryAndRecentAnswers()`를 즉시 1회 호출하도록 변경.
  - 화면 첫 진입 시 캐시된 recent answers만 보여주지 않고, summary와 카테고리 목록을 다시 읽어 최신 답변 목록으로 갱신.

검증:
- `dart format lib/screens/recent_answers_screen.dart`
- `dart analyze lib/screens/recent_answers_screen.dart lib/providers/report_provider.dart`
  - 에러 없음
  - 기존 `withOpacity` / `_` 관련 info 3건만 잔존

### 서버 앱 기준 상태/처분 색상으로 모바일 표시 통일

상태: 완료

변경:
- `lib/server_palette.dart`
  - 서버 웹 대시보드/배지 기준 색상을 모바일 공용 팔레트로 정리.
  - `보완요청`, `처리중`, `답변완료`, `불수용/기타`, `과태료`, `경고장/범칙금` 매핑을 한 곳에서 관리.
- `lib/widgets/report_list_card.dart`, `lib/widgets/report_detail_sheet.dart`
  - 개별 신고 카드와 상세 시트의 상태/보완 배지 색을 서버 기준으로 통일.
- `lib/screens/dashboard_screen.dart`, `lib/screens/watchlist_screen.dart`, `lib/screens/recent_answers_screen.dart`, `lib/screens/notifications_screen.dart`, `lib/screens/data_editor_screen.dart`, `lib/screens/statistics_screen.dart`, `lib/main.dart`
  - 대시보드, 최근 답변, 감시목록, 알림, 데이터 수정, 앱 내부 변경 알림 시트까지 같은 색상 매핑을 재사용하도록 정리.
  - `과태료` 는 분홍, `경고장/범칙금` 은 회색, `보완요청` 은 주황, `처리중` 은 회색, `답변완료` 는 하늘색으로 통일.

검증:
- `dart format` on touched files
- `dart analyze ...`
  - 에러 없음
  - 기존 `withOpacity` / 스타일 info warning 만 잔존

### 상태 계층 재설계 구현

상태: 완료

변경:
- `lib/services/standalone_parser.dart`
  - standalone API 상세 파서가 `result(raw 상태)` 와 `status(canonical 처리상태)` 를 분리하도록 정리.
  - 일반 `C_NOW=0` 은 `result=진행`, `status=처리중`, 열린 보완은 `status=보완요청` 으로 저장.
- `lib/services/local_db_service.dart`
  - 앱 시작 시 legacy `reports` row 를 raw `상태` + `보완_미응답` 기준으로 canonical `처리상태` 로 정규화하는 backfill 추가.
  - standalone 요약 통계의 `처리중` 버킷이 `검토중` legacy 값도 같이 흡수하도록 보강.
- `lib/services/sync_engine.dart`
  - standalone 증분 동기화가 더 이상 목록 raw 상태와 로컬 `처리상태` mismatch 를 비교하지 않고, `종결여부` 와 `보완_미응답` 기준으로 대상을 선정.
- `lib/models/report.dart`
  - 서버 응답을 읽을 때 raw `상태` 를 우선 보존하도록 `result` 매핑 수정.
- `lib/providers/report_provider.dart`, `lib/widgets/search_filter_sheet.dart`, `lib/screens/dashboard_screen.dart`, `lib/screens/data_editor_screen.dart`
  - 검색/대시보드/수정 화면이 canonical `처리상태` 중심으로 동작하도록 정리하고, legacy `진행/진행중/검토중` 은 UI에서 `처리중` 으로만 노출.

검증:
- `dart format` on touched files
- `dart analyze ...`
  - 에러 없음
  - 기존 `dashboard_screen.dart` 의 `withOpacity` deprecation info 6건만 잔존

## 2026-05-12 (문서/마무리)

### 대시보드 보완 요청 카드 + 신고내역 검색 항목 마감 정리

상태: 완료

변경:
- `lib/models/report.dart`
  - `DashboardStats` 에 `supplementCount` 추가. 서버 `/summary` 와 standalone 집계가 같은 필드를 공유.
- `lib/services/local_db_service.dart`
  - standalone 대시보드 집계가 `처리상태='보완요청'` 을 별도 카운트하도록 보강.
- `lib/screens/dashboard_screen.dart`
  - 대시보드 요약 카드에 `보완 요청` 추가.
  - 처리 현황 파이 차트에도 `보완요청` 구간 추가.
- `lib/providers/report_provider.dart`, `lib/widgets/search_filter_sheet.dart`
  - 신고내역 검색에서 `진행/진행중/처리중` raw 값을 UI에는 `처리중` 하나로만 노출하도록 정규화.
  - `보완요청` 상태 선택과 `보완횟수` 입력 필드 추가.
  - `과태료` 검색 라벨/활성 필터 문구를 실제 데이터 컬럼에 맞게 `범칙금/과태료` 로 정리.
- `README.md`
  - 대시보드 `보완 요청` 카드, 신고내역 `보완요청`/`보완횟수` 검색, 보완 컬럼 round-trip 보존 설명 반영.

검증:
- `dart analyze lib/models/report.dart lib/providers/report_provider.dart lib/screens/dashboard_screen.dart lib/services/local_db_service.dart lib/widgets/search_filter_sheet.dart`
  - 에러 없음
  - 기존 `withOpacity` deprecation info 만 잔존

## 2026-05-12 (최종 정리)

### 보완요청 마지막 round 저장 구조를 서버와 동일하게 정렬

상태: 완료

배경:
- 서버가 `보완_요청자 / 보완_요청일시 / 보완_완료일시 / 보완_요청_내용 / 보완_신고자_의견 + 보완횟수` 구조로 정리되면서, 모바일도 요청자 정보를 본문 prefix 문자열에 섞어 들고 있을 필요가 없어졌다.
- 답변 담당자와 보완 요청자가 다를 수 있으므로, 모바일 카드/상세 화면에서도 요청자 이름을 별도 텍스트로 보여줘야 했다.

변경:
- `lib/models/report.dart`
  - `Report` 에 `supplementRequester`, `supplementRequestedAt`, `supplementCompletedAt` 필드 추가.
  - `fromJson` 이 서버 응답의 `보완_요청자 / 보완_요청일시 / 보완_완료일시` 를 직접 매핑.
- `lib/services/local_db_service.dart`
  - DB version `8 -> 9`.
  - `reports` 테이블에 `보완_요청자`, `보완_요청일시`, `보완_완료일시` 3개 컬럼 추가.
  - 업서트, `synced_at` 변경 추적, row→Report 변환 모두 새 컬럼까지 반영.
- `lib/services/standalone_parser.dart`
  - standalone JSON 파서도 마지막 보완요청을 `요청자/요청일시/완료일시/본문` 구조로 압축.
  - 기존의 "요청자/연락처/일시 prefix를 본문 문자열에 붙이기" 로직 제거.
- `lib/widgets/report_detail_sheet.dart`
  - 보완 카드 상단에 `보완 요청자`, `요청 일시`, `완료 일시`를 별도 메타 행으로 표시.
  - 공식 안전신문고 앱 호출 URI를 `appsafetyreport://view?c_no=...&ext_path=M_MY_01_S0002.html&mem_yn=Y` 형식으로 정리.
- `lib/widgets/report_list_card.dart`
  - 개별 신고 카드에도 `보완 요청자: <이름>` 을 별도 줄로 표시.
- `lib/services/sync_engine.dart`
  - 별점 사유 보강으로 `Report` 를 재생성할 때 보완요청 관련 새 필드가 유실되지 않도록 보존.

비고:
- 연락처는 앱 UI에 별도 표시하지 않는다. 사용자 요청 범위는 "요청자 이름을 답변 담당자와 구분해서 보여주기" 였고, 서버도 최종적으로는 이름/일시/본문만 주력으로 보존한다.

## 2026-05-12

### 보완요청 마지막 round 표시 + 누적 횟수 (다회차 이력 보존은 제거)

상태: 완료

배경:
- 서버 측 정책이 "마지막 round 1세트 + 누적 횟수만 보존" 으로 단순화됨. 모바일도 동일 모델로 정렬.
- 마지막 답변자와 최종 판정자가 다를 수 있으므로 보완 요청 내용 본문 prefix 에 요청자/연락처/요청·완료 일시를 함께 표시한다.

변경:
- `lib/services/local_db_service.dart`
  - DB version 7 → 8. `reports` 테이블에 `보완횟수 INTEGER DEFAULT 0`, `보완_미응답 TEXT DEFAULT 'N'`, `보완_요청_내용 TEXT DEFAULT ''`, `보완_신고자_의견 TEXT DEFAULT ''` 4 컬럼 추가. 기존 DB 는 `_addSupplementColumns()` 가 ALTER TABLE 로 보강한다.
  - 이전 임시 `report_supplement_history` 테이블은 마이그레이션에서 `DROP TABLE IF EXISTS` 로 정리. 관련 함수 (`upsertSupplementHistory`, `getSupplementHistoryForReport`, `_loadSupplementCounts`, `_attachSupplementCounts`) 와 `_SupplementSummary` 호출부 전부 삭제.
  - `_syncedAtTrackedKeys` 에 4 새 컬럼 추가 → 마지막 round 변동도 synced_at 갱신 트리거로 작동.
  - `_rowToReport` / `_rowToReportWithCounts` 가 `보완횟수 / 보완_미응답 / 보완_요청_내용 / 보완_신고자_의견` 을 Report 의 새 필드로 매핑.
- `lib/models/report.dart`
  - `Report` 에 `supplementCount`, `supplementOpen`, `supplementRequest`, `supplementOpinion` 필드 추가. `fromJson` 이 서버 JSON 의 한국어 키 4개를 그대로 매핑.
- `lib/services/standalone_parser.dart`
  - `buildSupplementHistoryFromJson` 삭제. 대신 `summarizeLastSupplementFromJson(detailData, closedState: ...)` 가 안전신문고 API JSON `SPLMNT_*` 필드를 읽어 `_SupplementSummary` 로 압축. 본문 prefix 는 서버 `_build_supplement_summary` 와 동일한 형식.
  - `parseJsonToReport` 가 `_supplementSummary` 를 만들어 Report 생성자에 4 필드 함께 전달. 보완요청이 열려 있는 신고는 `processStatus='보완요청'`, `processingStatus='보완요청'`, `processingFinish='N'` 으로 통일.
- `lib/services/sync_engine.dart`, `lib/services/standalone_auto_sync_service.dart`
  - `upsertSupplementHistory(...)` + `buildSupplementHistoryFromJson(...)` 호출 제거. Report 자체가 4 필드를 들고 있으므로 별도 저장 단계가 필요 없다.
- `lib/services/server_contract.dart`, `lib/services/api_service.dart`
  - `supplementsPath`, `supplementsForReportPath`, `getSupplementHistory()` 모두 삭제.
- `lib/widgets/report_detail_sheet.dart`
  - 기존 다회차 round 리스트 위젯 (`_SupplementHistorySection`, `_SupplementRoundCard`, `_SupplementSectionHeader`) 제거.
  - 대신 `_SupplementSection` 단일 카드로 단순화: 보완 횟수 배지 + 미응답/응답 완료 상태 배지 + 요청 내용 본문(요청자 prefix 포함) + 신고자 의견.
- `lib/widgets/report_list_card.dart`
  - 신고번호 옆 `보완횟수:N회` 주황색 배지 유지 (이전 작업 그대로).

검증:
- `Report.fromJson` 이 서버 응답의 `보완횟수 / 보완_미응답 / 보완_요청_내용 / 보완_신고자_의견` 을 읽어 모델 필드로 보존.
- `parseJsonToReport(testresults/59614484)` (서버 testresults 동일 JSON) → `processStatus='보완요청'`, `processingFinish='N'`, `supplementCount=1`, `supplementOpen=true`, `supplementRequest` 가 `"보완 요청자: 이민지 (032-456-0263) · 요청 일시: 2026-05-12 10:32:40 · 완료 일시: (미응답)\n\n[본문]"` 형식.
- 종결 상태(취하) JSON → `supplementOpen=false`, 누적 횟수는 `SPLMNT_DMND_NO` 기반으로 보존.
- 상세 시트 위젯이 `report.supplementCount > 0 || supplementRequest != ''` 일 때만 보완 카드 렌더.

비고:
- 클라이언트 모드는 서버 응답 형식에 의존하므로 서버 동일 시점 커밋과 함께 배포해야 카드/배지가 채워진다.
- 다회차 이력 전체가 필요하면 안전신문고 공식 페이지를 직접 열어 확인. 앱은 마지막 round + 횟수 표시만 책임진다.

---

## 2026-05-08

### Client 최근 답변 / 알림 상세가 `synced_at`을 버리던 문제 수정

상태: 완료

변경:
- `lib/models/report.dart`
  - `Report` 모델에 `syncedAt` 추가, 서버/알림 payload의 `synced_at` 파싱
- `lib/providers/report_provider.dart`
  - `recentAnswerReports` 재계산 시 `답변일`만 보지 않고 `syncedAt DESC`, fallback `답변일 DESC`, `신고번호 DESC` 정렬 사용
- `lib/services/local_db_service.dart`
  - 로컬 DB row → `Report` 변환 시 `synced_at` 보존
- `lib/services/sync_engine.dart`
  - pending changes / heads-up 상세 payload 직렬화에 `synced_at` 포함
- `lib/models/rating_batch_result.dart`
  - reportData 직렬화에도 `synced_at` 포함

검증:
- `dart format lib/models/report.dart lib/models/rating_batch_result.dart lib/providers/report_provider.dart lib/services/local_db_service.dart lib/services/sync_engine.dart`
- `dart analyze lib/models/report.dart lib/models/rating_batch_result.dart lib/providers/report_provider.dart lib/services/local_db_service.dart lib/services/sync_engine.dart`
  - 에러 없음
  - 기존 style/info lint만 잔존

비고:
- Standalone DB 자체는 예전부터 `reports.synced_at` 을 저장하고 있었지만, 모바일 상위 `Report` 모델과 recent-answer 재계산 경로가 이 값을 실제로 쓰지 않아 서버/Standalone 모두에서 순서가 미세하게 흔들릴 수 있었다.
- Client 모드에서는 서버 WS `crawl_changes` payload에도 `synced_at` 이 빠져 있었기 때문에 증상이 더 두드러졌고, 이번 서버 패치와 함께 맞물려 해결된다.

### Client 모드 기존 사용자 웹소켓 서비스 비활성화 버그 수정

상태: 완료

원인:
- Standalone 모드 리팩토링 과정에서 안드로이드 백그라운드 웹소켓 서비스(`WsService`)가 현재 앱 모드(`appMode`)가 "server"일 때만 작동하도록 방어 코드가 추가됨.
- 기존 사용자나 초기화 직후에는 내부 저장소(SharedPreferences)에 `appMode` 값이 누락되어 빈 문자열(`""`)로 반환되는데, Kotlin 네이티브 단에서 이를 "서버 모드가 아님"으로 간주하고 서비스를 강제 종료시키는 문제가 발생함.

변경:
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - `autoStartWsServiceIfConfigured()`에서 `appMode`를 읽을 때 기본값을 `""` 대신 `"server"`로 지정하여 값이 없을 때도 기존처럼 정상적으로 웹소켓을 실행하도록 수정.

## 2026-05-07 (P0~P3 리팩토링)

### Client 파일 여러 개 다운로드/삭제 302 리다이렉트 수정

상태: 완료

변경:
- `lib/services/server_contract.dart`
  - 다중 파일 다운로드/삭제 경로를 `/api/v1/files/download-multi`, `/api/v1/files/delete-multi`로 정의
- `lib/services/api_service.dart`
  - 모바일 Client가 세션 로그인용 `/file-browser/*` 레거시 경로를 호출하지 않도록 수정
  - 다중 파일 다운로드/삭제를 API 키 인증 기반 파일 API로 전환

비고:
- 원인은 Client 모드에서 API 키만 가진 상태로 `/file-browser/download-multi`를 호출해
  서버가 `/login`으로 `302` 리다이렉트하던 구조였다.

### 서버-모바일 DB round-trip 항목 전수 점검 + exact import 보강

상태: 완료

변경:
- `pubspec.yaml`
  - 중복군 payload hash를 서버와 동일한 SHA-256으로 맞추기 위해 `crypto` 직접 의존성 선언
- `lib/services/duplicate_projection_service.dart`
  - 중복군 `group_id`/`fingerprint` 생성 기준을 서버와 동일한 SHA-256으로 통일
  - 예전 FNV hash로 만들어진 모바일 중복군도 한 번은 이어받을 수 있게 legacy hash 매핑 추가
  - `duplicate_group` 스키마에 `apply_globally` 컬럼 추가 및 refresh/update 시 같이 관리
- `lib/services/local_db_service.dart`
  - Standalone DB version `6 -> 7`
  - `importFromServerDb()` 가 `mysafety_sync_meta`, `mysafety_duplicate_group`, `mysafety_duplicate_member`를 함께 읽어 exact import 하도록 확장
  - 서버에서 `last_sync`, `watchlist`, 기타 sync meta key/value를 더 이상 잃지 않도록 복원
  - 서버 duplicate group/member 테이블이 있으면 import 직후 재계산으로 덮어쓰지 않고 그대로 유지
- `lib/models/report.dart`
  - 중복 신고 UI에서 `처리상태 · 과태료/범칙금`을 함께 표기하는 공용 getter 추가
- `lib/screens/duplicate_management_screen.dart`
- `lib/widgets/duplicate_group_detail_sheet.dart`
  - parent/child 카드와 상세 보기에서 처리상태 옆에 과태료 정보가 있으면 함께 노출

검증:
- `dart analyze lib/services/local_db_service.dart lib/services/duplicate_projection_service.dart lib/models/report.dart lib/screens/duplicate_management_screen.dart lib/widgets/duplicate_group_detail_sheet.dart`
  - 에러 없음
  - 기존 deprecated info 4건만 잔존
- `flutter pub get` 로 direct dependency 반영 확인

비고:
- 이번 정리 기준으로 모바일이 서버 DB를 import 할 때 보존 대상은
  `entry_value`, `raw_content`, `raw_type`, `saved_at`, `synced_at`,
  `sync_meta.*`, `duplicate_group.*`, `duplicate_member.*` 이다.
- `review_required` / `confirmed_duplicate` / `not_duplicate` 의미와 대표건 로직은 그대로 유지한다.

### `docs/mobile-refactoring-plan-2026-05.md` 적용 1차 — 문자열 키/패널/카테고리 fetch 정리

상태: 완료 (P0~P3 1차 분량). P4 (refresh nonce 제거) 와 ReportProvider 분해는 별도 차수로 보류.

신규 파일:
- `lib/services/app_prefs_keys.dart` — SharedPreferences 키 단일 소스
- `lib/services/app_storage_paths.dart` — `mysafetyreport` 산출물 디렉토리 fallback 단일 소스
- `lib/services/pending_db_import_action.dart` — 모드 전환 시 SetupScreen 이 적용할 액션 value object
- `lib/services/pending_changes_store.dart` — `pending_crawl_changes` / `foreground_event` 키 wrapper
- `lib/services/standalone_pending_queue_store.dart` — Standalone 알림 큐 read/append/remove 단일 소스
- `lib/services/server_connection_service.dart` — Setup 공용 서버 연결 테스트 + Settings 서버 버전 조회용 공통 서비스
- `lib/services/repositories/watchlist_repository.dart`
- `lib/services/repositories/duplicate_repository.dart`
- `lib/services/repositories/sunwi_repository.dart`
- `test/services/pending_changes_store_test.dart`
- `test/services/pending_db_import_action_test.dart`
- `test/services/server_connection_service_test.dart`
- `test/services/standalone_pending_queue_store_test.dart`

화면/위젯 변경:
- `lib/screens/setup_screen.dart` — `_connectServer` 가 `ServerConnectionService.testConnection()` 사용. `_applyPendingDbImport` 이 `PendingDbImportAction` 사용. raw http retry 루프 / pending action 문자열 파서 제거.
- `lib/screens/settings_screen.dart` — `_loadServerVersion` 이 `ServerConnectionService.fetchVersionInfo()` 사용. `_backupDir` / `_exportsDir` 가 `AppStoragePaths` alias. pending action 저장이 `PendingDbImportAction.save()` 호출. 연결 테스트 UI(`_testConnection`)는 아직 기존 상세 응답 표시 경로 유지.
- `lib/screens/file_browser_screen.dart` — `_exportsDir` 이 `AppStoragePaths.exportsRoot()` 호출.
- `lib/screens/watchlist_screen.dart` — `WatchlistPanel._load` 이 `WatchlistRepository.fromProvider` 경유, `ApiService` / `LocalDbService` 직접 호출 제거.
- `lib/screens/duplicate_management_screen.dart` — `DuplicateManagementPanel._load` / `_saveGroup` 이 `DuplicateRepository.fromProvider` 경유.
- `lib/screens/sunwi_screen.dart` — `SunwiSection._load` / `_exportCsv` 가 `SunwiRepository.fromProvider` 경유. 캐시 엔트리도 `SunwiSnapshot` 단일 객체로 단순화.
- `lib/widgets/selection_action_bar.dart` — `_sync` 가 `StandalonePendingQueueStore.append()` 호출 (raw prefs.setString 제거).
- `lib/main.dart` — `_checkForegroundEvent` 가 `ForegroundEventStore.readAndClear()`, `_checkPendingChanges` 가 `PendingChangesStore.readAndClear()` 사용.

서비스/Provider 변경:
- `lib/providers/report_provider.dart` — `_hasLoadedTraffic/Parking/Other` 3개 boolean 을 `Set<String> _loadedCategories` 로 통합. `fetchTrafficReports/Parking/Other` 가 `fetchCategoryReports(category)` 공용 경로의 thin wrapper. `ensureCategoryReportsLoaded` / `refreshAll` 도 한 줄 루프로 정리.
- `lib/services/sync_engine.dart` — `pending_crawl_changes` 직접 쓰기 대신 `PendingChangesStore.append()` 사용. 키 문자열 모두 `AppPrefsKeys` 로 치환.
- `lib/services/standalone_auto_sync_service.dart` — 큐 IO 가 `StandalonePendingQueueStore` 경유.
- `lib/services/standalone_auth_service.dart`, `lib/providers/notification_history_provider.dart` — 키 문자열을 `AppPrefsKeys` alias 로 치환.
- `lib/services/sunwi_service.dart` — `_standaloneExportDir` 이 `AppStoragePaths.subDir('sunwi')` alias.

검증:
- `dart analyze`
  - 에러 없음
  - warning/info 잔존 (`settings_screen.dart` dead code, deprecation/style lint 포함)
- `flutter test`
  - 기존 placeholder 1건 + 신규 service/store 테스트 통과

비고:
- 이번 차수에서 보류한 항목 (P4 refresh nonce 정리, `ReportProvider` 분해, `DbTransferService`/`FileExportService` 추출) 은 다음 차수로 이월.
- Kotlin native 의 SharedPreferences 키 이름과 호환을 유지한다. Kotlin 측 코드는 손대지 않았다.

---

## 2026-05-07

### 신고관리 `데이터 수정` 탭 실제 연결

상태: 완료

변경:
- `lib/screens/report_management_screen.dart`
  - `신고관리` 하위 탭을 `감시 목록 / 중복 신고 / 데이터 수정` 3개로 확장
- `lib/screens/data_editor_screen.dart`
  - 신고번호 역순 수정 목록 추가
  - 신고내역과 같은 상세검색 시트 재사용
  - 수정 카드를 누르면 서버 수정 페이지와 같은 순서의 필드를 바텀시트에 표시
  - `범칙금_과태료` 입력 칸에 서버와 동일한 예시 문구 표시
- `lib/models/editor_schema.dart`
- `lib/services/repositories/editor_repository.dart`
  - Client/Standalone 공통 데이터 수정 repository 계층 추가
  - Client는 서버 `editor/schema`, `editor/{category}/{id}` API 사용
  - Standalone은 로컬 SQLite `reports` row 직접 수정 사용
- `lib/services/api_service.dart`
  - 구버전 서버가 데이터 수정 API를 아직 제공하지 않는 경우 `404`를 전용 예외로 분기

비고:
- 모바일에서 `신고관리` 탭을 눌렀는데 `데이터 수정`이 보이지 않던 문제는
  실제 UI 연결이 빠져 있던 상태였고, 이번에 기능 탭까지 복구했다.

### Client 데이터 수정 상세 값 비어 보이던 문제 수정

상태: 완료

변경:
- `lib/services/repositories/editor_repository.dart`
  - Client 서버의 수정 대상 조회 응답이 `data.record` 중첩 구조라는 점을 반영
  - 모바일이 상위 payload를 그대로 record로 오해해 `ID`만 보이고 기본 정보/입력값이 비어 있던 문제 수정

검증:
- `dart analyze lib/services/repositories/editor_repository.dart lib/screens/data_editor_screen.dart`
  - 에러 없음

### 대시보드 임베드 신고현황 백지 방지 + Client 중복 신고 404 방어

상태: 완료

변경:
- `lib/screens/sunwi_screen.dart`
  - `SunwiSection(embedded: true)` 가 대시보드 안에서 자체 `ListView` 를 만들지 않고 일반 `Column`만 렌더하도록 수정
  - 대시보드 `SingleChildScrollView` 안에서 중첩 스크롤로 레이아웃이 깨져 백지로 보이던 문제 방지
- `lib/services/api_service.dart`
  - 서버가 `/api/v1/duplicates/groups` 를 아직 제공하지 않아 `404`를 돌릴 때 전용 예외로 분기
- `lib/screens/duplicate_management_screen.dart`
  - Client 모드에서 중복 신고 API 미지원(`404`)이면 크래시성 에러 대신 안내 문구와 빈 상태로 표시
  - Standalone 모드에서는 로드 전에 중복 projection 스키마 생성을 한 번 더 보장

비고:
- `404 중복 신고 그룹 조회 실패`는 Client 서버 버전 미지원일 때만 가능한 증상이고, Standalone은 동일 증상이 나지 않는다.

### 신고관리 탭 추가 + 신고현황 대시보드 하단 이동

상태: 완료

변경:
- `lib/main.dart`
  - 하단 `신고현황` 탭 제거
  - `신고내역`과 `통계` 사이에 `신고관리` 탭 추가
- `lib/screens/report_management_screen.dart`
  - `감시 목록`, `중복 신고` 하위 탭을 가진 관리 화면 추가
- `lib/screens/dashboard_screen.dart`
  - 대시보드 최하단에 `신고현황` 섹션을 임베드
  - 감시 목록 `관리`/`더 보기` 동선을 새 `신고관리 > 감시 목록` 화면으로 연결

비고:
- `SunwiSection` 은 대시보드 요약 로딩과 별개로 자체 로딩되어, 신고현황 데이터가 늦어도 대시보드 전체를 막지 않는다.

### 중복 신고 변경을 모바일 알림/신고 결과에 반영

상태: 완료

변경:
- `lib/models/notification_item.dart`
- `lib/providers/notification_history_provider.dart`
- `lib/screens/notifications_screen.dart`
  - `notification_kind=duplicate` 항목을 신고 결과 탭과 상세 시트에서 처리
- `lib/services/sync_engine.dart`
- `lib/services/standalone_auto_sync_service.dart`
  - 크롤링/동기화 뒤 중복군 변경을 감지해 pending change 및 앱 알림에 포함
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt`
  - 푸시/알림 탭 클릭 시 중복군 상세 payload까지 전달

### 모바일 설정 문구/배치 정리

상태: 완료

변경:
- `lib/screens/settings_screen.dart`
  - `경찰 기관명 정규화 → 취하 데이터 숨기기 → 중복 신고 대표건만 반영` 순서로 정리
  - 대표건 기준 설명 문구를 줄바꿈하고 `비활성화할 경우` 표현으로 수정

## 2026-05-06

### Standalone 중복 신고 projection 추가 + 대표건 기준 전역 설정 준비

상태: 완료

변경:
- `lib/services/duplicate_projection_service.dart`
  - `raw_content` exact match 기준의 Standalone 중복군 계산 로직 추가
  - `duplicate_group`, `duplicate_member` 로컬 테이블 생성/갱신
  - 대표건 자동 우선순위(`과태료 > 경고/범칙금 > 처리상태 > 답변일 > synced_at > 신고번호`) 적용
  - `review_required`, `confirmed_duplicate`, `not_duplicate` 상태와 `auto`, `manual` 대표건 모드 지원
- `lib/models/duplicate_group.dart`
  - 중복군/멤버 모델 및 라벨 헬퍼 추가
- `lib/widgets/duplicate_group_detail_sheet.dart`
  - 중복군 상세 바텀시트 추가
- `lib/screens/duplicate_management_screen.dart`
  - Client/Standalone 겸용 중복 신고 관리 패널 추가
  - 대표건 child를 직접 선택하면 자동 모드에서도 저장 전에 `수동 고정`으로 전환되도록 UX 보강
- `lib/services/local_db_service.dart`
  - Standalone DB version `5 -> 6`
  - DB 생성/업그레이드 시 중복 projection 스키마 자동 생성
  - 요약/목록/통계/감시목록/검색에 `useRepresentativeRecords` 기준 projection 반영
  - demo seed, 서버 DB import, 백업 복원, 수정 저장 후 중복군 재계산 연결
- `lib/providers/report_provider.dart`
  - `useRepresentativeRecords` 전역 상태 추가
  - Standalone `fetchSummary`/카테고리 로드에 대표건 기준 여부 전달

검증:
- `dart analyze ...` 대상 파일 기준 에러 없음
  - 경고/info만 남음

비고:
- `review_required` 그룹은 대표건 기준 설정과 무관하게 child 전체를 보여주는 방향을 로컬 projection에서도 유지한다.

### 모바일 기본 재시도 5회 상향 + 설정 기본값 정리

상태: 완료

변경:
- `lib/services/network_retry_config.dart`
  - 모바일 공용 재시도 횟수 상수 추가 (`5회`)
- `lib/services/api_service.dart`
- `lib/services/standalone_api_service.dart`
- `lib/services/standalone_auth_service.dart`
- `lib/screens/setup_screen.dart`
- `lib/screens/file_browser_screen.dart`
  - 각 네트워크 재시도 루프가 공용 상수를 사용하도록 정리
- `lib/screens/settings_screen.dart`
  - `크롤링 완료 후 구글 시트 자동 업로드` 기본값을 `false` 로 정리
  - `중복 신고 대표건만 반영` 전역 스위치 추가

비고:
- 서버 기본값(`auto_export_sheet=false`, `use_representative_records=true`)과 맞춘 변경이다.

### Watchlist / Sunwi 섹션 분리 기반 정리

상태: 완료

변경:
- `lib/screens/watchlist_screen.dart`
  - `WatchlistScreen` 을 `WatchlistPanel` 래퍼로 분리
  - 다른 화면/탭 안에 감시목록 패널을 재사용할 수 있게 구조 정리
- `lib/screens/sunwi_screen.dart`
  - `SunwiScreen` 을 `SunwiSection` 래퍼로 분리
  - `embedded` 모드를 추가해 대시보드 하단 등에 같은 섹션을 재사용할 수 있는 기반 추가

### Standalone DB version 5 / entry_value·raw_content·synced_at round-trip 보존

상태: 완료

변경:
- `lib/services/local_db_service.dart`
  - Standalone DB version `4 -> 5`
  - 원본 payload 보존용 `report_raw` 사이드카 테이블 추가
  - 기존 `reports.raw_content` 는 마이그레이션 시 `report_raw` 로 이관하고 본 테이블에서는 비워 두도록 변경
  - `upsertReport()` 가 동일 내용 재동기화에서는 `synced_at` 를 유지하고,
    실제 추적 필드 변경 또는 raw payload 변경이 있을 때만 갱신하도록 수정
  - 최근 답변 쿼리를 `synced_at DESC` 기준으로 변경하고,
    `synced_at` 가 없는 레코드는 `답변일 DESC`, `신고번호 DESC` fallback 정렬 적용
  - `clearAll()` 이 `report_raw` 도 함께 정리하도록 수정
  - `importFromServerDb()` 가 `mysafety_entry_value`, `mysafety_raw_content`, `merge_* .synced_at` 를 함께 읽어
    더 이상 `entry_value=''`, `raw_content=''`, `synced_at=now` 로 덮어쓰지 않도록 수정

검증:
- `dart format lib/services/local_db_service.dart`
- `dart analyze lib/services/local_db_service.dart lib/models/report.dart lib/services/sync_engine.dart`
  - 새 변경과 직접 관련 없는 기존 info 4건 외 추가 오류 없음

비고:
- 서버 쪽 `mysafety_raw_content` / `detail+merge.synced_at` 구조는 `safetyreport` 레포의 동일자 CHANGELOG 참고
- 이번 변경으로 Standalone DB 가 서버 DB 를 import 해도 `entry_value` 와 `synced_at` 를 더 정확히 보존한다

### Client 서버 계약 상수화 / Flutter-Android 호출 경로 정리

상태: 완료

변경:
- `lib/services/server_contract.dart`
  - Client 모드 서버 API prefix, 헤더 이름, WebSocket 경로, 주요 엔드포인트를 단일 상수 집합으로 정리
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerContract.kt`
  - 네이티브 쪽에서도 동일한 API/WS 경로와 이벤트 타입 상수를 사용하도록 정리
- `lib/services/api_service.dart`
  - Client 모드 HTTP 호출이 `ServerContract` 를 통해 URI/헤더를 만들도록 전환
- `lib/screens/setup_screen.dart`, `lib/screens/settings_screen.dart`, `lib/screens/file_browser_screen.dart`
  - 화면별로 흩어져 있던 Client 모드 서버 경로 하드코딩을 계약 헬퍼 기준으로 정리
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt`
  - `/ws/events`, `api_key`, `crawl_started`/`crawl_finished`/`crawl_changes`/`ping` 문자열을 공용 계약 상수로 정리
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt`
  - `/api/v1/crawl/enqueue`, `X-API-Key` 를 공용 계약 상수로 사용하도록 전환

비고:
- 서버 쪽 공용 서비스/크롤러 리팩토링은 `safetyreport` 레포의 동일자 CHANGELOG 참고
- Client 모드 서버 계약 문자열을 한 곳으로 모은 변경이며, 기존 서버 API 경로 자체는 바꾸지 않음

---

## 2026-05-05

### 대시보드 최근 답변 더보기 / 상세 시트 필드 링크 / 별점 batch 비차단화

상태: 완료

변경:
- `lib/screens/dashboard_screen.dart`
  - "최근 답변 완료 (3일)" 섹션을 감시 목록과 동일한 패턴으로 정리: 5건만 미리 보여주고
    그 이상은 "+ N건 더 보기" 링크로 별도 화면 이동
  - 우측 상단에 "모두 보기" 바로가기도 추가
- `lib/screens/recent_answers_screen.dart` (신규)
  - 대시보드 최근 답변 전체 리스트 화면
  - `ReportProvider.recentAnswerReports` 를 사용해 실제 카테고리 목록에서 최근 3일 답변을 재계산한 결과를 표시
- `lib/services/local_db_service.dart`
  - Standalone `computeSummary` 의 최근 답변 쿼리에 서버와 동일한 3일 윈도우 필터 추가,
    한도를 10 → 200 으로 상향
- `lib/models/report.dart`
  - `Report.category` 필드 추가, `Report.fromJson` 에서 `category` JSON 키 읽기
- `lib/services/local_db_service.dart`
  - `_rowToReport`, `_rowToReportWithCounts` 에서 `category` 컬럼을 Report 로 매핑
- `lib/providers/report_provider.dart`
  - `findCategory(report)` / `categoryToTabIndex(category)` 헬퍼 추가
    (Report.category 우선, 없으면 현재 로드된 카테고리 리스트에서 검색)
  - `ensureCategoryReportsLoaded()` / `recentAnswerReports` / `refreshSummaryAndRecentAnswers()` 추가
  - 최근 답변 화면은 summary 축약본이 아니라 실제 traffic/parking/other 목록에서 최근 3일 답변을 다시 계산해 사용
- `lib/widgets/report_detail_sheet.dart`
  - 차량번호 / 위반장소 / 위반법규 / 담당자 4개 필드를 클릭 가능한 링크로 변경
  - 탭 시 시트를 닫고 신고 내역 화면으로 이동, 동시에 해당 신고 카테고리 탭과 일치하는
    `ReportFilter` (carNumber / location / law / manager) 를 적용
  - 이동 전 `ensureCategoryReportsLoaded()` 를 통해 카테고리 재확인, 끝까지 못 찾으면 잘못된 기본 탭으로 보내지 않고 SnackBar 로 중단
- `lib/widgets/selection_action_bar.dart`
  - 별점 batch 처리(`_rate`)를 fire-and-forget 으로 변경
  - 시작 즉시 SnackBar 로 안내하고 선택 모드를 해제. 액션 바 전체가 스피너로 잠기는
    문제 해결 (FGS keep-alive 는 RatingService 내부 acquireFgs/releaseFgs 로 그대로 유지)
  - 결과는 알림 (rating_result) + 히스토리 + 완료 SnackBar 로만 통지
  - `dart:async` 의 `unawaited` 사용
- `lib/services/api_service.dart`
  - 카테고리별 목록 API 응답에 `category` 가 빠져 있으면 요청한 카테고리(`traffic`/`parking`/`other`)를 보강
- `lib/models/rating_batch_result.dart`
  - 별점 batch 결과 히스토리 직렬화에 `category` 저장 추가

비고:
- Standalone DB(스키마 v4) 는 이미 `category` 컬럼을 갖고 있어 모바일은 추가 마이그레이션
  없이 바로 활용 가능
- Client(server) 모드는 신규로 응답에 `category` 키가 들어오지만 기존 모바일 빌드는
  무시하므로 호환성 영향 없음
- 서버 대응 항목(`recent_answers[:200]`, `category` 전파, 웹 상세 링크/URL 연동)은
  `safetyreport` 레포 `2026-05-05` CHANGELOG에 기록한다.

### Android 15 edge-to-edge 공식 경로 전환

상태: 완료

변경:
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - `FlutterActivity` → `FlutterFragmentActivity` 로 전환
  - 수동 `WindowCompat.setDecorFitsSystemWindows(false)` 호출 제거
  - AndroidX `enableEdgeToEdge()` 를 적용해 Android 15+ 기본 edge-to-edge 와
    하위 버전 동작을 같은 경로로 맞춤

비고:
- 앱 코드에서 직접 쓰던 수동 edge-to-edge 진입점은 제거했다. 이후 Play Console 에
  경고가 남는다면 Flutter/AndroidX 내부 호출 여부를 추가 점검해야 한다.

## 2026-05-04
- '신고리스트'탭을 '신고내역'탭으로 변경(줄바꿈 이슈)

## 2026-05-03
변경:
- 플레이스토어 심사 결과에 따라 아이콘 변경함

## 2026-05-02

### 통계 드릴다운을 신고리스트 상세검색 기반으로 전환 + 위반법규 단일선택 보강

상태: 완료

변경:
- `lib/screens/statistics_screen.dart`
  - 통계 행 탭 시 기존 `FilteredListScreen` 대신 신고리스트 화면을 열도록 변경
  - 기관/담당자/연도/위반법규 필터를 `ReportFilter`에 주입하고 카테고리에 맞는 탭으로 진입
  - 통계의 `법규 없음(__없음__)` 상태도 신고리스트 필터로 그대로 전달
- `lib/screens/report_list_screen.dart`
  - 초기 탭 인덱스 지정 지원 추가
  - 통계/검색에서 넘어온 활성 필터를 상단 Chip으로 표시
- `lib/providers/report_provider.dart`
  - 위반법규 빈 값 전용 sentinel `kEmptyLawFilterValue` 추가
  - 로드된 교통/주정차/기타 신고 데이터에서 유효한 위반법규 목록을 수집하고, 빈 값 신고가 있으면 `없음` 옵션도 포함
  - 위반법규 필터를 자유입력 부분검색이 아닌 단일 선택 exact match / `없음` 매칭으로 변경
- `lib/widgets/search_filter_sheet.dart`
  - 위반법규 입력을 데이터 기반 단일선택 드롭다운으로 변경
  - 드롭다운의 `__없음__` 내부값을 사용자에게는 `없음`으로 표시
- `lib/screens/search_screen.dart`
  - 공용 상세검색 시트가 주정차 데이터까지 함께 로드/검색하도록 보강

비고:
- Client 모드는 이미 `/api/v1/reports/{category}` 원본 목록을 받아 모바일에서 필터링하는 구조라 서버 API 추가는 불필요

### Play Console 정부 정보 출처/비공식 고지 추가

상태: 완료

변경:
- `lib/widgets/report_detail_sheet.dart`
  - `안전신문고 앱에서 보기` 버튼 아래에 안전신문고 공식 출처 URL(`https://www.safetyreport.go.kr/`) 표시
  - `안전신문고 공식 사이트 열기` 외부 링크 버튼 추가
  - 비공식 앱 / 비정부 대표 아님 / 원문은 공식 서비스에서 확인해야 함 안내 문구 추가
- `lib/screens/settings_screen.dart`
  - `앱 정보` 카드에 동일한 공식 출처 URL, 외부 링크 버튼, 비공식 고지 문구 추가
- `CHANGELOG.md`, `CLAUDE.md`
  - 검색/통계 드릴다운 변경 및 Play Console 대응 지점 기록

### Standalone 모드 다중 선택 동기화 버튼 추가

상태: 완료

변경:
- `lib/widgets/selection_action_bar.dart`
  - Standalone 모드에서 여러 신고를 선택했을 때 Client 모드의 '크롤링' 버튼과 동일한 위치에 '동기화' 버튼 추가
  - 선택된 신고번호들을 `standalone_pending_reports` 큐에 추가하고 `StandaloneAutoSyncService.drainIfPending()`을 호출하여 개별 동기화 처리
  - `SharedPreferences` 누락된 임포트 추가 및 `withOpacity` deprecation 경고 수정

### Client 별점 주기 로그 파싱 버그 수정

상태: 완료

원인:
- 서버 로그 포맷이 `[timestamp][level|file] >> - [SPP-...] N점 별점 부여 성공 (API)` 인데,
  모바일의 regex `\[(.+?)\]`가 첫 번째 브래킷인 타임스탬프를 캡처해 신고번호 매칭 실패
- 성공 로그가 기록되어도 모바일에서 "서버 로그에서 결과를 확인하지 못했습니다." 표시

수정:
- `lib/services/rating_service.dart`
  - 4개 regex의 캡처 그룹을 `(.+?)` → `(SPP-.+?)`로 변경
  - 타임스탬프 브래킷을 건너뛰고 신고번호만 정확히 캡처

### 만족도 조사 여부 검색 필터 추가

상태: 완료

변경:
- 모바일 `lib/providers/report_provider.dart`
  - `ReportFilter`에 `pollStatus` 필드 추가
  - `_applyFilter()`에 `pollStatus` 필터 로직 반영
  - `activeLabels`에 만족도 필터 표시 추가
- 모바일 `lib/widgets/search_filter_sheet.dart`
  - 별점사유 아래에 `만족도 조사 여부` 단일선택 드롭다운 UI 추가
  - `_singleSelectDropdown` 위젯 메서드 추가

비고:
- 서버 웹 상세검색 드롭다운 추가 내역은 `safetyreport` 레포 `2026-05-02` CHANGELOG에 기록한다.

## 2026-05-01

### Client 별점 요청 302 대응

상태: 완료

변경:
- `lib/services/api_service.dart`
  - Client 모드 별점 시작 요청 경로를 웹 세션 기반 `/rating/start`에서 API 키 기반 `/api/v1/rating/start`로 변경
  - 서버가 예전 코드라 `302 /login`을 돌려줄 때 원인 파악이 쉬운 안내 메시지를 반환하도록 보강
- `CLAUDE.md`
  - Client 별점 흐름 설명을 새 API 경로 기준으로 수정

### 알림 탭 별점 주기 추가 + 다중 선택 배치 처리

상태: 완료

변경:
- `lib/widgets/selection_action_bar.dart`
  - 신고리스트 다중 선택 액션에 `별점 주기` 버튼 추가
  - 1~5점 선택 다이얼로그 추가
  - 완료 후 성공/스킵/실패 집계 푸시 알림 전송
- `lib/services/rating_service.dart`
  - Client(server) / Standalone 공통 별점 배치 처리 서비스 추가
  - 서버앱 참조 기준으로 별점 불가 신고(`참여 완료`, `참여 불가`, `답변 대기`, `취하/처리중/진행*`) 자동 스킵
  - Client는 서버 `/rating/start` 요청 후 `current_rating.log` 폴링으로 완료/실패 추적
  - Standalone은 안전신문고 만족도 API에 직접 POST 하고 로컬 DB 별점 상태 즉시 반영
  - 두 모드 모두 작업 중 `SyncForegroundService`를 재사용해 프로세스 보존
- `lib/models/rating_batch_result.dart`
  - 별점 배치 결과/개별 신고 결과 모델 추가
- `lib/models/notification_item.dart`
  - 알림 kind(`crawl` / `report` / `rating`) 구분 추가
- `lib/providers/notification_history_provider.dart`
  - 별점 배치 결과를 알림 히스토리에 저장하는 로직 추가
  - 알림 탭 내부 서브탭 선호 인덱스 상태 추가
- `lib/screens/notifications_screen.dart`
  - 알림 탭을 `크롤링 현황 / 신고 결과 / 별점 주기` 3탭으로 확장
  - 별점 주기 결과 카드, 성공/스킵/실패 요약, 실패 신고번호 표시 추가
  - 항목 탭 시 신고 상세로 이동 가능한 report 카드형 상세 시트 추가
- `lib/services/api_service.dart`
  - Client 모드용 서버 별점 시작 요청 / 서버 current_rating.log 조회 메서드 추가
- `lib/services/standalone_api_service.dart`
  - Standalone 모드용 만족도 POST / 상태 조회 / 워밍업 메서드 추가
- `lib/services/local_db_service.dart`
  - 신고번호 기준 만족도조사여부 / 별점 / 별점사유 갱신 메서드 추가
- `lib/providers/report_provider.dart`
  - 별점 배치 실행 후 전체 데이터 새로고침 + 최신 report 데이터로 결과 보강하는 메서드 추가
- `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt`
  - 로컬 알림에 `nav_subtab` / `event_type` payload 지원 추가
  - 푸시 알림 탭 시 `알림 > 별점 주기` 또는 `알림 > 신고 결과`로 직접 진입 가능하게 수정
- `lib/main.dart`
  - native intent의 `sub_tab` 수신 및 신고 결과 도착 시 알림 서브탭 자동 이동 추가
- `test/widget_test.dart`
  - 기본 샘플 카운터 테스트를 현재 앱 구조와 충돌 없는 placeholder 테스트로 교체

### 신고 카드 공용화 + 문서 git 반영

상태: 완료

변경:
- `lib/widgets/report_list_card.dart`
  - 신고 카드 공용 UI 추가: 상태칩, 선택 강조, 차량번호 배지, 메타 행 렌더링 통합
- `lib/screens/report_list_screen.dart`
  - 일반 신고 / 중복차량 카드가 공용 카드 위젯을 사용하도록 리팩토링
  - 중복차량 횟수 배지는 화면 전용 `headerSuffix`로 분리
- `lib/screens/search_screen.dart`
  - 검색 결과 카드 중복 UI 제거, 공용 카드 위젯 사용
- `lib/screens/filtered_list_screen.dart`
  - 필터 결과 카드 중복 UI 제거, 공용 카드 위젯 사용
- `CLAUDE.md`
  - `.gitignore` 해제 전제로 git 추적 문서 기준 설명으로 갱신
  - 프로젝트 루트 구조를 git 추적 항목 기준으로 정리
- `.gitignore`
  - `CLAUDE.md` ignore 규칙 제거

### 상세검색 다중선택 키보드 처리 보정

상태: 완료

변경:
- `lib/widgets/search_filter_sheet.dart`
  - Enter/숫자패드 Enter 입력 시 먼저 `onTap()`을 실행하도록 조정
  - 이미 선택된 항목이 아니어도 키보드로 선택 토글 + 제출이 일관되게 동작하도록 수정

### 신고리스트 상세검색 AND/OR + 다중선택 공통 적용

상태: 완료

변경:
- `lib/providers/report_provider.dart`
  - `ReportFilter`의 `rating` / `status` 단일값을 `ratings` / `statuses` 다중값으로 확장
  - `_contains()`에 `&` = AND, `,` = OR 검색 문법 적용
  - `availableStatuses` 추가: 현재 로드된 신고 목록에서 distinct 처리상태를 추출
  - `ReportProvider._applyFilter()`가 목록 공통 필터이므로 Client(server) 모드와 Standalone 모드에 동시에 반영
- `lib/widgets/search_filter_sheet.dart`
  - 상세검색 상단에 `&` / `,` 안내 문구 추가
  - `처리상태`, `별점`을 다중선택 드롭다운 UI로 변경
  - 선택된 항목 우측에 초록 `v` 표시
  - `report_list_screen.dart`, `search_screen.dart`가 공유하는 필터 시트에 동일 동작 적용

## 2026-05-02

### 문서 역할 분리 정리

상태: 완료

변경:
- `CLAUDE.md`
  - 세션별 작업 이력 섹션을 제거하고 구조/작동 방식/운영 메모만 남기도록 정리
  - 작업/버그/세션 기록은 `CHANGELOG.md`에만 남긴다는 규칙을 상단에 명시
- `CHANGELOG.md`
  - 기존 `CLAUDE.md`에 남아 있던 작업 이력 잔재는 날짜별 변경 항목 기준으로 이 파일에서 관리하도록 정리

### 신고현황 탭 + sunwi 이식

변경:
- 하단 네비게이션에 `신고현황` 탭 추가. 위치는 `통계`와 `알림` 사이.
- 새 `SunwiScreen` / `SunwiService` / `SunwiPayload` 모델 추가.
- Client 모드에서는 서버 `/api/v1/sunwi/payload` 데이터를 그대로 표시.
- Standalone 모드에서는 안전신문고 통계 API를 직접 순회 호출해 전국 Top5 데이터를 생성.
- 화면 상단에 `ALL CSV 생성`, `TOP5 CSV 생성` 버튼 추가.
- Standalone CSV는 `Documents/mysafetyreport/sunwi/`에 `sunwi_category_all_latest.csv`, `sunwi_category_top5_latest.csv`로 저장.
- 새 탭 삽입에 맞춰 알림/파일/동기화 탭 인덱스를 한 칸씩 뒤로 조정하고, Android `NotificationService` / `WsService` / Flutter `showNotification` 연동 인덱스도 함께 수정.

### DB import 안정화

변경:
- 외부 `.db` import 전에 임시 staging/snapshot을 만들어 `-wal`/`-shm`를 함께 병합하는 경로 추가.
- `LocalDbService.detectDbKind`, `importFromServerDb`, `replaceFromBackup`가 모두 같은 snapshot 규칙을 사용하도록 통일.
- Setup/복원 화면의 파일 선택을 다중 선택 허용으로 바꿔 `.db`와 `-wal`/`-shm`를 함께 staging 가능하게 보강.
- Standalone 복원도 파일 형식을 자동 감지해 모바일 백업은 그대로 복원, 서버 DB는 변환 import 하도록 수정.

### 신고현황/감시목록/파일 탭 사용성 보정

상태: 완료

변경:
- `lib/screens/sunwi_screen.dart`
  - 탭 전환 nonce가 들어와도 모드별 마지막 수집 시각 기준 3시간 TTL 안에서는 캐시를 재사용하고, 3시간 경과 시에만 재동기화하도록 변경
  - 사용자가 직접 새로고침할 때만 TTL을 무시하는 강제 재수집 경로 추가
  - 서버 대시보드와 동일하게 대분류/소분류를 5초마다 자동 전환하고, 수동 이동 시 타이머를 리셋하도록 보강
- `lib/screens/watchlist_screen.dart`
  - 빈 감시목록 안내 문구에 서버 추가 외에도 신고리스트 다중 선택 모드에서 바로 추가할 수 있다는 안내 반영
- `lib/screens/file_browser_screen.dart`
  - Standalone 파일 탭이 `mysafetyreport` 하위 폴더도 표시하도록 로컬 브라우저를 파일 전용 목록에서 폴더 탐색형으로 확장
  - 현재 위치 카드와 상위 폴더 이동 항목을 추가해 `sunwi/` 하위 CSV 폴더에 앱 안에서 직접 진입 가능하게 수정
- `CLAUDE.md`
  - `sunwi` 3시간 TTL/5초 자동 전환과 standalone 파일 탭 하위 폴더 탐색 규칙을 구조 문서에 반영

### Play Console demo 로그인 완화

상태: 완료

변경:
- `lib/services/local_db_service.dart`
  - Play review demo 판정 로직을 공용 helper로 추출
  - demo 계정을 `demo / demo / demo`뿐 아니라 `demo / demo` + 휴대폰번호 공란도 허용하도록 완화
- `lib/screens/setup_screen.dart`
  - 초기 Standalone 로그인에서 휴대폰번호가 비어 있어도 `demo / demo`로 심사용 데모 진입 가능하게 수정
  - 데모 모드 저장 시 내부 phone 값은 기존과 동일하게 `demo`로 유지
- `lib/screens/settings_screen.dart`
  - 재로그인 / 휴대폰번호 갱신 다이얼로그도 같은 demo 판정 규칙을 사용하도록 통일
- `CLAUDE.md`
  - Play Console 심사 계정 안내를 `phone blank allowed` 기준으로 갱신

### 문서 정리

상태: 완료

변경:
- `CLAUDE.md`
  - `ReportProvider` / `search_filter_sheet` 설명에 새 검색 규칙 반영
  - 신고리스트 상세검색이 Client(server) / Standalone 공통 로직임을 명시
- `CHANGELOG.md`
  - 모바일 레포 최초 생성
  - 기존 `CLAUDE.md`의 주요 작업 이력을 이 파일로 이관

## 2026-04-27

### 버그 수정 묶음

변경:
- Client 파싱 강건화: 서버가 `''`를 보내는 경우도 `Report.fromJson`, `AgencyStats.fromJson`이 안전하게 파싱하도록 보강
- Standalone DB 백업 일관성: WAL 환경에서 최신 별점/사유 누락이 없도록 `LocalDbService.exportBackup()`에서 flush 후 복사
- Client → Standalone 전환 시 최신 백업 자동 탐색을 제거하고 `.db` 직접 선택 방식으로 변경
- 파일 브라우저 정렬을 standalone 로컬 파일 / client 서버 파일 모두 파일명 내림차순으로 통일
- Standalone 외부 저장소 파일은 temp 디렉토리 복사 후 열도록 변경
- Client → Standalone 전환 시 남아 있던 `WsService`를 즉시 정지하도록 보강

### Play Console 심사용 데모 모드

변경:
- `demo / demo / demo` 자격증명으로 실제 로그인 없이 예시 신고 3건 시드 후 진입
- `ReportProvider.isStandaloneDemo` 추가: keep-alive, pending queue drain, 실제 sync, 자동 재로그인 차단
- 동기화 화면에서 데모 안내 카드 표시, 동기화/재동기화 버튼 비활성화
- 재로그인 다이얼로그에서도 동일한 데모 자격증명으로 재진입 가능

### Android 빌드/릴리즈 정리

변경:
- `.github/workflows/build-apk.yml` 유지: VERSION → `pubspec.yaml` 동기화 후 Docker 기반 APK/AAB 빌드
- 로컬용 `build_android_release.sh` 추가: CI와 같은 경로/키스토어 마운트로 release APK/AAB 동시 빌드
- `build_test_apk.sh`는 debug/간이 release 용으로 유지

## 2026-04 기존 이관 기록

- Standalone 모드 신규 구현: 안전신문고 직접 로그인(RSA + OAuth), 자동 재로그인, sqflite 로컬 DB, 증분 sync, 카드 시트
- Kotlin `NotificationService`가 SPP 신고번호를 큐에 적재하고 Flutter drain으로 넘기는 알림 큐 인프라 구축
- Legacy SharedPreferences 손상 이슈를 CSV 큐 형식과 `MainActivity` 마이그레이션으로 해결
- Standalone `refreshAll()`의 `Future.wait`를 순차 await로 바꿔 sqflite 단일 connection 충돌 완화
- `CrawlScreen`이 sync/log 이벤트를 항상 구독하도록 조정해 실행 상태 가시성 개선
- 사용자 용어를 `단건`에서 `개별`로 통일 (`ChangeType.individualConfirm` 등)
- 중복차량 정렬을 서버와 동일한 `max(신고번호) DESC → 차량번호 ASC → 신고번호 DESC`로 맞춤
- Standalone 전용 그린 테마 도입: `appMode`에 따라 MaterialApp 시드 컬러 동적 전환
- Android 15 edge-to-edge 대응
- xlsx 열기 실패 시 `share_plus` 공유 sheet로 fallback
- `SyncEngine.emitDone`로 개별 sync 완료 신호를 명시해 `_isRunning` 고착 버그 수정
- `SyncForegroundService`로 drain/sync 중 프로세스 보호
- drain 시 per-item 제거 방식으로 바꿔 앱 종료 시 큐 항목 영구 손실 방지
- 사용자 요청에 맞춰 개별 fetch + 증분 fallback 1회 구조로 단순화
- dead `standalone_sync_pending` 제거, ChangeType 상수화, `_drainAndRefresh()` 추출
- 설정 화면에 GitHub issues 버그 제보 버튼 추가
- standalone → client 자동 백업, client → standalone 3-way 선택, 서버 DB → 모바일 DB 변환 경로 추가
- standalone 로그인 Step 3과 Client `downloadDb`에 retry/timeout 매트릭스 보강
- `main` 브랜치 병합으로 1.0.7+11 누적 변경, 권한/개인정보처리방침 정리 반영
