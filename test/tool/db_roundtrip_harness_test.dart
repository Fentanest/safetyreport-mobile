// 서버↔모바일 DB 왕복 하네스 (PROJECT_RULES §3-1). 서버 레포 scripts/dev/db_roundtrip_check.py 가 환경변수로 호출한다.
// 환경변수가 없으면 건너뛴다(일반 flutter test 에는 영향 없음).
//   SR_RT_MODE=import  SR_RT_SERVER_DB=<서버 DB>  SR_RT_MOBILE_OUT=<가져온 모바일 DB 저장 경로>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final env = Platform.environment;
  final mode = env['SR_RT_MODE'];
  TestWidgetsFlutterBinding.ensureInitialized();

  test('server db -> mobile import (roundtrip harness)', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = Directory.systemTemp.createTempSync('sr_roundtrip_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});

    final imported = await LocalDbService.importFromServerDb(env['SR_RT_SERVER_DB']!);
    expect(imported, greaterThan(0));
    await LocalDbService.closeDb();
    File('${dir.path}/standalone_reports.db').copySync(env['SR_RT_MOBILE_OUT']!);
  }, skip: mode == 'import' ? false : 'roundtrip harness: SR_RT_MODE=import 일 때만 실행');
}
