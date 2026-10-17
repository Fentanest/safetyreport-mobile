/// Explicit amount grammar only; disposition and minimum estimates stay separate.
/// Mirrors services/fine_amount_syntax.py; every character class is explicit so
/// Dart and Python agree (contracts/explicit-fine-vectors.json).
library;

// Union of Python and Dart whitespace (incl. U+001C-U+001F, U+0085, U+FEFF).
const _spaceSet =
    r'\t\n\x0b\x0c\r\x1c-\x20\x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff';
const _s = '[$_spaceSet]';
// Followed by whitespace, a comma or the end of text.
const _end = '(?![^,$_spaceSet])';
const _maxDigits = 15; // Longer digit runs are not amounts.
final _fine = RegExp('과태료$_s*:?$_s*(\\()?$_s*([0-9,.]+)$_s*(만)?$_s*원');
final _money = RegExp('(?<![0-9,.])([0-9,.]+)$_s*(만|천|백|억)?$_s*원');
final _limit = RegExp(
  '최대|상한|이하|이상|미만|초과|(?:미이행|불이행|불응)$_s*(?:시|할$_s*경우)|재위반|않을$_s*(?:경우|시)|경우에?는?|부과하지|부과할$_s*수$_s*없'
  // Future conditions ("다시 적발될 시", "적발되면", "~할 시", "~하면").
  '|(?:될|할|적발|위반)$_s*시(?:에는?|에도)?$_end|(?:하|되|않으)면$_end',
);
// A refusal/non-imposition decision from the amount's clause to the end of its sentence ("부과할
// 예정이었으나, ... 부과하지 않습니다") withdraws that amount. One in another sentence or an earlier
// clause is about another violation or charge ("가산금은 부과하지 않습니다") and does not.
final _refusal = RegExp(
  '부과하지|부과할$_s*수$_s*없|미부과|부과(?:가|는)?$_s*(?:불가(?!피)|어렵|곤란)',
);
// A decision sentence ends at a sentence-final ending, not at a line break inside it ("예정이었으나,\n...").
final _decisionEnd = RegExp(r'。|(?<=[다요])[.!?]|(?<=[다요.!?])\n');
// Another amount in a reduction clause ("경우 과태료 80,000원으로 감경") is a second stated amount
// even when its clause is conditional.
final _reduction = RegExp('감경|경감|감면');
// A limit amount ("20만원 이하", "최대 200만원") is guidance, not a second stated amount.
final _limitBefore = RegExp('(?:최대|상한)$_s*(?:과태료)?$_s*:?$_s*\$');
final _previousLimit = RegExp(
  '(?:최대|상한|(?:미이행|불이행|불응)$_s*시|않을$_s*경우)$_s*[:：]?$_s*\$',
);
final _followingLimit = RegExp('$_s*\\)?$_s*(?:이하|이상|미만|초과)');
final _close = RegExp('$_s*\\)');
// Sentence ends and post-predicate clause connectives ("부과할 예정이며, ...").
final _sentence = RegExp(r'\n|。|(?<=[다요])[.!?]');
final _clause = RegExp('(?:며|으나|지만|는데|(?:였|했|하|되)고)(?=,|$_s)');

String? _number(String token, String? unit) {
  if (token.replaceAll(RegExp(r'[^0-9]'), '').length > _maxDigits) return null;
  if (unit == null) return token;
  if (unit == '만' && RegExp(r'^[0-9]+$').hasMatch(token)) {
    return (BigInt.parse(token) * BigInt.from(10000)).toString();
  }
  return null;
}

String? _identity(String? n) => n?.replaceAll(RegExp(r'[,.]'), '');

String? explicitFineNumber(String source) {
  const wide = '０１２３４５６７８９，．：（）';
  const ascii = '0123456789,.:()';
  var text = source;
  for (var i = 0; i < wide.length; i++) {
    text = text.replaceAll(wide[i], ascii[i]);
  }
  final matches = _fine.allMatches(text).toList();
  if (matches.isEmpty) return null;
  final decisionEnds = <int>{
    text.length,
    for (final m in _decisionEnd.allMatches(text)) m.end,
  }.toList()..sort();
  final cuts = <int>{
    0,
    text.length,
    for (final m in _sentence.allMatches(text)) m.end,
    for (final m in _clause.allMatches(text)) m.end,
  }.toList()..sort();
  (int, int) clause(int start, int end) =>
      (cuts.lastWhere((c) => c <= start), cuts.firstWhere((c) => c >= end));
  final candidates = <String>[];
  final skipped = <(int, int)>[];
  for (final match in matches) {
    if (match[1] != null && _close.matchAsPrefix(text, match.end) == null) {
      return null;
    }
    final (a, b) = clause(match.start, match.end);
    final sentenceEnd = decisionEnds.firstWhere((e) => e >= match.end);
    var before = text.substring(0, a);
    if (before.endsWith('\n')) before = before.substring(0, before.length - 1);
    final previous = a == 0 ? '' : before.split('\n').last;
    if (_refusal.hasMatch(text.substring(a, sentenceEnd)) ||
        _limit.hasMatch(text.substring(a, b)) ||
        _previousLimit.hasMatch(previous) ||
        _followingLimit.matchAsPrefix(text, match.end) != null) {
      skipped.add((match.start, match.end));
      continue;
    }
    final value = _number(match[2]!, match[3]);
    if (value == null) return null;
    candidates.add(value);
  }
  if (candidates.toSet().length != 1) return null;
  // Other monetary values (e.g. before/after reduction, a surcharge) make the
  // statement ambiguous; a limit amount in generic guidance does not.
  for (final m in _money.allMatches(text)) {
    if (_identity(_number(m[1]!, m[2])) == _identity(candidates.first)) {
      continue;
    }
    final (a, b) = clause(m.start, m.end);
    if (_followingLimit.matchAsPrefix(text, m.end) != null ||
        _limitBefore.hasMatch(text.substring(a, m.start))) {
      continue;
    }
    if (_reduction.hasMatch(text.substring(a, b))) return null;
    if (skipped.any((x) => x.$1 <= m.start && m.start < x.$2)) continue;
    return null;
  }
  return candidates.first;
}
