// 통계 화면 실제 렌더 캡처(검수용 도구). 환경변수가 있을 때만 실행하고, 일반 flutter test 에는 영향이 없다.
//   SR_RENDER_OUT=<PNG 폴더>  SR_RENDER_MODE=standalone|client
//   standalone: SR_RENDER_DB=<서버 fixture 를 가져온 모바일 DB>  (임시 폴더에 복사해서 쓴다)
//   client:     SR_RENDER_BASE=<fixture 서버 주소>  SR_RENDER_KEY=<fixture API 키>
// 폰트: loadGoldenFonts(호스트 Noto CJK + MaterialIcons). 렌더 중 예외(overflow 포함)가 하나라도 있으면 실패한다.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/ui_harness.dart';

class _RenderProvider extends ReportProvider {
  _RenderProvider(this._mode, this._base, this._key);
  final AppMode _mode;
  final String _base;
  final String _key;
  @override
  AppMode get appMode => _mode;
  @override
  String get baseUrl => _base;
  @override
  String get apiKey => _key;
  @override
  bool get excludeWithdraw => true;
  @override
  @override
  bool get useRepresentativeRecords => true;
}

void main() {
  final env = Platform.environment;
  final out = env['SR_RENDER_OUT'];
  final mode = env['SR_RENDER_MODE'] == 'client'
      ? AppMode.server
      : AppMode.standalone;
  TestWidgetsFlutterBinding.ensureInitialized();

  const boundaryKey = ValueKey('render-boundary');
  Directory? dbDir;

  setUpAll(() async {
    if (out == null) return;
    Directory(out).createSync(recursive: true);
    if (mode == AppMode.standalone) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dbDir = Directory.systemTemp.createTempSync('sr_render_');
      await databaseFactory.setDatabasesPath(dbDir!.path);
      File(
        env['SR_RENDER_DB']!,
      ).copySync('${dbDir!.path}/standalone_reports.db');
    } else {
      HttpOverrides.global = null; // fixture 서버(로컬)에만 실제 요청
    }
    SharedPreferences.setMockInitialValues({});
  });
  tearDownAll(() async {
    if (out == null) return;
    if (mode == AppMode.standalone) {
      await LocalDbService.closeDb();
      dbDir?.deleteSync(recursive: true);
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 2));
    final bytes = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.png),
    );
    File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  final scenarios = <(double, Brightness, double)>[
    for (final w in [360.0, 390.0, 430.0])
      for (final b in Brightness.values) (w, b, 1.0),
    (360.0, Brightness.light, 1.3),
    (360.0, Brightness.dark, 2.0),
  ];

  for (final (width, brightness, scale) in scenarios) {
    final tag =
        '${mode == AppMode.server ? 'client' : 'standalone'}-${width.toInt()}-${brightness.name}-x$scale';
    testWidgets('통계 화면 렌더 $tag', (tester) async {
      final skip = await loadGoldenFonts();
      if (skip != null) {
        markTestSkipped(skip);
        return;
      }
      tester.view.physicalSize = Size(width * 2, 800 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      try {
        final provider = _RenderProvider(
          mode,
          env['SR_RENDER_BASE'] ?? '',
          env['SR_RENDER_KEY'] ?? '',
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: ChangeNotifierProvider<ReportProvider>.value(
              value: provider,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.build(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const StatisticsScreen(),
              ),
            ),
          ),
        );
        await settle(tester);
        await shot(tester, '$tag-1-summary');

        Future<void> reveal(Finder f) async {
          await tester.ensureVisible(f);
          await settle(tester);
        }

        await reveal(find.byKey(const ValueKey('stats-charts-toggle')));
        await tester.tap(find.byKey(const ValueKey('stats-charts-toggle')));
        await settle(tester);
        await reveal(find.text('처분 분포'));
        await shot(tester, '$tag-2-charts');
        await reveal(find.text('위반 유형별 현황'));
        await shot(tester, '$tag-3-types');

        await reveal(find.byKey(const ValueKey('stats-type-person')));
        await tester.tap(find.byKey(const ValueKey('stats-type-person')));
        await settle(tester);
        await shot(tester, '$tag-4-person');

        await tester.tap(find.byKey(const ValueKey('stats-type-other-agency')));
        await settle(tester);
        await shot(tester, '$tag-5-other-agency');

        await tester.scrollUntilVisible(
          find.text('전국 안전신고 현황'),
          400,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('stats-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await settle(tester);
        await shot(tester, '$tag-6-sunwi');

        // 다음 시나리오 전에 화면을 내려 타이머(전국 현황 자동 넘김 등)를 정리한다.
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        // ignore: avoid_print
        print('render-done $tag errors=${errors.length}');
      } finally {
        FlutterError.onError = previous; // 테스트 끝나기 전에 되돌려야 한다(바인딩 검사)
      }
      // Standalone 전국 현황은 테스트의 가짜 HTTP(400)에 재시도(2초 지연)를 건다 — 가짜 시간을 흘려 끝낸다.
      for (
        var i = 0;
        i < 400 && tester.binding.transientCallbackCount >= 0;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(seconds: 3));
      }
      expect(errors, isEmpty, reason: describeErrors(errors));
    }, skip: out == null); // SR_RENDER_OUT 가 있을 때만 실행
  }
}
