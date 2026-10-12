import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/sqlite_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/large_data_fixture.dart';

// Separate Dart AND FFI worker isolates are essential: two factories in the
// same Dart isolate share an FFI worker, whose synchronous busy wait would also
// block the holder's COMMIT. This matches main vs WorkManager in production.
Future<void> _contender((String, SendPort, bool) args) async {
  final (path, reply, write) = args;
  final commands = ReceivePort();
  Database? db;
  try {
    db = await openAppDatabase(
      path,
      factory: databaseFactoryFfi,
      singleInstance: false,
    );
    reply.send({'ready': commands.sendPort, 'busy': await _busyTimeout(db)});
    await commands.first;
    reply.send({'attempting': true});
    final timer = Stopwatch()..start();
    try {
      await db.transaction((tx) async {
        if (write) {
          await tx.insert('data', {'id': 2, 'value': 'worker'});
        } else {
          await tx.query('data');
        }
      });
      reply.send({'ok': true, 'ms': timer.elapsedMilliseconds});
    } catch (error) {
      reply.send({'error': error.toString(), 'ms': timer.elapsedMilliseconds});
    }
  } catch (error) {
    reply.send({'error': error.toString()});
  } finally {
    await db?.close();
    commands.close();
    reply.send({'closed': true});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('sr-contention-');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await LocalDbService.closeDb();
    await dir.delete(recursive: true);
  });

  for (final roles in [(false, true), (true, false), (true, true)]) {
    test(
      'overlap holderWrites=${roles.$1}, workerWrites=${roles.$2}',
      () async {
        await _race(dir, holderWrites: roles.$1, workerWrites: roles.$2);
      },
    );
  }

  test(
    'lock beyond budget fails finitely and leaves committed data intact',
    () async {
      await _race(dir, holderWrites: true, workerWrites: true, exhaust: true);
    },
  );

  test(
    'configuration precedes schema callbacks and covers read-only reopens',
    () async {
      final path = '${dir.path}/settings.db';
      final db = await openAppDatabase(
        path,
        version: 1,
        onConfigure: (db) async {
          expect(await _busyTimeout(db), sqliteBusyTimeoutMs);
          await db.rawQuery('PRAGMA journal_mode=WAL');
        },
        onCreate: (db, _) async {
          expect(await _busyTimeout(db), sqliteBusyTimeoutMs);
          await db.execute('CREATE TABLE data(id INTEGER PRIMARY KEY)');
        },
      );
      await db.close();
      final read = await openAppDatabase(
        path,
        readOnly: true,
        singleInstance: false,
      );
      try {
        expect(await _busyTimeout(read), sqliteBusyTimeoutMs);
        expect(
          (await read.rawQuery('PRAGMA journal_mode')).single.values.single,
          'wal',
        );
        await expectLater(
          read.insert('data', {'id': 1}),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await read.close();
      }
      final reopened = await openAppDatabase(path, singleInstance: false);
      expect(await _busyTimeout(reopened), sqliteBusyTimeoutMs);
      await reopened.close();
    },
  );

  test(
    'report and community entry points preserve their bounded waits and WAL',
    () async {
      final db = await LocalDbService.db;
      expect(await _busyTimeout(db), sqliteBusyTimeoutMs);
      expect(
        (await db.rawQuery('PRAGMA journal_mode')).single.values.single,
        'wal',
      );
      final path = '${dir.path}/community.db';
      final community = await CommunityStore.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      try {
        expect(await _busyTimeout(community.db), 30000);
        expect(
          (await community.db.rawQuery(
            'PRAGMA journal_mode',
          )).single.values.single,
          'wal',
        );
      } finally {
        await CommunityStore.closeForTest(path);
      }
    },
  );

  test(
    '50k report dashboard and migration stay within their wait budgets on host',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 50000);
      final timer = Stopwatch()..start();
      final summary = await LocalDbService.computeSummary();
      timer.stop();
      expect(summary.total, 50000);
      expect(timer.elapsedMilliseconds, lessThan(sqliteBusyTimeoutMs));
      // Synthetic host timing only; this does not establish a device latency SLA.
      // ignore: avoid_print
      print(
        'contention budget: 50000-row computeSummary=${timer.elapsedMilliseconds}ms',
      );
      // This path holds the source write lock while creating its full backup.
      // Existing v16/v17 integrity tests cover the schema/value conversion;
      // here a synthetic 50k-row database exercises the long critical section.
      await db.setVersion(LocalDbService.inPlaceFrom);
      final path = db.path;
      await LocalDbService.closeDb();
      timer.reset();
      timer.start();
      final migration = await LocalDbService.migrateInPlace(path);
      timer.stop();
      expect(migration, isNotNull);
      expect(timer.elapsedMilliseconds, lessThan(30000));
      // ignore: avoid_print
      print(
        'contention budget: 50000-row migrateInPlace=${timer.elapsedMilliseconds}ms',
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

Future<int> _busyTimeout(Database db) async =>
    (await db.rawQuery('PRAGMA busy_timeout')).single.values.single as int;

Future<void> _race(
  Directory dir, {
  required bool holderWrites,
  required bool workerWrites,
  bool exhaust = false,
}) async {
  final path = '${dir.path}/race.db';
  final db = await openAppDatabase(path, singleInstance: false);
  final replies = ReceivePort();
  final events = StreamIterator<dynamic>(replies);
  final release = Completer<void>();
  final acquired = Completer<void>();
  Isolate? worker;
  Future<void>? holding;
  Future<Map<dynamic, dynamic>> next() async {
    if (!await events.moveNext().timeout(const Duration(seconds: 15))) {
      throw StateError('worker exited without a result');
    }
    return events.current as Map<dynamic, dynamic>;
  }

  try {
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await db.execute('CREATE TABLE data(id INTEGER PRIMARY KEY, value TEXT)');
    await db.insert('data', {'id': 1, 'value': 'original'});
    worker = await Isolate.spawn(_contender, (
      path,
      replies.sendPort,
      workerWrites,
    ));
    final ready = await next();
    expect(ready['ready'], isA<SendPort>());
    expect(ready['busy'], sqliteBusyTimeoutMs);
    holding = db.transaction((tx) async {
      if (holderWrites) {
        await tx.update('data', {'value': 'holder'}, where: 'id=1');
      } else {
        // sqflite uses BEGIN IMMEDIATE/EXCLUSIVE even for read-only callbacks,
        // just as computeSummary does, so this holds the writer reservation.
        await tx.query('data');
      }
      acquired.complete();
      await release.future;
    });
    await acquired.future;
    (ready['ready'] as SendPort).send('go');
    expect((await next())['attempting'], true);
    var finished = false;
    final result = next().then((value) {
      finished = true;
      return value;
    });
    if (!exhaust) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        finished,
        false,
        reason:
            'must wait while the other transaction holds its lock; '
            '${finished ? await result : "still waiting"}',
      );
      release.complete();
      await holding;
    }
    final outcome = await result;
    if (exhaust) {
      expect(outcome['error'], contains('database is locked'));
      expect(outcome['ms'], greaterThanOrEqualTo(sqliteBusyTimeoutMs - 100));
      expect(outcome['ms'], lessThan(sqliteBusyTimeoutMs + 3000));
      release.complete();
      await holding;
    } else {
      expect(outcome['ok'], true, reason: '$outcome');
      expect(outcome['ms'], greaterThanOrEqualTo(300));
      expect(outcome['ms'], lessThan(sqliteBusyTimeoutMs));
    }
    expect((await next())['closed'], true);
    final rows = await db.query('data', orderBy: 'id');
    expect(rows, [
      {'id': 1, 'value': holderWrites ? 'holder' : 'original'},
      if (workerWrites && !exhaust) {'id': 2, 'value': 'worker'},
    ]);
    expect(
      (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
      'ok',
    );
    expect(
      (await db.rawQuery('PRAGMA journal_mode')).single.values.single,
      'wal',
    );
  } finally {
    if (!release.isCompleted) release.complete();
    await holding;
    worker?.kill(priority: Isolate.immediate);
    await events.cancel();
    replies.close();
    await db.close();
  }
}
