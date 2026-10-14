import 'law_citations.dart';
import 'law_selection.dart';
import 'law_recognition_data.dart';

final _key = RegExp(
  r'(.+?)제?(\d+)조(의\d+)?(?:제?(\d+)항)?(?:제?(\d+)호(의\d+)?)?(?:([가-하])목)?',
  unicode: true,
);
final _cache = <String, List<String>>{};
String canonicalLaw(String value) {
  final raw = value.trim();
  final text = normalizeLawText(raw).replaceAll(RegExp('[·ㆍ･・ᆞ]'), '');
  final m = _key.matchAsPrefix(text);
  if (m == null || m.end != text.length) return raw;
  var name = m[1]!;
  var suffix = '';
  for (final s in ['시행규칙', '시행령']) {
    if (name.endsWith(s)) {
      suffix = s;
      name = name.substring(0, name.length - s.length);
      break;
    }
  }
  name = (lawAliases[name] ?? name) + (suffix.isEmpty ? '' : ' $suffix');
  return '$name 제${m[2]}조${m[3] ?? ''}${m[4] == null ? '' : '제${m[4]}항'}${m[5] == null ? '' : '제${m[5]}호'}${m[6] ?? ''}${m[7] == null ? '' : '${m[7]}목'}';
}

List<String> readLaws(Object? value) {
  final text = value?.toString() ?? '';
  final cached = _cache[text];
  if (cached != null) return cached;
  final keys = text
      .split(RegExp(r'\r\n?|\n'))
      .where((s) => s.trim().isNotEmpty)
      .map(canonicalLaw)
      .toSet()
      .toList();
  final result = List<String>.unmodifiable(keys);
  if (_cache.length >= 8192) _cache.remove(_cache.keys.first);
  _cache[text] = result;
  return result;
}

String primaryLaw(Object? value) => (value?.toString() ?? '')
    .split(RegExp(r'\r\n?|\n'))
    .map((s) => s.trim())
    .firstWhere((s) => s.isNotEmpty, orElse: () => '');
String supplementLaw(String answer, String legacy) {
  final key = canonicalLaw(legacy);
  final result = chooseLawBasis(answer, oldKey: key);
  final selected = result['selected'] as String;
  if (selected.isEmpty && legacy.isNotEmpty) {
    final refs = (result['refs'] as List).cast<LawMap>().where(
      (r) => r['key'] == key || (r['key'] as String).startsWith('$key제'),
    );
    if (!refs.any(
      (r) => r['decision'] == 'excluded' || r['decision'] == 'procedure',
    )) {
      return legacy;
    }
  }
  return selected == key ? legacy : selected;
}

String legacyViolationLaw(String answer) {
  final m = RegExp(r'(?:「\s*([가-힣·\s]{1,40}?법)\s*」|(도로교통법))\s*제\s*(\d+\s*조(?:\s*의\s*\d+)?)(?:\s*(제?\s*\d{1,2}\s*항))?').firstMatch(answer);
  if (m == null) return '';
  String compact(String value) => value.replaceAll(RegExp(r'\s+'), '');
  return '${compact(m[1] ?? m[2]!)} 제${compact(m[3]!)}${compact(m[4] ?? '')}';
}
String parseViolationLaw(String answer) => supplementLaw(answer, legacyViolationLaw(answer));
