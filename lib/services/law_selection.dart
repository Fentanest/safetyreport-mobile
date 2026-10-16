import 'law_citations.dart';

final _boundary = lawRegex(
  '(?<=[다요])[.。!?](?!$lawSpaceClass*\\()|\\n$lawSpaceClass*\\n|(?<=\\n)(?=$lawSpaceClass*(?:[가-하]|[0-9]+)[.)]$lawSpaceClass)|(?=그러나|다만(?:,|$lawSpaceClass)|추가로|※)',
  unicode: true,
);
final _finding = lawRegex(
  r'''위반행위로판단|에저촉되어|위반에따라|위반되는사항|적합하지않다고판단|해당하는사실을확인|위반(?:한)?(?:사실|사항|행위)(?:이|가|을|를|은|는)?확인|위반(?:으로)?확인|위반한(?:사실|사항|불법|행위)|위반(?:으로|한행위로)판단|위반(?:사항|행위)?에해당(?:되어|하여|하므로|되나)|위반하였|위반하여|위반사항을통지|위반을확인|위반,|위반으로원상복구''',
  unicode: true,
);
final _sanction = lawRegex(
  r'''과태료(?:를)?부과(?:할예정|예정|처분|처리|하였|합니다|하겠습니다|대상)|과태료[0-9,.]+원을부과하고자|과태료처분(?:예정|대상)|과태료(?:를)?부과절차(?:를)?진행|행정처분하겠''',
  unicode: true,
);
final _remedy = lawRegex(
  r'''(?:원상복구|시정|정비)(?:명령|조치|요청)|원상복구(?:및[^.]{0,20})?(?:하도록|명령|의견진술)|번호판교체에대하여안내|행정조치하였|계도조치|행정계도|점검하여안전운행하도록행정지도''',
  unicode: true,
);
final _case = lawRegex(
  r'''귀하|해당차량|신고차량|신고된차량|차량소유|차주|피신고|신고하신|신고해주신|제보(?:하신|해주신)|소유주|민원신고사항|보내주신|첨부파일|첨부해주신|제출하신''',
  unicode: true,
);
final _denial = lawRegex(
  r'''위반(?:한)?(?:사실|사항|행위)(?:이|가|은|는)?없(?:습니다|음|어)|위반(?:한)?(?:사실|사항|행위)(?:을|를)?확인(?:할수없|하지못)|해당하지않|위반(?:한)?(?:사실|사항|행위)?(?:이|을|를|가)?(?:명확히)?(?:확인되지않|확정할수없)|위반이있었다고확정할수없|명확(?:하게|히)판단하기어려|식별이곤란한정도가아닌|대상(?:은|이)?(?:아니|아닙|아님)|해당되지않|적용하지않|위반으로의율하기는어렵|철거는못''',
  unicode: true,
);
final _allow = lawRegex(
  r'''주차가가능한곳|주차가능함을|주차가가능함을|주차가능표지를발급받은차량''',
  unicode: true,
);
final _reject = lawRegex(
  r'''과태료(?:를)?부과(?:는|가|하기|에)?(?:어려|곤란|불가)|과태료처분(?:은|이)?(?:어려|곤란|불가)|과태료(?:를)?부과할수없|단속(?:이|은)?어려|과태료를부과하지아니''',
  unicode: true,
);
final _future = lawRegex(
  r'''(?:위반사항|위반행위)에해당하는경우|검토후조치|위반사항확인후|단속검토예정|승인내역이없음|위반으로의심''',
  unicode: true,
);
final _procTitle = lawRegex(
  r'''사전통지|의견제출|자진납부|과태료경감|경고처분|적용배제|특례''',
  unicode: true,
);
final _procText = lawRegex(
  r'''신고포상금|포상금을지급|포상금을수령|신고는육하원칙|증거자료를객관적|영상에의해위반사실이명백히확인될것|신청권이나자료요청권한|촬영을삼가''',
  unicode: true,
);
final _sanctionTitle = lawRegex(r'''과태료|부과기준''', unicode: true);
final _remedyTitle = lawRegex(r'''점검및정비|정비명령|점검및정비명령''', unicode: true);

