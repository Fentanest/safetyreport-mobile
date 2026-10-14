import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/law_values.dart';

void main() {
  final data = jsonDecode(File('contracts/law-parser-vectors.json').readAsStringSync()) as Map;
  for (final c in data['cases'] as List) {
    test(c['name'] as String, () {
      expect(canonicalLaw(primaryLaw(parseViolationLaw(c['answer'] as String))), c['primary']);
    });
  }
  test('legacy format is retained', () {
    expect(parseViolationLaw('도로교통법 제13조3항 위반한 사실이 확인되었습니다.'), '도로교통법 제13조3항');
  });
}
