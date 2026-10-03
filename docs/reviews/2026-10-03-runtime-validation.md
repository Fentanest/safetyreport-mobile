# 대용량·사유 입력·Client 호환·DB 저장 위치 검증

## 범위와 환경

기준은 최신 dev `bc9b3b48`이다. 기존 사용자 파일을 보존하고 별도 작업 브랜치에서 변경했다. 서버 저장소는 계약/구현/왕복 도구 확인에만 사용했다. 제품 VERSION, 서명, 배포 경로는 바꾸지 않았다. 실제 크롤링·별점 제출·운영 업로드·push·배포를 수행하지 않았다.

측정은 Flutter **3.47.5 / Dart 3.13.4**, Android 15/API 35 `sdk_gphone64_x86_64` 에뮬레이터, 4 vCPU/2 GB RAM, 1080×2400@420, SwiftShader/Impeller OpenGLES의 **profile** APK에서 했다. 호스트는 공유 EPYC 7352 환경(노출 CPU 16개)이다. 테스트 application ID는 `.fixture2`로 운영 앱과 분리했다. 외부 네트워크는 fixture HttpOverrides로 차단했다. 후속 실제 UI 도구 검사/최종 집계는 같은 AVD의 메모리를 4 GB로 늘려 재부팅했다(실제 MemTotal 4,014,420 kB). 2 GB와 4 GB 수치를 구분한다. largeHeap/제품 설정은 변경하지 않았다. 소프트웨어 GPU와 호스트 부하 영향을 받으며 S24/실기기 제품 성능으로 일반화할 수 없다.

`tool/large_data_fixture.dart`는 0/1/3,000/58,388/100,000/500,000건을 SQL 배치로 생성한다. 다년 날짜, NULL/결과 미상/일부수용/취하, 40기관·200담당자, 확정/검토 중복군, 긴 신고내용과 별도 긴 raw payload를 포함한다. 원문·수정값·중복 메타·교환 컬럼은 보존한다. `SR_LARGE_TEST=1`은 실제 50만 건까지 실행했으며 기본 단위 테스트의 작은 자료와 구분한다.

## 1. 대용량 진단·수정

기존 registry compute/스냅샷 캐시는 실제 `Report.fromJson`, `_rowToReport`, 통계 기관 키 경로에서 적용되고 있었다. 그 뒤에도 `computeSummary`가 전체 projected rows/Report를 만들고 통계/overview가 반복 계산하는 비용은 남아 있었다. CHANGELOG의 registry 개선만으로 해결됐다고 판정하지 않았다.

`local_db_service.dart`를 SQL 전체 COUNT/조건 집계, narrow TEMP GROUP BY 스냅샷, 1,000행 스트림, 200개 목록 페이지, native 공간 셀로 전환했다. 원문을 통계 projection에서 제외했고 기관/처분/날짜/결측 의미는 기존 가중치 누산 및 공통 벡터로 대조했다. `report_provider.dart`와 각 화면은 revision/dataset epoch/요청 sequence로 캐시·늦은 결과를 제어한다. 지도 전체 메타와 표시 셀 예산을 구분하며 미리보기 제한을 전체 통계로 표시하지 않는다. `performance_trace.dart`에 SQL/반환 행/HTTP·JSON/Report/registry·차트/Provider/마커/build 계측을 추가했다.

빠른 화면 이동을 실제 렌더로 검사하다가 취소된 통계 화면들이 CTAS를 native 큐에 먼저 넣어 누적시키는 경로를 발견했다. Sqflite 스레드 CPU 시간이 약 10분으로 늘어났고 뒤의 조회가 기다렸다. 이는 한 SQL의 교착으로 단정할 근거가 아니다. Dart 진입 직렬화와 실행 직전 취소 재확인으로 폐기된 화면의 native 작업을 건너뛴다. 지도도 트랜잭션 대기 후 취소를 확인한다. 20개 폐기 조회 회귀 테스트는 실제 GROUP BY가 최초/최종 두 번만 실행됨을 확인한다. 이미 실행 중인 CTAS 한 번은 sqflite에서 즉시 중단할 수 없다.

### 측정값

아래는 각 시점의 실제 profile 기록이다. 초기 구현 측정과 최종 변경을 같은 빌드라고 주장하지 않는다. cold는 해당 프로세스/필터의 결과 캐시가 없는 집계이며 Linux 파일 캐시 cold를 보장하지 않는다. summary 전체/overview의 취하 제외 의미는 기존과 같아 모집단 수가 서로 다를 수 있다.

