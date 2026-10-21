// 최종 모바일 검토(2026-10-21) 항목 3, 4, 5, 6, 8, 9 회귀 시험 — 원본 1회 전송 런타임.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/community_capture.dart' show mobileParserVersion;
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/raw_backfill.dart';
import 'package:safetyreport/community/raw_backfill_runtime.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/db_optimize.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/standalone_api_service.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'raw_backfill_review_test.dart' show seed;
import 'uploader_test.dart' as u;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dbDir;
  late CommunityStore store;
  late Map<String, Object?> ctx;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbDir = Directory.systemTemp.createTempSync('sr_final_backfill_');
    await databaseFactory.setDatabasesPath(dbDir.path);
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (dbDir.existsSync()) dbDir.deleteSync(recursive: true);
  });

  Future<void> markV2Ready() async {
    await store.setMeta(
      'ingest_status',
      jsonEncode({
        'consent': {
          'state': 'active',
          'grant_id': ctx['consent_grant_id'],
          'policy_version': ctx['policy_version'],
        },
        'ingest': {'contracts': [1, 2], 'raw_policy_version': ctx['policy_version']},
      }),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({AppPrefsKeys.appMode: 'standalone'});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    store = await u.openStore();
    ctx = (await store.activeContext())!;
    await markV2Ready();
    RawBackfillRuntimeBackend.totalCountForTest = null;
    StandaloneApiService.listForTest = null;
  });
  tearDown(() async {
    RawBackfillRuntimeBackend.totalCountForTest = null;
    StandaloneApiService.listForTest = null;
    RawBackfillRuntimeBackend.generalWorkRunning = () => false;
    RawBackfillRuntimeBackend.optimizeStarter = () {};
    await u.closeStore(store);
  });

  RawBackfillRuntimeBackend backend({
    Duration slice = const Duration(minutes: 5),
    bool background = false,
  }) => RawBackfillRuntimeBackend(
    store,
    () => true,
    slice: slice,
    background: background,
  );

  Future<void> setLogin(ReloginOutcome outcome) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppPrefsKeys.standaloneAuthLastAt, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(AppPrefsKeys.standaloneAuthLastOutcome, outcome.name);
    await prefs.setString(AppPrefsKeys.standaloneAuthLastMessage, '시험');
  }

  group('3. the list phase and a slow item are not cut by the foreground deadline', () {
    test('a list slower than 3x the slice completes in one attempt', () async {
      const total = 600;
      RawBackfillRuntimeBackend.totalCountForTest = () async => total;
      StandaloneApiService.listForTest = (start, end) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return {
          'totalCnt': total,
          'result': [for (var i = start; i <= end; i++) {'C_NO': '$i', 'C_NOW': 10}],
        };
      };
      final b = backend(slice: const Duration(milliseconds: 400));
      await b.scope();
      final result = await b.inventory();
      expect(result['list_ok'], true, reason: '목록 단계는 hard deadline 에 끊기지 않는다');
      expect((result['ids'] as List).length, total);
    });

    test('the scope stays current after 3x the slice (an item is never hard-cancelled)', () async {
      final b = backend(slice: const Duration(milliseconds: 20));
      final scope = (await b.scope())!;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(b.yieldRequested(), isTrue, reason: '양보 요청은 그대로 선다');
      expect(await b.current(scope), isTrue);
    });
  });

  group('4. an official login refusal stops until a manual login', () {
    Future<void> failAuth(RawBackfillRuntimeBackend b) async {
      RawBackfillRuntimeBackend.totalCountForTest = () async => throw const TokenExpiredException();
      await b.scope();
    }

    test('needsManualLogin: paused for an hour and flagged', () async {
      await setLogin(ReloginOutcome.rejected);
      final b = backend();
      await failAuth(b);
      await expectLater(
        b.inventory(),
        throwsA(isA<BackfillPaused>().having((e) => e.retrySeconds, 'retry', 3600)),
      );
      expect(await store.meta('raw_login_manual'), '1');
    });

    test('a transient failure backs off exponentially, at most one hour', () async {
      await setLogin(ReloginOutcome.transient);
      final waits = <int>[];
      for (var i = 0; i < 6; i++) {
        final b = backend();
        await failAuth(b);
        try {
          await b.inventory();
        } on BackfillPaused catch (e) {
          waits.add(e.retrySeconds);
        }
      }
      expect(waits, [300, 600, 1200, 2400, 3600, 3600]);
      expect(await store.meta('raw_login_manual'), isNull);
    });

    test('while paused for a manual login the runtime makes no official request; a login resumes it', () async {
      await setLogin(ReloginOutcome.rejected);
      await store.setMeta('raw_login_manual', '1');
      await store.setMeta(
        'raw_backfill',
        jsonEncode({
          'state': 'paused',
          'reason': 'official_login_required',
          'next_attempt_at': DateTime.now().millisecondsSinceEpoch / 1000 + 3000,
          'phase': 'listing',
          'listing_complete': false,
        }),
      );
      var asked = 0;
      RawBackfillRuntimeBackend.totalCountForTest = () async {
        asked++;
        return 0;
      };
      var verified = 0;
      Future<bool> verify() async {
        verified++;
        return true;
      }

      await RawBackfillRuntime.run(store: store, verify: verify, background: true);
      expect(asked, 0);
      expect(verified, 0, reason: '수동 로그인 전에는 게이트 확인도 하지 않는다');
      // The user logs in by hand: the status turns to success and the pause is lifted at once.
      await setLogin(ReloginOutcome.success);
      await DbOptimize.writeMeta({'target': mobileParserVersion, 'cursor': '', 'done': true, 'holds': <String>[]});
      await RawBackfillRuntime.run(store: store, verify: verify, background: true);
      expect(asked, 1);
      expect(await store.meta('raw_login_manual'), isNull);
    });
  });

  group('5/6/8. readiness', () {
    test('5: general sync / photo work running means not ready, and nothing is started', () async {
      RawBackfillRuntimeBackend.generalWorkRunning = () => true;
      var started = 0;
      RawBackfillRuntimeBackend.optimizeStarter = () => started++;
      expect(await backend().optimizationReady(), isFalse);
      expect(started, 0);
    });

    test('6: the background isolate never starts the optimizer; the foreground does', () async {
      var started = 0;
      RawBackfillRuntimeBackend.optimizeStarter = () => started++;
      expect(await DbOptimize.needsRun(), isTrue);
      expect(await backend(background: true).optimizationReady(), isFalse);
      expect(started, 0);
      expect(await backend().optimizationReady(), isFalse);
      expect(started, 1);
    });

    test('8: only held reports left (waiting for the retry time) counts as ready', () async {
      await DbOptimize.writeMeta({
        'target': mobileParserVersion,
        'cursor': '',
        'done': false,
        'holds': ['R9'],
        'attempts': <String, int>{},
        'next_retry_at': DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
      });
      var started = 0;
      RawBackfillRuntimeBackend.optimizeStarter = () => started++;
      expect(await DbOptimize.needsRun(), isTrue, reason: '최적화 자체는 아직 done 이 아니다');
      expect(await backend().optimizationReady(), isTrue);
      expect(started, 0);
      // A sweep still in progress (cursor left) is not ready.
      await DbOptimize.writeMeta({
        'target': mobileParserVersion,
        'cursor': 'R5',
        'done': false,
        'holds': ['R9'],
      });
      expect(await backend().optimizationReady(), isFalse);
    });
  });

  group('9. uploading phase polls slowly and reads receipts in one batch', () {
    test('delay is 60s while uploading, 15s while filling', () async {
      expect(
        await RawBackfillRuntime.nextDelay(store, {'state': 'uploading'}),
        const Duration(seconds: 60),
      );
      expect(
        await RawBackfillRuntime.nextDelay(store, {'state': 'filling'}),
        const Duration(seconds: 15),
      );
    });

    test('prefetched receipts match the per-event answer and are used without further queries', () async {
      await seed('R1');
      await seed('R2');
      await seed('R3');
      final b = backend();
      await b.scope();
      final events = <String>[];
      for (final id in ['R1', 'R2', 'R3']) {
        await b.prepare(id);
        events.add((await b.enqueue(id, 'run-1'))!);
      }
      // Reference answers from the per-event path.
      final single = [for (var i = 0; i < 3; i++) await b.receipt('R${i + 1}', events[i])];
      expect(single, ['pending', 'pending', 'pending']);
      await store.setMeta('raw_receipt:${events[0]}', 'stored');
      await store.db.update('outbox', {'state': 'blocked'}, where: 'event_id=?', whereArgs: [events[1]]);
      await b.prefetchReceipts(events);
      // Changing the database now must not matter: answers come from the one batch.
      await store.db.update('outbox', {'state': 'pending'}, where: 'event_id=?', whereArgs: [events[1]]);
      expect(await b.receipt('R1', events[0]), 'stored');
      expect(await b.receipt('R2', events[1]), 'blocked');
      expect(await b.receipt('R3', events[2]), 'pending');
      // The batch answer is consumed once; afterwards the normal path answers.
      expect(await b.receipt('R2', events[1]), 'pending');
    });
  });
}
