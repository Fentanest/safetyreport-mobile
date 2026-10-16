import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/law_citations.dart';
import 'package:safetyreport/services/law_recognition_data.dart';
import 'package:safetyreport/services/law_selection.dart';
import 'package:safetyreport/services/law_values.dart';

void main() {
  final data =
      jsonDecode(File('contracts/law-parser-vectors.json').readAsStringSync())
          as Map;
  for (final c in data['cases'] as List) {
    test(c['name'] as String, () {
      final value = parseViolationLaw(c['answer'] as String);
      expect(canonicalLaw(primaryLaw(value)), c['primary']);
      if ((c as Map).containsKey('selected')) {
        expect(
          chooseLawBasis(c['answer'] as String)['selected'],
          c['selected'],
        );
      }
      if (c.containsKey('value')) expect(value, c['value']);
    });
  }
  test('legacy format is retained', () {
    expect(parseViolationLaw('도로교통법 제13조3항 위반한 사실이 확인되었습니다.'), '도로교통법 제13조3항');
  });
  test('recognition contract matches generated Dart data', () {
    final contract =
        jsonDecode(File('contracts/law-recognition.json').readAsStringSync())
            as Map;
    expect(lawAliases, contract['aliases']);
    String dart(String p) => p.replaceAll('(?P<', '(?<');
    expect(lawArticlePattern, dart(contract['article_pattern'] as String));
    expect(lawShortPattern, dart(contract['short_pattern'] as String));
  });
  test('digit boundary is kept only between digits', () {
    final copy = normalizedLawCopy('도로교통법 제 32 조의2 \u3000 1항 및 제33조');
    expect(copy.text, '도로교통법제32조의2 1항및제33조');
    expect(copy.mapping.length, copy.text.length);
    expect(copy.mapping[copy.text.indexOf(' ')], [14, 15]);
  });
  test('inherited paragraph uses ASCII digits only', () {
    List<String> keys(String t) =>
        parseLawCitations(t).refs.map((r) => r['key'] as String).toList();
    expect(keys('도로교통법 제32조를 위반하여 같은 조 제3항에 따라'), [
      '도로교통법 제32조',
      '도로교통법 제32조제3항',
    ]);
    for (final digit in ['\uff13', '\u0663']) {
      expect(keys('도로교통법 제32조를 위반하여 같은 조 제$digit항에 따라'), ['도로교통법 제32조']);
    }
  });
  test('entity rule matches Python and the browser', () {
    expect(decodeLawEntity('&nbsp;'), '\u00a0');
    expect(decodeLawEntity('&notit;'), '\u00acit;');
    expect(decodeLawEntity('&#1;'), '\u0001');
    expect(decodeLawEntity('&#x10FFFF;'), '\u{10ffff}');
    expect(decodeLawEntity('&#0;'), '\ufffd');
    expect(decodeLawEntity('&#x80;'), '\u20ac');
    expect(decodeLawEntity('&#xD800;'), '\ufffd');
    expect(decodeLawEntity('&#${'9' * 5000};'), '\ufffd');
    expect(decodeLawEntities('a&nbspb&amp;c'), 'a&nbspb&c');
  });
}
