# 백로그 (safetyreport-mobile)

아직 하지 않은 일. 끝나면 이 표에서 지우고 `CHANGELOG.md` 에 기록한다. 상세 설계·근거는 링크한 문서를 따른다.

| ID | 항목 | 상태 | 언제 |
|---|---|---|---|
| BL-1 | Play `H2.h.b` 2단계: flutter_secure_storage 11 + file_picker 13 | 대기 (1단계 dev 반영) | 1단계(v10) 릴리즈 뒤, 사용자 대부분이 v10 을 한 번 연 다음 릴리즈 |
| BL-2 | 통계 기관 카드 건수와 드릴다운 목록 건수 불일치 | 결정 필요 | 통계 의미 작업 때(PC와 함께) |

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
6. 문서: `android-runtime.md` H2.h.b 절, `data-contracts.md` 자격증명 절, `CHANGELOG.md`.

### 검증
- `flutter analyze`·`flutter test`(고정 3.47.5 — 기본 `flutter` 3.41.6 은 골든·`pubspec.lock` 이 달라진다).
- 에뮬레이터 제자리 업데이트: v10(표시 있음) → v11 값 그대로, v9(표시 없음) → v11 재로그인 안내. 배포 서명 빌드로도 한 번.
- 새 AAB 의 R8 mapping 에서 file_picker `FileUtils` 의 옵션 없는 `BitmapFactory.decodeStream` 이 사라졌는지 확인.
  Play Console 경고 해소는 실제 업로드 뒤에만 "해소"라고 쓴다(로컬 확인을 경고 해소로 보고하지 않는다).

## BL-2 통계 기관 카드 건수와 드릴다운 목록 건수 불일치

2026-10-04 UI·코드 점검 통합 검증(에뮬레이터, Standalone 데모)에서 발견. 이번 수정 전에도 같았다(기존 동작).

- 증상: 통계 > 교통위반 > 기관별 "예시 교통 담당 기관 총 27건" 카드를 누르면 드릴다운 목록이 "34건"을 보인다.
- 원인(코드 근거): 기관·담당자·법규 표는 **답변이 완료된 신고만** 센다(2026-09-28 사용자 결정, 서버 `report_stats_service.py:702-705`, 모바일 `local_statistics.dart:188-191`, 완료 = 수용·불수용·일부수용·기타·답변완료). 드릴다운은 기관명·분류·연도·법규만 조건으로 걸고 처리상태는 거르지 않아 같은 기관의 처리중·보완요청·이송 신고까지 보인다. 표 아래 "처리기관이 없는 N건"은 전체 − 기관 행 합계라서, 기관이 있어도 완료가 아닌 신고를 "기관 없음"으로 부른다(문구도 부정확).
  - 2026-10-04 처음 기록 때 "기관코드가 없어서"라고 쓴 것은 틀렸다. 정정.
- 실데이터 영향: 서버 주석에 따르면 실제 DB의 처리중 83건은 모두 처리기관이 비어 있어 처리중 때문에는 차이가 거의 없다. 데모 자료는 처리중에도 기관명을 넣어 차이가 크게 보였다. 보완요청·이송처럼 기관이 붙은 미완료 신고가 있으면 실자료에서도 차이가 난다(미확인).
- 결정 필요: (A) 기관 카드 드릴다운에 "답변 완료만" 조건을 붙여 카드 건수와 맞춘다(목록 제목·조건 칩에 표시, PC 드릴다운도 같은 규칙인지 대조), (B) 지금처럼 기관의 전체 신고를 보이고 카드와 목록 기준이 다름을 안내한다. 어느 쪽이든 각주 문구를 "답변 전이거나 기관이 없는 N건"처럼 고치고, 데모 자료의 처리중 기관명을 실자료처럼 비운다.
