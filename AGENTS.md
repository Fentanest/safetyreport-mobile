# AGENTS.md — safetyreport-mobile 공통 진입점

모든 에이전트(Claude/Opus, Gemini/agy, 기타)가 먼저 읽는 짧은 문서다. 상세는 링크를 따라 필요한 것만 읽는다.

## 이 앱
- "나만의 안전신문고" Android 앱. 안전신문고에 **이미 접수한 신고를 조회·관리**한다. 신고 접수 기능은 없다.
- Flutter(UI, Provider, sqflite) + Kotlin(백그라운드 서비스 3개, MethodChannel `com.fentanest.mysafetyreport/permissions`).
- 두 실행 모드: **Client**(`AppMode.server`, 사용자가 운영하는 크롤링 서버 `/home/better0101/projects/safetyreport`에 연결) / **Standalone**(안전신문고 API 직접 호출 + 로컬 SQLite). 크롤링(Client)과 동기화(Standalone)는 다른 기능이다.

## 반드시 지킬 것
[PROJECT_RULES.md](PROJECT_RULES.md) — 제품 불변조건, 권한, 기능 보존, 정본 우선순위, 완료 기준.

## 문서 지도
| 필요할 때 | 문서 |
|---|---|
| 구조·화면·흐름 | [docs/architecture/overview.md](docs/architecture/overview.md) |
| Kotlin·권한·FGS·알림·빌드/서명 | [docs/architecture/android-runtime.md](docs/architecture/android-runtime.md) |
| 서버 계약·SQLite·인증·집계 함정 | [docs/architecture/data-contracts.md](docs/architecture/data-contracts.md) |
| 원래 CLAUDE.md 원문과 이관 대응표 | [docs/architecture/README.md](docs/architecture/README.md) |
| UI 리뉴얼 설계 정본 | [docs/design/ui-renewal-spec.md](docs/design/ui-renewal-spec.md) |
| 기능 보존표 / 에셋 목록 | [docs/design/feature-matrix.csv](docs/design/feature-matrix.csv) · [docs/design/asset-manifest.csv](docs/design/asset-manifest.csv) |
| 통계 지표 정의 | [docs/design/statistics-spec.md](docs/design/statistics-spec.md) |
| 테스트 계획/베이스라인 | [docs/testing/ui-test-plan.md](docs/testing/ui-test-plan.md) |
| 에이전트 위임 절차(agy 호출·권한·검증) | [docs/agent-dispatch-runbook.md](docs/agent-dispatch-runbook.md) |
| 검수 기록 | [docs/reviews/](docs/reviews/) |

## 문서 원칙
- 작업/버그/세션 이력은 `CHANGELOG.md`에만 기록한다. 실제로 한 변경만 적는다.
- 구조 변경·설계 의도·운영 주의점은 `docs/architecture/`에 적는다. 루트 문서에 상세를 복사하지 않는다.
- 문서와 코드가 다르면 코드를 근거로 삼고, 차이를 해당 문서의 "코드 대조 정정"에 남긴다.

## 기본 명령
```sh
flutter analyze            # 2026-09-24: error 0 / warning 2(기존 setup_screen) / info 36 → 종료코드 1 (시작 baseline: info 73)
                           # 심각도 집계: flutter analyze | awk -F' • ' '/ • /{print $1}' | sort | uniq -c
flutter test               # 2026-09-24: 102 passed (골든은 `golden` 태그, 폰트 없는 환경에서 자동 skip)
```
빌드/릴리즈 스크립트(`build_android_release.sh`, `.github/workflows/build-apk.yml`)는 배포 경로다. 승인 없이 실행하지 않는다.
