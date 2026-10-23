import '../community/capture/observation_rules.dart' show parseAmount;
import '../services/plate_normalize.dart';
import 'report.dart';

enum ReportSortField {
  duplicateCount('중복횟수', 'duplicate_count'),
  reportNumber('신고번호', 'report_no'),
  fine('과태료/범칙금', 'fine'),
  rating('별점', 'rating'),
  supplementCount('보완횟수', 'supplement'),
  reportDate('신고일', 'report_date'),
  occurrenceDate('발생일', 'occurrence_date'),
  responseDate('답변일', 'response_date');

  const ReportSortField(this.label, this.column);
  final String label, column;
  bool get date => [reportDate, occurrenceDate, responseDate].contains(this);
}

class ReportSort {
  const ReportSort({
    this.field = ReportSortField.reportNumber,
    this.ascending = false,
  });
  static const defaults = ReportSort();
  final ReportSortField field;
  final bool ascending;
  String get direction => ascending ? 'ASC' : 'DESC';
  String get description => '${field.label} ${ascending ? '↑' : '↓'}';
  String get semantics =>
      '정렬: ${field.label}, ${field.date ? (ascending ? '오래된순' : '최신순') : (ascending ? '오름차순' : '내림차순')}';
  String get stored => '${field.name}:${ascending ? 'asc' : 'desc'}';
  static ReportSort restore(String? value, {bool duplicates = false}) {
    for (final field in ReportSortField.values) {
      if (field == ReportSortField.duplicateCount && !duplicates) continue;
      if (value == '${field.name}:asc' || value == '${field.name}:desc') {
        return ReportSort(field: field, ascending: value!.endsWith(':asc'));
      }
    }
    return defaults;
  }

  String orderBy(String value, {String fallback = 'r.신고번호 DESC, r.ID DESC'}) =>
      '($value IS NULL) ASC, $value $direction, $fallback';
  @override
  bool operator ==(Object other) =>
      other is ReportSort &&
      field == other.field &&
      ascending == other.ascending;
  @override
  int get hashCode => Object.hash(field, ascending);
}

/// 값이 없는 자료는 SQL NULL로 만든다. 추정 과태료는 사용하지 않는다.
String? _sortText(Object? x) {
  final value = x?.toString().trim();
  return value == null || value.isEmpty || ['-', 'null', 'None'].contains(value)
      ? null
      : value;
}

String? _sortDate(Object? x) {
  final value = _sortText(x);
  return value != null && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(value)
      ? value
      : null;
}

int? _sortInt(Object? x) => int.tryParse('${x ?? ''}');

Map<String, Object?> reportSortValues(Map<String, Object?> row) {
  final rating = _sortInt(row['별점']);
  return {
    'sort_id': row['ID'],
    'report_no': _sortText(row['신고번호']),
    'fine': parseAmount(
      row['범칙금_과태료'],
      Map<String, dynamic>.from(row),
    ).confirmedWon,
    'rating': rating != null && rating > 0 ? rating : null,
    'supplement': _sortInt(row['보완횟수']),
    'report_date': _sortDate(row['신고일']),
    'occurrence_date': _sortDate(row['발생일자']),
    'response_date': _sortDate(row['답변일']),
  };
}

/// Client 전체 목록을 임시 SQLite에 담을 때 필요한 카드 값. 상세는 기존 경로로 다시 읽는다.
Map<String, Object?> reportCardRow(Report r) => {
  'ID': r.id,
  '신고번호': r.reportNumber,
  '신고명': r.name,
  '신고일': r.date,
  '답변일': r.responseDate,
  '발생일자': r.occurrenceDate,
  '발생시각': r.occurrenceTime,
  '처리기관': r.agency,
  '처리기관코드': r.agencyCode,
  '담당자': r.manager,
  '처리상태': r.status,
  '상태': r.result,
  '범칙금_과태료': r.fineInfo,
  '벌점': r.penaltyPoints,
  '차량번호': r.carNumber,
  '위반법규': r.law,
  '위반장소': r.location,
  '만족도조사여부': r.pollStatus,
  '종결여부': r.processingFinish,
  '별점': r.rating,
  '별점사유': r.ratingCause,
  'category': r.category,
  'entry_value': r.entryValue,
  'ssnpc_cd': r.ssnpcCd,
  'ssnpc_type': r.ssnpcType,
  '사진_첫촬영': r.photoFirstCapture,
  '사진_끝촬영': r.photoLastCapture,
  'synced_at': r.syncedAt,
  '보완횟수': r.supplementCountKnown ? r.supplementCount : null,
  '보완_미응답': r.supplementOpen ? 'Y' : 'N',
  '보완_요청자': r.supplementRequester,
  '보완_요청일시': r.supplementRequestedAt,
  '보완_완료일시': r.supplementCompletedAt,
  'total_count': r.totalCount,
  'valid_count': r.validCount,
  Report.detailOmittedKey: true,
};

/// Client 중복 목록은 이미 전체 자료를 보유하므로 묶음을 유지해 정렬한다.
List<Report> sortDuplicateReports(
  List<Report> reports,
  ReportSort sort, {
  List<Report>? allReports,
}) {
  final groups = <String, List<Report>>{};
  final values = <Report, Object?>{};
  for (final r in reports) {
    (groups[normalizePlateGroupKey(r.carNumber)] ??= []).add(r);
    values[r] = switch (sort.field) {
      ReportSortField.reportNumber => _sortText(r.reportNumber),
      ReportSortField.fine => parseAmount(
        r.fineInfo,
        Map<String, dynamic>.from(reportCardRow(r)),
      ).confirmedWon,
      ReportSortField.rating => (r.rating ?? 0) > 0 ? r.rating : null,
      ReportSortField.supplementCount =>
        r.supplementCountKnown ? r.supplementCount : null,
      ReportSortField.reportDate => _sortDate(r.date),
      ReportSortField.occurrenceDate => _sortDate(r.occurrenceDate),
      ReportSortField.responseDate => _sortDate(r.responseDate),
      ReportSortField.duplicateCount => null,
    };
  }
  int compare(Object? a, Object? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    final result = a is int && b is int ? a.compareTo(b) : '$a'.compareTo('$b');
    return sort.ascending ? result : -result;
  }

  int fallback(Report a, Report b) {
    final n = b.reportNumber.compareTo(a.reportNumber);
    return n != 0 ? n : b.id.compareTo(a.id);
  }

  final representative = <String, Object?>{};
  final defaultNo = <String, String>{};
  final fullCounts = <String, int>{};
  for (final r in allReports ?? reports) {
    final key = normalizePlateGroupKey(r.carNumber);
    fullCounts[key] = (fullCounts[key] ?? 0) + 1;
    if (defaultNo[key] == null ||
        r.reportNumber.compareTo(defaultNo[key]!) > 0) {
      defaultNo[key] = r.reportNumber;
    }
  }
  for (final entry in groups.entries) {
    entry.value.sort((a, b) {
      final n = compare(values[a], values[b]);
      return n != 0 ? n : fallback(a, b);
    });
    representative[entry.key] = sort.field == ReportSortField.duplicateCount
        ? (entry.value.first.totalCount > 0
              ? entry.value.first.totalCount
              : fullCounts[entry.key])
        : values[entry.value.first];
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      final n = compare(representative[a], representative[b]);
      if (n != 0) return n;
      final fallback = defaultNo[b]!.compareTo(defaultNo[a]!);
      return fallback != 0 ? fallback : a.compareTo(b);
    });
  return [for (final key in keys) ...groups[key]!];
}
