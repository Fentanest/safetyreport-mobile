import 'package:flutter/foundation.dart' show listEquals;

const kEmptyLawFilterValue = '__없음__';

class ReportFilter {
  final String name;
  final String reportNumber;
  final String id;
  final List<String> ratings;
  final String ratingCause;
  final String agency;
  final String agencyKey;
  final String manager;
  final bool managerExact;
  final String carNumber;
  final String law;

  /// 저장 키 소속 판정(통계 막대·통계 법규 선택·상세 법규 링크). true 면 [law] 를 저장 키 그대로 보고
  /// 쉼표·& 로 나누지 않으며 하위 항·호를 포함한다(`matchesLawKeys`, 서버 `matches_law_keys`).
  /// false 면 검색 의미(`matchesLaws`). Client 모드는 서버가 `law_search_v2` 를 알릴 때만 보낸다.
  final bool lawExact;
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
    this.agencyKey = '',
    this.manager = '',
    this.managerExact = false,
    this.carNumber = '',
    this.law = '',
    this.lawExact = false,
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

  /// Version 1 Client search wire format; also the in-flight query identity.
  Map<String, Object> toSearchJson() => {
    'name': name,
    'reportNumber': reportNumber,
    'id': id,
    'ratings': ratings,
    'ratingCause': ratingCause,
    if (agencyKey.isEmpty) 'agency': agency,
    if (agencyKey.isNotEmpty) 'agencyKey': agencyKey,
    'manager': manager,
    if (managerExact) 'managerExact': true,
    'carNumber': carNumber,
    'law': law,
    // 2026-10-16 하위호환 추가: false 일 때는 보내지 않아 예전 v1 요청과 바이트가 같다.
    if (lawExact && law.isNotEmpty) 'lawExact': true,
    'location': location,
    'fine': fine,
    'supplementCount': supplementCount,
    'reportContent': reportContent,
    'processContent': processContent,
    'statuses': statuses,
    'reportDateStart': reportDateStart,
    'reportDateEnd': reportDateEnd,
    'occurDateStart': occurDateStart,
    'occurDateEnd': occurDateEnd,
    'responseDateStart': responseDateStart,
    'responseDateEnd': responseDateEnd,
    'occurTimeStart': occurTimeStart,
    'occurTimeEnd': occurTimeEnd,
    'excludePolice': excludePolice,
    'onlyPolice': onlyPolice,
    'pollStatus': pollStatus,
  };

