import '../models/report_filter.dart';

/// Parameterized conditions for the existing local list filter. SQLite handles
/// counts and pages before any Report is constructed. Agency expression uses a
/// revision/registry scoped TEMP lookup prepared by LocalDbService.
class ReportQuery {
  final clauses = <String>[];
  final args = <Object?>[];
  String get where => clauses.isEmpty ? '1=1' : clauses.join(' AND ');
  ReportQuery(ReportFilter f, {required String agencyExpression}) {
    void text(String column, String query) {
      if (query.trim().isEmpty) return;
      final groups = <String>[];
      for (final g in query.trim().split(',')) {
        final terms = g
            .split('&')
            .map((s) => s.trim().toLowerCase())
            .where((s) => s.isNotEmpty);
        final expressions = <String>[];
        for (final term in terms) {
          expressions.add('instr(lower(IFNULL($column,\'\')), ?) > 0');
          args.add(term);
        }
        if (expressions.isNotEmpty) {
          groups.add('(${expressions.join(' AND ')})');
        }
      }
      clauses.add(groups.isEmpty ? '0=1' : '(${groups.join(' OR ')})');
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
    if (f.law == kEmptyLawFilterValue) {
      clauses.add("trim(IFNULL(위반법규,'')) = ''");
    } else if (f.law.isNotEmpty) {
      clauses.add('trim(IFNULL(위반법규,\'\')) = ?');
      args.add(f.law);
    }
    if (f.statuses.isNotEmpty) {
      clauses.add(
        "(CASE WHEN trim(IFNULL(처리상태,'')) IN ('진행','진행중','검토중','처리중') THEN '처리중' ELSE trim(IFNULL(처리상태,'')) END) IN (${List.filled(f.statuses.length, '?').join(',')})",
      );
      args.addAll(f.statuses);
    }
    for (final item in [
      ('신고일', f.reportDateStart, f.reportDateEnd),
      ('발생일자', f.occurDateStart, f.occurDateEnd),
      ('답변일', f.responseDateStart, f.responseDateEnd),
      ('발생시각', f.occurTimeStart, f.occurTimeEnd),
    ]) {
      for (final bound in [(item.$2, '>='), (item.$3, '<=')]) {
        if (bound.$1.isNotEmpty) {
          clauses.add(
            "(IFNULL(${item.$1},'') = '' OR ${item.$1} ${bound.$2} ?)",
          );
          args.add(bound.$1);
        }
      }
    }
    if (f.excludePolice) clauses.add("instr($agencyExpression,'경찰') = 0");
    if (f.onlyPolice) clauses.add("instr($agencyExpression,'경찰') > 0");
    if (f.pollStatus.isNotEmpty) {
      clauses.add("trim(IFNULL(만족도조사여부,'')) = ?");
      args.add(f.pollStatus);
    }
  }
}
