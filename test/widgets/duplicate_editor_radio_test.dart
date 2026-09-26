// 중복 그룹 편집 시트: Radio → RadioGroup, DropdownButtonFormField value → initialValue 이관(2026-09-26 감사)
// 뒤에도 대표 후보를 고르면 "대표건 선정" 표시가 수동 고정으로 바뀌어야 한다(시트 상태가 바꾼 initialValue 를 드롭다운이 따라가는지).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/duplicate_management_screen.dart';
import 'package:safetyreport/services/duplicate_projection_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _StandaloneProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;
}

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
    dir = Directory.systemTemp.createTempSync('sr_dup_editor_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  testWidgets('picking a representative switches the mode dropdown to manual', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await LocalDbService.closeDb();
      await deleteDatabase(await LocalDbService.getDbPath());
      const body = '같은 신고 본문입니다 — 편집 시트 시험';
      await LocalDbService.upsertReport(_report('d1', 'SPP-1'), 'traffic', '자동차·교통위반-신호위반', rawContent: body);
      await LocalDbService.upsertReport(_report('d2', 'SPP-2'), 'traffic', '자동차·교통위반-신호위반', rawContent: body);
      await DuplicateProjectionService.refreshDuplicateGroups(await LocalDbService.db);
    });
    final provider = _StandaloneProvider();
    addTearDown(provider.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: DuplicateManagementPanel())),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('SPP-').first);
    await tester.pumpAndSettle();
    expect(find.text('자동 선정'), findsOneWidget);
    expect(find.text('수동 고정'), findsNothing);

    final radios = find.byType(RadioListTile<String>);
    expect(radios, findsNWidgets(2));
    // 현재 대표가 아닌 쪽을 고른다.
    final tiles = tester.widgetList<RadioListTile<String>>(radios).toList();
    final group = tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>));
    final other = tiles.indexWhere((t) => t.value != group.groupValue);
    expect(other, isNonNegative);
    await tester.tap(radios.at(other));
    await tester.pumpAndSettle();

    expect(tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>)).groupValue, tiles[other].value);
    expect(find.text('수동 고정'), findsOneWidget);
    expect(find.text('자동 선정'), findsNothing);
  });
}
