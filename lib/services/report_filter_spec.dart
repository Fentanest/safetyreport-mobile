import 'report_policy.dart';

/// 신고 목록 필터의 의미(EO R-02). 서버 `services/report_filter_spec.py`·웹 `list-predicates.js` 와 같고,
/// `contracts/report-filter-vectors.json`(두 레포 바이트 동일)으로 함께 검사한다.
///
/// - 검색어: ','(OR) 로 나누고 각 묶음을 '&'(AND) 로 나눈다. 앞뒤 공백을 떼고 빈 항목은 버린다.
///   남는 항목이 없으면 조건이 없는 것과 같다. 대소문자는 무시한다(SQL 은 SQLite lower() 라 ASCII 만).
/// - 날짜 범위: 값의 앞 10자리(YYYY-MM-DD, 뒤는 끝·공백·T)가 실제 날짜일 때만 비교한다. 끝 날짜는 그날 전체.
///   시각 범위: 앞 HH:MM(00~23:00~59). 형식이 맞지 않거나 비어 있으면 범위 조건이 있을 때 제외한다.
/// - 법규: 앞뒤 공백을 뗀 완전 일치. '__없음__' 은 빈 법규.
class ReportFilterSpec {
  ReportFilterSpec._();

  static const emptyLaw = '__없음__';
  static final _date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:$|[ T])');
  static final _time = RegExp(r'^(\d{2}):(\d{2})(?::\d{2})?');

  static List<List<String>> parseGroups(String query) => [
    for (final raw in query.split(','))
      [
        for (final term in raw.split('&'))
          if (ReportPolicy.norm(term).isNotEmpty)
            ReportPolicy.norm(term).toLowerCase(),
      ],
  ].where((group) => group.isNotEmpty).toList();

  static bool matchesGroups(Object? value, List<List<String>> groups) {
    if (groups.isEmpty) return true;
    final haystack = ReportPolicy.norm(value).toLowerCase();
    return groups.any((group) => group.every(haystack.contains));
  }

  static bool matchesText(Object? value, String query) =>
      matchesGroups(value, parseGroups(query));

  static bool _validDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return day <= (month == 2 && leap ? 29 : days[month - 1]);
  }

  /// 비교용 앞자리. 형식이 맞지 않으면 null.
  static String? rangeKey(Object? value, {required bool time}) {
    final text = value?.toString() ?? '';
    if (time) {
      final m = _time.firstMatch(text);
      if (m == null ||
          int.parse(m.group(1)!) > 23 ||
          int.parse(m.group(2)!) > 59) {
        return null;
      }
      return '${m.group(1)}:${m.group(2)}';
    }
    final m = _date.firstMatch(text);
    if (m == null ||
        !_validDate(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
        )) {
      return null;
    }
    return text.substring(0, 10);
  }

  static bool inRange(
    Object? value,
    String start,
    String end, {
    required bool time,
  }) {
    if (start.isEmpty && end.isEmpty) return true;
    final key = rangeKey(value, time: time);
    if (key == null) return false;
    return (start.isEmpty || start.compareTo(key) <= 0) &&
        (end.isEmpty || key.compareTo(end) <= 0);
  }

  static bool matchesLaw(Object? value, String law) {
    if (law.isEmpty) return true;
    final text = ReportPolicy.norm(value);
    return law == emptyLaw ? text.isEmpty : text == ReportPolicy.norm(law);
  }

  // ── SQL(SQLite) ─────────────────────────────────────────────────────

  /// [rangeKey] 와 같은 값을 SQL 로: 형식이 맞으면 앞자리, 아니면 NULL.
  static String sqlRangeKey(String column, {required bool time}) {
    if (time) {
      return "(CASE WHEN substr($column,1,5) GLOB '[0-9][0-9]:[0-9][0-9]' "
          "AND substr($column,1,2) <= '23' AND substr($column,4,2) <= '59' "
          'THEN substr($column,1,5) END)';
    }
    // date() 는 없는 날짜(2월 30일 등)를 다음 달로 넘기므로 되돌린 값과 같은지로 확인한다.
    return "(CASE WHEN substr($column,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
        "AND (length($column) = 10 OR substr($column,11,1) IN (' ','T')) "
        'AND date(substr($column,1,10)) = substr($column,1,10) '
        'THEN substr($column,1,10) END)';
  }

  /// 범위 조건 SQL. 조건이 없으면 null.
  static String? sqlRange(
    String column,
    String start,
    String end,
    List<Object?> args, {
    required bool time,
  }) {
    if (start.isEmpty && end.isEmpty) return null;
    final key = sqlRangeKey(column, time: time);
    final parts = <String>[];
    if (start.isNotEmpty) {
      parts.add('$key >= ?');
      args.add(start);
    }
    if (end.isNotEmpty) {
      parts.add('$key <= ?');
      args.add(end);
    }
    return '(${parts.join(' AND ')})';
  }

  /// 검색어 SQL. 묶음이 없으면 null(조건 없음).
  static String? sqlText(String column, String query, List<Object?> args) {
    final groups = parseGroups(query);
    if (groups.isEmpty) return null;
    final ors = <String>[];
    for (final group in groups) {
      final ands = <String>[];
      for (final term in group) {
        ands.add("instr(lower(IFNULL($column,'')), ?) > 0");
        args.add(term);
      }
      ors.add('(${ands.join(' AND ')})');
    }
    return '(${ors.join(' OR ')})';
  }

  static String? sqlLaw(String column, String law, List<Object?> args) {
    if (law.isEmpty) return null;
    if (law == emptyLaw) return "${ReportPolicy.sqlNorm(column)} = ''";
    args.add(ReportPolicy.norm(law));
    return '${ReportPolicy.sqlNorm(column)} = ?';
  }
}
