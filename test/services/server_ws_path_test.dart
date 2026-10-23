import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/server_contract.dart';

void main() {
  test('WebSocket preserves the same deployment path as REST', () {
    for (final base in [
      'http://localhost:8080',
      'https://localhost/safetyreport',
      ' https://localhost/safetyreport/nested/// ',
      'https://localhost/%ED%95%9C%EA%B8%80/a%2Fb',
      'https://[::1]:8443/safetyreport',
    ]) {
      final api = ServerContract.apiUri(base, ServerContract.wsEventsPath);
      final events = ServerContract.wsEventsUri(base, 'local-path-check');
      expect(events.pathSegments, api.pathSegments);
      expect(events.scheme, api.scheme == 'https' ? 'wss' : 'ws');
      expect(events.host, api.host);
      expect(events.hasPort, api.hasPort);
      if (api.hasPort) expect(events.port, api.port);
      expect(events.queryParameters['api_key'], 'local-path-check');
      expect(
        events.queryParameters['taxonomy'],
        ServerContract.taxonomyVersion,
      );
      final logs = ServerContract.wsClientUri(
        base,
        'local-path-check',
        '/crawl/ws/logs',
      );
      expect(
        logs.pathSegments,
        ServerContract.apiUri(base, '/crawl/ws/logs').pathSegments,
      );
    }
  });
}
