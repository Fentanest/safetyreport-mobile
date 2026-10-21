// Review fixes (mobile-review 3, 6, 15): v2 -> v1 fallback, 503 for a disabled v2, update notices.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/raw_ingest.dart';
import 'package:safetyreport/community/client_notice.dart';
import 'package:safetyreport/community/capture/raw_capture_source.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/consent_catchup.dart';
import 'package:safetyreport/community/soft_reset.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'fake_account.dart' show StubAuthService;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:safetyreport/community/ingest_status.dart';
import 'package:safetyreport/widgets/client_notice_host.dart';
import 'package:safetyreport/widgets/community_account_card.dart'
    show communityAuthNavigatorKey;
import 'package:shared_preferences/shared_preferences.dart';
import 'uploader_test.dart' as u;

Map<String, Object?> v2Status(Map<String, Object?> ctx, {bool v2 = true}) => {
  'consent': {
    'state': 'active',
    'grant_id': ctx['consent_grant_id'],
    'policy_version': ctx['policy_version'],
  },
  'ingest': {
    'contracts': v2 ? [1, 2] : [1],
    'raw_policy_version': ctx['policy_version'],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommunityStore store;
  late Map<String, Object?> ctx;
  late u.FakeGate gate;
  late u.FakeTokens tokens;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await u.openStore();
    ctx = (await store.activeContext())!;
    gate = u.FakeGate();
    tokens = u.FakeTokens();
    ClientNotice.versionProvider = () async => '2.4.1';
    ClientNotice.current.value = null;
  });
  tearDown(() async {
    ClientNotice.current.value = null;
    await u.closeStore(store);
  });

  Map<String, Object?> body(http.Request req) {
    final gz = req.headers['content-encoding'] == 'gzip';
    final text = utf8.decode(gz ? gzip.decode(req.bodyBytes) : req.bodyBytes);
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }

  Future<String?> capV2(String id) async {
    await store.setMeta('ingest_status', jsonEncode(v2Status(ctx)));
    final result = await capture(
      u.adapter('수용'),
      sourceReportId: id,
      trigger: 'realtime',
      store: store,
      projectNamespace: u.kNs,
      rawDetailSnapshot: rawSnapshot(
        '{"result":{"C_NO":"$id"}}',
        '2026-10-21T00:00:00Z',
        'crawl',
        {},
      ),
    );
    return result.eventId;
  }

  group('v2 -> v1 fallback', () {
    test(
      'a v1 row queued before the switch is sent as v1 once v2 is ready (never blocked)',
      () async {
        final v1 = (await capture(
          u.adapter('수용'),
          sourceReportId: 'OLD',
          trigger: 'realtime',
          store: store,
          projectNamespace: u.kNs,
        )).eventId!;
        await store.setMeta('ingest_status', jsonEncode(v2Status(ctx)));
        final protocols = <Object?>[];
        final client = MockClient((req) async {
          final b = body(req);
          protocols.add(b['protocol']);
          return http.Response(
            jsonEncode({
              'protocol': b['protocol'],
              'request_id': 'req1',
              'results': [u.ackFor(v1, 'accepted')],
            }),
            200,
          );
        });
        final run = await u
            .makeUploader(
              store: store,
              gate: gate,
              tokens: tokens,
              httpClient: client,
            )
            .requestCommunityUpload('realtime');
        expect(protocols, [1], reason: 'raw 없는 행은 v1 으로 보낸다');
        expect(run.result, 'sent');
        expect(await store.db.query('outbox'), isEmpty);
        final journal = await store.db.query(
          'source_journal',
          where: 'event_id=?',
          whereArgs: [v1],
        );
        expect(journal.single['blocked_reason'], isNull);
      },
    );

    test(
      'when status stops listing 2 a parked v2 row waits and a v1 event is issued for the report',
      () async {
        final v2 = (await capV2('SW1'))!;
        final rows = await store.db.query(
          'source_journal',
          where: 'event_id=?',
          whereArgs: [v2],
        );
        expect(rows.single['raw_event_json'], isNotNull);
        // Server operator turns v2 off: the next status answer lacks 2.
        await saveIngestStatus(store, v2Status(ctx, v2: false));
        final back = await capture(
          u.adapter('수용'),
          sourceReportId: 'SW1',
          trigger: 'realtime',
          store: store,
          projectNamespace: u.kNs,
        );
        expect(back.eventId, isNotNull, reason: 'v1 이벤트를 다시 만든다');
        final v1 = await store.db.query(
          'source_journal',
          where: 'event_id=?',
          whereArgs: [back.eventId],
        );
        expect(v1.single['raw_event_json'], isNull);
        final sent = <Object?>[];
        final client = MockClient((req) async {
          final b = body(req);
          sent.add(b['protocol']);
          return http.Response(
            jsonEncode({
              'protocol': 1,
              'request_id': 'req2',
              'results': [u.ackFor(back.eventId!, 'accepted')],
            }),
            200,
          );
        });
        await u
            .makeUploader(
              store: store,
              gate: gate,
              tokens: tokens,
              httpClient: client,
            )
            .requestCommunityUpload('realtime');
        expect(sent, [1]);
        final parked = await store.db.query(
          'outbox',
          where: 'event_id=?',
          whereArgs: [v2],
        );
        expect(parked.single['state'], 'retry_wait');
        expect(parked.single['last_error_code'], 'v2_unavailable');
      },
    );

    test(
      'a 503 service_unavailable for v2 is retryable, not a block',
      () async {
        final v2 = (await capV2('SW2'))!;
        final client = MockClient(
          (req) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'service_unavailable',
                'message': 'v2 off',
                'retryable': true,
              },
            }),
            503,
          ),
        );
        final run = await u
            .makeUploader(
              store: store,
              gate: gate,
              tokens: tokens,
              httpClient: client,
            )
            .requestCommunityUpload('realtime');
        expect(run.result, isNot('blocked_gate'));
        final row = await store.db.query(
          'outbox',
          where: 'event_id=?',
          whereArgs: [v2],
        );
        expect(row.single['state'], 'retry_wait');
        expect(gate.invalidated, isEmpty);
      },
    );

    test(
      'losing 2 lifts the 503 cooldown so v1 rows are not held behind it',
      () async {
        await store.setMeta('ingest_status', jsonEncode(v2Status(ctx)));
        await store.db.insert('upload_control', {
          'scope': 'service:ns',
          'state': 'cooling_down',
          'updated_at': '2026-10-21T00:00:00.000Z',
          'consecutive_failures': 3,
          'next_attempt_at': '2999-01-01T00:00:00.000Z',
          'last_error_code': 'service_unavailable',
        });
        await saveIngestStatus(store, v2Status(ctx, v2: false));
        expect(await store.db.query('upload_control'), isEmpty);
      },
    );

    test(
      'an ACKed raw event keeps only its content keys in the journal',
      () async {
        final v2 = (await capV2('CMP1'))!;
        final client = MockClient((req) async {
          return http.Response(
            jsonEncode({
              'protocol': 2,
              'request_id': 'req3',
              'results': [
                {...u.ackFor(v2, 'stored', projection: 'parse_pending')},
              ],
            }),
            200,
          );
        });
        await u
            .makeUploader(
              store: store,
              gate: gate,
              tokens: tokens,
              httpClient: client,
            )
            .requestCommunityUpload('realtime');
        final row = await store.db.query(
          'source_journal',
          where: 'event_id=?',
          whereArgs: [v2],
        );
        final kept = jsonDecode(row.single['raw_event_json'] as String) as Map;
        expect(kept['compact'], true);
        expect(kept.containsKey('body'), isFalse);
        expect((kept['raw'] as Map).containsKey('body'), isFalse);
        // The change detection still sees the same content keys (no spurious new event).
        final again = await capture(
          u.adapter('수용'),
          sourceReportId: 'CMP1',
          trigger: 'realtime',
          store: store,
          projectNamespace: u.kNs,
          rawDetailSnapshot: rawSnapshot(
            '{"result":{"C_NO":"CMP1"}}',
            '2026-10-21T00:00:00Z',
            'crawl',
            {},
          ),
        );
        expect(again.eventId, isNull);
      },
    );
  });

  group('update notice', () {
    Map<String, Object?> notice({
      String level = 'warning',
      String? mobile = '2.5.0',
      String message = '합성 안내',
    }) => {
      ...ClientNotice.fallback,
      'level': level,
      'message': message,
      'min_version': {'pc': null, 'mobile': mobile},
    };

    test(
      'versions compare numerically; only an older app is shown the notice',
      () {
        expect(ClientNotice.compareVersions('2.10.0', '2.5.0'), 1);
        expect(ClientNotice.compareVersions('2.5.0+178', '2.5.0'), 0);
        expect(ClientNotice.applies(notice(), '2.4.1'), isTrue);
        expect(ClientNotice.applies(notice(), '2.5.0'), isFalse);
        expect(ClientNotice.applies(notice(), '3.0.0'), isFalse);
        expect(ClientNotice.applies(notice(mobile: null), '1.0.0'), isFalse);
        expect(ClientNotice.applies(notice(), null), isTrue);
      },
    );

    test('an up-to-date app has no notice, an older one does', () async {
      ClientNotice.versionProvider = () async => '2.5.0';
      await ClientNotice.save(store, notice());
      expect(ClientNotice.current.value, isNull);
      ClientNotice.versionProvider = () async => '2.4.1';
      await ClientNotice.load(store);
      expect(ClientNotice.current.value!['message'], '합성 안내');
    });

    test(
      'status is the authority: null clears notice and the 426 flag; a satisfied notice lifts the flag',
      () async {
        await ClientNotice.save(store, notice(level: 'required'));
        await ClientNotice.markUpgradeRequired(store);
        expect(await store.meta('client_upgrade_required'), isNotNull);
        await ClientNotice.save(store, null);
        expect(await store.meta('client_upgrade_required'), isNull);
        expect(await store.meta('client_notice'), isNull);
        expect(ClientNotice.current.value, isNull);

        await ClientNotice.markUpgradeRequired(store);
        ClientNotice.versionProvider = () async => '2.5.1';
        await ClientNotice.save(store, notice());
        expect(await store.meta('client_upgrade_required'), isNull);
      },
    );

    test(
      'an ACK without a notice neither erases the stored notice nor keeps the 426 flag',
      () async {
        await ClientNotice.save(store, notice());
        await ClientNotice.markUpgradeRequired(store);
        await ClientNotice.save(
          store,
          null,
          authoritative: false,
          clearUpgrade: true,
        );
        expect(await store.meta('client_upgrade_required'), isNull);
        expect(await store.meta('client_notice'), isNotNull);
        expect(ClientNotice.current.value!['message'], '합성 안내');
      },
    );

    test(
      '426 is lifted by an app update (version changed) without any server answer',
      () async {
        await ClientNotice.markUpgradeRequired(store);
        expect(ClientNotice.current.value!['level'], 'required');
        ClientNotice.versionProvider = () async => '2.5.0';
        await ClientNotice.load(store);
        expect(ClientNotice.current.value, isNull);
      },
    );

    test(
      '426 keeps rows retryable and a lifted flag releases rows an old build blocked',
      () async {
        final v1 = (await capture(
          u.adapter('수용'),
          sourceReportId: 'U1',
          trigger: 'realtime',
          store: store,
          projectNamespace: u.kNs,
        )).eventId!;
        final client = MockClient(
          (req) async => http.Response(
            jsonEncode({
              'error': {'code': 'client_upgrade_required', 'message': 'old'},
            }),
            426,
          ),
        );
        await u
            .makeUploader(
              store: store,
              gate: gate,
              tokens: tokens,
              httpClient: client,
            )
            .requestCommunityUpload('realtime');
        var row = await store.db.query(
          'outbox',
          where: 'event_id=?',
          whereArgs: [v1],
        );
        expect(row.single['state'], 'retry_wait', reason: '영구 blocked 가 아니다');
      final wait = DateTime.parse(row.single['next_retry_at'] as String).difference(DateTime.now().toUtc());
      expect(wait.inMinutes, inInclusiveRange(55, 61), reason: '1시간 retry_wait');
        expect(gate.invalidated, isEmpty, reason: '게이트를 잠그지 않는다');
        expect(await store.meta('client_upgrade_required'), isNotNull);

        // Rows an older build left blocked are released when the flag is lifted.
        await store.db.update(
          'outbox',
          {'state': 'blocked', 'last_error_code': 'client_upgrade_required'},
          where: 'event_id=?',
          whereArgs: [v1],
        );
        await store.db.update(
          'source_journal',
          {'blocked_reason': 'blocked:client_upgrade_required'},
          where: 'event_id=?',
          whereArgs: [v1],
        );
        await ClientNotice.save(store, null);
        row = await store.db.query(
          'outbox',
          where: 'event_id=?',
          whereArgs: [v1],
        );
        expect(row.single['state'], 'pending');
        final journal = await store.db.query(
          'source_journal',
          where: 'event_id=?',
          whereArgs: [v1],
        );
        expect(journal.single['blocked_reason'], isNull);
      },
    );

    test(
      'shown history is persisted per notice hash and expires after a day',
      () async {
        final n = notice();
        expect(await ClientNotice.shownRecently(store, n), isFalse);
        await ClientNotice.markShown(store, n);
        expect(await ClientNotice.shownRecently(store, n), isTrue);
        expect(
          await ClientNotice.shownRecently(store, notice(message: '다른 안내')),
          isFalse,
        );
        expect(
          await ClientNotice.shownRecently(
            store,
            n,
            now: DateTime.now().add(const Duration(hours: 25)),
          ),
          isFalse,
        );
      },
    );

    testWidgets(
      'info/warning is a banner, required is a dialog, and a seen notice is not repeated',
      (tester) async {
        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 80)),
            );
            await tester.pump();
          }
        }

        await tester.runAsync(
          () => ClientNotice.save(store, notice(level: 'warning')),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: communityAuthNavigatorKey,
            builder: (context, child) =>
                ClientNoticeHost(store: store, child: child!),
            home: const Scaffold(body: Text('신고내역')),
          ),
        );
        await settle();
        expect(find.text('합성 안내'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing, reason: 'warning 은 배너');
        await tester.tap(find.byIcon(Icons.close));
        await settle();
        expect(find.text('합성 안내'), findsNothing);

        // Required: a dialog, once.
        await tester.runAsync(
          () => ClientNotice.save(
            store,
            notice(level: 'required', message: '필수 안내'),
          ),
        );
        await settle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('필수 안내'), findsOneWidget);
        await tester.tap(find.text('확인'));
        await settle();
        // Same notice again within a day: not shown.
        await tester.runAsync(() async {
          ClientNotice.current.value = null;
          await ClientNotice.load(store);
        });
        await settle();
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('unsent rows survive a reset and the v1 catch-up resends them', () {
    test(
      'reset keeps the journal; re-consent catch-up issues a new pending v1 event',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final v1 = (await capture(
          u.adapter('수용'),
          sourceReportId: 'KEEP1',
          trigger: 'realtime',
          store: store,
          projectNamespace: u.kNs,
        )).eventId!;
        await store.db.update(
          'source_journal',
          {'personal_save_state': 'saved'},
          where: 'event_id=?',
          whereArgs: [v1],
        );
        await CommunityReset.complete(store, auth: StubAuthService());
        final blocked = await store.db.query(
          'outbox',
          where: 'event_id=?',
          whereArgs: [v1],
        );
        expect(blocked.single['state'], 'blocked');
        expect(blocked.single['last_error_code'], 'consent_revoked');
        final journal = await store.db.query(
          'source_journal',
          where: 'event_id=?',
          whereArgs: [v1],
        );
        expect(
          journal.single['blocked_reason'],
          isNull,
          reason: '신고 자료·journal 은 남는다',
        );

        // Same account consents again with a new grant.
        await store.setContext({
          ...ctx
            ..remove('id')
            ..remove('state')
            ..remove('verified_at')
            ..remove('inactive_reason'),
          'consent_grant_id': '33333333-3333-4333-8333-333333333333',
        });
        final fresh = (await store.activeContext())!;
        final made = await ConsentCatchup(store).reshareMissing(fresh);
        expect(made, 1);
        final pending = await store.db.rawQuery(
          "SELECT o.state, j.raw_event_json FROM outbox o JOIN source_journal j ON j.event_id=o.event_id WHERE j.source_report_id='KEEP1' AND o.state='pending'",
        );
        expect(pending.length, 1);
        expect(
          pending.single['raw_event_json'],
          isNull,
          reason: 'v2 전환 전이므로 v1 행',
        );
      },
    );

    test(
      'with v2 ready the v1 catch-up job is handed over (completed), not left scheduled',
      () async {
        await store.setMeta('ingest_status', jsonEncode(v2Status(ctx)));
        await ConsentCatchup(store).schedule(ctx);
        final ran = await ConsentCatchup(store).run(
          verify: () async => true,
          manifest: () async => true,
          collectAll: () async => true,
        );
        expect(ran, isFalse);
        final job =
            jsonDecode((await store.meta(ConsentCatchup.jobKey(ctx)))!) as Map;
        expect(job['phase'], 'completed');
        expect(job['handoff'], 'raw_backfill');
      },
    );
  });

  group('raw snapshot never blocks a personal save', () {
    RawDetailUpsert corrupt() => RawDetailUpsert(
      zlib: Uint8List.fromList([1, 2, 3]),
      sha256: 'deadbeef',
      size: 3,
      fetchedAt: '2026-10-21T00:00:00Z',
      source: 'crawl',
    );

    test(
      'v1 mode does not even compute it; v2 mode swallows a damaged body',
      () async {
        expect(await rawSnapshotIfReady(store, corrupt(), const {}), isNull);
        await store.setMeta('ingest_status', jsonEncode(v2Status(ctx)));
        expect(await rawSnapshotIfReady(store, corrupt(), const {}), isNull);
        expect(await rawSnapshotIfReady(store, null, const {}), isNull);
      },
    );
  });
}
