// 설정의 "직전 DB 로 되돌리기"(감사 SOL-05·R2-03): 단독 모드에서 현재 DB 의 가져오기 직전 사본이 있을 때만 보이고,
// 실 DB ↔ 데모 DB 가 바뀌면 그 DB 기준으로 다시 판단한다. 누르면 확인 뒤 실제로 되돌린다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Provider extends ReportProvider {
  bool demo = false;
  int refreshes = 0;

  @override
  AppMode get appMode => AppMode.standalone;

  @override
  bool get isStandaloneDemo => demo;

  Future<void> switchDemo(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppPrefsKeys.standaloneDemoMode, value);
    await LocalDbService.closeDb();
    demo = value;
    notifyListeners();
  }

  @override
  Future<void> refreshAll() async => refreshes++;
}

Future<void> _makeServerDb(String path, String name) async {
  final db = await openDatabase(path);
  await db.execute(
    'CREATE TABLE mysafetymerge_traffic (ID TEXT PRIMARY KEY, 신고번호 TEXT, 신고명 TEXT, 위반장소 TEXT)',
  );
  await db.execute('CREATE TABLE mysafetymerge_parking AS SELECT * FROM mysafetymerge_traffic WHERE 0');
  await db.execute('CREATE TABLE mysafetymerge_other AS SELECT * FROM mysafetymerge_traffic WHERE 0');
  await db.execute('CREATE TABLE mysafety (ID TEXT PRIMARY KEY)');
  await db.insert('mysafetymerge_traffic', {'ID': 's1', '신고번호': 'SPP-1', '신고명': name, '위반장소': '서울'});
  await db.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_settings_revert_');
    await databaseFactory.setDatabasesPath(dir.path);
    PackageInfo.setMockInitialValues(
      appName: 'safetyreport', packageName: 'x', version: '1.0.0', buildNumber: '1', buildSignature: '');
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  Finder revertButton() => find.text('직전 DB 로 되돌리기');

  testWidgets('shows the revert only for a DB that has a pre-import copy, follows demo switches, and reverts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 실 DB: A 가져온 뒤 B 가져오기 → 직전 사본(A) 있음. 데모 DB: 사본 없음.
    await tester.runAsync(() async {
      await LocalDbService.closeDb();
      for (final f in dir.listSync().whereType<File>()) {
        f.deleteSync();
      }
      final a = '${dir.path}/a.db', b = '${dir.path}/b.db';
      await _makeServerDb(a, 'A');
      await _makeServerDb(b, 'B');
      await LocalDbService.importFromServerDb(a);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await LocalDbService.importFromServerDb(b);
    });
    final provider = _Provider();
    addTearDown(provider.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(revertButton(), findsOneWidget, reason: '실 DB 에는 직전 사본이 있다');

    await tester.runAsync(() => provider.switchDemo(true));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(revertButton(), findsNothing, reason: '데모 DB 에는 사본이 없다(R2-03)');

    await tester.runAsync(() => provider.switchDemo(false));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(revertButton(), findsOneWidget);

    await tester.ensureVisible(revertButton());
    await tester.tap(revertButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '되돌리기'));
    for (var i = 0; i < 50 && provider.refreshes == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final name = await tester.runAsync(() async =>
        (await (await LocalDbService.db).query('reports', where: 'ID = ?', whereArgs: ['s1'])).single['신고명']);
    expect(name, 'A', reason: '버튼이 실제로 직전 DB 로 되돌린다');
    expect(provider.refreshes, greaterThan(0));
  });
}
