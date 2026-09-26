// 일관된 DB 사본(copyDatabaseConsistent) — 이전 DB 백업과 초기화 크롤링 사전 백업이 쓴다.
// VACUUM INTO 는 SQLite 3.27 부터라 Android 7~10(API 24~29)에서 실패한다(Sol 재검증 4). 호스트 SQLite 로는 그 실패를 재현할 수 없어서
// 사본 내용을 원본과 전부 비교하고, 앱 코드가 VACUUM INTO 를 다시 실행하지 않는지 소스로도 확인한다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<List<Map<String, Object?>>> _all(Database db, String table) =>
    db.rawQuery('SELECT * FROM "$table" ORDER BY rowid');

void main() {
  late Directory dir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_db_copy_test_');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('the copy has every table, row, index, view, sequence and the version, including WAL-only rows', () async {
    final src = '${dir.path}/src.db';
    final db = await openDatabase(src, singleInstance: false);
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await db.rawQuery('PRAGMA wal_autocheckpoint=0');
    await db.execute('CREATE TABLE reports (ID TEXT PRIMARY KEY, 신고번호 TEXT NOT NULL DEFAULT \'\', 별점 INTEGER, 위도 REAL, 본문 TEXT)');
    await db.execute('CREATE TABLE log (n INTEGER PRIMARY KEY AUTOINCREMENT, msg TEXT)');
    await db.execute('CREATE INDEX ix_reports_number ON reports (신고번호)');
    await db.execute('CREATE VIEW reports_view AS SELECT ID, 신고번호 FROM reports');
    await db.execute('CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT)');
    await db.insert('reports', {'ID': 'a', '신고번호': 'SPP-1', '별점': 4, '위도': 37.5, '본문': '한글\n줄바꿈'});
    await db.insert('reports', {'ID': 'b', '신고번호': '', '별점': null, '위도': null, '본문': null});
    await db.insert('log', {'msg': 'x'});
    await db.insert('log', {'msg': 'y'});
    await db.delete('log', where: 'n = 2');
    await db.insert('sync_meta', {'key': 'watchlist', 'value': 'SPP-1'});
    await db.setVersion(10);
    final reader = await openDatabase(src, singleInstance: false);
    await reader.execute('BEGIN');
    await reader.rawQuery('SELECT count(*) FROM reports'); // 체크포인트를 막아 둔다
    await db.insert('reports', {'ID': 'wal', '신고번호': 'SPP-WAL'});

    final target = '${dir.path}/copy.bak';
    await LocalDbService.copyDatabaseConsistent(src, target);
    await reader.execute('COMMIT');
    await reader.close();

    final copy = await openDatabase(target, readOnly: true, singleInstance: false);
    expect(await copy.getVersion(), 10);
    for (final t in ['reports', 'log', 'sync_meta', 'sqlite_sequence']) {
      expect(await _all(copy, t), await _all(db, t), reason: t);
    }
    final names = (await copy.rawQuery("SELECT type || ':' || name AS k FROM sqlite_master ORDER BY k")).map((r) => r['k']).toList();
    expect(names, containsAll(['index:ix_reports_number', 'view:reports_view', 'table:reports', 'table:log']));
    expect((await copy.rawQuery('SELECT count(*) AS n FROM reports_view')).first['n'], 3);
    await copy.close();
    expect(await db.getVersion(), 10, reason: '원본은 바뀌지 않는다');
    await db.close();
  });

  test('a copy over an existing file replaces it (a retried run reuses the name)', () async {
    final src = '${dir.path}/src.db';
    final db = await openDatabase(src, singleInstance: false);
    await db.execute('CREATE TABLE t (x)');
    await db.insert('t', {'x': 1});
    await db.close();
    final target = '${dir.path}/copy.bak';
    File(target).writeAsStringSync('old partial copy');
    await LocalDbService.copyDatabaseConsistent(src, target);
    final copy = await openDatabase(target, readOnly: true, singleInstance: false);
    expect(await copy.query('t'), [
      {'x': 1},
    ]);
    await copy.close();
  });

  test('app code does not run VACUUM INTO (fails on Android 7-10)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (RegExp(r'''["']\s*VACUUM\s+INTO''', caseSensitive: false).hasMatch(line)) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
