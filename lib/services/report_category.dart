/// 안전신문고 SSNPC 코드와 메뉴를 서버와 동일한 5분류로 해석한다.
/// 정본: contracts/report-categories.json. 코드가 있으면 메뉴보다 우선한다.
library;

typedef Resolved = ({
  String? ssnpcCd,
  String? ssnpcType,
  String? code,
  String category,
});
typedef NormalizedCode = ({String? ssnpcCd, String? ssnpcType});

const categories = ["traffic", "parking", "safety", "living", "other"];
const categoryLabels = <String, String>{
  "traffic": "교통위반",
  "parking": "주정차위반",
  "safety": "안전신고",
  "living": "생활불편",
  "other": "기타",
};
const groupCategory = <String, String>{
  "TV": "traffic",
  "IP": "parking",
  "EP": "parking",
  "CM": "safety",
  "DR": "living",
};
const codes = <(String, String), ({String name, String category})>{
  ("CM", "01"): (name: "도로, 시설물 파손 및 고장", category: "safety"),
  ("CM", "02"): (name: "사업장 안전(건설·공사현장 등)", category: "safety"),
  ("CM", "03"): (name: "(구)지하수 미등록 시설·방치공", category: "safety"),
  ("CM", "04"): (name: "대기·수질오염", category: "safety"),
  ("CM", "05"): (name: "(구)쓰레기, 폐기물, 유독물", category: "living"),
  ("CM", "06"): (name: "(구)교통위반", category: "traffic"),
  ("CM", "07"): (name: "기타 안전·환경 위험요소", category: "safety"),
  ("CM", "08"): (name: "(구)자동차 안전신고", category: "traffic"),
  ("CM", "09"): (name: "대기오염", category: "safety"),
  ("CM", "10"): (name: "수질오염", category: "safety"),
  ("CM", "11"): (name: "소방안전", category: "safety"),
  ("CM", "12"): (name: "(구)감염병(코로나19)", category: "safety"),
  ("CM", "13"): (name: "계절별 집중신고", category: "safety"),
  ("CM", "14"): (name: "하천·계곡 내 불법시설", category: "safety"),
  ("CM", "15"): (name: "고층 건축물 화재 안전", category: "safety"),
  ("IP", "01"): (name: "소화전", category: "parking"),
  ("IP", "02"): (name: "교차로 모퉁이", category: "parking"),
  ("IP", "03"): (name: "버스정류소", category: "parking"),
  ("IP", "04"): (name: "횡단보도", category: "parking"),
  ("IP", "05"): (name: "어린이보호구역", category: "parking"),
  ("IP", "06"): (name: "인도", category: "parking"),
  ("EP", "01"): (name: "장애인전용구역", category: "parking"),
  ("EP", "02"): (name: "기타불법주정차", category: "parking"),
  ("EP", "03"): (name: "소방차전용구역", category: "parking"),
  ("EP", "04"): (name: "친환경차충전구역", category: "parking"),
  ("TV", "01"): (name: "자동차 안전신고", category: "traffic"),
  ("TV", "02"): (name: "교통위반(고속도로 포함)", category: "traffic"),
  ("TV", "03"): (name: "이륜차 위반", category: "traffic"),
  ("TV", "04"): (name: "(구)적재물 추락방지,중량·용량 위반", category: "traffic"),
  ("TV", "05"): (name: "버스전용차로 위반(고속도로제외)", category: "traffic"),
  ("TV", "06"): (name: "번호판 규정 위반", category: "traffic"),
  ("TV", "07"): (name: "불법등화, 반사판(지) 가림·손상", category: "traffic"),
  ("TV", "08"): (name: "불법 튜닝, 해체, 조작", category: "traffic"),
  ("TV", "09"): (name: "기타 자동차 안전기준 위반", category: "traffic"),
  ("TV", "10"): (name: "난폭/보복운전", category: "traffic"),
  ("DR", "01"): (name: "불법광고물", category: "living"),
  ("DR", "02"): (name: "자전거·이륜차 방치 및 불편", category: "living"),
  ("DR", "03"): (name: "(구)청소년 유해업소", category: "living"),
  ("DR", "04"): (name: "(구)에너지 과소비", category: "living"),
  ("DR", "05"): (name: "기타 생활불편", category: "living"),
  ("DR", "06"): (name: "쓰레기, 폐기물", category: "living"),
  ("DR", "07"): (name: "해양 쓰레기", category: "living"),
  ("DR", "08"): (name: "불법 숙박", category: "living"),
};
const entryMenus = <String, ({List<String> cds, String category})>{
  "불법주정차신고": (cds: ["IP", "EP"], category: "parking"),
  "자동차·교통위반": (cds: ["TV"], category: "traffic"),
  "자동차·교통위반신고": (cds: ["TV"], category: "traffic"),
  "안전신고": (cds: ["CM"], category: "safety"),
  "생활불편신고": (cds: ["DR"], category: "living"),
};

