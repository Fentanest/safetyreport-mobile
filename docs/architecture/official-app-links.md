# 공식 안전신문고 앱 딥링크 계약

## 범위와 판단

분석 대상은 저장소의 `kr.go.safepeople-328/`에 있는 Android 디컴파일 소스와 웹 자산이다.
Manifest 버전은 `3.2.8` / `versionCode=165`, 패키지는 `kr.go.safepeople`이다.
이 폴더가 스토어의 최신 배포본이나 설치 앱의 모든 웹 자산과 동일하다는 보장은 하지 않는다.

현재 우리 앱의 신고 상세 링크는 이 코드의 최초 실행·실행 중 복귀 라우팅 계약과 일치한다.
링크 수신과 화면 경로 해석은 실제 계정의 상세 조회 성공과 별개다.
실행한 검증과 미검증 범위는 [CHANGELOG.md](../../CHANGELOG.md)의
「공식 앱 3.2.8 딥링크 문서 최신화」에 기록한다.

## 신고 상세 URI

```text
appsafetyreport://view?openpage=true&c_no={내부 신고ID}&ext_path=M_MY_01_S0002.html&mem_yn=Y
```

| 항목 | 현재 계약 |
|---|---|
| scheme / host | `appsafetyreport` / `view` |
| `openpage` | 우리 앱은 `true`를 보낸다. 공식 JS의 분기 조건은 `scheme.indexOf('openpage') > -1`로, 값이 `true`인지 검사하는 방식은 아니다. 호환을 위해 현재 값을 유지한다. |
| `c_no` | 내부 신고 ID(`C_NO` → `Report.id`). 표시용 접수번호(`Report.reportNumber`)와 구분한다. |
| `ext_path` | 일반 신고 상세 `M_MY_01_S0002.html` |
| `mem_yn` | 우리 앱은 `Y`를 유지한다. `openpage` 분기에서는 읽지 않으며, 최초 실행의 구형 `c_no` 분기에서 사용한다. 인증을 대신하지 않는다. |

`openpage`가 없는 구형 링크는 최초 실행에서 `c_no` 분기를 탈 수 있지만,
실행 중 복귀의 공통 라우터에는 같은 분기가 없다. 따라서 현재 `openpage=true`를 제거하지 않는다.

## 공식 앱 처리 흐름

### Android 수신

[AndroidManifest.xml](../../kr.go.safepeople-328/resources/AndroidManifest.xml)의
`kr.go.safepeople.kotlin.activities.SchemeHandlerActivity`가 `ACTION_VIEW`,
`DEFAULT`, `BROWSABLE`과 함께 `appsafetyreport://view` 및 `appsafetyreport://chatbot`을 받는다.
`exported=true`, `launchMode=singleTask`다. 같은 필터에는 Kakao 공유 스킴도 선언되어 있다.

[SchemeHandlerActivity.java](../../kr.go.safepeople-328/sources/kr/go/safepeople/kotlin/activities/SchemeHandlerActivity.java)는
URI의 query를 `view` 경로에서는 `urlscheme`, `chatbot`에서는 `chatbot-linkdata` 전역 값에 저장한다.
`requestInfo`가 있으면 별도로 SharedPreferences에 보관한다.
`onCreate`에서 자신이 task root이면 패키지의 런처 Intent를 실행하고 종료한다.
`Startup`은 런처 진입점이며, 현재 딥링크를 직접 수신하는 Activity는 아니다.

### 최초 실행

[M_SPL_01_S0001.js](../../kr.go.safepeople-328/resources/assets/res/www/js/ui/M_SPL_01_S0001.js)의
`openpage` 분기에서 `c_no` → `global.loadCno`, `ext_path` → `MAIN_PAGE`,
`tab_id` → `global.pageTabId`로 해석한다.
화면 이동 시 `M.page.html(MAIN_PAGE, ...)`에 `cNo: global.loadCno`를 전달한다.

### 실행 중 복귀

[common_api.js](../../kr.go.safepeople-328/resources/assets/res/www/js/common/common_api.js)의
`M.onResume`이 `urlscheme`을 읽고 `openpage` 분기에서 다음 값으로 이동한다.

```javascript
M.page.html(page_path, {
    action: 'CLEAR_TOP',
    animation: 'MODAL_UP',
    param: { cNo: c_no, tabid: tab_id },
    orientation: 'DEFAULT'
});
```

처리 후 `urlscheme`과 `chatbot-linkdata`를 비운다. 위 코드는 해당 호출 부분의 발췌다.

### 상세 조회와 인증

[M_MY_01_S0002.js](../../kr.go.safepeople-328/resources/assets/res/www/js/ui/M_MY_01_S0002.js)는
전달된 `cNo`로 `api/singo/mySingoDetail`을 조회한다.
제공된 소스에는 `JwtManager`의 사용 가능한 회원 토큰과 `guest_reports` capability를 확인하는
인증 게이트가 있다. 자격이 없으면 로그인으로 이동하며 신고 식별자를 전달한다.
우리 앱의 링크 자체가 공식 앱의 로그인 자격을 전달하거나 만들어 주지는 않는다.
공식 앱에 같은 신고를 조회할 수 있는 계정으로 로그인한 상태를 전제로 안내한다.

## 화면 경로

기존 화면 목록을 유지한다. 일반 신고는 `M_MY_01_S0001.js`의 `getDetail()`에서
`M_MY_01_S0002.html`로 이동하며, `cRelation2 == '3'`인 제안은 `S0006`으로 분기한다.
아래 목록은 각 화면의 실제 실행 검증을 뜻하지 않는다.

