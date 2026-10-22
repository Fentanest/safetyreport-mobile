// 1회 전송 재개(2026-10-22, CLIENT-RULES 1~3절): 오류 분류·일시적 오류 paused·고정적 3회 보류·보류 자동 재시도·
// 업로드 확인 retry → 보류·보류만 남은 run 깨우기·첫 실행 1회 초기화·채우기 slice 끝 업로더 깨우기·점검 중 멈춤.
// 네트워크 없음. 시각은 주입한다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/community/backfill_errors.dart';
import 'package:safetyreport/community/backfill_store.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/raw_backfill.dart';
import 'package:safetyreport/community/raw_backfill_runtime.dart';
import 'package:safetyreport/community/raw_backfill_unstick.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../scripts/check_raw_backfill.dart' as offline;
import 'uploader_test.dart' as u;

/// 공유 FixtureBackend + 오류 주입(예외 객체 그대로)·업로더 깨우기 수.
class Backend extends offline.FixtureBackend {
  Object? Function(String id)? failWith;
  int wakes = 0;
  @override
  Future<Map<String, dynamic>> prepare(String id) async {
    final error = failWith?.call(id);
    if (error != null) throw error;
    return super.prepare(id);
  }

  @override
  Future<void> wakeUpload() async => wakes++;
}

