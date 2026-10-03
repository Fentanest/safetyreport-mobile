# 대용량 화면 조회와 Client 호환·DB 내보내기

이 문서는 현재 구현의 읽기 수명과 계약을 설명한다. 실행 증거와 미검증 항목은
[검증 기록](../reviews/2026-10-03-runtime-validation.md), 서버의 추가 작업은
[Client 조회 계약 인계](client-read-handoff.md)를 참조한다.

## 집계와 표시 모집단

- 대시보드 `computeSummary`: 전체 모집단의 SQL COUNT/조건 집계와 최근 답변·감시 목록 각각 최대 200건 미리보기다. `watchlistTotal`은 표시 목록 길이와 독립적이다. 전체 신고 수와 처분 계산은 기존 의미를 유지한다. 상태·금액 수정값은 원문 위에 COALESCE한다. 감시 목록은 확정 중복군의 어느 구성원이 감시 중이어도 대표건에 적용한다.
- `computeStatsBundle`: 원문·신고내용·처리내용을 제외한 최소 통계 컬럼을 SQLite TEMP GROUP BY로 스냅샷화한다. 날짜/금액/추정 규칙/기관 해석은 기존 Dart 계산을 가중치와 합계·개수 형태로 유지한다. native 결과를 1,000그룹씩 받아 처리하고 매 페이지 이벤트 루프에 양보한다. 전체 Report 객체나 전체 행 리스트를 UI isolate에 보관하지 않는다. 상세 기관표와 통계 overview가 같은 집계 결과를 공유한다. 고유 날짜·담당자 조합이 많으면 GROUP BY 압축률이 낮아 전체 narrow 행을 순차 처리할 수 있다. 이는 표본 추출이 아니다.
- 기관 registry의 기존 `compute` 초기화와 링크/키 캐시는 실제 통계·Report 경로에서 유지된다. registry 캐시만으로 원문·전체 Report 로딩 문제를 해결하지는 못한다.
- 리스트/별점/감시 목록/중복차량/주소 상세(Standalone)는 전체 SQL COUNT와 200건 페이지 조회를 분리한다. 선택은 현재 페이지 범위이며 버튼에 이를 표시한다. 표는 기존 lazy ListView를 유지한다. Client 기본 신고·별점 후보는 정본 페이지 API를 사용한다. 서버의 복합 필터·감시·중복 페이지 계약은 아직 부족하므로 [인계](client-read-handoff.md)의 제한을 적용한다.
- 지도: 전체 모집단의 메타 COUNT와 화면 범위의 32×32 공간 셀을 분리한다. 셀은 최대 1,024개, 원본 좌표는 변경하지 않는다. 여러 주소가 합쳐진 점은 cluster이며 탭하면 확대한다. 확대·이동 때 debounce 후 현재 범위를 다시 조회한다. centroid 주소를 실제 한 주소의 상세 목록으로 취급하지 않는다. 서버는 정본 `/stats/map/points`를 사용하며 1,200개 이하 반환을 검사한다. 누락 주소 그룹/미리보기는 Standalone에서 페이지화된다.

SQLite 요약·지도 읽기는 `exclusive:false` 트랜잭션의 일관된 스냅샷이다. 지도 트랜잭션은 셀 페이지를 소비할 때까지 유지하여 동기화 writer가 기다릴 수 있다. 통계는 native CTAS 완료 후 원본 읽기 잠금을 놓고 TEMP 데이터를 소비한다. `runBackgroundWork`/close guard가 DB 복원·내보내기와 읽기 수명을 보호한다. 사용자가 화면을 벗어나면 통계/지도는 페이지 경계에서 취소하고 TEMP 표를 정리한다. 통계 진입은 Dart에서 직렬화하고 실행 직전 취소를 확인하여 빠른 탐색으로 버린 화면마다 CTAS가 native 큐에 쌓이지 않게 한다. 지도도 트랜잭션 대기 후 취소를 재확인한다. 이미 실행 중인 native SQL 자체의 즉시 중단은 지원하지 않는다.

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
