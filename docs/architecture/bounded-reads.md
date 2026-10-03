# 대용량 화면 조회와 Client 호환·DB 내보내기

이 문서는 현재 구현의 읽기 수명과 계약을 설명한다. 실행 증거와 미검증 항목은
[검증 기록](../reviews/2026-10-03-runtime-validation.md), 서버의 추가 작업은
[Client 조회 계약 인계](client-read-handoff.md)를 참조한다.

## 집계와 표시 모집단

- 대시보드 `computeSummary`: 전체 모집단의 SQL COUNT/조건 집계와 최근 답변·감시 목록 각각 최대 200건 미리보기다. `watchlistTotal`은 표시 목록 길이와 독립적이다. 전체 신고 수와 처분 계산은 기존 의미를 유지한다. 상태·금액 수정값은 원문 위에 COALESCE한다. 감시 목록은 확정 중복군의 어느 구성원이 감시 중이어도 대표건에 적용한다.
- `computeStatsBundle`: 원문·신고내용·처리내용을 제외한 최소 통계 컬럼을 SQLite TEMP GROUP BY로 스냅샷화한다. 날짜/금액/추정 규칙/기관 해석은 기존 Dart 계산을 가중치와 합계·개수 형태로 유지한다. native 결과를 1,000그룹씩 받아 처리하고 매 페이지 이벤트 루프에 양보한다. 전체 Report 객체나 전체 행 리스트를 UI isolate에 보관하지 않는다. 상세 기관표와 통계 overview가 같은 집계 결과를 공유한다. 고유 날짜·담당자 조합이 많으면 GROUP BY 압축률이 낮아 전체 narrow 행을 순차 처리할 수 있다. 이는 표본 추출이 아니다.
- 기관 registry의 기존 `compute` 초기화와 링크/키 캐시는 실제 통계·Report 경로에서 유지된다. registry 캐시만으로 원문·전체 Report 로딩 문제를 해결하지는 못한다.
- 검색/데이터 수정/리스트/별점/감시 목록/중복차량/주소 상세(Standalone)는 전체 SQL COUNT와 200건 페이지 조회를 분리한다. 선택은 현재 페이지 범위이며 버튼에 이를 표시한다. 표는 기존 lazy ListView를 유지한다. Client 기본 신고·별점 후보는 정본 페이지 API를 사용한다. 서버의 복합 필터·감시·중복 페이지 계약은 아직 부족하므로 [인계](client-read-handoff.md)의 제한을 적용한다.
- 지도: 전체 모집단의 메타 COUNT와 화면 범위의 32×32 공간 셀을 분리한다. 셀은 최대 1,024개, 원본 좌표는 변경하지 않는다. 여러 주소가 합쳐진 점은 cluster이며 탭하면 확대한다. 확대·이동 때 debounce 후 현재 범위를 다시 조회한다. centroid 주소를 실제 한 주소의 상세 목록으로 취급하지 않는다. 서버는 정본 `/stats/map/points`를 사용하며 1,200개 이하 반환을 검사한다. 누락 주소 그룹/미리보기는 Standalone에서 페이지화된다.

SQLite 요약·지도 읽기는 `exclusive:false` 트랜잭션의 일관된 스냅샷이다. 지도 트랜잭션은 셀 페이지를 소비할 때까지 유지하여 동기화 writer가 기다릴 수 있다. 통계는 native CTAS 완료 후 원본 읽기 잠금을 놓고 TEMP 데이터를 소비한다. `runBackgroundWork`/close guard가 DB 복원·내보내기와 읽기 수명을 보호한다. 사용자가 화면을 벗어나면 통계/지도는 페이지 경계에서 취소하고 TEMP 표를 정리한다. 통계 진입은 Dart에서 직렬화하고 실행 직전 취소를 확인하여 빠른 탐색으로 버린 화면마다 CTAS가 native 큐에 쌓이지 않게 한다. 지도도 트랜잭션 대기 후 취소를 재확인한다. 이미 실행 중인 native SQL 자체의 즉시 중단은 지원하지 않는다.

## 화면 사전 로딩과 중복 재계산

대시보드는 요약 뒤 카테고리 전체를 사전 로딩하지 않는다. 검색·데이터 수정은 같은 200건 페이지 컴포넌트를 사용하고, legacy Provider 카테고리 메서드도 200건 preview만 보관한다. preview를 전체 집계처럼 표시하지 않는다. Standalone 필터의 법규·상태 선택지는 전체 effective view의 DISTINCT 두 컬럼에서 가져온다. Client 법규 선택지는 기존 compact stats/overview를 사용한다. 표준 상태와 페이지에서 발견한 상태는 유지하지만 서버의 전체 custom status DISTINCT 계약은 아직 없다. 알림의 미상 카테고리는 Standalone 단건 조회, Client 정본 raw page 순차 탐색(한 페이지만 보관)으로 찾는다.