| 단계 / 자료 | 요약 cold / warm ms | 통계+overview cold / warm ms | 지도 cold / warm ms | peak RSS |
|---|---:|---:|---:|---:|
| dev 기준 58,388 | 10,496 / 5,465 | 41,299 / 37,918 | 미측정 | 744 MiB |
| SQL 전환 58,388 | 557 / 524 | 4,156 / 1 | 709 / 602 | 357 MiB |
| SQL 전환 100,000 | 922 / 885 | 6,954 / 1 | 966 / 1,053 | 395 MiB |
| 500,000 초기 구조 변경 | 8,399 / 6,042 | 36,778 / 2 | 5,556 / 5,592 | 550 MiB |
| 500,000 covering index/캐시 중간 검증 | 4,653 / 16 | 54,105 / 2 | 10,555 / 6,643 | 494 MiB |
| 500,000 후속 재측정(2 GB, 호스트 fixture 동시 실행) | 19,586 / 6 | 46,751 / 1 | 9,844 / 1 | 512 MiB |
| 500,000 covering ID/메타 캐시(4 GB, 취하 제외 기본값) | 972 / 1 | 35,194 / 3 | 5,263 / 2 | 620 MiB |
| 500,000 최종 요약 취소 보완(4 GB, 기본 필터) | 1,875 / 1 | 37,521 / 1 | 5,976 / 1 | 597 MiB |

58,388건의 2초 목표는 이 에뮬레이터의 SQL 전환 측정에서 충족했다. 50만 건 5초 목표는 중간 한 측정에서 충족했지만 반복 cold에서 안정적으로 충족하지 못했다. 첫 기존 DB의 추가 인덱스 준비 25,744 ms도 별도 비용이며 집계 4,653 ms와 합하면 약 30.4초다. 최종 4 GB 검증은 DB 재사용/초기 조회·인덱스 확장 준비 13,633 ms, 요약 972 ms로 이 두 단계 합계 14,605 ms였다. registry 준비 2,139 ms는 별도다. 요약 집계 자체는 5초 목표를 충족하지만 최초 준비 전체는 그보다 길다. 2 GB 직전 covering count 검증은 5,136 ms로 여전히 목표 미달이었으며 4 GB 결과를 같은 조건의 개선률로 계산하지 않는다. 최종 covering ID 정렬은 긴 원문 조회를 200개로 제한한다. 50만 건 통계 cold는 약 35~66초로 느리다. 높은 날짜/담당자 조합으로 GROUP BY 압축률이 낮고 native CTAS/페이지 변환/가중치 차트 계산이 주요 비용이다. 마지막 요약 취소 보완 빌드에서는 DB 초기 조회 614 ms(이미 인덱스 준비됨), 요약 1,875 ms, registry 2,655 ms였다. 캐시 warm 수치로 cold 문제를 해결했다고 주장하지 않는다.

프로세스 RSS는 native/VM/그래픽 등을 포함한다. VM service `getMemoryUsage`에서 한 50만 건 완료 시 Dart heap 사용 84,808,752 bytes, capacity 89,714,688 bytes, external 548,528 bytes를 기록했다. 강제 GC를 하지 않았다. 해당 시점의 native PSS/RSS는 별도 `dumpsys meminfo` 증거에 있다. 최종 4 GB의 실제 화면 반복 중 VM heap은 133,049,008 bytes/capacity 138,215,424 bytes/external 577,408 bytes였다(강제 GC 없음). 다른 측정 시점이며 순수 집계 완료 heap과 혼합하지 않는다. 해당 4 GB dumpsys는 total PSS 364,837 kB/RSS 493,752 kB/swap 0 kB, native heap PSS 141,975 kB였다. 이전 실제 화면 반복 중 native 큐 누적 시 RSS가 약 859 MiB까지 늘어난 것은 위 순수 집계 peak와 별개의 상황이다. debug/host 단위 테스트 시간은 제품 성능으로 보고하지 않는다.

### 종료 원인의 구분

S24 제보의 OOM/ANR/Dart 예외/native 종료/SQLite 오류/지도 렌더 원인은 **실기기 로그가 없어 미확정**이다. fixture의 집계는 정확한 전체 건수와 bounded 전달을 검증했다. 초기 실제 지도 반복 중에는 에뮬레이터의 `system_server` GNSS watchdog이 `GnssNative.native_stop`에서 막혀 종료되고 이어 Geolocator JNI 오류가 발생했다. 선택 로그를 별도 보관했다. 이는 S24 종료와 동일한 원인이라는 증거가 아니다. 이후 GPS를 끄고 화면 반복을 검사했다. live GNSS는 미검증으로 남긴다.

실제 동기화 네트워크와 전체 중복군 재생성 파이프라인은 실행하지 않았으며 writer 테스트는 합성 로컬 수정이다(최종 SR_LARGE_TEST=1 snapshot 검사도 500,000건에서 실행). 기존 duplicate inventory 재생성의 raw 전량 경로는 화면 집계 경로와 별개로 남아 있고 전체 동기화의 50만 건 메모리 검증은 미완료다.

