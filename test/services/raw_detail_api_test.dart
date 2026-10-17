import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/services/server_contract.dart';

import '../support/selfhost_client_fixture.dart';

void main() {
  setUp(resetSelfhostFixture);

  test('rawDetailPath escapes the id into the reports route', () {
    expect(
      ServerContract.rawDetailPath('90000001'),
      '/api/v1/reports/90000001/raw-detail',
    );
    // ID 이탈 시도는 경로가 깨지지 않게 이스케이프된다(서버는 404로 답한다).
    expect(ServerContract.rawDetailPath('../outside'), contains('%2F'));
    expect(
      ServerContract.rawDetailPath('../outside'),
      '/api/v1/reports/..%2Foutside/raw-detail',
    );
  });

  test('supportsRawDetail needs the capability and version 1', () {
    expect(
      ServerContract.supportsRawDetail({
        'capabilities': ['raw_detail_v1'],
        'raw_detail_version': 1,
      }),
      isTrue,
    );
    expect(ServerContract.supportsRawDetail({'capabilities': []}), isFalse);
    expect(
      ServerContract.supportsRawDetail({
        'capabilities': ['raw_detail_v1'],
        'raw_detail_version': 2,
      }),
      isFalse,
    );
    expect(
      ServerContract.supportsRawDetail({
        'capabilities': ['raw_detail_v1'],
      }),
      isFalse,
    );
  });

  Future<RawDetailPayload> fetch(
    String reportId,
    Future<http.Response> Function(http.Request) handler,
  ) => http.runWithClient(
    () => ApiService(
      baseUrl: 'https://fixture.test',
      apiKey: 'fixture',
    ).fetchRawDetail(reportId),
    () => selfhostMockClient(handler),
  );

  test('fetchRawDetail maps 200 to the stored payload', () async {
    const stored = {
      'result': {'C_NO': '90000001', 'C_A_CONTENTS': '본문'},
    };
    await http.runWithClient(
      () async {
        final payload = await ApiService(
          baseUrl: 'https://fixture.test',
          apiKey: 'fixture',
        ).fetchRawDetail('90000001');
        expect(payload.id, '90000001');
        expect(payload.fetchedAt, '2026-10-17T12:34:56.789Z');
        expect(payload.source, 'crawl');
        expect(payload.sha256, 'abc');
        expect(payload.json, stored);
      },
      () => selfhostMockClient((r) async {
        expect(r.url.path, '/api/v1/reports/90000001/raw-detail');
        expect(r.headers['X-SafetyReport-Protocol'], '3');
        return http.Response(
          jsonEncode({
            'id': '90000001',
            'fetched_at': '2026-10-17T12:34:56.789Z',
            'source': 'crawl',
            'raw_sha256': 'abc',
            'json': stored,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });

  test('fetchRawDetail throws missing on 404', () async {
    await expectLater(
      fetch(
        'no-such-id',
        (r) async => http.Response(
          jsonEncode({'error': 'raw_detail_missing'}),
          404,
        ),
      ),
      throwsA(isA<RawDetailMissing>()),
    );
  });

  test('fetchRawDetail throws corrupt on 409', () async {
    await expectLater(
      fetch(
        '90000001',
        (r) async =>
            http.Response(jsonEncode({'error': 'raw_detail_corrupt'}), 409),
      ),
      throwsA(isA<RawDetailCorrupt>()),
    );
  });

  test('fetchRawDetail throws corrupt when json is not an object', () async {
    await expectLater(
      fetch(
        '90000001',
        (r) async => http.Response(
          jsonEncode({'id': '90000001', 'json': [1, 2]}),
          200,
        ),
      ),
      throwsA(isA<RawDetailCorrupt>()),
    );
  });

  test('fetchRawDetail rethrows other statuses for retry', () async {
    await expectLater(
      fetch('90000001', (r) async => http.Response('oops', 500)),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('500'),
        ),
      ),
    );
  });
}
