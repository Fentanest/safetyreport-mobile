// 명세 4절(원본 보기) 모바일 시험: 화면 표시·검색·복사, 없음·손상·오류 안내,
// 다시 쓰기, 시트 동작 표시 조건, 설정 항목·폴더 열기, 360px 라이트/다크 오버플로 없음.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/file_browser_screen.dart';
import 'package:safetyreport/screens/raw_detail_view_screen.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StandaloneProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;

  @override
  bool get isStandaloneDemo => true;

  @override
  Future<void> refreshAll() async {}
}

class _ClientWithRaw extends ReportProvider {
  @override
  bool get rawDetailSupported => true;

  @override
  Future<void> refreshAll() async {}
}

class _ClientWithoutRaw extends ReportProvider {
  @override
  Future<void> refreshAll() async {}
}

LocalFileEntry _entry(String name, {bool dir = false}) => LocalFileEntry(
  path: '/fake/root/$name',
  name: name,
  isDirectory: dir,
  size: 2048,
  modified: DateTime(2026, 10, 4, 9, 30),
);

class _RecordingFiles extends LocalFileSource {
  _RecordingFiles(this.entries);
  final List<LocalFileEntry> entries;
  final List<String> listed = [];

  @override
  Future<Directory> root() async => Directory('/fake/root');

  @override
  Future<bool> exists(Directory dir) async => true;

  @override
  Future<List<LocalFileEntry>> list(Directory dir) async {
    listed.add(dir.path);
    return List.of(entries);
  }
}

class _FakeSource implements RawDetailSource {
  @override
  final bool isStandalone;
  Future<RawDetailData> Function(String id)? loadBehavior;
  Future<String?> Function(String id, Map<String, dynamic> json)?
  rewriteBehavior;
  final List<(String, String)> shared = [];
  final List<(String, Map<String, dynamic>)> rewritten = [];
  int loads = 0;

  _FakeSource({
    this.isStandalone = true,
    this.loadBehavior,
    this.rewriteBehavior,
  });

  @override
  Future<RawDetailData> load(String reportId) async {
    loads++;
    final behavior = loadBehavior;
    if (behavior != null) return behavior(reportId);
    throw const RawDetailMissing();
  }

  @override
  Future<String?> rewriteFile(
    String reportId,
    Map<String, dynamic> sanitized,
  ) async {
    final behavior = rewriteBehavior;
    if (behavior != null) return behavior(reportId, sanitized);
    rewritten.add((reportId, sanitized));
    return '/tmp/$reportId.json';
  }

  @override
  Future<void> shareFile(String reportId, String pretty) async {
    shared.add((reportId, pretty));
  }
}

RawDetailData _storedData() {
  final json = {
    'result': {
      'C_NO': '90000001',
      'VHRNO': '12가3456',
      'note_a': '신고 접수 ZZMATCH 완료',
      'note_b': 'ZZMATCH 재확인',
      'nested': {'note_c': '마지막 ZZMATCH 기록'},
    },
    'fetched_via': 'crawl',
  };
  return RawDetailData(
    pretty: prettyRawJson(json),
    sanitized: json,
    fetchedAt: '2026-10-17T12:34:56.789Z',
    source: 'crawl',
    sha256: 'abc',
  );
}

Report _minimalReport() => Report(
  id: '90000001',
  reportNumber: '',
  name: '원본 보기 검수 신고',
  date: '',
  responseDate: '',
  agency: '',
  manager: '',
  status: '',
  result: '',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
);

