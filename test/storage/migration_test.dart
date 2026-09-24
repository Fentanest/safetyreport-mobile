// 구버전 모바일 DB(v9·v10) → 현재 버전 업그레이드 (저장 계층 재설계 R0).
// 견본은 현재 스키마에서 해당 버전 이후 추가된 것만 걷어 내 만든다(git 이력상 v10 = v11 - 사진 3열, v9 = v10 - 지오코딩 5열·geocode_cache).
// 업그레이드 뒤: 계약과 스키마가 일치하고, 이전부터 있던 열의 값이 그대로인지 확인한다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
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
    await LocalDbService.upsertReport(_report(i), i.isEven ? 'traffic' : 'parking', i.isEven ? '자동차·교통위반-신호위반' : '불법주정차신고-기타');
  }
  await LocalDbService.setWatchlistNumbers({'SPP-2609-000012'});
  var db = await LocalDbService.db;
  final removed = [..._photo, if (version <= 9) ..._geo];
  for (final col in removed) {
    await db.execute('ALTER TABLE reports DROP COLUMN "$col"');
  }
  if (version <= 9) await db.execute('DROP TABLE geocode_cache');
  await db.setVersion(version);
  final rows = await db.query('reports', orderBy: 'ID');
  await LocalDbService.closeDb();
  return rows;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final contract = jsonDecode(File('contracts/storage-contract.json').readAsStringSync()) as Map<String, dynamic>;
  final reportContract = (contract['entities'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['entity'] == 'report');
  final contractColumns = (reportContract['columns'] as List).cast<Map<String, dynamic>>().where((c) => c['mobile'] == true).map((c) => c['name'] as String).toSet();

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

  for (final version in [10, 9]) {
    test('v$version database upgrades to the contract version and keeps existing values', () async {
      final before = await _makeOldDb(version);
      final raw = await openDatabase(await LocalDbService.getDbPath());
      expect(await raw.getVersion(), version);
      final oldCols = (await raw.rawQuery('PRAGMA table_info(reports)')).map((r) => r['name']).toSet();
      expect(oldCols.containsAll(_photo), isFalse);
      await raw.close();

      final db = await LocalDbService.db; // 여기서 마이그레이션이 돈다
      expect(await db.getVersion(), (contract['schema_version'] as Map)['mobile']);
      final cols = (await db.rawQuery('PRAGMA table_info(reports)')).map((r) => r['name'] as String).toSet();
      expect(cols, contractColumns);
      for (final table in ['geocode_cache', 'report_override', 'duplicate_decision']) {
        expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name=?", [table]), isNotEmpty, reason: table);
      }

      final after = await db.query('reports', orderBy: 'ID');
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        for (final entry in before[i].entries) {
          expect(after[i][entry.key], entry.value, reason: '${before[i]['ID']}.${entry.key}');
        }
        for (final col in _photo) {
          expect(after[i][col], isNull, reason: '${before[i]['ID']}.$col');
        }
      }
      expect(await LocalDbService.getWatchlistNumbers(), {'SPP-2609-000012'});
    });
  }
}
