주어진 환경(`env.txt`)과 소스 코드를 분석하여 Flutter/Android 테스트 도구의 UI 리뉴얼 적용 가능성을 검토한 결과입니다.

## 도구별 판정

| 도구 | 적용 가능 | 전제조건 | 위험 | 근거 | 권고 순위 |
| --- | --- | --- | --- | --- | --- |
| `flutter_test` (위젯 테스트) | 가능 | 없음 | `ApiService` 등이 하드코딩되어 있어 `ReportProvider`나 네트워크 레이어 모킹 필요 | `pubspec.yaml:65` (`flutter_test` 존재) | 1 |
| 접근성 Guideline API | 가능 | 위젯 테스트와 동일 | 없음 | `flutter_test` 기본 내장 기능 | 1 |
| `matchesGoldenFile` (골든 테스트) | 가능 | 한국어 폰트 명시적 로드 필요 (`loadAppFonts()` 등) | 기본 폰트(Ahem) 사용 시 글자가 네모로 깨짐. OS/렌더링 엔진(Impeller) 차이로 인한 미세 픽셀 차이 발생 | 지식 기반(미검증) | 2 |
| `integration_test` | 부분 가능 | `pubspec.yaml`에 패키지 추가, `android/app/build.gradle.kts`에 `testInstrumentationRunner` 설정 필요 | 샌드박스로 인해 에뮬레이터 조작이 불가하여 현재 셸 환경에서는 직접 실행 불가 | `env.txt:9` (`adb` 기기 없음) | 3 |
| Patrol | 불가 | `patrol_cli` 설치 및 Android 네이티브(Gradle, Manifest) 설정 권한 | 네트워크 접근 제한 및 셸 샌드박스 오류로 인해 CLI 설치와 기기 구동 불가능 | `env.txt:10` (`patrol: not installed`) | 4 |
| Dart/Flutter MCP | 불가 | 셸을 통한 MCP 서버 실행 및 네트워크 통신 허용 필요 | 샌드박스 및 네트워크 차단 규칙 위반 | 사용자 규칙(셸/네트워크 금지) | - |
| Android CLI / 에뮬레이터 | 불가 | 셸 환경 및 네트워크 접근 권한 복구 필요 | 샌드박스 제약으로 인해 실행 시도 시 차단됨 | 사용자 규칙(셸 금지) | - |


## 기존 테스트 분석
현재 `test/` 폴더 내에 존재하는 테스트 종류와 회귀(Regression) 방지 목적은 다음과 같습니다.
1. **`report_navigation_regression_test.dart`**: 카테고리가 없는 알림 클릭 시 갱신 로직 회귀 방지, 상단 `TabBar`의 UI 상태 단언.
2. **`services/server_connection_service_test.dart`**: 서버 응답 코드(200, 401 등) 및 Payload 파싱 성공 여부 회귀 방지.
3. **`services/local_db_service_regression_test.dart`**: 백업 복원 시 지도 동기화 메타데이터 꼬임, 잘못된 주소 좌표 파싱 충돌 등의 오프라인 DB 동작 회귀 방지.

**TabBar 색상 단언의 문제점**
새로운 테마 적용 시 `report_navigation_regression_test.dart` (116~119줄)의 다음 코드는 실패하게 됩니다.
```dart
expect(tabBar.labelColor, Colors.white);
expect(tabBar.unselectedLabelColor, Colors.white70);
```
새 테마(Material 3 등)가 적용되면 하드코딩된 `Colors.white`가 아닌, 동적 테마 색상(`colorScheme.onPrimary` 등)이 할당될 수 있습니다. 이를 해결하려면 고정된 색상을 단언하지 않고, **선택/미선택 상태의 대비(contrast) 차이를 검증**하거나, `Theme.of(context)`를 활용하여 현재 적용된 테마의 의미론적 색상과 일치하는지를 검증하는 방식으로 바뀌어야 합니다.

## mock/fixture 전략

UI 리뉴얼 시 위젯/골든 테스트를 원활히 하기 위한 의존성 모킹 전략입니다.

* **sqflite**: 메모리 또는 임시 파일 기반 DB를 위해 `sqflite_common_ffi`를 사용합니다 (`databaseFactory = databaseFactoryFfi;`).
* **SharedPreferences**: `SharedPreferences.setMockInitialValues({});` 로 메모리 상에서 가짜 값을 주입합니다.
* **flutter_secure_storage**: `setMockInitialValues()` (버전에 따라) 지원 또는 MethodChannel(`plugins.it_nomads.com/flutter_secure_storage`)을 직접 가로채어 모킹해야 합니다.
* **video_player / MethodChannel**: `TestDefaultBinaryMessengerBinding`을 활용해 해당 플러그인의 MethodChannel 호출을 가로채고 더미 응답을 반환합니다.
* **flutter_map**: 네트워크 기반 TileProvider 대신, 빈 이미지를 반환하거나 내부 에셋을 반환하는 `MockTileProvider`를 사용하여 네트워크 차단 환경에서의 타임아웃을 방지합니다.
* **cached_network_image**: `HttpOverrides.global`을 지정하거나 Mock `CacheManager`를 주입하여, 네트워크 이미지 요청 시 1x1 투명 픽셀이나 더미 로컬 바이트를 반환하도록 합니다.

