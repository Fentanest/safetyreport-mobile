# Changelog

작업, 버그 수정, 세션 기록용 문서.

- 구조/운영 컨텍스트는 `CLAUDE.md`에 유지
- 2026-05-01에 `CLAUDE.md`의 작업 이력 섹션과 최근 검색 기능 변경을 이 파일로 이관 시작

---

## 2026-05-01

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

### 문서 정리

상태: 완료

변경:
- `CLAUDE.md`
  - `ReportProvider` / `search_filter_sheet` 설명에 새 검색 규칙 반영
  - 신고리스트 상세검색이 Client(server) / Standalone 공통 로직임을 명시
- `CHANGELOG.md`
  - 모바일 레포 최초 생성
  - 기존 `CLAUDE.md`의 주요 작업 이력 일부를 이관 시작

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
