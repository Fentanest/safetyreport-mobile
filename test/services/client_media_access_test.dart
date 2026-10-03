import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/client_media_access.dart';
import 'package:safetyreport/services/client_compatibility.dart';
import '../support/selfhost_client_fixture.dart';

void main() {
  setUp(resetSelfhostFixture);
  test(
    'government, CDN, scheme and port changes never receive server credentials',
    () async {
      var probes = 0;
      final client = MockClient((r) async {
        probes++;
        throw StateError('Must not request third-party');
      });
      for (final url in [
        'https://safetyreport.go.kr/photo.png',
        'https://cdn.fixture/video.mp4',
        'http://server.fixture/photo',
        'https://server.fixture:8443/photo',
        'https://server.fixture.evil.test/photo',
      ]) {
        expect(
          await ClientMediaAccess.headers(
            url,
            baseUrl: 'https://server.fixture',
            apiKey: 'private-fixture',
            client: client,
          ),
          isNull,
        );
      }
      expect(probes, 0);
    },
  );
  test(
    'self-host image and native video receive real product headers only after successful probe',
    () async {
      var probes = 0;
      final client = MockClient((r) async {
        probes++;
        expect(r.url.path, '/api/v1/server/version');
        return http.Response(jsonEncode(compatibleVersion), 200);
      });
      final headers = await ClientMediaAccess.headers(
        'https://server.fixture/media/video.mp4',
        baseUrl: 'https://server.fixture',
        apiKey: 'fixture',
        client: client,
      );
      expect(probes, 1);
      expect(headers, {
        'X-API-Key': 'fixture',
        'X-SafetyReport-Client': 'mobile',
        'X-SafetyReport-Version': '2.0.0+31',
        'X-SafetyReport-Protocol': '3',
      });
    },
  );
  test('old server cannot start an attachment request', () async {
    final client = MockClient(
      (r) async => http.Response('{"version":"2.9.0"}', 200),
    );
    await expectLater(
      ClientMediaAccess.headers(
        'https://server.fixture/photo.png',
        baseUrl: 'https://server.fixture',
        apiKey: 'fixture',
        client: client,
      ),
      throwsA(isA<ClientCompatibilityException>()),
    );
  });
}
