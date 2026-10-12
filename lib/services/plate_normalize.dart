/// 세 레포(safetyreport, safetyreport-mobile, safetyreport-community-map) 공통 번호판 정규화.
///
/// **원문은 절대 바꾸지 않는다.** 이 모듈은 로컬 DB 저장값(`차량번호`)을 그대로 두고 "읽을 때"(통계,
/// 중복차량, 추정 과태료 차종 판정 등) 번호판 토큰만 뽑아내는 순수 함수다. 세 레포가 같은 규칙을 쓴다 —
/// 하나를 바꾸면 세 레포의 공유 벡터 파일(바이트 동일)과 이 문서를 함께 바꾼다:
///   - safetyreport:                tests/fixtures/plate_normalize_vectors.json
///   - safetyreport-mobile:         test/fixtures/plate_normalize_vectors.json
///   - safetyreport-community-map:  tests/fixtures/plate_normalize_vectors.json (server/plate.ts 가 같은 규칙)
///
/// ## 규칙 (경계 규칙 포함, 2026-10-12 사용자·Opus 결정)
/// 1. NFKC 정규화 → 공백 전부(스페이스·탭·NBSP·전각공백 등) · 유니코드 서식 문자(Unicode category Cf —
///    제로폭 공백/조인터, LRM/RLM, bidi 제어, BOM 등, 실제로 섞여 있어도 보이지 않으므로 통째로 제거) ·
///    하이픈(`-`, NFKC 가 전각 하이픈도 반각으로 접어 주므로 이 한 글자만 지우면 된다) 제거.
/// 2. 남은 문자열에서 "지역 접두(17개 시·도 공식명/약칭 — 지도 서버 `server/plate.ts` 의 region 사전과
///    값이 같다, 긴 이름부터 시도) + 본문" 패턴과 일치하는 구간을 전부 찾는다.
///    본문 = 일반형(숫자 2~3자리 + 한글 1자 + 숫자 4자리, `fine_estimate.dart` `_plateRe` 와 같음)
///         또는 이륜형(숫자 0~1자리 + 한글 1자 + 숫자 0~1자리 + 숫자 4자리, `_motorcycleRe` 와 같음).
/// 3. 찾은 구간의 바로 앞/뒤 문자가 숫자(0-9) 또는 한글(음절 가-힣, 또는 낱자모 ㄱ-ㅎ/ㅏ-ㅣ)이면 그
///    구간은 버린다("경계가 애매하면 null") — `81수0136수`(번호판 뒤에 한글 한 글자가 구분자 없이 더
///    붙음), `25어95505`(끝 숫자가 5개 — 4자리를 넘는 초과분이 경계에 붙음), `0006마8861`(지역번호
///    2~3자리를 넘는 초과분이 앞 경계에 붙음) 같은 자리수 오류·군더더기를 걸러낸다.
///    구두점·기호·영문·다른 언어 문장은 경계로 허용한다 — `177도7967)`, `235호2929/흰색SUV차량입니다.`
///    는 통과. (공백은 2단계에서 모두 지우므로, 설명 문구와 번호판 사이에 공백만 있고 다른 구분자가
///    없으면 경계가 사라져 모호로 처리될 수 있다. 실데이터의 설명 붙은 사례는 모두 `/` 로 구분되어
///    있어 영향이 없었다.)
/// 4. 경계를 통과한 서로 다른 후보 문자열이 정확히 1개면 그 값(지역은 약칭으로 정규화)을 반환한다.
///    0개(미인식·날짜·숫자만·자모 섞임·자리수 오류 등) 또는 2개 이상(서로 다른 후보)이면 null —
///    추측하지 않는다.
///
/// 입력이 64자를 넘으면(원문 그대로 저장되는 업로드 payload 상한과 같음) null.
library;

// 지도 서버 server/plate.ts 의 `regions` 사전과 키/값이 같아야 한다 — 세 레포 공통 정의.
final Map<String, String> _regionMap = () {
  final base = <String, String>{
    '서울특별시': '서울', '부산광역시': '부산', '대구광역시': '대구', '인천광역시': '인천',
    '광주광역시': '광주', '대전광역시': '대전', '울산광역시': '울산', '세종특별자치시': '세종',
    '경기도': '경기', '강원특별자치도': '강원', '강원도': '강원', '충청북도': '충북',
    '충청남도': '충남', '전북특별자치도': '전북', '전라북도': '전북', '전라남도': '전남',
    '경상북도': '경북', '경상남도': '경남', '제주특별자치도': '제주', '제주도': '제주',
  };
  for (final short in base.values.toSet()) {
    base.putIfAbsent(short, () => short);
  }
  return base;
}();

