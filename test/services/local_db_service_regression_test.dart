import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/agency_stats.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_map.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/kakao_owner.dart';

Report _report({
  required String id,
  required String reportNumber,
  required String location,
  String status = '처리중',
  String result = '처리중',
  String agency = '서울강서경찰서 교통과',
  String fineInfo = '과태료',
  double? latitude,
  double? longitude,
}) {
  return Report(
    id: id,
    reportNumber: reportNumber,
    name: '테스트 신고',
    date: '2026-05-17',
    responseDate: '2026-05-17',
    agency: agency,
    manager: '담당자',
    status: status,
    result: result,
    fineInfo: fineInfo,
    penaltyPoints: '',
    carNumber: '12가3456',
    law: '도로교통법',
    location: location,
    latitude: latitude,
    longitude: longitude,
    occurrenceDate: '2026-05-17',
    occurrenceTime: '12:00',
    reportContent: '테스트 신고 내용',
    processContent: '테스트 처리 내용',
  );
}

Future<void> _resetStandaloneDb() async {
  await LocalDbService.closeDb();
  final dbPath = await LocalDbService.getDbPath();
  await deleteDatabase(dbPath);
  for (final ext in ['-wal', '-shm']) {
    final sidecar = File('$dbPath$ext');
    if (sidecar.existsSync()) {
      await sidecar.delete();
    }
  }
}

Future<String> _createInvalidServerDb() async {
  final path =
      '${Directory.systemTemp.path}/invalid_server_${DateTime.now().millisecondsSinceEpoch}.db';
  final db = await openDatabase(
    path,
    version: LocalDbService.serverSchemaVersion,
    onCreate: (txn, _) async {
      await txn.execute(
        'CREATE TABLE invalid_source (id TEXT PRIMARY KEY, value TEXT)',
      );
      await txn.insert('invalid_source', {'id': '1', 'value': 'bad'});
      // 주인은 맞게 적어 스키마 검사까지 가게 한다
      await txn.execute('CREATE TABLE mysafety_sync_meta (key TEXT PRIMARY KEY, value TEXT)');
      await stampOwner(txn, table: 'mysafety_sync_meta');
    },
  );
  await db.close();
  return path;
}

Future<String> _createServerDbWithSyncMeta() async {
  final path =
      '${Directory.systemTemp.path}/server_sync_meta_${DateTime.now().millisecondsSinceEpoch}.db';
  final db = await openDatabase(
    path,
    version: LocalDbService.serverSchemaVersion,
    onCreate: (txn, _) async {
      await txn.execute(
        'CREATE TABLE mysafety (ID TEXT PRIMARY KEY, value TEXT)',
      );
      await txn.execute('''
        CREATE TABLE mysafetymerge_traffic (
          ID TEXT PRIMARY KEY,
          신고번호 TEXT,
          위반장소 TEXT
        )
      ''');
      await txn.execute('''
        CREATE TABLE mysafetymerge_parking (
          ID TEXT PRIMARY KEY,
          신고번호 TEXT,
          위반장소 TEXT
        )
      ''');
      await txn.execute('''
        CREATE TABLE mysafetymerge_other (
          ID TEXT PRIMARY KEY,
          신고번호 TEXT,
          위반장소 TEXT
        )
      ''');
      await txn.execute(
        'CREATE TABLE mysafety_sync_meta (key TEXT PRIMARY KEY, value TEXT)',
      );
      await txn.insert('mysafety', {'ID': 'row-1', 'value': 'ok'});
      await txn.insert('mysafetymerge_traffic', {
        'ID': 'traffic-1',
        '신고번호': 'TRAFFIC-1',
        '위반장소': '서울특별시 강서구 마곡동 1',
      });
      await txn.insert('mysafety_sync_meta', {
        'key': 'map_backfill_state',
        'value': 'queued',
      });
      await txn.insert('mysafety_sync_meta', {
        'key': 'preserve_me',
        'value': 'ok',
      });
      await stampOwner(txn, table: 'mysafety_sync_meta');
    },
  );
  await db.close();
  return path;
}

