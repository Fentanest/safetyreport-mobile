import 'package:html/parser.dart' as html;
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'law_recognition_data.dart';

typedef LawMap = Map<String, dynamic>;

/// Explicit whitespace class shared with Python `law_citations.SPACE_CLASS`
/// (union of Python and Dart `\s`: includes U+001C-U+001F, U+0085, U+FEFF).
const lawSpaceClass =
    r'[\t\n\x0b\x0c\r\x1c-\x20\x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]';
final _spaceRunes = <int>{
  0x09,
  0x0a,
  0x0b,
  0x0c,
  0x0d,
  0x1c,
  0x1d,
  0x1e,
  0x1f,
  0x20,
  0x85,
  0xa0,
  0x1680,
  for (var c = 0x2000; c <= 0x200a; c++) c,
  0x2028,
  0x2029,
  0x202f,
  0x205f,
  0x3000,
  0xfeff,
};
const _dotRunes = {0xb7, 0x318d, 0xff65, 0x30fb, 0x119e};
final _entity = lawRegex(r'&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');
// HTML5 numeric character reference replacements (html package / browsers).
const _numericReplacements = <int, int>{
  0x00: 0xfffd,
  0x0d: 0x0d,
  0x80: 0x20ac,
  0x81: 0x81,
  0x82: 0x201a,
  0x83: 0x0192,
  0x84: 0x201e,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02c6,
  0x89: 0x2030,
  0x8a: 0x0160,
  0x8b: 0x2039,
  0x8c: 0x0152,
  0x8d: 0x8d,
  0x8e: 0x017d,
  0x8f: 0x8f,
  0x90: 0x90,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201c,
  0x94: 0x201d,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02dc,
  0x99: 0x2122,
  0x9a: 0x0161,
  0x9b: 0x203a,
  0x9c: 0x0153,
  0x9d: 0x9d,
  0x9e: 0x017e,
  0x9f: 0x0178,
};

/// One `&...;` token (semicolon required). Numeric references are decoded
/// here with a bounded digit count (the html tokenizer throws on huge values);
/// named references use the html parser. Mirrors Python `decode_entity`.
String decodeLawEntity(String token) {
  if (token.startsWith('&#')) {
    final hex = token.length > 2 && (token[2] == 'x' || token[2] == 'X');
    var digits = token
        .substring(hex ? 3 : 2, token.length - 1)
        .replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) digits = '0';
    if (digits.length > 8) return String.fromCharCode(0xfffd);
    final number = int.parse(digits, radix: hex ? 16 : 10);
    final replacement = _numericReplacements[number];
    if (replacement != null) return String.fromCharCode(replacement);
    if ((number >= 0xd800 && number <= 0xdfff) || number > 0x10ffff) {
      return String.fromCharCode(0xfffd);
    }
    return String.fromCharCode(number);
  }
  return html.parseFragment(token).text ?? token;
}

String decodeLawEntities(String text) =>
    text.replaceAllMapped(_entity, (m) => decodeLawEntity(m[0]!));
String normalizeLawText(String text) => unorm
    .nfkc(decodeLawEntities(text))
    .replaceAll(lawRegex('$lawSpaceClass+'), '');
final lawNames = lawRegex(
  (lawAliases.keys.toList()..sort((a, b) => b.length.compareTo(a.length)))
      .map(RegExp.escape)
      .join('|'),
  unicode: true,
);
final _article = lawRegex(lawArticlePattern, unicode: true);
final _short = lawRegex(lawShortPattern, unicode: true);
final _annex = lawRegex(r'별표 ?(?:제)?(?<n>[0-9]+)', unicode: true);
final _reference = lawRegex(
  r'''(같은법|동법|(?<![가-힣])법)(시행령|시행규칙)?[」』】\]"”’']*''',
  unicode: true,
);
final _quotes = lawRegex(r'''[「」『』【】\[\]"“”’‘']*''', unicode: true);
final _connector = lawRegex(r'(?:및|,|、|와|과|또는)+', unicode: true);
const _articleFields = ['a', 'sub', 'p', 'i', 'isub', 'l'];
RegExpMatch? _at(RegExp re, String s, int pos) =>
    re.matchAsPrefix(s, pos) as RegExpMatch?;

/// Whitespace/dot-free recognition copy with a source-offset map. A whitespace
/// run between two ASCII digits is kept as one ' ' ('제32조의2 1항').
({String text, List<List<int>> mapping}) normalizedLawCopy(String text) {
  final out = StringBuffer();
  final mapping = <List<int>>[];
  final tokens = lawRegex(
    r'&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);|.',
    dotAll: true,
    unicode: true,
  );
  List<int>? gap;
  var lastDigit = false;
  for (final m in tokens.allMatches(text)) {
    final token = m[0]!;
    final folded = unorm.nfkc(
      token.length > 1 ? decodeLawEntity(token) : token,
    );
    for (final rune in folded.runes) {
      if (_spaceRunes.contains(rune)) {
        gap ??= [m.start, m.end];
        continue;
      }
      if (_dotRunes.contains(rune)) continue;
      final digit = rune >= 0x30 && rune <= 0x39;
      if (gap != null && lastDigit && digit) {
        out.write(' ');
        mapping.add(gap);
      }
      gap = null;
      final char = String.fromCharCode(rune);
      out.write(char);
      for (var i = 0; i < char.length; i++) {
        mapping.add([m.start, m.end]);
      }
      lastDigit = digit;
    }
  }
  return (text: out.toString(), mapping: mapping);
}

