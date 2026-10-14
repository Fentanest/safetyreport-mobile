/// Explicit amount grammar only; disposition and minimum estimates stay separate.
final _fine = RegExp(r'과태료\s*:?\s*(\()?\s*([0-9,.]+)\s*(만)?\s*원');
final _money = RegExp(r'([0-9,.]+)\s*(만|천|백|억)?\s*원');
final _limit = RegExp(
  r'최대|상한|이하|이상|미만|초과|(?:미이행|불이행|불응)\s*(?:시|할\s*경우)|재위반|않을\s*(?:경우|시)|경우에?는?|부과하지|부과할\s*수\s*없',
);

String? _number(String token, String? unit) {
  if (unit == null) return token;
  if (unit == '만' && RegExp(r'^[0-9]+$').hasMatch(token)) {
    return (BigInt.parse(token) * BigInt.from(10000)).toString();
  }
  return null;
}

String? explicitFineNumber(String source) {
  const wide = '０１２３４５６７８９，．：（）';
  const ascii = '0123456789,.:()';
  var text = source;
  for (var i = 0; i < wide.length; i++) {
    text = text.replaceAll(wide[i], ascii[i]);
  }
  final matches = _fine.allMatches(text).toList();
  if (matches.isEmpty) return null;
  final candidates = <String>[];
  for (final match in matches) {
    if (match[1] != null &&
        !RegExp(r'^\s*\)').hasMatch(text.substring(match.end))) {
      return null;
    }
    final newline = text.lastIndexOf('\n', match.start);
    final stop = text.lastIndexOf('。', match.start);
    final start = (newline > stop ? newline : stop) + 1;
    final finish = text.indexOf('\n', match.end);
    final previous = start == 0
        ? ''
        : text.substring(0, start - 1).split('\n').last;
    if (_limit.hasMatch(
          text.substring(start, finish < 0 ? text.length : finish),
        ) ||
        RegExp(
          r'(?:최대|상한|(?:미이행|불이행|불응)\s*시|않을\s*경우)\s*[:：]?\s*$',
        ).hasMatch(previous) ||
        RegExp(
          r'^\s*\)?\s*(?:이하|이상|미만|초과)',
        ).hasMatch(text.substring(match.end))) {
      return null;
    }
    final value = _number(match[2]!, match[3]);
    if (value == null) return null;
    candidates.add(value);
  }
  if (candidates.toSet().length != 1) return null;
  String? identity(String? n) => n?.replaceAll(RegExp(r'[,.]'), '');
  for (final m in _money.allMatches(text)) {
    if (identity(_number(m[1]!, m[2])) != identity(candidates.first)) {
      return null;
    }
  }
  return candidates.first;
}
