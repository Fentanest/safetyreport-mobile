import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/community/cloud_availability.dart';
import 'package:safetyreport/community/consent_history.dart';
import 'package:safetyreport/community/consent_catchup.dart';
import 'package:safetyreport/community/capture/community_capture.dart'
    as capture;
import 'package:safetyreport/community/gate/community_client_rules.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'fake_account.dart';
import 'upload_control_test.dart' as u;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late u.Harness h;
  setUp(() async {
    CloudAvailability.shared = null;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    h = u.Harness();
    await h.open();
  });
  tearDown(() async {
    CloudAvailability.shared = null;
    await h.close();
  });

  for (final code in [429, 503]) {
    test(
      '$code, Retry-After date 600, process restart and repeated requests',
      () async {
        var time = DateTime.utc(2026, 10, 7);
        var calls = 0;
        final raw = MockClient((r) async {
          calls++;
          return http.Response(
            'busy',
            code,
            headers: {
              'retry-after': HttpDate.format(
                time.add(const Duration(seconds: 600)),
              ),
            },
          );
        });
        CloudAvailability.shared = CloudAvailability(
          h.store,
          u.url,
          now: () => time,
        );
        final client = CloudHttpClient(raw);
        await client.get(Uri.parse('${u.url}/auth/v1/user'));
        final at = await CloudAvailability.shared!.deadline();
        expect(at, time.add(const Duration(seconds: 600)));
        await h.restart();
        CloudAvailability.shared = CloudAvailability(
          h.store,
          u.url,
          now: () => time,
        );
        await Future.wait(
          List.generate(
            8,
            (_) => client.get(
              Uri.parse('${u.url}/functions/v1/community-account/status'),
            ),
          ),
        );
        expect(calls, 1);
        expect(await CloudAvailability.shared!.deadline(), at);
        time = time.add(const Duration(seconds: 601));
        final blocker = Completer<void>();
        final probe = CloudHttpClient(
          MockClient((r) async {
            calls++;
            await blocker.future;
            return http.Response('{}', 200);
          }),
        );
        final first = probe.get(Uri.parse('${u.url}/auth/v1/user'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final rest = await Future.wait(
          List.generate(
            5,
            (_) => probe.get(Uri.parse('${u.url}/auth/v1/user')),
          ),
        );
        expect(rest.every((r) => r.statusCode == 503), isTrue);
        blocker.complete();
        await first;
        expect(calls, 2);
        expect(await CloudAvailability.shared!.coolingDown(), isFalse);
      },
    );
  }
  test(
    'ingest snake case, camel case and header share the longest cooldown',
    () async {
      var clock = DateTime.utc(2026, 10, 7);
      var calls = 0;
      CloudAvailability.shared = CloudAvailability(
        h.store,
        u.url,
        now: () => clock,
      );
      final client = CloudHttpClient(
        MockClient((r) async {
          calls++;
          return http.Response(
            jsonEncode({
              'error': {'retryAfterSeconds': 600, 'retry_after_seconds': 900},
            }),
            503,
            headers: {'retry-after': '450'},
          );
        }),
      );
      await client.post(Uri.parse('${u.url}/functions/v1/community-ingest'));
      expect(
        await CloudAvailability.shared!.deadline(),
        clock.add(const Duration(seconds: 900)),
      );
      await h.restart();
      clock = clock.add(const Duration(seconds: 301));
      CloudAvailability.shared = CloudAvailability(
        h.store,
        u.url,
        now: () => clock,
      );
      await client.get(Uri.parse('${u.url}/auth/v1/user'));
      await client.get(
        Uri.parse('${u.url}/functions/v1/community-account/status'),
      );
      expect(calls, 1);
    },
  );
  test(
    'local revoke never hides suspension, even after restart or acceptance',
    () async {
      var history = ConsentHistory(h.store);
      await history.event(
        'a',
        'consent_required',
        'local',
        grant: 'g',
        localRevoke: true,
      );
      await history.event(
        'a',
        'suspended',
        'server',
        grant: 'g',
        status: statusJson(contributor: 'suspended'),
      );
      await h.restart();
      history = ConsentHistory(h.store);
      await history.event('a', 'unknown', 'timeout');
      await history.acceptedExplicitly('a');
      await history.event('a', 'consent_required', 'local');
      expect((await history.latest('a'))?['result'], 'suspended');
      await history.event(
        'a',
        'ok',
        'server',
        grant: 'g',
        status: statusJson(),
      );
      expect((await history.latest('a'))?['suspended'], false);
    },
  );
  test(
    'initial active status does not schedule a crawl; real consent transition does',
    () async {
      final history = ConsentHistory(h.store);
      await history.event(
        'a',
        'ok',
        'server',
        grant: 'g',
        status: statusJson(),
      );
      expect(await history.needsCatchup('a', 'g'), false);
      await history.event(
        'a',
        'consent_required',
        'server',
        grant: 'g',
        status: statusJson(consentState: 'revoked'),
      );
      await history.event(
        'a',
        'ok',
        'server',
        grant: 'g2',
        status: statusJson(),
      );
      expect(await history.needsCatchup('a', 'g2'), true);
    },
  );
  test(
    'browser OAuth honors an observed outage but healthy login starts immediately',
    () async {
      var time = DateTime.utc(2026, 10, 7);
      var launches = 0;
      final auth = CommunityAuthService(
        config: testAuthConfig(),
        launcher: (_) async {
          launches++;
          return true;
        },
      );
      CloudAvailability.shared = CloudAvailability(
        h.store,
        testAuthConfig().supabaseUrl,
        now: () => time,
      );
      expect(await auth.startLogin(), CommunityStartOutcome.launched);
      await CloudAvailability.shared!.failed();
      expect(await auth.startLogin(), CommunityStartOutcome.coolingDown);
      expect(launches, 1);
      time = time.add(const Duration(seconds: 301));
      expect(await auth.startLogin(), CommunityStartOutcome.launched);
      expect(launches, 2);
    },
  );
  test(
    'timeout has 300-second durable floor; plain 429 is transient',
    () async {
      final clock = DateTime.utc(2026, 10, 7);
      CloudAvailability.shared = CloudAvailability(
        h.store,
        u.url,
        now: () => clock,
      );
      final client = CloudHttpClient(
        MockClient((r) async => throw TimeoutException('fixture')),
      );
      await expectLater(
        client.get(Uri.parse('${u.url}/auth/v1/token')),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        await CloudAvailability.shared!.deadline(),
        clock.add(const Duration(seconds: 300)),
      );
      expect(
        classifyAccountResponse(429, 'rate limited', {}).transient,
        isTrue,
      );
    },
  );
  test(
    'secure history: transitions only, unknown does not overwrite; no DB audit',
    () async {
      final history = ConsentHistory(h.store);
      await history.event(
        'a',
        'consent_required',
        'server',
        grant: 'g',
        status: statusJson(consentState: 'none'),
      );
      final before = await const FlutterSecureStorage().read(
        key: ConsentHistory.key('a'),
      );
      await history.event('a', 'unknown', 'timeout');
      await history.event(
        'a',
        'consent_required',
        'server',
        grant: 'g',
        status: statusJson(consentState: 'none'),
      );
      expect(
        await const FlutterSecureStorage().read(key: ConsentHistory.key('a')),
        before,
      );
      await history.event(
        'a',
        'consent_required',
        'local-revoke',
        grant: 'g',
        localRevoke: true,
      );
      await history.event(
        'a',
        'ok',
        'server',
        grant: 'g',
        status: statusJson(),
      );
      expect(await history.uploadBlocked('a', 'g'), isTrue);
      await history.event(
        'a',
        'ok',
        'server',
        grant: 'g2',
        status: statusJson(),
      );
      expect(await history.uploadBlocked('a', 'g2'), isFalse);
      expect(
        await h.store.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='consent_events'",
        ),
        isEmpty,
      );
    },
  );
  test(
    'offline denial collection, restart, reconsent reshare and exactly-once successful catch-up',
    () async {
      final ctx = u.ctxA;
      final history = ConsentHistory(h.store);
      await history.event(
        ctx['contributor_fingerprint'] as String,
        'consent_required',
        'server',
        grant: ctx['consent_grant_id'] as String,
        status: statusJson(consentState: 'revoked'),
      );
      await history.pauseCapture(
        ctx['contributor_fingerprint'] as String,
        ctx['dataset_key'] as String,
        consentDenied: true,
      );
      await h.store.deactivateContext('consent_required');
      final event = await capture.capture(
        u.adapter(),
        sourceReportId: 'offline',
        trigger: 'realtime',
        store: h.store,
        projectNamespace: u.kNs,
      );
      await capture.markPersonalSave(event.eventId, true, store: h.store);
      expect(await h.store.db.query('outbox'), isEmpty);
      final source = (await h.store.db.query('source_journal')).single;
      expect(source['contributor_fingerprint'], ctx['contributor_fingerprint']);
      expect(source['blocked_reason'], 'consent_denied');
      await h.restart();
      await h.store.setContext({
        ...ctx,
        'consent_grant_id': '33333333-3333-4333-8333-333333333333',
      });
      final job = ConsentCatchup(h.store);
      await job.schedule((await h.store.activeContext())!);
      var collections = 0;
      expect(
        await job.run(
          verify: () async => true,
          manifest: () async => false,
          collectAll: () async {
            collections++;
            return true;
          },
        ),
        isFalse,
      );
      expect(await h.store.db.query('outbox'), isEmpty);
      expect(
        await job.run(
          verify: () async => true,
          manifest: () async => true,
          collectAll: () async {
            collections++;
            return false;
          },
        ),
        isFalse,
      );
      await h.restart();
      final resumed = ConsentCatchup(h.store);
      expect(
        await resumed.run(
          verify: () async => true,
          manifest: () async => true,
          collectAll: () async {
            collections++;
            return true;
          },
        ),
        isTrue,
      );
      expect(
        await resumed.run(
          verify: () async => true,
          manifest: () async => true,
          collectAll: () async {
            collections++;
            return true;
          },
        ),
        isFalse,
      );
      expect(collections, 2);
      final queued = await h.store.db.query('outbox');
      expect(queued.length, 1);
      final id = queued.single['event_id'];
      h.now = h.now.add(const Duration(days: 20));
      expect(await h.upload('recovery'), 'sent');
      expect(h.requests.single.$2['trigger'], 'reshare');
      expect((h.requests.single.$2['events'] as List).single['event_id'], id);
      expect(await h.store.db.query('outbox'), isEmpty);
      expect(await h.upload('recovery'), 'no_pending');
    },
  );
  test(
    'account switch and explicit deletion never reshare foreign/deleted records',
    () async {
      final old = await h.capture('old');
      await capture.markPersonalSave(old, true, store: h.store);
      await h.store.db.update(
        'source_journal',
        {'blocked_reason': 'deleted_by_user'},
        where: 'event_id=?',
        whereArgs: [old],
      );
      await h.store.setContext({
        ...u.ctxA,
        'contributor_fingerprint': 'different-account',
        'consent_grant_id': 'new',
      });
      expect(
        await ConsentCatchup(
          h.store,
        ).reshareMissing((await h.store.activeContext())!),
        0,
      );
      await h.store.setContext({...u.ctxA, 'consent_grant_id': 'new'});
      expect(
        await ConsentCatchup(
          h.store,
        ).reshareMissing((await h.store.activeContext())!),
        0,
      );
    },
  );
  for (final denied in ['none', 'revoked']) {
    test(
      'emergency policy $denied then 503 permits SAME-owner local use, not upload',
      () async {
        final auth = StubAuthService()
          ..setPhase(CommunityAccountPhase.connected);
        var fail = false;
        final client = CommunityAccountClient(
          supabaseUrl: testAuthConfig().supabaseUrl,
          publishableKey: 'test',
          client: MockClient(
            (r) async => fail
                ? http.Response('busy', 503)
                : http.Response.bytes(
                    utf8.encode(jsonEncode(statusJson(consentState: denied))),
                    200,
                  ),
          ),
        );
        final gate = CommunityGate(
          auth: auth,
          store: h.store,
          config: testAuthConfig(),
          accountClient: client,
          appMode: () => 'standalone',
          checkDataOwner: ownerOk,
          officialAccountId: () async => 'official',
        );
        addTearDown(gate.dispose);
        expect((await gate.refreshNow()).canEnter, isFalse);
        expect(gate.canBrowse, isTrue);
        fail = true;
        await gate.refreshNow();
        expect(gate.canBrowse, isTrue);
        expect(gate.canEnter, isFalse);
      },
    );
  }
  test('suspension persists across failed refresh and gate restart', () async {
    final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    var fail = false;
    final client = CommunityAccountClient(
      supabaseUrl: testAuthConfig().supabaseUrl,
      publishableKey: 'test',
      client: MockClient(
        (r) async => fail
            ? http.Response('busy', 503)
            : http.Response.bytes(
                utf8.encode(jsonEncode(statusJson(contributor: 'suspended'))),
                200,
              ),
      ),
    );
    CommunityGate make() => CommunityGate(
      auth: auth,
      store: h.store,
      config: testAuthConfig(),
      accountClient: client,
      appMode: () => 'standalone',
      checkDataOwner: ownerOk,
      officialAccountId: () async => 'official',
    );
    final first = make();
    expect((await first.refreshNow()).state, 'suspended');
    expect(
      (await ConsentHistory(h.store).latest('fp-32hex'))?['result'],
      'suspended',
    );
    first.dispose();
    fail = true;
    final restarted = make();
    addTearDown(restarted.dispose);
    await restarted.refreshNow();
    expect(restarted.canBrowse, isFalse);
  });
}
