import 'report_policy.dart';
import 'dart:convert';
import 'law_citations.dart';
import 'law_selection.dart';
import 'law_recognition_data.dart';

// Anchored: Python `fullmatch` / JS `^…$` backtrack until the whole text is
// one key; `matchAsPrefix` only saw the first (shortest) prefix match.
final _key = lawRegex(
  r'^(.+?)제?([0-9]+)조(의[0-9]+)?(?:제?([0-9]+)항)?(?:제?([0-9]+)호(의[0-9]+)?)?(?:([가-하])목)?$',
  unicode: true,
);
// A law name never contains another article or a list separator. Such text
// ('도로교통법 제32조, 제33조', '도로교통법 제32조 및 제33조') stays one raw key.
final _badName = lawRegex(r'[,&]|[0-9]조');
final _cache = <String, List<String>>{};

String _lawCompact(String value) =>
    normalizeLawText(value).replaceAll(lawRegex('[·ㆍ･・ᆞ]'), '');

/// Full (backtracking) match of one article key, or null. Same rule in Python/JS.
RegExpMatch? _structured(String compact) {
  final m = _key.firstMatch(compact);
  if (m == null) return null;
  final name = m[1]!;
  if (name == '제' ||
      lawRegex(r'^[0-9]+$').hasMatch(name) ||
      _badName.hasMatch(name)) {
    return null;
  }
  return m;
}

String _lawName(String name) {
  String clean(String value) => value
      .replaceAll(lawRegex(r'''[「」『』【】\[\]“”‘’"']'''), '')
      .replaceAll(lawRegex(r'\((?:약칭|이하같음|경찰청지침)\)'), '');
  name = clean(name);
  var suffix = '';
  for (final s in ['시행규칙', '시행령']) {
    if (name.endsWith(s)) {
      suffix = s;
      name = name.substring(0, name.length - s.length);
      break;
    }
  }
  name = clean(name);
  if (name.isEmpty) return '';
  return (lawAliases[name] ?? name) + (suffix.isEmpty ? '' : ' $suffix');
}

String canonicalLaw(String value) {
  final raw = ReportPolicy.norm(value);
  final m = _structured(_lawCompact(raw));
  if (m == null) return raw;
  final name = _lawName(m[1]!);
  if (name.isEmpty) return raw;
  return '$name 제${m[2]}조${m[3] ?? ''}${m[4] == null ? '' : '제${m[4]}항'}${m[5] == null ? '' : '제${m[5]}호'}${m[6] ?? ''}${m[7] == null ? '' : '${m[7]}목'}';
}

List<String> readLaws(Object? value) {
  final text = value?.toString() ?? '';
  final cached = _cache[text];
  if (cached != null) return cached;
  final keys = text
      .split(lawRegex(r'\r\n?|\n|\u2028|\u2029'))
      .where((s) => ReportPolicy.norm(s).isNotEmpty)
      .map(canonicalLaw)
      .toSet()
      .toList();
  final result = List<String>.unmodifiable(keys);
  if (_cache.length >= 8192) _cache.remove(_cache.keys.first);
  _cache[text] = result;
  return result;
}

/// 상세 법규 링크 값. [keyed] 면 개별 저장 키(`readLaws`), 아니면(법규 검색 v2 를 모르는 구서버)
/// 예전처럼 저장 원문 하나(앞뒤 공백 제거) — 구서버는 저장값 완전 일치로 찾는다.
List<String> lawLinkValues(Object? value, {required bool keyed}) {
  if (keyed) return readLaws(value);
  final raw = ReportPolicy.norm(value);
  return raw.isEmpty ? const [] : [raw];
}

String primaryLaw(Object? value) => (value?.toString() ?? '')
    .split(lawRegex(r'\r\n?|\n|\u2028|\u2029'))
    .map((s) => ReportPolicy.norm(s))
    .firstWhere((s) => s.isNotEmpty, orElse: () => '');
String supplementLaw(String answer, String legacy) =>
    parseLawValues(answer, legacy);

