import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/agency_stats.dart';
import 'package:safetyreport/services/local_db_service.dart';

/// 서버 `tests/test_report_stats_service.py::test_stats_tables_include_only_answered_rows`
/// 와 같은 입력·기대값(2026-09-28: 표는 답변 완료 신고만 — S-10 대체). 서버는 법규별 표도 만들지만 모바일에는 없어 기관/담당자만 비교한다.
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
  test('카테고리 과태료 합계는 기관 미지정 신고도 포함하고 추정액은 분리한다', () {
    final rows = <Map<String, dynamic>>[
      {'처리기관': 'A구청', '담당자': '김', '처리상태': '수용', '범칙금_과태료': '과태료: 40,000원'},
      {'처리기관': '', '담당자': '', '처리상태': '수용', '범칙금_과태료': '과태료: 20,000원'},
    ];
    final category = LocalDbService.buildStatsCategory(rows, rows);
    final agency = (category['by_agency'] as List)
        .cast<Map<String, dynamic>>()
        .single;
    expect(category['total_fine_amount'], 60000);
    expect(agency['total_fine_amount'], 40000);
    expect(category['estimated_fine_amount'], 0);
    expect(category['estimated_fine_count'], 0);
  });

  test('표는 답변 완료 신고만: 처리중·보완요청·취하는 기관·담당자가 있어도 넣지 않는다', () {
    final result = LocalDbService.buildStatsCategory(_rows, _rows);
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

    // B경찰서는 보완요청 1건뿐이라 표에 없다. 기관이 빈 신고도 없다.
    expect(agency.keys.toSet(), {'A구청'});
    final a = agency['A구청']!;
    expect(a['total'], 2); // 수용 + 답변완료(담당자 미지정)
    expect(a['fines'], 1);
    expect(a['in_progress'], 0);
    expect(a['unconfirmed'], 1); // 답변완료(처분 없음)
    expect(a['disposition_unknown'], 0);
    expect(a['no_penalty'], 1);
    expect(a['unclassified'], 0);
    expect(a['estimated_fine_amount'], 0);
    expect(a['estimated_fine_count'], 0);
    expect(a['avg_days'], 7.0); // 10일, 4일
    expect(a['avg_days_count'], 2);

    // 담당자표: 기관·담당자가 있고('미지정' 제외) 답변 완료 — 취하 '이' 는 빠진다.
    expect(person.keys.toSet(), {'A구청/김'});
    expect(person['A구청/김']!['total'], 1);
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
