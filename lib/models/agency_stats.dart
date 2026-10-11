int? _toIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  if (v is String) {
    if (v.trim().isEmpty) return null;
    return int.tryParse(v) ?? double.tryParse(v)?.toInt();
  }
  return null;
}

double? _toDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) {
    if (v.trim().isEmpty) return null;
    return double.tryParse(v);
  }
  return null;
}

class AgencyStatRow {
  final String agency;
  final String person;
  final int total;
  final double? avgResponseDays;

  /// 평균 처리기간 표본 수(완료 신고 중 두 날짜가 유효한 건, 2026-09-28). 구서버는 null.
  final int? avgDaysCount;
  final int fines;
  final double finesPct;
  final int warnings;
  final double warningsPct;
  final int rejects;
  final double rejectsPct;
  final int unconfirmed;
  final double unconfirmedPct;

  final int? dispositionUnknown;
  final double? dispositionUnknownPct;
  final int? noPenalty;
  final double? noPenaltyPct;
  final int? unclassified;
  final double? unclassifiedPct;

  /// 배정된 처리중 신고 수(S-10). 구서버 응답에는 없어서 null — 이때는 처리중이 unconfirmed 에 섞여 있다.
  final int? inProgress;
  final double? inProgressPct;
  final int totalFineAmount;

  /// 과태료 처분인데 금액을 읽지 못한 건수(S-05). 구서버 응답에는 없어서 0.
  final int fineAmountUnknown;

  final int? estimatedFineAmount;
  final int? estimatedFineCount;

  final double? avgRating; // 별점 평균 (1~5, 표본 없으면 null)
  final int ratingCount; // 별점 표본 수

  const AgencyStatRow({
    required this.agency,
    required this.person,
    required this.total,
    this.avgResponseDays,
    this.avgDaysCount,
    required this.fines,
    required this.finesPct,
    required this.warnings,
    required this.warningsPct,
    required this.rejects,
    required this.rejectsPct,
    required this.unconfirmed,
    required this.unconfirmedPct,
    this.dispositionUnknown,
    this.dispositionUnknownPct,
    this.noPenalty,
    this.noPenaltyPct,
    this.unclassified,
    this.unclassifiedPct,
    this.inProgress,
    this.inProgressPct,
    this.totalFineAmount = 0,
    this.fineAmountUnknown = 0,
    this.estimatedFineAmount,
    this.estimatedFineCount,
    this.avgRating,
    this.ratingCount = 0,
  });

  factory AgencyStatRow.fromJson(Map<String, dynamic> json) {
    return AgencyStatRow(
      agency: json['agency']?.toString() ?? '',
      person: json['person']?.toString() ?? '',
      total: _toIntOrNull(json['total']) ?? 0,
      avgResponseDays: _toDoubleOrNull(json['avg_days']),
      avgDaysCount: _toIntOrNull(json['avg_days_count']),
      fines: _toIntOrNull(json['fines']) ?? 0,
      finesPct: _toDoubleOrNull(json['fines_pct']) ?? 0.0,
      warnings: _toIntOrNull(json['warnings']) ?? 0,
      warningsPct: _toDoubleOrNull(json['warnings_pct']) ?? 0.0,
      rejects: _toIntOrNull(json['rejects']) ?? 0,
      rejectsPct: _toDoubleOrNull(json['rejects_pct']) ?? 0.0,
      unconfirmed: _toIntOrNull(json['unconfirmed']) ?? 0,
      unconfirmedPct: _toDoubleOrNull(json['unconfirmed_pct']) ?? 0.0,
      dispositionUnknown: _toIntOrNull(json['disposition_unknown']),
      dispositionUnknownPct: _toDoubleOrNull(json['disposition_unknown_pct']),
      noPenalty: _toIntOrNull(json['no_penalty']),
      noPenaltyPct: _toDoubleOrNull(json['no_penalty_pct']),
      unclassified: _toIntOrNull(json['unclassified']),
      unclassifiedPct: _toDoubleOrNull(json['unclassified_pct']),
      inProgress: _toIntOrNull(json['in_progress']),
      inProgressPct: _toDoubleOrNull(json['in_progress_pct']),
      totalFineAmount: _toIntOrNull(json['total_fine_amount']) ?? 0,
      fineAmountUnknown: _toIntOrNull(json['fine_amount_unknown']) ?? 0,
      estimatedFineAmount: _toIntOrNull(json['estimated_fine_amount']),
      estimatedFineCount: _toIntOrNull(json['estimated_fine_count']),
      avgRating: _toDoubleOrNull(json['avg_rating']),
      ratingCount: _toIntOrNull(json['rating_count']) ?? 0,
    );
  }
}