Future<void> _pumpScreen(
  WidgetTester tester,
  RawDetailSource source, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness),
      home: RawDetailViewScreen(reportId: '90000001', source: source),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RawDetailViewScreen.copyOverride = null;
  });

  group('pretty + search helpers', () {
    test('pretty uses two-space indent and keeps non-ASCII', () {
      final text = prettyRawJson({
        'result': {'C_A_CONTENTS': '과태료 40,000원'},
      });
      expect(text, startsWith('{\n  "result"'));
      expect(text, contains('과태료 40,000원'));
      expect(jsonDecode(text), isA<Map>());
    });

    test('findRawMatches counts every occurrence across lines', () {
      final lines = ['{"a": "x ZZMATCH y",', '"b": "ZZMATCH",', '"c": "none"}'];
      final matches = findRawMatches(lines, 'zzmatch');
      expect(matches.map((m) => m.line), [0, 1]);
      expect(findRawMatches(lines, ''), isEmpty);
      expect(findRawMatches(lines, '없음'), isEmpty);
    });
  });

  group('raw detail screen', () {
    testWidgets('shows stored json lines with fetch metadata', (tester) async {
      await _pumpScreen(tester, _FakeSource(loadBehavior: (_) async => _storedData()));
      expect(find.textContaining('C_A_CONTENTS'), findsNothing);
      expect(find.textContaining('note_a'), findsWidgets);
      expect(
        find.textContaining('받은 시각 2026-10-17T12:34:56.789Z'),
        findsOneWidget,
      );
    });

    testWidgets('search counts and steps through matches', (tester) async {
      await _pumpScreen(tester, _FakeSource(loadBehavior: (_) async => _storedData()));
      await tester.enterText(find.byType(TextField), 'ZZMATCH');
      await tester.pump();
      expect(find.text('3개 중 1번째'), findsOneWidget);
      await tester.tap(find.byTooltip('다음 일치'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('3개 중 2번째'), findsOneWidget);
      await tester.tap(find.byTooltip('이전 일치'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('3개 중 1번째'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '없는검색어');
      await tester.pump();
      expect(find.text('일치 없음'), findsOneWidget);
    });

    testWidgets('copies the whole pretty json', (tester) async {
      final data = _storedData();
      var copied = '';
      addTearDown(() => RawDetailViewScreen.copyOverride = null);
      RawDetailViewScreen.copyOverride = (text) async => copied = text;
      await _pumpScreen(tester, _FakeSource(loadBehavior: (_) async => data));
      await tester.tap(find.byTooltip('전체 복사'));
      await tester.pump();
      expect(copied, data.pretty);
      expect(find.text('원본 JSON을 복사했습니다.'), findsOneWidget);
    });

    testWidgets('shares a <ID>.json file', (tester) async {
      final data = _storedData();
      final source = _FakeSource(loadBehavior: (_) async => data);
      await _pumpScreen(tester, source);
      await tester.tap(find.byTooltip('공유'));
      await tester.pump();
      expect(source.shared, [('90000001', data.pretty)]);
    });

    testWidgets('standalone rewrites the file from the db payload', (
      tester,
    ) async {
      final data = _storedData();
      final source = _FakeSource(loadBehavior: (_) async => data);
      await _pumpScreen(tester, source);
      expect(find.text('파일로 다시 쓰기'), findsOneWidget);
      await tester.tap(find.text('파일로 다시 쓰기'));
      await tester.pump();
      expect(source.rewritten.single.$1, '90000001');
      expect(source.rewritten.single.$2['result'], data.sanitized['result']);
      expect(find.text('원본 파일을 다시 썼습니다: 90000001.json'), findsOneWidget);
    });

    testWidgets('rewrite failure shows an error notice', (tester) async {
      await _pumpScreen(
        tester,
        _FakeSource(
          loadBehavior: (_) async => _storedData(),
          rewriteBehavior: (_, _) async => null,
        ),
      );
      await tester.tap(find.text('파일로 다시 쓰기'));
      await tester.pump();
      expect(find.text('파일로 다시 쓸 수 없는 신고 ID입니다.'), findsOneWidget);
    });

    testWidgets('client hides the rewrite action', (tester) async {
      await _pumpScreen(
        tester,
        _FakeSource(
          isStandalone: false,
          loadBehavior: (_) async => _storedData(),
        ),
      );
      expect(find.text('파일로 다시 쓰기'), findsNothing);
    });

    testWidgets('missing shows the optimize notice', (tester) async {
      await _pumpScreen(tester, _FakeSource());
      expect(find.text('아직 원본이 없습니다(DB 최적화가 채웁니다)'), findsOneWidget);
      expect(find.text('파일로 다시 쓰기'), findsNothing);
    });

    testWidgets('corrupt shows the damage notice', (tester) async {
      await _pumpScreen(
        tester,
        _FakeSource(loadBehavior: (_) async => throw const RawDetailCorrupt()),
      );
      expect(
        find.textContaining('손상되어 보여줄 수 없습니다'),
        findsOneWidget,
      );
    });

    testWidgets('network error shows retry and loads again', (tester) async {
      var calls = 0;
      await _pumpScreen(
        tester,
        _FakeSource(
          loadBehavior: (_) async {
            calls++;
            if (calls == 1) throw Exception('네트워크 오류');
            return _storedData();
          },
        ),
      );
      expect(find.textContaining('원본을 불러오지 못했습니다'), findsOneWidget);
      await tester.tap(find.text('다시 시도'));
      await tester.pump();
      await tester.pump();
      expect(calls, 2);
      expect(find.textContaining('note_a'), findsWidgets);
    });

    for (final brightness in Brightness.values) {
      testWidgets('360px $brightness has no overflow with a long body', (
        tester,
      ) async {
        final longBody = '긴 본문입니다. ' * 400;
        final json = {
          'result': {'C_NO': '90000001', 'C_A_CONTENTS': longBody},
        };
        await _pumpScreen(
          tester,
          _FakeSource(
            loadBehavior: (_) async => RawDetailData(
              pretty: prettyRawJson(json),
              sanitized: json,
            ),
          ),
          brightness: brightness,
          size: const Size(360, 640),
        );
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField), '긴 본문');
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('개 중 1번째'), findsOneWidget);
      });
    }
  });

  group('detail sheet action visibility', () {
    Future<void> pumpSheet(WidgetTester tester, ReportProvider provider) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: ReportDetailSheet(report: _minimalReport())),
          ),
        ),
      );
      await tester.pump();
      addTearDown(provider.dispose);
    }

    test('showRawDetailAction hides only client without the capability', () {
      expect(
        ReportDetailSheet.showRawDetailAction(
          mode: AppMode.standalone,
          rawDetailSupported: false,
        ),
        isTrue,
      );
      expect(
        ReportDetailSheet.showRawDetailAction(
          mode: AppMode.server,
          rawDetailSupported: true,
        ),
        isTrue,
      );
      expect(
        ReportDetailSheet.showRawDetailAction(
          mode: AppMode.server,
          rawDetailSupported: false,
        ),
        isFalse,
      );
    });

    testWidgets('standalone sheet shows the action', (tester) async {
      await pumpSheet(tester, _StandaloneProvider());
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(find.text('원본 응답'), findsOneWidget);
    });

    testWidgets('client sheet without capability hides the action', (
      tester,
    ) async {
      await pumpSheet(tester, _ClientWithoutRaw());
      expect(find.text('원본 응답'), findsNothing);
    });

    testWidgets('client sheet with capability shows the action', (
      tester,
    ) async {
      await pumpSheet(tester, _ClientWithRaw());
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(find.text('원본 응답'), findsOneWidget);
    });
  });

  group('settings raw folder item', () {
    const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'safetyreport',
        packageName: 'x',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(perm, (_) async => false);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(perm, null);
    });

    Future<void> pumpSettings(
      WidgetTester tester,
      ReportProvider provider,
    ) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsScreen(),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('standalone shows the raw folder item', (tester) async {
      await pumpSettings(tester, _StandaloneProvider());
      expect(find.text('원본 응답 폴더'), findsOneWidget);
    });

    testWidgets('client hides the raw folder item', (tester) async {
      await pumpSettings(tester, _ClientWithoutRaw());
      expect(find.text('원본 응답 폴더'), findsNothing);
      // 기존 파일 관리 항목은 양쪽에 그대로 있다.
      expect(find.textContaining('파일 관리'), findsOneWidget);
    });
  });

  group('file browser raw folder', () {    test('raw_details dir itself is protected, files inside are not', () {
      expect(
        isProtectedRawDetailsDir('/fake/root/raw_details', '/fake/root'),
        isTrue,
      );
      expect(
        isProtectedRawDetailsDir('/fake/root/raw_details/', '/fake/root'),
        isTrue,
      );
      expect(
        isProtectedRawDetailsDir(
          '/fake/root/raw_details/90000001.json',
          '/fake/root',
        ),
        isFalse,
      );
      expect(
        isProtectedRawDetailsDir('/fake/root/downloads', '/fake/root'),
        isFalse,
      );
    });

    testWidgets('opens directly at raw_details with initialSubdir', (
      tester,
    ) async {
      final source = _RecordingFiles([
        _entry('90000001.json'),
      ]);
      final provider = _StandaloneProvider();
      addTearDown(provider.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: FileBrowserScreen(
              localFiles: source,
              initialSubdir: 'raw_details',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(source.listed, ['/fake/root/raw_details']);
      // 현재 위치에 raw_details 가 보인다.
      expect(
        find.textContaining('mysafetyreport/raw_details'),
        findsOneWidget,
      );
      expect(find.text('90000001.json'), findsOneWidget);
    });

    testWidgets('raw folder row has no delete affordance', (tester) async {
      final source = _RecordingFiles([
        _entry('raw_details', dir: true),
        _entry('a.json'),
      ]);
      final provider = _StandaloneProvider();
      addTearDown(provider.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: FileBrowserScreen(localFiles: source),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      // 폴더(raw_details 포함)는 삭제 버튼이 없고, 파일에만 있다.
      expect(find.byTooltip('파일 삭제'), findsOneWidget);
    });
  });
}
