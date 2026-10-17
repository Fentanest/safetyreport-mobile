// Sol 모바일 P4 검수 5건 회귀 시험(명세 4절 원본 응답).
//
// 1. source 미주입 실제 진입 경로(Provider 해결 → Standalone 로컬 DB·Client API)로 JSON 표시.
// 2. 열린 시트에서 capability 가 생기면 '원본 응답' 버튼 표시.
// 3. 수천 줄 JSON 에서 화면 밖 일치로 다음/이전 이동 시 해당 줄이 보임.
// 4. 공유 뒤 임시 <ID>.json 삭제(성공·취소·실패), 화면 종료 시 잔여 정리.
// 5. Download 대체 경로에서도 '원본 응답 폴더'가 실제 raw_details 를 염.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/file_browser_screen.dart';
import 'package:safetyreport/screens/raw_detail_view_screen.dart';
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/raw_detail.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _StandaloneProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;

  @override
  bool get isStandaloneDemo => true;

  @override
  Future<void> refreshAll() async {}
}

class _ServerProvider extends ReportProvider {
  @override
  String get baseUrl => 'https://client-fake.example';

  @override
  String get apiKey => 'fake-key';

  @override
  Future<void> refreshAll() async {}
}

/// capability 가 늦게 생기는 Client (설정 응답 전 시트를 연 상황).
class _FlippableClientProvider extends ReportProvider {
  bool rawDetail = false;

  @override
  bool get rawDetailSupported => rawDetail;

  void setRawDetail(bool v) {
    rawDetail = v;
    notifyListeners();
  }

  @override
  Future<void> refreshAll() async {}
}

class _FakeSource implements RawDetailSource {
  Future<RawDetailData> Function(String id)? loadBehavior;

  _FakeSource({this.loadBehavior});

  @override
  bool get isStandalone => true;

  @override
  Future<RawDetailData> load(String reportId) {
    final behavior = loadBehavior;
    if (behavior != null) return behavior(reportId);
    throw const RawDetailMissing();
  }

  @override
  Future<String?> rewriteFile(
    String reportId,
    Map<String, dynamic> sanitized,
  ) async => '/tmp/$reportId.json';

  @override
  Future<void> shareFile(String reportId, String pretty) async {}
}