String legacyViolationLaw(String answer) {
  final m = lawRegex(
    r'(?:「\s*([가-힣·\s]{1,40}?법)\s*」|(도로교통법))\s*제\s*(\d+\s*조(?:\s*의\s*\d+)?)(?:\s*(제?\s*\d{1,2}\s*항))?',
  ).firstMatch(answer);
  if (m == null) return '';
  String compact(String value) => value.replaceAll(lawRegex(r'\s+'), '');
  return '${compact(m[1] ?? m[2]!)} 제${compact(m[3]!)}${compact(m[4] ?? '')}';
}

String parseViolationLaw(String answer) =>
    supplementLaw(answer, legacyViolationLaw(answer));

bool _termMatches(List<String> keys, String term, {required bool partial}) {
  if (keys.contains(ReportPolicy.norm(term))) return true;
  final aq = lawRegex(
    r'^제?([0-9]+)조(의[0-9]+)?(?:제?([0-9]+)항)?(?:제?([0-9]+)호(의[0-9]+)?)?(?:([가-하])목)?$',
  ).firstMatch(normalizeLawText(term));
  if (aq != null) {
    final tail =
        '제${aq[1]}조${aq[2] ?? ''}${aq[3] == null ? '' : '제${aq[3]}항'}${aq[4] == null ? '' : '제${aq[4]}호'}${aq[5] ?? ''}${aq[6] == null ? '' : '${aq[6]}목'}';
    return keys
        .expand(ancestorLaws)
        .any((p) => p == tail || p.endsWith(' $tail'));
  }
  final query = canonicalLaw(term);
  final compact = _lawCompact(query);
  final structured = _structured(compact) != null;
  var nameQuery = compact.replaceAll(lawRegex(r'''[「」『』【】\[\]“”‘’"']'''), '');
  var suffix = '';
  for (final s in ['시행규칙', '시행령']) {
    if (nameQuery.endsWith(s)) {
      suffix = s;
      nameQuery = nameQuery.substring(0, nameQuery.length - s.length);
      break;
    }
  }
  final baseName = lawAliases[nameQuery];
  final name = baseName == null
      ? null
      : baseName + (suffix.isEmpty ? '' : ' $suffix');
  for (final key in keys) {
    if (key == query) return true;
    if (structured && ancestorLaws(key).contains(query)) return true;
    if (name != null && key.startsWith('$name 제')) return true;
    if (partial &&
        !structured &&
        name == null &&
        _lawCompact(key).toLowerCase().contains(compact.toLowerCase())) {
      return true;
    }
  }
  return false;
}

final _matchCache = <String, bool>{};
bool matchesLaws(Object? value, String query, {bool partial = false}) {
  final key = jsonEncode([value?.toString() ?? '', query, partial]);
  final cached = _matchCache[key];
  if (cached != null) return cached;
  final result = _matchesLawsUncached(value, query, partial: partial);
  if (_matchCache.length >= 16384) _matchCache.remove(_matchCache.keys.first);
  _matchCache[key] = result;
  return result;
}

bool _matchesLawsUncached(Object? value, String query, {bool partial = false}) {
  final text = ReportPolicy.norm(query);
  if (text.isEmpty) return true;
  final keys = readLaws(value);
  if (text == '__없음__') return keys.isEmpty;
  // A query equal to one stored key matches it whole, even if that raw key
  // itself contains ',' or '&' (e.g. a user-edited '제32조, 제33조').
  if (keys.contains(text)) return true;
  if (lawRegex(r'[\r\n\u2028\u2029]').hasMatch(text)) {
    return readLaws(text).every((q) => _termMatches(keys, q, partial: partial));
  }
  final groups = text
      .split(',')
      .map(
        (g) => g
            .split('&')
            .map((s) => ReportPolicy.norm(s))
            .where((s) => s.isNotEmpty)
            .toList(),
      )
      .where((g) => g.isNotEmpty)
      .toList();
  return groups.isEmpty ||
      groups.any(
        (g) => g.every((q) => _termMatches(keys, q, partial: partial)),
      );
}

List<String> availableLawValues(Iterable<Object?> values) =>
    values.expand(readLaws).toSet().toList()..sort();
