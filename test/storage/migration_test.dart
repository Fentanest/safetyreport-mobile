// 구버전 모바일 DB(v9·v10·v14) — 2026-09-26 초기화 크롤링 릴리스(이전 DB 업데이트 로직 비활성).
// 견본은 현재 스키마에서 해당 버전 이후 추가된 것만 걷어 내 만든다(git 이력상 v10 = v11 - 사진 3열, v9 = v10 - 지오코딩 5열·geocode_cache).
// 이전 버전 DB 는 옮기지 않는다: 통째로 백업한 뒤 비우고(감시목록·지오코딩 캐시만 남김) 계약 버전의 빈 DB 로 연다.
// 서버 tests/test_storage_migration.py 와 같은 규칙.
// v16 → 17(2026-10-11)은 예외: 다른 버전과 달리 비우지 않고 제자리 변환([LocalDbService.migrateInPlace])한다 —
// 아래 "migrateInPlace" 그룹을 본다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _photo = ['사진_첫촬영', '사진_끝촬영', '사진_촬영수'];
const _geo = ['주소정규화', '행정구역', '위도', '경도', '지오코딩상태'];

Report _report(int i) => Report(
  id: 'm-$i',
  reportNumber: 'SPP-2609-00001$i',
  name: i.isEven ? '신호위반' : '불법주정차신고',
  date: '2026-09-0$i',
  responseDate: i == 3 ? '' : '2026-09-1$i',
  agency: '서울특별시 강서경찰서 교통과',
  manager: i == 2 ? '' : '김담당',
  status: i == 3 ? '처리중' : '수용',
  result: i == 3 ? '처리중' : '수용',
  fineInfo: i.isEven ? '과태료' : '',
  penaltyPoints: '',
  carNumber: '1$i가345$i',
  law: '도로교통법 제5조',
  location: '서울특별시 강서구 마곡동 $i',
  occurrenceDate: '2026-09-0$i',
  occurrenceTime: '08:0$i',
  reportContent: '본문 $i\n둘째 줄 "따옴표"',
  processContent: '처리 $i',
  rating: i == 1 ? 4 : null,
  ratingCause: i == 1 ? '빠른 처리' : '',
  pollStatus: i == 1 ? '참여 완료' : '참여 가능',
);

Future<void> _reset() async {
  await LocalDbService.closeDb();
  final path = await LocalDbService.getDbPath();
  await deleteDatabase(path);
  for (final ext in ['-wal', '-shm']) {
    final f = File('$path$ext');
    if (f.existsSync()) await f.delete();
  }
}

/// 현재 코드로 DB 를 만들고 행을 넣은 뒤, 지정 버전 이후 추가분을 걷어 내 구버전 파일로 되돌린다.
Future<List<Map<String, Object?>>> _makeOldDb(int version) async {
  for (var i = 1; i <= 3; i++) {
    await LocalDbService.upsertReport(
      _report(i),
      i.isEven ? 'traffic' : 'parking',
      i.isEven ? '자동차·교통위반-신호위반' : '불법주정차신고-기타',
    );
  }
  await LocalDbService.setWatchlistNumbers({'SPP-2609-000012'});
  var db = await LocalDbService.db;
  final removed = [..._photo, if (version <= 9) ..._geo];
  await (await LocalDbService.db).execute(
    'DROP VIEW IF EXISTS ${LocalDbService.effectiveReportsView}',
  ); // 보기가 참조하는 열은 못 지운다
  for (final col in removed) {
    await db.execute('ALTER TABLE reports DROP COLUMN "$col"');
  }
  if (version <= 9) await db.execute('DROP TABLE geocode_cache');
  await db.setVersion(version);
  final rows = await db.query('reports', orderBy: 'ID');
  await LocalDbService.closeDb();
  return rows;
}

