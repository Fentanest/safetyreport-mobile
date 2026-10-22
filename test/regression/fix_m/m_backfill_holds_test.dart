// FIX-M 회귀 시험: 1회 전송의 신고별 일시적 오류 상한(D1), 보류 횟수 유지(D2), 보류+확인 대기 깨움 간격(R1-3).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/backfill_errors.dart';
import 'package:safetyreport/community/backfill_store.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/raw_backfill.dart';
import 'package:safetyreport/community/raw_backfill_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../scripts/check_raw_backfill.dart' as offline;
import '../../community/uploader_test.dart' as u;

/// 신고마다 던질 예외를 고를 수 있는 backend.
class _Backend extends offline.FixtureBackend {
  final Map<String, Object Function()> errors = {};

  @override
  Future<Map<String, dynamic>> prepare(String id) async {
    final e = errors[id];
    if (e != null) throw e();
    return super.prepare(id);
  }
}

class _Runner {
  _Runner(this.backend);
  final offline.FixtureBackend backend;
  final items = MemoryBackfillItems();
  Map<String, dynamic>? saved;
  var t = 1000000;

  Future<Map<String, dynamic>> run() async => (await RawBackfill(
    load: () async => saved == null
        ? null
        : (jsonDecode(jsonEncode(saved)) as Map).cast<String, dynamic>(),
    save: (m, s) async => saved = m,
    backend: backend,
    items: items,
    now: () => DateTime.fromMillisecondsSinceEpoch(t * 1000),
  ).run(budget: 20))!;

  Map<String, dynamic> item(String id) => items.items[id]!;
}

