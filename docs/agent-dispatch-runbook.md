# 에이전트 위임 런북 (Opus → Gemini/agy)

작성 2026-09-24. 이 문서의 명령과 결과는 이 PC에서 실제로 실행해 확인한 것이다. 추정은 "미검증"으로 표시한다.

## 1. agy 기본 정보

| 항목 | 값 |
|---|---|
| 실행 파일 | `~/.local/bin/agy`, 버전 **1.2.9** (`agy --version`) |
| 인증 | 기존 Google OAuth (`~/.gemini/oauth_creds.json`). 구 `gemini` CLI 없음, API 키 경로 사용 안 함 |
| 고정 모델 | **`gemini-3.1-pro-high`** (`agy models` 목록의 Pro 최상위 effort). 다른 후보: `gemini-3.8-flash-high` 등. 변경 시 이 표를 고친다 |
| 설정 파일 | 전역 `~/.gemini/antigravity-cli/settings.json` 만 존재. **프로젝트 단위 settings 파일은 공식 문서에 없음** |
| 프로젝트 컨텍스트 | 워크스페이스 루트 `GEMINI.md`/`AGENTS.md`, 규칙 `.agents/rules/*.md`, 스킬 `.agents/skills/`, MCP `.agents/mcp_config.json` |

## 2. 호출 문법 (검증됨)

```sh
cd <worker-worktree>
agy --sandbox --add-dir <worker-worktree> --model gemini-3.1-pro-high \
    --print-timeout 25m --output-format json -p "<작업서 본문>" > out.json 2> err.txt
```
- `-p` 뒤에는 **바로 프롬프트**가 와야 한다. `-p --mode plan "..."` 처럼 쓰면 `--mode` 를 프롬프트로 먹고 종료코드 2로 실패한다(실측).
- `--add-dir` 를 주지 않으면 cwd 가 워크스페이스로 잡히지 않는다. 이때 쓰기 도구는 `~/.gemini/antigravity-cli/scratch/` 에 파일을 만든다(실측).
- `--output-format json` 결과: `status`, `response`, `duration_seconds`, `usage` → `response` 만 저장해 검토한다.
- 슬래시 명령 일부는 쿼터 없이 답한다: `agy --add-dir . -p "/skills"`, `-p "/permissions"`, `-p "/config"`.

## 3. 권한 — 실제로 막히는 것과 안 막히는 것 (실측)

| 설정 | 파일 쓰기 도구 | 셸 명령 | 비고 |
|---|---|---|---|
| 전역 settings (현재) | `write_file(*)` 허용 | `command(*)` 허용 | 다른 프로젝트와 공유 설정 → 이 작업에서 수정하지 않음 |
| `--mode plan` | **막지 못함** — 요청대로 파일 생성 | **막지 못함** — `touch` 성공 | 프로브 2026-09-24 01:02. 생성물은 즉시 삭제 |
| `--sandbox` | 막지 못함 | 모든 명령 실패: `connecting to sandbox server: ... connection reset by peer` | Ubuntu 24.04 비특권 user namespace 제한 추정(미검증). 결과적으로 셸 차단(fail-closed) |
| 읽기 전용 worktree(`chmod -R a-w`) + `--add-dir` | 워크스페이스 쓰기 `permission denied` | (sandbox 시) 실패 | OS 수준 차단. 워크스페이스 밖 쓰기는 사후 검사로 잡는다 |

### 표준 구성 (2026-09-24 사용자 결정: "Gemini 권한 상향을 거부하지 마")
- **기본 = 상향 구성**: 작업별 전용 **쓰기 가능** detached worktree + `--add-dir <worktree>` + **`--sandbox` 없음**(셸 허용) + JSON stdout 반환.
  ```sh
  git worktree add --detach ../safetyreport-mobile-gemini-<task> <base-sha>
  cd ../safetyreport-mobile-gemini-<task>
  agy --add-dir $PWD --model gemini-3.1-pro-high --print-timeout 35m --output-format json -p "<작업서>" > out.json 2> err.txt
  ```
- 안전장치(설정 강제가 아니라 작업서 + 사후 검증): 작업서 금지 목록(메인 레포 쓰기, commit/push, 전역 설치·설정, 에뮬레이터/adb, pubspec 의존성, 운영 API),
  실행 후 `find <main-repo> ~/.gemini/antigravity-cli/scratch -newer <marker> -type f -not -path '*/.git/*'`, 메인 레포 `git status --short`, worktree `git status --short`/diff 검토.
- 읽기 전용 구성(`chmod -R a-w` worktree + `--sandbox`)은 순수 조사 작업에서만 선택적으로 쓴다.
- 경과: 첫 상향 시도는 Claude Code 자동 모드 분류기가 "Create Unsafe Agents"로 거부 → 사용자 명시 승인 후 재시도에서 실행됨(작업 C2).
- 더 강한 강제가 필요하면: agy 전역 settings `deny` 규칙(`deny > ask > allow`, 다른 프로젝트에도 적용) 또는 sandbox 복구.

