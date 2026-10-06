> 정정(2026-10-07): 아래 당시 기록 중 “데모도 카카오·클라우드 필수” 및 데모 진입 차단은 잘못된 변경이었다. 현재 데모는 모든 게이트를 건너뛴다. 수정 근거와 검증은 [2.0.4 RC 보고서](../demo-mode-bypass-20261007/REPORT.md)를 따른다. 당시 테스트 수는 역사적 실행 기록이다.

# 공식 계정 1:1 바인딩 구현 검토 — 사용자 r2 정정 반영

- 작업 위치: `mobile-account-binding`, 브랜치 `fix/official-account-binding`, 기준 HEAD `1c6e27cb`.
- 기준: 사용자 r2 정정 우선, 기존 작업지시서와 `binding-contract.md`의 나머지 계약 유지.
- 상태: 구현 및 합성 HTTP/SQLite/위젯 검증. 운영 접속·배포·커밋 없음.

## 계약 결정

1. **안전신문고 ID/해시를 개인 DB에 저장하지 않는다.** `official_account_key` 상수·기록·소유권 비교를 제거했다. 개발 중 남은 키를 판정에 읽지 않으며 별도 마이그레이션하지 않는다. 임의 메타를 조용히 버리지 않는 기존 교환 계약은 유지한다.
2. 복원/가져오기는 **카카오 주인만** 검사한다. 같은 카카오면 안신 정보가 없거나 다른 안신 계정 시절의 백업도 허용한다. 카카오 주인 누락·불일치·로그인 미확인은 기존대로 거절한다. 검증 후 카카오 계정/설정 세대/대상 경로 변경도 최종 교체 전에 거절한다. 개인 DB 자료의 안신 소속은 추정하지 않는다.
3. 1:1은 설정의 공식 로그인 ID를 정규화해 `datasetKeyForOfficialId`로 계산한 해시와 중앙 `status.official_account.dataset_key`를 대조하고, 서버 등록 거절로 보장한다. 개인 DB에 해시가 없다는 이유로 재로그인·초기화를 요구하지 않는다.
4. 계정 변경은 **기존 설정 ID와 후보 ID의 변경 또는 서버 불일치**로 판단한다. 경고 → 일관 백업/무결성 검사 → `official_account_change_pending=true` → `contributions-delete`의 `official_account_released:true` 확인 및 기존 삭제 fence → `rotateDataset`/개인 자료·감시목록 초기화 → 새 설정/연결 → 새로 시작 순서를 유지한다. pending/restart 키는 계정 식별자 없는 상태값만 저장한다. 백업 실패/해제 미확인 시 개인 자료를 보존한다.
5. 가져오기 전 준비한 후보 ID는 Provider 메모리에만 보관한다. 준비 → 가져오기 → 설정 활성화에서 같은 변경을 중복 실행해 가져온 자료를 지우지 않는다. 설정 전환/초기화 시 이 임시값을 지운다. 가져오기에는 공식 ID 전달·Zone·별도 해시 환경변수가 필요 없다.
6. **카카오 연동은 모든 앱 사용자의 필수 조건**이다. Client/Standalone의 인증 필수 구조를 확인했고, 기존 데모 게이트 우회도 제거했다. 데모 역시 카카오 인증·클라우드 확인 후 합성 화면을 열며, 세션/클라우드 차단 시 하위 경로를 닫는다. 인증 전에는 온보딩에 머물고, 인증 후 중앙 접속 실패는 세 모드 모두 장애 페이지로 보낸다. 데모 업로드/공식 계정 등록은 계속 하지 않는다.
7. Client에는 모바일 공식 로그인 설정이 없으므로 PC 설정의 대조·변경은 PC 책임이다. 모바일 Client도 중앙 status와 클라우드 장애는 확인하되, 남아 있는 Standalone ID로 PC 계정을 추정하지 않는다. 데모에도 공식 로그인 계정이 없다. 서버 설정 조회 API를 새로 추정하지 않았다.
8. 구서버가 `official_account` **필드 자체를 생략**하면 원격 대조만 생략하고 정상 진입한다. 필드가 있으나 형식이 잘못되면 차단하며 `dataset_key:null`은 미바인딩이다. 삭제 응답의 해제 확인이 없으면 계정 변경은 완료하지 않는다.
9. 시작/포그라운드 복귀/포그라운드 5분 대조, HTTP 30초 제한, 자동 재시도 2/5/10초 3회 및 수동 재시도를 유지한다. 장애 시 성공 캐시로 우회하지 않고 context·동기화·keep-alive·예약 업로드를 차단한다. 불일치/선점 시 로그인 복구 화면의 뒤로가기·모드/데모 우회를 막는다.