RawDetailData _smallData() {
  final json = {
    'result': {'C_NO': '90000001', 'note_a': '진입 경로 확인용'},
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

/// 비동기 로드가 끝날 때까지(최대 ~2초) 기다린다.
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int rounds = 200,
}) async {
  for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RawDetailViewScreen.copyOverride = null;
    RawDetailSource.debugSourceOverride = null;
    ClientRawDetailSource.debugLoadOverride = null;
    debugRawShareTempDir = null;
    debugRawShareHook = null;
  });

  tearDown(() {
    RawDetailSource.debugSourceOverride = null;
    ClientRawDetailSource.debugLoadOverride = null;
    debugRawShareTempDir = null;
    debugRawShareHook = null;
  });

  group('RawDetailSource.of', () {
    testWidgets('standalone이면 로컬 DB 원본, client면 서버 API 원본', (
      tester,
    ) async {
      RawDetailSource? fromStandalone;
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: _StandaloneProvider(),
          child: MaterialApp(home: Builder(builder: (context) {
            fromStandalone = RawDetailSource.of(context);
            return const SizedBox();
          })),
        ),
      );
      RawDetailSource? fromClient;
      final server = _ServerProvider();
      addTearDown(server.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: server,
          child: MaterialApp(home: Builder(builder: (context) {
            fromClient = RawDetailSource.of(context);
            return const SizedBox();
          })),
        ),
      );
      expect(fromStandalone, isA<StandaloneRawDetailSource>());
      final client = fromClient;
      expect(client, isA<ClientRawDetailSource>());
      expect((client as ClientRawDetailSource).baseUrl, server.baseUrl);
      expect(client.apiKey, server.apiKey);
    });
  });

  group('실제 진입 경로(source 미주입)', () {
    late Directory dbDir;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dbDir = Directory.systemTemp.createTempSync('sr_sol_p4_raw_');
      await databaseFactory.setDatabasesPath(dbDir.path);
      SharedPreferences.setMockInitialValues({});
      final prep = prepareRawDetail({
        'result': {'C_NO': '90000001', 'note_a': '진입 경로 확인용'},
        'fetched_via': 'crawl',
      });
      final db = await LocalDbService.db;
      await db.insert('report_detail_raw', {
        'ID': '90000001',
        'raw_zlib': compressRawDetail(prep.canonical),
        'raw_sha256': prep.sha256,
        'raw_size': prep.canonical.length,
        'fetched_at': '2026-10-17T12:34:56.789Z',
        'source': 'crawl',
      });
    });

    tearDownAll(() async {
      await LocalDbService.closeDb();
      dbDir.deleteSync(recursive: true);
    });

    testWidgets('standalone 로컬 DB 원본으로 JSON 표시', (tester) async {
      final provider = _StandaloneProvider();
      addTearDown(provider.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          // 실제 진입 경로: source 를 주입하지 않는다.
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const RawDetailViewScreen(reportId: '90000001'),
          ),
        ),
      );
      await _waitFor(tester, find.textContaining('note_a'));
      expect(find.textContaining('note_a'), findsWidgets);
      expect(find.textContaining('원본을 불러오지 못했습니다'), findsNothing);
    });

    testWidgets('client 가짜 API 원본으로 JSON 표시', (tester) async {
      final provider = _ServerProvider();
      addTearDown(provider.dispose);
      var seenBaseUrl = '';
      var seenApiKey = '';
      ClientRawDetailSource.debugLoadOverride =
          (baseUrl, apiKey, reportId) async {
            seenBaseUrl = baseUrl;
            seenApiKey = apiKey;
            expect(reportId, '90000001');
            return _smallData();
          };
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          // 실제 진입 경로: source 를 주입하지 않는다.
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const RawDetailViewScreen(reportId: '90000001'),
          ),
        ),
      );
      await _waitFor(tester, find.textContaining('note_a'));
      expect(find.textContaining('note_a'), findsWidgets);
      expect(seenBaseUrl, provider.baseUrl);
      expect(seenApiKey, provider.apiKey);
    });
  });

  group('열린 시트 capability 반영', () {
    testWidgets('설정 응답 뒤 버튼이 나타난다', (tester) async {
      final provider = _FlippableClientProvider();
      addTearDown(provider.dispose);
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
      // 설정 응답 전: 버튼 없음.
      expect(find.text('원본 응답'), findsNothing);
      // 설정 응답: capability 가 생기면 열린 시트가 갱신된다.
      provider.setRawDetail(true);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(find.text('원본 응답'), findsOneWidget);
    });
  });

  group('긴 JSON 화면 밖 검색 이동', () {
    /// 평균 높이 어림을 크게 빗나가게 하는 수만 자 한 줄(수백 줄로 접힘).
    String longFiller() => '긴내용 ' * 8000;

    RawDetailData bigData() {
      final buf = StringBuffer('{\n');
      for (var i = 0; i < 3000; i++) {
        final value = i == 2500 ? 'ZZTARGET-LINE-2500' : 'padding value $i';
        buf.write('  "k${i.toString().padLeft(4, '0')}": "$value"');
        buf.write(i == 2999 ? '\n' : ',\n');
      }
      buf.write('}');
      return RawDetailData(pretty: buf.toString(), sanitized: const {});
    }

    Future<void> pumpBig(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: RawDetailViewScreen(
            reportId: '90000001',
            source: _FakeSource(loadBehavior: (_) async => bigData()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('다음·이전 이동 시 화면 밖 일치가 보인다', (tester) async {
      await pumpBig(tester);
      await tester.enterText(find.byType(TextField), 'ZZTARGET-LINE-2500');
      await tester.pump();
      expect(find.text('1개 중 1번째'), findsOneWidget);
      // 아직 화면 밖이라 해당 줄은 없다(검색창 텍스트와 겹치지 않게 줄 전체로 찾는다).
      const line = '"k2500": "ZZTARGET-LINE-2500"';
      expect(find.textContaining(line), findsNothing);
      await tester.tap(find.byTooltip('다음 일치'));
      await tester.pumpAndSettle();
      expect(find.textContaining(line), findsOneWidget);
      await tester.tap(find.byTooltip('이전 일치'));
      await tester.pumpAndSettle();
      expect(find.textContaining(line), findsOneWidget);
    });

    testWidgets('앞쪽에 매우 긴 줄이 있어도 뒤쪽 일치로 이동한다', (tester) async {
      // 앞쪽 수만 자 한 줄(수백 줄로 접힘)이 평균 높이 어림을 크게 빗나가게 한다.
      final buf = StringBuffer('{\n');
      buf.write('  "blob": "${longFiller()}",\n');
      for (var i = 0; i < 3000; i++) {
        final value = i == 2900 ? 'ZZTARGET-LATE-2900' : 'padding value $i';
        buf.write('  "k${i.toString().padLeft(4, '0')}": "$value"');
        buf.write(i == 2999 ? '\n' : ',\n');
      }
      buf.write('}');
      final data = RawDetailData(pretty: buf.toString(), sanitized: const {});
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: RawDetailViewScreen(
            reportId: '90000001',
            source: _FakeSource(loadBehavior: (_) async => data),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'ZZTARGET-LATE-2900');
      await tester.pump();
      expect(find.text('1개 중 1번째'), findsOneWidget);
      const line = '"k2900": "ZZTARGET-LATE-2900"';
      expect(find.textContaining(line), findsNothing);
      await tester.tap(find.byTooltip('다음 일치'));
      await tester.pumpAndSettle();
      // 최대 시도 안에 반드시 도달한다.
      expect(find.textContaining(line), findsOneWidget);
    });

    testWidgets('긴 줄을 사이에 두고 앞뒤 일치로 왕복한다', (tester) async {
      // 일치는 앞(8번 줄)·뒤(2900번 줄), 수만 자 줄은 중간(1500번 앞)에 둔다.
      final buf = StringBuffer('{\n');
      for (var i = 0; i < 3000; i++) {
        if (i == 1500) buf.write('  "blob": "${longFiller()}",\n');
        final value = i == 8
            ? 'ZZTARGET-EARLY-8'
            : (i == 2900 ? 'ZZTARGET-LATE-2900' : 'padding value $i');
        buf.write('  "k${i.toString().padLeft(4, '0')}": "$value"');
        buf.write(i == 2999 ? '\n' : ',\n');
      }
      buf.write('}');
      final data = RawDetailData(pretty: buf.toString(), sanitized: const {});
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: RawDetailViewScreen(
            reportId: '90000001',
            source: _FakeSource(loadBehavior: (_) async => data),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'ZZTARGET-');
      await tester.pump();
      expect(find.text('2개 중 1번째'), findsOneWidget);
      const lateLine = '"k2900": "ZZTARGET-LATE-2900"';
      const earlyLine = '"k0008": "ZZTARGET-EARLY-8"';
      // 아래로: 긴 줄을 지나 뒤쪽 일치까지 간다.
      await tester.tap(find.byTooltip('다음 일치'));
      await tester.pumpAndSettle();
      expect(find.textContaining(lateLine), findsOneWidget);
      // 위로: 긴 줄을 지나 앞쪽 일치까지 돌아온다.
      await tester.tap(find.byTooltip('이전 일치'));
      await tester.pumpAndSettle();
      expect(find.textContaining(earlyLine), findsOneWidget);
    });
  });

  group('공유 임시 파일 정리', () {
    test('성공·취소·실패 모두 자기 <ID>.json 과 하위 폴더를 지운다', () async {
      final dir = Directory.systemTemp.createTempSync('sr_sol_p4_share_');
      addTearDown(() => dir.deleteSync(recursive: true));
      debugRawShareTempDir = () async => dir;
      final seenPaths = <String>[];
      debugRawShareHook = (params) async {
        final path = params.files?.single.path ?? '';
        seenPaths.add(path);
        // 공유되는 이름은 <ID>.json 그대로다(하위 폴더별로 분리).
        expect(path.endsWith('/90000001.json'), isTrue);
        expect(File(path).existsSync(), isTrue);
        return const ShareResult('', ShareResultStatus.success);
      };
      await sharePrettyRawJson('90000001', '{"a":1}');
      expect(seenPaths.length, 1);
      expect(File(seenPaths.single).existsSync(), isFalse);
      // 자기 하위 폴더까지 정리한다.
      expect(Directory(seenPaths.single).parent.existsSync(), isFalse);

      debugRawShareHook = (_) async =>
          const ShareResult('', ShareResultStatus.dismissed);
      await sharePrettyRawJson('90000001', '{"a":1}');
      expect(seenPaths.length, 2);
      expect(File(seenPaths.last).existsSync(), isFalse);

      debugRawShareHook = (_) async => throw StateError('공유 실패');
      await expectLater(
        sharePrettyRawJson('90000001', '{"a":1}'),
        throwsStateError,
      );
      expect(seenPaths.length, 3);
      expect(File(seenPaths.last).existsSync(), isFalse);
    });

    test('동시에 두 번 공유해도 각자 파일이 준비 중 삭제되지 않고 끝나면 모두 정리', () async {
      final dir = Directory.systemTemp.createTempSync('sr_sol_p4_share2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      debugRawShareTempDir = () async => dir;
      final gate = Completer<void>();
      final sharedPaths = <String>[];
      var calls = 0;
      debugRawShareHook = (params) async {
        calls++;
        // 첫 공유를 준비 중에 붙잡아 두고 두 번째 공유를 겹쳐 시작한다.
        sharedPaths.add(params.files!.single.path);
        if (calls == 1) await gate.future;
        return const ShareResult('', ShareResultStatus.success);
      };
      final first = sharePrettyRawJson('90000001', '{"a":1}');
      for (var i = 0; i < 500 && sharedPaths.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(sharedPaths.length, 1);
      await sharePrettyRawJson('90000001', '{"a":2}');
      expect(calls, 2);
      // 공유마다 고유 파일이다.
      expect(sharedPaths[0] == sharedPaths[1], isFalse);
      // 준비 중인 첫 파일은 살아 있고, 끝난 두 번째는 정리됐다.
      expect(File(sharedPaths[0]).existsSync(), isTrue);
      expect(File(sharedPaths[1]).existsSync(), isFalse);
      gate.complete();
      await first;
      expect(File(sharedPaths[0]).existsSync(), isFalse);
    });

    testWidgets('화면을 떠나면 남은 임시 파일을 지운다', (tester) async {
      final dir = Directory.systemTemp.createTempSync('sr_sol_p4_leave_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      debugRawShareTempDir = () async => dir;
      final leftover = File('${dir.path}/90000001.json')
        ..writeAsStringSync('{"a":1}');
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: RawDetailViewScreen(
            reportId: '90000001',
            source: _FakeSource(loadBehavior: (_) async => _smallData()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(Container());
      await tester.pump();
      await _waitFor(tester, find.text('절대 없음'), rounds: 20);
      expect(leftover.existsSync(), isFalse);
    });
  });

  group('진행 중 공유와 화면 종료', () {
    late Directory dbDir;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dbDir = Directory.systemTemp.createTempSync('sr_sol_final_share_db_');
      await LocalDbService.closeDb();
      await databaseFactory.setDatabasesPath(dbDir.path);
      final prep = prepareRawDetail({
        'result': {'C_NO': '90000001', 'note_a': '진행 중 공유 확인용'},
        'fetched_via': 'crawl',
      });
      final db = await LocalDbService.db;
      await db.insert('report_detail_raw', {
        'ID': '90000001',
        'raw_zlib': compressRawDetail(prep.canonical),
        'raw_sha256': prep.sha256,
        'raw_size': prep.canonical.length,
        'fetched_at': '2026-10-17T12:34:56.789Z',
        'source': 'crawl',
      });
    });

    tearDownAll(() async {
      await LocalDbService.closeDb();
      dbDir.deleteSync(recursive: true);
    });

    testWidgets('화면을 떠나도 진행 중인 공유 파일은 지우지 않고 끝나면 정리한다', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('sr_sol_final_share_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      debugRawShareTempDir = () async => dir;
      final gate = Completer<ShareResult>();
      String? sharedPath;
      debugRawShareHook = (params) async {
        sharedPath = params.files!.single.path;
        return gate.future;
      };
      final provider = _StandaloneProvider();
      addTearDown(provider.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          // 실제 진입 경로: source 미주입 → Standalone 실제 공유를 쓴다.
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const RawDetailViewScreen(reportId: '90000001'),
          ),
        ),
      );
      await _waitFor(tester, find.textContaining('note_a'));
      await tester.tap(find.byTooltip('공유'));
      for (var i = 0; i < 200 && sharedPath == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(sharedPath, isNotNull);
      expect(File(sharedPath!).existsSync(), isTrue);
      // 화면을 떠나면 dispose 정리가 돌지만 진행 중인 공유 파일은 남는다.
      await tester.pumpWidget(Container());
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(File(sharedPath!).existsSync(), isTrue);
      // 공유가 끝나면 자기 파일이 정리된다.
      gate.complete(const ShareResult('', ShareResultStatus.success));
      for (var i = 0; i < 200 && File(sharedPath!).existsSync(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(File(sharedPath!).existsSync(), isFalse);
    });
  });

  group('원본 폴더 대체 경로', () {    testWidgets('Download 대체 경로의 raw_details 를 연다', (tester) async {
      final source = _FallbackFiles([
        LocalFileEntry(
          path: '/fake/Download/mysafetyreport/raw_details/90000001.json',
          name: '90000001.json',
          isDirectory: false,
          size: 128,
          modified: DateTime(2026, 10, 4, 9, 30),
        ),
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
      // Documents 아래가 아니라 실제 쓰기 경로(Download 대체)의 raw_details.
      expect(source.listed, '/fake/Download/mysafetyreport/raw_details');
      expect(
        find.textContaining('mysafetyreport/raw_details'),
        findsOneWidget,
      );
      expect(find.text('90000001.json'), findsOneWidget);
    });
  });
}

/// Documents 루트는 있지만 그 아래 raw_details 는 없고, 실제 쓰기는
/// Download 로 대체된 기기를 재현한다.
class _FallbackFiles extends LocalFileSource {
  _FallbackFiles(this.entries);

  final List<LocalFileEntry> entries;
  String listed = '';

  @override
  Future<Directory> root() async =>
      Directory('/fake/Documents/mysafetyreport');

  @override
  Future<Directory> subDir(String name) async =>
      Directory('/fake/Download/mysafetyreport/$name');

  @override
  Future<bool> exists(Directory dir) async =>
      dir.path != '/fake/Documents/mysafetyreport/raw_details';

  @override
  Future<List<LocalFileEntry>> list(Directory dir) async {
    listed = dir.path;
    return List.of(entries);
  }
}
