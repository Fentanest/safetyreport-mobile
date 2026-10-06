// Test-only Android entrypoint: never imported by lib/main.dart.
// Run only with SR_TEST_APPLICATION_ID=com.fentanest.mysafetyreport.bindingrc.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/upload_hooks.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/setup_screen.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/screens/cloud_unavailable_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import '../test/community/fake_account.dart';

class _Offline extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = (_, _, _) => Future.error(
          const SocketException('RC fixture blocks external network'),
        );
}

// Background jobs are outside this UI test. Gate, settings, SQLite and routes
// are production implementations; only authentication/HTTP are synthetic.
class _Provider extends ReportProvider {
  @override
  Future<void> onGatePassed() => refreshAll();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('official binding RC: real routes and Android SQLite', (
    tester,
  ) async {
    HttpOverrides.global = _Offline();
    final support = await getApplicationSupportDirectory();
    Future<void> capture(String name) async {
      // Confirmation dialogs can cover a continuously animated loading button.
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      final ack = File('${support.path}/$name.ack');
      if (await ack.exists()) await ack.delete();
      // Host takes adb exec-out screencap, then acknowledges the exact frame.
      debugPrint('SR_CAPTURE:$name');
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!await ack.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('capture $name');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await ack.delete();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await prefs.setString(AppPrefsKeys.appMode, 'standalone');
    await prefs.setString(AppPrefsKeys.standaloneUsername, 'account-a');
    await prefs.setString(AppPrefsKeys.standalonePhoneNumber, '01000000000');
    setUpSecureStorage();
    final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
    LocalDbService.currentKakaoId = () async => '910001';
    await LocalDbService.prepareOfficialAccountChange(resetRequired: false);
    final store = await CommunityStore.open();
    final provider = _Provider();
    await provider.init();
    var status = statusJson()
      ..['official_account'] = {
        'dataset_key': datasetKeyForOfficialId('account-a'),
        'bound_at': null,
      };
    final server = FakeAccountServer(status: () => status);
    final gate = CommunityGate(
      config: testAuthConfig(),
      auth: auth,
      accountClient: server.accountClient(),
      configStatus: () => 'ok',
      appMode: () => 'standalone',
      officialAccountId: () async => provider.standaloneUsername,
      datasetGeneration: () => provider.accountConfigEpoch,
      checkDataOwner: ownerOk,
      deviceLabel: () => 'RC fixture',
      platformName: () => 'android',
    );
    provider.officialAccountNeedsReset = gate.officialAccountNeedsReset;
    provider.releaseOfficialAccount = gate.releaseOfficialAccount;
    provider.addListener(gate.onAppModeChanged);
    CommunityUploadHooks.beginDeletion = () async => 'fixture-delete';
    CommunityUploadHooks.confirmDeletion = () async {};
    CommunityUploadHooks.onContributionsDeleted = () async => true;
    await gate.refreshNow();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportProvider>.value(value: provider),
          ChangeNotifierProvider<CommunityGate>.value(value: gate),
          ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
        ],
        child: const SafetyReportApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(gate.canEnter, isTrue);
    expect(find.byType(MainNavigationScreen), findsOneWidget);
    await capture('01-match-dashboard');

    // Seed a report only after fresh-install baseline was recorded.
    await (await LocalDbService.db).insert('reports', {
      'ID': 'fixture-a-1',
      '신고번호': 'SPP-FIXTURE-1',
      'category': 'traffic',
    });
    await LocalDbService.setWatchlistNumbers({'SPP-FIXTURE-1'});
    final same = '${support.path}/same-kakao-old-official.db';
    await LocalDbService.exportBackup(same);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    await tester.pumpAndSettle();
    status['official_account'] = {
      'dataset_key': datasetKeyForOfficialId('account-b'),
    };
    await gate.refreshNow();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.byType(MainNavigationScreen), findsNothing);
    await capture('02-mismatch-login');
    await capture(
      '02-mismatch-back',
    ); // host sends real Android BACK before capture
    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);

    status['official_account'] = {'dataset_key': null};
    server.registerThrows = {'code': 'official_account_taken'};
    await gate.refreshNow();
    await tester.pumpAndSettle();
    expect(find.textContaining('운영자에게 문의'), findsOneWidget);
    await capture('04-official-account-taken');
    server.registerThrows = null;
    server.statusFailures = 20;
    await gate.refreshNow();
    await tester.pumpAndSettle();
    expect(find.byType(CloudUnavailableScreen), findsOneWidget);
    final calls = server.statusCalls;
    await capture('05-cloud-offline');
    // Live binding uses real timers: explicitly wait through 2/5/10 second retries.
    await Future<void>.delayed(const Duration(seconds: 19));
    await tester.pumpAndSettle();
    expect(server.statusCalls, calls + 3);
    debugPrint('SR_ASSERT:auto-retry calls=${server.statusCalls - calls}');
    await capture('05-cloud-auto-retried');
    server.statusFailures = 0;
    status['official_account'] = {
      'dataset_key': datasetKeyForOfficialId('account-a'),
    };
    await tester.tap(find.text('재시도'));
    await tester.pumpAndSettle();
    expect(gate.canEnter, isTrue);
    expect(find.byType(MainNavigationScreen), findsOneWidget);
    await capture('05-cloud-manual-recovered');

