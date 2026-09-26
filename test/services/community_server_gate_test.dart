// Client 서버 게이트·초기화 링크 — 가짜 HTTP, 네트워크 없음.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
import 'package:safetyreport/services/server_contract.dart';

void main() {
  test('server contract paths exist', () {
    expect(ServerContract.communityGatePath, '/api/v1/community/gate');
    expect(ServerContract.communityRebuildPath, '/api/v1/community/rebuild');
    expect(ServerContract.communityRebuildStartPath, '/api/v1/community/rebuild/start');
    expect(ServerContract.communityRebuildResumePath, '/api/v1/community/rebuild/resume');
    expect(ServerContract.communityUserTokenHeader, 'X-Community-User-Token');
  });

  test('403 COMMUNITY_ONBOARDING_REQUIRED is a branch signal, not a crash', () async {
    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({'code': 'COMMUNITY_ONBOARDING_REQUIRED', 'message': 'onboard first'}),
        403,
      ),
    );
    final res = await CommunityServerLinkService.fetchCommunityGate(
      baseUrl: 'https://srv.test',
      apiKey: 'k',
      client: mock,
    );
    expect(res.isOk, isFalse);
    expect(res.needsOnboarding, isTrue);
    expect(res.needsRebuild, isFalse);
  });

  test('409 COMMUNITY_REBUILD_REQUIRED surfaces for rebuild start', () async {
    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({'code': 'COMMUNITY_REBUILD_REQUIRED', 'message': 'rebuild first'}),
        409,
      ),
    );
    final res = await CommunityServerLinkService.startCommunityRebuild(
      baseUrl: 'https://srv.test',
      apiKey: 'k',
      userToken: 'tok',
      client: mock,
    );
    expect(res.isOk, isFalse);
    expect(res.needsRebuild, isTrue);
  });

  test('start posts user token header; gate fingerprints comparable', () async {
    late http.Request seen;
    final mock = MockClient((req) async {
      seen = req;
      return http.Response(
        jsonEncode({
          'data': {
            'account_fingerprint': 'srv-fp',
            'initialized': false,
            'state': 'required',
          },
        }),
        200,
      );
    });
    final res = await CommunityServerLinkService.startCommunityRebuild(
      baseUrl: 'https://srv.test',
      apiKey: 'k',
      userToken: 'phone-token',
      client: mock,
    );
    expect(res.isOk, isTrue);
    expect(seen.headers['X-Community-User-Token'], 'phone-token');
    expect(res.data?['account_fingerprint'], 'srv-fp');
  });
}
