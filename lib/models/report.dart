/// JSON 값을 int?로 안전하게 변환.
/// 서버는 NaN을 빈 문자열('')로 직렬화할 수 있어 `as num?` 직접 캐스팅이 실패함.
int? _toIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  if (v is String) {
    if (v.trim().isEmpty) return null;
    return int.tryParse(v) ?? double.tryParse(v)?.toInt();
  }
  return null;
}

class Report {
  final String id;
  final String reportNumber;
  final String name;
  final String date;
  final String responseDate;
  final String agency;
  final String manager;
  final String status; // 처리상태
  final String result; // 상태 (C_NOW)
  final String fineInfo;
  final String penaltyPoints;
  final String carNumber;
  final String law;
  final String location;
  final String occurrenceDate;
  final String occurrenceTime;
  final String reportContent;
  final String processContent;
  final String attachedPhotos;
  final String attachedFiles;
  final String mapImage;
  final String pollStatus; // 만족도조사여부
  final String processingFinish; // 종결여부 (Y/N)
  final int? rating; // 별점 (1~5, null=미부여)
  final String ratingCause; // 별점사유 (불만족 텍스트, 없으면 '')
  final int totalCount;
  final int validCount;
  final String
  category; // 'traffic' | 'parking' | 'other' | '' (서버 응답에서 카테고리를 모를 때 빈 값)
  final int? syncedAt; // 마지막 실제 반영 시각 (epoch millis)
  final int supplementCount; // 누적 보완요청 횟수 (없으면 0)
  final bool supplementOpen; // 마지막 round 가 아직 미응답인지 (Y → true)
  final String supplementRequest; // 마지막 round 요청 내용 (요청자/연락처/일시 prefix 포함)
  final String supplementOpinion; // 마지막 round 의 신고자 보완 의견

  Report({
    required this.id,
    required this.reportNumber,
    required this.name,
    required this.date,
    required this.responseDate,
    required this.agency,
    required this.manager,
    required this.status,
    required this.result,
    required this.fineInfo,
    required this.penaltyPoints,
    required this.carNumber,
    required this.law,
    required this.location,
    required this.occurrenceDate,
    required this.occurrenceTime,
    required this.reportContent,
    required this.processContent,
    this.attachedPhotos = '',
    this.attachedFiles = '',
    this.mapImage = '',
    this.pollStatus = '답변 대기',
    this.processingFinish = 'N',
    this.rating,
    this.ratingCause = '',
    this.totalCount = 0,
    this.validCount = 0,
    this.category = '',
    this.syncedAt,
    this.supplementCount = 0,
    this.supplementOpen = false,
    this.supplementRequest = '',
    this.supplementOpinion = '',
  });

  String get statusWithFine {
    final statusText = status.trim();
    final fineText = fineInfo.trim();
    if (statusText.isEmpty) return fineText;
    if (fineText.isEmpty) return statusText;
    return '$statusText · $fineText';
  }

  factory Report.fromJson(Map<String, dynamic> json) {
    return Report(
      id: json['ID']?.toString() ?? '',
      reportNumber: json['신고번호']?.toString() ?? '',
      name: json['신고명']?.toString() ?? '',
      date: json['신고일']?.toString() ?? '',
      responseDate: json['답변일']?.toString() ?? '',
      agency: json['처리기관']?.toString() ?? '',
      manager: json['담당자']?.toString() ?? '',
      status: (json['처리상태'] ?? json['상태'])?.toString() ?? '',
      result: json['결과']?.toString() ?? '',
      fineInfo: json['범칙금_과태료']?.toString() ?? '',
      penaltyPoints: json['벌점']?.toString() ?? '',
      carNumber: json['차량번호']?.toString() ?? '',
      law: json['위반법규']?.toString() ?? '',
      location: json['위반장소']?.toString() ?? '',
      occurrenceDate: json['발생일자']?.toString() ?? '',
      occurrenceTime: json['발생시각']?.toString() ?? '',
      reportContent: json['신고내용']?.toString() ?? '',
      processContent: json['처리내용']?.toString() ?? '',
      attachedPhotos: json['첨부사진']?.toString() ?? '',
      attachedFiles: json['첨부파일']?.toString() ?? '',
      mapImage: json['지도']?.toString() ?? '',
      pollStatus: json['만족도조사여부']?.toString() ?? '답변 대기',
      processingFinish: json['종결여부']?.toString() ?? 'N',
      rating: _toIntOrNull(json['별점']),
      ratingCause: json['별점사유']?.toString() ?? '',
      totalCount: _toIntOrNull(json['total_count']) ?? 0,
      validCount: _toIntOrNull(json['valid_count']) ?? 0,
      category: json['category']?.toString() ?? '',
      syncedAt: _toIntOrNull(json['synced_at']),
      supplementCount: _toIntOrNull(json['보완횟수']) ?? 0,
      supplementOpen: (json['보완_미응답']?.toString() ?? 'N') == 'Y',
      supplementRequest: json['보완_요청_내용']?.toString() ?? '',
      supplementOpinion: json['보완_신고자_의견']?.toString() ?? '',
    );
  }
}

class DashboardStats {
  final String lastCrawlTime;
  final int total;
  final int acceptCount;
  final int partialCount;
  final int rejectCount;
  final int processingCount;
  final int completedCount;
  final int withdrawCount;
  final int tFineCount;
  final int tPenaltyCount;
  final int tRejectCount;
  final int tUnconfirmedCount;
  final List<Report> recentAnswers;
  final List<Report> watchlist;

  DashboardStats({
    required this.lastCrawlTime,
    required this.total,
    required this.acceptCount,
    required this.partialCount,
    required this.rejectCount,
    required this.processingCount,
    required this.completedCount,
    required this.withdrawCount,
    required this.tFineCount,
    required this.tPenaltyCount,
    required this.tRejectCount,
    required this.tUnconfirmedCount,
    required this.recentAnswers,
    required this.watchlist,
  });

  factory DashboardStats.fromJson(Map<String, dynamic> json) {
    var recentList = json['recent_answers'] as List? ?? [];
    var watchList = json['watchlist'] as List? ?? [];
    return DashboardStats(
      lastCrawlTime: json['last_crawl_time']?.toString() ?? '',
      total: _toIntOrNull(json['total']) ?? 0,
      acceptCount: _toIntOrNull(json['acceptCount']) ?? 0,
      partialCount: _toIntOrNull(json['partialCount']) ?? 0,
      rejectCount: _toIntOrNull(json['rejectCount']) ?? 0,
      processingCount: _toIntOrNull(json['processingCount']) ?? 0,
      completedCount: _toIntOrNull(json['completedCount']) ?? 0,
      withdrawCount: _toIntOrNull(json['withdrawCount']) ?? 0,
      tFineCount: _toIntOrNull(json['tFineCount']) ?? 0,
      tPenaltyCount: _toIntOrNull(json['tPenaltyCount']) ?? 0,
      tRejectCount: _toIntOrNull(json['tRejectCount']) ?? 0,
      tUnconfirmedCount: _toIntOrNull(json['tUnconfirmedCount']) ?? 0,
      recentAnswers: recentList
          .map((i) => Report.fromJson(i as Map<String, dynamic>))
          .toList(),
      watchlist: watchList
          .map((i) => Report.fromJson(i as Map<String, dynamic>))
          .toList(),
    );
  }
}
