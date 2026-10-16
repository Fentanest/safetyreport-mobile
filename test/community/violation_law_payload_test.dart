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

  test('adapter picks the primary law like PC build_adapter_input; buildPayload only cleans', () {
    // 결함 1: 대표 법규 고르기는 어댑터 입력 단계(PC build_adapter_input 과 같은 호출 지점)에서 한다.
    final report = longFieldReport(status: '수용').copyWith(
      law: '도로교통법 제32조\n도로교통법 제33조',
    );
    final input = buildReportAdapterInput(report, '불법주정차신고');
    expect(input['violation_law'], '도로교통법 제32조');
    expect(buildPayload(input)['violation_law'], '도로교통법 제32조');
    // 계약 벡터(observations violation_law_cleaned_and_truncated): buildPayload 는 입력 문자열을 정리·60자 자르기만.
    final contractStyle = Map<String, Object?>.from(input)
      ..['violation_law'] = '  자동차관리법\n 제29조';
    expect(buildPayload(contractStyle)['violation_law'], '자동차관리법 제29조');
  });

  test('empty law becomes null', () {
    final payload = buildPayload(
      buildReportAdapterInput(longFieldReport(status: '수용'), '자동차·교통위반'),
    );
    expect(payload.containsKey('violation_law'), isTrue);
    expect(payload['violation_law'], isNull);
  });
}
