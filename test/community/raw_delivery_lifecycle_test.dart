import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/raw_ingest.dart';
import 'package:safetyreport/community/client_notice.dart';
import 'package:safetyreport/community/soft_reset.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
import 'package:safetyreport/services/sync_operation_admission.dart';
import 'fake_account.dart';
import 'uploader_test.dart' as u;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommunityStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    store = await u.openStore();
  });
  tearDown(() async {
    CommunityReset.pauseForegroundRetry();
    MaintenanceService.resumeForAccount();
    ClientNotice.current.value = null;
    await u.closeStore(store);
  });
  test('ACK notice survives reload and 426 is always required', () async {
    ClientNotice.versionProvider = () async => '2.4.1';
    final notice = {
      ...ClientNotice.fallback,
      'message': '합성 중앙 안내',
      'level': 'warning',
      'min_version': {'pc': null, 'mobile': '2.5.0'},
    };
    await ClientNotice.save(store, notice);
    ClientNotice.current.value = null;
    await ClientNotice.load(store);
    expect(ClientNotice.current.value!['message'], '합성 중앙 안내');
    await ClientNotice.markUpgradeRequired(store);
    expect(ClientNotice.current.value!['level'], 'required');
  });
  test(
    'a revoked work generation cannot publish after an external await',
    () async {
      var wrote = false;
      await expectLater(
        SyncOperationAdmission.run(
          () async {
            await SyncOperationAdmission.cancelAll(store);
            await SyncOperationAdmission.protectWrite(() async {
              wrote = true;
            });
          },
          null,
          openStore: () async => store,
        ),
        throwsStateError,
      );
      expect(wrote, false);
    },
  );
  test('Client follows PC lock and keeps its phone login', () async {
    final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    var permitted = true;
    final server = FakeAccountServer(status: () => statusJson());
    final gate = CommunityGate(
      auth: auth,
      store: store,
      config: testAuthConfig(),
      configStatus: () => 'ok',
      accountClient: server.accountClient(),
      appMode: () => 'server',
      serverGate: () async => CommunityGateLinkResult.success({
        'can_local': permitted,
        'can_enter': permitted,
      }),
    );
    addTearDown(gate.dispose);
    expect((await gate.refreshNow()).canEnter, true);
    permitted = false;
    gate.invalidate('pc_reset');
    await gate.refreshNow();
    expect(gate.canBrowse, false);
    expect(gate.state.state, 'server_consent_required');
    expect(gate.notice, contains('서버 동의 필요'));
    expect(auth.state.value.phase, CommunityAccountPhase.connected);
  });
  test(
    'failed withdrawal retains login and a durable retry; confirmation soft resets',
    () async {
      final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
      var fail = true;
      final client = CommunityAccountClient(
        supabaseUrl: testAuthConfig().supabaseUrl,
        publishableKey: 'synthetic',
        client: MockClient(
          (r) async => fail
              ? http.Response('{"error":{"code":"busy","retryable":true}}', 503)
              : http.Response(
                  '{"protocol":1,"grant_id":"g","revoked":true,"already_revoked":false,"lineage_active":false}',
                  200,
                ),
        ),
      );
      await store.setMeta('raw_backfill', '{"state":"done"}');
      await CommunityReset.begin(store, 'g', auth: auth, client: client);
      expect(
        await CommunityReset.attempt(
          store,
          auth: auth,
          client: client,
          force: true,
        ),
        false,
      );
      expect(auth.state.value.phase, CommunityAccountPhase.connected);
      expect(await CommunityReset.pending(store), isNotNull);
      expect(await store.activeContext(), isNull);
      fail = false;
      expect(
        await CommunityReset.attempt(
          store,
          auth: auth,
          client: client,
          force: true,
        ),
        true,
      );
      expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
      expect(await CommunityReset.pending(store), isNull);
      expect(await store.meta('raw_backfill'), isNull);
    },
  );
  test('late withdrawal confirmation cannot reset a changed session', () async {
    final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    final client = CommunityAccountClient(
      supabaseUrl: testAuthConfig().supabaseUrl,
      publishableKey: 'synthetic',
      client: MockClient((_) async {
        await auth.disconnect();
        return http.Response(
          '{"protocol":1,"grant_id":"g","revoked":true,"already_revoked":false,"lineage_active":false}',
          200,
        );
      }),
    );
    await CommunityReset.begin(store, 'g', auth: auth, client: client);
    expect(
      await CommunityReset.attempt(
        store,
        auth: auth,
        client: client,
        force: true,
      ),
      false,
    );
    expect(await CommunityReset.pending(store), isNotNull);
  });
  test(
    'supplement-only changes create v2 journal and preserve frozen raw bytes',
    () async {
      final ctx = (await store.activeContext())!;
      await store.setMeta(
        'ingest_status',
        jsonEncode({
          'consent': {
            'state': 'active',
            'grant_id': ctx['consent_grant_id'],
            'policy_version': ctx['policy_version'],
          },
          'ingest': {
            'contracts': [1, 2],
            'raw_policy_version': ctx['policy_version'],
          },
        }),
      );
      final input = <String, Object?>{
        'processing_status': '수용',
        'geocode': null,
      };
      final packet = rawSnapshot(
        '{"result":{"C_NO":"SYNTHETIC01"}}',
        '2026-10-21T00:00:00Z',
        'crawl',
        {},
      );
      final first = await capture(
        input,
        sourceReportId: 'SYNTHETIC01',
        trigger: 'realtime',
        store: store,
        rawDetailSnapshot: packet,
      );
      final changed = rawSnapshot(
        '{"result":{"C_NO":"SYNTHETIC01"}}',
        '2026-10-21T00:00:00Z',
        'crawl',
        {'별점사유': '합성 사유'},
      );
      final second = await capture(
        input,
        sourceReportId: 'SYNTHETIC01',
        trigger: 'realtime',
        store: store,
        rawDetailSnapshot: changed,
      );
      expect(second.eventId, isNotNull);
      expect(second.eventId, isNot(first.eventId));
      final rows = await store.db.query(
        'source_journal',
        where: 'event_id=?',
        whereArgs: [first.eventId],
      );
      expect(
        ((jsonDecode(rows.first['raw_event_json'] as String) as Map)['raw']
            as Map)['body'],
        (packet['raw'] as Map)['body'],
      );
    },
  );
}
