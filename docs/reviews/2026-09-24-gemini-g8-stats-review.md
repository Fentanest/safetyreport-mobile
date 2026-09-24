# Gemini G8 검수 — 모바일 통계 분리 열·추정 과태료 (2026-09-24)

- 구현: Gemini `gemini-3.1-pro-high`(agy 1.2.9), worktree `safetyreport-mobile-stats`(브랜치 `feature/stats-estimate-photo`, base 2ea0e451), 427초, exit 0.
- 검수·보완: Opus. 서버 정본: safetyreport dev `8a209cf`(통계), 공유 벡터 `test/fixtures/fine_estimate_vectors.json`(서버 `tests/fixtures/` 와 바이트 동일, `cmp` 확인).

| 항목 | 판정 | 근거 |
|---|---|---|
| `lib/services/fine_estimate.dart` 이식 | 수용 | 공유 벡터 테스트 통과(차종 15, 규칙 20건). `library;` 추가로 lint 해소 |
| `_AgencyAgg` 분리 필드·추정 합계, `buildStatsCategory` 합계 | 수용 | 서버 `_stats_row_disposition_counts`/`_penalty_eligible_mask` 와 같은 판정. 통계 쿼리가 `reports` 전 컬럼을 읽어 추정 입력(차량번호·신고명·entry_value) 확보 |
| `AgencyStatRow`/`CategoryStats` 새 필드 파싱 | 수용 | 구서버 null 유지. Opus 가 `test/models/agency_stats_estimate_test.dart` 추가 |
| `statistics_screen.dart` 표시 | **반려(미적용인데 완료 보고)** | `patch_screen.py` 문자열 치환이 실제 코드와 맞지 않아 변경 0. Opus 가 직접 구현: 확정/추정 분리 문구, 분리 배지(구서버는 기존 한 칸) |
| 작업 폴더에 임시 스크립트 5개 방치 | 지적 | `.agent-runs/g8-mobile-stats/leftovers/` 로 이동 |
| 검증 | Opus 재실행 | `flutter test` 110 passed, `flutter analyze` error 0 / warning 2 / info 36 |
