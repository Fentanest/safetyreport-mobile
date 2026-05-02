class SunwiItem {
  final int rank;
  final String sido;
  final String sigungu;
  final int count;
  final String region;

  const SunwiItem({
    required this.rank,
    required this.sido,
    required this.sigungu,
    required this.count,
    required this.region,
  });

  factory SunwiItem.fromJson(Map<String, dynamic> json) {
    return SunwiItem(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      sido: json['sido']?.toString() ?? '',
      sigungu: json['sigungu']?.toString() ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      region: json['region']?.toString() ?? '',
    );
  }
}

class SunwiChildCategory {
  final String name;
  final String fullName;
  final List<SunwiItem> items;

  const SunwiChildCategory({
    required this.name,
    required this.fullName,
    required this.items,
  });

  factory SunwiChildCategory.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => SunwiItem.fromJson(item.cast<String, dynamic>()))
        .toList();
    return SunwiChildCategory(
      name: json['name']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      items: items,
    );
  }
}

class SunwiParentCategory {
  final String name;
  final List<SunwiChildCategory> children;

  const SunwiParentCategory({required this.name, required this.children});

  factory SunwiParentCategory.fromJson(Map<String, dynamic> json) {
    final children = (json['children'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (child) => SunwiChildCategory.fromJson(child.cast<String, dynamic>()),
        )
        .toList();
    return SunwiParentCategory(
      name: json['name']?.toString() ?? '',
      children: children,
    );
  }
}

class SunwiPayload {
  final bool available;
  final String period;
  final String periodLabel;
  final String updatedAt;
  final List<SunwiParentCategory> categories;
  final String error;
  final int failedCount;
  final String csvDownloadUrl;
  final String allCsvDownloadUrl;

  const SunwiPayload({
    required this.available,
    required this.period,
    required this.periodLabel,
    required this.updatedAt,
    required this.categories,
    required this.error,
    required this.failedCount,
    required this.csvDownloadUrl,
    required this.allCsvDownloadUrl,
  });

  factory SunwiPayload.fromJson(Map<String, dynamic> json) {
    final categories = (json['categories'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (group) =>
              SunwiParentCategory.fromJson(group.cast<String, dynamic>()),
        )
        .toList();
    return SunwiPayload(
      available: json['available'] == true,
      period: json['period']?.toString() ?? '',
      periodLabel: json['period_label']?.toString() ?? '',
      updatedAt: json['updated_at']?.toString() ?? '',
      categories: categories,
      error: json['error']?.toString() ?? '',
      failedCount: (json['failed_count'] as num?)?.toInt() ?? 0,
      csvDownloadUrl: json['csv_download_url']?.toString() ?? '',
      allCsvDownloadUrl: json['all_csv_download_url']?.toString() ?? '',
    );
  }
}
