import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// SQL copied from tag v1.3.5's _create and DuplicateProjectionService.createSchema.
// Does not use ALTER DROP COLUMN, so this test also runs on SQLite 3.22.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('onboarding_db_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  tearDown(() async {
    await LocalDbService.closeDb();
    await CommunityStore.closeForTest('${dir.path}/community.db');
    await dir.delete(recursive: true);
  });

  test(
    'fresh install opens personal and community DB and records owner',
    () async {
      final db = await LocalDbService.db;
      // Recorded in the old-library run to prove which engine actually executed SQL.
      // ignore: avoid_print
      print('SQLite engine: ${await db.rawQuery('SELECT sqlite_version()')}');
      expect(await LocalDbService.checkOwner('920001'), 'ok');
      expect(await LocalDbService.dbOwner(), '920001');
      expect(await LocalDbService.checkOwner('920002'), 'mismatch');
      final store = await CommunityStore.open();
      expect(
        await store.meta('schema_version'),
        '$communityStoreSchemaVersion',
      );
    },
  );

  for (final journal in ['delete', 'wal']) {
    test(
      'v1.3.5 update opens with $journal, preserves backup and watchlist',
      () async {
        final path = await LocalDbService.getDbPath();
        final old = await openDatabase(path);
        await old.rawQuery('PRAGMA journal_mode=$journal');
        final schema =
            jsonDecode(
                  File(
                    'test/fixtures/mobile-v1.3.5-schema.json',
                  ).readAsStringSync(),
                )
                as List;
        for (final sql in schema.cast<String>()) {
          await old.execute(sql);
        }
        await old.insert('reports', {
          'ID': 'synthetic-1',
          '신고내용': '합성 자료\n보존 확인',
          'category': 'traffic',
        });
        await old.insert('sync_meta', {
          'key': 'watchlist',
          'value': '["synthetic-1"]',
        });
        await old.setVersion(10);
        await old.close();
        final db = await LocalDbService.db;
        expect(await db.getVersion(), LocalDbService.dbVersion);
        expect(await db.query('reports'), isEmpty);
        expect(await LocalDbService.getMeta('watchlist'), '["synthetic-1"]');
        expect(await LocalDbService.checkOwner('920001'), 'ok');
        final reset =
            jsonDecode(
                  (await LocalDbService.getMeta(
                    LocalDbService.legacyResetMetaKey,
                  ))!,
                )
                as Map;
        final backup = await openDatabase(
          reset['backup'] as String,
          readOnly: true,
        );
        expect((await backup.query('reports')).single['신고내용'], '합성 자료\n보존 확인');
        expect(await backup.getVersion(), 10);
        await backup.close();
      },
    );
  }
}
