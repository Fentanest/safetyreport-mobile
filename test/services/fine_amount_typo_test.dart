import 'dart:convert';
import 'dart:io';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine;
import 'package:safetyreport/services/standalone_parser.dart' show extractFineAmount;
import 'package:safetyreport/community/capture/observation_rules.dart' as rules;
import 'package:safetyreport/community/capture/community_capture.dart' show mobileParserVersion;

void main() {
  final vectors = jsonDecode(File('test/fixtures/fine_amount_typo_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  for (final c in vectors['cases'] as List) {
    test(c['name'] as String, () {
      final r = Map<String, dynamic>.from(c['record'] as Map);
      final raw = c['raw'] as String;
      final original = jsonEncode(r);
      final row = {...r, '범칙금_과태료': raw, '처리상태': '수용', '처리기관': '시험구청', '담당자': '시험'};
      final stats = LocalDbService.buildStatsCategory([row], [row]);
      expect(stats['total_fine_amount'], c['stats_won']);
      expect((stats['by_agency'] as List).single['total_fine_amount'], c['stats_won']);
      expect(extractFineAmount(raw, r), c['stats_won']);
      final amount = rules.parseAmount(raw, r);
      expect(amount.confirmedWon, c['confirmed_won']);
      expect(amount.kind, c['kind']);
      final p = rules.buildPayload({
        'processing_status': '수용', 'penalty_amount': raw,
        'category': r['category'], 'entry_value': r['entry_value'],
        'ssnpc_cd': r['ssnpc_cd'], 'ssnpc_type': r['ssnpc_type'],
        'car_number': r['차량번호'], 'report_name': r['신고명'],
        'violation_law': r['위반법규'], 'occurrence_time': r['발생시각'],
        'photo_first_capture': r['사진_첫촬영'], 'photo_last_capture': r['사진_끝촬영'],
      });
      expect((p['amount'] as Map)['confirmed_won'], c['confirmed_won']);
      final eligible = raw.contains('과태료') && c['stats_won'] == 0 && fine.estimate(r) != null;
      expect(p.containsKey('fine_estimate'), eligible);
      expect(jsonEncode(r), original);
    });
  }
  for (final c in vectors['candidate_cases'] as List) {
    test(c['name'] as String, () {
      expect(fine.parseAmountNumber(c['number'] as String, (c['legal_amounts'] as List).cast<int>()), c['confirmed_won']);
    });
  }
  test('보정 표시/정상 금액 유지/재전송 파서 버전', () {
    final r = Map<String, dynamic>.from(vectors['cases'][0]['record'] as Map);
    expect(fine.correctedFineText('과태료: 40,0000원', r), '과태료: 40,000원');
    expect(fine.correctedFineText('과태료: 400,000원', r), isNull);
    expect(mobileParserVersion, 'mobile-parser-7');
  });
}
