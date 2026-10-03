import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/client_compatibility.dart';
import 'package:safetyreport/services/server_contract.dart';

const compatibleVersion = {
  'version': '3.0.0.0-dev',
  'protocol_version': 3,
  'supported_client_protocols': [3],
};
void resetSelfhostFixture() {
  ServerContract.productVersion = '2.0.0+31';
  ClientCompatibility.invalidate();
}

MockClient selfhostMockClient(
  Future<http.Response> Function(http.Request) handler,
) => MockClient((request) async {
  if (request.url.path == ServerContract.serverVersionPath) {
    return http.Response(jsonEncode(compatibleVersion), 200);
  }
  return handler(request);
});
