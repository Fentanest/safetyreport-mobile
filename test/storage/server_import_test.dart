// 서버 DB 가져오기 변환 규칙 (저장 계층 재설계 R1b/R1c, 서버 레포 docs/plans/storage-refactor-plan.md).
// 2026-10-11: 서버 스키마 6(mysafety_report 단일 표 + mysafety_report_body) — 옛 mysafety + mysafetymerge_* 묶음은
// 버전 검사만으로 거절된다(같은 버전 백업만 받는다는 사용자 결정). 구조를 들여다보지 않는다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/kakao_owner.dart';
import '../support/server_db_fixture.dart';

Future<String> _serverDb(
  Directory dir, {
  required List<String> watchlist,
  String? staleMetaWatchlist,
}) async {
  final path = '${dir.path}/server_${DateTime.now().microsecondsSinceEpoch}.db';
  final db = await openServerSchemaDb(path);
  await stampOwner(db, table: 'mysafety_sync_meta');
  for (final (id, number, merged) in [
    ('s1', 'SPP-1', 'Y'),
    ('s2', 'SPP-2', 'N'),
  ]) {
    await insertServerReport(db, {
      'ID': id,
      '상태': '수용',
      '신고번호': number,
      '신고명': '신호위반',
      '신고일': '2026-09-01',
      '감시목록': merged,
      '처리상태': '수용',
      '처리기관': '기관',
      '처리기관코드': id == 's1' ? 'B410002' : null,
      '담당자': null,
      '위반장소': '서울 강서구 1',
      '주소정규화': null,
      '지오코딩상태': null,
      '종결여부': 'Y',
      'synced_at': null,
      '보완횟수': null,
      'category': 'traffic',
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
  useTestKakaoAccount();

  for (final official in [null, 'another-official-account']) {
    test(
      'server import accepts missing/different official account for same Kakao owner: $official',
      () async {
        final path = await _serverDb(dir, watchlist: []);
        final source = await openDatabase(path, singleInstance: false);
        if (official == null) {
          await source.delete(
            'mysafety_sync_meta',
            where: 'key=?',
            whereArgs: ['official_account_key'],
          );
        } else {
          await source.insert('mysafety_sync_meta', {
            'key': 'official_account_key',
            'value': official,
          });
        }
        await source.close();
        await (await LocalDbService.db).insert('reports', {
          'ID': 'preserved',
          'category': 'traffic',
        });
        expect(await LocalDbService.importFromServerDb(path), 2);
        expect(
          (await (await LocalDbService.db).query(
            'reports',
          )).map((r) => r['ID']),
          unorderedEquals(['s1', 's2']),
        );
      },
    );
  }

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

  for (final malformed in [
    'invalid-category',
    'raw-orphan',
    'fractional-integer',
  ]) {
    test(
      'server population $malformed is refused without replacing existing data',
      () async {
        final existing = await LocalDbService.db;
        await existing.insert('reports', {
          'ID': 'retained',
          '신고명': '원래 자료',
          'category': 'other',
        });
        final path = await _serverDb(dir, watchlist: []);
        final source = await openDatabase(path, singleInstance: false);
        if (malformed == 'invalid-category') {
          // 5분류(traffic·parking·safety·living·other) 밖의 값 — 이 앱이 모르는 분류(§4-341).
          await source.update(
            'mysafety_report',
            {'category': 'legacy_bucket'},
            where: 'ID=?',
            whereArgs: ['s1'],
          );
        } else if (malformed == 'raw-orphan') {
          // 본문 원문은 보존할 신고(category 있는 행)가 있어야 한다 — 없으면 거절.
          await source.insert('mysafety_report_body', {
            'ID': 'absent',
            'raw_content': '보존할 원문',
          });
        } else {
          await source.update(
            'mysafety_report',
            {'별점': 2.5},
            where: 'ID=?',
            whereArgs: ['s1'],
          );
        }
        await source.close();
        await expectLater(
          LocalDbService.importFromServerDb(path),
          throwsA(isA<FormatException>()),
        );
        expect((await _row('retained'))['신고명'], '원래 자료');
        expect(await (await LocalDbService.db).query('reports'), hasLength(1));
      },
    );
  }

  test(
    'server rows with negative and zero rowid survive every mapped value',
    () async {
      final path = await _serverDb(dir, watchlist: []);
      final source = await openDatabase(path, singleInstance: false);
      await source.rawUpdate(
        'UPDATE mysafety_report SET rowid=-1 WHERE ID=?',
        ['s1'],
      );
      await source.rawUpdate(
        'UPDATE mysafety_report SET rowid=0 WHERE ID=?',
        ['s2'],
      );
      await source.update(
        'mysafety_report',
        {'신고명': '001 한글\r\n줄바꿈', '담당자': '', '처리기관코드': '0001'},
        where: 'ID=?',
        whereArgs: ['s1'],
      );
      await source.close();
      expect(await LocalDbService.importFromServerDb(path), 2);
      final row = await _row('s1');
      expect(row['신고명'], '001 한글\r\n줄바꿈');
      expect(row['담당자'], '');
      expect(row['처리기관코드'], '0001');
      expect((await _row('s2'))['담당자'], isNull);
    },
  );

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
      // 원문 기관코드는 값이 있으면 그대로, 없으면 NULL 로 왕복한다(§3-1).
      expect(row['처리기관코드'], 'B410002');
      expect((await _row('s2'))['처리기관코드'], isNull);
    },
  );

  test(
    '목록에서만 본 신고(category NULL)가 있으면 조용히 빼지 않고 가져오기를 거절한다(Astra 재검수 #1)',
    () async {
      final path = await _serverDb(dir, watchlist: []);
      final source = await openDatabase(path, singleInstance: false);
      await source.insert('mysafety_report', {
        'ID': 'list-only',
        '신고번호': 'SPP-LIST',
        '신고명': '목록만',
        'category': null, // 상세를 아직 저장하지 않은 신고 — 앱에는 둘 자리가 없다
      });
      await source.close();
      final before = await (await LocalDbService.db).query('reports');
      await expectLater(
        LocalDbService.importFromServerDb(path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('목록만 있는 신고) 1건'),
          ),
        ),
      );
      expect(
        await (await LocalDbService.db).query('reports'),
        before,
        reason: '거절하면 앱 DB 는 그대로다',
      );
    },
  );

  test('상세 받은 신고의 분류·본문은 그대로 가져온다', () async {
    final path = await _serverDb(dir, watchlist: []);
    final source = await openDatabase(path, singleInstance: false);
    await source.insert('mysafety_report_body', {
      'ID': 's1',
      'raw_content': '본문 원문',
      'raw_type': 'report_body',
      'saved_at': 1,
    });
    await source.close();
    expect(await LocalDbService.importFromServerDb(path), 2);
    expect(
      (await (await LocalDbService.db).query('reports')).map((r) => r['ID']),
      unorderedEquals(['s1', 's2']),
    );
    final raw = await (await LocalDbService.db).query(
      'report_raw',
      where: 'ID = ?',
      whereArgs: ['s1'],
    );
    expect(raw.single['raw_content'], '본문 원문');
  });

  // ── 2026-09-26 초기화 크롤링 릴리스: 이전(또는 더 새) 버전 서버 DB 는 가져오지 않는다 (PC exchange.refuse_other_version) ──
  // 5 는 2026-10-11 전 서버 스키마(생활불편·안전신고 분리 전) — 구조가 지금과 같아도(같은 fixture) 버전만으로 거절된다.

  for (final version in [0, 1, 2, 3, 4, 5, 7]) {
    test(
      'server DB of schema $version is refused before replacing the DB',
      () async {
        await LocalDbService.importFromServerDb(
          await _serverDb(dir, watchlist: []),
        );
        final path = await _serverDb(dir, watchlist: []);
        final db = await openDatabase(path, singleInstance: false);
        await db.setVersion(version);
        await db.update('mysafety_report', {'신고명': '바뀌면 안 됨'});
        await db.close();
        await expectLater(
          LocalDbService.importFromServerDb(path),
          throwsA(
            isA<LegacyDatabaseException>().having(
              (e) => e.toString(),
              'message',
              contains(
                version < LocalDbService.serverSchemaVersion
                    ? '이전 버전 서버 DB(스키마 $version)'
                    : '더 새 버전 서버 DB(스키마 $version)',
              ),
            ),
          ),
        );
        expect((await _row('s1'))['신고명'], '신호위반', reason: '기존 DB 그대로');
      },
    );
  }

  test('the server schema version matches the contract', () {
    final contract =
        jsonDecode(File('contracts/storage-contract.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(
      LocalDbService.serverSchemaVersion,
      (contract['schema_version'] as Map)['server'],
    );
  });

  // ── 2026-09-26 감사 SOL-02·03·05 (PC exchange 와 같은 규칙) ──────────────────

  Future<void> alter(String path, List<String> sql) async {
    final db = await openDatabase(path, singleInstance: false);
    for (final q in sql) {
      await db.execute(q);
    }
    await db.close();
  }

  test(
    'unknown server column with a value refuses before replacing the DB (SOL-02)',
    () async {
      final first = await _serverDb(dir, watchlist: []);
      await LocalDbService.importFromServerDb(first);
      final path = await _serverDb(dir, watchlist: []);
      await alter(path, [
        'ALTER TABLE mysafety_report ADD COLUMN 미래열 TEXT',
        "UPDATE mysafety_report SET 미래열 = '' WHERE ID = 's1'",
        "UPDATE mysafety_report SET 신고명 = '바뀌면 안 됨'",
      ]);
      await expectLater(
        LocalDbService.importFromServerDb(path),
        throwsA(
          isA<UnknownColumnsException>().having(
            (e) => e.toString(),
            'message',
            contains('mysafety_report.미래열(1행)'),
          ),
        ),
      );
      expect((await _row('s1'))['신고명'], '신호위반', reason: '기존 DB 그대로');
    },
  );

  test(
    'unknown server column that is all NULL loses nothing and imports',
    () async {
      final path = await _serverDb(dir, watchlist: []);
      await alter(path, [
        'ALTER TABLE mysafety_report ADD COLUMN 미래열 TEXT',
      ]);
      expect(await LocalDbService.importFromServerDb(path), 2);
    },
  );

  test(
    'entry_value: no server row is NULL, an empty or filled row is kept as is (SOL-03)',
    () async {
      // 2026-10-11 부터 entry_value 는 mysafety_report 의 평범한 한 열이다(옛 mysafety_entry_value
      // 사이드카 표는 없다) — 다른 TEXT 열과 같은 경로로 원본 그대로 복사된다.
      final path = await _serverDb(dir, watchlist: []);
      await alter(path, ["UPDATE mysafety_report SET entry_value = '' WHERE ID = 's1'"]);
      await LocalDbService.importFromServerDb(path);
      expect((await _row('s1'))['entry_value'], '');
      expect((await _row('s2'))['entry_value'], isNull);

      final filled = await _serverDb(dir, watchlist: []);
      await alter(filled, [
        "UPDATE mysafety_report SET entry_value = '자동차·교통위반-신호위반' WHERE ID = 's2'",
      ]);
      await LocalDbService.importFromServerDb(filled);
      expect((await _row('s2'))['entry_value'], '자동차·교통위반-신호위반');
      expect((await _row('s1'))['entry_value'], isNull);
    },
  );

  test(
    'old mixed server DB layout (mysafety + mysafetymerge_*, schema 5) is refused by the version check alone',
    () async {
      // 2026-10-11 전 구조(표 여러 개로 나뉜 병합 레이아웃)는 지금 가져오기가 더는 지원하지 않는다.
      // 구조를 읽기 전에 버전만으로 거절된다(같은 버전 백업만 받는다는 사용자 결정) — mysafety_report 가 없어도 상관없다.
      await LocalDbService.importFromServerDb(
        await _serverDb(dir, watchlist: []),
      );
      final path =
          '${dir.path}/legacy_mixed_${DateTime.now().microsecondsSinceEpoch}.db';
      final db = await openDatabase(path, singleInstance: false);
      await db.setVersion(5);
      await db.execute(
        'CREATE TABLE mysafety (ID TEXT PRIMARY KEY, 신고번호 TEXT, 신고명 TEXT)',
      );
      await db.execute(
        'CREATE TABLE mysafetymerge_traffic (ID TEXT PRIMARY KEY, 신고번호 TEXT, 신고명 TEXT)',
      );
      await db.execute(
        'CREATE TABLE mysafetymerge_parking (ID TEXT PRIMARY KEY, 신고번호 TEXT, 신고명 TEXT)',
      );
      await db.execute(
        'CREATE TABLE mysafetymerge_other (ID TEXT PRIMARY KEY, 신고번호 TEXT, 신고명 TEXT)',
      );
      await db.insert('mysafetymerge_traffic', {
        'ID': 'old1',
        '신고번호': 'OLD-1',
        '신고명': '옛 구조',
      });
      await db.close();
      await expectLater(
        LocalDbService.importFromServerDb(path),
        throwsA(
          isA<LegacyDatabaseException>().having(
            (e) => e.toString(),
            'message',
            contains('이전 버전 서버 DB(스키마 5)'),
          ),
        ),
      );
      expect((await _row('s1'))['신고명'], '신호위반', reason: '기존 DB 그대로');
      expect(
        (await (await LocalDbService.db).query(
          'reports',
          where: 'ID = ?',
          whereArgs: ['old1'],
        )),
        isEmpty,
      );
    },
  );

  test(
    'a successful import keeps the previous DB as a backup, newest three only (SOL-05)',
    () async {
      final dbFile = File(await LocalDbService.getDbPath());
      for (final f in dbFile.parent.listSync().whereType<File>()) {
        if (f.uri.pathSegments.last.contains('.before_import.')) f.deleteSync();
      }
      final first = await _serverDb(dir, watchlist: []);
      await LocalDbService.importFromServerDb(first);
      expect(
        await LocalDbService.latestImportBackup(),
        isNull,
        reason: '처음에는 바꿀 DB 가 없었다',
      );
      for (var i = 0; i < 4; i++) {
        final next = await _serverDb(dir, watchlist: []);
        await alter(next, ["UPDATE mysafety_report SET 신고명 = '가져오기 $i' WHERE ID='s1'"]);
        await LocalDbService.importFromServerDb(next);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final latest = await LocalDbService.latestImportBackup();
      expect(latest, isNotNull);
      final backup = await openDatabase(
        latest!,
        readOnly: true,
        singleInstance: false,
      );
      final name = (await backup.query(
        'reports',
        where: 'ID = ?',
        whereArgs: ['s1'],
      )).single['신고명'];
      await backup.close();
      expect(name, '가져오기 2', reason: '마지막 가져오기 직전 DB');
      final dbPath = await LocalDbService.getDbPath();
      final base = File(dbPath).uri.pathSegments.last;
      final kept = File(dbPath).parent
          .listSync()
          .whereType<File>()
          .where(
            (f) => f.uri.pathSegments.last.startsWith('$base.before_import.'),
          )
          .length;
      expect(kept, LocalDbService.importBackupKeep);
    },
  );

  test(
    'the settings revert brings back the DB from before the last import, and can be undone (SOL-05 recheck)',
    () async {
      final dbFile = File(await LocalDbService.getDbPath());
      for (final f in dbFile.parent.listSync().whereType<File>()) {
        if (f.uri.pathSegments.last.contains('.before_import.')) f.deleteSync();
      }
      expect(
        await LocalDbService.revertToPreviousImport(),
        isFalse,
        reason: '사본이 없으면 아무것도 하지 않는다',
      );
      final a = await _serverDb(dir, watchlist: []);
      await alter(a, ["UPDATE mysafety_report SET 신고명 = 'A' WHERE ID='s1'"]);
      await LocalDbService.importFromServerDb(a);
      final b = await _serverDb(dir, watchlist: []);
      await alter(b, ["UPDATE mysafety_report SET 신고명 = 'B' WHERE ID='s1'"]);
      await LocalDbService.importFromServerDb(b);
      expect((await _row('s1'))['신고명'], 'B');
      expect(await LocalDbService.revertToPreviousImport(), isTrue);
      expect((await _row('s1'))['신고명'], 'A');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
        await LocalDbService.revertToPreviousImport(),
        isTrue,
        reason: '되돌리기 직전 DB(B)도 사본으로 남는다',
      );
      expect((await _row('s1'))['신고명'], 'B');
    },
  );
}
