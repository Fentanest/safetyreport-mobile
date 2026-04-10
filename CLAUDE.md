# 나만의 안전신문고 앱 — 프로젝트 컨텍스트

나만의 안전신문고 Flutter Android 앱. 서버 레포(safetyreport)의 FastAPI `/api/v1/` API를 소비합니다.

## 작업 규칙
- 작업 완료 후: CLAUDE.md에 변경 내용 기록 + 코드 git 커밋
- CLAUDE.md 자체는 git에 커밋하지 않음 (로컬 전용)
- 서버 레포: `/home/better0101/projects/safetyreport`

---

## 디렉토리 구조

```
/
├── lib/
│   ├── main.dart                   # 앱 진입점, IndexedStack 6탭
│   ├── models/
│   │   ├── report.dart             # Report, DashboardStats
│   │   └── agency_stats.dart       # AgencyStats, CategoryStats
│   ├── providers/
│   │   ├── report_provider.dart    # 신고 데이터 상태 관리
│   │   └── notification_history_provider.dart
│   ├── services/
│   │   └── api_service.dart        # HTTP API 호출 (/api/v1/)
│   └── screens/
│       ├── dashboard_screen.dart
│       ├── report_list_screen.dart     # 4탭: 교통/주정차/기타/중복차량
│       ├── statistics_screen.dart      # 18탭 통계 (카테고리×6유형)
│       ├── filtered_list_screen.dart   # 대시보드 카드 → 필터된 목록
│       ├── crawl_screen.dart           # 크롤링 제어 + 실시간 로그
│       ├── notifications_screen.dart   # 크롤링현황 / 신고결과 2탭
│       ├── settings_screen.dart
│       └── file_browser_screen.dart
├── android/app/src/main/kotlin/com/fentanest/mysafetyreport/
│   ├── MainActivity.kt      # MethodChannel (권한, WsService, showNotification)
│   ├── WsService.kt         # 백그라운드 WebSocket Foreground Service
│   └── NotificationService.kt  # 카카오/안전신문고 알림 리스너
├── VERSION                  # 앱 버전 (예: 1.0.0+1)
└── .github/workflows/build-apk.yml  # APK 빌드 + GitHub Release
```

---

## Flutter Report 모델 필드 (fromJson 매핑)
```
id ← 'ID'                    reportNumber ← '신고번호'      name ← '신고명'
date ← '신고일'               responseDate ← '답변일'        agency ← '처리기관'
manager ← '담당자'            status ← '처리상태'            result ← '결과'
fineInfo ← '범칙금_과태료'    penaltyPoints ← '벌점'        carNumber ← '차량번호'
law ← '위반법규'              location ← '위반장소'          occurrenceDate ← '발생일자'
occurrenceTime ← '발생시각'   reportContent ← '신고내용'    processContent ← '처리내용'
attachedPhotos ← '첨부사진'   attachedFiles ← '첨부파일'    mapImage ← '지도'
totalCount ← 'total_count'   validCount ← 'valid_count'
```

---

## 서버 API 엔드포인트 (/api/v1)

인증: `X-API-Key` 헤더 (서버 `/devices` 페이지에서 발급).

| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/summary` | 대시보드 요약 |
| GET | `/reports/traffic` | 교통위반 신고 목록 |
| GET | `/reports/parking` | 주정차위반 신고 목록 |
| GET | `/reports/other` | 기타위반 신고 목록 |
| GET | `/stats` | 기관별/담당자별 통계 |
| GET/POST | `/watchlist` | 감시 목록 조회/수정 |
| POST | `/crawl/enqueue` | 신고번호 큐 등록 (알림 리스너 연동) |
| GET | `/crawl/status` | 크롤링 실행 여부 |
| GET | `/crawl/done` | 완료 마커 조회 (읽으면 삭제) |
| GET | `/crawl/results` | 변경 신고 목록 조회 (읽으면 삭제) |
| GET | `/crawl/config` | crawl_type, crawl_mode, max_empty_pages |
| POST | `/crawl/start` | 모바일에서 크롤링 시작 |
| POST | `/crawl/kill` | 크롤링 강제 중지 |
| POST | `/crawl/resume` | 비회원 로그인 완료 신호 |
| GET | `/app/config` | 앱 설정 (exclude_withdraw, normalize_police 등) |
| POST | `/settings` | 필터 설정 저장 |
| GET | `/files?path=` | 서버 파일 브라우저 (logs/results 한정) |
| GET | `/files/download?path=` | 파일 다운로드 (헤더 또는 쿼리 파라미터 api_key) |
| GET | `/vehicle/{번호}` | 차량번호 검색 |

---

## 하단 탭 구조

| 인덱스 | 탭 | 화면 |
|--------|----|----|
| 0 | 대시보드 | `DashboardScreen` |
| 1 | 신고리스트 | `ReportListScreen` |
| 2 | 통계 | `StatisticsScreen` |
| 3 | 알림 | `NotificationsScreen` |
| 4 | 파일 | `FileBrowserScreen` |
| 5 | 크롤링 | `CrawlScreen` |

---

## Android 서비스 구성

### WsService (Foreground Service)
- OkHttp WebSocket, `pingInterval = 25s` (프로토콜 레벨)
- 재연결 백오프: 3s → 6s → 12s → 24s → 60s
- Foreground 알림: `ws_service` 채널 (`IMPORTANCE_LOW`, 소리 없음)
  - 재연결 중: "서버 연결 대기 중..."
  - 연결됨: "서버 연결됨 ✓"
  - 탭 시 앱 열림 (`getLaunchIntentForPackage` + FLAG_ACTIVITY_SINGLE_TOP)
- `crawl_started`, `crawl_finished` → `ws_push_v2` 채널 (`IMPORTANCE_HIGH`) 알림
- `crawl_changes` → `ws_push_v2` 채널 개별 알림 + `FlutterSharedPreferences`에 `flutter.pending_crawl_changes` 저장
  - 앱 포어그라운드 복귀 시 `main.dart`가 읽어 알림 탭으로 이동 + 카드 뷰 바텀시트 표시
- `START_STICKY` — OS 강제 종료 후 자동 재시작

### MainActivity MethodChannel (`com.fentanest.mysafetyreport/permissions`)
| 메서드 | 기능 |
|--------|------|
| `isNotificationListenerEnabled` | 알림 리스너 활성화 여부 |
| `openNotificationListenerSettings` | 시스템 알림 접근 설정 화면 |
| `startWsService` | WsService 시작 |
| `stopWsService` | WsService 중지 |
| `isWsServiceRunning` | WsService 실행 여부 |
| `showNotification` | 로컬 Android 알림 표시 (폴링 완료 시 보완용) |
| `navigateToTab` | 특정 탭으로 이동 (WS 알림 탭 등) |

### NotificationService (알림 리스너)
카카오톡/안전신문고 알림 인터셉트 → 신고번호 정규식 추출 → `/api/v1/crawl/enqueue`
- 신고번호 패턴: `SPP-\d{4}-\d{6,8}`

---

## 알림 파이프라인

### 경로 1: WsService.kt (백그라운드)
앱 종료 상태에서도 동작:
1. WsService가 `/ws/events?api_key=<key>` 연결 유지
2. `crawl_finished` 수신 → `showPushNotif()` → Android 시스템 알림 (ws_push_v2 채널)
3. 알림 기록 → `FlutterSharedPreferences` → 앱 재시작 시 알림 탭 표시

### 경로 2: 앱 포그라운드 폴링 (보완)
1. 앱 포그라운드 복귀 → `notifications_screen._fetchServerResults()`
2. `/api/v1/crawl/done` 폴링 → 완료 마커 있으면
3. `/api/v1/crawl/results` 조회 → 알림 탭 추가
4. `showNotification` MethodChannel → Android 시스템 알림 (중복 방지 X, WsService 미수신분 보완)

---

## 주요 아키텍처 결정 사항

### 알림 채널 주의
채널 ID별 importance는 **최초 생성 시에만** 설정 가능. 기존 채널 importance 변경 불가.
importance 올릴 때는 채널 ID를 바꿔야 함.
현재 채널: `ws_push_v2` (WsService), `app_push_v2` (MainActivity) — 모두 `IMPORTANCE_HIGH`.

### Flutter SharedPreferences 크로스-프로세스 캐시 주의
Android native(Kotlin)에서 `FlutterSharedPreferences` 직접 쓰기 시 Flutter 캐시에 즉시 반영 안 됨.
Flutter 측에서 `prefs.reload()` 호출 필요 (→ `NotificationHistoryProvider.load()`, `main.dart _checkPendingChanges()` 적용됨).

WsService가 Kotlin 쪽에서 쓰는 SharedPreferences 키:
- `flutter.notifications_history` — 크롤링 시작/완료 알림 기록 (JSON array)
- `flutter.pending_crawl_changes` — crawl_changes 이벤트 수신 시 변경 목록 임시 저장

### 신고리스트 탭 구조 (report_list_screen.dart)
`TabController(length: 4)` — 교통위반 / 주정차 / 기타위반 / 중복차량.
- 교통/주정차/기타: `_buildTab()` — `ReportProvider.filtered*Reports` 표시, 검색필터 적용
- 중복차량: `_buildDuplicateTab()` — `filteredDuplicateReports` (필터 미적용, 서버 정렬 유지)
  - `_buildDuplicateCard()`: 기본 카드 + `totalCount`를 **'N회' 뱃지** (deepOrange)로 표시
- 전체선택 시 중복차량 탭(index 3)은 선택 대상에서 제외

### 알림 탭 구조 (notifications_screen.dart)
`DefaultTabController(length: 2)` 로 두 탭 분리:
- **크롤링 현황**: `extraData == null`인 항목 (크롤링 시작/완료 알림)
- **신고 결과**: `extraData != null`인 항목 (개별 신고 변경 결과) → 탭 시 `ReportDetailSheet` 표시

### 통계 탭 구조 (statistics_screen.dart)
`TabController(length: 18)` — 교통위반 6탭 + 주정차위반 6탭 + 기타위반 6탭.
`_GroupedTabBar` preferredSize.height = 132 (3행).
각 그룹: 기관별 / 담당자별 / 경찰 기관 / 경찰 담당자 / 비경찰 기관 / 비경찰 담당자.
행 클릭 필터: `r.agency == agency` (정확히 일치, `contains` 아님).

### 첨부사진/파일 URL 구분자
DB에서 `\n`(또는 `%0A`) 으로 구분 저장됨. `_splitUrls()`는 `split(RegExp(r'\n|%0A|%0a'))` 사용.

### 이미지 로딩 (report_detail_sheet.dart)
`_RetryableImage` 위젯: `Image.network` 기반, 최대 5회 자동 재시도(1s 간격), 15초 타임아웃.
동영상: `_VideoPlayer` 위젯, seek bar + 재생/일시정지 오버레이 컨트롤.
파일 열기: `http.get` 으로 임시 디렉터리에 다운로드 후 `open_filex`로 ACTION_VIEW 전달.

---

## 빌드

```bash
# Docker로 APK/AAB 빌드
docker run --rm \
  -v ${PWD}:/build \
  -v ~/.pub-cache:/root/.pub-cache \
  -v ~/.android-sdk:/root/Android/Sdk \
  --workdir /build \
  ghcr.io/cirruslabs/flutter:stable \
  bash -c "flutter build apk --release"
