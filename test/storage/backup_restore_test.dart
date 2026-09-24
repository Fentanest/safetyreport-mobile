// 앱 백업 복원(replaceFromBackup) — 교체 방식과 거부 조건 (저장 계층 재설계 R1d, M-11).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report(String id, String number) => Report(
      id: id,
      reportNumber: number,
      name: '신호위반',
      date: '2026-09-01',
      responseDate: '2026-09-10',
      agency: '기관',
      manager: '담당',
      status: '수용',
      result: '수용',
      fineInfo: '',
      penaltyPoints: '',
      carNumber: '12가3456',
      law: '',
      location: '서울 강서구 1',
      occurrenceDate: '2026-09-01',
      occurrenceTime: '08:00',
      reportContent: '본문',
      processContent: '처리',
    );

Future<Set<String>> _ids() async =>
    (await (await LocalDbService.db).query('reports', columns: ['ID'])).map((r) => r['ID'] as String).toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Directory files;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_backup_restore_test_');
    files = Directory('${dir.path}/files')..createSync();
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

  /// 현재 DB 에 [id] 한 건을 넣고 백업 파일로 내보낸 뒤, 라이브 DB 는 [liveId] 한 건만 남긴다.
  Future<String> makeBackup(String id, {int? version, List<String> dropColumns = const []}) async {
    await LocalDbService.upsertReport(_report(id, 'SPP-$id'), 'traffic', '자동차·교통위반-신호위반');
    final d = await LocalDbService.db;
    for (final c in dropColumns) {
      await d.execute('ALTER TABLE reports DROP COLUMN "$c"');
    }
    if (version != null) await d.setVersion(version);
    final path = '${files.path}/backup_${DateTime.now().microsecondsSinceEpoch}.db';
    await LocalDbService.exportBackup(path);
    await deleteDatabase(await LocalDbService.getDbPath());
    await LocalDbService.upsertReport(_report('live', 'SPP-live'), 'traffic', '자동차·교통위반-신호위반');
    return path;
  }

  test('older app backup is migrated and swapped in', () async {
    final path = await makeBackup('old-1', version: 10, dropColumns: ['사진_첫촬영', '사진_끝촬영', '사진_촬영수']);
    expect(await _ids(), {'live'});
    await LocalDbService.replaceFromBackup(path);
    expect(await _ids(), {'old-1'});
    final d = await LocalDbService.db;
    expect(await d.getVersion(), LocalDbService.dbVersion);
    final cols = (await d.rawQuery('PRAGMA table_info(reports)')).map((r) => r['name']).toSet();
    expect(cols, containsAll(['사진_첫촬영', '사진_촬영수']));
  });

  test('backup from a newer app is refused and the live DB is untouched', () async {
    final path = await makeBackup('new-1', version: LocalDbService.dbVersion + 1);
    await expectLater(LocalDbService.replaceFromBackup(path), throwsException);
    expect(await _ids(), {'live'});
  });

  test('a server DB is refused by the app backup restore', () async {
    final path = '${files.path}/server.db';
    final s = await openDatabase(path);
    await s.execute('CREATE TABLE mysafety (ID TEXT PRIMARY KEY)');
    await s.execute('CREATE TABLE mysafetymerge_traffic (ID TEXT PRIMARY KEY)');
    await s.close();
    await LocalDbService.upsertReport(_report('live', 'SPP-live'), 'traffic', '자동차·교통위반-신호위반');
    await expectLater(LocalDbService.replaceFromBackup(path), throwsException);
    expect(await _ids(), {'live'});
  });

  test('no staging directories are left behind', () async {
    final path = await makeBackup('old-2', version: 11, dropColumns: []);
    await LocalDbService.replaceFromBackup(path);
    final leftovers = Directory.systemTemp.listSync().where((e) => e.path.contains('mysafetyreport_restore_staged_'));
    expect(leftovers, isEmpty);
  });
}
