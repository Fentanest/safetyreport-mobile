import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/upload_hooks.dart';
import 'package:safetyreport/community/capture/server_completed.dart'
    as completed;
import '../community/fake_account.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/pending_db_import_action.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CommunityStore store;
  final realKakao = LocalDbService.currentKakaoId;
  final realBackupDirectory = LocalDbService.accountBackupDirectory;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('official_binding_');
    await databaseFactory.setDatabasesPath(dir.path);
    LocalDbService.accountBackupDirectory = () => dir;
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'account-a',
    });
    FlutterSecureStorage.setMockInitialValues({});
    LocalDbService.currentKakaoId = () async => '910001';
    store = await CommunityStore.open();
    await LocalDbService.prepareOfficialAccountChange(resetRequired: false);
    await (await LocalDbService.db).insert('reports', {
      'ID': 'a-1',
      '신고번호': 'SPP-A1',
      'category': 'traffic',
    });
    await store.setContext({
      'dataset_key': datasetKeyForOfficialId('account-a'),
    });
  });

  tearDown(() async {
    LocalDbService.accountBackupDirectory = realBackupDirectory;
    StandaloneAuthService.stopKeepAlive();
    LocalDbService.currentKakaoId = realKakao;
    await LocalDbService.closeDb();
    await CommunityStore.closeForTest(store.path);
    await dir.delete(recursive: true);
  });

  Future<List<String>> ids() async => [
    for (final row in await (await LocalDbService.db).query('reports'))
      row['ID'] as String,
  ];
  Future<String> backup({String? key, bool unknown = false}) async {
    final path =
        '${dir.path}/backup-${DateTime.now().microsecondsSinceEpoch}.db';
    await LocalDbService.exportBackup(path);
    final d = await openDatabase(path, singleInstance: false);
    if (unknown) {
      await d.delete(
        'sync_meta',
        where: 'key=?',
        whereArgs: ['official_account_key'],
      );
    } else if (key != null) {
      await d.insert('sync_meta', {
        'key': 'official_account_key',
        'value': key,
      });
    }
    await d.close();
    return path;
  }

  test(
    'same normalized settings account preserves reports and dataset without storing official identity',
    () async {
      final dataset = await store.localDatasetId();
      final provider = ReportProvider();
      await provider.init();
      addTearDown(provider.dispose);
      await provider.prepareStandaloneAccount(' ACCOUNT-A ');
      expect(await LocalDbService.getMeta('official_account_key'), isNull);
      expect(await ids(), ['a-1']);
      expect(await store.localDatasetId(), dataset);
      await LocalDbService.requireAccountChangeComplete();
    },
  );

  for (final unknown in [false, true]) {
    test(
      'backup ${unknown ? 'missing official key' : 'other official account'} accepted for same Kakao owner',
      () async {
        final file = await backup(
          key: datasetKeyForOfficialId('account-b'),
          unknown: unknown,
        );
        final dataset = await store.localDatasetId();
        await (await LocalDbService.db).insert('reports', {
          'ID': 'newer',
          'category': 'other',
        });
        await LocalDbService.replaceFromBackup(file);
        expect(await ids(), ['a-1']);
        expect(await store.localDatasetId(), isNot(dataset));
        expect(await store.activeContext(), isNull);
        expect(await LocalDbService.latestImportBackup(), isNotNull);
      },
    );
  }

  test(
    'same Kakao backup restores without official metadata; previous DB can be restored',
    () async {
      final file = await backup();
      await (await LocalDbService.db).insert('reports', {
        'ID': 'a-2',
        'category': 'other',
      });
      await LocalDbService.replaceFromBackup(file);
      expect(await ids(), ['a-1']);
      final before = await LocalDbService.latestImportBackup();
      expect(before, isNotNull);
      await LocalDbService.replaceFromBackup(before!);
      expect(await ids(), containsAll(['a-1', 'a-2']));
    },
  );

  test('final publication refuses account changing after validation', () async {
    final file = await backup();
    var checks = 0;
    LocalDbService.currentKakaoId = () async =>
        ++checks <= 2 ? '910001' : '910002';
    await expectLater(
      LocalDbService.replaceFromBackup(file),
      throwsA(isA<ForeignDatabaseException>()),
    );
    expect(await ids(), ['a-1']);
  });

  test(
    'local reports without official metadata remain usable; legacy mismatch is ignored',
    () async {
      final dataset = await store.localDatasetId();
      await LocalDbService.prepareOfficialAccountChange(resetRequired: false);
      await LocalDbService.requireAccountChangeComplete();
      expect(await ids(), ['a-1']);
      await LocalDbService.setMeta(
        'official_account_key',
        datasetKeyForOfficialId('account-b'),
      );
      await LocalDbService.prepareOfficialAccountChange(resetRequired: false);
      await LocalDbService.requireAccountChangeComplete();
      expect(await ids(), ['a-1']);
      expect(await store.localDatasetId(), dataset);
    },
  );

  test(
    'provider account change requires confirmation; rotates, deactivates and clears reports/watchlist',
    () async {
      final provider = ReportProvider()..releaseOfficialAccount = () async {};
      await provider.init();
      addTearDown(provider.dispose);
      final dataset = await store.localDatasetId();
      await LocalDbService.setWatchlistNumbers({'SPP-A1'});
      await expectLater(
        provider.setStandaloneConfig(
          'account-b',
          phoneNumber: '01000000000',
          confirmAccountReset: () async => false,
        ),
        throwsA(isA<ForeignDatabaseException>()),
      );
      expect(provider.standaloneUsername, 'account-a');
      expect(await ids(), ['a-1']);
      expect(await store.localDatasetId(), dataset);
      await provider.setStandaloneConfig(
        'account-b',
        phoneNumber: '01000000000',
        confirmAccountReset: () async => true,
      );
      expect(await ids(), isEmpty);
      expect(await LocalDbService.getWatchlistNumbers(), isEmpty);
      expect(await LocalDbService.getMeta('official_account_key'), isNull);
      expect(await LocalDbService.dbOwner(), '910001');
      expect(await store.localDatasetId(), isNot(dataset));
      expect(await store.activeContext(), isNull);
      expect(provider.standaloneUsername, 'account-b');
      expect(
        jsonDecode((await store.meta('dataset_history'))!).last['reason'],
        'official_account_change',
      );
    },
  );

  test(
    'prepared account change before import is not repeated during config activation',
    () async {
      final file = await backup(key: datasetKeyForOfficialId('account-a'));
      var releases = 0;
      final provider = ReportProvider()
        ..releaseOfficialAccount = () async {
          releases++;
        };
      await provider.init();
      addTearDown(provider.dispose);
      await provider.prepareStandaloneAccount(
        'account-b',
        confirmAccountReset: () async => true,
      );
      expect(await ids(), isEmpty);
      await PendingDbImportAction.save(CopyMobileBackupAction(file));
      final result = await PendingDbImportAction.applyPending(
        onFailure: (_, e) async => fail('$e'),
      );
      expect(result.status, PendingDbImportStatus.applied);
      await provider.setStandaloneConfig(
        ' ACCOUNT-B ',
        phoneNumber: '01000000000',
        confirmAccountReset: () async =>
            fail('already prepared account must not reset imported data'),
      );
      expect(await ids(), ['a-1']);
      expect(releases, 1);
      expect(
        await LocalDbService.getMeta(LocalDbService.officialRestartKey),
        'true',
      );
    },
  );

  test(
    'wired provider backs up, releases server, rotates, then registers new account',
    () async {
      final provider = ReportProvider();
      await provider.init();
      final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
      String? remote = datasetKeyForOfficialId('account-a');
      final server = FakeAccountServer(
        status: () =>
            statusJson()..['official_account'] = {'dataset_key': remote},
      );
      server.onDelete = () {
        remote = null;
      };
      final gate = CommunityGate(
        auth: auth,
        store: store,
        accountClient: server.accountClient(),
        configStatus: () => 'ok',
        appMode: () => provider.appMode.name,
        officialAccountId: () async => provider.standaloneUsername,
        datasetGeneration: () => provider.accountConfigEpoch,
        checkAccountChangeComplete: LocalDbService.requireAccountChangeComplete,
        checkDataOwner: ownerOk,
        deviceLabel: () => 'Test',
      );
      provider.officialAccountNeedsReset = gate.officialAccountNeedsReset;
      provider.releaseOfficialAccount = gate.releaseOfficialAccount;
      provider.addListener(gate.onAppModeChanged);
      var wasOpen = false;
      gate.addListener(() {
        final blocked = wasOpen && !gate.canEnter;
        wasOpen = gate.canEnter;
        if (blocked) provider.onGateBlocked();
      });
      CommunityUploadHooks.beginDeletion = () =>
          completed.beginDeletion(store: store);
      CommunityUploadHooks.confirmDeletion = () =>
          completed.confirmDeletion(store: store);
      CommunityUploadHooks.onContributionsDeleted = () =>
          completed.applyPendingDeletion(store: store);
      addTearDown(() {
        provider.removeListener(gate.onAppModeChanged);
        provider.dispose();
        gate.dispose();
        CommunityUploadHooks.beginDeletion = null;
        CommunityUploadHooks.confirmDeletion = null;
        CommunityUploadHooks.onContributionsDeleted = null;
      });
      await gate.refreshNow();
      expect(gate.canEnter, isTrue);
      final previousDataset = await store.localDatasetId();
      await provider.setStandaloneConfig(
        'account-b',
        phoneNumber: '01000000000',
        confirmAccountReset: () async => true,
      );
      await gate.refreshNow();
      expect(gate.canEnter, isTrue);
      expect(provider.standaloneUsername, 'account-b');
      expect(await ids(), isEmpty);
      expect(await store.localDatasetId(), isNot(previousDataset));
      expect(
        (await store.activeContext())?['dataset_key'],
        datasetKeyForOfficialId('account-b'),
      );
      expect(server.count('/contributions-delete'), 1);
      final actions = server.requests
          .map((r) => r.url.path.split('/').last)
          .toList();
      expect(
        actions.lastIndexOf('connections'),
        greaterThan(actions.indexOf('contributions-delete')),
      );
      expect(
        await LocalDbService.getMeta(LocalDbService.officialRestartKey),
        'true',
      );
    },
  );

  test('backup is complete before central release and wipe', () async {
    await LocalDbService.setWatchlistNumbers({'SPP-A1'});
    var released = false;
    await LocalDbService.prepareOfficialAccountChange(
      resetRequired: true,
      confirmReset: () async => true,
      releaseBinding: () async {
        final backups = dir
            .listSync()
            .whereType<File>()
            .where(
              (f) => f.path.split('/').last.startsWith('standalone_backup_'),
            )
            .toList();
        expect(backups, hasLength(1));
        final saved = await openDatabase(
          backups.single.path,
          singleInstance: false,
        );
        expect((await saved.query('reports')).single['ID'], 'a-1');
        expect(
          (await saved.query(
            'sync_meta',
            where: 'key=?',
            whereArgs: ['official_account_key'],
          )),
          isEmpty,
        );
        expect(
          (await saved.rawQuery('PRAGMA integrity_check')).single.values.single,
          'ok',
        );
        await saved.close();
        expect(await ids(), ['a-1']);
        released = true;
      },
    );
    expect(released, isTrue);
    expect(await ids(), isEmpty);
    expect(
      await LocalDbService.getMeta(LocalDbService.officialRestartKey),
      'true',
    );
  });

  test(
    'backup failure never calls central release or removes personal data',
    () async {
      final file = File('${dir.path}/not-a-directory')
        ..writeAsStringSync('synthetic');
      LocalDbService.accountBackupDirectory = () => Directory(file.path);
      var released = false;
      await expectLater(
        LocalDbService.prepareOfficialAccountChange(
          resetRequired: true,
          confirmReset: () async => true,
          releaseBinding: () async {
            released = true;
          },
        ),
        throwsA(anything),
      );
      expect(released, isFalse);
      expect(await ids(), ['a-1']);
      expect(
        await LocalDbService.getMeta(LocalDbService.officialChangePendingKey),
        isNull,
      );
    },
  );

  test(
    'uncertain central release preserves DB and persists block across reopen; retry completes',
    () async {
      await expectLater(
        LocalDbService.prepareOfficialAccountChange(
          resetRequired: true,
          confirmReset: () async => true,
          releaseBinding: () async =>
              throw StateError('synthetic lost response'),
        ),
        throwsStateError,
      );
      expect(await ids(), ['a-1']);
      await LocalDbService.closeDb();
      await expectLater(
        LocalDbService.requireAccountChangeComplete(),
        throwsA(isA<ForeignDatabaseException>()),
      );
      expect(
        await LocalDbService.getMeta(LocalDbService.officialChangePendingKey),
        'true',
      );
      await LocalDbService.prepareOfficialAccountChange(
        resetRequired: true,
        confirmReset: () async => true,
        releaseBinding: () async {},
      );
      expect(await ids(), isEmpty);
      expect(
        await LocalDbService.getMeta(LocalDbService.officialChangePendingKey),
        isNull,
      );
    },
  );

  test(
    'remote mismatch resets even when candidate matches current settings',
    () async {
      await LocalDbService.prepareOfficialAccountChange(
        resetRequired: true,
        confirmReset: () async => true,
        releaseBinding: () async {},
      );
      expect(await ids(), isEmpty);
      expect(await store.activeContext(), isNull);
    },
  );

  test(
    'demo prefs still check real database when entering live account',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await LocalDbService.closeDb();
      await prefs.setBool(AppPrefsKeys.standaloneDemoMode, true);
      await (await LocalDbService.db).insert('reports', {
        'ID': 'demo-1',
        'category': 'traffic',
      });
      await LocalDbService.prepareOfficialAccountChange(
        resetRequired: true,
        confirmReset: () async => true,
        releaseBinding: () async {},
      );
      expect(await ids(), ['demo-1']);
      await LocalDbService.closeDb();
      await prefs.setBool(AppPrefsKeys.standaloneDemoMode, false);
      expect(await ids(), isEmpty);
    },
  );

  test('account cannot change while confirmation is open', () async {
    await expectLater(
      LocalDbService.prepareOfficialAccountChange(
        resetRequired: true,
        confirmReset: () async {
          LocalDbService.currentKakaoId = () async => '910002';
          return true;
        },
      ),
      throwsA(isA<ForeignDatabaseException>()),
    );
    expect(await ids(), ['a-1']);
  });

  test(
    'pending import after reset requires Kakao reauth, then succeeds before official config activation',
    () async {
      final file = await backup();
      final provider = ReportProvider()..releaseOfficialAccount = () async {};
      await provider.init();
      addTearDown(provider.dispose);
      await PendingDbImportAction.save(CopyMobileBackupAction(file));
      await provider.resetConfig();
      // resetConfig really removes the session. A direct import at this point fails closed.
      LocalDbService.currentKakaoId = realKakao;
      expect(await CommunityAuthService.instance.currentKakaoId(), isNull);
      final refused = await PendingDbImportAction.applyPending(
        onFailure: (_, error) async {
          expect(error, isA<ForeignDatabaseException>());
          return null;
        },
      );
      expect(refused.status, PendingDbImportStatus.kept);
      // The root's onboarding precedes Setup. Model its successful reauthentication.
      LocalDbService.currentKakaoId = () async => '910001';
      expect(
        (await SharedPreferences.getInstance()).getString(
          AppPrefsKeys.standaloneUsername,
        ),
        isNull,
      );
      final applied = await PendingDbImportAction.applyPending(
        onFailure: (_, e) async => fail('$e'),
      );
      expect(applied.status, PendingDbImportStatus.applied);
      expect(await PendingDbImportAction.read(), isNull);
      expect(await ids(), ['a-1']);
      await provider.setStandaloneConfig(
        'account-a',
        phoneNumber: '01000000000',
      );
      expect(await ids(), ['a-1']);
      expect(provider.standaloneUsername, 'account-a');
    },
  );

  test(
    'pending import accepts different official account with same Kakao owner before settings activation',
    () async {
      final file = await backup(key: datasetKeyForOfficialId('account-b'));
      await PendingDbImportAction.save(DetectAndApplyDbFileAction(file));
      final applied = await PendingDbImportAction.applyPending(
        onFailure: (_, e) async => fail('$e'),
      );
      expect(applied.status, PendingDbImportStatus.applied);
      expect(await PendingDbImportAction.read(), isNull);
      expect(await ids(), ['a-1']);
    },
  );
}
