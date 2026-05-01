# 나만의 안전신문고 — Android 앱

안전신문고에 신고한 민원의 처리 상태를 한 곳에서 보고, 변경되면 즉시 알림을 받는 개인용 Android 앱입니다.

두 가지 사용 방식 중 하나를 선택할 수 있습니다.

| 방식 | 설명 | 누구에게 |
|------|------|-----------|
| **Standalone 모드** | 앱이 안전신문고에 직접 로그인해서 데이터를 가져옵니다. 별도 서버 불필요 | 빠르게 써보고 싶은 일반 사용자 |
| **Client 모드** | 직접 운영하는 크롤링 서버에 연결해 자동/주기적 크롤링 + 통계/파일 관리까지 | 라즈베리파이 등으로 24/7 서버 돌리고 싶은 사용자 |

---

## 다운로드

- [Google Play 스토어](https://play.google.com/store/apps/details?id=com.fentanest.mysafetyreport)
- [GitHub Releases](https://github.com/Fentanest/safetyreport-mobile/releases) — 최신 APK 직접 다운로드

요구사항: **Android 7.0 (API 24) 이상**.

---

## Standalone 모드 — 가장 간단한 시작

별도 서버 설치 없이, 본인 안전신문고 계정만 있으면 바로 사용할 수 있습니다.

### 설정

1. 앱 실행 → **연결 방식 선택** 화면에서 **Standalone 모드** 선택
2. 안전신문고 계정 (아이디 / 비밀번호) 입력 → 로그인
3. 첫 동기화 (전체 신고 내역 가져오기) — 신고 건수에 따라 수십 초 ~ 수 분 소요
4. 끝. 신고 내역, 통계, 중복차량, 처리상태 변경 알림 사용 가능

### 자동 알림 (선택)

설정 → "알림 접근 권한" 허용 시:
- 카카오톡 / 안전신문고 앱에서 신고 관련 알림이 오면 → 앱이 자동으로 해당 신고를 동기화 → 처리 상태가 바뀌었으면 푸시 알림
- 알림을 탭하면 곧바로 동기화 화면으로 이동 + 자동 처리

### 보안

- 비밀번호는 안드로이드 `EncryptedSharedPreferences` (Keystore 기반) 에 저장됩니다.
- 토큰 만료 시 (1시간) 저장된 비밀번호로 자동 재로그인.
- 모든 통신은 HTTPS, RSA 공개키 기반 암호화 사용 (안전신문고 공식 웹과 동일 방식).

---

## Client 모드 — 24/7 자동 크롤링 + 통계

라즈베리파이나 항상 켜진 PC 에 별도 크롤링 서버를 돌려서, 모바일 앱은 결과만 받아보는 방식입니다. 자동 정기 크롤링 / 통계 / 파일 관리 / 다중 기기 지원 등 더 풍부한 기능을 사용할 수 있습니다.

### 시작 가이드 (3개 링크)

1. **프로젝트 소개 / 사용법 안내** — <https://hb.worklazy.net/mysafetyreport/>
2. **라즈베리파이 서버 설정 가이드** — <https://hb.worklazy.net/raspberry-pi-mysafetyreport-setup/>
3. **서버 소스코드 (GitHub)** — <https://github.com/Fentanest/safetyreport>

### 모바일 앱 설정

1. 앱 실행 → **Client 모드** 선택
2. 서버 주소 (예: `https://my-server.example.com` 또는 `http://192.168.1.100:6819`)
3. 서버 웹 UI 의 **기기 연동** 페이지에서 발급받은 API 키 입력
4. **연결 테스트** → **저장**
5. 설정 → **백그라운드 서버 연결** ON (WebSocket 으로 실시간 이벤트 수신)

### 자동 알림 연동 (선택)

Standalone 과 동일하게 알림 접근 권한 허용 시 카카오톡/안전신문고 알림 → 서버에 자동 크롤링 요청.

---

## 주요 기능 한눈에

| 기능 | Standalone | Client |
|------|:----------:|:------:|
| 신고 목록 (교통/주정차/기타/중복차량) | ✅ | ✅ |
| 처리상태 변경 자동 감지 + 알림 | ✅ | ✅ |
| 기관별 / 담당자별 통계 + 위반법규 필터 | ✅ | ✅ |
| 알림 접근 권한 기반 개별 신고 자동 동기화 | ✅ | ✅ |
| 백그라운드 24/7 크롤링 | ❌(앱 실행시에 가능) | ✅ (서버가 담당) |
| Excel 내보내기 | ✅(수동) | ✅ |
| Google Sheets 연동 | ❌ | ✅ |
| 만족도 조사(별점) 일괄 실행 | ✅ | ✅ |
| 크롬 확장프로그램 사용 | ❌ | ✅ |
| DB 백업 / 복원 | ✅ | ✅ |
| 개별 신고 데이터 직접 수정 | ❌ | ✅ |
| 상세 로그 제공 | ❌ | ✅ |

---

## 화면 구성

| 탭 | 내용 |
|----|------|
| 대시보드 | 처리 요약, 최근 답변, 감시목록 |
| 신고 리스트 | 교통 / 주정차 / 기타 / 중복차량 |
| 통계 | 연도 × 카테고리 × 유형별 처리 통계, 위반법규 필터 |
| 알림 | 변경 알림 히스토리 (최대 200개) |
| 파일 | 로컬 / 서버 파일 브라우저 (Excel 포함) |
| 동기화 / 크롤링 | Standalone 동기화 / Client 크롤링 제어 |

---

## 자주 묻는 질문

**Q. Standalone 모드에서 비밀번호는 안전한가요?**  
A. Android Keystore 기반의 `EncryptedSharedPreferences` 에 저장되며 앱 데이터 외부로 절대 전송되지 않습니다. RSA 공개키로 암호화 후 안전신문고에 전달.

**Q. 동기화 도중 앱을 닫아도 되나요?**  
A. 가능합니다. Foreground Service 가 작동해 동기화 진행 알림이 표시되며, OS 가 우선순위 후순위로 격상해 죽지 않게 보호합니다. 강제종료 / 메모리 부족 등으로 중단되더라도 미처리 신고번호는 큐에 보존되어 다음 실행 시 자동 재시도됩니다.

**Q. xlsx 파일을 탭했는데 "열 수 있는 앱이 없습니다" 가 떠요.**  
A. xlsx 핸들러 (Microsoft Excel / Google Sheets 등) 가 설치되어 있지 않으면 자동으로 시스템 공유 sheet 가 뜹니다. Drive / OneDrive / 메일 등으로 보내거나 파일 관리자로 열 수 있습니다. 길게 눌러도 동일 메뉴.

**Q. Standalone 에서 Client 로 (또는 그 반대) 전환할 수 있나요?**  
A. 설정 → 연결 방식 카드의 "변경" 버튼으로 가능합니다. 단 기존 연결 정보는 초기화됩니다.

---

## 버그 제보 / 기능 요청

앱 내 **설정 → 앱 정보 → "버그 제보 / 기능 요청"** 버튼으로 GitHub 이슈 페이지로 바로 이동합니다.

직접 링크: <https://github.com/Fentanest/safetyreport-mobile/issues>

---

## 연관 프로젝트

- [safetyreport](https://github.com/Fentanest/safetyreport) — Client 모드용 서버 (FastAPI + Selenium / API)
- [safetyreport-chromeextension](https://github.com/Fentanest/safetyreport-chromeextension) — Chrome 확장 (선택)

---

## 라이선스

[LICENSE](LICENSE) 참조.
