// 상세 원본 정규 직렬화 계약 벡터(contracts/raw-detail-vectors.json — 서버 tests/test_raw_detail_vectors.py 와 같은 파일).
// 서버·모바일이 같은 입력에서 같은 정규 바이트와 sha 를 내야 한다(Python·Dart 바이트 동일).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:safetyreport/services/standalone_parser.dart';

Map<String, dynamic> _deepMap(Map<String, dynamic> m) => {
  for (final e in m.entries)
    e.key: e.value is Map
        ? _deepMap(Map<String, dynamic>.from(e.value))
        : e.value is List
        ? [
            for (final v in e.value as List)
              v is Map ? _deepMap(Map<String, dynamic>.from(v)) : v,
          ]
        : e.value,
};

void main() {
  final vectors =
      jsonDecode(
            File(
              'contracts/raw-detail-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cases = (vectors['cases'] as List).cast<Map<String, dynamic>>();

  test('reporter keys match the contract in order', () {
    expect(
      rawDetailReporterKeys,
      (vectors['reporter_keys'] as List).cast<String>(),
    );
  });

  for (final c in cases) {
    test('canonical bytes and sha match the contract: ${c['name']}', () {
      final input = _deepMap(
        Map<String, dynamic>.from(c['input'] as Map<String, dynamic>),
      );
      final before = jsonEncode(input);
      final prepared = prepareRawDetail(input);
      // 입력은 바뀌지 않는다.
      expect(jsonEncode(input), before);
      expect(utf8.decode(prepared.canonical), c['canonical']);
      expect(prepared.sha256, c['sha256']);
      expect(prepared.canonical.length, c['size']);
      // 압축→해제→대조 왕복.
      final blob = compressRawDetail(prepared.canonical);
      expect(
        decompressAndVerifyRawDetail(blob, prepared.sha256),
        prepared.canonical,
      );
    });
  }

  test('reporter keys are removed only inside result', () {
    final withKeys = _deepMap(
      Map<String, dynamic>.from(
        (cases.firstWhere((c) => c['name'] == 'basic_with_reporter_keys')['input']
                as Map)
            .cast<String, dynamic>(),
      ),
    );
    final prepared = prepareRawDetail(withKeys);
    final result = prepared.sanitized['result'] as Map<String, dynamic>;
    for (final k in rawDetailReporterKeys) {
      expect(result.containsKey(k), isFalse, reason: k);
    }
    // 공무원 담당자·본문·첨부는 그대로 둔다.
    final answers = (result['answers'] as List).single as Map<String, dynamic>;
    expect(answers['C_MANAGE_MAN'], '김담당');
    expect(answers['C_MANAGE_MAN_PHONE'], '02-123-4567');
    expect(answers['C_MANAGE_MAN_EMAIL'], 'x@y.go.kr');
    expect(result['VHRNO'], '12가3456');
    expect(answers['C_MANAGE_CONTENTS'], contains('과태료 40,000원'));

    // envelope 바깥·result 중첩 안의 같은 이름은 건드리지 않는다.
    final nested = _deepMap(
      Map<String, dynamic>.from(
        (cases.firstWhere(
                  (c) => c['name'] == 'reporter_keys_only_in_result',
                )['input']
                as Map)
            .cast<String, dynamic>(),
      ),
    );
    final sanitized = prepareRawDetail(nested).sanitized;
    expect(sanitized['C_NAME'], 'envelope level kept');
    expect(
      ((sanitized['result'] as Map)['nested'] as Map)['C_EMAIL'],
      'nested kept',
    );

    // result 가 객체가 아니면 아무 것도 지우지 않는다.
    final notObject = _deepMap(
      Map<String, dynamic>.from(
        (cases.firstWhere((c) => c['name'] == 'result_not_object')['input']
                as Map)
            .cast<String, dynamic>(),
      ),
    );
    final kept = prepareRawDetail(notObject).sanitized;
    expect(
      (((kept['result'] as List).single) as Map)['C_NAME'],
      'list item kept',
    );
  });

  test('tampered blob or sha is refused as corrupt', () {
    final input = _deepMap(
      Map<String, dynamic>.from(
        (cases.first['input'] as Map).cast<String, dynamic>(),
      ),
    );
    final prepared = prepareRawDetail(input);
    final blob = compressRawDetail(prepared.canonical);
    expect(
      () => decompressAndVerifyRawDetail(blob, '0' * 64),
      throwsStateError,
    );
    expect(
      () => decompressAndVerifyRawDetail(
        Uint8List.fromList(utf8.encode('not-zlib')),
        prepared.sha256,
      ),
      throwsStateError,
    );
  });

  test('parser input is result: reporter keys do not change the parse', () {
    // 신고자 키 5개 포함·제외 result 를 파서에 줘도 결과가 같다(명세 1-3).
    final withKeys = <String, dynamic>{
      'C_NO': '90000001',
      'C_NAME': '홍길동',
      'C_EMAIL': 'a@b.c',
      'C_PHONE': '01012345678',
      'C_PHONE2': '010-1234-5678',
      'C_ID': 'fixtureid1',
      'C_NOW': 10,
      'VHRNO': '12가3456',
      'RN_ADRES': '서울 강서구 1',
      'C_A_CONTENTS': '차량번호 : 12가3456\n본문',
    };
    final withoutKeys = Map<String, dynamic>.from(withKeys)
      ..removeWhere((k, _) => rawDetailReporterKeys.contains(k));
    final a = parseJsonToReport(const {}, withKeys);
    final b = parseJsonToReport(const {}, withoutKeys);
    expect(a.reportNumber, b.reportNumber);
    expect(a.status, b.status);
    expect(a.carNumber, b.carNumber);
    expect(a.law, b.law);
    expect(a.manager, b.manager);
    expect(a.location, b.location);
    expect(a.reportContent, b.reportContent);
    expect(a.fineInfo, b.fineInfo);
    expect(
      entryValueFromDetail(const {}, withKeys),
      entryValueFromDetail(const {}, withoutKeys),
    );
  });

  test('fetched_at is UTC ISO8601 with milliseconds and Z', () {
    expect(
      formatRawFetchedAt(DateTime.utc(2026, 10, 17, 12, 34, 56, 789)),
      '2026-10-17T12:34:56.789Z',
    );
    expect(
      formatRawFetchedAt(DateTime(2026, 10, 17, 21, 34, 56, 789)),
      '2026-10-17T12:34:56.789Z',
      reason: 'KST 입력도 UTC 로 바꾼다',
    );
  });

  test('raw detail file is indented JSON without reporter keys (tmp → rename)', () async {
    final dir = await Directory.systemTemp.createTemp('sr_raw_detail_file_');
    try {
      final input = _deepMap(
        Map<String, dynamic>.from(
          (cases.firstWhere(
                    (c) => c['name'] == 'basic_with_reporter_keys',
                  )['input']
                  as Map)
              .cast<String, dynamic>(),
        ),
      );
      final sanitized = prepareRawDetail(input).sanitized;
      await writeRawDetailFile('90000001', sanitized, dir: dir);
      final file = File('${dir.path}/90000001.json');
      expect(file.existsSync(), isTrue);
      expect(File('${dir.path}/90000001.json.tmp').existsSync(), isFalse);
      final text = file.readAsStringSync(encoding: utf8);
      expect(text, startsWith('{\n  "result"'));
      final back =
          jsonDecode(text) as Map<String, dynamic>;
      expect(
        (back['result'] as Map).containsKey('C_NAME'),
        isFalse,
      );
      expect(
        ((back['result'] as Map)['answers'] as List).single['C_MANAGE_MAN'],
        '김담당',
      );
      // 비ASCII 그대로(이스케이프 없음). 신고자 이름은 빠져 있다.
      expect(text, contains('김담당'));
      expect(text.contains('홍길동'), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('unsafe report id does not escape raw_details', () async {
    // 서버 is_safe_report_id·raw_file_path 와 같은 규칙: 영숫자·_·- 만, 64자 이내,
    // 정규화 최종 경로가 raw_details 아래일 때만 쓴다. 위반은 쓰지 않고 진단만.
    expect(isSafeReportId('90000001'), isTrue);
    expect(isSafeReportId('r-1_A'), isTrue);
    for (final bad in [
      '../outside',
      '..',
      '',
      'a/b',
      r'a\b',
      'a.json',
      'a b',
      '한글',
      'a' * 65,
    ]) {
      expect(isSafeReportId(bad), isFalse, reason: bad);
    }
    final dir = await Directory.systemTemp.createTemp('sr_raw_detail_escape_');
    try {
      final rawDir = Directory('${dir.path}/raw_details')..createSync();
      expect(rawFilePath('../outside', rawDir), isNull);
      expect(rawFilePath('', rawDir), isNull);
      expect(
        rawFilePath('90000001', rawDir),
        '${rawDir.absolute.path}/90000001.json',
      );
      final sanitized = <String, dynamic>{
        'result': {'C_NO': 'x'},
      };
      expect(
        await writeRawDetailFile('../outside', sanitized, dir: rawDir),
        isNull,
      );
      expect(
        File('${dir.path}/outside.json').existsSync(),
        isFalse,
        reason: 'raw_details 밖(mysafetyreport/outside.json)에 쓰면 안 된다',
      );
      expect(rawDir.listSync(), isEmpty);
      expect(
        File('${rawDir.path}/../outside.json.tmp').existsSync(),
        isFalse,
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
