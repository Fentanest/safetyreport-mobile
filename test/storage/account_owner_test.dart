// 신고 자료의 주인 = 로그인한 카카오 계정 (2026-09-27 사용자 결정, 서버 tests/test_account_data.py 와 같은 규칙).
// - 게이트 통과 뒤 처음이면 DB 에 카카오 회원번호를 적고, 다르면 mismatch.
// - 카카오 로그아웃은 신고 자료만 지운다(감시목록·지오코딩 캐시 유지), 동기화·지도 변환 중이면 아무것도 지우지 않는다.
// - 가져오기·복원은 주인이 같은 DB 만 받는다(주인 없는 DB·다른 계정 DB·로그인 확인 불가 거절, 무엇이든 바꾸기 전에).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report(int i) => Report(
  id: 'm-$i',
  reportNumber: 'SPP-2609-00001$i',
  name: '신호위반',
  date: '2026-09-0$i',
  responseDate: '2026-09-1$i',
  agency: '서울특별시 강서경찰서 교통과',
  manager: '김담당',
  status: '수용',
  result: '수용',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '1$i가3451',
  law: '도로교통법 제5조',
  location: '서울특별시 강서구 마곡동 $i',
  occurrenceDate: '2026-09-0$i',
  occurrenceTime: '08:0$i',
  reportContent: '본문 $i',
  processContent: '처리 $i',
  rating: null,
  ratingCause: '',
  pollStatus: '참여 가능',
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

Future<void> _seed() async {
  for (var i = 1; i <= 3; i++) {
    await LocalDbService.upsertReport(_report(i), 'traffic', '자동차·교통위반-신호위반');
  }
  await LocalDbService.setWatchlistNumbers({'SPP-2609-000012'});
  await (await LocalDbService.db).insert('geocode_cache', {
    '주소정규화': '남길 주소',
    '상태': 'ok',
    'source': 'kakao',
  });
}

Future<int> _count(String table) async =>
    (await (await LocalDbService.db).rawQuery('SELECT count(*) AS n FROM $table')).first['n'] as int;

