// 앱 백업 복원(replaceFromBackup) — 교체 방식과 거부 조건 (저장 계층 재설계 R1d, M-11).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/kakao_owner.dart';

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

Future<Set<String>> _ids() async => (await (await LocalDbService.db).query(
  'reports',
  columns: ['ID'],
)).map((r) => r['ID'] as String).toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Directory files;
  useTestKakaoAccount();

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
    await stampOwner(
      await LocalDbService.db,
    ); // 게이트가 적는 이 기기 DB 의 주인 — 백업에 함께 들어간다
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  /// 현재 DB 에 [id] 한 건을 넣고 백업 파일로 내보낸 뒤, 라이브 DB 는 [liveId] 한 건만 남긴다.
  Future<String> makeBackup(
    String id, {
    int? version,
    List<String> dropColumns = const [],
  }) async {
    await LocalDbService.upsertReport(
      _report(id, 'SPP-$id'),
      'traffic',
      '자동차·교통위반-신호위반',
    );
    final d = await LocalDbService.db;
    await (await LocalDbService.db).execute(
      'DROP VIEW IF EXISTS ${LocalDbService.effectiveReportsView}',
    ); // 보기가 참조하는 열은 못 지운다
    for (final c in dropColumns) {
      await d.execute('ALTER TABLE reports DROP COLUMN "$c"');
    }
    if (version != null) await d.setVersion(version);
    final path =
        '${files.path}/backup_${DateTime.now().microsecondsSinceEpoch}.db';
    await LocalDbService.exportBackup(path);
    await deleteDatabase(await LocalDbService.getDbPath());
    await LocalDbService.upsertReport(
      _report('live', 'SPP-live'),
      'traffic',
      '자동차·교통위반-신호위반',
    );
    return path;
  }

  for (final version in [10, 11, 14]) {
    test(
      'older app backup (v$version) is refused, not migrated, and the live DB is untouched',
      () async {
        final path = await makeBackup(
          'old-$version',
          version: version,
          dropColumns: version <= 10 ? ['사진_첫촬영', '사진_끝촬영', '사진_촬영수'] : [],
        );
        expect(await _ids(), {'live'});
        await expectLater(
          LocalDbService.replaceFromBackup(path),
          throwsA(
            isA<LegacyDatabaseException>().having(
              (e) => e.toString(),
              'message',
              contains('이전 버전 모바일 앱 DB(스키마 $version)'),
            ),
          ),
        );
        expect(await _ids(), {'live'});
        expect(
          await (await LocalDbService.db).getVersion(),
          LocalDbService.dbVersion,
        );
        expect(
          await LocalDbService.latestImportBackup(),
          isNull,
          reason: '교체하지 않았으니 before_import 사본도 없다',
        );
      },
    );
  }

  test('a backup from this app version is swapped in', () async {
    final path = await makeBackup('cur-1');
    await LocalDbService.replaceFromBackup(path);
    expect(await _ids(), {'cur-1'});
  });

  test(
    'backup from a newer app is refused and the live DB is untouched',
    () async {
      final path = await makeBackup(
        'new-1',
        version: LocalDbService.dbVersion + 1,
      );
      await expectLater(
        LocalDbService.replaceFromBackup(path),
        throwsException,
      );
      expect(await _ids(), {'live'});
    },
  );

  test('a v17 app backup is upgraded in place (detail table created empty)', () async {
    await LocalDbService.upsertReport(
      _report('old-17', 'SPP-old-17'),
      'traffic',
      '자동차·교통위반-신호위반',
    );
    final d = await LocalDbService.db;
    await (await LocalDbService.db).execute(
      'DROP VIEW IF EXISTS ${LocalDbService.effectiveReportsView}',
    );
    await d.execute('DROP TABLE report_detail_raw');
    await d.setVersion(17);
    final path = '${files.path}/backup_v17.db';
    await LocalDbService.exportBackup(path);
    // 원본 표가 없는 v17 백업 — 교체 전에 올린다.
    await deleteDatabase(await LocalDbService.getDbPath());
    await LocalDbService.upsertReport(
      _report('live', 'SPP-live'),
      'traffic',
      '자동차·교통위반-신호위반',
    );
    await LocalDbService.replaceFromBackup(path);
    expect(await _ids(), {'old-17'});
    expect(
      await (await LocalDbService.db).getVersion(),
      LocalDbService.dbVersion,
    );
    expect(
      await (await LocalDbService.db).query('report_detail_raw'),
      isEmpty,
      reason: '올려 받은 예전 백업의 원본 표는 비어 있다',
    );
  });

  test('export and restore keep detail rows with identical bytes', () async {
    final envelope = <String, dynamic>{
      'result': {
        'C_NO': 7,
        'C_NAME': '홍길동',
        'C_A_CONTENTS': '합성 본문',
      },
      'resultCode': '0000',
    };
    final prepared = prepareRawDetail(envelope);
    await LocalDbService.upsertReport(
      _report('raw-1', 'SPP-raw-1'),
      'traffic',
      '자동차·교통위반-신호위반',
      rawDetail: RawDetailUpsert(
        zlib: compressRawDetail(prepared.canonical),
        sha256: prepared.sha256,
        size: prepared.canonical.length,
        fetchedAt: '2026-10-17T12:00:00.000Z',
        source: 'crawl',
      ),
    );
    final path = '${files.path}/backup_raw.db';
    await LocalDbService.exportBackup(path);
    await deleteDatabase(await LocalDbService.getDbPath());
    await LocalDbService.replaceFromBackup(path);
    final d = await LocalDbService.db;
    final row =
        (await d.query(
          'report_detail_raw',
          where: 'ID = ?',
          whereArgs: ['raw-1'],
        )).single;
    final want = compressRawDetail(prepared.canonical);
    expect(row['raw_zlib'], want, reason: '백업·복원에서 BLOB 바이트 그대로');
    expect(row['raw_sha256'], prepared.sha256);
    expect(row['raw_size'], prepared.canonical.length);
    expect(row['fetched_at'], '2026-10-17T12:00:00.000Z');
    expect(row['source'], 'crawl');
  });

  test('복수 법규 원본과 사용자 수정값을 백업 복원한다', () async {
    const raw = '도로교통법 제32조\n도로교통법 제33조';
    const edited = '장애인복지법 제39조제3항\n장애인복지법 제90조제3항';
    await LocalDbService.upsertReport(
      _report('law', 'SPP-law').copyWith(law: raw),
      'traffic',
      '자동차·교통위반-신호위반',
    );
    await LocalDbService.updateEditableRecord('law', {'위반법규': edited});
    final path = '${files.path}/multilaw.db';
    await LocalDbService.exportBackup(path);
    await deleteDatabase(await LocalDbService.getDbPath());
    await LocalDbService.replaceFromBackup(path);
    final d = await LocalDbService.db;
    expect((await d.query('reports', columns: ['위반법규'])).single['위반법규'], raw);
    expect(
      (await d.query(
        'report_override',
        where: 'column_name = ?',
        whereArgs: ['위반법규'],
      )).single['value'],
      edited,
    );
    expect(
      (await d.query(
        LocalDbService.effectiveReportsView,
        columns: ['위반법규'],
      )).single['위반법규'],
      edited,
    );
  });

  test('a server DB is refused by the app backup restore', () async {
    final path = '${files.path}/server.db';
    final s = await openDatabase(path);
    await s.execute('CREATE TABLE mysafety (ID TEXT PRIMARY KEY)');
    await s.execute('CREATE TABLE mysafetymerge_traffic (ID TEXT PRIMARY KEY)');
    await s.close();
    await LocalDbService.upsertReport(
      _report('live', 'SPP-live'),
      'traffic',
      '자동차·교통위반-신호위반',
    );
    await expectLater(LocalDbService.replaceFromBackup(path), throwsException);
    expect(await _ids(), {'live'});
  });

  test('no staging directories are left behind', () async {
    // 시스템 임시 폴더는 병렬로 도는 다른 테스트 파일의 복원도 잠깐 쓴다. 이 테스트 전부터 있던 것은 빼고,
    // 새로 생긴 것 중 잠시 뒤에도 남아 있는 것(= 실제로 정리되지 않은 것)만 실패로 본다.
    Set<String> staging() => Directory.systemTemp
        .listSync()
        .where((e) => e.path.contains('mysafetyreport_restore_staged_'))
        .map((e) => e.path)
        .toSet();
    final before = staging();
    final path = await makeBackup('cur-2');
    await LocalDbService.replaceFromBackup(path);
    final refused = await makeBackup('old-2', version: 11, dropColumns: []);
    await expectLater(
      LocalDbService.replaceFromBackup(refused),
      throwsA(isA<LegacyDatabaseException>()),
    );
    var leftovers = staging().difference(before);
    for (var i = 0; i < 50 && leftovers.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      leftovers = leftovers.intersection(staging());
    }
    expect(leftovers, isEmpty);
  });
}
