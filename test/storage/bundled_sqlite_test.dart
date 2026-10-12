import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:safetyreport/services/bundled_sqlite.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundle preserves directory, WAL, FTS, version and snapshot values across isolates',
    () async {
      final dir = await Directory.systemTemp.createTemp('bl1-sqlite-');
      final factory = createDatabaseFactoryFfi();
      await factory.setDatabasesPath(dir.path);
      final path = p.join(dir.path, 'existing.db');
      final db = await factory.openDatabase(path);
      try {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute(
          'CREATE TABLE data(id INTEGER PRIMARY KEY, value TEXT, n REAL)',
        );
        await db.insert('data', {'id': 1, 'value': '한글\n둘째 줄', 'n': 1.25});
        await db.insert('data', {'id': 2, 'value': null, 'n': null});
        await db.insert('data', {'id': 3, 'value': '', 'n': 0});
        await db.execute('CREATE VIRTUAL TABLE search USING fts4(value)');
        await db.insert('search', {'value': '검색 자료'});
        await db.setVersion(42);
        await BundledSqlite.install(
          platformFactory: factory,
          bundledFactory: databaseFactoryFfi,
        );
        expect(await getDatabasesPath(), dir.path);
        expect(
          (await db.rawQuery('PRAGMA journal_mode')).single.values.single,
          'wal',
        );
        final version = await db.rawQuery('SELECT sqlite_version() AS version');
        expect(version.single['version'], '3.53.4');
        final other = await Isolate.run(() async {
          final connection = await databaseFactoryFfi.openDatabase(path);
          try {
            return <String, Object?>{
              'version': (await connection.rawQuery(
                'SELECT sqlite_version() AS version',
              )).single['version'],
              'rows': await connection.query('data', orderBy: 'id'),
              'user_version': await connection.getVersion(),
              'fts': await connection.rawQuery(
                "SELECT value FROM search WHERE search MATCH '검색'",
              ),
            };
          } finally {
            await connection.close();
          }
        });
        expect(other['version'], version.single['version']);
        expect(other['rows'], await db.query('data', orderBy: 'id'));
        expect(other['user_version'], 42);
        expect(other['fts'], [
          {'value': '검색 자료'},
        ]);
        final backupPath = p.join(dir.path, 'backup.db');
        await LocalDbService.copyDatabaseConsistent(path, backupPath);
        final backup = await openDatabase(backupPath, singleInstance: false);
        try {
          expect(
            await backup.query('data', orderBy: 'id'),
            await db.query('data', orderBy: 'id'),
          );
          expect(await backup.getVersion(), 42);
          expect(
            await backup.rawQuery(
              "SELECT value FROM search WHERE search MATCH '검색'",
            ),
            [
              {'value': '검색 자료'},
            ],
          );
          expect(
            (await backup.rawQuery(
              'PRAGMA integrity_check',
            )).single.values.single,
            'ok',
          );
        } finally {
          await backup.close();
        }
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
