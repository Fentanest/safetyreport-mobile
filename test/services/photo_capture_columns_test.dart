// 주정차 사진 촬영 시각 3컬럼(DB v11). 서버와 교환하는 값이라 앱 안의 저장 경로에서 사라지면 안 된다(PROJECT_RULES §3-1).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report({String processContent = '처리 내용'}) => Report(
  id: 'p-1',
  reportNumber: 'SPP-2609-0000001',
  name: '불법주정차신고',
  date: '2026-09-22',
  responseDate: '2026-09-23',
  agency: '서울특별시 강서구 주차관리과',
  manager: '담당자',
  status: '수용',
  result: '수용',
  fineInfo: '과태료',
  penaltyPoints: '',
  carNumber: '서울85바1234',
  law: '',
  location: '서울특별시 강서구 등촌동 101',
  occurrenceDate: '2026-09-22',
  occurrenceTime: '01:00',
  reportContent: '신고 내용',
  processContent: processContent,
);

Future<void> _resetDb() async {
  await LocalDbService.closeDb();
  final dbPath = await LocalDbService.getDbPath();
  await deleteDatabase(dbPath);
  for (final ext in ['-wal', '-shm']) {
    final sidecar = File('$dbPath$ext');
    if (sidecar.existsSync()) await sidecar.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(
      (tempDbDir = Directory.systemTemp.createTempSync(
        'sr_db_photo_test_',
      )).path,
    );
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _resetDb();
  });

  tearDown(_resetDb);

  test(
    'upsertReport keeps photo capture columns when the report is re-saved',
    () async {
      await LocalDbService.upsertReport(
        _report(),
        'parking',
        '불법주정차신고-기타 불법주정차',
      );
      final d = await LocalDbService.db;
      await d.update(
        'reports',
        {
          '사진_첫촬영': '2026-09-22 01:00:00',
          '사진_끝촬영': '2026-09-22 02:30:00',
          '사진_촬영수': 3,
        },
        where: 'ID = ?',
        whereArgs: ['p-1'],
      );

      // 내용이 바뀐 재저장(REPLACE)에서도 모델에 없는 교환 컬럼이 유지돼야 한다.
      await LocalDbService.upsertReport(
        _report(processContent: '처리 내용 변경'),
        'parking',
        '불법주정차신고-기타 불법주정차',
      );
      final row = (await d.query(
        'reports',
        where: 'ID = ?',
        whereArgs: ['p-1'],
      )).single;
      expect(row['처리내용'], '처리 내용 변경');
      expect(row['사진_첫촬영'], '2026-09-22 01:00:00');
      expect(row['사진_끝촬영'], '2026-09-22 02:30:00');
      expect(row['사진_촬영수'], 3);
    },
  );

  test('new report starts with NULL photo columns (not yet tried)', () async {
    await LocalDbService.upsertReport(_report(), 'parking', '불법주정차신고-기타 불법주정차');
    final d = await LocalDbService.db;
    final row = (await d.query(
      'reports',
      where: 'ID = ?',
      whereArgs: ['p-1'],
    )).single;
    for (final col in LocalDbService.photoCaptureColumns) {
      expect(row.containsKey(col), isTrue, reason: col);
      expect(row[col], isNull, reason: col);
    }
  });

  // v10 → 현재 업그레이드는 test/storage/migration_test.dart 가 실제 v10 구조로 검사한다(사진 3열 포함).
}
