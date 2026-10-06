import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/community/upload_hooks.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/screens/cloud_unavailable_screen.dart';
import 'package:safetyreport/screens/setup_screen.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StubAuthService auth;
  late FakeAccountServer server;
  late Map<String, Object?> status;
  var localId = 'account-a';
  var epoch = 0;

  setUp(() {
    setUpSecureStorage();
    SharedPreferences.setMockInitialValues({});
    auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    status = statusJson()
      ..['official_account'] = {
        'dataset_key': datasetKeyForOfficialId('account-a'),
        'bound_at': null,
      };
    server = FakeAccountServer(status: () => status);
    localId = 'account-a';
    epoch = 0;
  });

  CommunityGate gate({String mode = 'standalone'}) {
    final g = CommunityGate(
      config: testAuthConfig(),
      auth: auth,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => mode,
      officialAccountId: () async => localId,
      datasetGeneration: () => epoch,
      checkDataOwner: ownerOk,
      deviceLabel: () => 'Test device',
      platformName: () => 'android',
    );
    addTearDown(g.dispose);
    return g;
  }

  test(
    'same normalized account enters; mismatch blocks before registration',
    () async {
      localId = ' ACCOUNT-A ';
      final g = gate();
      expect((await g.refreshNow()).canEnter, isTrue);
      localId = 'account-b';
      expect((await g.refreshNow()).state, 'official_account_mismatch');
      expect(g.canEnter, isFalse);
      expect(server.count('/connections'), 1);
    },
  );

  test(
    'old server missing field skips comparison; null is unbound; malformed blocks',
    () async {
      final g = gate();
      status.remove('official_account');
      expect((await g.refreshNow()).canEnter, isTrue);
      status['official_account'] = {'dataset_key': null, 'bound_at': null};
      expect((await g.refreshNow()).canEnter, isTrue);
      status['official_account'] = {'dataset_key': 123};
      expect((await g.refreshNow()).state, 'cloud_unavailable');
      expect(g.canEnter, isFalse);
    },
  );

  for (final code in ['official_account_mismatch', 'official_account_taken']) {
    test(
      'connections 409 $code blocks entry and displays Korean recovery',
      () async {
        status['official_account'] = {'dataset_key': null};
        server.registerThrows = {
          'code': code,
          'message': 'untrusted server wording',
        };
        final g = gate();
        expect((await g.refreshNow()).state, code);
        expect(g.canEnter, isFalse);
        expect(g.notice, officialAccountErrorMessage(code));
        if (code.endsWith('taken')) expect(g.notice, contains('운영자에게 문의'));
      },
    );
  }

  for (final mode in ['standalone', 'server', 'demo']) {
    test(
      '$mode requires Kakao session and blocks cloud failure after authentication',
      () async {
        auth.setPhase(CommunityAccountPhase.disconnected);
        final g = gate(mode: mode);
        expect((await g.refreshNow()).canEnter, isFalse);
        expect(server.statusCalls, 0);
        auth.setPhase(CommunityAccountPhase.connected);
        await g.refreshNow();
        expect(g.canEnter, isTrue);
        server.statusFailures = 1;
        expect((await g.refreshNow()).state, 'cloud_unavailable');
        expect(g.canEnter, isFalse);
      },
    );
  }

  test(
    'fresh success cache cannot bypass subsequent network failure',
    () async {
      final g = gate();
      expect((await g.refreshNow()).canEnter, isTrue);
      server.statusFailures = 1;
      expect((await g.refreshNow(silent: true)).state, 'cloud_unavailable');
      expect(g.canEnter, isFalse);
      expect((await g.retryCloud()).canEnter, isTrue);
      expect(server.accountClient().timeout, const Duration(seconds: 30));
    },
  );

  testWidgets(
    'cloud page retries 3 times at increasing intervals and manual retry recovers',
    (tester) async {
      final g = gate(mode: 'server');
      server.statusFailures = 10;
      await tester.runAsync(g.refreshNow);
      await tester.pumpWidget(
        MaterialApp(home: CloudUnavailableScreen(gate: g)),
      );
      expect(find.text(CommunityGate.cloudUnavailableMessage), findsOneWidget);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
      final first = server.statusCalls;
      // runAsync starts the first retry on real time; reschedule within fake time.
      await tester.tap(find.text('재시도'));
      await tester.pumpAndSettle();
      final manual = server.statusCalls;
      expect(manual, first + 1);
      for (final seconds in [2, 5, 10]) {
        await tester.pump(Duration(seconds: seconds));
        await tester.pumpAndSettle();
      }
      expect(server.statusCalls, manual + 3);
      await tester.pump(const Duration(seconds: 30));
      expect(server.statusCalls, manual + 3);
      server.statusFailures = 0;
      await tester.tap(find.text('재시도'));
      await tester.pumpAndSettle();
      expect(g.canEnter, isTrue);
    },
  );

  testWidgets('foreground return and five minute poll compare account again', (
    tester,
  ) async {
    final g = gate();
    await g.refreshNow();
    g.startPolling();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    final before = server.statusCalls;
    status['official_account'] = {
      'dataset_key': datasetKeyForOfficialId('account-b'),
    };
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(server.statusCalls, before + 1);
    expect(g.state.state, 'official_account_mismatch');
    status['official_account'] = {
      'dataset_key': datasetKeyForOfficialId('account-a'),
    };
    g.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(g.canEnter, isTrue);
    g.stopPolling();
  });

  test(
    'late response from previous configuration cannot unlock current mismatch',
    () async {
      final g = gate();
      final delayed = Completer<void>();
      server.statusDelay = delayed.future;
      final previous = g.refreshNow();
      epoch++;
      localId = 'account-b';
      g.onAppModeChanged();
      delayed.complete();
      await previous;
      await g.refreshNow();
      expect(g.canEnter, isFalse);
      expect(g.state.state, 'official_account_mismatch');
    },
  );

  test(
    'candidate check precedes delete, release ack required, then new connections',
    () async {
      final g = gate();
      CommunityUploadHooks.beginDeletion = () async => 'delete-1';
      CommunityUploadHooks.confirmDeletion = () async {};
      CommunityUploadHooks.onContributionsDeleted = () async => true;
      addTearDown(() {
        CommunityUploadHooks.beginDeletion = null;
        CommunityUploadHooks.confirmDeletion = null;
        CommunityUploadHooks.onContributionsDeleted = null;
      });
      expect(await g.officialAccountNeedsReset('account-b'), isTrue);
      expect(server.count('/connections'), 0);
      server.deleteResponse = {}; // 구서버의 삭제 성공은 바인딩 해제 증거가 아니다.
      await expectLater(
        g.releaseOfficialAccount(),
        throwsA(isA<CommunityAccountError>()),
      );
      expect(g.canEnter, isFalse);
      await g.refreshNow();
      expect(server.count('/connections'), 0);
      server.deleteResponse = {'official_account_released': true};
      server.onDelete = () =>
          status['official_account'] = {'dataset_key': null};
      await g.releaseOfficialAccount();
      localId = 'account-b';
      epoch++;
      g.onAppModeChanged();
      await g.refreshNow();
      expect(g.canEnter, isTrue);
      expect(server.count('/contributions-delete'), 2);
      expect(server.count('/connections'), 1);
      expect(server.requests.last.url.path, endsWith('/connections'));
    },
  );

  testWidgets('recovery updates server notice without dropping login input', (
    tester,
  ) async {
    Widget app(String notice) => MaterialApp(
      home: SetupScreen(
        initialMode: AppMode.standalone,
        accountRecovery: true,
        initialNotice: notice,
      ),
    );
    await tester.pumpWidget(app('계정 불일치'));
    await tester.enterText(find.byType(TextField).first, 'account-b');
    await tester.pumpWidget(app('운영자에게 문의해 주세요.'));
    expect(find.text('운영자에게 문의해 주세요.'), findsOneWidget);
    expect(find.text('계정 불일치'), findsNothing);
    expect(find.text('account-b'), findsOneWidget);
  });

  testWidgets('account recovery has no route back to modes or demo', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SetupScreen(
          initialMode: AppMode.standalone,
          accountRecovery: true,
          initialNotice: '바인딩된 계정으로 로그인해 주세요.',
        ),
      ),
    );
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    expect(find.text('Demo 보기'), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '모드 선택으로 돌아가기',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('안전신문고 로그인'), findsOneWidget);
  });
}