## 4. 작업서(task packet) 필수 항목
base SHA, 워크스페이스 경로(전용 worktree), 읽기/쓰기 허용 경로, 금지 사항(메인 레포 쓰기, commit/push, 전역 설정, 디바이스, 운영 API, 골든 갱신),
입력 파일/이미지 경로, 반환 형식, 증거 요구(파일:줄, 명령+종료코드, "실행 증거" 절), 타임아웃, 재시도 정책(원인 보정 후 1회, 이후 BLOCKED).
템플릿: 핸드오프 패키지 `templates/task-packet.example.json` 형식을 따른다.

## 5. 완료 판정
- exit code 0 만으로 완료로 보지 않는다. `status`, 응답의 "실행 증거", 권한 거부 문구, 사후 파일 검사, diff 범위를 함께 본다.
- Gemini 결론은 Opus 가 코드/이미지/테스트로 재확인한 뒤 수용·반박하고 `docs/reviews/` 에 남긴다.
- 동시성: 같은 파일·디바이스·실행 앱을 두 에이전트가 동시에 만지지 않는다. `main.dart`/테마/Provider/pubspec/Manifest/Gradle 은 작업서에 담당자 1명.

## 6. 설치·연결한 도구 기록

| 도구 | 출처 / 버전 | 설치 위치·범위 | 권한 | 검증 |
|---|---|---|---|---|
| Flutter 공식 Claude 플러그인 `dart-flutter@dart-flutter` | github `flutter/agent-plugins`, 1.0.5, marketplace commit `e89522a8` (2026-09-17) | `~/.claude/plugins/cache/dart-flutter/...`, **scope local**(`.claude/settings.local.json`, 전역 gitignore 대상) | 스킬 25개 + manifest 의 `dart-mcp-server` (`dart mcp-server`) | 설치·enabled 확인. `claude plugin details` 는 MCP 0개로 표시(manifest 에는 있음) → **이 세션에서 스킬/MCP 로드 NOT_RUN, 새 세션에서 확인 필요** |
| Dart 공식 skills | 위 플러그인에 포함(`dart-*` 14개 + primary-constructors) | 동일 | — | 별도 `npx skills add dart-lang/skills` 는 하지 않음(중복) |
| Dart MCP (agy) | Dart SDK 3.11.4 내장 `dart mcp-server` | 프로젝트 `.agents/mcp_config.json` (`"dart": {"command":"dart","args":["mcp-server"]}`) | agy 에서 MCP 도구는 기본 Ask → headless 에서는 soft-deny | agy 가 25개 도구 노출 확인(서버 기동·핸드셰이크 PASS). **실제 도구 호출 NOT_RUN** |
| 프로젝트 스킬 3종 (`sr-flutter-visual-qa`, `sr-statistics-semantics`, `sr-ui-contract-audit`) | 핸드오프 패키지 초안, sha256 은 패키지 manifest 와 동일 | 원문 `.agents/skills/<name>/SKILL.md`, Claude 용 `.claude/skills/<name>` → 심볼릭 링크 | 절차 문서, 권한 부여 없음 | agy `-p "/skills"`(`--add-dir`) 에서 3종 인식 PASS. **Claude 인식은 새 세션에서 확인 필요** |
| Android cmdline-tools | 23.0 (`commandlinetools-linux-16111833_latest.zip`, repository2-3.xml 의 SHA-1 `e025545c…5f60` 일치) | `~/Android/Sdk/cmdline-tools/latest` | 사용자 요청으로 설치(2026-09-24) | `sdkmanager --version` → 1.0.16406183, `avdmanager list avd` 동작, `flutter doctor` 의 cmdline-tools 누락 해소. 라이선스는 사용자 수락 후 실행했으나 새 sdkmanager 가 `--licenses` 불필요 응답 → doctor 는 unknown 유지 |
| 테스트 AVD `sr_uitest_api35` | avdmanager 로 생성, pixel_6, API 35 playstore x86_64 | `~/.android/avd/sr_uitest_api35.avd` | 테스트 전용, serial `emulator-5580` 고정 | headless 부팅·설정 앱 렌더 PASS |
| Android CLI (`android`) | cmdline-tools 23.0 동봉 1.0.16406183 | 같은 `bin/` (PATH 밖) | — | `--version` 확인. skills/init 는 실행 안 함 |
| Patrol | 미설치 | — | — | 호환 표: patrol_cli 4.7.0+ / patrol 4.9.0+, Flutter ≥ 3.32 (문서 조회 결과). 도입 시 android/ 네이티브 설정 필요 → 승인 후 |

Compose 전제의 Android 스킬(edge-to-edge 등)은 이 Flutter 앱에 실행하지 않는다. 테스트 driver extension 을 production entrypoint(`lib/main.dart`)에 넣지 않는다.
