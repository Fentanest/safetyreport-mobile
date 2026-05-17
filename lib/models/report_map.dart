int? _toIntOrNull(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  if (value is String) {
    if (value.trim().isEmpty) return null;
    return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  }
  return null;
}

double? _toDoubleOrNull(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) {
    if (value.trim().isEmpty) return null;
    return double.tryParse(value);
  }
  return null;
}

class ReportMapBreakdownItem {
  final String label;
  final int count;
  final double pct;

  const ReportMapBreakdownItem({
    required this.label,
    required this.count,
    required this.pct,
  });

  factory ReportMapBreakdownItem.fromJson(Map<String, dynamic> json) {
    return ReportMapBreakdownItem(
      label: json['label']?.toString() ?? '',
      count: _toIntOrNull(json['count']) ?? 0,
      pct: _toDoubleOrNull(json['pct']) ?? 0,
    );
  }
}

class ReportMapAgencyItem {
  final String name;
  final int count;
  final double pct;

  const ReportMapAgencyItem({
    required this.name,
    required this.count,
    required this.pct,
  });

  factory ReportMapAgencyItem.fromJson(Map<String, dynamic> json) {
    return ReportMapAgencyItem(
      name: json['name']?.toString() ?? '',
      count: _toIntOrNull(json['count']) ?? 0,
      pct: _toDoubleOrNull(json['pct']) ?? 0,
    );
  }
}

class ReportMapPoint {
  final double lat;
  final double lng;
  final String address;
  final String region;
  final int total;
  final List<ReportMapBreakdownItem> statusBreakdown;
  final List<ReportMapBreakdownItem> dispositionBreakdown;
  final List<ReportMapAgencyItem> agencyBreakdown;
  final List<ReportMapBreakdownItem> categoryBreakdown;

  const ReportMapPoint({
    required this.lat,
    required this.lng,
    required this.address,
    required this.region,
    required this.total,
    required this.statusBreakdown,
    required this.dispositionBreakdown,
    required this.agencyBreakdown,
    required this.categoryBreakdown,
  });

  factory ReportMapPoint.fromJson(Map<String, dynamic> json) {
    final statusList = json['status_breakdown'] as List? ?? const [];
    final dispositionList = json['disposition_breakdown'] as List? ?? const [];
    final agencyList = json['agency_breakdown'] as List? ?? const [];
    final categoryList = json['category_breakdown'] as List? ?? const [];

    return ReportMapPoint(
      lat: _toDoubleOrNull(json['lat']) ?? 0,
      lng: _toDoubleOrNull(json['lng']) ?? 0,
      address: json['address']?.toString() ?? '',
      region: json['region']?.toString() ?? '',
      total: _toIntOrNull(json['total']) ?? 0,
      statusBreakdown: statusList
          .whereType<Map>()
          .map(
            (item) => ReportMapBreakdownItem.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList(),
      dispositionBreakdown: dispositionList
          .whereType<Map>()
          .map(
            (item) => ReportMapBreakdownItem.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList(),
      agencyBreakdown: agencyList
          .whereType<Map>()
          .map(
            (item) =>
                ReportMapAgencyItem.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      categoryBreakdown: categoryList
          .whereType<Map>()
          .map(
            (item) => ReportMapBreakdownItem.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList(),
    );
  }
}

class ReportMapMeta {
  final List<String> availableYears;
  final String currentYear;
  final String selectedCategory;
  final String dedupeMode;
  final int totalReports;
  final int geocodedReports;
  final int missingReports;
  final int addressGroups;
  final int agencyCount;

  const ReportMapMeta({
    required this.availableYears,
    required this.currentYear,
    required this.selectedCategory,
    required this.dedupeMode,
    required this.totalReports,
    required this.geocodedReports,
    required this.missingReports,
    required this.addressGroups,
    required this.agencyCount,
  });

  factory ReportMapMeta.fromJson(Map<String, dynamic> json) {
    final years = json['available_years'] as List? ?? const [];
    return ReportMapMeta(
      availableYears: years.map((item) => item.toString()).toList(),
      currentYear: json['current_year']?.toString() ?? 'all',
      selectedCategory: json['selected_category']?.toString() ?? 'all',
      dedupeMode: json['dedupe_mode']?.toString() ?? 'raw',
      totalReports: _toIntOrNull(json['total_reports']) ?? 0,
      geocodedReports: _toIntOrNull(json['geocoded_reports']) ?? 0,
      missingReports: _toIntOrNull(json['missing_reports']) ?? 0,
      addressGroups: _toIntOrNull(json['address_groups']) ?? 0,
      agencyCount: _toIntOrNull(json['agency_count']) ?? 0,
    );
  }
}

class ReportMapPayload {
  final List<ReportMapPoint> points;
  final ReportMapMeta meta;

  const ReportMapPayload({required this.points, required this.meta});

  factory ReportMapPayload.fromJson(Map<String, dynamic> json) {
    final pointList = json['points'] as List? ?? const [];
    final metaJson = json['meta'] is Map
        ? Map<String, dynamic>.from(json['meta'] as Map)
        : const <String, dynamic>{};
    return ReportMapPayload(
      points: pointList
          .whereType<Map>()
          .map(
            (item) => ReportMapPoint.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      meta: ReportMapMeta.fromJson(metaJson),
    );
  }
}

class GeocodeBackfillProgress {
  final String state;
  final bool running;
  final int total;
  final int processed;
  final int updated;
  final int notFound;
  final int remainingMissing;
  final double progressPct;
  final String errorMessage;
  final int startedAt;
  final int finishedAt;
  final bool hasSavedCoordinates;

  const GeocodeBackfillProgress({
    required this.state,
    required this.running,
    required this.total,
    required this.processed,
    required this.updated,
    required this.notFound,
    required this.remainingMissing,
    required this.progressPct,
    required this.errorMessage,
    required this.startedAt,
    required this.finishedAt,
    required this.hasSavedCoordinates,
  });

  bool get isCompleted => state == 'completed';
  bool get isError => state == 'error';
  bool get requiresConfiguration =>
      state == 'config_required' || state == 'config_warning';
  bool get isWarning => state == 'config_warning';

  factory GeocodeBackfillProgress.fromJson(Map<String, dynamic> json) {
    return GeocodeBackfillProgress(
      state: json['state']?.toString() ?? 'idle',
      running: json['running'] == true,
      total: _toIntOrNull(json['total']) ?? 0,
      processed: _toIntOrNull(json['processed']) ?? 0,
      updated: _toIntOrNull(json['updated']) ?? 0,
      notFound: _toIntOrNull(json['not_found']) ?? 0,
      remainingMissing: _toIntOrNull(json['remaining_missing']) ?? 0,
      progressPct: _toDoubleOrNull(json['progress_pct']) ?? 0,
      errorMessage: json['error_message']?.toString() ?? '',
      startedAt: _toIntOrNull(json['started_at']) ?? 0,
      finishedAt: _toIntOrNull(json['finished_at']) ?? 0,
      hasSavedCoordinates: json['has_saved_coordinates'] == true,
    );
  }
}
