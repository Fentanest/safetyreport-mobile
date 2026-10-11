// schedule catchUp·게이트 캐시 테스트 (순수 벡터는 contract_vectors_test).
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/upload/community_schedule.dart';
import 'package:safetyreport/community/upload/community_uploader.dart';

Future<CommunityStore> openStore() async {
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('sr_t6_sched_');
  final store = await CommunityStore.open(
    path: '${dir.path}/community.db',
    factory: databaseFactoryFfi,
  );
  await store.setContext({
    'contributor_fingerprint': 'fp1',
    'connection_id': '11111111-1111-4111-8111-111111111111',
    'writer_epoch': 1,
    'dataset_key': 'ds1',
    'consent_grant_id': '22222222-2222-4222-8222-222222222222',
    'policy_version': '2026-09-28.1',
    'consent_text_sha256': 'abc',
    'source_app': 'safetyreport-mobile',
    'source_mode': 'standalone',
  });
  return store;
}

Future<void> closeStore(CommunityStore store) async {
  final path = store.path;
  await store.db.close();
  await CommunityStore.closeForTest(path);
  try {
    await Directory(File(path).parent.path).delete(recursive: true);
  } catch (_) {}
}

void main() {
  group('catchUp', () {
    late CommunityStore store;
    setUp(() async => store = await openStore());
    tearDown(() async => closeStore(store));

    test('첫 실행은 midnight 업로드를 한 번 실행한다', () async {
      var triggers = <String>[];
      final state = await catchUp(
        'os',
        store: store,
        runUpload: (t) async {
          triggers.add(t);
          return const UploadRunResult(
            runId: 'r1',
            result: 'sent',
            counts: {'sent': 2},
          );
        },
        now: DateTime.utc(2026, 9, 26, 3),
      );
      expect(state, equals('succeeded'));
      expect(triggers, equals(['midnight']));
      final rows = await store.db.rawQuery('SELECT state FROM schedule_runs');
      expect(rows.first['state'], equals('succeeded'));
    });

    test('succeeded 키는 다시 실행하지 않는다', () async {
      var calls = 0;
      Future<UploadRunResult> run(String t) async {
        calls++;
        return const UploadRunResult(runId: 'r', result: 'sent');
      }

      final now = DateTime.utc(2026, 9, 26, 3);
      await catchUp('os', store: store, runUpload: run, now: now);
      final again = await catchUp('os', store: store, runUpload: run, now: now);
      expect(again, equals('succeeded'));
      expect(calls, equals(1));
    });

    test('context 없으면 deferred', () async {
      await store.deactivateContext('test');
      final state = await catchUp(
        'os',
        store: store,
        runUpload: (t) async =>
            const UploadRunResult(runId: 'r', result: 'sent'),
        now: DateTime.utc(2026, 9, 26, 3),
      );
      expect(state, equals('deferred'));
    });
  });

  test(
    'midnight key is succeeded only for sent/no_pending (PC run_midnight 와 같음)',
    () {
      for (final r in ['sent', 'no_pending']) {
        expect(midnightState(r), 'succeeded', reason: r);
      }
      for (final r in [
        'not_due',
        'cooldown',
        'busy_other_run',
        'needs_auth',
        'needs_consent',
        'blocked_gate',
        'more_pending',
      ]) {
        expect(midnightState(r), 'deferred', reason: r);
      }
      expect(midnightState('failed'), 'failed');
      expect(midnightState('partial'), 'failed');
    },
  );

  group('gate cache', () {
    test('ok + 600초 이내만 true', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      expect(await isGateCacheFresh(prefs, now), isFalse);
      await prefs.setString(
        'community_gate_cache_v1',
        '{"state":"ok","verified_at":${now.millisecondsSinceEpoch}}',
      );
      expect(await isGateCacheFresh(prefs, now), isTrue);
      expect(
        await isGateCacheFresh(prefs, now.add(const Duration(seconds: 601))),
        isFalse,
      );
      await prefs.setString(
        'community_gate_cache_v1',
        '{"state":"consent_required","verified_at":${now.millisecondsSinceEpoch}}',
      );
      expect(await isGateCacheFresh(prefs, now), isFalse);
    });
  });

  group('cloudRecoveryDelay (결함 2: 과거 마감이면 즉시 재등록하지 않고 최소 지연)', () {
    test('마감이 미래면 그 차이를 그대로 쓴다', () {
      final now = DateTime.utc(2026, 10, 7);
      expect(
        cloudRecoveryDelay(now.add(const Duration(seconds: 120)), now),
        const Duration(seconds: 120),
      );
    });

    test(
      '마감이 지금(또는 과거)이면 최소 지연(cloudRecoveryMinDelay)을 쓴다 — probe 진행 중 로컬 재실행 루프 방지',
      () {
        final now = DateTime.utc(2026, 10, 7);
        // 수정 전에는 delay=0(즉시 REPLACE 재등록)이었다 — 이 시험은 그 값에서 실패한다.
        expect(cloudRecoveryDelay(now, now), cloudRecoveryMinDelay);
        expect(
          cloudRecoveryDelay(now.subtract(const Duration(seconds: 1)), now),
          cloudRecoveryMinDelay,
        );
        expect(
          cloudRecoveryDelay(now.subtract(const Duration(minutes: 10)), now),
          cloudRecoveryMinDelay,
        );
      },
    );
  });

  group('자정 one-off 기기별 분산 오프셋(④: 0~1800초, 설치 한 번만 뽑아 영속)', () {
    test('처음 한 번만 무작위로 뽑고, 이후에는 영속된 값을 그대로 쓴다', () async {
      SharedPreferences.setMockInitialValues({});
      final first = await midnightOffsetSeconds(random: _FixedIntRandom(900));
      expect(first, 900);
      expect(first, inInclusiveRange(0, communityMidnightOffsetMaxSeconds));
      // 두 번째 호출에 다른 난수를 줘도 이미 저장된 값을 그대로 돌려준다(기기별 고정).
      final second = await midnightOffsetSeconds(random: _FixedIntRandom(1234));
      expect(second, 900);
    });

    test('자정까지 남은 시간 + 오프셋만큼 지연하고, 결과가 음수면 0으로 바닥을 둔다', () {
      final now = DateTime.utc(2026, 10, 7, 12); // KST 21시 — 다음 자정까지 아직 남음
      final dueDelay = nextDueAt(now).difference(now);
      expect(
        midnightTaskDelay(now, 600),
        dueDelay + const Duration(seconds: 600),
      );
      expect(midnightTaskDelay(now, 0), dueDelay);
    });
  });
}

/// 매번 같은 값을 돌려주는 가짜 Random([midnightOffsetSeconds] 시험 전용 — 결정적 오프셋).
class _FixedIntRandom implements Random {
  _FixedIntRandom(this.value);
  final int value;
  @override
  int nextInt(int max) => value % max;
  @override
  double nextDouble() => 0.5;
  @override
  bool nextBool() => false;
}
