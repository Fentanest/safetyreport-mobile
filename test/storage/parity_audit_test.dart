// 2026-09-25 서버↔모바일 동등성 검수(6Sol·Opus)에서 맞춘 규칙들. 서버 쪽 대응:
// reports_repo._save_raw·_save_one, database._normalize_processing_layers, maintenance_service.repair_car_numbers,
// duplicate_group_service._normalize_duplicate_status/_normalize_representative_mode.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/duplicate_projection_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _r({String fine = '', String status = '수용'}) => Report(
  id: '7',
  reportNumber: 'SPP-7',
  name: '신호위반',
  date: '2026-09-01',
  responseDate: '2026-09-05',
  agency: '서울특별시 강서경찰서 교통과',
  manager: '담당',
  status: status,
  result: status,
  fineInfo: fine,
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '본문',
  processContent: '처리',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  const ev = '자동차·교통위반-신호위반';
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_parity_audit_');
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

  Future<Map<String, Object?>> raw() async {
    final d = await LocalDbService.db;
    final rows = await d.query('report_raw', where: 'ID = ?', whereArgs: ['7']);
    return rows.isEmpty ? {} : rows.first;
  }

  test(
    'raw body: saved as report_body, empty keeps existing, type change counts',
    () async {
      final first = await LocalDbService.upsertReport(
        _r(),
        'traffic',
        ev,
        rawContent: '원문',
      );
      expect(first.isNew, isTrue);
      expect((await raw())['raw_type'], 'report_body');

      // 새 원문이 비면 기존 원문 유지, 변경 아님(서버 _save_raw)
      final again = await LocalDbService.upsertReport(
        _r(),
        'traffic',
        ev,
        rawContent: '',
      );
      expect(again.changed, isFalse);
      expect((await raw())['raw_content'], '원문');

      // 원문 종류만 달라도 변경(서버와 같음)
      final typed = await LocalDbService.upsertReport(
        _r(),
        'traffic',
        ev,
        rawContent: '원문',
        rawType: 'other',
      );
      expect(typed.changed, isTrue);
    },
  );

  test('change result: unchanged, fine-only change, status change', () async {
    await LocalDbService.upsertReport(_r(), 'traffic', ev, rawContent: '원문');
    final same = await LocalDbService.upsertReport(
      _r(),
      'traffic',
      ev,
      rawContent: '원문',
    );
    expect(same.isNew, isFalse);
    expect(same.changed, isFalse);
    final fine = await LocalDbService.upsertReport(
      _r(fine: '과태료: 40,000원'),
      'traffic',
      ev,
      rawContent: '원문',
    );
    expect(fine.changed, isTrue);
    expect(fine.syncedAt, greaterThanOrEqualTo(same.syncedAt));
  });

  test('v15 normalization treats NULL like the server', () async {
    final d = await LocalDbService.db;
    await LocalDbService.upsertReport(_r(status: '진행'), 'traffic', ev);
    await d.update(
      'reports',
      {'상태': '진행', '처리상태': null, '보완_미응답': 'Y'},
      where: 'ID = ?',
      whereArgs: ['7'],
    );
    await LocalDbService.normalizeLegacyProcessingStatesForTest(d);
    final row = (await d.query(
      'reports',
      where: 'ID = ?',
      whereArgs: ['7'],
    )).single;
    expect(row['처리상태'], '보완요청');
    expect(row['종결여부'], 'N');

    await d.update(
      'reports',
      {'상태': '진행', '처리상태': null, '보완_미응답': null},
      where: 'ID = ?',
      whereArgs: ['7'],
    );
    await LocalDbService.normalizeLegacyProcessingStatesForTest(d);
    final row2 = (await d.query(
      'reports',
      where: 'ID = ?',
      whereArgs: ['7'],
    )).single;
    expect(row2['처리상태'], '처리중');
  });

  test(
    'car number repair re-extracts from the stored body (server repair_car_numbers)',
    () async {
      const body = '내용\n* 차량번호 : \n* 발생일자 : 2026-09-01\n* 발생시각 : 08:00';
      await LocalDbService.upsertReport(_r(), 'traffic', ev, rawContent: body);
      final d = await LocalDbService.db;
      await d.update(
        'reports',
        {'차량번호': '* 발생일자 : 2026-09-01'},
        where: 'ID = ?',
        whereArgs: ['7'],
      );
      expect(await LocalDbService.repairCarNumbersForTest(d), 1);
      final row = (await d.query(
        'reports',
        where: 'ID = ?',
        whereArgs: ['7'],
      )).single;
      expect(row['차량번호'], '');
      expect(await LocalDbService.repairCarNumbersForTest(d), 0);
    },
  );

  test('legacy duplicate status and mode map like the server', () {
    expect(
      DuplicateProjectionService.normalizeDuplicateStatus('excluded'),
      'not_duplicate',
    );
    expect(
      DuplicateProjectionService.normalizeDuplicateStatus('CONFIRMED'),
      'confirmed_duplicate',
    );
    expect(
      DuplicateProjectionService.normalizeDuplicateStatus('auto'),
      'confirmed_duplicate',
    );
    expect(
      DuplicateProjectionService.normalizeDuplicateStatus('review_required'),
      'review_required',
    );
    expect(DuplicateProjectionService.normalizeDuplicateStatus('weird'), '');
    expect(
      DuplicateProjectionService.normalizeRepresentativeMode(
        '',
        existingStatus: 'confirmed',
      ),
      'manual',
    );
    expect(
      DuplicateProjectionService.normalizeRepresentativeMode('MANUAL'),
      'manual',
    );
    expect(
      DuplicateProjectionService.normalizeRepresentativeMode(null),
      'auto',
    );
  });
}