Future<String> _createMobileBackupWithStaleMapState() async {
  await LocalDbService.upsertReport(
    _report(
      id: 'backup-1',
      reportNumber: 'BACKUP-1',
      location: '서울특별시 강서구 마곡동 9',
    ),
    'traffic',
    '자동차·교통위반',
  );
  final db = await LocalDbService.db;
  await db.insert('sync_meta', {
    'key': 'map_backfill_state',
    'value': 'queued',
  });
  await db.insert('sync_meta', {'key': 'preserve_me', 'value': 'ok'});
  await stampOwner(db);
  await LocalDbService.closeDb();

  final sourcePath = await LocalDbService.getDbPath();
  final backupPath =
      '${Directory.systemTemp.path}/mobile_backup_${DateTime.now().millisecondsSinceEpoch}.db';
  await File(sourcePath).copy(backupPath);
  return backupPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  useTestKakaoAccount();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // flutter test 는 파일별로 병렬 실행된다. DB 를 쓰는 테스트 파일마다 전용 경로를 써야
    // standalone_reports.db 를 서로 덮어쓰지 않는다(2026-09-24 Gemini 검수 R1 에서 재현).
    await databaseFactory.setDatabasesPath(
      (tempDbDir = Directory.systemTemp.createTempSync('sr_db_test_')).path,
    );
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _resetStandaloneDb();
  });

  tearDown(() async {
    await _resetStandaloneDb();
  });

  group('LocalDbService regressions', () {
    test(
      'representative projection cache is invalidated after watchlist updates',
      () async {
        await LocalDbService.upsertReport(
          _report(
            id: 'rep-1',
            reportNumber: 'R-1',
            location: '서울특별시 강서구 마곡동 1',
            status: '수용',
            result: '수용',
          ),
          'traffic',
          '자동차·교통위반',
        );
        await LocalDbService.upsertReport(
          _report(
            id: 'member-2',
            reportNumber: 'R-2',
            location: '서울특별시 강서구 마곡동 1',
            status: '수용',
            result: '수용',
          ),
          'traffic',
          '자동차·교통위반',
        );

        final db = await LocalDbService.db;
        final now = DateTime.now().millisecondsSinceEpoch;
        await db.insert('duplicate_group', {
          'group_id': 'group-1',
          'fingerprint': 'fingerprint-1',
          'match_type': 'payload_exact',
          'status': 'confirmed_duplicate',
          'representative_mode': 'auto',
          'representative_id': 'rep-1',
          'member_count': 2,
          'apply_globally': 1,
          'note': '',
          'created_at': now,
          'updated_at': now,
        });
        await db.insert('duplicate_member', {
          'group_id': 'group-1',
          'report_id': 'rep-1',
          'report_number': 'R-1',
          'category': 'traffic',
          'is_representative': 1,
          'priority_score': 10,
          'raw_match': 1,
          'field_match': 1,
          'created_at': now,
          'updated_at': now,
        });
        await db.insert('duplicate_member', {
          'group_id': 'group-1',
          'report_id': 'member-2',
          'report_number': 'R-2',
          'category': 'traffic',
          'is_representative': 0,
          'priority_score': 9,
          'raw_match': 1,
          'field_match': 1,
          'created_at': now,
          'updated_at': now,
        });

        final before = await LocalDbService.computeSummary(
          useRepresentativeRecords: true,
        );
        expect(before.watchlist, isEmpty);

        await LocalDbService.setWatchlistNumbers({'R-2'});

        final after = await LocalDbService.computeSummary(
          useRepresentativeRecords: true,
        );
        expect(after.watchlist, hasLength(1));
        expect(after.watchlist.first.reportNumber, 'R-1');
      },
    );

    test(
      'failed server db import preserves existing standalone data',
      () async {
        await LocalDbService.upsertReport(
          _report(
            id: 'keep-1',
            reportNumber: 'KEEP-1',
            location: '서울특별시 강서구 공항동 1',
          ),
          'traffic',
          '자동차·교통위반',
        );

        final invalidServerDbPath = await _createInvalidServerDb();
        addTearDown(() async {
          await deleteDatabase(invalidServerDbPath);
        });

        await expectLater(
          LocalDbService.importFromServerDb(invalidServerDbPath),
          throwsException,
        );

        final db = await LocalDbService.db;
        final rows = await db.query('reports', orderBy: '신고번호 ASC');
        expect(rows, hasLength(1));
        expect(rows.first['신고번호'], 'KEEP-1');
      },
    );

    test('server db import drops stale map backfill sync state', () async {
      final serverDbPath = await _createServerDbWithSyncMeta();
      addTearDown(() async {
        await deleteDatabase(serverDbPath);
      });

      final imported = await LocalDbService.importFromServerDb(serverDbPath);
      expect(imported, 1);

      final db = await LocalDbService.db;
      final rows = await db.query('sync_meta', orderBy: 'key ASC');
      final keys = rows
          .map((row) => row['key']?.toString() ?? '')
          .where((key) => key.isNotEmpty)
          .toSet();

      expect(keys.contains('map_backfill_state'), isFalse);
      expect(keys.contains('preserve_me'), isTrue);
    });

    test(
      'replacing mobile backup clears stale map backfill sync state',
      () async {
        final backupPath = await _createMobileBackupWithStaleMapState();
        addTearDown(() async {
          final file = File(backupPath);
          if (file.existsSync()) {
            await file.delete();
          }
        });

        await LocalDbService.replaceFromBackup(backupPath);

        final db = await LocalDbService.db;
        final rows = await db.query('sync_meta', orderBy: 'key ASC');
        final keys = rows
            .map((row) => row['key']?.toString() ?? '')
            .where((key) => key.isNotEmpty)
            .toSet();

        expect(keys.contains('map_backfill_state'), isFalse);
        expect(keys.contains('preserve_me'), isTrue);
      },
    );

    test(
      'stats and map payload keep reject bucket while separating unconfirmed',
      () async {
        final reports = [
          _report(
            id: 'fine-1',
            reportNumber: 'FINE-1',
            location: '서울특별시 강서구 마곡동 1',
            status: '수용',
            result: '수용',
            fineInfo: '과태료: 40,000원',
          ),
          _report(
            id: 'warn-1',
            reportNumber: 'WARN-1',
            location: '서울특별시 강서구 마곡동 1',
            status: '답변완료',
            result: '답변완료',
            fineInfo: '경고',
          ),
          _report(
            id: 'reject-1',
            reportNumber: 'REJECT-1',
            location: '서울특별시 강서구 마곡동 1',
            status: '기타',
            result: '기타',
            fineInfo: '',
          ),
          _report(
            id: 'unknown-1',
            reportNumber: 'UNKNOWN-1',
            location: '서울특별시 강서구 마곡동 1',
            status: '처리중',
            result: '처리중',
            fineInfo: '미확인',
          ),
        ];

        for (final report in reports) {
          await LocalDbService.upsertReport(report, 'traffic', '자동차·교통위반');
        }

        final db = await LocalDbService.db;
        for (final report in reports) {
          await db.update(
            'reports',
            {
              '주소정규화': '서울특별시 강서구 마곡동 1',
              '행정구역': '서울특별시 강서구 마곡동',
              '위도': 37.5601,
              '경도': 126.8301,
              '지오코딩상태': 'success',
            },
            where: 'ID = ?',
            whereArgs: [report.id],
          );
        }

        final stats = AgencyStats.fromJson(await LocalDbService.computeStats());
        final row = stats.traffic.byAgency.first;
        expect(row.fines, 1);
        expect(row.warnings, 1);
        expect(row.rejects, 1);
        // 2026-09-28 사용자 결정: 기관표는 답변 완료 신고만 — 처리중은 표에 들어가지 않는다(S-10 대체).
        // 지도 처분 분포(아래 '미확인')는 서버 `_build_disposition_breakdown` 과 같이 그대로다.
        expect(row.unconfirmed, 0);
        expect(row.inProgress, 0);

        final payload = ReportMapPayload.fromJson(
          await LocalDbService.computeReportMapStats(),
        );
        expect(payload.meta.agencyCount, 1);
        expect(payload.points, hasLength(1));
        expect(payload.points.first.fineRate, 25.0);

        final dispositionCounts = {
          for (final item in payload.points.first.dispositionBreakdown)
            item.label: item.count,
        };
        expect(dispositionCounts['과태료'], 1);
        expect(dispositionCounts['경고/범칙금'], 1);
        expect(dispositionCounts['불수용/기타'], 1);
        expect(dispositionCounts['미확인'], 1);
        expect(dispositionCounts.containsKey('기타/미확인'), isFalse);
      },
    );

    test('official coordinates overwrite a same-address recrawl and ignore old cache', () async {
      const address = '서울특별시 강서구 마곡동 1';
      final db = await LocalDbService.db;
      await db.insert('geocode_cache', {
        '주소정규화': address,
        '위도': 37.1,
        '경도': 126.1,
        '상태': 'ok',
        'source': 'kakao',
      });
      await LocalDbService.upsertReport(
        _report(id: 'official-1', reportNumber: 'OFFICIAL-1', location: address,
            latitude: 37.560123456789, longitude: 126.830123456789),
        'traffic', '자동차·교통위반',
      );
      var row = (await db.query('reports', where: 'ID = ?', whereArgs: ['official-1'])).single;
      expect((row['위도'], row['경도'], row['지오코딩상태']),
          (37.560123456789, 126.830123456789, 'ok'));

      await LocalDbService.upsertReport(
        _report(id: 'official-1', reportNumber: 'OFFICIAL-1', location: address,
            latitude: 37.56123456789, longitude: 126.83123456789),
        'traffic', '자동차·교통위반',
      );
      row = (await db.query('reports', where: 'ID = ?', whereArgs: ['official-1'])).single;
      expect((row['위도'], row['경도']), (37.56123456789, 126.83123456789));

      await LocalDbService.upsertReport(
        _report(id: 'official-1', reportNumber: 'OFFICIAL-1', location: address),
        'traffic', '자동차·교통위반',
      );
      row = (await db.query('reports', where: 'ID = ?', whereArgs: ['official-1'])).single;
      expect((row['위도'], row['경도'], row['지오코딩상태']),
          (null, null, 'not_found'));
    });

    test('map shows an official point even when the address is empty', () async {
      await LocalDbService.upsertReport(
        _report(
          id: 'official-no-address',
          reportNumber: 'OFFICIAL-NO-ADDRESS',
          location: '',
          latitude: 37.560123456789,
          longitude: 126.830123456789,
        ),
        'traffic',
        '자동차·교통위반',
      );
      final payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(),
      );
      expect(payload.points, hasLength(1));
      expect(payload.points.single.lat, 37.560123456789);
      expect(payload.points.single.lng, 126.830123456789);
    });

    test(
      'map payload ignores NaN coordinates instead of crashing map view',
      () async {
        await LocalDbService.upsertReport(
          _report(
            id: 'nan-1',
            reportNumber: 'NAN-1',
            location: '서울특별시 강서구 마곡동 99',
          ),
          'traffic',
          '자동차·교통위반',
        );

        final db = await LocalDbService.db;
        await db.update(
          'reports',
          {
            '주소정규화': '서울특별시 강서구 마곡동 99',
            '행정구역': '서울특별시 강서구 마곡동',
            '위도': double.nan,
            '경도': 126.8301,
            '지오코딩상태': 'ok',
          },
          where: 'ID = ?',
          whereArgs: ['nan-1'],
        );

        final localPayload = ReportMapPayload.fromJson(
          await LocalDbService.computeReportMapStats(),
        );
        expect(localPayload.points, isEmpty);
        expect(localPayload.meta.missingReports, 1);

        final serverPayload = ReportMapPayload.fromJson({
          'points': [
            {
              'lat': double.nan,
              'lng': 126.8301,
              'address': '서울특별시 강서구 마곡동 99',
              'region': '서울특별시 강서구 마곡동',
              'total': 1,
              'status_breakdown': const [],
              'disposition_breakdown': const [],
              'agency_breakdown': const [],
              'category_breakdown': const [],
            },
          ],
          'meta': {
            'available_years': ['2026'],
            'current_year': 'all',
            'selected_category': 'all',
            'dedupe_mode': 'canonical',
            'total_reports': 1,
            'geocoded_reports': 1,
            'missing_reports': 0,
            'address_groups': 1,
            'agency_count': 0,
          },
        });
        expect(serverPayload.points, isEmpty);
      },
    );

    test(
      'missing address payload groups reports by unresolved address',
      () async {
        final reports = [
          _report(
            id: 'missing-a',
            reportNumber: 'MISS-A',
            location: '서울특별시 강서구 방화동 101',
          ),
          _report(
            id: 'missing-b',
            reportNumber: 'MISS-B',
            location: '서울특별시 강서구 방화동 101',
          ),
          _report(
            id: 'mapped-c',
            reportNumber: 'MAP-C',
            location: '서울특별시 강서구 마곡동 55',
          ),
        ];

        for (final report in reports) {
          await LocalDbService.upsertReport(report, 'traffic', '자동차·교통위반');
        }

        final db = await LocalDbService.db;
        await db.update(
          'reports',
          {
            '주소정규화': '서울특별시 강서구 방화동 101',
            '행정구역': '서울특별시 강서구 방화동',
            '위도': null,
            '경도': null,
            '지오코딩상태': 'pending',
          },
          where: 'ID IN (?, ?)',
          whereArgs: ['missing-a', 'missing-b'],
        );
        await db.update(
          'reports',
          {
            '주소정규화': '서울특별시 강서구 마곡동 55',
            '행정구역': '서울특별시 강서구 마곡동',
            '위도': 37.5601,
            '경도': 126.8301,
            '지오코딩상태': 'ok',
          },
          where: 'ID = ?',
          whereArgs: ['mapped-c'],
        );

        final payload = ReportMapMissingPayload.fromJson(
          await LocalDbService.computeReportMapMissingGroups(),
        );
        expect(payload.groupCount, 1);
        expect(payload.reportCount, 2);
        expect(payload.groups, hasLength(1));
        expect(payload.groups.first.address, '서울특별시 강서구 방화동 101');
        expect(payload.groups.first.reports, hasLength(2));
      },
    );
  });
}