## 변경 파일과 역할

아래는 이전 실행부터 이어지는 최종 미커밋 변경과 r2에서 원래 동작으로 되돌린 파일을 함께 설명한다.

| 파일 | 최종 역할 / r2 정정 |
|---|---|
| `lib/services/local_db_service.dart` | 안신 메타/복원 비교 제거, 카카오 검사 보존, 계정 정보 없는 pending·백업/초기화 |
| `lib/providers/report_provider.dart` | 설정 ID/서버로 변경 판단, 가져오기 전 준비 중복 방지, 인증 실패 정리 |
| `lib/services/pending_db_import_action.dart` | 공식 ID 전달 제거, 기존 카카오 검사 기반 apply로 복귀(최종 HEAD 대비 diff 없음) |
| `lib/services/{sync_engine,standalone_auto_sync_service}.dart` | 안신 메타 비교 대신 변경 중단 상태만 검사 |
| `lib/community/gate/community_account_client.dart` | 확장 응답/오류 파싱, 30초 제한 |
| `lib/community/gate/community_gate.dart`, `lib/community/upload_hooks.dart` | 서버 대조/재시도/진입 차단, 삭제 해제/fence, 변경 중단 검사 연결 |
| `lib/main.dart` | 로그인/장애/새 시작 라우팅, 데모 포함 필수 게이트와 하위 경로 차단 |
| `lib/screens/{setup_screen,settings_screen}.dart` | 계정 변경 확인 및 가져오기 전 준비/후 활성화 |
| `lib/screens/{cloud_unavailable_screen,official_account_start_screen}.dart`, `lib/widgets/official_account_reset_dialog.dart` | 장애/새 시작/계정 변경 경고 |
| `test/storage/{official_account_binding_test,server_import_test,backup_restore_test}.dart` | 안신 불일치/미기록 백업 허용, 카카오 변경 차단, 백업·실패 보존·서버 해제·pending 회귀 |
| `test/community/{official_binding_gate_test,entry_order_test,gate_state_test,gate_silent_refresh_test,techlog_2026_10_04_test,fake_account}.dart` | 구/신 서버, 세 모드 인증/장애, 복구 라우트, 주기/재시도/오래된 응답 |
| `test/widgets/{official_account_reset_dialog_test,setup_pending_db_import_test}.dart` | 경고와 준비→가져오기→활성화 순서 |
| `test/services/sync_inventory_safety_test.dart` | 동기화 fixture |
| `test/support/kakao_owner.dart`, `test/storage/account_owner_test.dart`, `test/tool/db_roundtrip_harness_test.dart` | 불필요한 공식 계정 fixture/환경변수 제거, 기존 카카오 기반으로 복귀(최종 HEAD 대비 diff 없음) |
| `docs/architecture/{data-contracts,community-gate,community-account}.md`, `CHANGELOG.md`, 본 REPORT·검사 로그 | 확정 규칙과 검증 근거 |

## pending_db_import 가설 확인

