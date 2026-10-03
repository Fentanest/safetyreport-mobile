import '../support/selfhost_client_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/server_connection_service.dart';

void main() {
  setUp(resetSelfhostFixture);
  group('ServerConnectionService.checkVersion', () {
    test('accepts a configured v3 server before other API calls', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/server/version');
        expect(request.headers['X-API-Key'], 'secret');
        return http.Response(
          '{"version":"3.0.0.0","protocol_version":3,"supported_client_protocols":[3]}',
          200,
        );
      });
      final result = await ServerConnectionService.checkVersion(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );
      expect(result.isOk, isTrue);
    });

    test('rejects an old stored server version', () async {
      final client = MockClient(
        (_) async => http.Response('{"version":"2.5.3"}', 200),
      );
      final result = await ServerConnectionService.checkVersion(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );
      expect(result.status, ServerConnectionStatus.incompatibleServer);
    });

    test('fails closed when the version endpoint is unavailable', () async {
      final client = MockClient((_) async => http.Response('missing', 404));
      final result = await ServerConnectionService.checkVersion(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );
      expect(result.status, ServerConnectionStatus.incompatibleServer);
    });
  });

  group('ServerConnectionService.testConnection', () {
    test(
      'returns ok for valid summary response and normalizes base url',
      () async {
        final client = MockClient((request) async {
          expect(request.headers['X-API-Key'], 'secret');
          if (request.url.path == '/api/v1/summary') {
            return http.Response('{"data":{"total":7}}', 200);
          }
          expect(request.url.path, '/api/v1/server/version');
          return http.Response(
            '{"version":"3.0.0.0","protocol_version":3,"supported_client_protocols":[3]}',
            200,
          );
        });

        final result = await ServerConnectionService.testConnection(
          baseUrl: 'https://example.com/',
          apiKey: 'secret',
          client: client,
        );

        expect(result.isOk, isTrue);
        expect(result.normalizedUrl, 'https://example.com');
      },
    );

    test('rejects a pre-v3 PC server before requesting summary', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/server/version');
        return http.Response('{"version":"2.5.3"}', 200);
      });
      final result = await ServerConnectionService.testConnection(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );
      expect(result.status, ServerConnectionStatus.incompatibleServer);
      expect(result.message, contains('v3 이상'));
    });

    test('rejects an old server without a version endpoint', () async {
      final client = MockClient(
        (request) async => request.url.path.endsWith('/summary')
            ? http.Response('{"data":{"total":7}}', 200)
            : http.Response('missing', 404),
      );
      final result = await ServerConnectionService.testConnection(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );
      expect(result.status, ServerConnectionStatus.incompatibleServer);
    });

    test('accepts only recognizable v3 or newer versions', () {
      expect(ServerConnectionService.supportsServerVersion('3.0.0.0'), isTrue);
      expect(ServerConnectionService.supportsServerVersion('v4.1.0'), isTrue);
      expect(ServerConnectionService.supportsServerVersion('2.9.9'), isFalse);
      expect(ServerConnectionService.supportsServerVersion('unknown'), isFalse);
    });

    test('returns unauthorized for 401 response', () async {
      final client = MockClient((_) async => http.Response('denied', 401));

      final result = await ServerConnectionService.testConnection(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );

      expect(result.status, ServerConnectionStatus.unauthorized);
      expect(result.statusCode, 401);
    });

    test('returns httpError for non-401 http failures', () async {
      final client = MockClient((_) async => http.Response('oops', 503));

      final result = await ServerConnectionService.testConnection(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );

      expect(result.status, ServerConnectionStatus.httpError);
      expect(result.statusCode, 503);
    });

    test('returns networkError for malformed 200 response body', () async {
      final client = MockClient(
        (request) async => request.url.path.endsWith('/version')
            ? http.Response(
                '{"version":"3.0.0.0","protocol_version":3,"supported_client_protocols":[3]}',
                200,
              )
            : http.Response('<html>', 200),
      );

      final result = await ServerConnectionService.testConnection(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );

      expect(result.status, ServerConnectionStatus.networkError);
      expect(result.message, contains('서버 응답 파싱 실패'));
    });
  });

  group('ServerConnectionService.fetchVersionInfo', () {
    test('parses version payload', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.com/api/v1/server/version',
        );
        expect(request.headers['X-API-Key'], 'secret');
        return http.Response(
          '{"version":"1.2.3","latest_version":"1.2.4","up_to_date":false}',
          200,
        );
      });

      final info = await ServerConnectionService.fetchVersionInfo(
        baseUrl: 'https://example.com/',
        apiKey: 'secret',
        client: client,
      );

      expect(info.version, '1.2.3');
      expect(info.latestVersion, '1.2.4');
      expect(info.status, 'outdated');
    });

    test('returns empty info on non-200 response', () async {
      final client = MockClient((_) async => http.Response('missing', 404));

      final info = await ServerConnectionService.fetchVersionInfo(
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        client: client,
      );

      expect(info, same(ServerVersionInfo.empty));
      expect(info.hasVersion, isFalse);
    });
  });
}
