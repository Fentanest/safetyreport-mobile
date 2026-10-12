import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/screens/secure_storage_recovery_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/secure_storage_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Probe extends FlutterSecureStorage {
  _Probe({this.fail = false});
  final bool fail;
  int reads = 0;
  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    if (fail) throw Exception('keystore');
    return {
      'community_session_v1': 'synthetic-session',
      'community_connection_v1': 'synthetic-connection',
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'v10 marker preserves credentials and marker without a migration or native probe',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.secureStorageV10Migrated: true,
      });
      FlutterSecureStorage.setMockInitialValues({
        AppPrefsKeys.communitySession: 'synthetic',
        AppPrefsKeys.standalonePassword: 'synthetic-password',
      });
      expect(
        await SecureStorageMigration.checkReady(
          isAndroid: true,
          storedEntries: () async =>
              throw StateError('must not inspect migrated storage'),
        ),
        SecureStorageReadiness.ready,
      );
      expect(await const FlutterSecureStorage().readAll(), {
        AppPrefsKeys.communitySession: 'synthetic',
        AppPrefsKeys.standalonePassword: 'synthetic-password',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppPrefsKeys.secureStorageV10Migrated), isTrue);
      expect(
        prefs.containsKey(AppPrefsKeys.secureStorageV11Initialized),
        isFalse,
      );
    },
  );

  test(
    'v9 ESP or default storage without marker never opens or deletes storage',
    () async {
      final storage = _Probe();
      expect(
        await SecureStorageMigration.checkReady(
          storage: storage,
          isAndroid: true,
          storedEntries: () async => 3,
        ),
        SecureStorageReadiness.reauthenticationRequired,
      );
      expect(storage.reads, 0);
      expect(await SecureStorageMigration.isDone(), isFalse);
    },
  );

  test(
    'existing preferences with empty ciphertext still require explicit guidance',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'standalone',
      });
      final storage = _Probe();
      expect(
        await SecureStorageMigration.checkReady(
          storage: storage,
          isAndroid: true,
          storedEntries: () async => 0,
        ),
        SecureStorageReadiness.reauthenticationRequired,
      );
      expect(storage.reads, 0);
    },
  );

  test(
    'fresh install records only v11 marker after successful inspection',
    () async {
      expect(
        await SecureStorageMigration.checkReady(
          storage: _Probe(),
          isAndroid: true,
          storedEntries: () async => 0,
        ),
        SecureStorageReadiness.ready,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppPrefsKeys.secureStorageV11Initialized), isTrue);
      expect(prefs.containsKey(AppPrefsKeys.secureStorageV10Migrated), isFalse);
      expect(await SecureStorageMigration.isDone(), isTrue);
    },
  );

  test(
    'failed inspection and failed reads are errors, never empty-account success',
    () async {
      final storage = _Probe();
      expect(
        await SecureStorageMigration.checkReady(
          storage: storage,
          isAndroid: true,
          storedEntries: () async => -1,
        ),
        SecureStorageReadiness.unavailable,
      );
      expect(storage.reads, 0);
      expect(await SecureStorageMigration.isDone(), isFalse);
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.secureStorageV10Migrated: true,
      });
      expect(
        await SecureStorageMigration.checkReady(storage: _Probe(fail: true)),
        SecureStorageReadiness.unavailable,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(
          AppPrefsKeys.secureStorageV10Migrated,
        ),
        isTrue,
      );
    },
  );

  test(
    'iOS checks the unchanged Keychain and never claims v10 Android migration',
    () async {
      expect(
        await SecureStorageMigration.checkReady(
          storage: _Probe(),
          isAndroid: false,
        ),
        SecureStorageReadiness.ready,
      );
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          AppPrefsKeys.secureStorageV10Migrated,
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'missing marker explains reauthentication without delete or bypass',
    (tester) async {
      var exits = 0;
      await tester.pumpWidget(
        SecureStorageRecoveryApp(
          readiness: SecureStorageReadiness.reauthenticationRequired,
          exit: () async => exits++,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('재로그인과 커뮤니티 연결 재설정이 필요합니다'), findsOneWidget);
      expect(find.textContaining('지우고 계속'), findsNothing);
      await tester.tap(find.text('앱 종료'));
      expect(exits, 1);
    },
  );

  testWidgets('recovery guidance scrolls at narrow width and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SecureStorageRecoveryScreen(
            readiness: SecureStorageReadiness.reauthenticationRequired,
            exit: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('앱 종료').hitTestable(), findsOneWidget);
  });

  test(
    'background tasks do not open either storage before readiness marker',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: AppMode.standalone.name,
      });
      var opened = false;
      expect(
        await runCommunityUploadTask(
          'community-upload-periodic',
          openStore: () async {
            opened = true;
            return null;
          },
        ),
        isTrue,
      );
      expect(opened, isFalse);
      expect(await BackgroundLoginCheck.run(), isFalse);
    },
  );
}
