요청하신 '디자인 시안 vs 실제 기능 대조' 작업(작업 B)의 분석 결과입니다.

## 1. 요소 분류
| 이미지 | 요소 | 분류 | 근거 | 비고 |
|---|---|---|---|---|
| mobile dark / white.png | 하단 탭 7개 | existing | `lib/main.dart`:1013 (NavigationBar) | 시안 하단 캡션은 5개로 그룹핑했으나 시각적 아이콘과 실제 코드는 7개로 동일하게 구현됨. |
| mobile dark / white.png | 알림 탭 내 '시스템 공지' | unsupported | `lib/screens/notifications_screen.dart`:411 | `NotificationItemKind`에 시스템 공지 모델이 정의되어 있지 않음. |
| mobile dark / white.png | 알림/크롤링 세그먼트 버튼 | presentation-change | `lib/screens/notifications_screen.dart`:457 | 시안은 4개 항목을 보여주나 실제 탭은 '크롤링 현황', '신고 결과', '별점 주기' 3개로 구성됨. |
| board.png | 빈 상태 내 "파일 업로드" | unsupported | `lib/screens/file_browser_screen.dart`:1 (전체) | 파일 조회 기능은 있으나, 사용자의 일반 파일 업로드 버튼 및 기능은 코드에 없음. |
| board.png | 데이터 없음/네트워크 오류 화면 | existing | `lib/screens/dashboard_screen.dart`:67 (_buildErrorState) | 상황에 따른 빈 상태 및 오류 UI가 처리되어 있음. |
| UI COMPONENT KIT.png | 모바일 탭 (별점, 감시목록 등) | existing | `lib/screens/report_management_screen.dart`:48 | 시안의 4개 탭(별점, 감시 목록, 중복 신고, 데이터 수정)이 코드에 그대로 구현됨. |
| UI COMPONENT KIT.png | Side Navigation (관리자 웹) | pc-only | 코드 근거 없음 | 모바일 앱(lib/)에는 좌측 데스크톱 사이드바 네비게이션이 없음. |
| UI COMPONENT KIT.png | 13. Table / 20. Pagination | pc-only | 코드 근거 없음 | 모바일 앱은 무한 스크롤 및 카드 리스트(`report_list_card.dart`) 형태로 렌더링됨. |
| UI COMPONENT KIT.png | 10. Floating Action (신고하기) | unsupported | `lib/main.dart` 앱 구조 | 앱 안내에 신고 접수 기능이 없다고 명시되어 있으며, 해당하는 새 레코드 생성 기능이 없음. |
| UI COMPONENT KIT.png | 18. Bottom Sheet "선택 삭제" | unsupported | 미확인 | 코드를 살펴본 결과 신고 데이터를 사용자가 임의로 삭제하는 기능은 확인되지 않음. |

---

## 2. 집계/수치 오류
1. **합계 불일치 및 백분율 모수 오류**: `mobile dark.png` 좌측 대시보드에서 '총 신고 3,037건'과 하위 상태들(수용 2,092건+일부 470건+불수용 304건+취하 113건+처리중 58건)의 합은 정확히 3,037로 일치합니다. 그러나 '수용'의 비율로 표기된 **71.5%**는 총 신고수(3,037건)나 처리 완료(2,979건) 기준과 맞지 않는 임의의 모수(약 2,925건)를 기준으로 계산된 디자인상의 오류입니다.
2. **도넛 차트 항목 누락**: `mobile dark.png` 04.통계 화면 및 `guide.png`의 처리결과 도넛 차트 중앙에는 '총 3,037건'이라 적혀 있으나, 정작 차트 조각과 범례에서는 **처리 중(58건)** 데이터가 완전히 누락되어 있습니다.
3. **중복차량을 네 번째 카테고리로 합산**: `guide.png` 상단 차트 툴팁에서 월간 합계(1,642건)를 '교통위반 + 주정차위반 + 기타위반 + 중복차량'으로 계산했습니다. 중복차량은 기존 카테고리들과 중첩되는 속성이므로 합산 시 숫자가 뻥튀기되는 **이중 계산(Double Counting)** 통계 오류입니다. (실제 코드의 `ReportListScreen`에서도 탭은 존재하나 별도의 중복 필터 역할만 수행합니다.)
4. **전기 대비 증감률 기능 부재**: `mobile dark.png` 04.통계 화면에 '총 신고 +12%', '평균 처리기간 -12%' 등 전기 대비 비교 지표가 표시되나, 실제 앱 코드(`ReportProvider` 등)에는 과거 기간 데이터를 비교 호출하는 집계 로직이 없습니다 (디자인상 하드코딩된 더미 수치).
5. **평균 처리기간의 비현실성**: `mobile dark.png` 04.통계 화면 내 평균 처리기간이 '58.6일'로 매우 비현실적으로 길게 설정되어 있습니다.
6. **과태료 월별 합계의 기준 날짜 오류**: `guide.png`의 과태료 금액 요약 차트에서 과태료를 단순히 '월별 민원 신고일' 기준으로 합계 내고 있습니다. 이는 실제 과태료 부과 시점 및 회계 기준과 일치하지 않는 논리적 오류를 내포합니다.

---

