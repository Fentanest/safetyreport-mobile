// 서버 DB 가져오기 변환 규칙 (저장 계층 재설계 R1b, 서버 레포 docs/plans/storage-refactor-plan.md).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _serverDb(
  Directory dir, {
  required List<String> watchlist,
  String? staleMetaWatchlist,
}) async {
  final path = '${dir.path}/server_${DateTime.now().microsecondsSinceEpoch}.db';
  final db = await openDatabase(path);
  await db.execute(
    '''CREATE TABLE mysafetymerge_traffic (ID TEXT PRIMARY KEY, 상태 TEXT, 신고번호 TEXT, 신고명 TEXT, 신고일 TEXT,
    만족도조사여부 TEXT, 별점 INTEGER, 별점사유 TEXT, 감시목록 TEXT, 처리상태 TEXT, 처리기관 TEXT, 담당자 TEXT, 위반장소 TEXT,
    주소정규화 TEXT, 행정구역 TEXT, 위도 REAL, 경도 REAL, 지오코딩상태 TEXT, 종결여부 TEXT, synced_at INTEGER, 보완횟수 INTEGER)''',
  );
  await db.execute(
    'CREATE TABLE mysafetymerge_parking AS SELECT * FROM mysafetymerge_traffic WHERE 0',
  );
  await db.execute(
    'CREATE TABLE mysafetymerge_other AS SELECT * FROM mysafetymerge_traffic WHERE 0',
  );
  await db.execute('CREATE TABLE mysafety_watchlist (신고번호 TEXT PRIMARY KEY)');
  await db.execute(
    'CREATE TABLE mysafety_sync_meta (key TEXT PRIMARY KEY, value TEXT)',
  );
  await db.execute('CREATE TABLE mysafety (ID TEXT PRIMARY KEY)');
  for (final (id, number, merged) in [
    ('s1', 'SPP-1', 'Y'),
    ('s2', 'SPP-2', 'N'),
  ]) {
    await db.insert('mysafetymerge_traffic', {
      'ID': id,
      '상태': '수용',
      '신고번호': number,
      '신고명': '신호위반',
      '신고일': '2026-09-01',
      '감시목록': merged,
      '처리상태': '수용',
      '처리기관': '기관',
      '담당자': null,
      '위반장소': '서울 강서구 1',
      '주소정규화': null,
      '지오코딩상태': null,
      '종결여부': 'Y',
      'synced_at': null,
      '보완횟수': '',
    });
  }
  for (final n in watchlist) {
    await db.insert('mysafety_watchlist', {'신고번호': n});
  }
  if (staleMetaWatchlist != null) {
    await db.insert('mysafety_sync_meta', {
      'key': 'watchlist',
      'value': staleMetaWatchlist,
    });
  }
  await db.close();
  return path;
}