    // Expire the official session and return through the actual recovery login.
    await StandaloneAuthService.clearToken();
    status['official_account'] = {
      'dataset_key': datasetKeyForOfficialId('account-b'),
    };
    await gate.refreshNow();
    await tester.pumpAndSettle();
    var verifiedBackup = false;
    server.onDelete = () {
      status['official_account'] = {'dataset_key': null};
    };
    // Check real exported SQLite snapshot before allowing central deletion.
    provider.releaseOfficialAccount = () async {
      final backups =
          LocalDbService.accountBackupDirectory()
              .listSync()
              .whereType<File>()
              .where(
                (f) =>
                    f.path.contains('standalone_backup_') &&
                    f.path.endsWith('.db'),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      final saved = await openDatabase(
        backups.last.path,
        singleInstance: false,
        readOnly: true,
      );
      expect((await saved.query('reports')).single['ID'], 'fixture-a-1');
      expect(
        (await saved.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      expect(
        await saved.query(
          'sync_meta',
          where: 'key=?',
          whereArgs: ['official_account_key'],
        ),
        isEmpty,
      );
      await saved.close();
      expect((await (await LocalDbService.db).query('reports')).length, 1);
      debugPrint(
        'SR_ASSERT:backup-before-release ${backups.last.path} integrity=ok rows=1 official-key=absent',
      );
      verifiedBackup = true;
      await gate.releaseOfficialAccount();
    };
    SetupScreen.standaloneLoginOverride = (_, _) async {};
    await tester.enterText(find.byType(TextField).at(0), 'account-c');
    await tester.enterText(find.byType(TextField).at(1), 'fixture-password');
    await tester.enterText(find.byType(TextField).at(2), '01000000000');
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '로그인'));
    await tester.tap(find.widgetWithText(FilledButton, '로그인'));
    for (
      var i = 0;
      i < 100 && find.text('안전신문고 계정별 자료 분리').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('안전신문고 계정별 자료 분리'), findsOneWidget);
    await capture('03-account-change-warning');
    await tester.tap(find.text('자료 비우고 계속'));
    await tester.pumpAndSettle();
    // Configuration invalidates cached gate state; repeat the real status check.
    await gate.refreshNow();
    await tester.pumpAndSettle();
    expect(verifiedBackup, isTrue);
    expect(await (await LocalDbService.db).query('reports'), isEmpty);
    expect(await LocalDbService.getMeta('watchlist'), isNull);
    expect(provider.standaloneUsername, 'account-c');
    expect(find.text('새 계정으로 시작'), findsOneWidget);
    await capture('03-account-change-new-start');
    await tester.tap(find.text('새 계정으로 시작'));
    await tester.pumpAndSettle();

    // File chooser is injected; confirmation, import, rejection and snackbars
    // are actual SettingsScreen code with real Android SQLite files.
    await (await LocalDbService.db).insert('reports', {
      'ID': 'fixture-restore',
      'category': 'traffic',
    });
    // The backup has no official ID: it predates account-c but same Kakao owns it.
    final foreign = '${support.path}/foreign-kakao.db';
    await File(same).copy(foreign);
    final otherDb = await openDatabase(foreign, singleInstance: false);
    await otherDb.update(
      'sync_meta',
      {'value': '910002'},
      where: 'key=?',
      whereArgs: [LocalDbService.kakaoMemberMetaKey],
    );
    await otherDb.close();
    var pickedPath = '';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
      (_) async => [
        {
          'name': pickedPath.split('/').last,
          'path': pickedPath,
          'size': await File(pickedPath).length(),
        },
      ],
    );
    nav.push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    await tester.pumpAndSettle();
    final restore = find.text('DB 복원 (업로드)');
    await tester.scrollUntilVisible(
      restore,
      450,
      scrollable: find.byType(Scrollable).first,
    );
    pickedPath = foreign;
    await tester.tap(restore);
    await tester.pumpAndSettle();
    await tester.tap(find.text('복원 시작'));
    await tester.pumpAndSettle();
    expect(find.textContaining('DB 복원 실패:'), findsOneWidget);
    expect(
      (await (await LocalDbService.db).query('reports')).single['ID'],
      'fixture-restore',
    );
    await capture('06-foreign-kakao-rejected');
    pickedPath = same;
    await tester.tap(restore);
    await tester.pumpAndSettle();
    await tester.tap(find.text('복원 시작'));
    await tester.pumpAndSettle();
    expect(find.text('모바일 백업 복원이 완료되었습니다.'), findsOneWidget);
    expect(await LocalDbService.getMeta('official_account_key'), isNull);
    expect(
      (await (await LocalDbService.db).query('reports')).single['ID'],
      'fixture-a-1',
    );
    await capture('06-same-kakao-accepted');
    debugPrint('SR_ASSERT:ALL_SIX_SCENARIOS_PASS');
    await tester.pumpWidget(const SizedBox.shrink());
    gate.dispose();
    provider.dispose();
    await LocalDbService.closeDb();
    await CommunityStore.closeForTest(store.path);
    binding.reportData = {'six_scenarios': 'pass'};
  }, timeout: const Timeout(Duration(minutes: 8)));
}
