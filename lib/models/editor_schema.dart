class EditorSchema {
  final List<String> titleFields;
  final List<String> detailFields;
  final String fineInfoExample;

  const EditorSchema({
    required this.titleFields,
    required this.detailFields,
    required this.fineInfoExample,
  });

  static const defaultTitleFields = <String>[
    '상태',
    '신고번호',
    '신고명',
    '신고일',
    '만족도조사여부',
    '감시목록',
  ];

  static const defaultDetailFields = <String>[
    '처리상태',
    '차량번호',
    '위반법규',
    '범칙금_과태료',
    '벌점',
    '처리기관',
    '담당자',
    '답변일',
    '발생일자',
    '발생시각',
    '위반장소',
    '종결여부',
    '신고내용',
    '처리내용',
    '지도',
    '첨부사진',
    '첨부파일',
  ];

  static const defaultFineInfoExample =
      '예: 과태료: 40,000원 / 범칙금: 30,000원 / 경고 / 미확인';

  factory EditorSchema.fromJson(Map<String, dynamic> json) {
    List<String> asStringList(dynamic value, List<String> fallback) {
      final list = value as List?;
      if (list == null) return fallback;
      final normalized = list
          .map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList();
      return normalized.isEmpty ? fallback : normalized;
    }

    return EditorSchema(
      titleFields: asStringList(json['title_fields'], defaultTitleFields),
      detailFields: asStringList(json['detail_fields'], defaultDetailFields),
      fineInfoExample:
          json['fine_info_example']?.toString().trim().isNotEmpty == true
          ? json['fine_info_example'].toString().trim()
          : defaultFineInfoExample,
    );
  }

  factory EditorSchema.fallback() => const EditorSchema(
    titleFields: defaultTitleFields,
    detailFields: defaultDetailFields,
    fineInfoExample: defaultFineInfoExample,
  );
}
