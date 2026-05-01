import 'report.dart';

enum RatingBatchItemStatus { success, skip, failure }

extension RatingBatchItemStatusX on RatingBatchItemStatus {
  String get value => switch (this) {
    RatingBatchItemStatus.success => 'success',
    RatingBatchItemStatus.skip => 'skip',
    RatingBatchItemStatus.failure => 'failure',
  };

  String get label => switch (this) {
    RatingBatchItemStatus.success => '성공',
    RatingBatchItemStatus.skip => '스킵',
    RatingBatchItemStatus.failure => '실패',
  };

  static RatingBatchItemStatus fromValue(String value) => switch (value) {
    'success' => RatingBatchItemStatus.success,
    'skip' => RatingBatchItemStatus.skip,
    'failure' => RatingBatchItemStatus.failure,
    _ => RatingBatchItemStatus.failure,
  };
}

class RatingBatchItem {
  final String reportNumber;
  final String name;
  final RatingBatchItemStatus status;
  final String message;
  final Map<String, dynamic>? reportData;

  const RatingBatchItem({
    required this.reportNumber,
    required this.name,
    required this.status,
    required this.message,
    this.reportData,
  });

  bool get hasReportData => reportData != null && reportData!.isNotEmpty;

  RatingBatchItem copyWith({
    String? reportNumber,
    String? name,
    RatingBatchItemStatus? status,
    String? message,
    Map<String, dynamic>? reportData,
  }) {
    return RatingBatchItem(
      reportNumber: reportNumber ?? this.reportNumber,
      name: name ?? this.name,
      status: status ?? this.status,
      message: message ?? this.message,
      reportData: reportData ?? this.reportData,
    );
  }

  factory RatingBatchItem.fromJson(Map<String, dynamic> json) {
    return RatingBatchItem(
      reportNumber: json['reportNumber']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      status: RatingBatchItemStatusX.fromValue(
        json['status']?.toString() ?? '',
      ),
      message: json['message']?.toString() ?? '',
      reportData: json['reportData'] is Map
          ? Map<String, dynamic>.from(json['reportData'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'reportNumber': reportNumber,
    'name': name,
    'status': status.value,
    'message': message,
    if (reportData != null) 'reportData': reportData,
  };
}

class RatingBatchResult {
  final String id;
  final String timestamp;
  final String mode;
  final int score;
  final int requestedCount;
  final int eligibleCount;
  final List<RatingBatchItem> items;

  const RatingBatchResult({
    required this.id,
    required this.timestamp,
    required this.mode,
    required this.score,
    required this.requestedCount,
    required this.eligibleCount,
    required this.items,
  });

  int get successCount => items
      .where((item) => item.status == RatingBatchItemStatus.success)
      .length;
  int get skipCount =>
      items.where((item) => item.status == RatingBatchItemStatus.skip).length;
  int get failureCount => items
      .where((item) => item.status == RatingBatchItemStatus.failure)
      .length;

  List<String> get failedReportNumbers => items
      .where(
        (item) =>
            item.status == RatingBatchItemStatus.failure &&
            item.reportNumber.trim().isNotEmpty,
      )
      .map((item) => item.reportNumber)
      .toList(growable: false);

  String get title => '⭐ 별점 ${score}점 처리';
  String get summary => '성공 $successCount건, 스킵 $skipCount건, 실패 $failureCount건';

  RatingBatchResult copyWith({
    String? id,
    String? timestamp,
    String? mode,
    int? score,
    int? requestedCount,
    int? eligibleCount,
    List<RatingBatchItem>? items,
  }) {
    return RatingBatchResult(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      mode: mode ?? this.mode,
      score: score ?? this.score,
      requestedCount: requestedCount ?? this.requestedCount,
      eligibleCount: eligibleCount ?? this.eligibleCount,
      items: items ?? this.items,
    );
  }

  RatingBatchResult enrichWithReports(Map<String, Report> reportsByNumber) {
    return copyWith(
      items: items
          .map((item) {
            final report = reportsByNumber[item.reportNumber];
            if (report == null) return item;
            return item.copyWith(
              name: report.name,
              reportData: reportToMap(report),
            );
          })
          .toList(growable: false),
    );
  }

  factory RatingBatchResult.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as List? ?? const [])
        .map(
          (item) =>
              RatingBatchItem.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
    return RatingBatchResult(
      id: json['id']?.toString() ?? '',
      timestamp: json['timestamp']?.toString() ?? '',
      mode: json['mode']?.toString() ?? 'server',
      score: _toInt(json['score']),
      requestedCount: _toInt(json['requestedCount']),
      eligibleCount: _toInt(json['eligibleCount']),
      items: items,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp,
    'mode': mode,
    'score': score,
    'requestedCount': requestedCount,
    'eligibleCount': eligibleCount,
    'items': items.map((item) => item.toJson()).toList(),
    'successCount': successCount,
    'skipCount': skipCount,
    'failureCount': failureCount,
  };
}

int _toInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

Map<String, dynamic> reportToMap(Report report) {
  return {
    'ID': report.id,
    '신고번호': report.reportNumber,
    '신고명': report.name,
    '신고일': report.date,
    '답변일': report.responseDate,
    '처리기관': report.agency,
    '담당자': report.manager,
    '처리상태': report.status,
    '결과': report.result,
    '범칙금_과태료': report.fineInfo,
    '벌점': report.penaltyPoints,
    '차량번호': report.carNumber,
    '위반법규': report.law,
    '위반장소': report.location,
    '발생일자': report.occurrenceDate,
    '발생시각': report.occurrenceTime,
    '신고내용': report.reportContent,
    '처리내용': report.processContent,
    '첨부사진': report.attachedPhotos,
    '첨부파일': report.attachedFiles,
    '지도': report.mapImage,
    '만족도조사여부': report.pollStatus,
    '종결여부': report.processingFinish,
    '별점': report.rating,
    '별점사유': report.ratingCause,
    'total_count': report.totalCount,
    'valid_count': report.validCount,
  };
}
