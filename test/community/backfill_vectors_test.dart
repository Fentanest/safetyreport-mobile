// 재전송·사진 보충과 일반 캡처의 추정 판정 공통 사례(test/fixtures/community_backfill_vectors.json).
//
// PC tests/test_community_backfill_vectors.py 가 바이트 동일한 같은 파일을 읽어 같은 결과를 확인한다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/fine_estimate_resend.dart';
import 'package:safetyreport/community/capture/observation_rules.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine_estimate;

final Map<String, dynamic> _vectors =
    jsonDecode(
          File(
            'test/fixtures/community_backfill_vectors.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, Object?> _row(Map<String, dynamic> testCase, {String? fine}) => {
  ...(_vectors['base_personal'] as Map<String, dynamic>),
  ...(testCase['personal'] as Map<String, dynamic>),
  '범칙금_과태료': ?fine,
};

/// 일반 캡처의 어댑터 입력(SyncEngine → buildReportAdapterInput 과 같은 buildAdapterInput).
Map<String, Object?> _captureInput(Map<String, Object?> row) =>
    buildAdapterInput(
      status: row['처리상태'] as String,
      reportNumber: row['신고번호'] as String?,
      fineInfo: row['범칙금_과태료'] as String,
      date: row['신고일'] as String,
      responseDate: row['답변일'] as String,
      agency: row['처리기관'] as String,
      manager: row['담당자'] as String,
      carNumber: row['차량번호'] as String,
      location: row['위반장소'] as String,
      penaltyPoints: row['벌점'] as String,
      entryValue: row['entry_value'] as String,
      ssnpcCd: row['ssnpc_cd'] as String?,
      ssnpcType: row['ssnpc_type'] as String?,
      violationLaw: row['위반법규'] as String,
      progressStatus: row['처리상태'] as String,
      reportName: row['신고명'] as String,
      occurrenceTime: row['발생시각'] as String,
      photoFirstCapture: row['사진_첫촬영'] as String?,
      photoLastCapture: row['사진_끝촬영'] as String?,
    );

Map<String, Object?> _journalPayload(Map<String, dynamic> testCase) {
  final payload = buildPayload(
    _captureInput(_row(testCase, fine: testCase['journal_raw'] as String)),
  );
  final override = testCase['journal_override'] as Map<String, dynamic>;
  if (override.containsKey('confirmed_won')) {
    payload['amount'] = {
      ...(payload['amount'] as Map<String, Object?>),
      'confirmed_won': override['confirmed_won'],
    };
  }
  if (override.containsKey('fine_estimate')) {
    payload.remove('fine_estimate');
    if (override['fine_estimate'] != null) {
      payload['fine_estimate'] = override['fine_estimate'];
    }
  }
  return payload;
}

void main() {
  test('rule_version matches', () {
    expect(_vectors['rule_version'], fine_estimate.ruleVersion);
  });

  for (final raw in _vectors['cases'] as List) {
    final testCase = raw as Map<String, dynamic>;
    test('${testCase['name']}', () {
      final row = _row(testCase);
      final expected = testCase['expected'] as Map<String, dynamic>;
      final captured = buildPayload(_captureInput(row));
      expect({
        'confirmed_won': (captured['amount'] as Map)['confirmed_won'],
        'disposition': captured['disposition'],
        'violation_law': captured['violation_law'],
        'fine_estimate': captured['fine_estimate'],
      }, expected['capture']);

      final journal = _journalPayload(testCase);
      final backfilled = refreshFineEstimate(
        journal,
        adapterInputFromResendRow(row),
      );
      expect(backfilled['fine_estimate'], expected['backfill_fine_estimate']);
      // 추정 외 필드는 journal 그대로(amount 포함 — 확정 금액은 다음 실시간 수집이 갱신).
      final rest = Map<String, Object?>.from(backfilled)
        ..remove('fine_estimate');
      expect(rest, Map<String, Object?>.from(journal)..remove('fine_estimate'));
      // 한 번 더 보충해도 같다(멱등).
      expect(
        refreshFineEstimate(backfilled, adapterInputFromResendRow(row)),
        backfilled,
      );
    });
  }
}
