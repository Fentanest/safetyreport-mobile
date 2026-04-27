class AgencyStatRow {
  final String agency;
  final String person;
  final int total;
  final double? avgResponseDays;
  final int fines;
  final double finesPct;
  final int warnings;
  final double warningsPct;
  final int rejects;
  final double rejectsPct;
  final int totalFineAmount;
  final double? avgRating;     // 별점 평균 (1~5, 표본 없으면 null)
  final int ratingCount;       // 별점 표본 수

  const AgencyStatRow({
    required this.agency,
    required this.person,
    required this.total,
    this.avgResponseDays,
    required this.fines,
    required this.finesPct,
    required this.warnings,
    required this.warningsPct,
    required this.rejects,
    required this.rejectsPct,
    this.totalFineAmount = 0,
    this.avgRating,
    this.ratingCount = 0,
  });

  factory AgencyStatRow.fromJson(Map<String, dynamic> json) {
    return AgencyStatRow(
      agency: json['agency']?.toString() ?? '',
      person: json['person']?.toString() ?? '',
      total: (json['total'] as num?)?.toInt() ?? 0,
      avgResponseDays: (json['avg_days'] as num?)?.toDouble(),
      fines: (json['fines'] as num?)?.toInt() ?? 0,
      finesPct: (json['fines_pct'] as num?)?.toDouble() ?? 0.0,
      warnings: (json['warnings'] as num?)?.toInt() ?? 0,
      warningsPct: (json['warnings_pct'] as num?)?.toDouble() ?? 0.0,
      rejects: (json['rejects'] as num?)?.toInt() ?? 0,
      rejectsPct: (json['rejects_pct'] as num?)?.toDouble() ?? 0.0,
      totalFineAmount: (json['total_fine_amount'] as num?)?.toInt() ?? 0,
      avgRating: (json['avg_rating'] as num?)?.toDouble(),
      ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
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

  const CategoryStats({
    required this.byAgency,
    required this.byPerson,
    required this.policeByAgency,
    required this.policeByPerson,
    required this.otherByAgency,
    required this.otherByPerson,
    this.availableLaws = const [],
    this.hasEmptyLaw = false,
  });

  static List<AgencyStatRow> _parse(Map<String, dynamic> json, String key) =>
      (json[key] as List? ?? [])
          .map((i) => AgencyStatRow.fromJson(i as Map<String, dynamic>))
          .toList();

  factory CategoryStats.fromJson(Map<String, dynamic> json) {
    return CategoryStats(
      byAgency:      _parse(json, 'by_agency'),
      byPerson:      _parse(json, 'by_person'),
      policeByAgency: _parse(json, 'police_by_agency'),
      policeByPerson: _parse(json, 'police_by_person'),
      otherByAgency:  _parse(json, 'other_by_agency'),
      otherByPerson:  _parse(json, 'other_by_person'),
      availableLaws: (json['available_laws'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      hasEmptyLaw: json['has_empty_law'] as bool? ?? false,
    );
  }
}

class AgencyStats {
  final CategoryStats traffic;
  final CategoryStats parking;
  final CategoryStats other;
  final List<String> availableYears;

  const AgencyStats({
    required this.traffic,
    required this.parking,
    required this.other,
    required this.availableYears,
  });

  factory AgencyStats.fromJson(Map<String, dynamic> json) {
    return AgencyStats(
      traffic: CategoryStats.fromJson(
          (json['traffic'] as Map<String, dynamic>?) ?? {}),
      parking: CategoryStats.fromJson(
          (json['parking'] as Map<String, dynamic>?) ?? {}),
      other: CategoryStats.fromJson(
          (json['other'] as Map<String, dynamic>?) ?? {}),
      availableYears: (json['available_years'] as List? ?? [])
          .map((y) => y.toString())
          .toList(),
    );
  }
}
