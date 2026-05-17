import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report({
  required String id,
  required String reportNumber,
  required String location,
  String status = '처리중',
  String result = '처리중',
}) {
  return Report(
    id: id,
    reportNumber: reportNumber,
    name: '테스트 신고',
    date: '2026-05-17',
    responseDate: '2026-05-17',
    agency: '서울강서경찰서 교통과',
    manager: '담당자',
    status: status,
    result: result,
    fineInfo: '과태료',
    penaltyPoints: '',
    carNumber: '12가3456',
    law: '도로교통법',
    location: location,
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
    version: 1,
    onCreate: (txn, _) async {
      await txn.execute(
        'CREATE TABLE invalid_source (id TEXT PRIMARY KEY, value TEXT)',
      );
      await txn.insert('invalid_source', {'id': '1', 'value': 'bad'});
    },
  );
  await db.close();
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
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
  });
}