void main() {
  group('D1 신고별 일시적 오류 상한', () {
    test('같은 신고가 연속 5번 일시적 오류면 그 신고만 보류하고 뒤 신고를 처리한다', () async {
      final backend = _Backend()
        ..errors['A'] = () => BackfillTransient('no_result');
      final r = _Runner(backend);
      final seen = <String>[];
      for (var i = 0; i < 10 && r.items.items['A']?['state'] != 'hold'; i++) {
        final m = await r.run();
        seen.add('${m['state']}/${m['reason']}');
        r.t += 3601; // 다음 시도 시각을 넘긴다
      }
      // 앞의 4번은 run 이 쉬고(커서 그대로), 5번째에 A 만 보류하고 B·C 로 넘어간다.
      expect(seen, hasLength(5));
      expect(seen.take(4), everyElement('paused/no_result'));
      final a = r.item('A');
      expect(a['state'], 'hold');
      expect(a['hold_count'], 1);
      expect(a['error'], 'transient_no_result');
      expect(a.containsKey(transientAttemptsKey), isFalse);
      expect(r.item('B')['state'], 'queued');
      expect(r.item('C')['state'], 'queued');
      // 다른 신고가 성공했으므로 run 의 연속 일시적 횟수는 0.
      expect(r.saved!['transient_failures'], 0);
    });

    test('다른 작업의 잠금·DB 잠김·로그인 사유는 신고 탓이 아니라 세지 않는다', () async {
      for (final error in <Object Function()>[
        () => BackfillPaused('sync_busy'),
        () => Exception('database is locked'),
        () => BackfillPaused('official_login_retry'),
      ]) {
        final backend = _Backend()..errors['A'] = error;
        final r = _Runner(backend);
        for (var i = 0; i < 10; i++) {
          await r.run();
          r.t += 3601;
        }
        expect(r.item('A')['state'], 'pending', reason: '${error()}');
        expect(r.item('A').containsKey(transientAttemptsKey), isFalse);
        expect(r.item('B')['state'], 'pending');
      }
    });

    test('성공하면 그 신고의 연속 횟수는 0 부터 다시 센다', () async {
      final backend = _Backend()
        ..errors['A'] = () => BackfillTransient('server_5xx');
      final r = _Runner(backend);
      for (var i = 0; i < 4; i++) {
        await r.run();
        r.t += 3601;
      }
      expect(r.item('A')[transientAttemptsKey], 4);
      backend.errors.clear();
      await r.run();
      expect(r.item('A')['state'], 'queued');
      expect(r.item('A').containsKey(transientAttemptsKey), isFalse);
    });
  });

  group('D2 보류 횟수 유지', () {
    test('업로드 확인 retry 로 생긴 보류도 hold_count 를 이어 올리고 first_held_at 은 고정, stored 때만 지운다', () async {
      final backend = _Backend()..receipts['A'] = 'retry';
      backend.receipts['B'] = 'stored';
      backend.receipts['C'] = 'stored';
      final r = _Runner(backend);
      // 보류에서 풀림 → 채우기 → 확인 retry → 다시 보류가 한 run 안에서 일어날 수 있으므로 hold_count 변화로 센다.
      final holds = <(int, int)>[];
      for (var i = 0; i < 400 && holds.length < 4; i++) {
        await r.run();
        final a = r.item('A');
        final count = a['hold_count'] as int?;
        if (a['state'] == 'hold' &&
            (holds.isEmpty || holds.last.$1 != count)) {
          holds.add((count!, a['first_held_at'] as int));
        }
        r.t += 600;
      }
      expect(holds.map((h) => h.$1), [1, 2, 3, 4]);
      expect(holds.map((h) => h.$2).toSet(), hasLength(1),
          reason: 'first_held_at 은 처음 보류된 때로 남는다');
      // 이제 서버가 저장했다고 답한다 → stored 가 되면 보류 이력을 지운다.
      backend.receipts['A'] = 'stored';
      for (var i = 0; i < 400 && r.item('A')['state'] != 'stored'; i++) {
        await r.run();
        r.t += 3600;
      }
      final a = r.item('A');
      expect(a['state'], 'stored');
      for (final k in ['hold_count', 'first_held_at', 'next_attempt_at', 'stale']) {
        expect(a.containsKey(k), isFalse, reason: k);
      }
    });

    test('보류에서 풀린 신고가 채우기에 성공해도 hold_count 를 지우지 않는다', () async {
      final backend = _Backend()..errors['A'] = () => StateError('parse');
      final r = _Runner(backend);
      for (var i = 0; i < 3; i++) {
        await r.run();
        r.t += 30;
      }
      expect(r.item('A')['state'], 'hold');
      final first = r.item('A')['first_held_at'];
      backend.errors.clear();
      r.t += 16 * 60;
      await r.run();
      expect(r.item('A')['state'], 'queued');
      expect(r.item('A')['hold_count'], 1);
      expect(r.item('A')['first_held_at'], first);
    });
  });

  group('R1-3 보류 + 확인 대기 깨움 간격', () {
    late CommunityStore store;
    setUpAll(sqfliteFfiInit);
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await u.openStore();
    });
    tearDown(() => u.closeStore(store));

    test('보류 1건 + queued 만 남으면 15초가 아니라 min(보류 시각, 10분)', () async {
      final backend = offline.FixtureBackend()..fail = {'A'};
      Map<String, dynamic>? saved;
      var t = 1000000;
      Future<Map<String, dynamic>> run() async => (await RawBackfill(
        load: () async => saved == null
            ? null
            : (jsonDecode(jsonEncode(saved)) as Map).cast<String, dynamic>(),
        save: (m, s) async => saved = m,
        backend: backend,
        items: SqliteBackfillItems(store, () async {}),
        now: () => DateTime.fromMillisecondsSinceEpoch(t * 1000),
      ).run(budget: 20))!;
      Map<String, dynamic> m = {};
      for (var i = 0; i < 10; i++) {
        m = await run();
        t += 30;
      }
      expect(m['state'], 'holds');
      expect((m['stats'] as Map)['queued'], 2);
      final items = SqliteBackfillItems(store, () async {});
      final holdAt = (await items.nextHoldAt(m['run_id'] as String))!;
      Future<Duration?> delayAt(int at) => RawBackfillRuntime.nextDelay(
        store,
        m,
        now: DateTime.fromMillisecondsSinceEpoch(at * 1000),
      );
      // 보류 시각이 10분보다 멀면 10분.
      expect(holdAt - t, greaterThan(600));
      expect(await delayAt(t), RawBackfillRuntime.holdsWaitingWake);
      // 보류 시각이 가까우면 그 시각(15초 하한).
      expect(await delayAt(holdAt - 200), const Duration(seconds: 200));
      expect(await delayAt(holdAt - 3), const Duration(seconds: 15));
    });
  });
}
