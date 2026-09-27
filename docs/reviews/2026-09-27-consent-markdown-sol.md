# 모바일 동의문 Markdown 표시 검수 (2026-09-27)

## 변경

- `CommunityOnboardingScreen`의 `_docText` 표시를 전용 `ConsentMarkdown` 위젯으로 교체했다. 기존 240px 높이 스크롤 영역, 기본 펼침, 정책 재시도, 동의 저장 및 해시 처리는 유지했다.
- 제목 1~3단계, 문단, `- ` 목록, 굵게, 인라인 코드, 표, 링크를 표시한다. 표는 좁은 화면에서 각 데이터 행을 `머리: 값` 형태로 세로 배치한다. 지원하지 않는 문법은 일반 텍스트로 표시한다.
- 링크는 HTTPS와 `safemap.worklazy.net`, `safeauth.worklazy.net`, `github.com` 호스트에 한해 기존 `url_launcher`로 외부 브라우저를 연다. 다른 주소는 선택 가능한 `글 (주소)` 텍스트로 표시한다.
- 실제 동의문 계약 파일을 읽는 위젯 테스트를 추가했다. 원문 Markdown 기호 제거, 표 셀과 링크 글자 표시, 좁은 폭의 레이아웃 예외, 허용 밖 링크의 탭 인식기 부재를 확인하도록 작성했다.

## 검증

- `/home/better0101/development/flutter/bin/flutter analyze --no-pub lib`: **통과**, No issues found.
- `/home/better0101/development/flutter/bin/flutter analyze --no-pub lib/widgets/consent_markdown.dart test/widgets/consent_markdown_test.dart`: **통과**, No issues found.
- `/home/better0101/development/flutter/bin/flutter test --no-pub test/widgets/consent_markdown_test.dart`: **실행 전 차단**. Flutter SDK의 `bin/cache/engine.stamp`가 읽기 전용이어서 `update_engine_version.sh`에서 종료했다. 첫 `flutter test` 시도도 같은 오류였다. 위젯 테스트 통과 및 실제 렌더 스크린샷은 이 작업 환경에서 확인하지 못했다.
- `flutter analyze lib` 실행 중 자동 변경된 `pubspec.lock`은 원래 상태로 되돌렸다. 의존성 파일은 변경하지 않았다.

## 통합자(community-map 세션) 후속 조정
- Sol 실행 환경에서 `flutter test`가 막혀(Flutter SDK 캐시 읽기 전용) 테스트·화면 확인은 통합자가 했다.
- 동의문 사본이 dev에서 앱 계약 사본에서 빠졌으므로(`contracts/community-ingest/consent/` 삭제, 중앙 `policy`로만 받음) 테스트는 `test/fixtures/share-consent-2026-09-28.1.md`(지도 레포 `contracts/consent/` 정본 사본)를 읽는다.
- 두 칸 표는 휴대폰에서 첫 칸을 굵은 제목, 둘째 칸을 내용으로 보인다("구분:"·"다른 이용자에게 보이는 내용:" 반복 제거). 세 칸 이상은 첫 칸 제목 + "머리: 값".
- 인라인 코드의 monospace 글꼴은 한글 글리프가 없어 `경기76자3623`이 네모로 보였다 → 기본 글꼴 + 배경색만.
- 증거: `docs/reviews/screenshots/consent-markdown/mobile-390-{light,dark}.png` — `CONSENT_SCREENSHOT=1 flutter test test/widgets/consent_markdown_screenshot_test.dart`(실제 한글 글꼴, 평소엔 건너뜀).
- 결과: `flutter test` 676 통과, 실패 4 = `test/golden/renewal_golden_test.dart`(이 환경에서 dev 원본도 같은 실패). 1회 실행에서 `gate_state_test` 1건이 타이밍으로 실패했으나 단독 3회·전체 재실행 통과. `flutter analyze` 이상 없음.