/// 지금 스키마의 서버 DB(최소 열) — 주인 [owner] 를 mysafety_sync_meta 에 적는다.
Future<String> _serverDb(Directory dir, String? owner) async {
  final path = '${dir.path}/server_${DateTime.now().microsecondsSinceEpoch}.db';
  final db = await openDatabase(path);
  await db.setVersion(LocalDbService.serverSchemaVersion);
  await db.execute(
    '''CREATE TABLE mysafetymerge_traffic (ID TEXT PRIMARY KEY, 상태 TEXT, 신고번호 TEXT, 신고명 TEXT, 신고일 TEXT,
    만족도조사여부 TEXT, 별점 INTEGER, 별점사유 TEXT, 감시목록 TEXT, 처리상태 TEXT, 처리기관 TEXT, 담당자 TEXT, 위반장소 TEXT,
    주소정규화 TEXT, 행정구역 TEXT, 위도 REAL, 경도 REAL, 지오코딩상태 TEXT, 종결여부 TEXT, synced_at INTEGER, 보완횟수 INTEGER)''',
  );
  await db.execute('CREATE TABLE mysafetymerge_parking AS SELECT * FROM mysafetymerge_traffic WHERE 0');
  await db.execute('CREATE TABLE mysafetymerge_other AS SELECT * FROM mysafetymerge_traffic WHERE 0');
  await db.execute('CREATE TABLE mysafety_watchlist (신고번호 TEXT PRIMARY KEY)');
  await db.execute('CREATE TABLE mysafety_sync_meta (key TEXT PRIMARY KEY, value TEXT)');
  await db.execute('CREATE TABLE mysafety (ID TEXT PRIMARY KEY)');
  await db.insert('mysafetymerge_traffic', {
    'ID': 's1',
    '상태': '수용',
    '신고번호': 'SPP-S1',
    '신고명': '신호위반',
    '신고일': '2026-09-01',
    '감시목록': 'N',
    '처리상태': '수용',
    '처리기관': '기관',
    '위반장소': '서울 강서구 1',
    '종결여부': 'Y',
  });
  if (owner != null) {
    await db.insert('mysafety_sync_meta', {'key': LocalDbService.kakaoMemberMetaKey, 'value': owner});
  }
  await db.close();
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final defaultProvider = LocalDbService.currentKakaoId;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_account_owner_test_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LocalDbService.currentKakaoId = () async => '910001';
    await _reset();
    await _seed();
  });
  tearDown(() => LocalDbService.currentKakaoId = defaultProvider);
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  test('first login stamps the owner, the same account is ok, another account is a mismatch', () async {
    expect(await LocalDbService.dbOwner(), isNull);
    expect(await LocalDbService.checkOwner('910001'), 'ok');
    expect(await LocalDbService.dbOwner(), '910001');
    expect(await LocalDbService.checkOwner('910001'), 'ok');
    expect(await LocalDbService.checkOwner('910002'), 'mismatch');
    expect(await LocalDbService.dbOwner(), '910001', reason: '다른 계정이 와도 주인은 바뀌지 않는다');
    expect(await LocalDbService.checkOwner(null), 'unknown');
    expect(await LocalDbService.checkOwner(''), 'unknown');
  });

  test('logout wipe empties the reports only and clears the owner', () async {
    await LocalDbService.checkOwner('910001');
    await (await LocalDbService.db).insert('report_override', {
      'ID': 'm-1',
      'column_name': '처리상태',
      'value': '불수용',
      'updated_at': 1,
    });
    final store = await CommunityStore.open();
    final dataset = await store.localDatasetId();
    expect(await _count('reports'), 3);
    final info = await LocalDbService.wipeReportData('kakao_logout');
    expect(await store.localDatasetId(), isNot(dataset), reason: '지운 자료의 공유 대기 사본이 다음 계정으로 가지 않게 먼저 선회전');
    expect(await _count('reports'), 0);
    expect(await _count('report_override'), 0);
    expect(await LocalDbService.getWatchlistNumbers(), {'SPP-2609-000012'});
    expect(await _count('geocode_cache'), 1);
    expect(await LocalDbService.dbOwner(), isNull, reason: '비운 DB 는 다음 로그인 계정이 주인이 된다');
    expect(info['kept'], LocalDbService.legacyKept);
    final db = await LocalDbService.db;
    expect(await db.getVersion(), LocalDbService.dbVersion);
    expect((await db.rawQuery('PRAGMA integrity_check')).first.values.first, 'ok');
    // 비운 뒤에도 앱이 쓰는 보기·검색이 그대로 동작한다
    expect(await db.query(LocalDbService.effectiveReportsView), isEmpty);
    await LocalDbService.upsertReport(_report(1), 'traffic', '자동차·교통위반-신호위반');
    expect(await db.query(LocalDbService.effectiveReportsView), hasLength(1));
  });

  test('adopt wipes and stamps the new owner', () async {
    await LocalDbService.checkOwner('910001');
    await LocalDbService.wipeReportData('db_owner_adopt', thenOwner: '910002');
    expect(await _count('reports'), 0);
    expect(await LocalDbService.dbOwner(), '910002');
    expect(await LocalDbService.checkOwner('910002'), 'ok');
  });

  test('nothing is wiped while sync or map conversion is running', () async {
    await LocalDbService.checkOwner('910001');
    final release = Completer<void>();
    final work = LocalDbService.runBackgroundWork(() => release.future);
    try {
      await expectLater(LocalDbService.wipeReportData('kakao_logout'), throwsA(isA<DbBusyException>()));
    } finally {
      release.complete();
      await work;
    }
    expect(await _count('reports'), 3);
    expect(await LocalDbService.dbOwner(), '910001');
  });

  group('import refusal', () {
    setUp(() async => LocalDbService.checkOwner('910001'));

    test('a server DB of another account, without an owner, or without a known login is refused before anything changes', () async {
      for (final (owner, current) in [('910002', '910001'), (null, '910001'), ('910001', null)]) {
        LocalDbService.currentKakaoId = () async => current;
        final path = await _serverDb(dir, owner);
        await expectLater(LocalDbService.importFromServerDb(path), throwsA(isA<ForeignDatabaseException>()),
            reason: '$owner/$current');
        expect(await _count('reports'), 3);
        expect(await LocalDbService.dbOwner(), '910001');
      }
    });

    test('a server DB of the same account is imported and keeps the owner', () async {
      final path = await _serverDb(dir, '910001');
      expect(await LocalDbService.importFromServerDb(path), 1);
      expect(await LocalDbService.dbOwner(), '910001');
    });

    test('a mobile backup of another account or without an owner is refused (revert uses the same path)', () async {
      final live = await LocalDbService.getDbPath();
      await LocalDbService.closeDb();
      for (final owner in ['910002', null]) {
        final copy = '${dir.path}/backup_${owner ?? 'none'}.db';
        await File(live).copy(copy);
        final db = await openDatabase(copy, singleInstance: false);
        if (owner == null) {
          await db.delete('sync_meta', where: 'key = ?', whereArgs: [LocalDbService.kakaoMemberMetaKey]);
        } else {
          await db.update('sync_meta', {'value': owner}, where: 'key = ?', whereArgs: [LocalDbService.kakaoMemberMetaKey]);
        }
        await db.close();
        await expectLater(LocalDbService.replaceFromBackup(copy), throwsA(isA<ForeignDatabaseException>()),
            reason: '$owner');
        expect(await _count('reports'), 3);
        expect(await LocalDbService.dbOwner(), '910001');
      }
      final same = '${dir.path}/backup_same.db';
      await LocalDbService.closeDb();
      await File(live).copy(same);
      await LocalDbService.replaceFromBackup(same);
      expect(await _count('reports'), 3);
      expect(await LocalDbService.dbOwner(), '910001');
    });
  });
}
