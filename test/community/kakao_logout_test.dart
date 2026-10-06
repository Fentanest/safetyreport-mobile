// 카카오 로그아웃 = 이 기기의 신고 자료 삭제, 다른 계정 자료가 남은 기기의 "지우고 이 계정으로 시작" (2026-09-27 사용자 결정).
// PC web/routers/community_route.py 의 /logout·/db-owner/adopt 와 같은 규칙.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/kakao_logout.dart';
import 'package:safetyreport/screens/community_onboarding_screen.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';

import 'fake_account.dart';

class _CountingAuth extends StubAuthService {
  int disconnects = 0;

  @override
  Future<CommunityDisconnectResult> disconnect() async {
    disconnects++;
    return super.disconnect();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;
  late _CountingAuth auth;
  late FakeAccountServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    setUpSecureStorage();
    tmp = await Directory.systemTemp.createTemp('kakao_logout_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
    auth = _CountingAuth()..setPhase(CommunityAccountPhase.connected);
    server = FakeAccountServer();
  });

  tearDown(() async {
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  CommunityGate gateWith(Future<String> Function(String?) check, {String mode = 'standalone'}) {
    final gate = CommunityGate(
      checkDataOwner: check,
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => mode,
      officialAccountId: () async => 'User@Example.com',
    );
    addTearDown(gate.dispose);
    return gate;
  }

  testWidgets('unreadable DB offers session logout, preserves data and persists protection', (tester) async {
    bool? done;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(onPressed: () async {
        done = await KakaoLogout.confirmAndRun(context, gate: null, auth: auth,
          dbOwner: () async => throw StateError('database cannot open'),
          wipe: (_) async => fail('unverified data must never be wiped'),
        );
      }, child: const Text('test logout'));
    })));
    await tester.tap(find.text('test logout'));
    await tester.pumpAndSettle();
    expect(find.textContaining('자료는 그대로 보호하고'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '로그아웃'));
      for (var i = 0; done == null && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(auth.disconnects, 1);
    expect((await SharedPreferences.getInstance()).getBool(AppPrefsKeys.communityOwnerQuarantined), isTrue);
    expect(auth.state.value.phase, CommunityAccountPhase.disconnected);
  });

  test('logout keeps the data only when it is known to belong to another account', () async {
    final gate = gateWith(ownerOk);
    for (final (owner, session, wipes) in [
      ('910001', '910001', true),
      (null, '910001', true),
      ('910001', null, true),
      ('910002', '910001', false),
    ]) {
      auth.kakaoId = session;
      expect(
        await KakaoLogout.wipesData(gate: gate, auth: auth, dbOwner: () async => owner),
        wipes,
        reason: '$owner/$session',
      );
    }
    auth.kakaoId = '910001';
    await expectLater(
      KakaoLogout.wipesData(gate: gate, auth: auth, dbOwner: () async => throw StateError('disk')),
      throwsStateError,
      reason: '주인 표시를 읽지 못하면 "주인 없음"으로 보고 지우지 않는다 — 로그아웃하지 않음(Codex 검수 P1)',
    );
    for (final mode in ['server', 'demo']) {
      expect(
        await KakaoLogout.wipesData(gate: gateWith(ownerOk, mode: mode), auth: auth, dbOwner: () async => '910001'),
        isFalse,
        reason: '$mode: 이 기기에 지울 이 계정의 신고 자료가 없다',
      );
    }
  });

  test('logout wipes first, then logs out; a busy DB keeps everything and stays logged in', () async {
    final gate = gateWith(ownerOk);
    expect((await gate.refreshNow()).canEnter, isTrue);
    final order = <String>[];
    final ok = await KakaoLogout.run(
      gate: gate,
      auth: auth,
      wipes: true,
      wipe: (reason) async => order.add('wipe:$reason'),
      afterWipe: () async => order.add('refresh'),
    );
    expect(ok, isNull);
    expect(order, ['wipe:kakao_logout', 'refresh']);
    expect(auth.disconnects, 1);
    expect(gate.canEnter, isFalse);

    final busy = await KakaoLogout.run(
      gate: gate,
      auth: auth,
      wipes: true,
      wipe: (_) async => throw DbBusyException('동기화 중'),
    );
    expect(busy, '동기화 중');
    expect(auth.disconnects, 1, reason: '지우지 못했으면 로그아웃하지 않는다');

    await KakaoLogout.run(
      gate: gate,
      auth: auth,
      wipes: false,
      wipe: (_) async => fail('다른 계정의 자료는 지우지 않는다'),
    );
    expect(auth.disconnects, 2);
  });

  test('a pass in client or demo mode does not let the real standalone DB in until its owner is checked', () async {
    var mode = 'server';
    var owner = 'mismatch';
    final gate = CommunityGate(
      checkDataOwner: (_) async => owner,
      config: testAuthConfig(),
      auth: auth,
      store: store,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => mode,
      officialAccountId: () async => 'User@Example.com',
    );
    addTearDown(gate.dispose);
    expect((await gate.refreshNow()).canEnter, isTrue, reason: 'Client 는 기기 DB 주인을 보지 않는다');
    expect(gate.canEnter, isTrue);
    mode = 'standalone';
    expect(gate.canEnter, isFalse, reason: '다른 모드에서 받은 통과로 들어가지 않는다(Codex 검수 P1)');
    expect((await gate.requireFresh()).state, 'db_owner_mismatch', reason: '새 작업 전 확인도 다시 한다');
    mode = 'demo';
    // 데모는 메인 UI에서 직접 허용하며 업로드용 freshness를 얻지 않는다.
    expect((await gate.requireFresh()).state, 'demo_mode');
    mode = 'standalone';
    owner = 'ok';
    gate.onAppModeChanged();
    expect(gate.isChecked, isFalse, reason: '다시 확인하는 동안 신고 화면을 보이지 않는다');
    await gate.refreshNow();
    expect(gate.canEnter, isTrue);
  });

  test('adopt wipes with the current account as the new owner and re-checks the gate', () async {
    var owner = 'mismatch';
    final gate = gateWith((_) async => owner);
    expect((await gate.refreshNow()).state, 'db_owner_mismatch');
    final calls = <(String, String)>[];
    final error = await KakaoLogout.adopt(
      gate: gate,
      auth: auth,
      wipe: (reason, id) async {
        calls.add((reason, id));
        owner = 'ok';
      },
    );
    expect(error, isNull);
    expect(calls, [('db_owner_adopt', '910001')]);
    expect(gate.canEnter, isTrue);
    expect(await KakaoLogout.adopt(gate: gate, auth: auth, wipe: (_, _) async => fail('상태가 아닐 때는 지우지 않는다')),
        isNotNull);
  });

  testWidgets('onboarding shows the mismatch box with adopt and keep-data logout', (tester) async {
    late CommunityGate gate;
    await tester.runAsync(() async {
      gate = gateWith((_) async => 'mismatch');
      await gate.refreshNow();
    });
    expect(gate.state.state, 'db_owner_mismatch');
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider.value(
        value: gate,
        child: CommunityOnboardingScreen(
          gate: gate,
          auth: auth,
          accountClient: server.accountClient(),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const Key('communityOwnerMismatch')), findsOneWidget);
    expect(find.text('이 기기의 신고 내역은 다른 카카오 계정의 것입니다.'), findsOneWidget);
    expect(find.text('신고 내역 지우고 이 계정으로 시작'), findsOneWidget);
    expect(find.text('로그아웃(신고 내역 유지)'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('communityOwnerAdopt')));
    await tester.ensureVisible(find.byKey(const Key('communityOwnerAdopt')));
    await tester.tap(find.byKey(const Key('communityOwnerAdopt')));
    await tester.pumpAndSettle();
    expect(find.text('이 계정으로 새로 시작'), findsOneWidget, reason: '지우기 전에 확인받는다');
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(gate.state.state, 'db_owner_mismatch');
  });
}
