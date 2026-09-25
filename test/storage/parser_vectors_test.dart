// 파서 공통 기대값 (contracts/parser-vectors.json — 서버 tests/test_parser_vectors.py 와 같은 파일).
// 모바일 parseJsonToReport 결과를 DB 열 이름으로 옮겨 기대값과 비교한다. 적힌 키만 본다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/standalone_parser.dart';

Map<String, Object?> _asColumns(Map<String, dynamic> detail) {
  final r = parseJsonToReport(<String, dynamic>{}, detail);
  return {
    '신고번호': r.reportNumber,
    '신고명': r.name,
    '신고일': r.date,
    '상태': r.result,
    '만족도조사여부': r.pollStatus,
    '별점': r.rating,
    'entry_value': entryValueFromDetail(<String, dynamic>{}, detail),
    '처리상태': r.status,
    '종결여부': r.processingFinish,
    '처리기관': r.agency,
    '담당자': r.manager,
    '답변일': r.responseDate,
    '처리내용': r.processContent,
    '위반법규': r.law,
    '범칙금_과태료': r.fineInfo,
    '벌점': r.penaltyPoints,
    '차량번호': r.carNumber,
    '발생일자': r.occurrenceDate,
    '발생시각': r.occurrenceTime,
    '위반장소': r.location,
    '신고내용': r.reportContent,
    '첨부사진': r.attachedPhotos,
    '첨부파일': r.attachedFiles,
    '지도': r.mapImage,
    'raw_content': normalizeRawPayloadText(rawContentOf(detail)),
    '보완횟수': r.supplementCount,
    '보완_미응답': r.supplementOpen ? 'Y' : 'N',
    '보완_요청자': r.supplementRequester,
    '보완_요청_내용': r.supplementRequest,
    '보완_신고자_의견': r.supplementOpinion,
  };
}

void main() {
  final doc =
      jsonDecode(File('contracts/parser-vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  for (final c in (doc['cases'] as List).cast<Map<String, dynamic>>()) {
    test(c['name'], () {
      final got = _asColumns(c['detail'] as Map<String, dynamic>);
      final expected = c['expect'] as Map<String, dynamic>;
      for (final e in expected.entries) {
        expect(got[e.key], e.value, reason: '${c['name']} · ${e.key}');
      }
    });
  }
}