네트워크 없는 로컬 집계(지도 tile HTTP도 fixture에서 차단, 배경 tile 다운로드는 미검증), 연속 필터/취소, 같은 건수 수정·삭제, 동시 writer/snapshot, 실제 탐색·회전·백그라운드 복귀를 구분한다. 첫 20회 UI 기록은 제어/뒤로가기 성공만 검사해 데이터가 준비됐다는 증거가 부족했다. `--wait-data`를 추가하여 차트/모집단/지도 메타 준비를 별도로 요구한다. 2 GB의 data-ready UI 검사는 첫 지도 대기 중 UIAutomator가 종료 코드 137로 종료돼 실패했다. 앱 자체의 S24 OOM 원인으로 단정하지 않는다. 최종 4 GB에서는 실제 대시보드 모집단/통계 차트/지도 메타 준비, 지도 뒤로가기를 매번 확인한 20회가 **469.69초**에 통과했고 HOME 후 복귀도 통과했다. 이 시간은 UiAutomator 여러 번 캡처/외부 adb 입력/대기를 포함한 검사 전체 시간이며 화면 진입 지연으로 계산하지 않는다. GPS는 꺼져 있었다. 마지막 소스에서 연도 버튼 20회 연속 입력→대시보드 이동→통계 복귀는 15.83초 검사에 통과했다. 회전 시 stats-list PageStorageKey가 스크롤 위치를 유지해 화면 밖 차트의 접근성 문구를 기다리는 자동 oracle은 시간 초과했다. 상단으로 스크롤한 후 portrait에서 차트/166,334건이 모두 보임을 다시 확인했다. 최종 방향 XML rotation=1의 XML에 166,334건이 유지되고, 스크롤한 가로 화면에서 상세 기관 41곳이 표시됨을 확인했다. rotation=0 복귀에서 월별 처리 추이 표시를 다시 확인했고 실제 스크린샷을 보관했다. 페이지 스크롤과 회전 모두 가능했다.

Client 대시보드/통계는 기존 집계 API를 사용한다. 서버의 정본 category page/viewport map API를 연결했다. 다만 현재 서버 summary watchlist, watchlist/duplicate/missing 상세는 전량 또는 복합 필터 페이지 계약이 부족하다. 복합 필터는 후보 페이지 범위라고 명시한다. 이 부분의 50만 건 Client 전체 기능 완료는 **서버 추가 계약 필요**이며 [구체적인 인계](../architecture/client-read-handoff.md)에 요청/응답/벡터를 적었다. 서버를 직접 수정하거나 없는 API를 가정하지 않았다.

## 2. 별점 사유 입력

`widgets/rating_dialog.dart`, `selection_action_bar.dart`, Provider의 제출/draft 처리를 수정했다. 고정 높이 입력과 버튼의 경쟁을 없애고 AlertDialog의 스크롤 내용과 actions를 분리했다. 가로/큰 글꼴/키보드로 높이가 부족하면 입력과 actions를 좌우 배치한다. TextField GlobalKey로 레이아웃 전환 중 포커스와 내용을 보존한다. viewInsets는 Dialog가 한 번 적용한다. 기존 1,000 rune/개행/서버·Standalone 의미를 유지하며 취소는 제출하지 않고 중복 실행은 guard한다. 오류 draft는 유지한다.

360×640/640×360, light/dark, 글꼴 1.0/1.3/2.0, 키보드 열기/닫기, 여러 줄·emoji·길이 초과를 위젯 검사했다. Android 15 profile에서 실제 IME의 세로 1.0, 가로 1.3/2.0를 확인했다. 처음 가로 2.0에서 버튼은 보이지만 입력 높이가 0으로 줄어든 문제를 스크린샷으로 발견해 adaptive 배치를 수정했다. 수정 후 입력 두 줄과 취소/확인이 모두 IME 위에서 보인다. 스크린샷은 fixture이고 실제 별점 제출은 하지 않았다. 다른 IME/실기기는 미검증이다.

## 3. 서버 호환 차단

`contracts/selfhost-compat/`는 PC 정본과 바이트 동일하게 복사했다. `client_compatibility.dart`, Dart `server_contract.dart`/ApiService/로그 WS/미디어 경로, Kotlin ServerContract/ServerVersionCompatibility/WsService/NotificationService에 protocol 3을 적용했다. 실제 제품 버전 2.0.0+31을 유지한다. 인증된 GET version에서 major≥3 + protocol_version=3 + supported_client_protocols에 3 포함을 모두 요구한다. 네트워크/TLS/DNS/timeout/401과 구형/메타 누락을 구분한다. HTTP 409 및 WS 4406은 사용자 업데이트 조치로 안내하며 무한 재연결을 중단한다. 주소/키 세대와 lease로 오래된 성공을 다른 서버에 쓰지 않는다. native 재연결도 검사한다. Standalone은 self-host gate 대상이 아니다.

