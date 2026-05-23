# 2026-05-23 Client 모드 첫 실행 서버 응답 지연 분석

## 증상

- 앱을 처음 실행했을 때 `Client 모드`에서 대시보드가 `서버 연결 실패: Exception: 서버 응답 지연`으로 한 번 실패한다.
- 같은 화면에서 `다시 시도`를 누르면 정상적으로 로드되는 경우가 많다.

## 원인 분석

결론은 서버 레포의 단일 API 버그보다 모바일 Client 초기화 구조 문제에 더 가깝다.

- 서버 `../safetyreport/web/routers/api_route.py`의 `/api/v1/summary`, `/api/v1/reports/{category}` 라우트는 얇은 래퍼이고, 첫 호출만 별도 warm-up 하거나 지연시키는 분기 로직이 없다.
- 반면 모바일 `lib/main.dart`는 하단 탭을 `IndexedStack`에 미리 올려 두고 있었다. 이 구조에서는 현재 보이지 않는 탭도 첫 빌드 시점에 함께 `initState()`가 실행된다.
- 실제로 첫 실행 직후 아래 화면들이 동시에 네트워크를 시작하고 있었다.
  - `DashboardScreen`: `fetchSummary()`, `ensureCategoryReportsLoaded()`
  - `ReportListScreen`: 교통/주정차/기타/중복 목록 전체 로드
  - `StatisticsScreen`: 통계 로드
  - `NotificationsScreen`: 크롤링 결과 확인
  - `FileBrowserScreen`: 서버 파일 목록 로드
  - `CrawlScreen`: 크롤링 설정/상태 로드
- `ReportProvider.fetchSummary()`는 5초 timeout 뒤 `Exception('서버 응답 지연')`을 던지므로, 첫 진입 시 요청이 몰리면 대시보드 summary가 먼저 timeout으로 터질 수 있다.
- 재시도 시에는 이미 다른 초기 요청이 끝났거나 숨은 탭의 1회성 로드가 지나가 있어 정상 응답으로 보일 수 있다.

## 판단

- 주원인: 모바일 Client 초기 요청 폭주
- 부원인: 같은 데이터를 여러 화면이 겹쳐 요청해도 중복 차단이 없던 구조
- 서버 레포 수정 필요성: 이번 증상 기준으로는 낮음

## 적용한 수정

- `lib/main.dart`
  - `IndexedStack` 자식을 즉시 전부 만들지 않고, 선택된 탭과 한 번이라도 방문한 탭만 lazy build 하도록 변경
- `lib/screens/dashboard_screen.dart`
  - 첫 진입 시 summary를 먼저 await 하고, 카테고리 preload는 그 다음 백그라운드로 넘기도록 순서 조정
- `lib/screens/report_list_screen.dart`
  - 첫 빌드에서 무조건 전체 목록을 다시 때리지 않고 `ensureCategoryReportsLoaded()` 기반으로 완화
- `lib/providers/report_provider.dart`
  - `summary`, 카테고리별 목록, 중복 목록, 감시목록, 앱 설정 로드에 in-flight dedupe 추가
  - 같은 요청이 진행 중이면 새 요청을 추가로 보내지 않고 기존 Future를 재사용

## 기대 효과

- Client 모드 첫 실행 시 대시보드 summary 요청이 숨은 탭 트래픽에 밀려 timeout 나는 가능성을 크게 줄인다.
- 탭 전환 직후나 화면 중복 진입 시 같은 API를 여러 번 연속 호출하던 패턴도 완화된다.