Future<Map<String, Object?>> _row(String id) async =>
    (await (await LocalDbService.db).query(
      'reports',
      where: 'ID = ?',
      whereArgs: [id],
    )).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_server_import_test_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  test(
    'empty server watchlist clears flags and ignores a stale sync_meta copy (M-8, S-15)',
    () async {
      final path = await _serverDb(
        dir,
        watchlist: [],
        staleMetaWatchlist: 'SPP-1',
      );
      await LocalDbService.importFromServerDb(path);
      expect((await _row('s1'))['감시목록'], 'N');
      expect(await LocalDbService.getWatchlistNumbers(), isEmpty);
      expect(await LocalDbService.getMeta('watchlist'), '');
    },
  );

  test('watch flag is derived from the server watchlist table', () async {
    final path = await _serverDb(dir, watchlist: ['SPP-2']);
    await LocalDbService.importFromServerDb(path);
    expect((await _row('s1'))['감시목록'], 'N');
    expect((await _row('s2'))['감시목록'], 'Y');
    expect(await LocalDbService.getWatchlistNumbers(), {'SPP-2'});
  });

  test(
    'values keep NULL and numeric columns get numbers or NULL (M-9, M-10)',
    () async {
      final path = await _serverDb(dir, watchlist: []);
      await LocalDbService.importFromServerDb(path);
      final row = await _row('s1');
      expect(row['synced_at'], isNull);
      expect(row['담당자'], isNull);
      expect(row['주소정규화'], isNull);
      expect(row['보완횟수'], isNull);
    },
  );

  // ── 2026-09-26 감사 SOL-02·03·05 (PC exchange 와 같은 규칙) ──────────────────

  Future<void> alter(String path, List<String> sql) async {
    final db = await openDatabase(path);
    for (final q in sql) {
      await db.execute(q);
    }
    await db.close();
  }

  test('unknown server column with a value refuses before replacing the DB (SOL-02)', () async {
    final first = await _serverDb(dir, watchlist: []);
    await LocalDbService.importFromServerDb(first);
    final path = await _serverDb(dir, watchlist: []);
    await alter(path, [
      'ALTER TABLE mysafetymerge_traffic ADD COLUMN 미래열 TEXT',
      "UPDATE mysafetymerge_traffic SET 미래열 = '' WHERE ID = 's1'",
      "UPDATE mysafetymerge_traffic SET 신고명 = '바뀌면 안 됨'",
    ]);
    await expectLater(
      LocalDbService.importFromServerDb(path),
      throwsA(isA<UnknownColumnsException>().having((e) => e.toString(), 'message', contains('mysafetymerge_traffic.미래열(1행)'))),
    );
    expect((await _row('s1'))['신고명'], '신호위반', reason: '기존 DB 그대로');
  });

  test('unknown server column that is all NULL loses nothing and imports', () async {
    final path = await _serverDb(dir, watchlist: []);
    await alter(path, ['ALTER TABLE mysafetymerge_traffic ADD COLUMN 미래열 TEXT']);
    expect(await LocalDbService.importFromServerDb(path), 2);
  });

  test('entry_value: no server row is NULL, an empty or filled row is kept as is (SOL-03)', () async {
    final path = await _serverDb(dir, watchlist: []);
    await alter(path, [
      'CREATE TABLE mysafety_entry_value (ID TEXT PRIMARY KEY, entry_value TEXT NOT NULL)',
      "INSERT INTO mysafety_entry_value VALUES ('s1', '')",
    ]);
    await LocalDbService.importFromServerDb(path);
    expect((await _row('s1'))['entry_value'], '');
    expect((await _row('s2'))['entry_value'], isNull);
    final filled = await _serverDb(dir, watchlist: []);
    await alter(filled, [
      'CREATE TABLE mysafety_entry_value (ID TEXT PRIMARY KEY, entry_value TEXT NOT NULL)',
      "INSERT INTO mysafety_entry_value VALUES ('s2', '자동차·교통위반-신호위반')",
    ]);
    await LocalDbService.importFromServerDb(filled);
    expect((await _row('s2'))['entry_value'], '자동차·교통위반-신호위반');
    expect((await _row('s1'))['entry_value'], isNull);
  });

  test('a successful import keeps the previous DB as a backup, newest three only (SOL-05)', () async {
    final dbFile = File(await LocalDbService.getDbPath());
    for (final f in dbFile.parent.listSync().whereType<File>()) {
      if (f.uri.pathSegments.last.contains('.before_import.')) f.deleteSync();
    }
    final first = await _serverDb(dir, watchlist: []);
    await LocalDbService.importFromServerDb(first);
    expect(await LocalDbService.latestImportBackup(), isNull, reason: '처음에는 바꿀 DB 가 없었다');
    for (var i = 0; i < 4; i++) {
      final next = await _serverDb(dir, watchlist: []);
      await alter(next, ["UPDATE mysafetymerge_traffic SET 신고명 = '가져오기 $i'"]);
      await LocalDbService.importFromServerDb(next);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final latest = await LocalDbService.latestImportBackup();
    expect(latest, isNotNull);
    final backup = await openDatabase(latest!, readOnly: true, singleInstance: false);
    final name = (await backup.query('reports', where: 'ID = ?', whereArgs: ['s1'])).single['신고명'];
    await backup.close();
    expect(name, '가져오기 2', reason: '마지막 가져오기 직전 DB');
    final dbPath = await LocalDbService.getDbPath();
    final base = File(dbPath).uri.pathSegments.last;
    final kept = File(dbPath).parent.listSync().whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('$base.before_import.')).length;
    expect(kept, LocalDbService.importBackupKeep);
  });
}