`bounded_duplicate_rebuild.dart`는 동기화 후 중복 재계산에도 전량 raw/Report inventory를 만들지 않는다. 원문 해시와 기존 우선순위는 128건 projection → worker isolate → 작은 digest로 계산한다. `sr_duplicate_input_v1`과 revision 표는 폐기 가능한 파생 자료이며 원문을 저장하지 않는다. source/decision/member/group의 persistent 트리거는 다른 연결의 수정도 반영한다. 같은 건수 수정은 해당 digest를 지우고, 삭제·복원은 ID/rowid를 현 DB에서 다시 확인한다. 빈 결과에도 built_revision을 기록하여 중복군 없는 DB를 진입마다 재계산하지 않는다. 최초 hash 인덱스는 bulk digest 후 만든다.

native TEMP 표에서 그룹·멤버·정렬/충돌을 구성한다. 기존 Dart List.sort의 동률 결정까지 보존하기 위해 그룹별 `<field hash,count>`만 worker에 보내며, UI는 128개씩 보내고 acknowledgment를 기다린다. 거대한 Report/원문 리스트를 isolate 사이에 복제하지 않는다. 거대 그룹의 hash 목록은 worker에 남을 수 있다. staging 연결에서는 main DB의 긴 write 트랜잭션을 잡지 않는다. 최종 파생 표는 private 임시 SQLite로 전달하고 shared 연결의 큐에서 revision 재확인 후 원자적으로 교체한다. 재계산 중 변경되면 staged 결과를 버리고 최대 3번 다시 계산한다. TEMP/첨부 staging/연결은 실패·완료 시 정리하고 close guard가 복원·내보내기를 보호한다.

실제 Android sqflite 연결은 단일 reader pool/TRUNCATE로 관찰되었다. PRAGMA WAL 요청만으로 Android open flags와 pool이 바뀐다고 가정하지 않는다. 독립 publisher가 main write lock을 오래 잡지 않게 하는 방식과 실제 공유 연결의 동시 요약 완료를 검증했다. 마지막 publish SQL은 native 큐를 점유할 수 있고 즉시 취소 API는 없다.

Standalone 중복 관리: 전체 상태 COUNT와 50그룹 페이지, 각 그룹 50명 preview/상세/대표 후보 페이지를 분리한다. 수동 대표 선택은 membership 단건 검사 후 저장하므로 후보 전체를 재정렬하지 않는다. 알림 payload에는 대표 메타·실제 member_count·deferred 표시만 넣으며 원문/전체 멤버를 SharedPreferences에 복제하지 않는다. 사진 backfill도 전체 대상을 Report 리스트로 만들지 않고 COUNT 후 ID cursor 128건씩 처리한다. 실패한 행은 다음 실행에서 재시도하며 cutoff와 동기화 대기 의미를 유지한다.

서버 DB 가져오기는 title/detail(legacy merge fallback), entry/raw를 native JOIN projection으로 128건씩 읽고 batch로 대상 DB에 옮긴다. raw 전체 Map을 별도로 보관하지 않는다. 교환 표·NULL·빈 수정값·원문·타입을 보존한다. WAL snapshot의 before-import 백업은 private copy에서 checkpoint/DELETE 후 닫아 sidecar 없이 교환 가능하게 만든다.

## 무효화와 비동기 결과

캐시는 요약 4개, 통계 4개, 지도 8개 및 전체 지도 메타 4개 결과로 한정한다. 키에는 DB 연결 identity, TEMP 쓰기 revision(원문·수정값·중복·sync_meta 트리거), `PRAGMA data_version`(다른 연결의 변경), registry snapshot identity, 필터·중복 모드를 넣는다. 지도 범위/줌, 요약의 현재 날짜도 키에 포함한다. 전체 지도 메타는 viewport와 독립된 scope 키로 재사용하며, viewport 단계가 취소돼도 이미 계산한 작은 메타를 재사용한다. 건수만으로 판정하지 않는다. DB 닫기·복원은 캐시를 비우고 새 연결을 사용한다. 조회 중 revision이 바뀐 결과는 재사용하지 않는다.

Provider의 `datasetEpoch`는 모드·계정·주소/키·게이트·Standalone 공통 필터 변경마다 증가한다. 화면별 요청 sequence와 epoch로 늦게 도착한 결과를 버린다. Client 차단 시 화면 자료를 비우지만 로컬 DB를 삭제하지 않는다. 통계 탭의 TickerMode 비활성화·dispose는 취소를 전달하고 복귀 시 다시 조회한다. 로컬 요약도 트랜잭션 대기 후 취소를 확인한다. 변경 후 refreshAll은 진행 중이던 이전 요약 완료를 기다린 다음 현재 revision으로 다시 조회한다. 로컬 요약의 5초 제한은 제거했다. 5초는 측정 목표이며, 준비 중에도 탐색이 가능하도록 한다.