class Harness {
  Harness(this.backend, {this.items});
  final Backend backend;
  final BackfillItems? items;
  Map<String, dynamic>? saved;
  int time = 1000000;
  Map<String, Object?>? pause;
  Future<Map<String, dynamic>> run({int budget = 20, bool retry = false}) async =>
      (await RawBackfill(
        load: () async => saved == null
            ? null
            : (jsonDecode(jsonEncode(saved)) as Map).cast<String, dynamic>(),
        save: (m, s) async => saved = m,
        backend: backend,
        items: items,
        maintenance: () async => pause,
        now: () => DateTime.fromMillisecondsSinceEpoch(time * 1000),
      ).run(budget: budget, retryHolds: retry))!;
  Map<String, dynamic> item(String id) =>
      ((saved!['items'] as Map)[id] as Map).cast<String, dynamic>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classify_backfill_error (CLIENT-RULES 1절 표)', () {
    final vectors = <(Object, String, String?)>[
      (const SocketException('reset'), 'transient', 'network'),
      (const HandshakeException('tls'), 'transient', 'network'),
      (http.ClientException('closed'), 'transient', 'network'),
      (TimeoutException('slow'), 'transient', 'timeout'),
      (Exception('상세 조회 실패 (R1, 503)'), 'transient', 'server_5xx'),
      (Exception('상세 조회 실패 (R1, 500)'), 'transient', 'server_5xx'),
      (Exception('목록 조회 실패 (429)'), 'transient', 'rate_limited'),
      (Exception('네트워크 오류 (3회 재시도 실패): x'), 'transient', 'network'),
      (BackfillTransient('no_result'), 'transient', 'no_result'),
      (BackfillPaused('sync_busy'), 'transient', 'sync_busy'),
      (
        Exception('DatabaseException(database is locked (code 5 SQLITE_BUSY))'),
        'transient',
        'db_locked',
      ),
      (BackfillTransient('maintenance'), 'transient', 'maintenance'),
      (const FormatException('bad'), 'fixed', null),
      (TypeError(), 'fixed', null),
      (RangeError('r'), 'fixed', null),
      (StateError('missing_report'), 'fixed', null),
      (StateError('raw_event_not_created'), 'fixed', null),
      (Exception('상세 조회 실패 (R1, 404)'), 'fixed', null),
      (Exception('something else'), 'fixed', null),
      (ArgumentError('x'), 'fixed', null),
    ];
    for (final (error, kind, reason) in vectors) {
      test('$error → $kind', () {
        expect(classifyBackfillError(error), kind);
        expect(transientBackfillReason(error), reason);
      });
    }
    test('intervals', () {
      expect([1, 2, 3, 4, 9].map(transientBackoffSeconds), [
        60,
        300,
        900,
        3600,
        3600,
      ]);
      expect([1, 2, 3, 4, 7].map(holdBackoffSeconds), [
        900,
        3600,
        21600,
        86400,
        86400,
      ]);
    });
  });

  group('2-2 transient errors pause the run', () {
    test('40 seconds of transient errors: no hold, run paused, attempts untouched', () async {
      final b = Backend()..failWith = (_) => const SocketException('down');
      final h = Harness(b);
      final start = h.time;
      var m = await h.run();
      while (h.time - start <= 40) {
        m = await h.run();
        h.time += 5;
      }
      expect(m['state'], 'paused');
      expect(m['reason'], 'network');
      expect((m['stats'] as Map)['holds'], 0);
      expect(h.item('A')['attempts'], 0);
      expect(m['cursor'], 0, reason: '커서는 그 신고에 머문다');
      // Backoff grows only with consecutive transient failures: 60 → 300.
      expect(m['next_attempt_at'], closeTo(start + 60, 1));
      h.time = start + 61;
      m = await h.run();
      expect(m['transient_failures'], 2);
      expect(m['next_attempt_at'], closeTo(h.time + 300, 1));
      // Recovery resets the counter.
      b.failWith = null;
      h.time += 301;
      m = await h.run();
      expect(m['transient_failures'], 0);
      expect(m['state'], 'uploading');
    });
  });

  group('2-2 fixed errors hold, holds retry by themselves', () {
    test('three fixed errors → hold with next_attempt_at; time passes → pending again', () async {
      final b = Backend()
        ..failWith = (id) => id == 'A' ? StateError('parse') : null;
      final h = Harness(b);
      var m = await h.run();
      m = await h.run();
      m = await h.run();
      expect(m['state'], 'holds');
      final held = h.item('A');
      expect(held['state'], 'hold');
      expect(held['hold_count'], 1);
      expect(held['next_attempt_at'], h.time + 900);
      expect(held['first_held_at'], h.time);
      expect(held['stale'], false);
      // Not yet due: still held.
      h.time += 600;
      m = await h.run();
      expect(h.item('A')['state'], 'hold');
      // Due: back to pending with attempts 2 — one more failure holds again (1 hour).
      h.time += 301;
      m = await h.run();
      expect(h.item('A')['state'], 'hold');
      expect(h.item('A')['hold_count'], 2);
      expect(h.item('A')['next_attempt_at'], h.time + 3600);
      // Due again and the error is gone: the report goes out.
      b.failWith = null;
      h.time += 3601;
      m = await h.run();
      expect(h.item('A')['state'], 'queued');
      expect(m['state'], 'uploading');
    });

    test('30 days after the first hold the hold is marked stale and keeps retrying daily', () async {
      final b = Backend()
        ..failWith = (id) => id == 'A' ? StateError('parse') : null;
      final h = Harness(b);
      for (var i = 0; i < 3; i++) {
        await h.run();
      }
      final first = h.item('A')['first_held_at'] as int;
      for (var i = 0; i < 40 && h.time - first <= holdStaleSeconds; i++) {
        h.time = (h.item('A')['next_attempt_at'] as int) + 1;
        await h.run();
      }
      expect(h.item('A')['state'], 'hold');
      expect(h.item('A')['stale'], isTrue);
      expect(h.item('A')['next_attempt_at'], h.time + 86400);
    });

    test('the retry button releases every hold immediately', () async {
      final b = Backend()
        ..failWith = (id) => id == 'A' ? StateError('parse') : null;
      final h = Harness(b);
      for (var i = 0; i < 3; i++) {
        await h.run();
      }
      b.failWith = null;
      final m = await h.run(retry: true);
      expect(h.item('A')['state'], 'queued');
      expect(h.item('A')['hold_count'], 0);
      expect((m['stats'] as Map)['holds'], 0);
    });
  });

  group('2-2 upload receipts', () {
    test('three retry receipts → hold (upload_retry), blocked → not_eligible', () async {
      final b = Backend()..receipts = {'A': 'retry', 'B': 'blocked'};
      final h = Harness(b);
      var m = await h.run(); // fill all → uploading
      for (var i = 0; i < 6 && h.item('A')['state'] != 'hold'; i++) {
        m = await h.run();
      }
      expect(h.item('A')['state'], 'hold');
      expect(h.item('A')['error'], 'upload_retry');
      expect(h.item('A')['next_attempt_at'], isNotNull);
      expect(h.item('B')['state'], 'not_eligible');
      expect(h.item('B')['error'], 'upload_rejected');
      expect(m['state'], anyOf('holds', 'uploading'));
    });
  });

  group('2-4 the filling slice wakes the uploader', () {
    test('new queued reports in an unfinished filling slice → one wake', () async {
      final b = Backend();
      final h = Harness(b);
      await h.run(budget: 0); // listing only
      b.wakes = 0;
      final m = await h.run(budget: 2);
      expect(m['state'], 'filling');
      expect(b.wakes, 1);
      b.wakes = 0;
      await h.run(budget: 0);
      expect(b.wakes, 0, reason: '새로 queued 된 것이 없으면 깨우지 않는다');
    });
  });

  group('2-9 maintenance', () {
    test('a paused upload pauses the run without any work or attempt', () async {
      final b = Backend();
      final h = Harness(b)..pause = {'wake_at': 1000500};
      var m = await h.run();
      expect(m['state'], 'paused');
      expect(m['reason'], 'maintenance');
      expect(m['next_attempt_at'], 1000500);
      expect(b.enqueued, isEmpty);
      // No resume time: no timer of its own.
      h.pause = {'wake_at': null};
      m = await h.run();
      expect(m['next_attempt_at'], 0);
      // Resumed early (status said so): the run continues right away.
      h.pause = null;
      m = await h.run();
      expect(m['state'], 'uploading');
    });
  });

  group('runtime with the item store', () {
    late CommunityStore store;
    setUpAll(() {
      sqfliteFfiInit();
    });
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await u.openStore();
    });
    tearDown(() => u.closeStore(store));

    test('2-2 holds-only run wakes at the earliest hold time (15 s floor, 24 h cap)', () async {
      final items = SqliteBackfillItems(store, () async {});
      final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
      await items.reset('run-h', {
        'X': {'state': 'hold', 'attempts': 3, 'eligible': true, 'next_attempt_at': 1000900},
        'Y': {'state': 'hold', 'attempts': 3, 'eligible': true, 'next_attempt_at': 1003600},
        'Z': {'state': 'stored', 'attempts': 0, 'eligible': true},
      });
      expect(
        await RawBackfillRuntime.nextDelay(store, {'state': 'holds', 'run_id': 'run-h'}, now: now),
        const Duration(seconds: 900),
      );
      await items.reset('run-h', {
        'X': {'state': 'hold', 'attempts': 3, 'eligible': true, 'next_attempt_at': 999000},
      });
      expect(
        await RawBackfillRuntime.nextDelay(store, {'state': 'holds', 'run_id': 'run-h'}, now: now),
        const Duration(seconds: 15),
      );
      await items.reset('run-h', {
        'X': {'state': 'hold', 'attempts': 3, 'eligible': true, 'next_attempt_at': 1000000 + 90000},
      });
      expect(
        await RawBackfillRuntime.nextDelay(store, {'state': 'holds', 'run_id': 'run-h'}, now: now),
        const Duration(hours: 24),
      );
      expect(
        await RawBackfillRuntime.nextDelay(store, {'state': 'paused', 'reason': 'maintenance', 'next_attempt_at': 0}),
        isNull,
        reason: '점검 중에는 자기 타이머가 없다',
      );
    });

    test('sqlite store: release, retry and stale counts', () async {
      final items = SqliteBackfillItems(store, () async {});
      await items.reset('r', {
        'A': {'state': 'hold', 'attempts': 3, 'eligible': true, 'hold_count': 1, 'next_attempt_at': 100, 'first_held_at': 50},
        'B': {'state': 'hold', 'attempts': 3, 'eligible': true, 'hold_count': 4, 'next_attempt_at': 5000000, 'first_held_at': 0},
        'C': {'state': 'stored', 'attempts': 0, 'eligible': true},
      });
      expect(await items.releaseDueHolds('r', 4000000), 1);
      final page = {for (final (_, id, i) in await items.page('r', 0, 10)) id: i};
      expect(page['A']!['state'], 'pending');
      expect(page['A']!['attempts'], 2);
      expect(page['A']!['hold_count'], 1);
      expect(page['B']!['state'], 'hold');
      expect(page['B']!['stale'], isTrue);
      final counts = await items.stateCounts('r');
      expect(counts['holds'], 1);
      expect(counts['stale_holds'], 1);
      expect(counts['pending'], 1);
      expect(counts['stored'], 1);
      expect(counts['total'], 3);
      await items.retry('r');
      final after = {for (final (_, id, i) in await items.page('r', 0, 10)) id: i};
      expect(after['B']!['state'], 'pending');
      expect(after['B']!['attempts'], 0);
      expect(after['B']!['hold_count'], 0);
      expect(after['B']!['stale'], false);
      expect(after['B']!.containsKey('next_attempt_at'), isFalse);
    });

    Future<Map<String, dynamic>> marker() async =>
        (jsonDecode((await store.meta('raw_backfill'))!) as Map).cast<String, dynamic>();

    Future<void> seed(Map<String, Object?> m, Map<String, Map<String, dynamic>> rows) async {
      await SqliteBackfillItems(store, () async {}).reset(m['run_id'] as String, rows);
      await store.setMeta('raw_backfill', jsonEncode(m));
    }

    Map<String, Map<String, dynamic>> rows() => {
      'H': {'state': 'hold', 'attempts': 3, 'eligible': true, 'hold_count': 2, 'next_attempt_at': 9e9, 'stale': true, 'first_held_at': 1},
      'U': {'state': 'not_eligible', 'attempts': 3, 'eligible': false, 'error': 'upload_rejected'},
      'D': {'state': 'not_eligible', 'attempts': 0, 'eligible': false, 'error': 'deleted'},
      'S': {'state': 'stored', 'attempts': 0, 'eligible': true},
      'Q': {'state': 'queued', 'attempts': 0, 'eligible': true, 'event_id': 'e'},
    };

    test('2-3 unstick: holds and upload_rejected come back, done reopens, runs once', () async {
      await seed({'run_id': 'run-1', 'state': 'done', 'phase': 'uploading', 'cursor': 5, 'listing_complete': true}, rows());
      expect(await unstickRawBackfill(store), 2);
      final items = {for (final (_, id, i) in await SqliteBackfillItems(store, () async {}).page('run-1', 0, 10)) id: i};
      expect(items['H']!['state'], 'pending');
      expect(items['H']!['attempts'], 0);
      expect(items['H']!['hold_count'], 0);
      expect(items['H']!['stale'], false);
      expect(items['H']!.containsKey('next_attempt_at'), isFalse);
      expect(items['U']!['state'], 'pending');
      expect(items['U']!['eligible'], true);
      expect(items['U']!.containsKey('error'), isFalse);
      expect(items['D']!['state'], 'not_eligible', reason: '다른 사유의 제외는 그대로');
      expect(items['S']!['state'], 'stored');
      expect(items['Q']!['state'], 'queued');
      final m = await marker();
      expect(m['state'], 'filling');
      expect(m['phase'], 'filling');
      expect(m['cursor'], 0);
      expect(await store.meta(rawBackfillUnstickKey), rawBackfillUnstickVersion);
      // Second run: nothing changes.
      await SqliteBackfillItems(store, () async {}).put('run-1', 'H', {'state': 'hold', 'attempts': 3, 'eligible': true});
      expect(await unstickRawBackfill(store), isNull);
      final again = {for (final (_, id, i) in await SqliteBackfillItems(store, () async {}).page('run-1', 0, 10)) id: i};
      expect(again['H']!['state'], 'hold');
    });

    test('2-3 unstick: done without reverted items stays done; holds reopens', () async {
      await seed({'run_id': 'run-2', 'state': 'done', 'phase': 'uploading', 'cursor': 1}, {
        'S': {'state': 'stored', 'attempts': 0, 'eligible': true},
      });
      expect(await unstickRawBackfill(store), 0);
      expect((await marker())['state'], 'done');
    });

    test('2-3 unstick: holds marker with a hold reopens filling', () async {
      await seed({'run_id': 'run-3', 'state': 'holds', 'phase': 'uploading', 'cursor': 2}, {
        'H': {'state': 'hold', 'attempts': 3, 'eligible': true},
      });
      expect(await unstickRawBackfill(store), 1);
      expect((await marker())['state'], 'filling');
    });

    test('2-3 unstick: paused clears the wait unless a manual official login is needed', () async {
      await seed({'run_id': 'run-4', 'state': 'paused', 'reason': 'network', 'phase': 'filling', 'next_attempt_at': 9e9, 'transient_failures': 4, 'failures': 2}, {
        'H': {'state': 'hold', 'attempts': 3, 'eligible': true},
      });
      await unstickRawBackfill(store);
      final m = await marker();
      expect(m['state'], 'paused');
      expect(m['next_attempt_at'], 0);
      expect(m['transient_failures'], 0);
      expect(m['failures'], 0);
    });

    test('2-3 unstick: manual official login pause is kept', () async {
      await store.setMeta(rawLoginManualKey, '1');
      await seed({'run_id': 'run-5', 'state': 'paused', 'reason': 'official_login_required', 'phase': 'filling', 'next_attempt_at': 9e9}, {});
      await unstickRawBackfill(store);
      expect((await marker())['next_attempt_at'], 9e9);
    });

    test('2-3 unstick: other running states are left as they are; no run only writes the mark', () async {
      await seed({'run_id': 'run-6', 'state': 'uploading', 'phase': 'uploading', 'cursor': 3}, {
        'U': {'state': 'not_eligible', 'attempts': 3, 'eligible': false, 'error': 'upload_rejected'},
      });
      expect(await unstickRawBackfill(store), 1);
      final m = await marker();
      expect(m['state'], 'uploading');
      expect(m['cursor'], 3);
    });

    test('2-3 unstick: without a run only the mark is written', () async {
      expect(await unstickRawBackfill(store), 0);
      expect(await store.meta('raw_backfill'), isNull);
      expect(await store.meta(rawBackfillUnstickKey), rawBackfillUnstickVersion);
    });
  });

  test('pending reports left behind an uploading run go back to filling', () async {
    final items = MemoryBackfillItems();
    final b = Backend();
    final h = Harness(b, items: items);
    var m = await h.run();
    expect(m['state'], 'uploading');
    // A reverted (unstick-like) pending item while the run is uploading.
    items.items['A']!.addAll({'state': 'pending', 'attempts': 0});
    h.saved!['items'] = items.items;
    m = await h.run();
    expect(m['phase'], anyOf('filling', 'uploading'));
    m = await h.run();
    expect(items.items['A']!['state'], 'queued');
  });
}
