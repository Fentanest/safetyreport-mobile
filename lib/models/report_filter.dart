import 'package:flutter/foundation.dart' show listEquals;

const kEmptyLawFilterValue = '__없음__';

class ReportFilter {
  final String name;
  final String reportNumber;
  final String id;
  final List<String> ratings;
  final String ratingCause;
  final String agency;
  final String manager;
  final String carNumber;
  final String law;
  final String location;
  final String fine;
  final String supplementCount;
  final String reportContent;
  final String processContent;
  final List<String> statuses;
  final String reportDateStart;
  final String reportDateEnd;
  final String occurDateStart;
  final String occurDateEnd;
  final String responseDateStart;
  final String responseDateEnd;
  final String occurTimeStart;
  final String occurTimeEnd;
  final bool excludePolice;
  final bool onlyPolice;
  final String pollStatus;

  const ReportFilter({
    this.name = '',
    this.reportNumber = '',
    this.id = '',
    this.ratings = const [],
    this.ratingCause = '',
    this.agency = '',
    this.manager = '',
    this.carNumber = '',
    this.law = '',
    this.location = '',
    this.fine = '',
    this.supplementCount = '',
    this.reportContent = '',
    this.processContent = '',
    this.statuses = const [],
    this.reportDateStart = '',
    this.reportDateEnd = '',
    this.occurDateStart = '',
    this.occurDateEnd = '',
    this.responseDateStart = '',
    this.responseDateEnd = '',
    this.occurTimeStart = '',
    this.occurTimeEnd = '',
    this.excludePolice = false,
    this.onlyPolice = false,
    this.pollStatus = '',
  });

  List<Object> get _values => [
    name,
    reportNumber,
    id,
    ratingCause,
    agency,
    manager,
    carNumber,
    law,
    location,
    fine,
    supplementCount,
    reportContent,
    processContent,
    reportDateStart,
    reportDateEnd,
    occurDateStart,
    occurDateEnd,
    responseDateStart,
    responseDateEnd,
    occurTimeStart,
    occurTimeEnd,
    excludePolice,
    onlyPolice,
    pollStatus,
  ];
  @override
  bool operator ==(Object other) =>
      other is ReportFilter &&
      listEquals(_values, other._values) &&
      listEquals(ratings, other.ratings) &&
      listEquals(statuses, other.statuses);
  @override
  int get hashCode => Object.hash(
    Object.hashAll(_values),
    Object.hashAll(ratings),
    Object.hashAll(statuses),
  );

  ReportFilter copyWith({
    String? name,
    String? reportNumber,
    String? id,
    List<String>? ratings,
    String? ratingCause,
    String? agency,
    String? manager,
    String? carNumber,
    String? law,
    String? location,
    String? fine,
    String? supplementCount,
    String? reportContent,
    String? processContent,
    List<String>? statuses,
    String? reportDateStart,
    String? reportDateEnd,
    String? occurDateStart,
    String? occurDateEnd,
    String? responseDateStart,
    String? responseDateEnd,
    String? occurTimeStart,
    String? occurTimeEnd,
    bool? excludePolice,
    bool? onlyPolice,
    String? pollStatus,
  }) {
    return ReportFilter(
      name: name ?? this.name,
      reportNumber: reportNumber ?? this.reportNumber,
      id: id ?? this.id,
      ratings: ratings ?? this.ratings,
      ratingCause: ratingCause ?? this.ratingCause,
      agency: agency ?? this.agency,
      manager: manager ?? this.manager,
      carNumber: carNumber ?? this.carNumber,
      law: law ?? this.law,
      location: location ?? this.location,
      fine: fine ?? this.fine,
      supplementCount: supplementCount ?? this.supplementCount,
      reportContent: reportContent ?? this.reportContent,
      processContent: processContent ?? this.processContent,
      statuses: statuses ?? this.statuses,
      reportDateStart: reportDateStart ?? this.reportDateStart,
      reportDateEnd: reportDateEnd ?? this.reportDateEnd,
      occurDateStart: occurDateStart ?? this.occurDateStart,
      occurDateEnd: occurDateEnd ?? this.occurDateEnd,
      responseDateStart: responseDateStart ?? this.responseDateStart,
      responseDateEnd: responseDateEnd ?? this.responseDateEnd,
      occurTimeStart: occurTimeStart ?? this.occurTimeStart,
      occurTimeEnd: occurTimeEnd ?? this.occurTimeEnd,
      excludePolice: excludePolice ?? this.excludePolice,
      onlyPolice: onlyPolice ?? this.onlyPolice,
      pollStatus: pollStatus ?? this.pollStatus,
    );
  }

