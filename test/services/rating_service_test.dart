import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/rating_service.dart';

Report _report({
  required String reportNumber,
  String status = '답변완료',
  String pollStatus = '참여 가능',
}) {
  return Report(
    id: reportNumber,
    reportNumber: reportNumber,
    name: '테스트 신고',
    date: '2026-05-23',
    responseDate: '2026-05-23',
    agency: '테스트 기관',
    manager: '담당자',
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
}

void main() {
  group('RatingService.isListEligible', () {
    test('참여 가능 + 처리 완료 신고만 true', () {
      expect(
        RatingService.isListEligible(_report(reportNumber: 'SPP-2605-0000001')),
        isTrue,
      );
    });

    test('pollStatus 가 비어 있어도 서버 기준이면 true', () {
      expect(
        RatingService.isListEligible(
          _report(reportNumber: 'SPP-2605-0000006', pollStatus: ''),
        ),
        isTrue,
      );
    });

    test('참여 완료 신고는 false', () {
      expect(
        RatingService.isListEligible(
          _report(reportNumber: 'SPP-2605-0000002', pollStatus: '참여 완료'),
        ),
        isFalse,
      );
    });

    test('검토중 신고는 false', () {
      expect(
        RatingService.isListEligible(
          _report(reportNumber: 'SPP-2605-0000003', status: '검토중'),
        ),
        isFalse,
      );
    });
  });

  group('RatingService.ineligibleReason', () {
    test('답변 대기 pollStatus 여도 처리 완료면 허용한다', () {
      expect(
        RatingService.ineligibleReason(
          _report(
            reportNumber: 'SPP-2605-0000004',
            status: '답변완료',
            pollStatus: '답변 대기',
          ),
        ),
        isNull,
      );
    });

    test('진행중 계열 상태는 처리중 메시지로 막는다', () {
      expect(
        RatingService.ineligibleReason(
          _report(reportNumber: 'SPP-2605-0000005', status: '진행중'),
        ),
        '처리중 상태에서는 만족도 조사를 진행할 수 없습니다.',
      );
    });
  });
}
