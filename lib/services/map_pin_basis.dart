// 신고 지도 핀 기준의 순수 규칙(2026-10-05). Standalone 계산(LocalDbService)과 Client 요청(ApiService)이 함께 쓴다.

/// 주소키·장소 문구·핀 기준 값의 앞뒤에서 지우는 문자(서버 Python `str.strip()` 기본 집합).
/// 정본 목록은 공용 벡터 `contracts/map-pin-basis-vectors.json` 의 `strip_code_points`.
/// Dart `trim()`(BOM 을 지우고 U+001C~U+001F 는 남김)·SQLite `trim()`(공백만) 과 다르다.
const mapStripCodePoints = <int>[
  0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x85, 0xa0,
  0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
  0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
];
final _stripSet = mapStripCodePoints.toSet();

String stripMapText(Object? value) {
  final runes = (value?.toString() ?? '').runes.toList();
  var start = 0, end = runes.length;
  while (start < end && _stripSet.contains(runes[start])) {
    start++;
  }
  while (end > start && _stripSet.contains(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes, start, end);
}

/// 'address' 외 모두 'coords'. 앞뒤 공백(위 집합)·대소문자는 무시한다(서버 `normalize_pin_basis` 와 같음).
String normalizeMapPinBasis(String? value) =>
    stripMapText(value).toLowerCase() == 'address' ? 'address' : 'coords';