final String _regionAlt = (() {
  final keys = _regionMap.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  return keys.join('|');
})();

// 일반형 — fine_estimate.dart `_plateRe` 의 숫자+한글+숫자 부분과 같다.
const String _carBody = r'\d{2,3}[가-힣]\d{4}';
// 이륜형(완화된 형태) — fine_estimate.dart `_motorcycleRe` 와 같다.
const String _motoBody = r'\d{0,1}[가-힣]\d{0,1}\d{4}';

final RegExp _tokenRe = RegExp('($_regionAlt)?($_carBody|$_motoBody)');
// 토큰 경계: 숫자 또는 한글(음절/낱자모)이 바로 붙어 있으면 경계가 불분명하다.
final RegExp _adjacentRe = RegExp(r'[0-9ᄀ-ᇿㄱ-ㆎ가-힣]');
final RegExp _stripRe = RegExp(r'[-\s]');

// Dart 의 String.normalize 가 없는 일부 플랫폼(net 영향 없음)을 고려해 NFKC 를 직접 구현하지 않고,
// intl 패키지 없이도 동작하도록 실제 데이터에서 쓰이는 전각 숫자/하이픈만 좁게 접는다. 나머지(결합
// 문자 등)는 Unicode category Cf 제거로 충분히 처리된다 — PC/지도 레포(NFKC 전체 지원)와 결과가
// 같은지는 공유 벡터(plate_normalize_vectors.json)로 맞춘다.
String _foldFullwidth(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0); // 전각 ASCII → 반각 ASCII(숫자 포함)
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Unicode category Cf(서식 문자: 제로폭 공백/조인터, LRM/RLM, bidi 제어, BOM 등).
bool _isFormatChar(int rune) {
  return (rune == 0x00AD) ||
      (rune >= 0x0600 && rune <= 0x0605) ||
      (rune == 0x061C) ||
      (rune == 0x06DD) ||
      (rune == 0x070F) ||
      (rune == 0x08E2) ||
      (rune == 0x180E) ||
      (rune >= 0x200B && rune <= 0x200F) ||
      (rune >= 0x202A && rune <= 0x202E) ||
      (rune == 0x2060) ||
      (rune >= 0x2061 && rune <= 0x2064) ||
      (rune >= 0x2066 && rune <= 0x206F) ||
      (rune == 0xFEFF) ||
      (rune >= 0xFFF9 && rune <= 0xFFFB) ||
      (rune == 0x110BD) ||
      (rune == 0x110CD) ||
      (rune >= 0x13430 && rune <= 0x13438) ||
      (rune == 0x1BCA0) ||
      (rune >= 0x1D173 && rune <= 0x1D17A) ||
      (rune == 0xE0001) ||
      (rune >= 0xE0020 && rune <= 0xE007F) ||
      (rune >= 0xE0100 && rune <= 0xE01EF);
}

String _clean(String text) {
  text = _foldFullwidth(text);
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (!_isFormatChar(rune)) buffer.writeCharCode(rune);
  }
  return buffer.toString().replaceAll(_stripRe, '');
}

const int _maxRawLength = 64;

/// 원문에서 유효한 번호판 토큰을 정확히 하나 찾으면 그 값을, 아니면 null 을 돌려준다. 원문은 바꾸지 않는다.
String? normalizePlate(dynamic raw) {
  if (raw == null) return null;
  final text0 = raw.toString();
  if (text0.length > _maxRawLength) return null;
  final text = _clean(text0);
  if (text.isEmpty) return null;

  final candidates = <String>{};
  for (final match in _tokenRe.allMatches(text)) {
    final body = match.group(2);
    if (body == null || body.isEmpty) continue;
    final start = match.start, end = match.end;
    if (start > 0 && _adjacentRe.hasMatch(text[start - 1])) continue;
    if (end < text.length && _adjacentRe.hasMatch(text[end])) continue;
    final regionMatch = match.group(1) ?? '';
    final region = _regionMap[regionMatch] ?? regionMatch;
    candidates.add(region + body);
  }

  if (candidates.length == 1) return candidates.first;
  return null;
}