## 3. 이미지 간 충돌
| 항목 | 이미지별 값 | 권고 (결정 필요 여부) |
|---|---|---|
| **로고 형태** | `LOGO.png`, `white banner.png`: '방패와 꼬깔콘' 아이콘<br>`favicon.png`, `dark banner.png`: '카메라와 느낌표' 아이콘 | 메인 심볼 2종이 충돌 중이므로 최종 사용할 하나의 앱 로고 디자인 결정 필요. |
| **타이포그래피** | `design tokens.png`: 가독성을 위한 **Noto Sans KR** 사용 명시<br>`guide.png`: 기존 서비스와 동일한 **Pretendard** 사용 명시 | 모바일 UI에 적용할 메인 시스템 폰트 통일 및 결정 필요. |
| **상태색 Hex (수용)** | `design tokens.png` Semantic Colors: **#22C55E** (밝은 초록)<br>`guide.png` 보조 컬러 가이드: **#10B981** (청록) | 메인 브랜드 컬러 및 데이터 시각화의 통일성을 위해 색상 코드 하나로 결정 필요. |
| **하단 탭 구조** | `mobile dark.png` 하단 캡션 텍스트는 5개 메뉴로 설명되나, 실제 이미지의 네비게이션 바와 `UI COMPONENT KIT.png`는 7개 아이콘 배치를 보여줌. | 아이콘 및 코드 구현체(7개)와 동일하게 가이드를 7개 탭 체제로 수정 권고. |

---

## 4. 에셋 판정
| 파일 | 용도 후보 | 런타임 사용 가능성 | 이유 |
|---|---|---|---|
| **LOGO.png** | 앱 구동 및 헤더 로고 | 정제 필요 | Light/Dark 두 버전이 한 이미지 파일에 묶여있고 흰색 텍스트 박스와 여백이 렌더링되어 있어 런타임에 직접 띄울 수 없음. 배경 투명화 및 분리 작업 필요. |
| **favicon.png** | 런처 아이콘 | 정제 필요 | 고해상도 정사각형 이미지이나, 실제 모바일 기기(AOS/iOS)의 둥근 모서리 및 알파 채널 규격에 맞는 여백 컷팅 확인 필요. |
| **icons.png** | UI 네비게이션 아이콘 | 불가 | 여러 아이콘이 한 장표에 나열된 프리젠테이션용 스프라이트 이미지. Flutter 런타임 적용을 위해 개별 벡터(SVG) 파일이나 자체 폰트 아이콘으로 쪼개어 전달받아야 함. |
| **badge.png** | 리스트/카드 상태 뱃지 | 불가 | '처리중', '수용' 등 텍스트가 픽셀로 이미지에 구워져 있어 다국어 대응, 크기 유동 조절, 다크 테마 전환이 불가. Flutter의 `Chip` 위젯으로 코딩 구현이 권장됨. |
| **dark/white banner.png** | 스플래시 스크린 | 정제 필요 | 디자인 비율이 가로형이어서 모바일 세로 기기에서 찌그러짐. 텍스트가 이미지에 포함되어 화면 해상도 대응이 불가하므로 배경 그래픽 분리 필수. |
| **sync.png** 등 | 동기화/통계 빈 화면 그래픽 | 정제 필요 | 모바일 화면 비율 내에 알맞게 들어가는지 리사이징 여부와 배경 Alpha 처리가 필요. |

---

## 5. 실행 증거
- **조회된 코드 및 구성 파일**:
  - `.review-inputs/file_index.tsv` (전체 파일 구조 확인)
  - `lib/main.dart`: 하단 NavigationBar 탭 7개 확인.
  - `lib/screens/dashboard_screen.dart`: 대시보드 상태 차트 및 오류 위젯 렌더링 검토.
  - `lib/screens/notifications_screen.dart`: 알림화면 탭 3개 구조 분리 및 '시스템 공지' 미존재 검토.
  - `lib/screens/file_browser_screen.dart`: 파일 탐색기 및 업로드 미존재 증명.
  - `lib/screens/report_management_screen.dart`: 신고관리 화면 4개 탭 구조 확인.
  - `lib/screens/report_list_screen.dart`: 교통/주정차/기타/중복차량 필터 구조 검토.
  - `lib/screens/statistics_screen.dart`: 통계 데이터 구성 검토.
- **열람된 디자인 이미지(14종 전체)**:
  - `.review-inputs/design/mobile dark.png`
  - `.review-inputs/design/mobile white.png`
  - `.review-inputs/design/board.png`
  - `.review-inputs/design/guide.png`
  - `.review-inputs/design/design tokens.png`
  - `.review-inputs/design/UI COMPONENT KIT.png`
  - `.review-inputs/design/badge.png`
  - `.review-inputs/design/icons.png`
  - `.review-inputs/design/LOGO.png`
  - `.review-inputs/design/favicon.png`
  - `.review-inputs/design/dark banner.png`
  - `.review-inputs/design/white banner.png`
  - `.review-inputs/design/sync.png`
  - `.review-inputs/design/data분석일러스트.png`
- **미확인 항목**:
  - 시안 내 바텀시트의 '선택 삭제' 등 구체적인 레코드 임의 삭제 트리거는, 앱 특징상 외부 동기화 읽기 위주의 클라이언트라 구현되지 않았을 것으로 보이나 파일 전체 상세 경로를 추적하지 않아 '미확인' 처리하였습니다.
  - 통계 API 및 과거년도 데이터 패치 로직 구현 여부는 프론트엔드 단독 구조만으로 서버 구현체를 특정할 수 없어 미확인으로 남겨두었습니다.
