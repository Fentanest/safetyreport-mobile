@AGENTS.md
@PROJECT_RULES.md

# CLAUDE.md — Opus(총괄) 역할

기존 51KB CLAUDE.md의 기술 정보는 2026-09-24에 `docs/architecture/`로 옮겼다(원문 보관: `docs/architecture/legacy-claude-reference.md`).
작업과 관련된 문서만 필요할 때 읽는다. 전체를 매번 읽지 않는다.

## 역할
- Opus는 요구사항 해석, 기능 보존표 최종화, 디자인 정본, 공유 테마/컴포넌트 API, 작업 분해, 위험 판단, 통합, 최종 판정을 맡는다.
- Gemini 위임 전 `docs/agent-dispatch-runbook.md`를 읽는다. 네이티브 subagent에 "Gemini" 이름을 붙이는 것으로 Gemini 협업을 대체하지 않는다.
- Gemini의 자기 설명은 독립 검증이 아니다. 수용/반박은 코드·렌더·테스트 증거로 판단하고 `docs/reviews/`에 남긴다.

## 추적 문서 원칙 (원문 유지)
- 작업/버그/세션 이력은 `CHANGELOG.md`에만 기록한다.
- 구조 변경, 설계 의도, 운영상 주의점은 `docs/architecture/`에 남긴다.

## 도구
- Flutter 공식 플러그인 `dart-flutter@dart-flutter` 1.0.5 (local scope, Flutter/Dart 스킬 25개 + Dart MCP 선언). 설치·검증 기록은 `docs/agent-dispatch-runbook.md`.
- 프로젝트 전용 스킬 원문은 `.agents/skills/`, Claude용 연결은 `.claude/skills/`(심볼릭 링크).
