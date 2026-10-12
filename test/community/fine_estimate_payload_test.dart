// fine_estimate(observation-v5(fine_estimate 추가), fine-estimate-contract.md) payload 판정.
//
// 조건·판정 로직은 lib/services/fine_estimate.dart 를 그대로 호출한다(여기서 다시 구현하지
// 않음). 벡터는 PC 와 공유하는 test/fixtures/fine_estimate_vectors.json 을 그대로 쓴다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/report_adapter.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine_estimate;
import 'package:crypto/crypto.dart';

import '../support/ui_harness.dart';

/// fine_estimate_vectors.json 의 record(Korean 열 이름) → buildPayload 어댑터 입력.
/// 금액은 고정으로 '과태료'(미확인)를 줘 늘 적격으로 만든다 — 이 테스트의 목적은 gate 가 아니라
/// classify/estimate 결과가 payload 에 그대로 실리는지다.
Map<String, Object?> _inputFromVectorRecord(Map<String, dynamic> record) {
  return buildAdapterInput(
    status: '수용',
    fineInfo: '과태료',
    date: '2026-09-01',
    responseDate: '2026-09-10',
    agency: '서울특별시 중구청',
    manager: '홍길동',
    carNumber: record['차량번호']?.toString() ?? '',
    location: '서울특별시 중구 세종대로 110',
    penaltyPoints: '',
    entryValue: record['entry_value']?.toString() ?? '',
    ssnpcCd: record['ssnpc_cd']?.toString(),
    ssnpcType: record['ssnpc_type']?.toString(),
    violationLaw: record['위반법규']?.toString() ?? '',
    progressStatus: '수용',
    category: record['category']?.toString(),
    reportName: record['신고명']?.toString() ?? '',
    occurrenceTime: record['발생시각']?.toString() ?? '',
    photoFirstCapture: record['사진_첫촬영']?.toString(),
    photoLastCapture: record['사진_끝촬영']?.toString(),
  );
}

