import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/database_snapshot.dart';
import 'package:safetyreport/services/local_database_exchange.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CommunityStore store;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('sr_exchange_recovery_');
    store = await CommunityStore.open(
      path: '${root.path}/community.db',
      factory: databaseFactoryFfi,
    );
    await store.setMeta('local_dataset_id', 'old-dataset');
    await store.setMeta('dataset_history', '[]');
  });
  tearDown(() async {
    await CommunityStore.closeForTest(store.path);
    await root.delete(recursive: true);
  });
  Future<String> digest(String path) async =>
      sha256.convert(await File(path).readAsBytes()).toString();
  Future<void> journal(
    String stage,
    String current,
    String backup,
    String prepared,
  ) async {
    await File('$current.exchange.json').writeAsString(
      jsonEncode({
        'format_version': 1,
        'operation_id': 'fixture',
        'stage': stage,
        'previous_good': backup,
        'previous_sha256': await digest(backup),
        'previous_target_sha256': await digest(backup),
        'prepared_sha256': await digest(prepared),
        'previous_dataset': 'old-dataset',
        'previous_history': '[]',
        'next_dataset': 'new-dataset',
      }),
    );
  }

  test(
    'read-only WAL snapshot keeps every value/type, rowid 0/-1 and source bytes',
    () async {
      final path = '${root.path}/source.db';
      final writer = await openDatabase(path, singleInstance: false);
      addTearDown(writer.close);
      await writer.rawQuery('PRAGMA journal_mode=WAL');
      await writer.rawQuery('PRAGMA wal_autocheckpoint=0');
      await writer.execute(
        'CREATE TABLE cells(id INTEGER PRIMARY KEY,a TEXT,b TEXT,c INTEGER,d REAL,e BLOB)',
      );
      for (final id in [-1, 0, 1]) {
        await writer.insert('cells', {
          'id': id,
          'a': '001한글\r\n',
          'b': id == 0 ? '' : null,
          'c': 123,
          'd': 3.125,
          'e': Uint8List.fromList([0, 1, 255]),
        });
      }
      final beforeMain = await digest(path),
          beforeWal = await digest('$path-wal');
      final target = '${root.path}/snapshot.db';
      await copyReadOnlyDatabaseSnapshot(path, target);
      final copy = await openDatabase(
        target,
        readOnly: true,
        singleInstance: false,
      );
      addTearDown(copy.close);
      final projection =
          'SELECT rowid,* ,typeof(a) ta,typeof(b) tb,typeof(c) tc,typeof(d) td,typeof(e) te FROM cells ORDER BY id';
      expect(
        await copy.rawQuery(projection),
        await writer.rawQuery(projection),
      );
      expect(await digest(path), beforeMain);
      expect(await digest('$path-wal'), beforeWal);
    },
  );
  test(
    'snapshot cursor aliases and WITHOUT ROWID preserve opaque column values',
    () async {
      final writer = await openDatabase(
        '${root.path}/opaque.db',
        singleInstance: false,
      );
      addTearDown(writer.close);
      await writer.execute(
        'CREATE TABLE opaque(rowid TEXT,_rowid_ TEXT,oid TEXT,_sr_snapshot_cursor TEXT,key TEXT PRIMARY KEY) WITHOUT ROWID',
      );
      await writer.insert('opaque', {
        'rowid': '001',
        '_rowid_': '',
        'oid': null,
        '_sr_snapshot_cursor': 'opaque-value',
        'key': 'key-1',
      });
      await writer.execute(
        'CREATE TABLE ordinary(_sr_snapshot_cursor TEXT,value BLOB)',
      );
      await writer.insert('ordinary', {
        '_sr_snapshot_cursor': 'retain-me',
        'value': Uint8List.fromList([0, 255]),
      });
      final target = '${root.path}/opaque-copy.db';
      await copyReadOnlyDatabaseSnapshot(writer.path, target);
      final copy = await openDatabase(
        target,
        readOnly: true,
        singleInstance: false,
      );
      addTearDown(copy.close);
      expect(await copy.query('opaque'), await writer.query('opaque'));
      expect(await copy.query('ordinary'), await writer.query('ordinary'));
    },
  );
  test(
    'an unreadable source publishes nothing and removes only its private target',
    () async {
      final target = '${root.path}/snapshot.db';
      await expectLater(
        copyReadOnlyDatabaseSnapshot('${root.path}/absent.db', target),
        throwsA(anything),
      );
      expect(await File(target).exists(), isFalse);
    },
  );
  test(
    'existing snapshot destination is refused without deleting it',
    () async {
      final target = File('${root.path}/existing.db')
        ..writeAsStringSync('keep');
      await expectLater(
        copyReadOnlyDatabaseSnapshot('${root.path}/absent.db', target.path),
        throwsFormatException,
      );
      expect(await target.readAsString(), 'keep');
    },
  );
  test(
    'failed publication restores file, dataset and history together',
    () async {
      final old = File('${root.path}/personal.db')
        ..writeAsStringSync('old-file');
      final prepared = File('${root.path}/prepared.db')
        ..writeAsStringSync('new-file');
      await expectLater(
        LocalDatabaseExchange.publish(
          destination: old.path,
          prepared: prepared.path,
          reason: 'fixture',
          store: store,
          copy: (a, b) async {
            await File(a).copy(b);
          },
          commit: () async {
            await old.delete();
            throw StateError('injected-before-rename');
          },
        ),
        throwsStateError,
      );
      expect(await old.readAsString(), 'old-file');
      expect(await store.localDatasetId(), 'old-dataset');
      expect(await store.meta('dataset_history'), '[]');
      expect(await File('${old.path}.exchange.json').exists(), isFalse);
    },
  );
  test(
    'crash after rename retains the new file and completes its dataset identity',
    () async {
      final current = File('${root.path}/personal.db')
        ..writeAsStringSync('new-file');
      final backup = File('${current.path}.exchange-good-fixture.db')
        ..writeAsStringSync('old-file');
      final prepared = File('${root.path}/prepared.db')
        ..writeAsStringSync('new-file');
      await journal('publishing', current.path, backup.path, prepared.path);
      await LocalDatabaseExchange.recover(current.path, store: store);
      expect(await current.readAsString(), 'new-file');
      expect(await store.localDatasetId(), 'new-dataset');
    },
  );
  test('published marker never rolls back later user writes', () async {
    final current = File('${root.path}/personal.db')
      ..writeAsStringSync('new-file-plus-later-writes');
    final backup = File('${current.path}.exchange-good-fixture.db')
      ..writeAsStringSync('old-file');
    final prepared = File('${root.path}/prepared.db')
      ..writeAsStringSync('new-file');
    await journal('published', current.path, backup.path, prepared.path);
    await LocalDatabaseExchange.recover(current.path, store: store);
    expect(await current.readAsString(), 'new-file-plus-later-writes');
    expect(await store.localDatasetId(), 'new-dataset');
  });
  test(
    'ambiguous publication retains current file, recovery backup and journal',
    () async {
      final current = File('${root.path}/personal.db')
        ..writeAsStringSync('unknown-writer');
      final backup = File('${current.path}.exchange-good-fixture.db')
        ..writeAsStringSync('old-file');
      final prepared = File('${root.path}/prepared.db')
        ..writeAsStringSync('new-file');
      await journal('publishing', current.path, backup.path, prepared.path);
      await expectLater(
        LocalDatabaseExchange.recover(current.path, store: store),
        throwsFormatException,
      );
      expect(await current.readAsString(), 'unknown-writer');
      expect(await backup.exists(), isTrue);
      expect(await File('${current.path}.exchange.json').exists(), isTrue);
    },
  );
}