HTTP 헤더와 WS 인증/query 필드, PC 3.0.0.0/dev 형식, 누락/2.x/미지원 protocol/409를 fixture 공통 벡터와 Kotlin 단위 테스트로 확인했다. 첨부 영상·이미지도 동일 서버 origin만 키/헤더를 붙이며 타사 origin에 키를 전송하지 않는다. 로컬 DB를 삭제하지 않고 차단 시 과거 Client 화면 자료를 최신 서버처럼 유지하지 않는다. 운영 서버 연결/실제 기존 1.5.3 서버 차단은 수행하지 않았다. 서버 측 구형 앱 차단은 PC 담당 작업이다.

## 4. DB 완료·저장 위치

`db_export_location.dart`, Kotlin `DbExportLocation.kt`/MainActivity, settings의 Client 다운로드와 Standalone 내보내기를 연결했다. 정상 내보내기 파일만 private staging cache에 만든 뒤 공유 Downloads/mysafetyreport(API29+) 또는 사용자가 선택한 SAF(API28 이하)로 스트리밍 publish한다. 운영 DB 경로를 직접 노출하지 않는다. MediaStore pending/실패 삭제, SAF 취소, 64 KiB copy, 파일 크기 확인으로 불완전 파일을 완료 표시하지 않는다. 광범위 저장소 권한을 추가하지 않았다.

포그라운드는 파일명/실제 위치/완료 및 저장 위치 열기·파일 열기·공유 동작을 제공하고 기본 Files 위치로 안내한다. 실제 document URI 변환이 지원되면 initial URI를 사용하고 아니면 Downloads 화면으로 폴백한다. 백그라운드는 다른 앱을 강제로 열지 않고 완료 알림 탭의 PendingIntent로 안내한다.

Android 15 profile에서 Standalone 50만 건 정상 내보내기 **769,716,224 bytes**를 MediaStore에 저장했다. 실제 URI/name/path, `is_pending=0`, 크기와 기본 DocumentsUI Downloads 전환을 확인했고 mysafetyreport 폴더에서 정확한 파일명을 확인했다. pulled fixture DB는 SQLite quick_check=ok, reports/raw 각각 500,000건이었다. 특정 파일 강조는 이 AVD에서 보장되지 않아 Downloads 폴백과 파일명 안내를 사용했다. DB 형식 열기와 위치 안내를 분리한다. 삼성 내 파일/SAF28/실제 백그라운드 알림 탭/운영 Client 다운로드는 미검증이다. 실패·취소·파일 앱 없음·공유·백그라운드 강제 실행 금지는 Dart fixture 테스트로 검사했다.

## 검증 실행과 증거

증거 폴더: [runtime-validation](2026-10-03-runtime-validation/).

| 검사 | 실행 결과 |
|---|---|
| flutter analyze | 오류 0. 기존 warning 9/info 10 유지, 기존 종료 코드 1. dev 시작 warning 9/info 15보다 감소 |
| 전체 flutter test | 860 passed / 14 skipped (골든 폰트/태그 등 기존 환경 제한 포함) |
| SR_LARGE_TEST=1 | 0/1/3천/58,388/10만/50만 및 필터 parity, 7 passed; host 시간은 성능 수치 아님 |
| Kotlin :app:testDebugUnitTest | 공통 호환 벡터·헤더·메시지 4 tests passed |
| DB 양방향 roundtrip | 모든 교환 컬럼/NULL/원문/raw/수정값/메타/중복: diff_count=0 |
| PC↔모바일 공통 통계 parity | 44조합 diff=0; 기존 표시 전용 one-side key 차이는 계약 도구 기록 유지 |
| 동시 writer/native snapshot(500,000건 포함)/취소 burst/covering watch count/year NULL drilldown/viewport 메타 재사용/대기 요약 취소 | 6 passed |
| 실제 50만 건 UI | 데이터 준비 포함 20회/뒤로가기/백그라운드 복귀, 연도 연속 변경 후 복귀, 스크롤·회전 데이터 표시 통과; 화면 밖 차트 oracle 실패 별도 기록 |
| profile APK | 격리 fixture application ID로 빌드/설치 성공; 제품 버전 변경 없음 |

배포·push는 하지 않았다. 마지막 소스 변경 후 해당 검사와 profile 증거를 갱신한 범위만 완료로 보고하며, 위의 서버 계약·실기기·cold 성능 제한은 남아 있다.
