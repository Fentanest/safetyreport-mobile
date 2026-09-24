// 모바일 사용자 소유 데이터 보존 (저장 계층 재설계 R3, 결정 D-6).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/duplicate_projection_service.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_user_data_test_');
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

  test(
    'M-18: a duplicate decision survives the group being rebuilt from scratch',
    () async {
      const body = '같은 신고 본문입니다 — 중복 판정용';
      await LocalDbService.upsertReport(
        _report('d1', 'SPP-1'),
        'traffic',
        '자동차·교통위반-신호위반',
        rawContent: body,
      );
      await LocalDbService.upsertReport(
        _report('d2', 'SPP-2'),
        'traffic',
        '자동차·교통위반-신호위반',
        rawContent: body,
      );
      final db = await LocalDbService.db;
      await DuplicateProjectionService.refreshDuplicateGroups(db);
      final groupId =
          (await db.query(
                DuplicateProjectionService.groupTable,
              )).single['group_id']
              as String;
      await DuplicateProjectionService.updateDuplicateGroup(
        db,
        groupId,
        duplicateStatus: 'not_duplicate',
        representativeMode: 'manual',
        representativeId: 'd2',
        note: '서로 다른 건',
      );

      await db.delete(DuplicateProjectionService.memberTable);
      await db.delete(DuplicateProjectionService.groupTable);
      await DuplicateProjectionService.refreshDuplicateGroups(db);
      final g = (await db.query(DuplicateProjectionService.groupTable)).single;
      expect(
        (
          g['status'],
          g['representative_mode'],
          g['representative_id'],
          g['note'],
        ),
        ('not_duplicate', 'manual', 'd2', '서로 다른 건'),
      );
    },
  );

  test(
    'M-6/M-7: watchlist changes start from the DB list, not a stale in-memory copy',
    () async {
      await LocalDbService.upsertReport(
        _report('w1', 'SPP-A'),
        'traffic',
        '자동차·교통위반-신호위반',
      );
      await LocalDbService.changeWatchlist(add: ['SPP-A']);
      // 가져오기·복원 등으로 DB 의 목록이 바뀐 상황
      await LocalDbService.setWatchlistNumbers({'SPP-C'});
      final next = await LocalDbService.changeWatchlist(add: ['SPP-B']);
      expect(next, {'SPP-C', 'SPP-B'}); // 예전 메모리 목록(SPP-A)이 되살아나지 않음
      final row = (await (await LocalDbService.db).query(
        'reports',
        where: 'ID = ?',
        whereArgs: ['w1'],
      )).single;
      expect(row['감시목록'], 'N');
    },
  );

  test(
    'R4: edited fields report their site originals for the editor',
    () async {
      await LocalDbService.upsertReport(
        _report('e1', 'SPP-E'),
        'traffic',
        '자동차·교통위반-신호위반',
      );
      expect(await LocalDbService.getSiteValuesOfEditedFields('e1'), isEmpty);
      await LocalDbService.updateEditableRecord('e1', {
        '처리내용': '고친 값',
        '담당자': '담당',
      });
      expect(await LocalDbService.getSiteValuesOfEditedFields('e1'), {
        '처리내용': '처리',
      });
      await LocalDbService.updateEditableRecord('e1', {
        '처리내용': '처리',
      }); // 원본으로 되돌리기
      expect(await LocalDbService.getSiteValuesOfEditedFields('e1'), isEmpty);
    },
  );
}
