---
name: sr-flutter-visual-qa
description: safetyreport-mobile의 실제 Flutter 렌더를 승인된 네이비·블루 및 화이트 시안과 비교하고 라이트/다크, 두 실행모드, 좁은 폭, 큰 글꼴, 시스템 UI, 접근성을 검수한다.
---

# Flutter 실화면 검수

## 전제
이 스킬은 절차다. 앱을 조작할 MCP/SDK/장치를 자동 설치하거나 권한을 부여하지 않는다.
현재 task에서 배정한 단일 디바이스와 runtime만 조작한다. fixture와 테스트 계정만 사용한다.

## 테스트 매트릭스의 시작안
- Client/Standalone × light/dark.
- 논리 폭 360/412, text scale 1.0/1.3/2.0. 프로젝트의 지원 디바이스에 맞춰 확정한다.
- 최소 지원 Android와 현재 지원 target API 환경은 build 설정에서 확인한다.
- 목록, 상세, 선택, 필터, 빈 데이터, 오류, 로딩 상태.
- 가로/회전/키보드/시스템 뒤로가기/앱 background→resume.

## 절차
1. baseline commit, Flutter/Dart/Android/폰트/locale/fixture/viewport를 기록한다.
2. 실제 Flutter 앱 또는 widget test로 렌더한다. 디자인 생성 이미지는 실행 증거가 아니다.
3. 화면 캡처와 runtime errors/widget tree/semantics를 함께 확인한다.
4. 긴 제목·기관명·차량번호, 잘린 숫자와 단위, 메타데이터 충돌, 가려진 버튼, 색상 대비를 검사한다.
5. 터치영역/label 검사를 Flutter 접근성 Guideline API로 보강한다. 단순 시각 추정으로 통과 판정하지 않는다.
6. 승인된 실제 Flutter 렌더를 golden baseline으로 만든다. 자동 업데이트로 실패를 숨기지 않는다. golden은 고정 환경에서 수행한다.
7. 글로우/blur/그림자의 의도는 보존하되 대량 목록 스크롤과 차트는 profile 모드에서 검증한다. emulator 결과만으로 실기기 성능 보장을 하지 않는다.
8. 공유/파일선택/권한/알림/앱 복귀는 native UI 도구 또는 수동 실행 증거로 확인한다. 앱 내부 테스트 통과로 대체하지 않는다.

## 출력
각 case의 기대/실제, severity, screenshot 경로, 테스트 명령과 종료코드, runtime 오류, 수정 제안.
상태는 PASS/FAIL/BLOCKED/NOT_RUN으로 나누며 테스트를 실행하지 않은 상태에서 PASS로 쓰지 않는다.
