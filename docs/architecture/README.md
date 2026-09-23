# docs/architecture — 기술 문서 색인과 이관 대응표

2026-09-24 에 루트 `CLAUDE.md`(51KB)를 주제별로 나눴다. 원문은 한 글자도 버리지 않았고,
[legacy-claude-reference.md](legacy-claude-reference.md) 에 원본 그대로 보관한다(자동 import 대상 아님).
각 파일 상단의 "코드 대조 정정" 표가 원문과 현재 코드(base `c64be69a`)의 차이를 기록한다.

| 파일 | 다루는 것 | 언제 읽나 |
|---|---|---|
| [overview.md](overview.md) | 모드 개요, 기술 스택, 디렉토리, 하단 탭/패널 구조, 부팅·별점·최근답변 흐름, 상세검색, 신고현황/파일, 출처 고지, 테마 | 화면/UI 작업 전 |
| [android-runtime.md](android-runtime.md) | Android 15 edge-to-edge, 알림 감지→동기화, drain 큐, emit, SharedPreferences 키/함정, FGS·알림 채널, enqueue 억제, ChangeType, 버전·빌드 | Kotlin/권한/알림/빌드 작업 전 |
| [data-contracts.md](data-contracts.md) | Client 서버 계약, 중복 projection, 재시도, 중복 알림, 인증, SQLite, 모드 전환 DB 이관, errno 104, refreshAll 직렬화, CRLF regex, API 엔드포인트 | 데이터/네트워크/집계 작업 전 |
| [legacy-claude-reference.md](legacy-claude-reference.md) | 원문 보관 | 이관 누락 의심 시 대조 |

## 제목별 대응표 (원문 줄 번호 → 새 위치)

| 원문 제목 | 원문 줄 | 새 위치 |
|---|---|---|
| (머리말: 추적 문서 원칙) | 1-8 | 루트 `CLAUDE.md` / `AGENTS.md` 문서 원칙 |
| 프로젝트 개요 | 10-27 | overview.md |
| 기술 스택 | 28-35 | overview.md |
| 디렉토리 구조 | 36-145 | overview.md (+정정) |
| Client 서버 계약 단일 소스 | 146-163 | data-contracts.md |
| Standalone 중복 projection | 164-185 | data-contracts.md |
| 설정 기본값 / 재시도 정책 | 186-198 | data-contracts.md |
| Android 15 / Play Console wider-screen 메모 | 199-225 | android-runtime.md |
| 재사용 패널 구조 | 226-237 | overview.md |
| 하단 탭 구조 | 238-253 | overview.md (+정정: 신고관리 4개 하위 탭) |
| 중복 변경 알림 흐름 | 254-270 | data-contracts.md |
| Client 중복 신고 API 호환성 | 271-279 | data-contracts.md |
| 핵심 흐름 1. 앱 부팅 | 280-301 | overview.md (+정정: edge-to-edge) |
| 핵심 흐름 2. 알림 감지 → 동기화 | 302-318 | android-runtime.md |
| 핵심 흐름 3. drainIfPending | 319-339 | android-runtime.md |
| 핵심 흐름 4. 변경사항 emit | 340-354 | android-runtime.md |
| 핵심 흐름 5. 다중 선택 별점 주기 | 355-387 | overview.md |
| 핵심 흐름 6. 최근 답변 / 카테고리 라우팅 | 388-412 | overview.md |
| Standalone 인증 아키텍처 (로그인·데모·토큰·자격증명) | 413-462 | data-contracts.md |
| SQLite 스키마 / 주요 쿼리 함수 | 463-530 | data-contracts.md (+정정: version 10, 보완 7컬럼) |
| 신고리스트 상세검색 | 531-548 | overview.md |
| 신고현황 / 파일 브라우저 | 549-556 | overview.md |
| 정부 정보 출처 / 비공식 고지 | 557-572 | overview.md (+ `PROJECT_RULES.md` 불변조건) |
| SharedPreferences 키 + 큐 형식 함정 | 573-602 | android-runtime.md |
| Foreground Service 정책 / 알림 채널 | 603-634 | android-runtime.md |
| 자동 enqueue 알림 억제 로직 | 635-647 | android-runtime.md |
| ChangeType 상수 | 648-663 | android-runtime.md |
| 모드별 테마 | 664-676 | overview.md (+정정: 다크 테마/AppThemeMode) |
| 모드 전환 + DB 마이그레이션 | 677-705 | data-contracts.md |
| errno=104 silent retry 매트릭스 | 706-721 | data-contracts.md (+정정: 5회) |
| refreshAll 직렬화 | 722-735 | data-contracts.md |
| Python ↔ Dart regex 함정 (CRLF) | 736-753 | data-contracts.md |
| 버전 관리 / 로컬 빌드 / 릴리즈 빌드 | 754-789 | android-runtime.md |
| 외부 참조 | 790-800 | overview.md |
| 서버 API 주요 엔드포인트 | 801-813 | data-contracts.md |
| 안전신문고 API 엔드포인트 | 814-823 | data-contracts.md |

분할 스크립트는 원문 10~823행의 비어 있지 않은 모든 줄이 세 파일 중 하나에 들어갔는지 검사했다(미포함 0줄).
