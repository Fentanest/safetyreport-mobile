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

        expect(vehicleKind(plate), equals(expectedKind), reason: 'plate: $plate');
        expect(fineClass(plate), equals(expectedClass), reason: 'plate: $plate');
      }
    });

    test('cases', () {
      final cases = vectors['cases'] as List;
      for (final testCase in cases) {
        final name = testCase['name'];
        final record = testCase['record'] as Map<String, dynamic>;
        final expectedAmount = testCase['amount'];
        final expectedRule = testCase['rule'];

        final result = estimate(record);
        if (expectedAmount == null) {
          if (expectedRule == null) {
            expect(result, isNull, reason: 'case: $name');
          } else {
            // Some tests have expectedRule but amount is null, meaning it was classified but no fine amount could be determined (e.g. motorcycle parking).
            // Actually `estimate` returns null if amount is null.
            expect(result, isNull, reason: 'case: $name');
          }
        } else {
          expect(result, isNotNull, reason: 'case: $name');
          expect(result!['amount'], equals(expectedAmount), reason: 'case: $name (amount)');
          expect(result['rule'], equals(expectedRule), reason: 'case: $name (rule)');
        }
      }
    });
  });
}
