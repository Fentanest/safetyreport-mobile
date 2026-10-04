# 리팩터링 계획 산출물

- [검토·상세 계획](plan.md): 현재 HEAD, 보존 조건, PR0~PR6, 의존성·측정·보류 정책·첫 구현 후보.
- [27개 발견 카드](findings.md) / [JSON](findings.json): 현재 정적 근거·보호·반증·회귀·통과·롤백.
- [검토 범위 CSV](review-scope.csv) / [집계](scope-summary.json): tracked624 경로와 이번 실제 읽기 상한.
- [변경 대상 경로 해석표](file-map.md): 파일명 약칭의 전체 경로와 제안 신규 모듈. 범위 CSV의 소스 해시는 계획 문서 작성 전 기준이다.
- [전 컬럼 교환 인덱스](exchange-columns.md): 정본 계약을 기반으로 한 검토용 목록.
- [빈 측정 양식](benchmark-template.json): 실제 수치 없음, NOT_RUN.
- [입력 원문](input/00_README.md) / [출처·해시](provenance.json): 원문8개 보존. 원문 안의 실행 기록·검토 수치는 과거 작성자의 기록이다.

제품 코드 변경·실행 검증은 없다. 이 계획을 제출한 뒤 구현으로 자동 전환하지 않는다.
