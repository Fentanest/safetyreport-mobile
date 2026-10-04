# safetyreport-mobile 리팩터링 계획 패키지

대상: `Fentanest/safetyreport-mobile/dev`  
기준 HEAD: `ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60`  
문서 날짜: 2026-10-04 (Asia/Seoul)  
작업 모드: **PLAN ONLY**

## 파일

| 파일 | 역할 |
|---|---|
| `01_safetyreport_mobile_dev_refactoring_plan_ko.md` | 전체 구조·안전성·기능·성능·UI·단계별 PR·측정·롤백 계획 |
| `02_sol_planning_prompt_ko.md` | Sol에게 계획의 현재성 검증과 상세화를 지시할 붙여넣기 프롬프트 |
| `03_source_audit_original.md` | 사용자 첨부 감사 원문. 바이트 변경 없이 복사 |
| `04_work_items_and_evidence_ko.md` | DB6/UI4/N9/S8의 27개 발견별 작업 카드·수용 조건·근거 범위 |
| `05_traceability_index.json` | 기계 판독용 발견·검토 범위·계획 상태. 실행결과 아님 |
| `06_benchmark_record_template.json` | 후속 승인 뒤 채울 계측 기록 양식. 수치는 전부 null/빈 배열 |
| `manifest.json` | 파일 SHA256·산출물 범위·원본 동일성 |

## 사용

폴더를 Sol이 읽을 수 있는 작업 위치에 놓고 02 프롬프트를 전달한다. 현재 레포나 운영 데이터 폴더를 덮어쓰지 않는다. 루트에 파일이 있다고 가정하지 말고 실제 배치 경로를 알려 준다.

이번에는 자료 보호·완료/ACK 판정·세대/소유권·조회 정확성·cold 통계/중복·Client 계약·책임 분리 순으로 **계획**을 검토한다. 구현·앱·테스트·벤치마크·빌드·기기·외부 작업은 이 패키지로 승인되지 않는다.

현재 HEAD는 첨부 감사와 같지만 Sol이 읽을 때는 다시 확인한다. 이미 해결된 발견을 재수정하거나 지정 SHA로 reset하지 않는다. 과거 테스트/성능 기록, 이번 코드 재열람, 새 설계와 아직 실행하지 않은 검증을 분리한다.

자료 근거와 사용 범위는 04에 있다. 공식 기술 문서는 특정 전제를 확인하는 보조 근거이며 제품 계약을 덮어쓰지 않는다.

## 현재 완료 상태

- 완료: 첨부 감사 기반 상세 계획·Sol 인계문·27개 추적 카드·원본 보존·패키지 생성.
- 소스 확인: 연결된 GitHub의 dev HEAD 및12개 파일의 전체/지정 구간 재열람.
- 미실행: 제품 코드 수정, Flutter/Kotlin 테스트, 앱/기기/실데이터, 성능/전력·DB 왕복, 외부 로그인/수집/별점/업로드, 배포.
