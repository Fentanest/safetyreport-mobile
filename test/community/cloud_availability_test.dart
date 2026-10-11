// CloudAvailability 쿨다운 지터(±20%) + 연속 실패 점증(300·2^(n-1), 상한 1800초, 성공 시 n=0) 회귀.
// cloud-retry-brief 공용 원칙 ①(PC 와 같은 식). isolate 간 공유는 같은 community.db(store)를 쓰는
// 서로 다른 CloudAvailability 인스턴스로 흉내 낸다(실제로는 포그라운드/WorkManager 가 각자 isolate).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/cloud_availability.dart';
import 'package:safetyreport/community/community_store.dart';

import 'fixed_random.dart';

const _url = 'https://proj.supabase.test';

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cloud_avail_test_');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(
      path: dbPath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    CloudAvailability.shared = null;
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  test('escalatedCooldownBaseSeconds: 300·2^(n-1), 상한 1800초', () {
    expect(escalatedCooldownBaseSeconds(1), 300);
    expect(escalatedCooldownBaseSeconds(2), 600);
    expect(escalatedCooldownBaseSeconds(3), 1200);
    expect(escalatedCooldownBaseSeconds(4), 1800); // 2400 → 상한
    expect(escalatedCooldownBaseSeconds(5), 1800);
    expect(escalatedCooldownBaseSeconds(100), 1800);
  });

  test('지터는 기준값의 ±20% 범위 안에서만 움직인다(균등)', () async {
    final clock = DateTime.utc(2026, 10, 7);
    final low = CloudAvailability(
      store,
      _url,
      now: () => clock,
      random: const FixedRandom(0.0),
    );
    await low.failed();
    expect(
      await low.deadline(),
      clock.add(const Duration(seconds: 240)), // 300 * 0.8
      reason: 'nextDouble()==0.0 → 지터 하한',
    );

    // 같은 store/URL 이라 마감이 남아있다 — 새 store 로 상한 지터를 따로 확인한다.
    final tmp2 = await Directory.systemTemp.createTemp('cloud_avail_test2_');
    addTearDown(() => tmp2.delete(recursive: true));
    final store2 = await CommunityStore.open(
      path: '${tmp2.path}/community.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(() => CommunityStore.closeForTest(store2.path));
    final high = CloudAvailability(
      store2,
      _url,
      now: () => clock,
      random: const FixedRandom(1.0),
    );
    await high.failed();
    expect(
      await high.deadline(),
      clock.add(const Duration(seconds: 360)), // 300 * 1.2
      reason: 'nextDouble()==1.0 → 지터 상한',
    );
  });

  test('연속 실패 점증은 같은 store 를 쓰는 다른 인스턴스(= isolate) 사이에 공유된다', () async {
    var clock = DateTime.utc(2026, 10, 7);
    final foreground = CloudAvailability(
      store,
      _url,
      now: () => clock,
      random: const FixedRandom(),
    );
    await foreground.failed(); // n=1 → 300초
    expect(await foreground.consecutiveFailures(), 1);
    expect(
      await foreground.deadline(),
      clock.add(const Duration(seconds: 300)),
    );

    clock = clock.add(const Duration(seconds: 301)); // 첫 쿨다운이 끝난 뒤
    // "다른 isolate" — 같은 store 를 새 인스턴스로 연다. 공유가 안 되면(수정 전) n 이 다시
    // 1부터 시작해 300초가 나온다 — 이 시험은 그 상태에서 실패한다.
    final background = CloudAvailability(
      store,
      _url,
      now: () => clock,
      random: const FixedRandom(),
    );
    await background.failed(); // n=2 → 600초
    expect(await background.consecutiveFailures(), 2);
    expect(
      await background.deadline(),
      clock.add(const Duration(seconds: 600)),
    );

    clock = clock.add(const Duration(seconds: 601));
    await foreground.failed(); // n=3 → 1200초(다시 foreground 인스턴스로)
    expect(await foreground.consecutiveFailures(), 3);
    expect(
      await foreground.deadline(),
      clock.add(const Duration(seconds: 1200)),
    );
  });

  test('성공하면 연속 실패 횟수가 0 으로 돌아가 다음 실패는 다시 300초부터 시작한다', () async {
    var clock = DateTime.utc(2026, 10, 7);
    final avail = CloudAvailability(
      store,
      _url,
      now: () => clock,
      random: const FixedRandom(),
    );
    CloudAvailability.shared = avail;
    await avail.failed(); // n=1
    clock = clock.add(const Duration(seconds: 301));
    await avail.failed(); // n=2 → 600초
    expect(await avail.consecutiveFailures(), 2);

    clock = clock.add(const Duration(seconds: 601)); // n=2 쿨다운도 지남
    final client = CloudHttpClient(
      MockClient((r) async => http.Response('{}', 200)),
    );
    await client.get(Uri.parse('$_url/auth/v1/user'));
    expect(await avail.consecutiveFailures(), 0, reason: '성공하면 n=0');
    expect(await avail.coolingDown(), isFalse);

    await avail.failed(); // 새 연속 실패: 다시 n=1 → 300초(점증이 이어지지 않는다)
    expect(await avail.consecutiveFailures(), 1);
    expect(await avail.deadline(), clock.add(const Duration(seconds: 300)));
  });

  test('서버 Retry-After 가 점증 기준보다 길면 그 값을 따르고(줄이지 않는다), 짧으면 점증값이 이긴다', () async {
    var clock = DateTime.utc(2026, 10, 7);
    final avail = CloudAvailability(
      store,
      _url,
      now: () => clock,
      random: const FixedRandom(),
    );
    await avail.failed(
      retryAfterSeconds: 50,
    ); // n=1: 점증 300 > Retry-After 50 → 300
    expect(await avail.deadline(), clock.add(const Duration(seconds: 300)));

    clock = clock.add(const Duration(seconds: 301));
    await avail.failed(
      retryAfterSeconds: 5000,
    ); // n=2: 점증 600 < Retry-After 5000 → 5000
    expect(await avail.deadline(), clock.add(const Duration(seconds: 5000)));
  });
}
