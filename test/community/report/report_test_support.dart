import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/report/report_env.dart';
import 'package:safetyreport/services/community_auth_config.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const testConnectionId = '11111111-1111-4111-8111-111111111111';

class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;
}

/// 가짜 HTTP 와 고정 시계로 [ReportEnv] 를 맞춘다. [handler] 가 응답을 만든다.
class FakeNet {
  FakeNet(this.handler);
  http.Response Function(http.Request request) handler;
  final List<RecordedRequest> requests = [];
  DateTime clock = DateTime.utc(2026, 10, 22, 3, 0, 0);

  void install({String token = 'tok-test', String version = '2.5.1'}) {
    ReportEnv.configOverride = CommunityAuthConfig.validate(
      url: 'https://example.supabase.co',
      key: 'sb_publishable_test',
    );
    ReportEnv.tokenOverride = () async => token;
    ReportEnv.versionOverride = () async => version;
    ReportEnv.platformOverride = 'android';
    ReportEnv.now = () => clock;
    ReportEnv.clientFactory = () => MockClient((req) async {
      requests.add(RecordedRequest(req.method, req.url, req.headers, req.body));
      return handler(req);
    });
  }

  void advance(Duration d) => clock = clock.add(d);
}

Future<CommunityStore> openReportStore({bool withContext = true}) async {
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('sr_report_');
  final store = await CommunityStore.open(
    path: '${dir.path}/community.db',
    factory: databaseFactoryFfi,
  );
  if (withContext) {
    await store.setContext({
      'contributor_fingerprint': 'fp1',
      'connection_id': testConnectionId,
      'writer_epoch': 1,
      'dataset_key': 'ds1',
      'consent_grant_id': '22222222-2222-4222-8222-222222222222',
      'policy_version': '2026-10-21.1',
      'consent_text_sha256': 'abc',
      'source_app': 'safetyreport-mobile',
      'source_mode': 'standalone',
    });
  }
  return store;
}

Map<String, Object?> bf({
  String state = 'filling',
  String? phase = 'filling',
  String? reason,
  int stored = 10,
}) => {
  'state': state,
  'phase': phase,
  'reason': reason,
  'next_attempt_at': null,
  'total': 100,
  'stored': stored,
  'queued': 0,
  'pending': 90,
  'holds': 0,
  'stale_holds': 0,
  'raw_unavailable': 0,
  'not_eligible': 0,
  'run_started_at': '2026-10-22T01:00:00Z',
  'updated_at': '2026-10-22T02:59:00Z',
};

Map<String, Object?> opt({bool running = false}) => {
  'required': false,
  'running': running,
  'holds_only': false,
};