/// 버전 16 DB(SSNPC 열 추가 전, [LocalDbService.migrateInPlace] 대상) — 지금 스키마에서
/// ssnpc_cd·ssnpc_type 만 걷어 내 만든다. 생활불편 신고 한 건은 3분류 시절처럼 'other' 로 잘못 저장된
/// 채 두고(지금 분류기라면 'living'), 사용자 소유 자료(수정값·중복 판단·중복 멤버·감시목록)도 같이 넣어
/// 제자리 변환이 신고가 아닌 것은 건드리지 않는지 본다.
Future<void> _makeV16Db() async {
  await LocalDbService.upsertReport(
    _report(2), // 'm-2', traffic — 이미 맞는 분류라 변환으로 바뀌지 않아야 한다
    'traffic',
    '자동차·교통위반-신호위반',
  );
  final db = await LocalDbService.db;
  await db.insert('reports', {
    'ID': 'm-living',
    '신고번호': 'SPP-2609-000099',
    '신고명': '쓰레기 방치',
    'category': 'other', // 3분류 시절 오분류 — 지금 분류기(DR-06)라면 living
    'entry_value': '생활불편 신고-쓰레기, 폐기물',
  });
  await db.insert('report_override', {
    'ID': 'm-living',
    'column_name': '처리상태',
    'value': '불수용',
    'updated_at': 1,
  });
  await db.insert('duplicate_group', {
    'group_id': 'g1',
    'fingerprint': 'fp',
    'match_type': 'payload_exact',
    'status': 'confirmed_duplicate',
    'representative_mode': 'auto',
    'representative_id': 'm-living',
    'member_count': 1,
    'apply_globally': 1,
    'note': '',
    'created_at': 1,
    'updated_at': 1,
  });
  await db.insert('duplicate_member', {
    'group_id': 'g1',
    'report_id': 'm-living',
    'report_number': 'SPP-2609-000099',
    'category': 'other', // 변환이 신고와 같이 이 사본도 living 으로 갱신해야 한다
    'is_representative': 1,
    'priority_score': 1,
    'raw_match': 1,
    'field_match': 1,
    'created_at': 1,
    'updated_at': 1,
  });
  await db.insert('duplicate_decision', {
    'group_id': 'g1',
    'status': 'confirmed_duplicate',
    'representative_mode': 'auto',
    'representative_id': 'm-living',
    'apply_globally': 1,
    'note': '',
    'updated_at': 1,
  });
  await LocalDbService.setWatchlistNumbers({'SPP-2609-000099'});
  await db.execute(
    'DROP VIEW IF EXISTS ${LocalDbService.effectiveReportsView}',
  ); // 보기가 참조하는 열은 못 지운다
  await db.execute('ALTER TABLE reports DROP COLUMN "ssnpc_cd"');
  await db.execute('ALTER TABLE reports DROP COLUMN "ssnpc_type"');
  await db.setVersion(16);
  await LocalDbService.closeDb();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final contract =
      jsonDecode(File('contracts/storage-contract.json').readAsStringSync())
          as Map<String, dynamic>;
  final reportContract = (contract['entities'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((e) => e['entity'] == 'report');
  final contractColumns = (reportContract['columns'] as List)
      .cast<Map<String, dynamic>>()
      .where((c) => c['mobile'] == true)
      .map((c) => c['name'] as String)
      .toSet();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_migration_test_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _reset();
  });
  tearDownAll(() async {
    await _reset();
    dir.deleteSync(recursive: true);
  });

  List<File> legacyBackups(String path) {
    final folder = File(path).parent;
    final name = File(path).uri.pathSegments.last;
    return folder
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('$name.legacy_v'))
        .toList();
  }

  List<File> preUpgradeBackups(String path) {
    final folder = File(path).parent;
    final name = File(path).uri.pathSegments.last;
    return folder
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('$name.pre_v'))
        .toList();
  }

  for (final version in [14, 10, 9]) {
    test(
      'v$version database is backed up whole, then emptied to the contract version (no migration)',
      () async {
        final before = await _makeOldDb(version);
        final path = await LocalDbService.getDbPath();
        if (version >= 10) {
          final raw = await openDatabase(path);
          await raw.insert('geocode_cache', {'주소정규화': '서울 강서구 1', '위도': 37.5, '경도': 126.8, '상태': 'ok'});
          await raw.close();
        }
        for (final f in legacyBackups(path)) {
          f.deleteSync();
        }

        final db = await LocalDbService.db; // 여기서 이전 DB 비우기가 돈다(마이그레이션 없음)
        expect(await db.getVersion(), (contract['schema_version'] as Map)['mobile']);
        final cols = (await db.rawQuery('PRAGMA table_info(reports)'))
            .map((r) => r['name'] as String)
            .toSet();
        expect(cols, contractColumns);
        expect(await db.query('reports'), isEmpty, reason: '신고는 초기화 크롤링이 다시 채운다');
        expect(await LocalDbService.getWatchlistNumbers(), {'SPP-2609-000012'}, reason: '감시목록은 남긴다');
        final cache = await db.query('geocode_cache');
        expect(cache.map((r) => r['주소정규화']), version >= 10 ? ['서울 강서구 1'] : isEmpty);

        // 백업: 비우기 전 그대로(버전·행)
        final backups = legacyBackups(path);
        expect(backups, hasLength(1));
        expect(backups.single.path, contains('.legacy_v$version.'));
        final copy = await openDatabase(backups.single.path, readOnly: true, singleInstance: false);
        expect(await copy.getVersion(), version);
        expect((await copy.query('reports', orderBy: 'ID')).map((r) => r['ID']), before.map((r) => r['ID']));
        await copy.close();
        expect(preUpgradeBackups(path), isEmpty, reason: '업그레이드 전 백업(업데이트 로직)은 꺼져 있다');

        // 안내용 기록과 새 설치 판정
        final facts = await LocalDbService.personalDbFacts();
        expect(facts.reports, 0);
        expect(facts.legacyReset?['from_version'], version);
        expect(facts.legacyReset?['backup'], backups.single.path);
        expect(facts.legacyReset?['kept'], ['watchlist', if (version >= 10) 'geocode_cache']);

        // 다시 열어도 새 백업·비우기 없음
        await LocalDbService.closeDb();
        await LocalDbService.db;
        expect(legacyBackups(path), hasLength(1));
        expect((await LocalDbService.personalDbFacts()).legacyReset?['backup'], backups.single.path);
        for (final f in legacyBackups(path)) {
          f.deleteSync();
        }
      },
    );
  }

  test('the backup keeps a write that is still only in the WAL (checkpoint blocked by a reader)', () async {
    await _makeOldDb(10);
    final path = await LocalDbService.getDbPath();
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
    final writer = await openDatabase(path, singleInstance: false);
    await writer.rawQuery('PRAGMA journal_mode=WAL');
    await writer.rawQuery('PRAGMA wal_autocheckpoint=0');
    final reader = await openDatabase(path, singleInstance: false);
    await reader.execute('BEGIN');
    await reader.rawQuery('SELECT count(*) FROM reports'); // 이 스냅샷이 있는 동안 WAL 을 본 파일로 다 옮기지 못한다
    await writer.insert('reports', {'ID': 'wal-only', '신고번호': 'SPP-WAL'});
    try {
      final info = await LocalDbService.resetLegacyDatabase(path, beforeReset: () async {});
      final copy = await openDatabase(info!['backup'] as String, readOnly: true, singleInstance: false);
      expect((await copy.query('reports', where: 'ID = ?', whereArgs: ['wal-only'])), hasLength(1),
          reason: 'WAL 에만 있던 행도 백업에 들어간다');
      expect(await copy.getVersion(), 10);
      await copy.close();
    } finally {
      await reader.execute('COMMIT');
      await reader.close();
      await writer.close();
    }
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
  });

  test('the old DB is emptied in place: a connection opened before sees the new DB, the file stays whole', () async {
    // 열린 DB 의 WAL 삭제·파일 이름 교체를 하지 않는다(Sol 재검증 3). 먼저 열어 둔 연결이 옛 파일을 계속 보거나 손상된 파일을 보지 않는다.
    await _makeOldDb(10);
    final path = await LocalDbService.getDbPath();
    final early = await openDatabase(path, singleInstance: false);
    await early.rawQuery('PRAGMA journal_mode=WAL');
    try {
      await LocalDbService.resetLegacyDatabase(path, beforeReset: () async {});
      expect(await early.getVersion(), LocalDbService.dbVersion);
      expect((await early.rawQuery('SELECT count(*) AS n FROM reports')).first['n'], 0);
      expect((await early.rawQuery('PRAGMA integrity_check')).first.values.first, 'ok');
      expect(File('$path.legacy_reset_staging').existsSync(), isFalse);
    } finally {
      await early.close();
    }
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
  });

  test('a write attempted while the old DB is being emptied fails instead of being lost', () async {
    await _makeOldDb(10);
    final path = await LocalDbService.getDbPath();
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
    Object? writeError;
    final info = await LocalDbService.resetLegacyDatabase(path, beforeReset: () async {
      final other = await openDatabase(path, singleInstance: false);
      try {
        await other.rawQuery('PRAGMA busy_timeout=200');
        await other.insert('reports', {'ID': 'late', '신고번호': 'SPP-LATE'});
      } catch (e) {
        writeError = e;
      } finally {
        await other.close();
      }
    });
    expect(writeError, isNotNull, reason: '백업 뒤 교체 전 쓰기는 잠김으로 실패해야 한다(조용히 사라지지 않게)');
    expect(info, isNotNull);
    final db = await LocalDbService.db;
    expect(await db.query('reports'), isEmpty);
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
  });

  test('an old demo DB is emptied without rotating the real account community dataset', () async {
    SharedPreferences.setMockInitialValues({AppPrefsKeys.standaloneDemoMode: true});
    await _makeOldDb(10);
    final path = await LocalDbService.getDbPath();
    expect(path, endsWith(LocalDbService.demoDbFileName));
    final store = await CommunityStore.open();
    final before = await store.localDatasetId();
    await LocalDbService.db;
    expect(await store.localDatasetId(), before);
    expect((await LocalDbService.personalDbFacts()).legacyReset?['from_version'], 10);
    await LocalDbService.closeDb();
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
    // 실제 계정 DB 를 비울 때는 선회전한다.
    SharedPreferences.setMockInitialValues({});
    await _reset();
    await _makeOldDb(10);
    await LocalDbService.db;
    expect(await store.localDatasetId(), isNot(before));
    final realPath = await LocalDbService.getDbPath();
    for (final f in legacyBackups(realPath)) {
      f.deleteSync();
    }
  });

  test('an old DB with a virtual table (and its shadow tables) is backed up and emptied', () async {
    await _makeOldDb(10);
    final path = await LocalDbService.getDbPath();
    final raw = await openDatabase(path, singleInstance: false);
    await raw.execute('CREATE VIRTUAL TABLE old_search USING fts5(body)');
    await raw.insert('old_search', {'body': '옛 검색 색인'});
    await raw.close();
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
    final info = await LocalDbService.resetLegacyDatabase(path, beforeReset: () async {});
    expect(info, isNotNull);
    final db = await openDatabase(path, singleInstance: false);
    expect(await db.getVersion(), LocalDbService.dbVersion);
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name LIKE 'old_search%'"), isEmpty);
    await db.close();
    final copy = await openDatabase(info!['backup'] as String, readOnly: true, singleInstance: false);
    expect((await copy.rawQuery("SELECT body FROM old_search WHERE old_search MATCH '검색'")), hasLength(1));
    await copy.close();
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
  });

  test('a failing step before the reset leaves the old DB as it was', () async {
    final before = await _makeOldDb(10);
    final path = await LocalDbService.getDbPath();
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
    await expectLater(
      LocalDbService.resetLegacyDatabase(path, beforeReset: () async => throw StateError('no community store')),
      throwsStateError,
    );
    final raw = await openDatabase(path, singleInstance: false);
    expect(await raw.getVersion(), 10);
    expect((await raw.query('reports')).length, before.length);
    await raw.close();
    expect(File('$path.legacy_reset_staging').existsSync(), isFalse);
    expect(legacyBackups(path), hasLength(1), reason: '백업은 남는다');
    for (final f in legacyBackups(path)) {
      f.deleteSync();
    }
  });

  test('a new install and a current DB are left alone', () async {
    final path = await LocalDbService.getDbPath();
    expect(await LocalDbService.resetLegacyDatabase(path), isNull); // 파일 없음
    final db = await LocalDbService.db;
    expect(await db.getVersion(), LocalDbService.dbVersion);
    await LocalDbService.closeDb();
    expect(await LocalDbService.resetLegacyDatabase(path), isNull); // 이미 최신
    final facts = await LocalDbService.personalDbFacts();
    expect(facts.reports, 0);
    expect(facts.legacyReset, isNull);
    expect(legacyBackups(path), isEmpty);
  });

  // ── migrateInPlace: v16 → 17 제자리 변환(2026-10-11) ─────────────────────────

  List<File> inPlaceBackups(String path) {
    final folder = File(path).parent;
    final name = File(path).uri.pathSegments.last;
    return folder
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('$name.before_v17.'))
        .toList();
  }

  test(
    'migrateInPlace: v16 → 17 는 entry_value 로 category 를 다시 정하고, 중복 멤버 사본도 갱신하고, 백업을 남긴다',
    () async {
      await _makeV16Db();
      final path = await LocalDbService.getDbPath();
      for (final f in inPlaceBackups(path)) {
        f.deleteSync();
      }

      final info = await LocalDbService.migrateInPlace(path);
      expect(info, isNotNull);
      expect(info!['from_version'], 16);
      expect(info['reports'], 2);
      expect(info['moved_categories'], 1, reason: '생활불편 신고 한 건만 other → living 으로 옮긴다');

      final backupPath = info['backup'] as String;
      expect(File(backupPath).existsSync(), isTrue);
      final backup = await openDatabase(backupPath, readOnly: true, singleInstance: false);
      expect(await backup.getVersion(), 16, reason: '백업은 변환 전 버전 그대로');
      expect(
        (await backup.query('reports', where: 'ID = ?', whereArgs: ['m-living'])).single['category'],
        'other',
        reason: '백업은 변환 전 값 그대로',
      );
      await backup.close();

      final db = await openDatabase(path, singleInstance: false);
      expect(await db.getVersion(), LocalDbService.dbVersion);
      final cols = (await db.rawQuery('PRAGMA table_info(reports)')).map((r) => r['name'] as String).toSet();
      expect(cols, containsAll(['ssnpc_cd', 'ssnpc_type']));
      final living = (await db.query('reports', where: 'ID = ?', whereArgs: ['m-living'])).single;
      expect(living['category'], 'living', reason: '생활불편 메뉴의 "쓰레기, 폐기물" 은 지금 분류기로 living(DR-06)');
      expect(living['신고명'], '쓰레기 방치', reason: '분류 외 값은 그대로');
      expect(living['entry_value'], '생활불편 신고-쓰레기, 폐기물');
      final traffic = (await db.query('reports', where: 'ID = ?', whereArgs: ['m-2'])).single;
      expect(traffic['category'], 'traffic', reason: '이미 맞는 분류는 바뀌지 않는다(moved_categories 에 세지 않음)');
      final member = (await db.query('duplicate_member', where: 'report_id = ?', whereArgs: ['m-living'])).single;
      expect(member['category'], 'living', reason: '중복 멤버의 category 사본도 같이 갱신된다');
      expect(
        await db.query('report_override', where: 'ID = ?', whereArgs: ['m-living']),
        hasLength(1),
        reason: '사용자 수정값은 제자리 변환이 건드리지 않는다',
      );
      expect(
        await db.query('duplicate_decision', where: 'group_id = ?', whereArgs: ['g1']),
        hasLength(1),
      );
      await db.close();

      expect(
        await LocalDbService.migrateInPlace(path),
        isNull,
        reason: '이미 17 이면 할 일이 없다(두 번째 호출)',
      );

      // 이후 정상 경로로 열어도 문제 없다 — 신고 2건·감시목록 그대로.
      await LocalDbService.closeDb();
      final opened = await LocalDbService.db;
      expect(await opened.getVersion(), LocalDbService.dbVersion);
      expect(await opened.query('reports'), hasLength(2));
      expect(await LocalDbService.getWatchlistNumbers(), {'SPP-2609-000099'});

      for (final f in inPlaceBackups(path)) {
        f.deleteSync();
      }
    },
  );

  test('a v15 DB still goes through resetLegacyDatabase; a v16 DB does not(제자리 변환 몫)', () async {
    await _makeOldDb(15);
    final path15 = await LocalDbService.getDbPath();
    for (final f in legacyBackups(path15)) {
      f.deleteSync();
    }
    final reset15 = await LocalDbService.resetLegacyDatabase(path15, beforeReset: () async {});
    expect(reset15, isNotNull);
    expect(reset15!['from_version'], 15);
    for (final f in legacyBackups(path15)) {
      f.deleteSync();
    }

    await _reset();
    await _makeOldDb(16);
    final path16 = await LocalDbService.getDbPath();
    expect(
      await LocalDbService.resetLegacyDatabase(path16, beforeReset: () async {}),
      isNull,
      reason: 'v16 은 migrateInPlace 몫이다 — resetLegacyDatabase 는 손대지 않는다',
    );
    for (final f in inPlaceBackups(path16)) {
      f.deleteSync();
    }
  });
}