```

GitHub Actions: `.github/workflows/build-apk.yml`
- main 브랜치 push 또는 수동 실행
- APK → GitHub Release 업로드
- AAB → 아티팩트로만 업로드 (릴리즈 미포함)
- 태그 중복 시 빌드 스킵

---

## 주요 버그 이력

| 버그 | 원인 | 수정 |
|------|------|------|
| FilteredListScreen parking 카테고리 미처리 | `_getReports()`의 else 분기가 `'parking'`을 traffic+other 합산으로 반환, `initState()`에서 parking prefetch 누락 | `'parking'` 분기 추가, 카테고리별 개별 prefetch로 변경, all 분기에 parkingReports 포함 |
| 모바일 `/api/v1/reports/traffic` 500 | `df.to_dict()` 결과에 pandas `NaN` 포함 → JSON 직렬화 실패 | 서버에서 `df.fillna('')` 후 `to_dict()` |
| 다중 선택 크롤링 1건만 전송 | 건별 `enqueue` 호출 → 첫 번째 이후 "busy" 반환 | `startCrawlQueue(numbers)` 추가 → `crawl/start` + `queue_list`로 일괄 전송 |
| 알림 팝업(heads-up) 미표시 | `IMPORTANCE_DEFAULT` 채널 → heads-up 불가, importance 변경 불가 | 채널 ID `ws_push_v2`, `app_push_v2`로 변경, `IMPORTANCE_HIGH` + `enableVibration` |
| 알림 탭 WsService 기록 미반영 | Flutter SharedPreferences 싱글톤 캐시가 WsService 직접 쓰기 미반영 | `prefs.reload()` 추가 |
| WsService 중지 버튼 앱 크래시 | `stopSelf()` 전 `stopForeground()` 미호출 | `stopForeground(true)` 추가 |
| 모바일 첨부 URL 분리 오류 | `_splitUrls()`가 `,`로 split | `split('\n')` → `split(RegExp(r'\n|%0A|%0a'))`로 변경 |
| 감시목록 카드 차량번호 누락 | `_WatchCard` 위젯에 차량번호 행 없음 | `_row(Icons.directions_car_outlined, '차량번호', ...)` 추가 |
| 크롤링 방식 선택 UI 중복 | 크롤링 화면에 방식 변경 UI → 설정 페이지와 이중화 | 크롤링 화면에서 선택 UI 제거, 현재 방식 뱃지로 표시만 |
| 모바일 crawl_changes 누적 전달 | `save_crawl_changes()`가 기존 파일에 병합 저장 | 매 크롤링마다 덮어쓰기로 변경 |
| 파일 브라우저 다운로드 401 | `/files/download`가 헤더만 허용 → 브라우저는 헤더 전송 불가 | `api_key` 쿼리 파라미터도 허용 |
| 모바일 데이터 갱신 안 됨 | AppBar 새로고침 버튼 누락 시 구 데이터 표시 | 새로고침 버튼 제거, 모든 화면에 `RefreshIndicator` 적용 |
| 동영상 일시정지/탐색 불가 | seek bar 없음 | 하단 오버레이 컨트롤 바 추가: 재생/일시정지 + Slider seek바 |
| 첨부사진 무한 로딩 | `CachedNetworkImage` Connection Reset 시 `errorWidget` 미호출 | `Image.network`로 교체, 최대 5회 자동 재시도 |
| 다른 앱으로 열기 브라우저 다운로드 | `launchUrl(externalApplication)` → Content-Disposition: attachment 따라 다운로드 | `http.get`으로 임시 다운로드 후 `open_filex`로 전달 |
| 처리내용 전화번호 탭 불가 | 전화번호 감지 로직 미흡 | 전화번호 키워드 + 한국 번호 형식 자체 감지 추가 |
| 알림 탭 신고건 탭 잘못 배치 | `saveToHistory()`가 `extraData` 없이 저장 → 크롤링 현황 탭에 표시 | `extraData: JSONObject?` 파라미터 추가 |
| 알림 탭 탭 시 앱만 열림 (네비 없음) | WsService 알림 탭 PendingIntent에 네비 정보 없음 | Intent extras `nav_tab=3` → `onNewIntent` → MethodChannel `navigateToTab` |
| 이미지 최초 로드 실패 | 첫 로드 실패 시 broken_image 고정 표시 | `_RetryableImage` 위젯: 자동 재시도 |
| 재설치 후 구 데이터 잔존 | `allowBackup=true` 기본값으로 앱 데이터 백업·복원 | `android:allowBackup="false"` 추가 |
