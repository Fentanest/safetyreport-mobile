import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/client_compatibility.dart';
import 'package:safetyreport/services/server_connection_service.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:safetyreport/services/api_service.dart';
import '../support/selfhost_client_fixture.dart';

void main() {
  setUp(resetSelfhostFixture);
  final vectors =
      jsonDecode(
            File('contracts/selfhost-compat/vectors.json').readAsStringSync(),
          )
          as Map;
  test('canonical server product vectors match the client major gate', () {
    for (final v in vectors['cases'] as List) {
      expect(
        ServerConnectionService.supportsServerVersion(v['server']),
        v['code'] != 'SERVER_UPGRADE_REQUIRED',
        reason: v['name'],
      );
    }
    expect(
      ServerContract.apiHeaders('k')['X-SafetyReport-Version'],
      '2.0.0+31',
    );
    expect(
      ServerContract.wsClientUri(
        'https://example.test',
        'secret',
        '/crawl/ws/logs',
      ).queryParameters,
      {
        'api_key': 'secret',
        'client_type': 'mobile',
        'client_version': '2.0.0+31',
        'client_protocol': '3',
      },
    );
  });
  for (final body in [
    {'version': '3.0.0.0'},
    {
      'version': '3.0.0.0',
      'protocol_version': 2,
      'supported_client_protocols': [3],
    },
    {
      'version': '3.0.0.0',
      'protocol_version': 3,
      'supported_client_protocols': [2],
    },
    {
      'version': '3.0.0.0',
      'protocol_version': '3',
      'supported_client_protocols': [3],
    },
  ]) {
    test('missing/unsupported metadata fails closed: $body', () async {
      final result = await ServerConnectionService.checkVersion(
        baseUrl: 'https://fixture.test',
        apiKey: 'k',
        client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
      );
      expect(result.status, ServerConnectionStatus.incompatibleServer);
    });
  }
  test(
    'API and DB download never bypass compatibility; failures do not retry or touch files',
    () async {
      final requests = <String>[];
      final mock = MockClient((r) async {
        requests.add(r.url.path);
        expect(r.headers['X-SafetyReport-Protocol'], '3');
        expect(r.headers['X-SafetyReport-Version'], '2.0.0+31');
        return http.Response(jsonEncode({'version': '2.9.0'}), 200);
      });
      final api = ApiService(baseUrl: 'https://fixture.test', apiKey: 'k');
      await http.runWithClient(() async {
        await expectLater(
          api.getSummary(),
          throwsA(isA<ClientCompatibilityException>()),
        );
        await expectLater(
          api.getStats(),
          throwsA(isA<ClientCompatibilityException>()),
        );
        final dir = Directory.systemTemp.createTempSync();
        try {
          await expectLater(
            api.downloadDbToFile('${dir.path}/backup.db', client: mock),
            throwsA(isA<ClientCompatibilityException>()),
          );
          expect(dir.listSync(), isEmpty);
        } finally {
          dir.deleteSync(recursive: true);
        }
      }, () => mock);
      expect(requests, ['/api/v1/server/version']);
    },
  );
  test('parallel probe and late previous-account response', () async {
    final response = Completer<http.Response>();
    var probes = 0;
    final mock = MockClient((r) {
      probes++;
      return response.future;
    });
    final a = ClientCompatibility.ensure(
      'https://shared.test',
      'a',
      client: mock,
    );
    final b = ClientCompatibility.ensure(
      'https://shared.test',
      'a',
      client: mock,
    );
    response.complete(http.Response(jsonEncode(compatibleVersion), 200));
    await Future.wait([a, b]);
    expect(probes, 1);
    ClientCompatibility.invalidate();
    final late = Completer<http.Response>();
    final old = ClientCompatibility.ensure(
      'https://shared.test',
      'old',
      client: MockClient((_) => late.future),
    );
    final assertion = expectLater(old, throwsStateError);
    await ClientCompatibility.ensure(
      'https://shared.test',
      'new',
      client: selfhostMockClient((_) async => http.Response('', 200)),
    );
    late.complete(http.Response(jsonEncode(compatibleVersion), 200));
    await assertion;
    expect(ClientCompatibility.failure.value, isNull);
  });
  test(
    'same address/new key requires fresh probe; stale probes cannot authorize',
    () async {
      var probes = 0;
      final mock = MockClient((r) async {
        probes++;
        return http.Response(jsonEncode(compatibleVersion), 200);
      });
      await ClientCompatibility.ensure('https://a.test', 'k1', client: mock);
      await ClientCompatibility.ensure('https://a.test', 'k1', client: mock);
      await ClientCompatibility.ensure('https://a.test', 'k2', client: mock);
      expect(probes, 2);
    },
  );
  test(
    '409 identifies which product must be upgraded and blocks subsequent requests',
    () async {
      var probes = 0, summaries = 0;
      await http.runWithClient(
        () async {
          final api = ApiService(baseUrl: 'https://fixture.test', apiKey: 'k');
          await expectLater(
            api.getSummary(),
            throwsA(
              isA<ClientCompatibilityException>().having(
                (e) => e.toString(),
                'message',
                contains('모바일 앱'),
              ),
            ),
          );
          await expectLater(
            api.getSummary(),
            throwsA(isA<ClientCompatibilityException>()),
          );
        },
        () => MockClient((r) async {
          if (r.url.path.endsWith('/version')) {
            probes++;
            return http.Response(jsonEncode(compatibleVersion), 200);
          }
          summaries++;
          return http.Response('{"code":"CLIENT_UPGRADE_REQUIRED"}', 409);
        }),
      );
      expect((probes, summaries), (1, 1));
      expect(
        ServerConnectionService.upgradeMessage(
          '{"code":"SERVER_UPGRADE_REQUIRED"}',
        ),
        contains('PC 서버'),
      );
    },
  );
}