class CategoryStats {
  final List<AgencyStatRow> byAgency;
  final List<AgencyStatRow> byPerson;
  final List<AgencyStatRow> policeByAgency;
  final List<AgencyStatRow> policeByPerson;
  final List<AgencyStatRow> otherByAgency;
  final List<AgencyStatRow> otherByPerson;
  final List<String> availableLaws;
  final bool hasEmptyLaw;
  final int totalFineAmount;
  final int? estimatedFineAmount;
  final int? estimatedFineCount;

  const CategoryStats({
    required this.byAgency,
    required this.byPerson,
    required this.policeByAgency,
    required this.policeByPerson,
    required this.otherByAgency,
    required this.otherByPerson,
    this.availableLaws = const [],
    this.hasEmptyLaw = false,
    this.totalFineAmount = 0,
    this.estimatedFineAmount,
    this.estimatedFineCount,
  });

  static List<AgencyStatRow> _parse(Map<String, dynamic> json, String key) =>
      (json[key] as List? ?? [])
          .map((i) => AgencyStatRow.fromJson(i as Map<String, dynamic>))
          .toList();

  factory CategoryStats.fromJson(Map<String, dynamic> json) {
    return CategoryStats(
      byAgency: _parse(json, 'by_agency'),
      byPerson: _parse(json, 'by_person'),
      policeByAgency: _parse(json, 'police_by_agency'),
      policeByPerson: _parse(json, 'police_by_person'),
      otherByAgency: _parse(json, 'other_by_agency'),
      otherByPerson: _parse(json, 'other_by_person'),
      availableLaws: (json['available_laws'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      hasEmptyLaw: json['has_empty_law'] as bool? ?? false,
      totalFineAmount: _toIntOrNull(json['total_fine_amount']) ?? 0,
      estimatedFineAmount: _toIntOrNull(json['estimated_fine_amount']),
      estimatedFineCount: _toIntOrNull(json['estimated_fine_count']),
    );
  }
}

class AgencyStats {
  final CategoryStats traffic;
  final CategoryStats parking;

  /// 안전신고·생활불편(5분류, 2026-10-11). 구서버(3분류) 응답에는 키가 없어 null —
  /// 이때는 other 에 안전신고·생활불편·기타가 모두 접혀 있다(서버 report_category.legacy_category 와 같음).
  final CategoryStats? safety;
  final CategoryStats? living;
  final CategoryStats other;
  final List<String> availableYears;

  const AgencyStats({
    required this.traffic,
    required this.parking,
    this.safety,
    this.living,
    required this.other,
    required this.availableYears,
  });

  /// 서버가 5분류(safety·living)를 보냈는지. false 면 구서버 응답(3분류).
  bool get hasFiveCategories => safety != null && living != null;

  CategoryStats forCategory(String category) {
    switch (category) {
      case 'traffic':
        return traffic;
      case 'parking':
        return parking;
      case 'safety':
        return safety ?? const CategoryStats(
          byAgency: [], byPerson: [], policeByAgency: [], policeByPerson: [],
          otherByAgency: [], otherByPerson: [],
        );
      case 'living':
        return living ?? const CategoryStats(
          byAgency: [], byPerson: [], policeByAgency: [], policeByPerson: [],
          otherByAgency: [], otherByPerson: [],
        );
      default:
        return other;
    }
  }

  factory AgencyStats.fromJson(Map<String, dynamic> json) {
    return AgencyStats(
      traffic: CategoryStats.fromJson(
        (json['traffic'] as Map<String, dynamic>?) ?? {},
      ),
      parking: CategoryStats.fromJson(
        (json['parking'] as Map<String, dynamic>?) ?? {},
      ),
      safety: json['safety'] is Map
          ? CategoryStats.fromJson(json['safety'] as Map<String, dynamic>)
          : null,
      living: json['living'] is Map
          ? CategoryStats.fromJson(json['living'] as Map<String, dynamic>)
          : null,
      other: CategoryStats.fromJson(
        (json['other'] as Map<String, dynamic>?) ?? {},
      ),
      availableYears: (json['available_years'] as List? ?? [])
          .map((y) => y.toString())
          .toList(),
    );
  }
}
