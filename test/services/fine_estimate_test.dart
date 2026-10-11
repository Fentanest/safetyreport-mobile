import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/fine_estimate.dart';

void main() {
  group('fine_estimate_vectors', () {
    late Map<String, dynamic> vectors;

    setUpAll(() {
      final file = File('test/fixtures/fine_estimate_vectors.json');
      vectors = jsonDecode(file.readAsStringSync());
    });

    test('rule_version matches', () {
      expect(ruleVersion, equals(vectors['rule_version']));
    });

    test('plates', () {
      final plates = vectors['plates'] as List;
      for (final plateInfo in plates) {
        final plate = plateInfo['plate'];
        final expectedKind = plateInfo['kind'];
        final expectedClass = plateInfo['class'];

        expect(
          vehicleKind(plate),
          equals(expectedKind),
          reason: 'plate: $plate',
        );
        expect(
          fineClass(plate),
          equals(expectedClass),
          reason: 'plate: $plate',
        );
      }
    });

    test('cases', () {
      final cases = vectors['cases'] as List;
      for (final testCase in cases) {
        final name = testCase['name'];
        final record = testCase['record'] as Map<String, dynamic>;
        final expectedAmount = testCase['amount'];
        final expectedRule = testCase['rule'];
        final original = jsonEncode(record);

        expect(
          classify(record),
          equals(expectedRule),
          reason: 'case: $name (classify)',
        );
        final result = estimate(record);
        if (expectedAmount == null) {
          expect(result, isNull, reason: 'case: $name');
        } else {
          expect(result, isNotNull, reason: 'case: $name');
          expect(
            result!['amount'],
            equals(expectedAmount),
            reason: 'case: $name (amount)',
          );
          expect(
            result['rule'],
            equals(expectedRule),
            reason: 'case: $name (rule)',
          );
          if (testCase.containsKey('basis')) {
            expect(
              result['basis'],
              testCase['basis'],
              reason: 'case: $name (basis)',
            );
          }
        }
        expect(
          jsonEncode(record),
          original,
          reason: 'case: $name (확정 원문과 입력 보존)',
        );
      }
    });
  });
}
