// SQ-P11: Standalone 파일 목록은 목록을 읽을 때 한 번만 비동기로 stat 하고,
// build·정렬에서 동기 파일 시스템 API 를 부르지 않으며, 무관한 Provider 알림으로 다시 그리지 않는다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/file_browser_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StandaloneProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;
}

LocalFileEntry _entry(String name, {bool dir = false, int size = 2048}) =>
    LocalFileEntry(
      path: '/fake/root/$name',
      name: name,
      isDirectory: dir,
      size: size,
      modified: DateTime(2026, 10, 4, 9, 30),
    );

class _FakeSource extends LocalFileSource {
  _FakeSource(this.entries);
  final List<LocalFileEntry> entries;
  int listCalls = 0;

  @override
  Future<Directory> root() async => Directory('/fake/root');

  @override
  Future<bool> exists(Directory dir) async => true;

  @override
  Future<List<LocalFileEntry>> list(Directory dir) async {
    listCalls++;
    // 정렬은 화면 책임이다 — 일부러 섞어서 돌려준다.
    return List.of(entries);
  }
}

/// build 중 동기 stat/type 조회를 센다(예전 코드는 항목마다 statSync, 정렬 비교마다 isDirectorySync).
class _SyncFsCounter {
  int statSync = 0;
  int typeSync = 0;
}

Future<void> _pump(
  WidgetTester tester,
  ReportProvider provider,
  LocalFileSource source,
) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(home: FileBrowserScreen(localFiles: source)),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('folders first, then names descending ignoring case', () {
    final entries = [
      _entry('b.xlsx'),
      _entry('Logs', dir: true),
      _entry('A.db'),
      _entry('archive', dir: true),
      _entry('c.log'),
      _entry('B2.txt'),
    ]..sort(compareLocalFileEntries);
    expect(entries.map((e) => e.name), [
      'Logs',
      'archive',
      'c.log',
      'B2.txt',
      'b.xlsx',
      'A.db',
    ]);
  });

  testWidgets(
    'lists sorted entries lazily without sync file-system calls in build',
    (tester) async {
      final provider = _StandaloneProvider();
      addTearDown(provider.dispose);
      final source = _FakeSource([
        for (var i = 0; i < 300; i++)
          _entry('file_${i.toString().padLeft(3, '0')}.xlsx'),
        _entry('sunwi', dir: true),
        _entry('Backups', dir: true),
      ]);
      final counter = _SyncFsCounter();
      await IOOverrides.runZoned(
        () => _pump(tester, provider, source),
        // 가짜 나열기를 쓰므로 실제 파일 시스템에 닿을 일이 없다 — 세고 실패시킨다.
        statSync: (path) {
          counter.statSync++;
          throw UnsupportedError('statSync($path) during file list');
        },
        fseGetTypeSync: (path, followLinks) {
          counter.typeSync++;
          throw UnsupportedError('typeSync($path) during file list');
        },
      );
      expect(counter.statSync, 0);
      expect(counter.typeSync, 0);
      expect(source.listCalls, 1);

      // 폴더가 먼저, 파일은 이름 내림차순.
      final sunwi = tester.getTopLeft(find.text('sunwi')).dy;
      final backups = tester.getTopLeft(find.text('Backups')).dy;
      final top = tester.getTopLeft(find.text('file_299.xlsx')).dy;
      expect(sunwi, lessThan(backups));
      expect(backups, lessThan(top));
      expect(find.text('폴더  ·  26/10/04 09:30'), findsNWidgets(2));
      expect(find.textContaining('2.0 KB  ·  26/10/04 09:30'), findsWidgets);
      // ListView.builder: 화면 밖 항목은 만들지 않는다.
      expect(find.text('file_000.xlsx'), findsNothing);
    },
  );

  testWidgets('only filesRefreshNonce changes rebuild/reload the screen', (
    tester,
  ) async {
    final provider = _StandaloneProvider();
    addTearDown(provider.dispose);
    final source = _FakeSource([_entry('a.xlsx')]);
    await _pump(tester, provider, source);
    expect(source.listCalls, 1);

    var screenBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is FileBrowserScreen) screenBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    provider.bumpStatsRefresh(); // 파일 화면과 무관한 알림
    await tester.pump();
    expect(screenBuilds, 0);
    expect(source.listCalls, 1);

    provider.bumpFilesRefresh();
    await tester.pump();
    await tester.pump();
    expect(screenBuilds, greaterThan(0));
    expect(source.listCalls, 2);
  });
}
