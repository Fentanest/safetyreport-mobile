// 서버 대기 큐에서 처리하지 못한 번호 표시·요청 거부 이유 전달(서버 감사 R7-03·R8-02).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/services/crawl_unresolved.dart';

void main() {
  test('reads unresolved numbers from /crawl/status and tolerates old servers', () {
    final list = CrawlUnresolved.fromStatus({
      'status': 'success',
      'running': false,
      'unresolved': [
        {'number': 'SPP-2609', 'reason': 'ambiguous', 'at': '2026-09-26T00:00:00+00:00'},
        {'number': 'SPP-0000-1', 'reason': 'not_found'},
        {'reason': 'broken'},
      ],
    });
    expect(list.map((u) => u.number), ['SPP-2609', 'SPP-0000-1']);
    expect(list.first.message, contains('정확한 신고번호'));
    expect(list.last.message, contains('찾지 못했습니다'));
    expect(CrawlUnresolved.fromStatus({'status': 'success', 'running': true}), isEmpty, reason: '구서버');
  });

  test('enqueueCrawl surfaces the server reason for a refused number', () async {
    final api = ApiService(baseUrl: 'http://server.test', apiKey: 'k');
    await http.runWithClient(() async {
      await expectLater(
        api.enqueueCrawl('SPP-2609'),
        throwsA(predicate((e) => e.toString().contains('정확한 신고번호로 요청하세요'))),
      );
    }, () => MockClient((req) async => http.Response.bytes(
          utf8.encode(jsonEncode({'detail': '여러 신고에 걸리는 번호라 어느 신고인지 정할 수 없습니다. 정확한 신고번호로 요청하세요: SPP-2609'})),
          400,
          headers: {'content-type': 'application/json'},
        )));
  });
}
