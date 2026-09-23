/// 통계 화면 요약 카드 + 월별 추이.
///
/// Client: 서버 `GET /api/v1/stats/overview` (서버 `report_stats_service.get_stats_overview`).
/// Standalone: `LocalDbService.computeStatsOverview`. 두 쪽 정의는 `docs/design/statistics-spec.md` §4 와 같다.
class MonthlyCount {
  final String month; // YYYY-MM
  final int count;

  const MonthlyCount(this.month, this.count);

  factory MonthlyCount.fromJson(Map<String, dynamic> json) => MonthlyCount(
    json['month']?.toString() ?? '',
    (json['count'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {'month': month, 'count': count};
}

class OverviewSummary {
  final int total;
  final int completed;
  final int accept;
  final int partial;
  final int reject;
  final int supplement;
  final int processing;
  final int withdraw;

  /// 평균 처리일: 신고일·답변일이 모두 유효하고 차이가 0 이상인 신고만의 평균(소수 1자리). 표본 0 이면 null.
  final double? avgDays;

  /// 평균 처리일 표본 수.
  final int avgDaysCount;

  /// 답변일이 신고일보다 앞서 평균에서 뺀 건수.
  final int reversedDateCount;

  /// 신고일을 읽을 수 없어 월별 신고 추이에서 빠진 건수.
  final int undatedReportCount;
  final List<MonthlyCount> monthlyReported;
  final List<MonthlyCount> monthlyAnswered;

  const OverviewSummary({
    required this.total,
    required this.completed,
    required this.accept,
    required this.partial,
    required this.reject,
    required this.supplement,
    required this.processing,
    required this.withdraw,
    required this.avgDays,
    required this.avgDaysCount,
    required this.reversedDateCount,
    required this.undatedReportCount,
    required this.monthlyReported,
    required this.monthlyAnswered,
  });

  static const empty = OverviewSummary(
    total: 0,
    completed: 0,
    accept: 0,
    partial: 0,
    reject: 0,
    supplement: 0,
    processing: 0,
    withdraw: 0,
    avgDays: null,
    avgDaysCount: 0,
    reversedDateCount: 0,
    undatedReportCount: 0,
    monthlyReported: [],
    monthlyAnswered: [],
  );

  static int _int(dynamic v) => (v as num?)?.toInt() ?? 0;

  static List<MonthlyCount> _months(dynamic v) => (v as List? ?? const [])
      .whereType<Map>()
      .map((e) => MonthlyCount.fromJson(Map<String, dynamic>.from(e)))
      .toList(growable: false);

  factory OverviewSummary.fromJson(Map<String, dynamic>? json) {
    if (json == null) return empty;
    return OverviewSummary(
      total: _int(json['total']),
      completed: _int(json['completed']),
      accept: _int(json['accept']),
      partial: _int(json['partial']),
      reject: _int(json['reject']),
      supplement: _int(json['supplement']),
      processing: _int(json['processing']),
      withdraw: _int(json['withdraw']),
      avgDays: (json['avg_days'] as num?)?.toDouble(),
      avgDaysCount: _int(json['avg_days_count']),
      reversedDateCount: _int(json['reversed_date_count']),
      undatedReportCount: _int(json['undated_report_count']),
      monthlyReported: _months(json['monthly_reported']),
      monthlyAnswered: _months(json['monthly_answered']),
    );
  }

  Map<String, dynamic> toJson() => {
    'total': total,
    'completed': completed,
    'accept': accept,
    'partial': partial,
    'reject': reject,
    'supplement': supplement,
    'processing': processing,
    'withdraw': withdraw,
    'avg_days': avgDays,
    'avg_days_count': avgDaysCount,
    'reversed_date_count': reversedDateCount,
    'undated_report_count': undatedReportCount,
    'monthly_reported': monthlyReported.map((e) => e.toJson()).toList(),
    'monthly_answered': monthlyAnswered.map((e) => e.toJson()).toList(),
  };
}

class StatsOverview {
  final OverviewSummary all;
  final OverviewSummary traffic;
  final OverviewSummary parking;
  final OverviewSummary other;

  /// 연도 필터 기준 컬럼. S-08 결정으로 두 모드 모두 '답변일'.
  final String yearBasis;

  /// 취하 데이터 숨기기 설정 적용 여부(대시보드 '전체'는 취하 포함이라 통계 총계와 다를 수 있음).
  final bool excludeWithdraw;

  const StatsOverview({
    required this.all,
    required this.traffic,
    required this.parking,
    required this.other,
    required this.yearBasis,
    this.excludeWithdraw = false,
  });

  OverviewSummary forCategory(String category) {
    switch (category) {
      case 'traffic':
        return traffic;
      case 'parking':
        return parking;
      case 'other':
        return other;
      default:
        return all;
    }
  }

  factory StatsOverview.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? section(String key) {
      final value = json[key];
      return value is Map ? Map<String, dynamic>.from(value) : null;
    }

    return StatsOverview(
      all: OverviewSummary.fromJson(section('all')),
      traffic: OverviewSummary.fromJson(section('traffic')),
      parking: OverviewSummary.fromJson(section('parking')),
      other: OverviewSummary.fromJson(section('other')),
      yearBasis: json['year_basis']?.toString() ?? '',
      excludeWithdraw: json['exclude_withdraw'] == true,
    );
  }
}
