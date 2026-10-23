import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _row = <String, Object?>{
  'ID': 'fixture-report-dates',
  '신고번호': 'SPP-FIXTURE-16',
  '신고명': '답변 날짜 확인용 합성 신고',
  '신고일': '2026-10-01',
  '답변일': '2026-10-16',
  '처리상태': '수용',
  '차량번호': '123가4567',
  'category': 'traffic',
};

class _Provider extends ReportProvider {
  _Provider(this.mode, {this.responseDate = '2026-10-16'});
  final AppMode mode;
  final String responseDate;

  @override
  AppMode get appMode => mode;
  @override
  bool get useRepresentativeRecords => false;

  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (
    reports: [
      Report.fromJson({..._row, '답변일': responseDate}),
    ],
    total: 1,
  );
}

Future<void> _pumpList(
  WidgetTester tester,
  _Provider provider, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(provider.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.build(brightness),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const Scaffold(
            body: LocalPagedReportList(category: 'traffic'),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 100 && find.text('소요 15일').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('SPP-FIXTURE-16').evaluate().isNotEmpty) break;
  }
  expect(tester.takeException(), isNull);
}

void main() {
  for (final mode in AppMode.values) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('답변일과 소요일: ${mode.name}/${brightness.name}/x$scale', (
          tester,
        ) async {
          if (mode == AppMode.standalone) {
            late Directory dir;
            await tester.runAsync(() async {
              sqfliteFfiInit();
              databaseFactory = databaseFactoryFfi;
              dir = Directory.systemTemp.createTempSync('sr_report_dates_');
              await databaseFactory.setDatabasesPath(dir.path);
              await (await LocalDbService.db).insert('reports', _row);
            });
            addTearDown(() async {
              await LocalDbService.closeDb();
              dir.deleteSync(recursive: true);
            });
          }
          await _pumpList(
            tester,
            _Provider(mode),
            brightness: brightness,
            scale: scale,
          );
          expect(find.text('신고: 2026-10-01'), findsOneWidget);
          expect(find.text('답변: 2026-10-16'), findsOneWidget);
          expect(find.text('소요 15일'), findsOneWidget);
          for (final text in ['신고: 2026-10-01', '답변: 2026-10-16']) {
            expect(
              tester
                  .renderObject<RenderParagraph>(find.text(text))
                  .didExceedMaxLines,
              isFalse,
              reason: '큰 글꼴에서도 날짜 전체가 보여야 한다',
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets('잘못된 답변일도 원문은 보존하고 소요일만 생략한다', (tester) async {
    await _pumpList(
      tester,
      _Provider(AppMode.server, responseDate: '2026-02-30'),
    );
    expect(find.text('답변: 2026-02-30'), findsOneWidget);
    expect(find.textContaining('소요'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
