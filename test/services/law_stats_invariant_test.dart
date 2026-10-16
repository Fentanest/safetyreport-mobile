// 법규 막대 건수 == 드릴다운 행 수(2026-10-16). 서버 tests/test_law_values.py 와 같은 공통 벡터
// contracts/law-search-vectors.json 의 canonical_cases·key_cases·stats_cases 를 쓴다.
// 판정: 저장 키 소속(matchesLawKeys) = 정확 일치 + 같은 조의 하위 항·호 포함, 쉼표·& 분해 없음.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_filter.dart';
import 'package:safetyreport/services/law_values.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/report_filter_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _r(String id, String law) => Report(
  id: id,
  reportNumber: 'SPP-$id',
  name: '합성 법규',
  date: '2026-01-01',
  responseDate: '2026-01-02',
  agency: '합성 기관',
  manager: '담당',
  status: '수용',
  result: '수용',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '',
  law: law,
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vectors =
      jsonDecode(File('contracts/law-search-vectors.json').readAsStringSync())
          as Map;
  for (final c in vectors['canonical_cases'] as List) {
    test('canonical ${c['name']}', () {
      expect(canonicalLaw(c['value'] as String), c['expected']);
    });
  }
  for (final c in vectors['key_cases'] as List) {
    test('key membership ${c['name']}', () {
      expect(matchesLawKeys(c['value'], c['query'] as String), c['expected']);
    });
  }

  test('legacy Client server keeps raw stored values (no law_search_v2)', () {
    const stored = ' 도로교통법 제32조1항\n소음·진동관리법 제21조 ';
    expect(lawLinkValues(stored, keyed: true), [
      '도로교통법 제32조제1항',
      '소음진동관리법 제21조',
    ]);
    expect(lawLinkValues(stored, keyed: false), [
      '도로교통법 제32조1항\n소음·진동관리법 제21조',
    ]);
    expect(lawLinkValues('  ', keyed: false), isEmpty);
    // 구서버와 같은 저장값 완전 일치(앞뒤 공백 무시, __없음__ = 빈 값).
    expect(
      ReportFilterSpec.matchesLaw(
        ' 도로교통법 제32조1항 ',
        '도로교통법 제32조1항',
        legacy: true,
      ),
      isTrue,
    );
    expect(
      ReportFilterSpec.matchesLaw(
        '도로교통법 제32조1항',
        '도로교통법 제32조제1항',
        legacy: true,
      ),
      isFalse,
    );
    expect(ReportFilterSpec.matchesLaw('', '__없음__', legacy: true), isTrue);
    expect(
      ReportFilterSpec.matchesLaw('도로교통법 제32조제1항', '도로교통법 제32조', exact: true),
      isTrue,
    );
    expect(
      ReportFilterSpec.matchesLaw('주차장법 제33조', '도로교통법 제32조, 제33조', exact: true),
      isFalse,
    );
  });

  test('toSearchJson omits lawExact unless set with a law', () {
    expect(
      const ReportFilter(law: 'x').toSearchJson().containsKey('lawExact'),
      isFalse,
    );
    expect(
      const ReportFilter(lawExact: true).toSearchJson().containsKey('lawExact'),
      isFalse,
    );
    expect(
      const ReportFilter(law: 'x', lawExact: true).toSearchJson()['lawExact'],
      isTrue,
    );
    expect(
      const ReportFilter(law: 'x', lawExact: true),
      isNot(const ReportFilter(law: 'x')),
    );
    expect(
      const ReportFilter(
        law: 'x',
        lawExact: true,
      ).without(ReportFilterField.law),
      const ReportFilter(),
    );
  });

  group('local statistics bars equal drilldown', () {
    late Directory dir;
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dir = Directory.systemTemp.createTempSync('sr_law_bar_');
      await databaseFactory.setDatabasesPath(dir.path);
    });
    tearDownAll(() async {
      await LocalDbService.closeDb();
      dir.deleteSync(recursive: true);
    });

    for (final c in vectors['stats_cases'] as List) {
      test(c['name'] as String, () async {
        SharedPreferences.setMockInitialValues({});
        await LocalDbService.closeDb();
        await deleteDatabase(await LocalDbService.getDbPath());
        final values = [
          for (final v in c['values'] as List) (v as String?) ?? '',
        ];
        for (var i = 0; i < values.length; i++) {
          await LocalDbService.upsertReport(
            _r('$i', values[i]),
            'traffic',
            '자동차·교통위반-기타',
          );
        }
        final expected = (c['expected'] as List).cast<Map>();
        final overview = await LocalDbService.computeStatsOverview();
        expect(overview['all']['violation_laws'], expected);
        final rows = [
          for (final v in values) <String, dynamic>{'위반법규': v, '처리상태': '수용'},
        ];
        expect(
          LocalDbService.summarizeOverviewRows(rows)['violation_laws'],
          expected,
        );
        for (final bar in expected) {
          final filter = bar['filter'] as String;
          final count = bar['count'] as int;
          expect(
            values.where((v) => matchesLawKeys(v, filter)).length,
            count,
            reason: filter,
          );
          // 막대 → 목록(lawExact) 드릴다운, 통계 법규 선택 모두 같은 건수.
          final page = await LocalDbService.getReportPage(
            filter: ReportFilter(law: filter, lawExact: true),
          );
          expect(page.total, count, reason: 'list $filter');
          final filtered = await LocalDbService.computeStatsOverview(
            law: filter,
          );
          expect(filtered['all']['total'], count, reason: 'stats $filter');
        }
      });
    }
  });
}
