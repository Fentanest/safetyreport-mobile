import 'package:html/parser.dart' as html;
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'law_recognition_data.dart';

typedef LawMap = Map<String, dynamic>;
final _entity = RegExp(r'&(?:#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);');
String decodeLawEntities(String text) => text.replaceAllMapped(
  _entity,
  (m) => html.parseFragment(m[0]!).text ?? m[0]!,
);
String normalizeLawText(String text) => unorm
    .nfkc(decodeLawEntities(text))
    .replaceAll(RegExp(r'\s', unicode: true), '');
final lawNames = RegExp(
  (lawAliases.keys.toList()..sort((a, b) => b.length.compareTo(a.length)))
      .map(RegExp.escape)
      .join('|'),
  unicode: true,
);
final _article = RegExp(lawArticlePattern, unicode: true);
final _short = RegExp(lawShortPattern, unicode: true);
final _annex = RegExp(r'별표\s*(?:제)?(?<n>\d+)', unicode: true);
final _reference = RegExp(
  r'''(같은법|동법|(?<![가-힣])법)(시행령|시행규칙)?[」』】\]"”’']*''',
  unicode: true,
);
final _quotes = RegExp(r'''[「」『』【】\[\]"“”’‘']*''', unicode: true);
final _connector = RegExp(r'(?:및|,|、|와|과|또는)+', unicode: true);
const _articleFields = ['a', 'sub', 'p', 'i', 'isub', 'l'];
RegExpMatch? _at(RegExp re, String s, int pos) =>
    re.matchAsPrefix(s, pos) as RegExpMatch?;

({String text, List<List<int>> mapping}) normalizedLawCopy(String text) {
  final out = StringBuffer();
  final mapping = <List<int>>[];
  final tokens = RegExp(
    r'&(?:#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);|.',
    dotAll: true,
    unicode: true,
  );
  for (final m in tokens.allMatches(text)) {
    final folded = unorm.nfkc(decodeLawEntities(m[0]!));
    for (final rune in folded.runes) {
      final char = String.fromCharCode(rune);
      if (RegExp(r'\s', unicode: true).hasMatch(char) || '·ㆍ･・ᆞ'.contains(char)) {
        continue;
      }
      out.write(char);
      for (var i = 0; i < char.length; i++) {
        mapping.add([m.start, m.end]);
      }
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
  final plates = RegExp(
    r'(?<!\d)\d{2,3}[가-힣][\d*]{2,4}',
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
    final sf = _at(RegExp(r'(시행령|시행규칙)'), t, pos);
    if (sf != null) {
      law += ' ${sf[0]}';
      pos = sf.end;
    }
    for (var i = 0; i < 2; i++) {
      pos = _at(_quotes, t, pos)!.end;
      final q = _at(RegExp(r'\((?:약칭|이하같음|경찰청지침)\)'), t, pos);
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
        if (_at(RegExp(r'(?:부터|내지|~|∼|～)'), t, pos) != null) {
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
      if (RegExp(
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
  for (final block in RegExp(r'.+?(?=\n\s*\n|$)', dotAll: true).allMatches(s)) {
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
    for (final m in RegExp(r'제\s*(\d+)\s*항(?=에)').allMatches(block[0]!)) {
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
  for (final m in RegExp(r'\[별표\](\d+)호([가-하])목').allMatches(t)) {
    final span = source(m.start, m.end);
    final before = refs.where((r) => r['source_span'][1] <= span[0]).toList();
    if (before.isEmpty) continue;
    before.sort(
      (a, b) =>
          (a['source_span'][1] as int).compareTo(b['source_span'][1] as int),
    );
    final parent = before.last;
    if (RegExp(
      r'[。!?]|[다요]\.|\n\s*\n',
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
