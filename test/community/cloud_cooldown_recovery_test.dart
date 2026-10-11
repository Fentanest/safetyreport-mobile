// 결함 1 회귀 (cloud-retry-brief): 쿨다운 마감 바로 그 순간 포그라운드 게이트와 WorkManager 복구가
// 함께 깨어나면, probe lease 를 못 잡은 쪽은 로컬에서 합성한 503 cloud_cooldown 을 받는다. 수정 전
// `CommunityGate._cloudUnavailable` 은 이 합성 응답도 `ensureCooldown()` 으로 새 쿨다운을 썼다 —
// probe 가 곧 성공해도 그 쪽이 기억한 마감(`at`)과 저장된 마감이 달라져 지우지 못해(107-113 의
// `current == isoUtc(at)` 비교) 회복이 5분+ 늦어졌다. 가짜 시계 + Completer 로 그 경합을 재현한다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/cloud_availability.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';

import 'fake_account.dart';
import 'fixed_random.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  setUp(() async {
    setUpSecureStorage();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('cloud_recovery_test_');
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

  test(
    '마감 직후 합성 cloud_cooldown 응답은 쿨다운을 새로 쓰지 않아, probe 성공과 함께 바로 회복한다',
    () async {
      final cfg = testAuthConfig();
      var clock = DateTime.utc(2026, 10, 7);
      CloudAvailability.shared = CloudAvailability(
        store,
        cfg.supabaseUrl,
        now: () => clock,
        random: const FixedRandom(),
      );

      // 1번째 실패로 첫 쿨다운을 만든다(n=1 → 300초, 지터 없음).
      await CloudAvailability.shared!.failed();
      final firstDeadline = await CloudAvailability.shared!.deadline();
      expect(firstDeadline, clock.add(const Duration(seconds: 300)));

      // 마감 시각에 정확히 도달 — 시간 기준으로는 더 이상 "쿨다운 중"이 아니다.
      clock = firstDeadline!;

      // "WorkManager 복구"가 먼저 probe lease 를 잡고 느린 네트워크 요청을 보내는 중이라고 한다.
      final releaseProbe = Completer<void>();
      final probeClient = CloudHttpClient(
        MockClient((r) async {
          await releaseProbe.future;
          return http.Response('{}', 200);
        }),
      );
      final probeFuture = probeClient.get(
        Uri.parse('${cfg.supabaseUrl}/auth/v1/user'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // 거의 같은 순간 포그라운드 게이트가 깨어나 상태를 다시 확인한다 — lease 를 못 잡아
      // 실제 서버에는 묻지도 못하고 로컬에서 합성한 cloud_cooldown(503) 을 받는다.
      final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
      var gateCalls = 0;
      final gateClient = MockClient((r) async {
        gateCalls++;
        return http.Response(jsonEncode(statusJson()), 200);
      });
      final gate = CommunityGate(
        checkDataOwner: ownerOk,
        config: cfg,
        auth: auth,
        store: store,
        httpClient: gateClient,
        configStatus: () => 'ok',
        appMode: () => 'standalone',
        officialAccountId: () async => 'official',
      );
      addTearDown(gate.dispose);

      final state = await gate.refreshNow();
      expect(state.state, 'cloud_unavailable');
      expect(gateCalls, 0, reason: '합성 cloud_cooldown 이면 실제 서버까지 가면 안 된다');

      // 결함 1 수정 전에는 여기서 ensureCooldown() 이 (지난 마감을 보고) 새 쿨다운을 써서
      // firstDeadline 보다 늦은 마감으로 덮어쓴다 — 이 비교에서 실패한다.
      expect(
        await CloudAvailability.shared!.deadline(),
        firstDeadline,
        reason: '합성 cloud_cooldown 응답은 쿨다운을 새로 쓰면 안 된다',
      );

      // 이제 WorkManager 쪽 probe 가 성공한다.
      releaseProbe.complete();
      await probeFuture;

      // probe 가 기억한 마감과 저장된 마감이 그대로 같으므로 바로 지워져 즉시 회복한다.
      expect(await CloudAvailability.shared!.coolingDown(), isFalse);
      expect(await CloudAvailability.shared!.deadline(), isNull);
    },
  );
}