String _key(String law, LawMap g) =>
    '$law 제${g['a']}조${g['sub'] ?? ''}${g['p'] == null ? '' : '제${g['p']}항'}${g['i'] == null ? '' : '제${g['i']}호${g['isub'] ?? ''}'}${g['l'] == null ? '' : '${g['l']}목'}';

({List<LawMap> refs, List<LawMap> pending}) parseLawCitations(String s) {
  final normalized = normalizedLawCopy(s);
  final t = normalized.text;
  final mapping = normalized.mapping;
  final names = lawNames.allMatches(t).toList();
  final refs = <LawMap>[];
  final covered = <List<int>>[];
  final pending = <LawMap>[];
  final plates = lawRegex(
    r'(?<![0-9])[0-9]{2,3}[가-힣][0-9*]{2,4}',
    unicode: true,
  ).allMatches(t).map((m) => [m.start, m.end]).toList();
  List<int> source(int a, int b) => [mapping[a][0], mapping[b - 1][1]];
  void add(
    String law,
    LawMap g,
    int start,
    int finish,
    List<int> nameSpan, {
    String kind = 'article',
  }) {
    final key = kind == 'annex' ? '$law 별표 ${g['n']}' : _key(law, g);
    final span = source(start, finish);
    covered.add([start, finish]);
    refs.add({
      'key': key,
      'law': law,
      'kind': kind,
      'structure': Map<String, dynamic>.from(g),
      'source_span': span,
      'source_text': s.substring(span[0], span[1]),
      'name_span': nameSpan,
    });
  }

  for (var ni = 0; ni < names.length; ni++) {
    final n = names[ni];
    final base = lawAliases[n[0]]!;
    var law = base;
    var pos = n.end;
    final end = ni + 1 < names.length ? names[ni + 1].start : t.length;
    final nameSpan = source(n.start, n.end);
    final sf = _at(lawRegex(r'(시행령|시행규칙)'), t, pos);
    if (sf != null) {
      law += ' ${sf[0]}';
      pos = sf.end;
    }
    for (var i = 0; i < 2; i++) {
      pos = _at(_quotes, t, pos)!.end;
      final q = _at(lawRegex(r'\((?:약칭|이하같음|경찰청지침)\)'), t, pos);
      if (q != null) pos = q.end;
    }
    RegExpMatch? a = _at(_article, t, pos);
    var kind = 'article';
    if (a == null) {
      a = _at(_annex, t, pos);
      kind = 'annex';
    }
    LawMap? previous;
    var lastFinish = pos;
    while (true) {
      if (a != null && a.end <= end) {
        if (kind == 'annex') {
          add(
            law,
            {'n': a.namedGroup('n')},
            a.start,
            a.end,
            nameSpan,
            kind: 'annex',
          );
          previous = null;
        } else {
          LawMap g;
          if (kind == 'article') {
            g = {
              for (final field in _articleFields) field: a.namedGroup(field),
            };
          } else {
            g = Map<String, dynamic>.from(previous!);
            final p = a.namedGroup('p');
            if (p != null) {
              g.addAll({
                'p': p,
                'i': a.namedGroup('i'),
                'isub': null,
                'l': null,
              });
            } else {
              g.addAll({
                'i': a.namedGroup('i_only'),
                'isub': a.namedGroup('isub'),
                'l': null,
              });
            }
          }
          add(law, g, a.start, a.end, nameSpan);
          previous = g;
        }
        pos = a.end;
        lastFinish = pos;
        if (_at(lawRegex(r'(?:부터|내지|~|∼|～)'), t, pos) != null) {
          pending.add({
            'type': 'range_not_expanded',
            'span': source(a.start, a.end),
          });
          break;
        }
        final sep = _at(_connector, t, pos);
        if (sep != null) {
          pos = sep.end;
          var direct = _at(_article, t, pos);
          var nextKind = 'article';
          if (direct == null) {
            direct = _at(_annex, t, pos);
            nextKind = 'annex';
          }
          if (direct == null && previous != null) {
            direct = _at(_short, t, pos);
            nextKind = 'short';
          }
          if (direct != null) {
            a = direct;
            kind = nextKind;
            continue;
          }
        }
      }
      final found = _reference
          .allMatches(t, pos)
          .where((m) => m.end <= end)
          .toList();
      if (found.isEmpty) break;
      final rr = found.first;
      final gap = t.substring(lastFinish, rr.start);
      if (lawRegex(
        r'[「『][^」』]{2,100}(?:법|법률|조례|고시)[」』]',
        unicode: true,
      ).hasMatch(gap)) {
        pending.add({
          'type': 'ambiguous_reference',
          'span': source(rr.start, rr.end),
        });
        break;
      }
      if (rr[1] == '법' &&
          names.map((x) => lawAliases[x[0]]).toSet().length != 1) {
        pos = rr.end;
        a = null;
        continue;
      }
      law = base + (rr[2] == null ? '' : ' ${rr[2]}');
      pos = rr.end;
      a = _at(_article, t, pos);
      kind = 'article';
      if (a == null) {
        a = _at(_annex, t, pos);
        kind = 'annex';
      }
      previous = null;
    }
  }
  // A paragraph-only reference inherits only the sole local law/article.
  for (final block in lawRegex(
    '.+?(?=\\n$lawSpaceClass*\\n|\$)',
    dotAll: true,
  ).allMatches(s)) {
    final parents = refs
        .where(
          (r) =>
              r['kind'] == 'article' &&
              block.start <= r['source_span'][0] &&
              r['source_span'][0] < block.end,
        )
        .toList();
    final identities = parents
        .map(
          (r) =>
              [r['law'], r['structure']['a'], r['structure']['sub']].join('|'),
        )
        .toSet();
    if (identities.length != 1) continue;
    for (final m in lawRegex(
      '제$lawSpaceClass*([0-9]+)$lawSpaceClass*항(?=에)',
    ).allMatches(block[0]!)) {
      final span = [block.start + m.start, block.start + m.end];
      if (parents.any(
        (r) => r['source_span'][0] <= span[0] && span[0] < r['source_span'][1],
      )) {
        continue;
      }
      final before = parents
          .where((r) => r['source_span'][1] <= span[0])
          .toList();
      if (before.isEmpty) continue;
      final parent = before.last;
      final g = Map<String, dynamic>.from(parent['structure'] as Map)
        ..addAll({'p': m[1], 'i': null, 'isub': null, 'l': null});
      refs.add({
        'key': _key(parent['law'] as String, g),
        'law': parent['law'],
        'kind': 'article',
        'structure': g,
        'source_span': span,
        'source_text': s.substring(span[0], span[1]),
        'name_span': parent['name_span'],
        'inherited_article_span': parent['source_span'],
      });
    }
  }
  for (final m in lawRegex(r'\[별표\]([0-9]+)호([가-하])목').allMatches(t)) {
    final span = source(m.start, m.end);
    final before = refs.where((r) => r['source_span'][1] <= span[0]).toList();
    if (before.isEmpty) continue;
    before.sort(
      (a, b) =>
          (a['source_span'][1] as int).compareTo(b['source_span'][1] as int),
    );
    final parent = before.last;
    if (lawRegex(
      '[。!?]|[다요]\\.|\\n$lawSpaceClass*\\n',
    ).hasMatch(s.substring(parent['source_span'][1] as int, span[0]))) {
      continue;
    }
    refs.add({
      'key': '${parent['law']} 별표 제${m[1]}호${m[2]}목',
      'law': parent['law'],
      'kind': 'annex',
      'structure': {'n': null, 'i': m[1], 'l': m[2]},
      'source_span': span,
      'source_text': s.substring(span[0], span[1]),
      'name_span': parent['name_span'],
    });
  }
  refs.sort(
    (a, b) =>
        (a['source_span'][0] as int).compareTo(b['source_span'][0] as int),
  );
  for (final a in _article.allMatches(t)) {
    if (covered.any((x) => x[0] <= a.start && a.start < x[1]) ||
        plates.any((x) => x[0] <= a.start && a.start < x[1])) {
      continue;
    }
    final span = source(a.start, a.end);
    pending.add({
      'type': 'unbound_article',
      'span': span,
      'text': s.substring(span[0], span[1]),
    });
  }
  final unique = <String, LawMap>{};
  for (final r in refs) {
    final key = r['key'] as String;
    unique.putIfAbsent(
      key,
      () => {
        for (final k in ['key', 'law', 'kind', 'structure']) k: r[k],
        'occurrences': <LawMap>[],
      },
    );
    (unique[key]!['occurrences'] as List<LawMap>).add({
      for (final k in [
        'source_span',
        'source_text',
        'name_span',
        'inherited_article_span',
      ])
        if (r.containsKey(k)) k: r[k],
    });
  }
  return (refs: unique.values.toList(), pending: pending);
}

final _regexCache = <String, RegExp>{};
RegExp lawRegex(String pattern, {bool unicode = false, bool dotAll = false}) {
  final key = '$unicode|$dotAll|$pattern';
  return _regexCache.putIfAbsent(
    key,
    () => RegExp(pattern, unicode: unicode, dotAll: dotAll),
  );
}