List<int> _span(dynamic value) => (value as List).cast<int>();
List<LawMap> _occ(LawMap r) => (r['occurrences'] as List).cast<LawMap>();
List<LawMap> _evidence(LawMap r) => (r['evidence'] as List).cast<LawMap>();

List<({int start, int end, String text})> _segments(String s) {
  final out = <({int start, int end, String text})>[];
  var pos = 0;
  for (final m in _boundary.allMatches(s)) {
    if (m.start > pos) {
      out.add((start: pos, end: m.start, text: s.substring(pos, m.start)));
    }
    pos = m.end;
  }
  if (pos < s.length) {
    out.add((start: pos, end: s.length, text: s.substring(pos)));
  }
  return out;
}

/// Existing parsing remains the baseline. These events supplement its result.
LawMap chooseLawBasis(String answer, {String oldKey = ''}) {
  final parsed = parseLawCitations(answer);
  final refs = parsed.refs;
  final pending = parsed.pending;
  final segs = _segments(answer);
  final annotated = refs
      .map((r) => <String, dynamic>{...r, 'evidence': <LawMap>[]})
      .toList();
  final allGroups = <LawMap>[];
  final groupBySegment = <int, List<LawMap>>{};
  for (var si = 0; si < segs.length; si++) {
    final segment = segs[si];
    final lo = segment.start;
    final hi = segment.end;
    final occ = <LawMap>[];
    for (var ri = 0; ri < refs.length; ri++) {
      for (final o in _occ(refs[ri])) {
        final a = _span(o['source_span'])[0];
        if (lo <= a && a < hi) occ.add({'ri': ri, 'o': o});
      }
    }
    occ.sort(
      (a, b) => _span(
        (a['o'] as LawMap)['source_span'],
      )[0].compareTo(_span((b['o'] as LawMap)['source_span'])[0]),
    );
    final groups = <List<LawMap>>[];
    for (final item in occ) {
      if (groups.isEmpty) {
        groups.add([item]);
        continue;
      }
      final previous = groups.last.last['o'] as LawMap;
      final o = item['o'] as LawMap;
      final end = _span(previous['source_span'])[1];
      final start = _span(o['source_span'])[0];
      final masks = <List<int>>[_span(o['name_span'])];
      for (final p in pending) {
        final span = _span(p['span']);
        if (p['type'] == 'unbound_article' &&
            end <= span[0] &&
            span[1] <= start) {
          masks.add(span);
        }
      }
      masks.sort((a, b) => a[0].compareTo(b[0]));
      var cursor = end;
      final parts = <String>[];
      for (final span in masks) {
        if (span[0] < end || span[1] > start) continue;
        parts.add(answer.substring(cursor, span[0]));
        cursor = span[1];
      }
      parts.add(answer.substring(cursor, start));
      final gap = normalizeLawText(parts.join());
      final residue = gap.replaceAll(
        lawRegex(
          r'''(?:및|또는|동법|같은법|시행령|시행규칙|와|과)|[「」『』【】\[\]"“”‘’(),、]''',
          unicode: true,
        ),
        '',
      );
      if (residue.isEmpty) {
        groups.last.add(item);
      } else {
        groups.add([item]);
      }
    }
    groupBySegment[si] = [];
    for (var gi = 0; gi < groups.length; gi++) {
      final items = groups[gi];
      final first = items.first['o'] as LawMap;
      final last = items.last['o'] as LawMap;
      var start = _span(first['source_span'])[0];
      final nameStart = _span(first['name_span'])[0];
      final earlier = groups
          .take(gi)
          .expand((g) => g)
          .any((x) => _span((x['o'] as LawMap)['source_span'])[0] < start);
      if (lo <= nameStart && nameStart < start && !earlier) start = nameStart;
      var end = hi;
      if (gi + 1 < groups.length) {
        final next = groups[gi + 1].first['o'] as LawMap;
        end = _span(next['source_span'])[0];
        final na = _span(next['name_span'])[0];
        if (_span(last['source_span'])[1] <= na && na < end) end = na;
      }
      final a = gi == 0 ? lo : start;
      final g = <String, dynamic>{
        'id': allGroups.length,
        'segment': si,
        'span': [a, end],
        'text': answer.substring(a, end),
        'items': items,
        'tail_start': _span(last['source_span'])[1],
      };
      allGroups.add(g);
      groupBySegment[si]!.add(g);
    }
  }
  for (final g in allGroups) {
    final q = normalizeLawText(g['text'] as String);
    final caseNexus =
        _case.hasMatch(q) ||
        lawRegex(
          r'(?:행위|사실|위반사항)(?:이|가|을|를|은|는)?(?:확인되|확인하|파악되|판단되)',
          unicode: true,
        ).hasMatch(q) ||
        _finding.hasMatch(q);
    final afterGroup = normalizeLawText(
      answer.substring(g['tail_start'] as int, _span(g['span'])[1]),
    );
    final generic = lawRegex(
      r'(?:가입하지아니한자|위반자|차량소유자)는과태료(?:가)?부과(?:대상|됩니다)',
      unicode: true,
    ).hasMatch(q);
    final policy =
        lawRegex(r'(?:경고처리|계도처분|경고처분)', unicode: true).hasMatch(q) &&
        lawRegex(r'경우|개선안|지침|기준', unicode: true).hasMatch(q) &&
        !_finding.hasMatch(q);
    final proof =
        _finding.hasMatch(q) ||
        lawRegex(r'^(?:을|를)위반한', unicode: true).hasMatch(afterGroup) ||
        lawRegex(
          r'''^(?:\([^)]*\))?["“‘「][^"”’」]*["”’」](?:에해당되어|로판단되어)''',
          unicode: true,
        ).hasMatch(afterGroup);
    final sanction = _sanction.hasMatch(q);
    final remedy = _remedy.hasMatch(q);
    for (final item in (g['items'] as List).cast<LawMap>()) {
      final ri = item['ri'] as int;
      final o = item['o'] as LawMap;
      final title = normalizeLawText(o['source_text'] as String);
      final tail = normalizeLawText(
        answer.substring(_span(o['source_span'])[1], _span(g['span'])[1]),
      );
      final definition = lawRegex(
        r'''^(?:\([^)]*\))?(?:에서|는|은)["“‘'「]''',
        unicode: true,
      ).hasMatch(tail);
      String role, reason;
      if (_procTitle.hasMatch(title) || _procText.hasMatch(q) || policy) {
        role = 'procedure';
        reason = 'procedure_or_policy_context';
      } else if (definition) {
        role = 'general';
        reason = 'quoted_statutory_explanation';
      } else if (generic) {
        role = 'general';
        reason = 'generic_liability_without_case_finding';
      } else if (_allow.hasMatch(q)) {
        role = 'excluded';
        reason = 'case_permission';
      } else if (_denial.hasMatch(q)) {
        role = 'excluded';
        reason = 'case_denial';
      } else if (_future.hasMatch(q)) {
        role = 'unresolved';
        reason = 'unconfirmed_finding';
      } else if (_reject.hasMatch(q) && !proof) {
        role = 'unresolved';
        reason = 'enforcement_rejection_without_violation_finding';
      } else if (_remedyTitle.hasMatch(title)) {
        role = caseNexus && remedy ? 'remedy' : 'unknown';
        reason = 'remedy_basis';
      } else if (_sanctionTitle.hasMatch(title)) {
        role = caseNexus && sanction ? 'sanction' : 'unknown';
        reason = 'sanction_basis';
      } else if (proof) {
        role = 'violation';
        reason = 'case_violation_finding';
      } else if (caseNexus && sanction) {
        role = 'sanction';
        reason = 'case_sanction_with_named_basis';
      } else if (caseNexus && remedy) {
        role = 'remedy';
        reason = 'case_remedy_with_named_basis';
      } else {
        role = 'unknown';
        reason = 'no_verified_event_link';
      }
      _evidence(annotated[ri]).add({
        'role': role,
        'reason': reason,
        'group': g['id'],
        'span': g['span'],
        'text': g['text'],
        'citation': o,
      });
    }
  }
  for (var si = 0; si < segs.length; si++) {
    if ((groupBySegment[si]?.isNotEmpty ?? false) || si == 0) continue;
    final previous = groupBySegment[si - 1] ?? [];
    if (previous.length != 1) continue;
    final g = previous.single;
    final ids = (g['items'] as List)
        .cast<LawMap>()
        .map((x) => x['ri'] as int)
        .toSet();
    if (ids.length != 1) continue;
    final ri = ids.single;
    final lo = segs[si].start;
    var hi = segs[si].end;
    var raw = segs[si].text;
    var q = normalizeLawText(raw);
    final normalized = normalizedLawCopy(raw);
    final nextName = lawNames.firstMatch(normalized.text);
    if (nextName != null) {
      final cut = normalized.mapping[nextName.start][0];
      raw = raw.substring(0, cut);
      hi = lo + cut;
      q = normalizeLawText(raw);
    }
    if (!_case.hasMatch(q) ||
        !_remedy.hasMatch(q) ||
        _denial.hasMatch(q) ||
        _future.hasMatch(q) ||
        lawRegex(r'경우|미이행|추후').hasMatch(q)) {
      continue;
    }
    final roles = _evidence(annotated[ri]).map((e) => e['role']).toSet();
    if (roles.intersection({
      'excluded',
      'procedure',
      'unresolved',
    }).isNotEmpty) {
      continue;
    }
    _evidence(annotated[ri]).add({
      'role': 'remedy',
      'reason': 'adjacent_case_action_single_basis',
      'group': g['id'],
      'span': [lo, hi],
      'text': raw,
      'citation': null,
    });
  }
  const rank = {'violation': 0, 'sanction': 1, 'remedy': 2};
  for (final r in annotated) {
    final roles = _evidence(r).map((e) => e['role'] as String).toSet();
    final accepted = roles.intersection(rank.keys.toSet());
    if (accepted.isNotEmpty && roles.contains('excluded')) {
      r['decision'] = 'conflict';
      r['rank'] = null;
    } else if (accepted.isNotEmpty) {
      final sorted = accepted.toList()
        ..sort((a, b) => rank[a]!.compareTo(rank[b]!));
      r['decision'] = sorted.first;
      r['rank'] = rank[sorted.first];
    } else if (roles.contains('excluded')) {
      r['decision'] = 'excluded';
      r['rank'] = null;
    } else if (roles.contains('unresolved')) {
      r['decision'] = 'unresolved';
      r['rank'] = null;
    } else if (roles.length == 1 && roles.contains('procedure')) {
      r['decision'] = 'procedure';
      r['rank'] = null;
    } else if (roles.isNotEmpty &&
        roles.difference({'general', 'procedure'}).isEmpty) {
      r['decision'] = 'general';
      r['rank'] = null;
    } else {
      r['decision'] = 'unknown';
      r['rank'] = null;
    }
  }
  var candidates = annotated
      .where((r) => r['rank'] != null && r['kind'] == 'article')
      .toList();
  var legacy = false;
  bool oldMember(LawMap r) =>
      r['key'] == oldKey ||
      (oldKey.isNotEmpty && (r['key'] as String).startsWith('$oldKey제'));
  if (candidates.isEmpty && oldKey.isNotEmpty) {
    candidates = annotated
        .where(
          (r) =>
              r['decision'] == 'unknown' &&
              oldMember(r) &&
              r['kind'] == 'article',
        )
        .toList();
    legacy = candidates.isNotEmpty;
    for (final r in candidates) {
      r['rank'] = 3;
    }
  }
  candidates.sort((a, b) {
    var c = (a['rank'] as int).compareTo(b['rank'] as int);
    if (c != 0) return c;
    c = (oldMember(a) ? 0 : 1).compareTo(oldMember(b) ? 0 : 1);
    if (c != 0) return c;
    return _span(
      _occ(a).first['source_span'],
    )[0].compareTo(_span(_occ(b).first['source_span'])[0]);
  });
  return {
    'selected': candidates.isEmpty ? '' : candidates.first['key'],
    'refs': annotated,
    'pending': pending,
    'legacy_fallback': legacy,
    'groups': allGroups
        .map(
          (g) => <String, dynamic>{
            'id': g['id'],
            'span': g['span'],
            'text': g['text'],
            'refs': (g['items'] as List)
                .cast<LawMap>()
                .map((x) => refs[x['ri'] as int]['key'])
                .toList(),
          },
        )
        .toList(),
  };
}
