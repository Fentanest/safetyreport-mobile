# 나만의 안전신문고 — Android 앱

안전신문고 민원 처리 현황을 스마트폰에서 실시간으로 확인하는 Android 앱입니다.  
[나만의 안전신문고 서버](https://github.com/Fentanest/safetyreport)와 연동하여 동작합니다.

---

## 주요 기능

- **실시간 크롤링 알림** — 민원 처리 결과가 바뀌면 즉시 Android 알림 수신 (백그라운드 WebSocket 서비스)
- **신고 목록 조회** — 교통위반 / 주정차위반 / 기타위반 / 중복차량 4개 탭
- **처리 통계** — 기관별·담당자별 통계 (교통/주정차/기타 × 전체·경찰·비경찰)
- **자동 크롤링 연동** — 카카오톡/안전신문고 알림을 감지하여 서버 크롤링 자동 시작
- **크롤링 제어** — 앱에서 직접 크롤링 시작·중지, 실시간 로그 확인
- **파일 브라우저** — 서버의 로그·결과 파일 열람 및 다운로드

---

## 시작하기

### 요구사항

- Android 6.0 (API 23) 이상
- [나만의 안전신문고 서버](https://github.com/Fentanest/safetyreport)가 네트워크 내에서 실행 중이어야 합니다

### 설치

1. [Releases](https://github.com/Fentanest/safetyreport-mobile/releases) 페이지에서 최신 APK 다운로드
2. Android 설정 → 알 수 없는 소스 설치 허용 후 APK 설치

### 초기 설정

1. 앱 실행 후 **설정** 탭 이동
2. 서버 주소 입력 (예: `http://192.168.1.100:6819`)
3. 서버 웹 UI의 **기기 연동** 페이지에서 API 키 발급 후 입력
4. **WebSocket 서비스 시작** 버튼을 눌러 백그라운드 연결 활성화

### 자동 크롤링 연동 (선택)

카카오톡이나 안전신문고 앱 알림을 감지하여 서버 크롤링을 자동으로 시작하려면:

1. 설정 → **알림 접근 권한** 허용
2. 카카오톡 또는 안전신문고 앱 알림에 신고번호가 포함되면 자동으로 서버에 크롤링 요청

---

## 빌드

```bash
flutter build apk --release
```

또는 GitHub Actions의 `build-apk.yml` 워크플로우를 수동 실행하면 APK가 자동 빌드되어 GitHub Release로 게시됩니다.

### 서명 설정 (필요 시)

러너 서버의 `~/mysafetyreport-android/` 경로에 아래 파일이 있어야 합니다:
- `key.properties` — 키스토어 경로·비밀번호 설정
- `upload-keystore.jks` — 서명 키스토어

---

## 연관 프로젝트

- [safetyreport](https://github.com/Fentanest/safetyreport) — 서버 (FastAPI + Selenium)
- [safetyreport-chromeextension](https://github.com/Fentanest/safetyreport-chromeextension) — Chrome 확장
