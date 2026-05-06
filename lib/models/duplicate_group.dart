import 'report.dart';

class DuplicateStatuses {
  static const reviewRequired = 'review_required';
  static const confirmedDuplicate = 'confirmed_duplicate';
  static const notDuplicate = 'not_duplicate';

  static String labelOf(String value) {
    switch (value) {
      case confirmedDuplicate:
        return '중복 확정';
      case notDuplicate:
        return '중복 아님';
      default:
        return '검토 필요';
    }
  }
}

class RepresentativeModes {
  static const auto = 'auto';
  static const manual = 'manual';

  static String labelOf(String value) {
    return value == manual ? '수동 고정' : '자동 선정';
  }
}

class DuplicateMember {
  final String groupId;
  final String reportId;
  final String reportNumber;
  final String category;
  final String entryValue;
  final bool isRepresentative;
  final bool rawMatch;
  final bool fieldMatch;
  final Report report;

  const DuplicateMember({
    required this.groupId,
    required this.reportId,
    required this.reportNumber,
    required this.category,
    required this.entryValue,
    required this.isRepresentative,
    required this.rawMatch,
    required this.fieldMatch,
    required this.report,
  });

  factory DuplicateMember.fromJson(Map<String, dynamic> json) {
    final normalized = Map<String, dynamic>.from(json);
    final reportData = Map<String, dynamic>.from(normalized);
    if ((reportData['category']?.toString().trim() ?? '').isEmpty) {
      reportData['category'] = normalized['category']?.toString() ?? '';
    }
    return DuplicateMember(
      groupId: normalized['group_id']?.toString() ?? '',
      reportId:
          normalized['report_id']?.toString() ??
          normalized['ID']?.toString() ??
          '',
      reportNumber:
          normalized['report_number']?.toString() ??
          normalized['신고번호']?.toString() ??
          '',
      category: normalized['category']?.toString() ?? '',
      entryValue:
          normalized['entry_value']?.toString() ??
          normalized['신고메뉴']?.toString() ??
          '',
      isRepresentative:
          normalized['is_representative'] == 1 ||
          normalized['is_representative'] == true,
      rawMatch:
          normalized['raw_match'] == 1 || normalized['raw_match'] == true,
      fieldMatch:
          normalized['field_match'] == 1 || normalized['field_match'] == true,
      report: Report.fromJson(reportData),
    );
  }

  Map<String, dynamic> toJson() => {
    'group_id': groupId,
    'report_id': reportId,
    'report_number': reportNumber,
    'category': category,
    'entry_value': entryValue,
    'is_representative': isRepresentative ? 1 : 0,
    'raw_match': rawMatch ? 1 : 0,
    'field_match': fieldMatch ? 1 : 0,
    ...{
      'ID': report.id,
      '신고번호': report.reportNumber,
      '신고명': report.name,
      '신고일': report.date,
      '답변일': report.responseDate,
      '처리기관': report.agency,
      '담당자': report.manager,
      '처리상태': report.status,
      '상태': report.result,
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
      'category': report.category,
    },
  };
}

class DuplicateGroup {
  final String groupId;
  final String status;
  final String representativeMode;
  final String representativeId;
  final int memberCount;
  final String note;
  final List<DuplicateMember> members;
  final DuplicateMember? representative;

  const DuplicateGroup({
    required this.groupId,
    required this.status,
    required this.representativeMode,
    required this.representativeId,
    required this.memberCount,
    required this.note,
    required this.members,
    required this.representative,
  });

  String get statusLabel => DuplicateStatuses.labelOf(status);
  String get representativeModeLabel =>
      RepresentativeModes.labelOf(representativeMode);

  factory DuplicateGroup.fromJson(Map<String, dynamic> json) {
    final members =
        (json['members'] as List? ?? const [])
            .map((item) => DuplicateMember.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
    DuplicateMember? representative;
    final representativeJson = json['representative'];
    if (representativeJson is Map) {
      representative = DuplicateMember.fromJson(
        Map<String, dynamic>.from(representativeJson),
      );
    } else {
      representative = members.cast<DuplicateMember?>().firstWhere(
        (member) => member?.isRepresentative == true,
        orElse: () => null,
      );
    }
    return DuplicateGroup(
      groupId: json['group_id']?.toString() ?? '',
      status: json['status']?.toString() ?? DuplicateStatuses.reviewRequired,
      representativeMode:
          json['representative_mode']?.toString() ?? RepresentativeModes.auto,
      representativeId: json['representative_id']?.toString() ?? '',
      memberCount:
          int.tryParse(json['member_count']?.toString() ?? '') ??
          members.length,
      note: json['note']?.toString() ?? '',
      members: members,
      representative: representative,
    );
  }

  Map<String, dynamic> toJson() => {
    'group_id': groupId,
    'status': status,
    'representative_mode': representativeMode,
    'representative_id': representativeId,
    'member_count': memberCount,
    'note': note,
    'members': members.map((member) => member.toJson()).toList(),
    'representative': representative?.toJson(),
  };
}