  List<Object> get _values => [
    name,
    reportNumber,
    id,
    ratingCause,
    agency,
    agencyKey,
    manager,
    managerExact,
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
    lawExact && law.isNotEmpty,
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
    String? agencyKey,
    String? manager,
    bool? managerExact,
    String? carNumber,
    String? law,
    bool? lawExact,
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
      agencyKey: agencyKey ?? this.agencyKey,
      manager: manager ?? this.manager,
      managerExact: managerExact ?? this.managerExact,
      carNumber: carNumber ?? this.carNumber,
      law: law ?? this.law,
      lawExact: lawExact ?? this.lawExact,
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
      agencyKey.isEmpty &&
      !managerExact &&
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
  List<String> get activeLabels =>
      activeConditions.map((c) => c.label).toList(growable: false);

  /// 활성 조건 하나하나(칩 표시와 개별 해제용, SQ-U16). 순서는 [activeLabels] 와 같다.
  List<ReportFilterCondition> get activeConditions {
    final list = <ReportFilterCondition>[];
    void add(ReportFilterField field, String label) =>
        list.add(ReportFilterCondition(field, label));
    if (name.isNotEmpty) add(ReportFilterField.name, '신고명: $name');
    if (reportNumber.isNotEmpty) {
      add(ReportFilterField.reportNumber, '신고번호: $reportNumber');
    }
    if (id.isNotEmpty) add(ReportFilterField.id, 'ID: $id');
    if (ratings.isNotEmpty) {
      add(
        ReportFilterField.ratings,
        '별점: ${ratings.map((rating) => rating == '__none__' ? '없음' : '$rating점').join(', ')}',
      );
    }
    if (ratingCause.isNotEmpty) {
      add(ReportFilterField.ratingCause, '별점사유: $ratingCause');
    }
    if (agency.isNotEmpty) add(ReportFilterField.agency, '기관: $agency');
    if (manager.isNotEmpty) add(ReportFilterField.manager, '담당자: $manager');
    if (carNumber.isNotEmpty) {
      add(ReportFilterField.carNumber, '차량: $carNumber');
    }
    if (law == kEmptyLawFilterValue) {
      add(ReportFilterField.law, '위반법규: 없음');
    } else if (law.isNotEmpty) {
      add(ReportFilterField.law, '위반법규: $law');
    }
    if (location.isNotEmpty) {
      add(ReportFilterField.location, '위반장소: $location');
    }
    if (fine.isNotEmpty) add(ReportFilterField.fine, '범칙금/과태료: $fine');
    if (supplementCount.isNotEmpty) {
      add(ReportFilterField.supplementCount, '보완횟수: $supplementCount');
    }
    if (reportContent.isNotEmpty) {
      add(ReportFilterField.reportContent, '신고내용: $reportContent');
    }
    if (processContent.isNotEmpty) {
      add(ReportFilterField.processContent, '처리내용: $processContent');
    }
    if (statuses.isNotEmpty) {
      add(ReportFilterField.statuses, '상태: ${statuses.join(', ')}');
    }
    if (reportDateStart.isNotEmpty || reportDateEnd.isNotEmpty) {
      add(ReportFilterField.reportDate, '신고일: $reportDateStart~$reportDateEnd');
    }
    if (occurDateStart.isNotEmpty || occurDateEnd.isNotEmpty) {
      add(ReportFilterField.occurDate, '발생일: $occurDateStart~$occurDateEnd');
    }
    if (responseDateStart.isNotEmpty || responseDateEnd.isNotEmpty) {
      add(
        ReportFilterField.responseDate,
        '답변일: $responseDateStart~$responseDateEnd',
      );
    }
    if (occurTimeStart.isNotEmpty || occurTimeEnd.isNotEmpty) {
      add(ReportFilterField.occurTime, '발생시각: $occurTimeStart~$occurTimeEnd');
    }
    if (excludePolice) add(ReportFilterField.excludePolice, '경찰기관 제외');
    if (onlyPolice) add(ReportFilterField.onlyPolice, '경찰기관만');
    if (pollStatus.isNotEmpty) {
      add(ReportFilterField.pollStatus, '만족도: $pollStatus');
    }
    return list;
  }

  /// [field] 조건 하나만 비운 필터(나머지 조건은 그대로, SQ-U16 칩 ×).
  ReportFilter without(ReportFilterField field) => switch (field) {
    ReportFilterField.name => copyWith(name: ''),
    ReportFilterField.reportNumber => copyWith(reportNumber: ''),
    ReportFilterField.id => copyWith(id: ''),
    ReportFilterField.ratings => copyWith(ratings: const []),
    ReportFilterField.ratingCause => copyWith(ratingCause: ''),
    ReportFilterField.agency => copyWith(agency: '', agencyKey: ''),
    ReportFilterField.manager => copyWith(manager: '', managerExact: false),
    ReportFilterField.carNumber => copyWith(carNumber: ''),
    ReportFilterField.law => copyWith(law: '', lawExact: false),
    ReportFilterField.location => copyWith(location: ''),
    ReportFilterField.fine => copyWith(fine: ''),
    ReportFilterField.supplementCount => copyWith(supplementCount: ''),
    ReportFilterField.reportContent => copyWith(reportContent: ''),
    ReportFilterField.processContent => copyWith(processContent: ''),
    ReportFilterField.statuses => copyWith(statuses: const []),
    ReportFilterField.reportDate => copyWith(
      reportDateStart: '',
      reportDateEnd: '',
    ),
    ReportFilterField.occurDate => copyWith(
      occurDateStart: '',
      occurDateEnd: '',
    ),
    ReportFilterField.responseDate => copyWith(
      responseDateStart: '',
      responseDateEnd: '',
    ),
    ReportFilterField.occurTime => copyWith(
      occurTimeStart: '',
      occurTimeEnd: '',
    ),
    ReportFilterField.excludePolice => copyWith(excludePolice: false),
    ReportFilterField.onlyPolice => copyWith(onlyPolice: false),
    ReportFilterField.pollStatus => copyWith(pollStatus: ''),
  };

  String get rating => ratings.join(',');
  String get status => statuses.join(',');
}

/// 칩 하나가 나타내는 필터 조건(날짜·시각 범위는 시작~끝을 한 조건으로 본다).
enum ReportFilterField {
  name,
  reportNumber,
  id,
  ratings,
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
  statuses,
  reportDate,
  occurDate,
  responseDate,
  occurTime,
  excludePolice,
  onlyPolice,
  pollStatus,
}

class ReportFilterCondition {
  const ReportFilterCondition(this.field, this.label);

  final ReportFilterField field;
  final String label;
}
