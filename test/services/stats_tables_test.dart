import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/agency_stats.dart';
import 'package:safetyreport/services/local_db_service.dart';

/// 서버 `tests/test_report_stats_service.py::test_stats_tables_include_assigned_in_progress_rows`
/// 와 같은 입력·기대값(S-10). 서버는 법규별 표도 만들지만 모바일에는 없어 기관/담당자만 비교한다.
const _rows = <Map<String, dynamic>>[
  {
    '처리기관': 'A구청',
    '담당자': '김',
    '처리상태': '수용',
    '범칙금_과태료': '과태료: 40,000원',
    '신고일': '2026-01-01',
    '답변일': '2026-01-11',
  },
  {
    '처리기관': 'A구청',
    '담당자': '김',
    '처리상태': '처리중',
    '범칙금_과태료': '',
    '신고일': '2026-01-05',
    '답변일': '2026-01-06',
  },
  {
    '처리기관': ' A구청 ',
    '담당자': '',
    '처리상태': '진행',
    '범칙금_과태료': null,
    '신고일': '2026-01-07',
    '답변일': null,
  },
  {
    '처리기관': 'A구청',
    '담당자': '미지정',
    '처리상태': '답변완료',
    '범칙금_과태료': '',
    '신고일': '2026-01-01',
    '답변일': '2026-01-05',
  },
  {
    '처리기관': 'A구청',
    '담당자': '이',
    '처리상태': '취하',
    '범칙금_과태료': '',
    '신고일': '2026-01-01',
    '답변일': '2026-01-02',
  },
  {
    '처리기관': '',
    '담당자': '',
    '처리상태': '처리중',
    '범칙금_과태료': '',
    '신고일': '2026-01-08',
    '답변일': '',
  },
  {
    '처리기관': null,
    '담당자': null,
    '처리상태': null,
    '범칙금_과태료': null,
    '신고일': null,
    '답변일': null,
  },
  {
    '처리기관': 'B경찰서',
    '담당자': '박',
    '처리상태': '보완요청',
    '범칙금_과태료': '',
    '신고일': '2026-02-01',
    '답변일': '',
  },
];

void main() {
  test('S-10: 기관·담당자 값으로 표에 넣고, 배정된 처리중은 in_progress 로 센다', () {
    final result = LocalDbService.buildStatsCategory(_rows, _rows, false);
    final agency = {
      for (final r
          in (result['by_agency'] as List).cast<Map<String, dynamic>>())
        r['agency'] as String: r,
    };
    final person = {
      for (final r
          in (result['by_person'] as List).cast<Map<String, dynamic>>())
        '${r['agency']}/${r['person']}': r,
    };

    // 기관이 비어 있으면 어느 표에도 넣지 않는다.
    expect(agency.keys.toSet(), {'A구청', 'B경찰서'});
    final a = agency['A구청']!;
    expect(a['total'], 5);
    expect(a['fines'], 1);
    expect(a['in_progress'], 2); // 처리중 + 진행(담당자 없어도 기관표에는 들어간다)
    expect(a['unconfirmed'], 2); // 답변완료(처분 없음) + 취하
    expect(a['in_progress_pct'], 40.0);
    expect(a['avg_days'], 7.0); // 완료 신고만: 10일, 4일
    expect(agency['B경찰서']!['in_progress'], 1); // 보완요청도 처리중

    // 담당자표는 기관과 담당자가 모두 있어야 한다('미지정'·빈 값 제외).
    expect(person.keys.toSet(), {'A구청/김', 'A구청/이', 'B경찰서/박'});
    expect(person['A구청/김']!['total'], 2);
    expect(person['A구청/김']!['in_progress'], 1);
    expect(person['A구청/김']!['avg_days'], 10.0);
  });

  test('S-10: 요약 평균 처리기간은 완료 신고만', () {
    final summary = LocalDbService.summarizeOverviewRows(const [
      {'처리상태': '수용', '신고일': '2026-01-01', '답변일': '2026-01-11'},
      {'처리상태': '처리중', '신고일': '2026-01-01', '답변일': '2026-01-02'},
      {'처리상태': '취하', '신고일': '2026-01-01', '답변일': '2026-01-03'},
    ]);
    expect(summary['avg_days_count'], 1);
    expect(summary['avg_days'], 10.0);
    expect(summary['monthly_answered'], [
      {'month': '2026-01', 'count': 3},
    ]);
  });

  test('구서버 응답(in_progress 없음)은 null 로 읽어 처리중 표시를 숨긴다', () {
    final old = AgencyStatRow.fromJson({
      'agency': 'A',
      'total': 3,
      'unconfirmed': 1,
    });
    expect(old.inProgress, isNull);
    final now = AgencyStatRow.fromJson({
      'agency': 'A',
      'total': 3,
      'in_progress': 2,
      'in_progress_pct': 66.7,
    });
    expect(now.inProgress, 2);
    expect(now.inProgressPct, 66.7);
  });
}
