import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/fine_amount_syntax.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine;
import 'package:safetyreport/services/standalone_parser.dart';

void main() {
  final cases =
      (jsonDecode(
                File('contracts/explicit-fine-vectors.json').readAsStringSync(),
              )
              as Map)['cases']
          as List;
  final record = <String, dynamic>{
    'category': 'parking',
    'entry_value': '불법주정차신고-기타 불법주정차',
    '위반법규': '도로교통법 제32조',
    '차량번호': '12가3456',
  };
  for (final c in cases) {
    test(c['name'] as String, () {
      final token = explicitFineNumber(c['text'] as String);
      expect(token, c['number']);
      final raw = token == null ? '과태료' : '과태료: $token원';
      expect(fine.extractFineAmount(raw, record), c['amount']);
      expect(fine.isEstimateTarget(raw, record), c['amount'] == 0);
      final report = parseJsonToReport({}, {
        'C_NOW': 10,
        'C_APP_GUBUN_NM': record['entry_value'],
        'answers': [
          {'C_MANAGER_TYPE_NM': '수용', 'C_MANAGE_CONTENTS': c['text']},
        ],
      });
      expect(report.status, '수용');
      expect(
        report.fineInfo,
        c['name'] == 'penalty distinct' ? '범칙금: 30,000원' : raw,
      );
      if (c['name'] == 'penalty distinct') {
        expect(report.penaltyPoints, '벌점: 15점');
      }
    });
  }
}
