// Review fixes for the one-time raw upload (mobile-review 2, 9, 10, 11, 12, 13, 14).
// Real LocalDbService (temporary FFI database) and a real community store; the official site is
// replaced through the test hooks. Nothing here talks to a network.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/backfill_store.dart';
import 'package:safetyreport/community/capture/raw_ingest.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/raw_backfill.dart';
import 'package:safetyreport/community/raw_backfill_runtime.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../scripts/check_raw_backfill.dart' as offline;
import 'uploader_test.dart' as u;

Map<String, dynamic> envelopeFor(String id) => {
  'resultCode': '0000',
  'result': {
    'C_NO': id,
    'C_NOW': 10,
    'C_A_CONTENTS':
        '본 신고는 안전신문고 앱의 자동차·교통위반 메뉴로 접수된 신고입니다\n'
        '* 차량번호 : 12가3456\n* 발생일자 : 2026-09-01\n* 발생시각 : 08:00\n신고합니다',
    'RN_ADRES': '서울특별시 강서구 마곡동 1',
    'STTEMNT_NO': 'SPP-2512-$id',
    'C_A_TITLE': '(자동차·교통위반) 신호위반',
    'C_DATE': '2025-12-30 23:40:00',
    'answers': [
      {
        'C_MANAGER_TYPE_NM': '수용',
        'C_MANAGE_CONTENTS': '과태료 40,000원을 부과하였습니다.',
        'C_MANAGE_ORG_NAME': '서울특별시 강서경찰서 교통과',
        'C_MANAGE_MAN': '김담당',
        'C_DATE': '2026-01-02',
      },
    ],
  },
};

Report reportFor(String id) => Report(
  id: id,
  reportNumber: 'SPP-2512-$id',
  name: '(자동차·교통위반) 신호위반',
  date: '2025-12-30',
  responseDate: '2026-01-02',
  agency: '서울특별시 강서경찰서 교통과',
  manager: '김담당',
  status: '수용',
  result: '수용',
  fineInfo: '과태료 40,000원',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '',
  location: '서울특별시 강서구 마곡동 1',
  occurrenceDate: '2026-09-01',
  occurrenceTime: '08:00',
  reportContent: '신고합니다',
  processContent: '과태료 40,000원을 부과하였습니다.',
  attachedPhotos: '',
);

