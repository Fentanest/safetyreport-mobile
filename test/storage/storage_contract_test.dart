// 저장 계약(contracts/storage-contract.json) ↔ 모바일 스키마 일치 (저장 계층 재설계 R0, 서버 레포 docs/plans/storage-refactor-plan.md).
// 서버 레포의 같은 파일과 바이트 동일해야 한다(서버 scripts/dev/db_roundtrip_check.py 가 sha256 비교).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _sqlTypes = {'TEXT': 'text', 'INTEGER': 'integer', 'REAL': 'real'};

Map<String, dynamic> _contract() =>
    jsonDecode(File('contracts/storage-contract.json').readAsStringSync())
        as Map<String, dynamic>;

Future<Map<String, String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info("$table")');
  return {
    for (final r in rows)
      r['name'] as String:
          '${_sqlTypes[(r['type'] as String).toUpperCase()]}|${(r['pk'] as int) > 0}',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_contract_test_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  test('every mobile table matches the storage contract', () async {
    final db = await LocalDbService.db;
    final contract = _contract();
    for (final entity
        in (contract['entities'] as List).cast<Map<String, dynamic>>()) {
      final table = entity['mobile_table'] as String?;
      if (table == null) continue;
      final expected = <String, String>{
        for (final c
            in (entity['columns'] as List).cast<Map<String, dynamic>>())
          if (c['mobile'] == true)
            c['name'] as String: '${c['type']}|${c['pk'] == true}',
      };
      expect(
        await _columns(db, table),
        expected,
        reason: 'entity ${entity['entity']} → $table',
      );
    }
  });

  test('no mobile table is missing from the contract', () async {
    final db = await LocalDbService.db;
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
    )).map((r) => r['name'] as String).toSet();
    final covered = (_contract()['entities'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => e['mobile_table'] as String?)
        .whereType<String>()
        .toSet();
    expect(tables, covered);
  });

  test(
    'change-tracked columns match the contract (server uses the same list)',
    () {
      final contract = _contract()['change_tracked'] as Map<String, dynamic>;
      expect(
        LocalDbService.syncedAtTrackedKeysForTest
            .where((k) => k != 'category' && k != 'entry_value')
            .toList(),
        (contract['columns'] as List).cast<String>(),
      );
    },
  );

  test('schema version in contract matches the app', () async {
    final db = await LocalDbService.db;
    expect(
      await db.getVersion(),
      (_contract()['schema_version'] as Map)['mobile'],
    );
  });
}