## 계측

`PerformanceTrace`는 `SR_PERF=true`일 때 로그/Timeline을 남기며 기본은 꺼져 있다. SQL 시간·반환 행 수, HTTP 전송/본문 버퍼링, UTF-8 변환, JSON decode, Report 생성, registry/기관표, chart data, Provider 적용, marker 생성, 화면 build를 분리한다. ProcessInfo RSS/maxRss는 native+VM 등을 포함한 프로세스 값이며 Dart heap이 아니다. Dart heap은 profile VM service `getMemoryUsage`, native/PSS는 `adb shell dumpsys meminfo`로 별도 측정한다. 원문·주소·키는 계측 로그에 넣지 않는다. SQL 큐 대기도 시간에 포함될 수 있으므로 동시 작업 여부를 함께 기록한다.

신규 인덱스는 읽기를 위한 보조 자료이며 제품 DB 버전·교환 컬럼을 변경하지 않는다. 기존 대용량 DB에서 첫 인덱스 준비가 오래 걸릴 수 있다. 최초 준비 시간을 cold 집계 시간에서 감추지 말고 별도 합산해 보고한다.

## 사유 입력

`RatingDialog`의 정상 배치는 스크롤 가능한 AlertDialog와 독립 actions다. 키보드 insets는 Flutter Dialog가 한 번 처리한다. 가로 화면의 키보드+큰 글꼴로 높이가 부족하면 입력 스크롤 영역과 취소/확인을 옆으로 배치한다. 공통 GlobalKey로 TextField의 포커스·입력을 유지한다. 기존 1,000 rune 제한과 개행 정규화는 변경하지 않는다. SelectionActionBar와 Provider의 in-flight guard가 중복 요청을 막고 실패 시 draft를 남긴다. 취소는 제출하지 않는다.

## self-host protocol 3

정본 사본은 [contracts/selfhost-compat](../../contracts/selfhost-compat/README.md)다. 실제 앱 제품 버전은 PackageInfo/Kotlin PackageManager에서 읽으며 protocol 3과 독립적이다. `ClientCompatibility`는 주소+키에 묶인 1분 memory lease 및 single-flight probe다. 실패는 명시적 재확인/설정 변경까지 차단하고 409/WS 4406은 자동 재시도하지 않는다. HTTP 본 요청·multipart·스트리밍 DB·커뮤니티 게이트·로그 WS가 검사하며 Kotlin 이벤트 WS와 알림 HTTP도 각각 검사한다. native 재연결마다 재검증한다. Standalone은 self-host 검사 대상이 아니다.

이미지·native video·다른 앱으로 여는 첨부도 Client에서 설정된 서버 origin에만 호환 헤더와 게이트를 적용한다. 정부/CDN 주소에는 서버 API 키를 보내지 않는다. 파일 형식 열기와 서버 연결 성공은 별개다. 서버 v2/메타 누락/미지원 protocol, API 키 오류, timeout/TLS/DNS는 구분하여 안내한다. 실제 구형 앱 차단은 서버 middleware의 책임이며 이 모바일 변경만으로 운영 서버의 차단을 보장하지 않는다.

## 완료된 DB 파일과 파일 앱

Client는 정상 서버 DB를 `.part` 스트리밍→완료 임시 파일로 만들고, Standalone은 기존 정상 snapshot 내보내기를 이용한다. 운영 DB 경로를 외부로 전달하지 않는다. Kotlin은 canonical 경로가 앱 cache 아래인 완료 `.db`만 받는다. Android 29+는 MediaStore Downloads `Download/mysafetyreport/`, IS_PENDING=1, 64KiB stream, 길이 확인, IS_PENDING=0 순서다. 취소·오류 시 미완료본을 삭제한다. Android 28 이하는 SAF CREATE_DOCUMENT의 실제 선택 URI를 사용한다. 광범위 폴더/전체 저장소 권한은 추가하지 않는다.

완료 결과는 실제 content URI·파일명·저장 위치다. foreground는 완료 Snackbar의 위치 열기와 자동 파일 화면 전환, background는 완료 알림 클릭으로 연다. MediaStore가 돌려준 실제 document URI를 얻을 수 있으면 EXTRA_INITIAL_URI로 시작하고, 얻을 수 없으면 시스템 Downloads/문서 화면으로 대체한다. URI를 파일 경로로 추측하지 않는다. 파일 강조는 파일 앱마다 달라 보장하지 않는다. 위치 열기 실패는 파일명/위치와 파일 열기·공유 대체 동작을 보여 준다.

정식 URI/초기 위치 동작의 근거: [Android 문서 파일 가이드](https://developer.android.com/training/data-storage/shared/documents-files), [MediaStore API](https://developer.android.com/reference/android/provider/MediaStore#getDocumentUri(android.content.Context,%20android.net.Uri)).