List<String> _selectedKeys(LawMap result) {
  final selected = result['selected'] as String;
  if (selected.isEmpty) return [];
  final refs = (result['refs'] as List).cast<LawMap>();
  final primary = refs.where((r) => r['key'] == selected).firstOrNull;
  if (primary == null) return [selected];
  final rank = primary['rank'];
  var candidates = refs
      .where((r) => r['kind'] == 'article' && r['rank'] == rank)
      .toList();
  if (rank == 3) {
    final groups = (primary['evidence'] as List)
        .cast<LawMap>()
        .where((e) => e['role'] == 'unknown')
        .map((e) => e['group'])
        .toSet();
    candidates = refs
        .where(
          (r) =>
              r['kind'] == 'article' &&
              r['decision'] == 'unknown' &&
              (r['evidence'] as List).cast<LawMap>().any(
                (e) => e['role'] == 'unknown' && groups.contains(e['group']),
              ),
        )
        .toList();
  }
  return <String>{
    selected,
    ...candidates.map((r) => r['key'] as String),
  }.toList();
}

String parseLawValues(String answer, String legacy, {bool multiple = true}) {
  final key = canonicalLaw(legacy);
  final result = chooseLawBasis(answer, oldKey: key);
  final selected = result['selected'] as String;
  if (selected.isEmpty && legacy.isNotEmpty) {
    final refs = (result['refs'] as List).cast<LawMap>().where(
      (r) => r['key'] == key || (r['key'] as String).startsWith('$key제'),
    );
    if (!refs.any(
      (r) =>
          r['decision'] == 'excluded' ||
          r['decision'] == 'procedure' ||
          r['decision'] == 'unresolved' ||
          r['decision'] == 'conflict' ||
          r['decision'] == 'general',
    )) {
      return legacy;
    }
  }
  final keys = multiple
      ? _selectedKeys(result)
      : (selected.isEmpty ? <String>[] : [selected]);
  return keys.length == 1 && keys.single == key ? legacy : keys.join('\n');
}

List<String> ancestorLaws(String key) {
  final m = _structured(_lawCompact(key));
  if (m == null || !key.contains(' 제')) return [key];
  var root = '${key.split(' 제').first} 제${m[2]}조${m[3] ?? ''}';
  final values = <String>{key, root};
  if (m[4] != null) {
    root += '제${m[4]}항';
    values.add(root);
  }
  if (m[5] != null) values.add('$root제${m[5]}호${m[6] ?? ''}');
  return values.toList();
}

/// Stored-key membership: the predicate behind every per-law statistic.
///
/// [query] is one stored key (or several, one per line = AND) exactly as the
/// statistics/detail links pass it. A row belongs to key K when one of its keys
/// is K or a descendant paragraph/item of K ([ancestorLaws]) — the same rule as
/// [lawMemberships], so a law bar's count equals the rows this returns. Unlike
/// [matchesLaws] there is no ','/'&' splitting and no law-name prefix search.
/// `__없음__` selects rows without any law. Same as Python `matches_law_keys`.
bool matchesLawKeys(Object? value, String query) {
  final text = ReportPolicy.norm(query);
  if (text.isEmpty) return true;
  final keys = readLaws(value);
  if (text == '__없음__') return keys.isEmpty;
  final parents = keys.expand(ancestorLaws).toSet();
  return readLaws(text).every(parents.contains);
}

List<String> lawMemberships(Object? value, Set<String> universe) => readLaws(
  value,
).expand(ancestorLaws).where(universe.contains).toSet().toList()..sort();

/// Exact raw-value SQL after resolving distinct values with matchesLaws.
/// Hex literals avoid SQL quoting and host-parameter limits, including NUL text.
String lawSqlValues(String column, Iterable<String> values) {
  final unique = values.toSet();
  if (unique.isEmpty) return '0=1';
  final terms = unique.map(
    (s) =>
        "CAST(X'${utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}' AS TEXT)",
  );
  return "IFNULL($column,'') IN (${terms.join(',')})";
}

/// Read SQLite text as bytes: the FFI driver's UTF-8 decoder strips a leading
/// BOM from TEXT. Preserve it here so the subsequent exact SQL matches storage.
String lawSqlRawValue(Object? value) {
  if (value == null) return '';
  if (value is! List<int>) return value.toString();
  final bom =
      value.length >= 3 &&
      value[0] == 239 &&
      value[1] == 187 &&
      value[2] == 191;
  return (bom ? '\uFEFF' : '') + utf8.decode(value);
}