| 파일명 | 페이지 제목 | 용도 | 비고 |
| :--- | :--- | :--- | :--- |
| **M_MY_01_S0001.html** | 나의신고 | 나의신고 **목록** | 신고 유형별 탭 포함 |
| **M_MY_01_S0002.html** | 나의신고 상세 | 나의 안전신고 **상세** | ✅ **딥링크 대상** (기본 라우팅 목적지) |
| **M_MY_01_S0003.html** | (미확인) | 나의신고 관련 서브 페이지 | - |
| **M_MY_01_S0004.html** | (구)생활불편신고 | (구)생활불편신고 **목록** | navbar-brand 직접 확인 |
| **M_MY_01_S0005.html** | (구)생활불편신고 | (구)생활불편신고 **상세** | trcode: `api/singo/mySBSingoDetail` |
| **M_MY_01_S0006.html** | 나의 국민안전제안 | 안전 **제안** 상세 | `cRelation2 == '3'`일 때 라우팅 |
| **M_MY_01_S0007.html** | (구)스마트국민제보 | (구)스마트국민제보 **목록** | navbar-brand 직접 확인 |
| **M_MY_01_S0008.html** | (구)스마트국민제보 | (구)스마트국민제보 **상세** | navbar-brand 직접 확인 |

## 우리 앱 구현

[report_detail_sheet.dart](../../lib/widgets/report_detail_sheet.dart)의
`buildSafetyReportAppUri(report.id)`를 공통 상세 시트에서 사용한다.
Client와 Standalone의 화면 이동 링크 생성은 같은 코드다.
[Report.fromJson](../../lib/models/report.dart)은 `ID`를 `id`로 읽고,
[Standalone 파서](../../lib/services/standalone_parser.dart)는 `C_NO`를 `id`로 보존한다.

```dart
Uri buildSafetyReportAppUri(String reportId) {
  return Uri(
    scheme: 'appsafetyreport',
    host: 'view',
    queryParameters: {
      'openpage': 'true',
      'c_no': reportId,
      'ext_path': 'M_MY_01_S0002.html',
      'mem_yn': 'Y',
    },
  );
}

// 기존 상세 시트에서 호출한다. 새 URI 조립 코드를 따로 만들지 않는다.
final uri = buildSafetyReportAppUri(report.id);
final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
```

실제 `_openInSafetyApp`은 빈 ID를 먼저 검사하고, `launchUrl`의 false 반환과 예외를 처리한다.
현재 실패 안내는 모두 “안전신문고 앱이 설치되어 있지 않습니다.”이므로 이 문구만으로
실패 원인이 미설치라고 확정할 수는 없다. 성공 반환도 Android에 실행을 요청했다는 뜻이며,
공식 앱의 인증·상세 응답 성공까지 보장하지 않는다.

[우리 앱 AndroidManifest.xml](../../android/app/src/main/AndroidManifest.xml)의
`queries`에 `ACTION_VIEW` / `appsafetyreport`가 선언되어 있다.
이 설정은 외부 공식 앱용이며, 커뮤니티 로그인 복귀 수신 필터와 별개다.
이 명세는 Android 대상이다. 기존 문서의 iOS 예시는 검증된 지원 계약으로 사용하지 않는다.

## 코드 대조 정정

| 기존 설명 | 코드에 맞는 설명 |
|---|---|
| Flutter 예제에서 `openpage` 생략 | 현재 생성 함수처럼 `openpage=true`를 포함한다. |
| `Startup`이 딥링크 수신 | `SchemeHandlerActivity`가 수신하고 필요한 경우 런처를 실행한다. |
| `openpage`의 값 `true`를 검사 | JS는 query 안의 `openpage` 문자열 존재로 분기한다. 보내는 값은 계속 `true`로 유지한다. |
| `chatbot?cno={ID}&url={PAGE}`는 동등한 대안 | 최초 실행에서는 `cno`를 읽지만 복귀 라우터는 상세용 `cNo`를 전달하지 않는다. 일반 신고 상세 링크의 대체 수단으로 쓰지 않는다. |
| 상세 화면은 회원 전용이며 인증은 세션 쿠키뿐 | 제공된 상세 소스에는 회원 JWT와 비회원 capability 분기가 있다. 링크만으로 조회 권한이 생기지는 않는다. |
| 모든 API는 `m.safetyreport.go.kr`로 향함 | `constant.js`의 주석 처리된 URL만으로 모든 요청 목적지를 확정할 수 없다. 우리 앱 Standalone은 `www.safetyreport.go.kr`를 사용한다. |
| exported Service가 없으므로 IPC 불가 | 시스템용 exported Service도 있어 “없음”은 부정확하다. exported 여부만으로 신고 데이터 조회 계약이 있다는 뜻은 아니다. |
| 서버 크롤링이 유일한 수집 수단 | Client는 사용자 서버의 크롤링, Standalone은 별도 인증 후 직접 API 동기화를 사용한다. |

## 데이터 접근 경계

딥링크는 공식 앱 화면을 여는 경로이며, 우리 앱으로 신고 상세 데이터나 인증정보를 반환하는
API로 취급하지 않는다. 일반 앱 권한으로 다른 앱의 private 파일·DB·WebView 저장소를
직접 읽는 방식도 우리 앱의 데이터 수집 경로가 아니다.

기존 문서의 Provider 목록과 “IPC/AIDL 전수 조사로 접근 불가”라는 결론은 이번 딥링크 검증으로
전체 재검증한 내용이 아니다. 공개 데이터 인터페이스가 있는지 판단하려면 개별 컴포넌트의
권한과 실제 구현을 별도로 확인해야 한다.

우리 앱의 실제 조회 경로는 [data-contracts.md](data-contracts.md),
[StandaloneApiService](../../lib/services/standalone_api_service.dart),
[StandaloneAuthService](../../lib/services/standalone_auth_service.dart)를 기준으로 한다.
