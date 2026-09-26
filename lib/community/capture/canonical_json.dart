// 해시용 정규 JSON (contracts/community-ingest/canonical-json.md).
//
// 규칙: object 키 UTF-16 코드 단위 오름차순(재귀), 구분자 `,`·`:` 공백 없음,
// `"` → `\"`, `\` → `\\` 만 이스케이프, 비ASCII 그대로, null 키 생략 없음.
import 'dart:collection';

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>(
      (a, b) => _compareUtf16(a, b),
    );
    for (final entry in value.entries) {
      sorted[entry.key.toString()] = _sortKeys(entry.value);
    }
    return sorted;
  }
  if (value is List) return value.map(_sortKeys).toList(growable: false);
  return value;
}

int _compareUtf16(String a, String b) {
  final ac = a.codeUnits;
  final bc = b.codeUnits;
  final n = ac.length < bc.length ? ac.length : bc.length;
  for (var i = 0; i < n; i++) {
    if (ac[i] != bc[i]) return ac[i] - bc[i];
  }
  return ac.length - bc.length;
}

String _escape(String s) {
  final out = StringBuffer();
  for (final rune in s.runes) {
    if (rune == 0x22) {
      out.write('\\"');
    } else if (rune == 0x5C) {
      out.write('\\\\');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

String _encode(Object? value) {
  if (value == null) return 'null';
  if (value is String) return '"${_escape(value)}"';
  if (value is int) return value.toString();
  if (value is Map) {
    final parts = <String>[];
    for (final entry in value.entries) {
      parts.add('"${_escape(entry.key.toString())}":${_encode(entry.value)}');
    }
    return '{${parts.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_encode).join(',')}]';
  }
  throw ArgumentError('canonical JSON 에는 object/string/정수/null 만 쓸 수 있다: $value');
}

/// 정규 JSON 문자열.
String canonicalJson(Object? value) => _encode(_sortKeys(value));
