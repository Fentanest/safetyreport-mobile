import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/client_compatibility.dart';
import 'package:safetyreport/services/server_contract.dart';

const compatibleVersion = {
  'version': '3.0.0.0-dev',
  'protocol_version': 3,
  'supported_client_protocols': [3],
  // 2026-10-11(Astra #5): 신서버는 5분류를 보낸다. 이 값이 없으면 ReportProvider 가
  // 구서버로 보고 안전신고·생활불편 조회를 보내지 않는다 — 이 fixture 를 쓰는 기존 테스트가
  // 그 경로를 타지 않도록 기본값을 신서버로 둔다.
  'report_taxonomy': 5,
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
