// SQ-P06: 페이지 목록은 카드·선택 동작에 쓰는 열만 읽고(신고내용·처리내용·첨부 URL 제외),
// 상세 시트를 열면 그 한 건을 다시 읽어 예전과 같은 내용을 보인다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/rating_batch_result.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/large_data_fixture.dart';

const _target = 'fixture-000000057'; // 57 % 3 == 0 → traffic, 목록 맨 위
const _file = 'https://example.test/report-attachment.pdf';

String _today() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

Future<Directory> _openFixture() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = Directory.systemTemp.createTempSync('sr_compact_list_');
  await databaseFactory.setDatabasesPath(dir.path);
  final db = await LocalDbService.db;
  await seedLargeDataFixture(db, 60);
  await db.update(
    'reports',
    {'신고일': _today(), '첨부파일': _file, '첨부사진': '', '보완_요청_내용': '합성 보완 요청'},
    where: 'ID=?',
    whereArgs: [_target],
  );
  return dir;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'fixture',
      AppPrefsKeys.standalonePhoneNumber: 'fixture',
    });
  });

  test('compact pages omit long columns but keep every list field', () async {
    final dir = await _openFixture();
    addTearDown(() async {
      await LocalDbService.closeDb();
      dir.deleteSync(recursive: true);
    });
    for (final scope in ['', 'duplicates']) {
      final full = await LocalDbService.getReportPage(
        category: 'traffic',
        scope: scope,
      );
      final compact = await LocalDbService.getReportPage(
        category: 'traffic',
        scope: scope,
        compact: true,
      );
      expect(compact.total, full.total);
      expect(compact.reports.length, full.reports.length);
      for (var i = 0; i < full.reports.length; i++) {
        final a = full.reports[i];
        final b = compact.reports[i];
        expect(a.detailLoaded, isTrue);
        expect(b.detailLoaded, isFalse);
        expect(b.reportContent, isEmpty);
        expect(b.processContent, isEmpty);
        expect(b.attachedFiles, isEmpty);
        expect(b.supplementRequest, isEmpty);
        // 목록·선택·별점 판정이 쓰는 값은 그대로다.
        expect(
          [
            b.id,
            b.reportNumber,
            b.name,
            b.date,
            b.responseDate,
            b.agency,
            b.agencyCode,
            b.manager,
            b.status,
            b.result,
            b.fineInfo,
            b.penaltyPoints,
            b.carNumber,
            b.law,
            b.location,
            b.occurrenceDate,
            b.occurrenceTime,
            b.pollStatus,
            b.processingFinish,
            b.rating,
            b.ratingCause,
            b.category,
            b.syncedAt,
            b.supplementCount,
            b.supplementOpen,
            b.supplementRequester,
            b.supplementRequestedAt,
            b.supplementCompletedAt,
            b.totalCount,
            b.validCount,
          ],
          [
            a.id,
            a.reportNumber,
            a.name,
            a.date,
            a.responseDate,
            a.agency,
            a.agencyCode,
            a.manager,
            a.status,
            a.result,
            a.fineInfo,
            a.penaltyPoints,
            a.carNumber,
            a.law,
            a.location,
            a.occurrenceDate,
            a.occurrenceTime,
            a.pollStatus,
            a.processingFinish,
            a.rating,
            a.ratingCause,
            a.category,
            a.syncedAt,
            a.supplementCount,
            a.supplementOpen,
            a.supplementRequester,
            a.supplementRequestedAt,
            a.supplementCompletedAt,
            a.totalCount,
            a.validCount,
          ],
        );
      }
    }
  });

  test('a stored rating result keeps the omitted-detail marker', () {
    final compact = Report.fromJson({
      'ID': 'x',
      '신고번호': 'SPP-1',
    }).copyWith(detailLoaded: false);
    final restored = Report.fromJson(reportToMap(compact));
    expect(restored.detailLoaded, isFalse);
    final full = Report.fromJson(reportToMap(Report.fromJson({'ID': 'y'})));
    expect(full.detailLoaded, isTrue);
  });

  testWidgets('opening a compact card loads the full report into the sheet', (
    tester,
  ) async {
    late Directory dir;
    final provider = ReportProvider();
    await tester.runAsync(() async {
      dir = await _openFixture();
      await provider.init();
    });
    addTearDown(() async {
      provider.dispose();
      await LocalDbService.closeDb();
      dir.deleteSync(recursive: true);
    });
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(body: LocalPagedReportList(category: 'traffic')),
        ),
      ),
    );
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(finder, findsWidgets);
    }

    final card = find.textContaining('SPP-000000057');
    await waitFor(card);
    await tester.tap(card.first);
    final sheet = find.byType(ReportDetailSheet);
    await waitFor(sheet);
    final shown = tester.widget<ReportDetailSheet>(sheet).report;
    expect(shown.detailLoaded, isTrue);
    expect(shown.id, _target);
    expect(shown.reportContent, '합성 본문');
    expect(shown.processContent, '합성 답변\nNULL·빈값·결과 미상');
    expect(shown.attachedFiles, _file);
    expect(shown.supplementRequest, '합성 보완 요청');
    expect(find.text('신고내용'), findsWidgets);
    expect(find.text('합성 본문'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
