/// 화면에 보이는 숫자 표기 공용 함수(SQ-U22).
///
/// 건수·금액은 모두 세 자리마다 쉼표를 찍는다. 금액은 "9만 5,000원" 같은 만 단위 표기를 쓰지 않고
/// 통계 요약 카드와 같은 전체 쉼표 표기("950,520,000원")로 통일한다.
/// 표시 전용이다 — 집계·저장 값은 바꾸지 않는다.
library;

final RegExp _thousands = RegExp(r'(\d)(?=(\d{3})+(?!\d))');

/// 쉼표만 찍은 숫자. 소수점 아래는 버린다. `1234` → `1,234`, `-1234` → `-1,234`.
String formatNumber(num value) =>
    value.toInt().toString().replaceAllMapped(_thousands, (m) => '${m[1]},');

/// 건수. `1234` → `1,234건`.
String formatCount(num value) => '${formatNumber(value)}건';

/// 금액(원). `950520000` → `950,520,000원`.
String formatWon(num value) => '${formatNumber(value)}원';
