# 신고 분류 개편(5분류·SSNPC) — 모바일

정본 계획은 서버 레포 `safetyreport/docs/plans/2026-10-11-report-taxonomy.md`(결정·저장 구조·단계·영향 범위). 이 문서는 그것을 가리킨다.

모바일에서 바뀌는 것(요약): 앱 DB 17(`ssnpc_cd`·`ssnpc_type`, 5분류), 버전 16 제자리 변환, 서버 스키마 6 가져오기,
초기화 크롤링 `source-rebuild-2026-10-11.1`(안내 문구 + 사과 문장), Client 사전 확인(켤 때마다 초기화 화면을 거치던 문제),
observation-v5(공유 category 5분류), 신고내역 탭 교통위반·주정차·안전신고·생활불편·기타·중복차량.
