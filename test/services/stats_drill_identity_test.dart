import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/models/report_filter.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'package:safetyreport/services/local_db_service.dart';
import '../support/stats_identity_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr-identity-');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
    await seedIdentityReports();
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    AgencyRegistry.testInject(null);
    dir.deleteSync(recursive: true);
  });

  test('filter identity, wire format, copy and chip clearing', () {
    const f = ReportFilter(agency: '(구)옛기관', agencyKey: 'src:9999993:옛기관',
        manager: '김민수', managerExact: true);
    expect(f.isEmpty, isFalse);
    expect(f.toSearchJson()['agencyKey'], 'src:9999993:옛기관');
    expect(f.toSearchJson().containsKey('agency'), isFalse);
    expect(f.toSearchJson()['managerExact'], isTrue);
    expect(f.copyWith(), f);
    expect(f.copyWith().hashCode, f.hashCode);
    expect(f.copyWith(agencyKey: ''), isNot(f));
    expect(f.copyWith(managerExact: false), isNot(f));
    expect(f.activeLabels, ['기관: (구)옛기관', '담당자: 김민수']);
    expect(f.without(ReportFilterField.agency).agencyKey, '');
    expect(f.without(ReportFilterField.manager).managerExact, isFalse);
    expect(const ReportFilter(agencyKey: 'key').isEmpty, isFalse);
    expect(const ReportFilter().toSearchJson().containsKey('agencyKey'), isFalse);
    expect(const ReportFilter().toSearchJson().containsKey('managerExact'), isFalse);
  });

  test('collision and historical cards equal count and first page before LIMIT', () async {
    for (final representative in [false, true]) {
      final stats = await LocalDbService.computeStats(useRepresentativeRecords: representative);
      for (final cat in ['all', 'traffic']) {
        for (final kind in ['by_agency', 'by_person']) {
          for (final row in stats[cat][kind] as List) {
            final filter = ReportFilter(
              agency: row['agency'] as String,
              agencyKey: row['agency_key'] as String,
              manager: kind == 'by_person' ? row['person'] as String : '',
              managerExact: kind == 'by_person',
              statuses: const ['수용'], law: '합성 법규', lawExact: true,
              responseDateStart: '2026-01-01', responseDateEnd: '2026-12-31',
            );
            final page = await LocalDbService.getReportPage(category: cat,
                filter: filter, useRepresentativeRecords: representative);
            expect(page.total, row['total']);
            expect(page.reports.length, row['total']);
            expect((await LocalDbService.getReportPage(category: cat, filter: filter,
                page: 1, useRepresentativeRecords: representative)).reports, isEmpty);
          }
        }
      }
    }
    final broad = await LocalDbService.getReportPage(filter: const ReportFilter(agency: '합성기관'));
    expect(broad.total, 201);
    expect(broad.reports.length, 200);
    expect(broad.reports.any((r) => r.id == 'target'), isFalse);
    for (final filter in [
      const ReportFilter(agencyKey: 'src:9999991:합성기관', agency: '무시할 표시명'),
      const ReportFilter(manager: ' 김민수 ', managerExact: true),
    ]) {
      final page = await LocalDbService.getReportPage(filter: filter);
      expect(page.total, 1);
      expect(page.reports.single.id, 'target');
    }
    expect((await LocalDbService.getReportPage(filter: const ReportFilter(manager: '김민수'))).total, 201);
    final old = await LocalDbService.getReportPage(filter: const ReportFilter(
        agency: '(구)옛기관', agencyKey: 'src:9999993:옛기관'));
    expect(old.total, 1);
    expect(old.reports.single.id, 'old');
  });

  // 통계 표가 담당자를 앞뒤 공백만 지우고 대소문자를 살려 묶으므로 정확 일치도 대소문자를 구분한다(Opus 검수 결정, 서버와 같음).
  test('exact manager keeps comma and ampersand, trim, and is case-sensitive', () async {
    final db = await LocalDbService.db;
    for (final pair in [(' A,B&C ', 'A,B&C'), (' ÉCOLE ', 'ÉCOLE'), ('İ ΟΣ', 'İ ΟΣ'), ('\uFEFF김민수\u00a0', '김민수')]) {
      await db.update('reports', {'담당자': pair.$1}, where: 'ID = ?', whereArgs: ['target']);
      final page = await LocalDbService.getReportPage(filter: ReportFilter(manager: pair.$2, managerExact: true));
      expect(page.total, 1);
      expect(page.reports.single.id, 'target');
    }
    for (final pair in [(' A,B&C ', 'a,b&c'), (' ÉCOLE ', 'école'), ('Lee', 'LEE')]) {
      await db.update('reports', {'담당자': pair.$1}, where: 'ID = ?', whereArgs: ['target']);
      final page = await LocalDbService.getReportPage(filter: ReportFilter(manager: pair.$2, managerExact: true));
      expect(page.reports.map((r) => r.id), isNot(contains('target')), reason: pair.toString());
    }
    expect((await LocalDbService.getReportPage(filter: const ReportFilter(manager: '김민수,이담당', managerExact: true))).total, 0);
  });
}
