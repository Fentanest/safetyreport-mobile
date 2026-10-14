import 'report_policy.dart';
import 'dart:convert';
import 'law_citations.dart';
import 'law_selection.dart';
import 'law_recognition_data.dart';

final _key = lawRegex(
  r'(.+?)제?(\d+)조(의\d+)?(?:제?(\d+)항)?(?:제?(\d+)호(의\d+)?)?(?:([가-하])목)?',
  unicode: true,
);
final _cache = <String, List<String>>{};
String canonicalLaw(String value) {
  final raw = ReportPolicy.norm(value);
  final text = normalizeLawText(raw).replaceAll(lawRegex('[·ㆍ･・ᆞ]'), '');
  final m = _key.matchAsPrefix(text);
  if (m == null || m.end != text.length) return raw;
  var name = m[1]!;
  if (name == '제' || lawRegex(r'^[0-9]+$').hasMatch(name)) return raw;
  name = name
      .replaceAll(lawRegex(r'''[「」『』【】\[\]“”‘’"']'''), '')
      .replaceAll(lawRegex(r'\((?:약칭|이하같음|경찰청지침)\)'), '');
  var suffix = '';
  for (final s in ['시행규칙', '시행령']) {
    if (name.endsWith(s)) {
      suffix = s;
      name = name.substring(0, name.length - s.length);
      break;
    }
  }
  name = name
      .replaceAll(lawRegex(r'''[「」『』【】\[\]“”‘’"']'''), '')
      .replaceAll(lawRegex(r'\((?:약칭|이하같음|경찰청지침)\)'), '');
  name = (lawAliases[name] ?? name) + (suffix.isEmpty ? '' : ' $suffix');
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
  final compact = normalizeLawText(query).replaceAll(lawRegex('[·ㆍ･・ᆞ]'), '');
  final m = _key.matchAsPrefix(compact);
  final structured = m != null && m.end == compact.length;
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
        normalizeLawText(key)
            .replaceAll(lawRegex('[·ㆍ･・ᆞ]'), '')
            .toLowerCase()
            .contains(compact.toLowerCase())) {
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
  final compact = normalizeLawText(key).replaceAll(lawRegex('[·ㆍ･・ᆞ]'), '');
  final m = _key.matchAsPrefix(compact);
  if (m == null || m.end != compact.length || !key.contains(' 제')) return [key];
  var root = '${key.split(' 제').first} 제${m[2]}조${m[3] ?? ''}';
  final values = <String>{key, root};
  if (m[4] != null) {
    root += '제${m[4]}항';
    values.add(root);
  }
  if (m[5] != null) values.add('$root제${m[5]}호${m[6] ?? ''}');
  return values.toList();
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
