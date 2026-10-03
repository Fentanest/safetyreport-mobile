import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/duplicate_projection_service.dart';
import '../../tool/large_data_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'build 500k realistic raw distribution using the actual mobile pipeline',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('sr_exchange_fixture_');
      await databaseFactory.setDatabasesPath(dir.path);
      SharedPreferences.setMockInitialValues({});
      try {
        final db = await LocalDbService.db;
        await seedLargeDataFixture(db, 500000);
        final groups = await DuplicateProjectionService.refreshDuplicateGroups(
          db,
        );
        expect(groups['group_count'], 2000);
        expect(groups['member_count'], 4000);
        final first = (await DuplicateProjectionService.getDuplicateGroups(
          db,
        )).first;
        await DuplicateProjectionService.updateDuplicateGroup(
          db,
          first.groupId,
          duplicateStatus: 'not_duplicate',
          representativeMode: 'manual',
          representativeId: first.members.last.reportId,
          note: '교환 수동 판단',
        );
        final watch = await db.rawQuery(
          "SELECT 신고번호 FROM reports WHERE 감시목록='Y' ORDER BY 신고번호",
        );
        for (final e in {
          'kakao_member_id': '910001',
          'watchlist': watch.map((r) => r['신고번호']).join(','),
          'last_sync': '2026-10-03T00:00:00',
          'fixture_null': null,
        }.entries) {
          await db.insert('sync_meta', {
            'key': e.key,
            'value': e.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await db.insert('report_override', {
          'ID': 'fixture-000000001',
          'column_name': '처리내용',
          'value': '교환 수정값\n보존',
          'updated_at': 1,
        });
        await db.insert('report_override', {
          'ID': 'fixture-000000002',
          'column_name': '담당자',
          'value': '',
          'updated_at': 2,
        });
        await db.insert('duplicate_decision', {
          'group_id': 'fixture-history',
          'status': 'not_duplicate',
          'representative_mode': 'manual',
          'representative_id': null,
          'apply_globally': 0,
          'note': null,
          'updated_at': 1,
        });
        await db.insert('geocode_cache', {
          '주소정규화': '합성 캐시 주소',
          '원본주소': null,
          '행정구역': null,
          '위도': 37.56012345678901,
          '경도': 126.83012345678901,
          '상태': 'ok',
          'source': 'fixture',
          'error_message': null,
          'updated_at': 0,
        });
        await LocalDbService.closeDb();
        await File(
          '${dir.path}/standalone_reports.db',
        ).copy(Platform.environment['SR_EXCHANGE_FIXTURE_OUT']!);
        // ignore: avoid_print
        print(
          'SR_EXCHANGE_FIXTURE rows=500000 groups=2000 members=4000 manual_override_null_raw_present=true',
        );
      } finally {
        await LocalDbService.closeDb();
        dir.deleteSync(recursive: true);
      }
    },
    skip: Platform.environment['SR_EXCHANGE_FIXTURE_OUT'] == null,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
