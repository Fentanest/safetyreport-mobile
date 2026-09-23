---
name: sr-ui-contract-audit
description: safetyreport-mobile UI 리뉴얼 전후에 시안의 버튼·정보·내비게이션을 실제 Flutter 코드와 대조하고 Client/Standalone 기능 회귀와 미승인 기능 추가를 검출한다.
---

# UI 기능 계약 대조

## 입력
사용자 지시, base commit, dirty diff, feature-matrix, 승인된 시안, 검사 범위.
AGENTS.md/PROJECT_RULES.md와 관련 architecture 문서를 먼저 읽는다.

## 절차
1. 화면/탭/카드/모달/필터/선택 액션에서 보이는 정보와 호출되는 callback을 찾는다. 코드 경로·심볼·현재 행 범위를 기록한다.
2. 동작이 Provider/서비스/서버 또는 DB 어디에 연결되는지 확인한다. 메뉴 이름만으로 기능 존재를 판단하지 않는다.
3. Client/Standalone, 빈 목록/오류/선택 상태, 외부 앱 링크, 알림 deep link를 분리한다.
4. 시안 요소를 existing / presentation-change / approved-enhancement / unsupported / needs-decision으로 분류한다.
5. 신규 신고접수, 임의 일반 파일업로드/레코드 삭제, 시스템 공지, 모드 혼합을 특히 검사한다. 기존 파일 삭제/DB복원과 구별한다.
6. 숨긴 기능, 끊긴 callback, 잘못 연결된 탭, 데이터 필드 삭제, 이름만 있는 비활성 버튼을 검출한다.
7. 주장마다 코드/스크린샷/실행 또는 테스트 근거를 붙인다. 미실행은 미검증으로 쓴다.

## 출력
기능별 ID, 모드, 기존 경로, 새 경로, 근거, 상태, 테스트ID, 필요한 결정.
코드 수정은 작업서에서 허용한 경우만 수행한다. 일반 검수 작업은 읽기 전용이다.
