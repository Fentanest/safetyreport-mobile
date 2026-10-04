import '../models/report_filter.dart';
import 'report_filter_spec.dart';
import 'report_policy.dart';

/// Parameterized conditions for the existing local list filter. SQLite handles
/// counts and pages before any Report is constructed. Agency expression uses a
/// revision/registry scoped TEMP lookup prepared by LocalDbService.
/// 조건의 의미는 [ReportFilterSpec](서버·웹과 같은 contracts/report-filter-vectors.json).
class ReportQuery {
  final clauses = <String>[];
  final args = <Object?>[];
  String get where => clauses.isEmpty ? '1=1' : clauses.join(' AND ');
  ReportQuery(ReportFilter f, {required String agencyExpression}) {
    void text(String column, String query) {
      final clause = ReportFilterSpec.sqlText(column, query, args);
      if (clause != null) clauses.add(clause);
    }

    for (final pair in [
      ('신고명', f.name),
      ('신고번호', f.reportNumber),
      ('ID', f.id),
      ('별점사유', f.ratingCause),
      (agencyExpression, f.agency),
      ('담당자', f.manager),
      ('차량번호', f.carNumber),
      ('위반장소', f.location),
      ('범칙금_과태료', f.fine),
      ('CAST(IFNULL(보완횟수,0) AS TEXT)', f.supplementCount),
      ('신고내용', f.reportContent),
      ('처리내용', f.processContent),
    ]) {
      text(pair.$1, pair.$2);
    }
    if (f.ratings.isNotEmpty) {
      clauses.add(
        "(CASE WHEN 별점 IS NULL OR 별점 <= 0 THEN '__none__' ELSE CAST(별점 AS TEXT) END) IN (${List.filled(f.ratings.length, '?').join(',')})",
      );
      args.addAll(f.ratings);
    }
    final law = ReportFilterSpec.sqlLaw('위반법규', f.law, args);
    if (law != null) clauses.add(law);
    if (f.statuses.isNotEmpty) {
      final status = ReportPolicy.sqlNorm('처리상태');
      final processing = ReportPolicy.sqlIn(
        status,
        ReportPolicy.processingOrder,
      );
      clauses.add(
        "(CASE WHEN $processing THEN '${ReportPolicy.processingLabel}' ELSE $status END) IN (${List.filled(f.statuses.length, '?').join(',')})",
      );
      args.addAll(f.statuses);
    }
    for (final item in [
      ('신고일', f.reportDateStart, f.reportDateEnd, false),
      ('발생일자', f.occurDateStart, f.occurDateEnd, false),
      ('답변일', f.responseDateStart, f.responseDateEnd, false),
      ('발생시각', f.occurTimeStart, f.occurTimeEnd, true),
    ]) {
      final range = ReportFilterSpec.sqlRange(
        item.$1,
        item.$2,
        item.$3,
        args,
        time: item.$4,
      );
      if (range != null) clauses.add(range);
    }
    if (f.excludePolice) clauses.add("instr($agencyExpression,'경찰') = 0");
    if (f.onlyPolice) clauses.add("instr($agencyExpression,'경찰') > 0");
    if (f.pollStatus.isNotEmpty) {
      clauses.add("trim(IFNULL(만족도조사여부,'')) = ?");
      args.add(f.pollStatus);
    }
  }
}
