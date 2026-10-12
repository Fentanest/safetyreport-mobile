import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/plate_normalize.dart';

/// 번호판 정규화 — 세 레포 공유 벡터(test/fixtures/plate_normalize_vectors.json)로 검증한다.
/// 같은 파일을 서버(tests/fixtures/…)·지도(tests/fixtures/…) 레포도 바이트 그대로 가진다.
void main() {
  group('plate_normalize_vectors', () {
    late Map<String, dynamic> vectors;

    setUpAll(() {
      final file = File('test/fixtures/plate_normalize_vectors.json');
      vectors = jsonDecode(file.readAsStringSync());
    });

    test('cases', () {
      final cases = vectors['cases'] as List;
      for (final c in cases) {
        final raw = c['raw'];
        final expected = c['expected'];
        expect(
          normalizePlate(raw),
          equals(expected),
          reason: 'name: ${c['name']}, raw: $raw',
        );
      }
    });
  });
}
