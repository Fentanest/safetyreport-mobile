import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/report_policy.dart';
import 'package:safetyreport/utils/report_duration.dart';

Report _report({
  String status = '수용',
  String date = '2026-10-01',
  String responseDate = '2026-10-16',
}) => Report.fromJson({'처리상태': status, '신고일': date, '답변일': responseDate});

void main() {
  test('완료 상태는 오늘과 무관하게 신고일부터 답변일까지 센다', () {
    for (final status in ReportPolicy.completedStatuses) {
      expect(
        reportDurationLabel(_report(status: status), today: DateTime(2027)),
        '소요 15일',
      );
    }
  });

  test('처리중 상태는 오래된 답변일이 있어도 오늘까지 센다', () {
    for (final status in ReportPolicy.processingStatuses) {
      expect(
        reportDurationLabel(
          _report(status: status),
          today: DateTime(2026, 10, 23, 23, 59),
        ),
        '경과 22일',
      );
    }
  });

  test('취하·이송·보완요청·미상은 경과일로 추측하지 않는다', () {
    for (final status in ['취하', '이송', '보완요청', '', '알 수 없는 상태']) {
      expect(reportDurationLabel(_report(status: status)), isNull);
    }
  });

  test('당일 0일, 자정 경계 1일, 윤년과 연도 경계를 달력 날짜로 센다', () {
    for (final sample in [
      ('2026-10-01 00:00:00', '2026-10-01 23:59:59', '소요 0일'),
      ('2026-10-01 23:59:59', '2026-10-02 00:00:00', '소요 1일'),
      ('2024-02-28', '2024-03-01', '소요 2일'),
      ('2025-12-31', '2026-01-01', '소요 1일'),
      (' 2026-10-01 ', ' 2026-10-16 ', '소요 15일'),
      ('2026-10-01T23:00:00+09:00', '2026-10-02T01:00:00+09:00', '소요 1일'),
    ]) {
      expect(
        reportDurationLabel(_report(date: sample.$1, responseDate: sample.$2)),
        sample.$3,
      );
    }
  });

  test('결측·잘못된 날짜·역전은 0일 등으로 바꾸지 않는다', () {
    for (final value in [
      '',
      '-',
      'null',
      '2026-02-30',
      '2026-13-01',
      'bad',
      '2026-10-01garbage',
      '2026-10-01 invalid',
    ]) {
      expect(reportDurationLabel(_report(date: value)), isNull);
      expect(reportDurationLabel(_report(responseDate: value)), isNull);
    }
    expect(reportDurationLabel(_report(responseDate: '2026-09-30')), isNull);
    expect(
      reportDurationLabel(
        _report(status: '처리중', date: '2026-10-24'),
        today: DateTime(2026, 10, 23),
      ),
      isNull,
    );
  });
}
