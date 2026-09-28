import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/observation_rules.dart';
import 'package:safetyreport/community/capture/report_adapter.dart';

import '../support/ui_harness.dart';

/// observation-v2(2026-09-28): 파서 결과 `Report.law`(위반법규)만 payload 로 — 처리내용 원문은 보내지 않는다.
/// 서버 `tests/test_community_capture.py::ViolationLawPayloadTests` 와 같은 규칙(공용 벡터는 contracts/community-ingest).
void main() {
  test('report adapter carries the parsed law into the payload', () {
    final report = longFieldReport(status: '수용').copyWith(
      law: ' 도로교통법  제5조 ',
      processContent: '도로교통법 제5조 위반으로 범칙금을 부과하였습니다.',
    );
    final payload = buildPayload(
      buildReportAdapterInput(report, '자동차·교통위반 > 신호위반'),
    );
    expect(payload['violation_law'], '도로교통법 제5조');
    expect(payload.toString(), isNot(contains('범칙금을 부과')));
  });

  test('empty law becomes null', () {
    final payload = buildPayload(
      buildReportAdapterInput(longFieldReport(status: '수용'), '자동차·교통위반'),
    );
    expect(payload.containsKey('violation_law'), isTrue);
    expect(payload['violation_law'], isNull);
  });
}
