// 별점 대상 판정 — 서버 services/rating_eligibility.py 와 같은 규칙(contracts/rating-eligibility-vectors.json, 두 레포 바이트 동일).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/rating_service.dart';

Report _report(String pollStatus, String status) => Report(
  id: '1',
  reportNumber: 'SPP-1',
  name: '테스트',
  date: '2026-09-01',
  responseDate: '',
  agency: '',
  manager: '',
  status: status,
  result: status,
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
  pollStatus: pollStatus,
);

void main() {
  final doc =
      jsonDecode(
            File(
              'contracts/rating-eligibility-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('shared eligibility vectors (same as server)', () {
    for (final raw in doc['eligibility_cases'] as List) {
      final c = raw as Map<String, dynamic>;
      // 서버의 None 은 모델에서 빈 문자열
      final report = _report(
        (c['poll_status'] as String?) ?? '',
        (c['status'] as String?) ?? '',
      );
      expect(RatingService.ineligibleReason(report), c['reason'], reason: '$c');
      expect(
        RatingService.isListEligible(report),
        c['reason'] == null,
        reason: 'list vs submit $c',
      );
    }
  });
}