void main() {
  late Map<String, dynamic> vectors;
  setUpAll(() {
    final file = File('test/fixtures/fine_estimate_vectors.json');
    vectors = jsonDecode(file.readAsStringSync());
  });

  group('fine_estimate field (vectors shared with PC)', () {
    test('rule_version matches fine_estimate.ruleVersion', () {
      expect(fine_estimate.ruleVersion, equals(vectors['rule_version']));
    });

    test('필드 생김: classify/estimate 가 규칙을 찾으면 won/rule/rule_version 그대로', () {
      final cases = vectors['cases'] as List;
      for (final raw in cases) {
        final testCase = raw as Map<String, dynamic>;
        final record = testCase['record'] as Map<String, dynamic>;
        final expectedAmount = testCase['amount'];
        final expectedRule = testCase['rule'];
        if (expectedAmount == null) continue; // 안 생김 쪽은 다음 테스트에서.
        final payload = buildPayload(_inputFromVectorRecord(record));
        expect(
          payload['fine_estimate'],
          equals({
            'won': expectedAmount,
            'rule': expectedRule,
            'rule_version': vectors['rule_version'],
          }),
          reason: 'case: ${testCase['name']}',
        );
      }
    });

    test('필드 안 생김: 규칙이 없으면(classify null) 키 자체가 없다(null 아님)', () {
      final cases = vectors['cases'] as List;
      var checked = 0;
      for (final raw in cases) {
        final testCase = raw as Map<String, dynamic>;
        final record = testCase['record'] as Map<String, dynamic>;
        if (testCase['amount'] != null) continue;
        checked++;
        final payload = buildPayload(_inputFromVectorRecord(record));
        expect(
          payload.containsKey('fine_estimate'),
          isFalse,
          reason: 'case: ${testCase['name']}',
        );
      }
      expect(checked, greaterThan(0));
    });
  });

  group('필드 안 생김: 확정 금액·대상 아닌 신고는 payload·해시 불변', () {
    test('과태료 금액이 확정이면(예: 40,000원) 같은 규칙이 있어도 넣지 않는다', () {
      final record = {
        'category': 'parking',
        'entry_value': '불법주정차신고-장애인 전용구역 불법주차',
        '차량번호': '12가3456',
      };
      // 규칙이 실제로 매치하는지(아니면 이 테스트가 공허하게 통과) 먼저 확인.
      expect(fine_estimate.classify(record), equals('disabled_parking'));

      final unknownAmount = buildPayload(
        buildAdapterInput(
          status: '수용',
          fineInfo: '과태료',
          date: '2026-09-01',
          responseDate: '2026-09-10',
          agency: 'A',
          manager: 'B',
          carNumber: '12가3456',
          location: 'L',
          penaltyPoints: '',
          entryValue: '불법주정차신고-장애인 전용구역 불법주차',
          progressStatus: '수용',
          category: 'parking',
        ),
      );
      expect(unknownAmount['fine_estimate'], isNotNull);

      final confirmedAmount = buildPayload(
        buildAdapterInput(
          status: '수용',
          fineInfo: '과태료: 100,000원',
          date: '2026-09-01',
          responseDate: '2026-09-10',
          agency: 'A',
          manager: 'B',
          carNumber: '12가3456',
          location: 'L',
          penaltyPoints: '',
          entryValue: '불법주정차신고-장애인 전용구역 불법주차',
          progressStatus: '수용',
          category: 'parking',
        ),
      );
      expect(confirmedAmount.containsKey('fine_estimate'), isFalse);
    });

    test('대상 아닌 신고(과태료 아님)의 payload_sha256 은 그대로', () {
      final input = buildAdapterInput(
        status: '수용',
        fineInfo: '경고',
        date: '2026-09-01',
        responseDate: '2026-09-10',
        agency: 'A',
        manager: 'B',
        carNumber: '12가3456',
        location: 'L',
        penaltyPoints: '',
        entryValue: '불법주정차신고-장애인 전용구역 불법주차',
        progressStatus: '수용',
      );
      final before = buildPayload({...input, 'category': null});
      final after = buildPayload({...input, 'category': 'parking'});
      // category 는 fine_estimate 계산에만 쓰이고(resolved.category 가 이미 entry_value 로 'parking'
      // 을 알아내므로) payload 의 공개 'category' 필드·해시에는 영향이 없어야 한다.
      expect(before.containsKey('fine_estimate'), isFalse);
      expect(after.containsKey('fine_estimate'), isFalse);
      expect(
        sha256.convert(utf8.encode(canonicalJson(before))).toString(),
        equals(sha256.convert(utf8.encode(canonicalJson(after))).toString()),
      );
    });
  });

  group('buildReportAdapterInput 로 category·사진 촬영 시각·신고명·발생시각이 전달된다', () {
    test('Report → fine_estimate 입력까지 끝까지 연결', () {
      final report = longFieldReport(status: '수용').copyWith(
        name: '밤샘주차 신고',
        fineInfo: '과태료',
        carNumber: '서울85바1234',
        occurrenceTime: '01:00',
      );
      final payload = buildPayload(
        buildReportAdapterInput(
          report,
          '불법주정차신고-기타 불법주정차',
          category: 'parking',
          photoFirstCapture: '2026-09-22 01:00:00',
          photoLastCapture: '2026-09-22 02:30:00',
        ),
      );
      expect(
        payload['fine_estimate'],
        equals({
          'won': 50000,
          'rule': 'overnight_truck',
          'rule_version': fine_estimate.ruleVersion,
        }),
      );
    });

    test('사진 촬영 시각을 안 주면(아직 모름) 밤샘주차 대신 일반 주정차로', () {
      final report = longFieldReport(status: '수용').copyWith(
        fineInfo: '과태료',
        carNumber: '서울85바1234',
      );
      final payload = buildPayload(
        buildReportAdapterInput(
          report,
          '불법주정차신고-기타 불법주정차',
          category: 'parking',
        ),
      );
      expect(
        payload['fine_estimate'],
        equals({
          'won': 40000,
          'rule': 'parking',
          'rule_version': fine_estimate.ruleVersion,
        }),
      );
    });
  });
}