`resetConfig` 직후 직접 가져오면 카카오 세션이 없어 거절된다. 실제 루트는 카카오 재인증 후 공식 로그인으로 진입하므로 항상 실패한다는 가설은 성립하지 않는다. 아직 공식 ID 설정이 없는 시점의 가져오기도 카카오 주인만 같으면 허용한다. 가짜 로그인 위젯은 계정 준비 → 가져오기 → 모드 활성화 순서, 실제 SQLite는 미인증 거절 → 재인증 성공과 다른 안신 계정 백업 허용을 검증한다. 실패/화면 이탈 시 pending 유지도 보존한다.

## 검사

Flutter는 `/home/better0101/development/flutter-3.47.5/bin/flutter`만 사용한다. 명령 앞에
`FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true`를 지정했다.

- `flutter analyze --no-pub`: **error 0 / warning 9 / info 0**, 종료 **1**. 기존 `agency_registry_wiring_test.dart` 6개·`registry_vectors_test.dart` 3개 unnecessary_cast이며 신규 진단 0. 경고 때문에 명령 자체는 성공 종료가 아니다.
- `flutter test --no-pub test/storage/official_account_binding_test.dart test/storage/server_import_test.dart test/community/official_binding_gate_test.dart test/community/entry_order_test.dart test/widgets/setup_pending_db_import_test.dart`: **70 passed / 0 failed**, 종료 0. 이후 준비 중복 회귀 1개를 추가해 전체 검사에 포함했다.
- 최종 `flutter test --no-pub`: **1,299 passed / 0 failed / 기존 16 skipped**, 종료 **0**, 2분 14초. 기존 폰트/로컬 스택/외부 왕복 환경 조건의 건너뜀은 통과 수에 포함하지 않았다. 직전 1,295개 대비 새 회귀 4개를 추가했고, 안신 백업 거절·데모 우회 기대값을 확정 규칙에 맞게 갱신했다. 테스트 삭제/실패를 skip 처리/0건 통과 표기는 없다.
- `git diff --check`: 통과.
- Dart format은 최초 환경변수만으로 실행 시 파일 포맷 후 sandbox 밖 telemetry 정리에서 종료 1이 났다. `dart --suppress-analytics format`으로 후속 실행은 종료 0. 기능과 무관한 기존 코드 포맷 차이는 제거했다.
- [VERIFICATION.txt](VERIFICATION.txt)에 명령·종료 코드·진단을 보존했다. 로컬 원문 로그는 `r2-targeted-test.log`, `r2-analyze.log`, `r2-full-test.log`(기존 로그 ignore 규칙 적용)다.

## 미확인·위험

- 실기기/에뮬레이터와 네이티브 저장소 권한/서비스는 이번 r2에서 **NOT_RUN**. 직전 실행의 지정 AVD 시도는 `/dev/kvm` 부재로 실패했다. Pixel_9_Pro는 조작하지 않았다.
- 운영 Supabase/Edge/Pages/스토어/실계정 접속 없음. 실제 중앙 해제/선점/양방향 바인딩은 **미검증**이며 합성 HTTP로만 검증했다.
- 실제 PC↔모바일 전 컬럼 왕복 외부 하네스는 **NOT_RUN**. 공식 계정 메타를 PC에 요구하던 배포 의존성은 없어졌다. 일반 교환 스키마·임의 메타 보존 규칙은 변경하지 않았다.
- 같은 카카오의 다른 안신 계정 시절 자료가 로컬 화면에 나타날 수 있다. 이는 r2에서 명시적으로 허용한 복원 규칙이며, 1:1 검증은 설정/서버 연결에 적용한다. 로컬 백업을 공식 응답인 것처럼 공유 업로드하는 경로는 추가하지 않았다.
- 중앙 삭제 후 로컬 초기화/새 등록 실패를 중앙에서 롤백할 수는 없다. 백업·pending/fence·재시도로 처리한다. 구서버에서 바인딩 해제 확인이 없으면 계정 변경은 차단된다.
- 외부 저장소 실제 공간 부족/권한 오류는 미검증. 합성 파일 경로 오류에서는 중앙 삭제·로컬 초기화를 시작하지 않음을 확인한다.

커밋·push·배포·릴리즈 빌드를 하지 않았다.