**Fixture 주입 지점 (경로 및 줄 번호)**
* **`ReportProvider`**: 의존성 주입 컨테이너 역할이 가능. `test/report_navigation_regression_test.dart:108`에서 `ChangeNotifierProvider.value()`를 통해 화면 트리에 Fake Provider를 주입하여 제어합니다.
* **`ApiService` (Client)**: `lib/providers/report_provider.dart:878`에 `ApiService get _api => ApiService(...)` 형태로 내부 인스턴스화 로직이 **하드코딩**되어 있습니다. 따라서 생성자 DI가 불가능하므로, 위젯 테스트 시에는 `ReportProvider` 자체를 상속(`_RecordingReportProvider`)하여 Mocking하거나, 전역 `HttpOverrides`로 API 호출을 가로채야 합니다.
* **`LocalDbService` (Standalone)**: `test/services/local_db_service_regression_test.dart:156`에서 `databaseFactoryFfi`로 교체하여 static SQLite 호출을 파일/메모리 레벨에서 낚아챕니다(Intercept). 별도의 인스턴스 주입 지점은 없습니다.

**골든 테스트용 한글 폰트 로딩 필요성**
위젯 테스트 환경은 기본적으로 `Ahem` 폰트를 사용하므로, 텍스트가 모두 검은색 사각형으로 렌더링됩니다. 이 상태로 골든 테스트를 하면 한글 텍스트의 오버플로우나 여백을 제대로 검증할 수 없습니다. 따라서 테스트 시작 전 `loadAppFonts()` 등을 통해 실제 Noto Sans KR이나 Roboto 등의 폰트 에셋을 명시적으로 로딩해야 정상적인 스크린샷 렌더링이 가능합니다.

**integration_test/Patrol 도입 시 요구사항**
* `android/app/build.gradle.kts` 의 `defaultConfig` 내에 `testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"` 설정이 추가되어야 합니다.
* **Production Entrypoint 진입 금지**: `integration_test` 바인딩 초기화 로직은 `lib/main.dart`에 포함되면 안 됩니다. 배포용 빌드에 테스트 패키지 API가 섞여들어가면 앱 크기 증가, 보안 문제, 불필요한 퍼포먼스 저하가 발생할 수 있습니다. 반드시 별도의 진입점(예: `integration_test/app_test.dart`)을 생성하여 구동해야 합니다.

## 환경 blocker

현재 로컬 환경(`.review-inputs/env.txt`)을 기준으로 작업 가능 여부는 다음과 같습니다.

* **즉시 가능한 것**: `flutter_test` 패키지를 이용한 단위 및 위젯 테스트 코드 작성, FFI를 활용한 `sqflite` 오프라인 DB 테스트.
* **설치가 필요한 것**: Patrol 테스트 자동화를 위한 `patrol_cli` 패키지 및 Android CLI 도구.
* **막힌 것 (Blocker)**: 셸 환경 샌드박스 오류 및 네트워크 조회 금지 규칙으로 인해, 누락된 `patrol_cli`의 외부 다운로드 및 설치가 원천 차단됩니다. 또한 `adb`에 연결된 기기/에뮬레이터가 없으나 에뮬레이터를 강제 실행할 셸 권한이 없으므로, **현재 환경에서는 Integration/Patrol 테스트 구동 자체가 불가능합니다.**

---

## 실행 증거
**열어본 파일 목록**
* `.review-inputs/env.txt`
* `.review-inputs/analyze.log`
* `.review-inputs/test.log`
* `pubspec.yaml`
* `.review-inputs/file_index.tsv`
* `test/report_navigation_regression_test.dart`
* `lib/providers/report_provider.dart`
* `lib/services/api_service.dart`
* `lib/services/local_db_service.dart`
* `android/app/build.gradle.kts`
* `test/services/server_connection_service_test.dart`
* `test/services/local_db_service_regression_test.dart`
* `test/widget_test.dart`
* `lib/main.dart`

**확인하지 못한 항목 (미확인)**
* Patrol 및 통합 테스트 구동 (에뮬레이터 및 셸 사용 불가로 인한 실행 제약)
* Android Manifest 상세 설정(`android/app/src/main/AndroidManifest.xml`) (빌드 스크립트만으로도 통합 테스트 전제 조건을 파악할 수 있어 조회 생략)
