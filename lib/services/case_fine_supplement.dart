/// Unknown-disposition supplement after the existing parser's final status step.
/// Mirrors services/case_fine_supplement.py and the shared observed-case vectors.
const _finalStatuses = {'수용', '일부수용', '불수용', '기타', '답변완료'};
const _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
};
final _entity = RegExp(
  r'&(#x[0-9a-fA-F]+|#X[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);',
);
final _space = RegExp(
  r'[ \t\r\n\f\v\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+',
);
final _boundary = RegExp(
  r'(?<=[다요])[.。!?]|\n\s*\n|(?<=\n)(?=\s*(?:\d+|[가-하])[.)]\s)|(?<=\n)(?=\s*[○※])',
);
final _action = RegExp(
  r'과태료(?:를)?부과(?:할예정|처리|로결정|되었|하였|절차를진행|및징수절차진행|하도록하겠|하겠습니다|합니다)',
);
final _proof = RegExp(
  r'불법주[·ㆍ]?정차로판단되어|불법행위\(충전방해행위\)에해당하여|(?:확인|검토)(?:한)?결과.{0,350}(?:확인되어|확인됨에따라|파악되어|위반차량으로)|위반행위가확인되어|위반(?:한)?사실이확인되어|위반한행위로확인되어|위반에해당되어|이중주차행위\(주차위반\)에해당되어',
  unicode: true,
);
final _condition = RegExp(r'미이행|불이행|불응|않을경우|않는경우|않을시|재위반|재차|경우|최대|이하|상한');
final _negative = RegExp(
  r'과태료.{0,30}(?:부과(?:가|하기|에)?(?:어려|곤란|불가)|부과할수없|부과하지|처분이불가|처분은하지)|과태료미부과',
  unicode: true,
);
final _caseNegative = RegExp(
  r'(?:자료|영상|사진).{0,25}확인|처리결과|식별되지않|확증할수없|통고처분이나과태료처분',
  unicode: true,
);
final _structured = RegExp(r'처리결과[:：]수용\(과태료부과\)');
final _notice = RegExp(r'위반행위에따른과태료[0-9,.]*원을부과하고자');
final _sent = RegExp(r'''과태료부과사전통지서[’”'"]*를발송하였''');

String _normalize(String text) {
  text = text.replaceAllMapped(_entity, (match) {
    final value = match[1]!;
    if (!value.startsWith('#')) return _entities[value]!;
    final hex = value.length > 1 && value[1].toLowerCase() == 'x';
    final number = int.tryParse(
      value.substring(hex ? 2 : 1),
      radix: hex ? 16 : 10,
    );
    if (number == null ||
        number <= 0 ||
        number > 0x10ffff ||
        (number >= 0xd800 && number <= 0xdfff)) {
      return match[0]!;
    }
    return String.fromCharCode(number);
  });
  text = String.fromCharCodes(
    text.runes.map((c) => c >= 0xff01 && c <= 0xff5e ? c - 0xfee0 : c),
  );
  return text.replaceAll(_space, '');
}

(String, String) supplementCaseFine(
  String status,
  String penalty,
  String answer,
) {
  if (!_finalStatuses.contains(status) || (penalty != '' && penalty != '미확인')) {
    return (status, penalty);
  }
  var positive = false;
  var negative = false;
  var structured = false;
  for (final sentence in answer.split(_boundary)) {
    final text = _normalize(sentence);
    if (!text.contains('과태료') || _condition.hasMatch(text)) continue;
    if (_negative.hasMatch(text)) {
      negative = negative || _caseNegative.hasMatch(text);
      continue;
    }
    if (_structured.hasMatch(text)) {
      positive = structured = true;
      continue;
    }
    final proof = _proof.firstMatch(text);
    final action = _action.firstMatch(text);
    if (proof != null && action != null && proof.start < action.start) {
      positive = true;
      continue;
    }
    final bare = text
        .replaceFirst(RegExp(r'^[가-하]\.'), '')
        .replaceAll(RegExp(r'^[ .-]+|[ .-]+$'), '');
    if (bare == '이에해당차량에대하여과태료를부과할예정입니다') {
      positive = true;
    } else if (_notice.hasMatch(text) && _sent.hasMatch(text)) {
      positive = true;
    }
  }
  if (positive && !negative) return (structured ? '수용' : status, '과태료');
  return (status, penalty);
}
