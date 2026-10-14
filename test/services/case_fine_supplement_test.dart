import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/case_fine_supplement.dart';
import 'package:safetyreport/services/standalone_parser.dart';

void main() {
  final cases =
      (jsonDecode(
                File(
                  'contracts/case-fine-supplement-vectors.json',
                ).readAsStringSync(),
              )
              as Map)['cases']
          as List;
  for (final c in cases) {
    test(c['name'] as String, () {
      expect(supplementCaseFine(c['status'], c['penalty'], c['text']), (
        c['expected_status'],
        c['expected_penalty'],
      ));
    });
  }
  test('existing disposition and lifecycle are preserved', () {
    final text = cases.first['text'] as String;
    for (final status in ['수용', '불수용', '기타']) {
      for (final penalty in [
        '과태료',
        '과태료: 0원',
        '과태료: 100,000원',
        '범칙금: 30,000원',
        '경고',
      ]) {
        expect(supplementCaseFine(status, penalty, text), (status, penalty));
      }
    }
    for (final status in ['취하', '이송', '처리중', '진행', '검토중', '보완요청', '']) {
      for (final penalty in ['', '미확인']) {
        expect(supplementCaseFine(status, penalty, text), (status, penalty));
      }
    }
  });
  test('full parser supplements only after final status', () {
    final text = cases.first['text'] as String;
    for (final c in [('수용', 10), ('불수용', 14)]) {
      final detail = <String, dynamic>{
        'C_NOW': c.$2,
        'C_APP_GUBUN_NM': '자동차·교통위반-기타 자동차 안전기준 위반',
        'answers': [
          {'C_MANAGER_TYPE_NM': c.$1, 'C_MANAGE_CONTENTS': text},
        ],
      };
      final original = jsonEncode(detail);
      final report = parseJsonToReport({}, detail);
      expect(report.status, c.$1);
      expect(report.fineInfo, '과태료');
      expect(report.penaltyPoints, '');
      expect(jsonEncode(detail), original);
    }
    final structured = cases.firstWhere(
      (c) =>
          (c['text'] as String).contains('처리결과') &&
          c['expected_status'] == '수용',
    )['text'];
    final report = parseJsonToReport({}, {
      'C_NOW': 15,
      'C_APP_GUBUN_NM': '자동차·교통위반',
      'answers': [
        {'C_MANAGER_TYPE_NM': '기타', 'C_MANAGE_CONTENTS': structured},
      ],
    });
    expect(report.status, '수용');
    expect(report.fineInfo, '과태료');
    final withdrawn = parseJsonToReport({}, {
      'C_NOW': 20,
      'C_APP_GUBUN_NM': '불법주정차신고',
      'answers': [
        {'C_MANAGER_TYPE_NM': '수용', 'C_MANAGE_CONTENTS': text},
      ],
    });
    expect(withdrawn.status, '취하');
    expect(withdrawn.fineInfo, '');
  });
}
