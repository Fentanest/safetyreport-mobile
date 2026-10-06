# 백로그 (safetyreport-mobile)

아직 하지 않은 일. 끝나면 이 표에서 지우고 `CHANGELOG.md` 에 기록한다. 상세 설계·근거는 링크한 문서를 따른다.

| ID | 항목 | 상태 | 언제 |
|---|---|---|---|
| BL-1 | Play `H2.h.b` 2단계: flutter_secure_storage 11 + file_picker 13 + **SQLite 엔진 버전 올리기** | 대기 (1단계 dev 반영) | 1단계(v10) 릴리즈 뒤, 사용자 대부분이 v10 을 한 번 연 다음 릴리즈 |

## BL-1 Play `H2.h.b` 2단계 — flutter_secure_storage 11 + file_picker 13

2026-09-27 등록. 결정: 2단계 진행(사용자 승인, 2026-09-27).

### 왜 두 단계인가
- `H2.h.b` 는 file_picker 11.0.2 `FileUtils.compressImage` 의 옵션 없는 `BitmapFactory.decodeStream`. 앱은 `compressionQuality` 를 늘 0 으로 써서
  실행 경로는 아니지만 바이너리에 있어 Play 가 경고한다. 해소하려면 file_picker 13(수정판)이 필요하다.
- file_picker ≥12 → win32 6 → share_plus 13·package_info_plus 10 → **flutter_secure_storage 11** 이 필요하다.
- flutter_secure_storage 11 은 v10 이전 방식(Android `encryptedSharedPreferences`, 옛 기본 cipher)으로 저장한 값을 읽지 못한다.
  9 → 11 로 바로 올리면 카카오 세션·연결 비밀·안전신문고 로그인 정보가 사라진다.
- 그래서 1단계(9 → 10, 앱을 열 때 이관 + `secureStorageV10Migrated` 표시)를 먼저 내고, 이 항목(2단계)은 그 다음 릴리즈에 낸다.
  근거: `docs/architecture/android-runtime.md` "이미지 디코딩·Play H2.h.b", `docs/architecture/data-contracts.md` 자격증명 절,
  `docs/reviews/2026-09-27-secure-storage-10-sol.md`.

### 시작 전 조건
- 1단계(v10)가 Play 에 배포되어 있고, 사용자 대부분이 v10 을 한 번 이상 연 뒤일 것(배포 뒤 기간·버전 분포는 Play Console 에서 확인 — 측정하지 않은 비율을 쓰지 않는다).
- 1단계에서 아직 확인하지 못한 것을 먼저 확인할 것:
  - 실제 앱에서 **로그인을 끝까지 마친** v9 자료(카카오 세션 토큰·안전신문고 로그인 정보·연결 비밀)가 v10 제자리 업데이트 뒤 그대로 읽히는지
    (지금까지는 로그인 대기 값 하나와 시험 앱으로 넣은 값만 확인).
  - 배포 서명 빌드로 같은 시험.
  - 이관 중 강제 종료, 앱·WorkManager 동시 첫 접근, Keystore 고장 기기.
  - iOS(Keychain, darwin 패키지) — 실기기 미확인.

### 할 일
1. `pubspec.yaml`: flutter_secure_storage 11, file_picker 13, share_plus 13, package_info_plus 10. 고정 Flutter(`tool/flutter-version`, 지금 3.47.5)로만 `pub get`.
2. `encryptedSharedPreferences` 매개변수 제거(11 에서 없어짐). 저장 옵션의 나머지는 바꾸지 않는다(새 암호화 도입 금지).
3. **표시(`secureStorageV10Migrated`) 없는 설치본**(v10 을 건너뛴 사용자): 조용히 로그아웃된 상태로 두지 않는다. 재로그인·커뮤니티 연결 재설정 안내로 보낸다.
   읽기 실패를 "자료 없음"으로 바꾸지 않는다. 로그인 정보를 지워 우회하는 경로를 두지 않는다(카카오 로그인 필수).
4. 1단계 이관 코드(`lib/services/secure_storage_migration.dart`)의 역할 정리: 11 에서는 이관이 불가능하므로 "표시 확인 → 없으면 안내"로 바꾼다.
   표시 키는 지우지 않는다(다음 판단 근거).
5. file_picker 13·share_plus 13·package_info_plus 10 의 API 변경 반영(파일 선택·공유·버전 표시 화면).
6. **SQLite 버전 올리기**(2026-10-06 사용자 지시 — 다음 패키지 버전 반영 때 함께).
   - 지금 `sqflite` 는 Android 기기에 들어 있는 SQLite 를 쓴다. 그래서 기기마다 버전이 다르다(Android 7~10 기본 3.9~3.22).
     2.0.2 에서 업로드 제어의 `ON CONFLICT … DO UPDATE`(3.24+)가 3.22 에서 문법 오류를 낸 것을 확인하고 3.9 호환 SQL 로 바꿨다(CHANGELOG 2026-10-06 v2.0.2).
     기기 SQLite 에 묶여 있는 한 새 SQL 을 쓸 때마다 같은 위험이 있다.
   - 할 일: 앱에 SQLite 를 함께 넣어(번들) 모든 기기에서 같은 최신 SQLite 를 쓰게 한다. 후보(시작할 때 조사로 확정 — 추측으로 고르지 않는다):
     `sqlite3_flutter_libs`(번들 SQLite) + `sqflite_common_ffi` 로 Android 연결 교체, 또는 같은 효과의 다른 방법.
     `sqflite` 자체 버전도 그때 최신으로.
   - 지켜야 할 것: 기존 DB 파일을 그대로 연다(파일 형식 호환·`user_version`·WAL·FTS 보조 표). 서버↔모바일 DB 교환·왕복 무결성(PROJECT_RULES §3-1),
     백그라운드 isolate(WorkManager)·첫 실행 이전 DB 비우기(`resetLegacyDatabase`)·백업/복원이 같은 엔진을 쓰는지, APK 크기 증가.
   - 엔진을 바꾼 뒤에도 최소 지원 SQLite 를 문서에 적고, 새 SQL 은 그 버전 기준으로 검사한다(지금은 3.22 실라이브러리 회귀 테스트가 있다 — `.agent-runs/mobile-gate` 방식).
7. 문서: `android-runtime.md` H2.h.b 절·SQLite 엔진 절, `data-contracts.md` 자격증명 절, `CHANGELOG.md`.

### 검증
- `flutter analyze`·`flutter test`(고정 3.47.5 — 기본 `flutter` 3.41.6 은 골든·`pubspec.lock` 이 달라진다).
- 에뮬레이터 제자리 업데이트: v10(표시 있음) → v11 값 그대로, v9(표시 없음) → v11 재로그인 안내. 배포 서명 빌드로도 한 번.
- SQLite: 실기기·에뮬레이터에서 `SELECT sqlite_version()` 이 번들 버전인지, 1.3.5·2.0.x DB 제자리 업데이트·서버 DB 왕복·백업 복원이 그대로인지.
- 새 AAB 의 R8 mapping 에서 file_picker `FileUtils` 의 옵션 없는 `BitmapFactory.decodeStream` 이 사라졌는지 확인.
  Play Console 경고 해소는 실제 업로드 뒤에만 "해소"라고 쓴다(로컬 확인을 경고 해소로 보고하지 않는다).