/// 후보 대분류 목록을 '|'로 연결한 값과 정규화 소분류가 별칭 키다.
const entryAliases = <(String, String), (String, String)>{
  ("TV", "버스전용차로위반(일반도로)"): ("TV", "05"),
  ("CM", "쓰레기,폐기물"): ("CM", "05"),
};
// Python re \s: Unicode White_Space + U+001C..U+001F, BOM은 제외.
// Dart RegExp(r'\s+')는 U+0085/제어 구분자를 놓치고 U+FEFF를 포함한다.
final _space = RegExp(
  r'[\u0009-\u000D\u001C-\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
);
// Python 3.14 str.isdigit()의 단일 문자 집합. zfill(2)는 두 글자 이상을 그대로 둔다.
final _singleDigit = RegExp(
  r'^[\u{30}-\u{39}\u{b2}-\u{b3}\u{b9}\u{660}-\u{669}\u{6f0}-\u{6f9}\u{7c0}-\u{7c9}\u{966}-\u{96f}\u{9e6}-\u{9ef}\u{a66}-\u{a6f}\u{ae6}-\u{aef}\u{b66}-\u{b6f}\u{be6}-\u{bef}\u{c66}-\u{c6f}\u{ce6}-\u{cef}\u{d66}-\u{d6f}\u{de6}-\u{def}\u{e50}-\u{e59}\u{ed0}-\u{ed9}\u{f20}-\u{f29}\u{1040}-\u{1049}\u{1090}-\u{1099}\u{1369}-\u{1371}\u{17e0}-\u{17e9}\u{1810}-\u{1819}\u{1946}-\u{194f}\u{19d0}-\u{19da}\u{1a80}-\u{1a89}\u{1a90}-\u{1a99}\u{1b50}-\u{1b59}\u{1bb0}-\u{1bb9}\u{1c40}-\u{1c49}\u{1c50}-\u{1c59}\u{2070}\u{2074}-\u{2079}\u{2080}-\u{2089}\u{2460}-\u{2468}\u{2474}-\u{247c}\u{2488}-\u{2490}\u{24ea}\u{24f5}-\u{24fd}\u{24ff}\u{2776}-\u{277e}\u{2780}-\u{2788}\u{278a}-\u{2792}\u{a620}-\u{a629}\u{a8d0}-\u{a8d9}\u{a900}-\u{a909}\u{a9d0}-\u{a9d9}\u{a9f0}-\u{a9f9}\u{aa50}-\u{aa59}\u{abf0}-\u{abf9}\u{ff10}-\u{ff19}\u{104a0}-\u{104a9}\u{10a40}-\u{10a43}\u{10d30}-\u{10d39}\u{10d40}-\u{10d49}\u{10e60}-\u{10e68}\u{11052}-\u{1105a}\u{11066}-\u{1106f}\u{110f0}-\u{110f9}\u{11136}-\u{1113f}\u{111d0}-\u{111d9}\u{112f0}-\u{112f9}\u{11450}-\u{11459}\u{114d0}-\u{114d9}\u{11650}-\u{11659}\u{116c0}-\u{116c9}\u{116d0}-\u{116e3}\u{11730}-\u{11739}\u{118e0}-\u{118e9}\u{11950}-\u{11959}\u{11bf0}-\u{11bf9}\u{11c50}-\u{11c59}\u{11d50}-\u{11d59}\u{11da0}-\u{11da9}\u{11f50}-\u{11f59}\u{16130}-\u{16139}\u{16a60}-\u{16a69}\u{16ac0}-\u{16ac9}\u{16b50}-\u{16b59}\u{16d70}-\u{16d79}\u{1ccf0}-\u{1ccf9}\u{1d7ce}-\u{1d7ff}\u{1e140}-\u{1e149}\u{1e2f0}-\u{1e2f9}\u{1e4f0}-\u{1e4f9}\u{1e5f1}-\u{1e5fa}\u{1e950}-\u{1e959}\u{1f100}-\u{1f10a}\u{1fbf0}-\u{1fbf9}]$',
  unicode: true,
);