Future<void> seed(String id, {String survey = '참여 완료'}) async {
  await LocalDbService.upsertReport(reportFor(id), 'traffic', '자동차·교통위반-신호위반');
  final d = await LocalDbService.db;
  await d.update(
    'reports',
    {'만족도조사여부': survey},
    where: 'ID=?',
    whereArgs: [id],
  );
  final prepared = prepareRawDetail(envelopeFor(id));
  await d.insert('report_detail_raw', {
    'ID': id,
    'raw_zlib': compressRawDetail(prepared.canonical),
    'raw_sha256': prepared.sha256,
    'raw_size': prepared.canonical.length,
    'fetched_at': '2026-10-17T12:00:00.000Z',
    'source': 'crawl',
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dbDir;
  late CommunityStore store;
  late Map<String, Object?> ctx;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbDir = Directory.systemTemp.createTempSync('sr_raw_review_');
    await databaseFactory.setDatabasesPath(dbDir.path);
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (dbDir.existsSync()) dbDir.deleteSync(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    store = await u.openStore();
    ctx = (await store.activeContext())!;
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
    RawBackfillRuntimeBackend.satisfactionForTest = null;
    RawBackfillRuntimeBackend.totalCountForTest = null;
  });
  tearDown(() async {
    RawBackfillRuntimeBackend.satisfactionForTest = null;
    RawBackfillRuntimeBackend.totalCountForTest = null;
    await u.closeStore(store);
  });

  RawBackfillRuntimeBackend backend() => RawBackfillRuntimeBackend(
    store,
    () => true,
    slice: const Duration(minutes: 5),
  );

  group('supplements never block the raw event', () {
    test(
      'a failed rating lookup leaves the value empty, is remembered, and the event is still issued',
      () async {
        await seed('R1');
        var asked = 0;
        RawBackfillRuntimeBackend.satisfactionForTest = (_) async {
          asked++;
          throw Exception('network down');
        };
        final b = backend();
        expect(await b.scope(), isNotNull);
        final first = await b.prepare('R1');
        expect(first['eligible'], true);
        expect(first['unfilled'], 1, reason: '못 채운 보충으로 세고 hold 하지 않는다');
        final event = await b.enqueue('R1', 'run-1');
        expect(event, isNotNull, reason: '보충 실패여도 원본 이벤트는 만든다');
        final rows = await store.db.query(
          'source_journal',
          where: 'event_id=?',
          whereArgs: [event],
        );
        expect(rows.single['raw_event_json'], isNotNull);
        expect(rows.single['capture_trigger'], 'raw_backfill:run-1');
        // Same report again (next run): the marker stops the lookup — no repeated request,
        // no inflated "filled" count.
        final again = await b.prepare('R1');
        expect(asked, 1);
        expect(again['filled'], 0);
        expect(again['unfilled'], 0);
      },
    );

    test('a lookup that finds nothing is remembered as "none"', () async {
      await seed('R2');
      var asked = 0;
      RawBackfillRuntimeBackend.satisfactionForTest = (_) async {
        asked++;
        return (score: null, cause: '', confirmed: true, exists: true);
      };
      final b = backend();
      await b.scope();
      final r = await b.prepare('R2');
      expect(r['unfilled'], 1);
      expect(r['filled'], 0);
      await b.prepare('R2');
      expect(asked, 1);
      final marker = await store.db.query(
        'raw_backfill_supplements',
        where: "report_id='R2' AND kind='rating'",
      );
      expect(marker.single['status'], 'none');
    });

    test('a found rating fills once and refreshes caches', () async {
      await seed('R3');
      RawBackfillRuntimeBackend.satisfactionForTest = (_) async =>
          (score: 4, cause: '친절', confirmed: true, exists: true);
      final b = backend();
      await b.scope();
      final r = await b.prepare('R3');
      expect(r['filled'], 1);
      final row = await LocalDbService.readReparseBase('R3');
      expect(row!['별점'], 4);
      expect(row['별점사유'], '친절');
    });
  });

  group('one event per report (B path)', () {
    test(
      'an event issued by the detail save is adopted, never duplicated',
      () async {
        await seed('R4');
        final b = backend();
        await b.scope();
        // What step B's ordinary detail save does: one raw event labelled plain `raw_backfill`.
        final row = (await LocalDbService.readReparseBase('R4'))!;
        final first = await b.enqueue('R4', 'run-a');
        expect(first, isNotNull);
        await store.db.update(
          'source_journal',
          {'capture_trigger': 'raw_backfill'},
          where: 'event_id=?',
          whereArgs: [first],
        );
        expect(row['ID'], 'R4');
        final adopted = await b.enqueue('R4', 'run-b');
        expect(adopted, first);
        final events = await store.db.rawQuery(
          "SELECT COUNT(*) AS n FROM source_journal WHERE source_report_id='R4'",
        );
        expect(events.first['n'], 1);
        final label = await store.db.query(
          'source_journal',
          columns: ['capture_trigger'],
          where: 'event_id=?',
          whereArgs: [first],
        );
        expect(label.single['capture_trigger'], 'raw_backfill:run-b');
      },
    );
  });

  group('unsendable reports are not eligible', () {
    test(
      'a user-deleted report is excluded from the denominator, not held',
      () async {
        await seed('R5');
        await seed('R6');
        final b = backend();
        await b.scope();
        final event = await b.enqueue('R5', 'run-x');
        await store.db.update(
          'source_journal',
          {'blocked_reason': 'deleted_by_user'},
          where: 'event_id=?',
          whereArgs: [event],
        );
        await expectLater(b.prepare('R5'), throwsA(isA<BackfillBlocked>()));

        // Through the state machine: the blocked report becomes not_eligible (no hold, can finish).
        final items = SqliteBackfillItems(store, b.check);
        var saved = <String, dynamic>{};
        final runner = RawBackfill(
          load: () async => saved.isEmpty ? null : saved,
          save: (m, s) async => saved = m,
          backend: _Listing(b, ['R5', 'R6']),
          items: items,
        );
        final result = (await runner.run(budget: 100))!;
        final run = result['run_id'] as String;
        final summary = await items.summary(run);
        expect(summary['holds'], 0);
        expect(
          (await items.page(
            run,
            0,
            10,
          )).firstWhere((e) => e.$2 == 'R5').$3['state'],
          'not_eligible',
        );
      },
    );
  });

  group('large database stays bounded', () {
    test(
      '20,000 reports: marker stays small, state lives in the table, slices are bounded',
      () async {
        final ids = [
          for (var i = 0; i < 20000; i++) 'B${i.toString().padLeft(6, '0')}',
        ];
        final fake = _Bulk(ids);
        var saved = <String, dynamic>{};
        final items = SqliteBackfillItems(store, () async {});
        final runner = RawBackfill(
          load: () async => saved.isEmpty ? null : saved,
          save: (m, s) async => saved = m,
          backend: fake,
          items: items,
        );
        final first = (await runner.run(budget: 1000))!;
        expect(first['cursor'], 1000, reason: '한 번에 예산만큼만 진행');
        expect(jsonEncode(first).length, lessThan(4000), reason: 'meta 에는 요약만');
        expect(first.containsKey('items'), isFalse);
        final run = first['run_id'] as String;
        expect(await items.size(run), 20000);
        var guard = 0;
        Map<String, dynamic> last = first;
        while (last['state'] != 'uploading' && guard++ < 40) {
          last = (await runner.run(budget: 1000))!;
          expect(jsonEncode(last).length, lessThan(4000));
        }
        expect(last['state'], 'uploading');
        expect(fake.enqueued.length, 20000);
        fake.stored = true;
        final done = (await runner.run(budget: 1000))!;
        final more = await runner.run(budget: 1000);
        expect((more ?? done)['state'], anyOf('done', 'uploading'));
      },
      // 2만 건 대량 삽입 시험: 크기 상한을 보는 시험이지 시간 예산 시험이 아니다(고부하 호스트에서 기본 30초를 넘는다).
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  group('retry keeps the phase', () {
    test(
      'retry while the list is incomplete never makes the run done',
      () async {
        final fixture = offline.FixtureBackend()..listOk = false;
        Map<String, dynamic>? saved;
        var time = 1000;
        RawBackfill make() => RawBackfill(
          load: () async => saved == null
              ? null
              : (jsonDecode(jsonEncode(saved)) as Map).cast<String, dynamic>(),
          save: (m, s) async => saved = m,
          backend: fixture,
          now: () => DateTime.fromMillisecondsSinceEpoch(time * 1000),
        );
        final paused = (await make().run())!;
        expect(paused['state'], 'paused');
        expect(paused['reason'], 'list_incomplete');
        final retried = (await make().run(retryHolds: true))!;
        expect(retried['state'], 'paused', reason: '목록 미완료면 0건 done 이 되지 않는다');
        expect(retried['phase'], 'listing');
        expect(retried['listing_complete'], isNot(true));
        time += 400;
        fixture.listOk = true;
        final next = (await make().run(retryHolds: true))!;
        expect(next['state'], isNot('done'));
        expect((next['stats'] as Map)['total'], 3);
      },
    );

    test(
      'retry after the listing keeps holds-only work (filling phase)',
      () async {
        final fixture = offline.FixtureBackend()..fail = {'A'};
        Map<String, dynamic>? saved;
        RawBackfill make() => RawBackfill(
          load: () async => saved == null
              ? null
              : (jsonDecode(jsonEncode(saved)) as Map).cast<String, dynamic>(),
          save: (m, s) async => saved = m,
          backend: fixture,
        );
        Map<String, dynamic> r = (await make().run())!;
        for (var i = 0; i < 4 && r['state'] != 'holds'; i++) {
          r = (await make().run())!;
        }
        expect(r['state'], 'holds');
        fixture.fail = {};
        final retried = (await make().run(retryHolds: true))!;
        expect(retried['listing_complete'], true);
        expect((retried['stats'] as Map)['holds'], 0);
      },
    );
  });

  group('run identity', () {
    test(
      'a grant, writer or parser change keeps the run; a dataset change or a cleared marker starts over',
      () async {
        final fixture = offline.FixtureBackend();
        Map<String, dynamic>? saved;
        RawBackfill make() => RawBackfill(
          load: () async => saved == null
              ? null
              : (jsonDecode(jsonEncode(saved)) as Map).cast<String, dynamic>(),
          save: (m, s) async => saved = m,
          backend: fixture,
        );
        final first = (await make().run(budget: 1))!;
        final run = first['run_id'];
        fixture.identity['consent_grant_id'] = 'fresh-grant';
        fixture.identity['writer_epoch'] = 9;
        fixture.identity['connection_id'] = 'other-connection';
        fixture.identity['parser_target'] = 'mobile-parser-99';
        final same = (await make().run(budget: 1))!;
        expect(same['run_id'], run, reason: '재동의·재연결·파서 세대로는 다시 돌지 않는다');
        expect(same['cursor'], 2);
        expect(same['consent_grant_id'], 'fresh-grant');
        fixture.identity['contributor_fingerprint'] = 'another-account';
      fixture.identity['dataset_key'] = 'another-dataset';
      final account = (await make().run(budget: 1))!;
      expect(account['run_id'], run, reason: 'run identity is local_dataset_id only');
      fixture.identity['local_dataset_id'] = 'restored-db';
        final restarted = (await make().run(budget: 1))!;
        expect(restarted['run_id'], isNot(run));
        expect(restarted['cursor'], 1);
        // Soft reset clears the marker; re-consent starts a new run.
        final other = restarted['run_id'];
        saved = null;
        final fresh = (await make().run(budget: 1))!;
        expect(fresh['run_id'], isNot(other));
      },
    );
  });

  group('runtime scheduling', () {
    test(
      'nothing is scheduled once the run is done; holds-only wakes at the hold time',
      () async {
        expect(
          await RawBackfillRuntime.nextDelay(store, {'state': 'done'}),
          isNull,
        );
        expect(await RawBackfillRuntime.nextDelay(store, null), isNull);
        final items = SqliteBackfillItems(store, () async {});
        await items.reset('run-h', {
          'X': {'state': 'hold', 'attempts': 3, 'eligible': true},
        });
        // 2026-10-22(CLIENT-RULES 1절): 보류만 남아도 다음 보류 시각에 스스로 깬다 — 시각 없는 예전 보류는 15초.
        expect(
          await RawBackfillRuntime.nextDelay(store, {
            'state': 'holds',
            'run_id': 'run-h',
          }),
          const Duration(seconds: 15),
        );
        await items.reset('run-h', {
          'X': {'state': 'hold', 'attempts': 3, 'eligible': true},
          'Y': {'state': 'queued', 'attempts': 0, 'eligible': true},
        });
        expect(
          await RawBackfillRuntime.nextDelay(store, {
            'state': 'holds',
            'run_id': 'run-h',
          }),
          isNotNull,
          reason: '다른 일이 남아 있으면 계속 본다',
        );
        final now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
        expect(
          await RawBackfillRuntime.nextDelay(store, {
            'state': 'paused',
            'next_attempt_at': 1100,
          }, now: now),
          const Duration(seconds: 100),
        );
        expect(
          await RawBackfillRuntime.nextDelay(store, {
            'state': 'filling',
          }, yielded: true),
          const Duration(seconds: 3),
        );
      },
    );

    test(
      'a finished run is not touched again: no fresh-gate request, no lease',
      () async {
        await store.setMeta(
          'raw_backfill',
          jsonEncode({
            'state': 'done',
            'local_dataset_id': await store.localDatasetId(),
            'contributor_fingerprint': ctx['contributor_fingerprint'],
            'dataset_key': ctx['dataset_key'],
          }),
        );
        var verified = 0;
        final marker = await RawBackfillRuntime.run(
          store: store,
          verify: () async {
            verified++;
            return true;
          },
        );
        expect(marker!['state'], 'done');
        expect(verified, 0);
        // A retry request is the only thing that reopens it.
        await store.setMeta('raw_backfill_retry', 'true');
        SharedPreferences.setMockInitialValues({'appMode': 'server'});
        await RawBackfillRuntime.run(
          store: store,
          verify: () async {
            verified++;
            return true;
          },
        );
      },
    );

    test(
      'the list request is guarded: failure backs off, a login problem pauses',
      () async {
        final b = backend();
        await b.scope();
        RawBackfillRuntimeBackend.totalCountForTest = () async =>
            throw Exception('socket');
        final soft = await b.inventory();
        expect(soft['list_ok'], false);
        RawBackfillRuntimeBackend.totalCountForTest = () async =>
            throw Exception('HTTP 401');
        await expectLater(
          b.inventory(),
          throwsA(
            isA<BackfillPaused>().having(
              (e) => e.reason,
              'reason',
              'official_login_required',
            ),
          ),
        );
      },
    );
  });

  group('supplement values are normalised', () {
    test(
      'out-of-range rating and over-long title cannot reach the server as invalid',
      () async {
        final snapshot = rawSnapshot(
          jsonEncode(envelopeFor('R7')),
          '2026-10-21T00:00:00Z',
          'crawl',
          {'별점': 6, '별점사유': 'x' * 10050, '신고명': 'ㅎ' * 1200, '사진_촬영수': -1},
        );
        final supplement = snapshot['supplement'] as Map;
        expect(supplement['rating'], isNull);
        expect((supplement['rating_cause'] as String).runes.length, 10000);
        expect(
          ((supplement['list'] as Map)['title'] as String).runes.length,
          1000,
        );
        expect(supplement['photo_count'], isNull);
      },
    );
  });
}

/// Wraps the real adapter but supplies the inventory (the list request is the only thing replaced).
class _Listing implements RawBackfillBackend {
  _Listing(this.inner, this.ids);
  final RawBackfillRuntimeBackend inner;
  final List<String> ids;
  @override
  Future<Map<String, dynamic>?> scope() => inner.scope();
  @override
  Future<bool> current(Map<String, dynamic> scope) => inner.current(scope);
  @override
  Future<bool> optimizationReady() async => true;
  @override
  Future<Map<String, dynamic>> inventory() async => {
    'list_ok': true,
    'ids': ids,
    'eligible_ids': ids,
  };
  @override
  Future<List<String>> localIds() async => ids;
  @override
  Future<List<String>> eligibleIds() async => ids;
  @override
  Future<Map<String, dynamic>> prepare(String id) => inner.prepare(id);
  @override
  Future<String?> enqueue(String id, String run) => inner.enqueue(id, run);
  @override
  Future<String> receipt(String id, String event) => inner.receipt(id, event);
  @override
  Future<void> wakeUpload() async {}
}

/// Synthetic backend for volume: every report is local and answered, nothing needs the network.
class _Bulk implements RawBackfillBackend {
  _Bulk(this.ids);
  final List<String> ids;
  final enqueued = <String>[];
  bool stored = false;
  @override
  Future<Map<String, dynamic>?> scope() async => {
    'local_dataset_id': 'local',
    'contributor_fingerprint': 'fp',
    'dataset_key': 'ds',
    'consent_grant_id': 'g',
    'connection_id': 'c',
    'writer_epoch': 1,
    'parser_target': 'p',
  };
  @override
  Future<bool> current(Map<String, dynamic> scope) async => true;
  @override
  Future<bool> optimizationReady() async => true;
  @override
  Future<Map<String, dynamic>> inventory() async => {
    'list_ok': true,
    'ids': ids,
    'eligible_ids': ids,
  };
  @override
  Future<List<String>> localIds() async => ids;
  @override
  Future<List<String>> eligibleIds() async => ids;
  @override
  Future<Map<String, dynamic>> prepare(String id) async => {
    'eligible': true,
    'raw_unavailable': false,
    'filled': 0,
    'unfilled': 0,
  };
  @override
  Future<String?> enqueue(String id, String run) async {
    enqueued.add(id);
    return 'e-$id';
  }

  @override
  Future<String> receipt(String id, String event) async =>
      stored ? 'stored' : 'pending';
  @override
  Future<void> wakeUpload() async {}
}