  ReportFilter withoutRatingStateFilters() {
    return copyWith(ratings: const [], ratingCause: '', pollStatus: '');
  }

  bool get isEmpty =>
      name.isEmpty &&
      reportNumber.isEmpty &&
      id.isEmpty &&
      ratings.isEmpty &&
      ratingCause.isEmpty &&
      agency.isEmpty &&
      manager.isEmpty &&
      carNumber.isEmpty &&
      law.isEmpty &&
      location.isEmpty &&
      fine.isEmpty &&
      supplementCount.isEmpty &&
      reportContent.isEmpty &&
      processContent.isEmpty &&
      statuses.isEmpty &&
      reportDateStart.isEmpty &&
      reportDateEnd.isEmpty &&
      occurDateStart.isEmpty &&
      occurDateEnd.isEmpty &&
      responseDateStart.isEmpty &&
      responseDateEnd.isEmpty &&
      occurTimeStart.isEmpty &&
      occurTimeEnd.isEmpty &&
      !excludePolice &&
      !onlyPolice &&
      pollStatus.isEmpty;

  /// 활성 필터 항목 요약 (Chip 표시용)
  List<String> get activeLabels {
    final list = <String>[];
    if (name.isNotEmpty) list.add('신고명: $name');
    if (reportNumber.isNotEmpty) list.add('신고번호: $reportNumber');
    if (id.isNotEmpty) list.add('ID: $id');
    if (ratings.isNotEmpty) {
      list.add(
        '별점: ${ratings.map((rating) => rating == '__none__' ? '없음' : '$rating점').join(', ')}',
      );
    }
    if (ratingCause.isNotEmpty) list.add('별점사유: $ratingCause');
    if (agency.isNotEmpty) list.add('기관: $agency');
    if (manager.isNotEmpty) list.add('담당자: $manager');
    if (carNumber.isNotEmpty) list.add('차량: $carNumber');
    if (law == kEmptyLawFilterValue) {
      list.add('위반법규: 없음');
    } else if (law.isNotEmpty) {
      list.add('위반법규: $law');
    }
    if (location.isNotEmpty) list.add('위반장소: $location');
    if (fine.isNotEmpty) list.add('범칙금/과태료: $fine');
    if (supplementCount.isNotEmpty) list.add('보완횟수: $supplementCount');
    if (reportContent.isNotEmpty) list.add('신고내용: $reportContent');
    if (processContent.isNotEmpty) list.add('처리내용: $processContent');
    if (statuses.isNotEmpty) list.add('상태: ${statuses.join(', ')}');
    if (reportDateStart.isNotEmpty || reportDateEnd.isNotEmpty) {
      list.add('신고일: $reportDateStart~$reportDateEnd');
    }
    if (occurDateStart.isNotEmpty || occurDateEnd.isNotEmpty) {
      list.add('발생일: $occurDateStart~$occurDateEnd');
    }
    if (responseDateStart.isNotEmpty || responseDateEnd.isNotEmpty) {
      list.add('답변일: $responseDateStart~$responseDateEnd');
    }
    if (occurTimeStart.isNotEmpty || occurTimeEnd.isNotEmpty) {
      list.add('발생시각: $occurTimeStart~$occurTimeEnd');
    }
    if (excludePolice) list.add('경찰기관 제외');
    if (onlyPolice) list.add('경찰기관만');
    if (pollStatus.isNotEmpty) list.add('만족도: $pollStatus');
    return list;
  }

  String get rating => ratings.join(',');
  String get status => statuses.join(',');
}