String _text(Object? value) {
  if (value == null || value == false || value == 0 || value == '') return '';
  if (value == true) return 'True';
  return value.toString();
}

String _norm(Object? value) => _text(value).replaceAll(_space, '');
String _normName(String name) {
  final text = _norm(name);
  return text.startsWith('(구)') ? text.substring(3) : text;
}

String _normSub(String sub) {
  final text = _norm(sub);
  return text.endsWith('불법주차') ? text.substring(0, text.length - 4) : text;
}

NormalizedCode normalizeCode(Object? cd, Object? type) {
  final normalizedCd = _norm(cd).toUpperCase();
  final rawType = _norm(type);
  final normalizedType = _singleDigit.hasMatch(rawType) ? '0$rawType' : rawType;
  return (
    ssnpcCd: normalizedCd.isEmpty ? null : normalizedCd,
    ssnpcType: normalizedType.isEmpty ? null : normalizedType,
  );
}

final _nameIndex = <(String, String), (String, String)>{
  for (final entry in codes.entries)
    (entry.key.$1, _normName(entry.value.name)): entry.key,
};

Resolved _fromEntryValue(Object? entryValue) {
  final text = _text(entryValue);
  final dash = text.indexOf('-');
  final menu = dash < 0 ? text : text.substring(0, dash);
  final sub = dash < 0 ? '' : text.substring(dash + 1);
  final found = entryMenus[_norm(menu)];
  if (found == null) {
    // '-' 가 아닌 구분자 등: 문구가 아는 메뉴 이름으로 시작하면 그중 가장 긴 메뉴(소분류는 모름)
    final whole = _norm(text);
    String? best;
    for (final name in entryMenus.keys) {
      if (whole.startsWith(name) && (best == null || name.length > best.length)) {
        best = name;
      }
    }
    return (
      ssnpcCd: null,
      ssnpcType: null,
      code: null,
      category: best == null ? 'other' : entryMenus[best]!.category,
    );
  }
  final key = _normSub(sub);
  if (key.isNotEmpty) {
    final alias = entryAliases[(found.cds.join('|'), key)];
    if (alias != null) return _known(alias);
    for (final cd in found.cds) {
      final hit = _nameIndex[(cd, key)];
      if (hit != null) return _known(hit);
    }
  }
  return (ssnpcCd: null, ssnpcType: null, code: null, category: found.category);
}

Resolved _known((String, String) key) => (
  ssnpcCd: key.$1,
  ssnpcType: key.$2,
  code: '${key.$1}-${key.$2}',
  category: codes[key]!.category,
);

Resolved resolve([Object? cd, Object? type, Object? entryValue]) {
  final normalized = normalizeCode(cd, type);
  final normalizedCd = normalized.ssnpcCd;
  if (normalizedCd != null) {
    final key = (normalizedCd, normalized.ssnpcType ?? '');
    if (codes.containsKey(key)) return _known(key);
    return (
      ssnpcCd: normalizedCd,
      ssnpcType: normalized.ssnpcType,
      code: null,
      category: groupCategory[normalizedCd] ?? 'other',
    );
  }
  return _fromEntryValue(entryValue);
}

String categoryOf([Object? cd, Object? type, Object? entryValue]) =>
    resolve(cd, type, entryValue).category;

String codeName(String? code) {
  if (code == null) return '';
  final dash = code.indexOf('-');
  if (dash < 0) return '';
  return codes[(code.substring(0, dash), code.substring(dash + 1))]?.name ?? '';
}


/// 5분류 이전 화면·통계·공유 계약이 쓰던 3분류. safety·living 은 예전 '기타'에 들어 있었다(서버 legacy_category 와 같음).
const legacyCategories = ["traffic", "parking", "other"];

/// 5분류 → 예전 3분류(traffic·parking·other).
String legacyCategory(String? category) =>
    category == "traffic" || category == "parking" ? category! : "other";

/// 예전 3분류 값 → 그에 해당하는 5분류 묶음. 'other' 는 safety·living·other.
List<String> expandLegacy(String category) =>
    category == "other" ? const ["safety", "living", "other"] : [category];
