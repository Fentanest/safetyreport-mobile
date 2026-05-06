import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/server_connection_service.dart';

void main() {
  group('ServerConnectionService.testConnection', () {
    test(
      'returns ok for valid summary response and normalizes base url',
      () async {
        final client = MockClient((request) async {
          expect(request.url.toString(), 'https://example.com/api/v1/summary');
          expect(request.headers['X-API-Key'], 'secret');
          return http.Response('{"data":{"total":7}}', 200);
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
      final client = MockClient((_) async => http.Response('<html>', 200));

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
