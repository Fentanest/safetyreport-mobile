// Synthetic upgrade probe. Only the isolated .bl1test application may run it.
import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:safetyreport/screens/secure_storage_recovery_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';
import 'package:safetyreport/services/bundled_sqlite.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/secure_storage_migration.dart';
import 'package:safetyreport/services/sqlite_connection.dart';

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

@pragma('vm:entry-point')
void probeBackground() {
  Workmanager().executeTask((task, input) async {
    DartPluginRegistrant.ensureInitialized();
    await BundledSqlite.initialize();
    final db = await openAppDatabase('${await getDatabasesPath()}/bl1_fixture.db');
    final version =
        (await db.rawQuery('SELECT sqlite_version() AS v')).single['v']
            as String;
    require(version == '3.53.4', 'background engine');
    require((await db.query('fixture')).length == 3, 'background rows');
    await (await SharedPreferences.getInstance()).setString(
      'bl1BackgroundVersion',
      version,
    );
    await db.close();
    debugPrint('BL1_BACKGROUND_PASS sqlite=$version');
    return true;
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  require(
    (await PackageInfo.fromPlatform()).packageName ==
        'com.fentanest.mysafetyreport.bl1test',
    'fixture package only',
  );
  final prefs = await SharedPreferences.getInstance();
  const missingMarker = bool.fromEnvironment('BL1_MISSING_MARKER');
  if (missingMarker) {
    const channel = MethodChannel(
      'com.fentanest.mysafetyreport/secure_storage',
    );
    final before = await channel.invokeMethod<int>('storedSecureEntries');
    require(
      prefs.getBool('secureStorageV10Migrated') != true,
      'fixture must have no v10 marker',
    );
    final readiness = await SecureStorageMigration.checkReady();
    require(
      readiness == SecureStorageReadiness.reauthenticationRequired,
      'missing marker must guide',
    );
    require(
      before != null &&
          before > 0 &&
          await channel.invokeMethod<int>('storedSecureEntries') == before,
      'guidance preserved ciphertext',
    );
    debugPrint('BL1_MISSING_MARKER_PASS');
    runApp(SecureStorageRecoveryApp(readiness: readiness));
    return;
  }
  require(
    await SecureStorageMigration.checkReady() == SecureStorageReadiness.ready,
    'v10 marker',
  );
  final values = await const FlutterSecureStorage().readAll();
  require(
    values['community_session_v1'] == 'bl1-synthetic-session',
    'session preserved',
  );
  require(
    values['standalone_password'] == 'bl1-synthetic-password',
    'password preserved',
  );
  require(
    values['community_connection_v1'] == 'bl1-synthetic-connection',
    'connection preserved',
  );
  await BundledSqlite.initialize();
  final path = '${await getDatabasesPath()}/bl1_fixture.db';
  require(
    path == prefs.getString('bl1FixturePath'),
    'existing Android directory',
  );
  final db = await openAppDatabase(path);
  final version = (await db.rawQuery(
    'SELECT sqlite_version() AS v',
  )).single['v'];
  require(version == '3.53.4', 'bundled engine');
  require(await db.getVersion() == 42, 'user_version preserved');
  final rows = await db.query('fixture', orderBy: 'id');
  require(
    rows.length == 3 &&
        rows[0]['value'] == '한글\n두 줄' &&
        rows[0]['n'] == 1.25 &&
        rows[1]['value'] == null &&
        rows[2]['value'] == '',
    'all values',
  );
  require(
    (await db.rawQuery(
          "SELECT value FROM search WHERE search MATCH '검색'",
        )).single['value'] ==
        '검색 자료',
    'legacy FTS4',
  );
  final backupPath = '$path.backup';
  await LocalDbService.copyDatabaseConsistent(path, backupPath);
  final backup = await openAppDatabase(backupPath, singleInstance: false);
  require(await backup.getVersion() == 42, 'backup version');
  require((await backup.query('fixture')).length == 3, 'backup rows');
  require(
    (await backup.rawQuery('PRAGMA integrity_check')).single.values.single ==
        'ok',
    'backup integrity',
  );
  await backup.close();
  await Workmanager().initialize(probeBackground);
  await Workmanager().registerOneOffTask('bl1-fixture', 'bl1-fixture');
  debugPrint(
    'BL1_UPGRADE_PASS sqlite=$version credentials=3 rows=3 fts4=ok backup=ok',
  );
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('BL1 upgrade pass'))),
    ),
  );
}
