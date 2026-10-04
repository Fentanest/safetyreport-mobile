/// 신고 상태·처분 규칙의 정본(EO R-01).
///
/// 서버 `services/report_policy.py`·웹 `web/static/ui/report-policy.js` 와 같은 규칙이고,
/// `contracts/report-policy-vectors.json`(두 레포 바이트 동일)으로 같은 결과를 내는지 검사한다.
///
/// 정책 이름(서버와 같음)
/// - displayStatus: 목록 필터·별점 대상 판정. 진행/진행중/검토중/처리중 → '처리중'. badgeKey: 상태 배지 색.
/// - breakdownStatus: 지도 묶음·상태 분포. displayStatus 에 더해 빈 값도 '처리중'.
/// - isCompleted / isProcessing: 요약 카드·대시보드. 처리중은 좁은 집합(빈 값·보완요청·이송 제외).
/// - tableDisposition: 통계표 행 8분류. inProgress 는 넓은 정의(완료도 취하도 아님).
/// - dashboardDisposition: 지도·기관 상세 4분류. 처리중을 '미확인'에 둔다(통계표와 의도적으로 다름).
/// - trafficDashboard: 대시보드 교통 막대 4계열(교통 분류만).
/// - listStatusFilter / listFineFilter: 목록·드릴다운 필터.
class ReportPolicy {
  ReportPolicy._();

  static const processingLabel = '처리중';
  static const completedOrder = ['수용', '불수용', '일부수용', '기타', '답변완료'];
  static const processingOrder = ['처리중', '진행', '진행중', '검토중'];
  static const rejectOrder = ['불수용', '기타'];
  static const completedStatuses = {'수용', '불수용', '일부수용', '기타', '답변완료'};
  static const processingStatuses = {'처리중', '진행', '진행중', '검토중'};
  static const rejectStatuses = {'불수용', '기타'};
  static const withdrawnStatus = '취하';
  static const supplementStatus = '보완요청';
  static const answeredUnknownStatus = '답변완료';
  static const fineUnknownText = '미확인';

  /// Python strip()·Dart trim()·JS trim() 이 공통으로 떼는 문자(서버 TRIM_CHARS 와 같은 순서).
  static const trimCodes = [
    0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xA0, 0x1680, //
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
  ];
  static final Set<int> _trimSet = trimCodes.toSet();

  static const _eligibleCategories = {'traffic', 'parking'};
  static const _eligibleMenus = ['자동차·교통위반', '불법주정차신고', '쓰레기, 폐기물'];
  static const _partialUnknownCategories = {'parking'};
  static const _partialUnknownMenus = ['불법주정차신고', '버스전용차로 위반', '쓰레기, 폐기물'];

  static const tableDispositionKeys = [
    'fines', 'warnings', 'rejects', 'unconfirmed', 'in_progress', //
    'disposition_unknown', 'no_penalty', 'unclassified',
  ];

  // ── 순수 판정 ──────────────────────────────────────────────────────────

  static String norm(Object? value) {
    final text = value?.toString() ?? '';
    var start = 0, end = text.length;
    while (start < end && _trimSet.contains(text.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _trimSet.contains(text.codeUnitAt(end - 1))) {
      end--;
    }
    return text.substring(start, end);
  }

  static String displayStatus(Object? status) {
    final text = norm(status);
    return processingStatuses.contains(text) ? processingLabel : text;
  }

  static String breakdownStatus(Object? status) {
    final text = displayStatus(status);
    return text.isEmpty ? processingLabel : text;
  }

  /// accept/partial/reject/processing/supplement/withdraw/default
  static String badgeKey(Object? status) {
    final text = norm(status);
    if (text == '수용') return 'accept';
    if (text == '일부수용') return 'partial';
    if (rejectStatuses.contains(text)) return 'reject';
    if (processingStatuses.contains(text)) return 'processing';
    if (text == supplementStatus) return 'supplement';
    if (text == withdrawnStatus) return 'withdraw';
    return 'default';
  }

  static bool isCompleted(Object? status) =>
      completedStatuses.contains(norm(status));
  static bool isProcessing(Object? status) =>
      processingStatuses.contains(norm(status));
  static bool isReject(Object? status) => rejectStatuses.contains(norm(status));
  static bool isWithdrawn(Object? status) => norm(status) == withdrawnStatus;

  static bool hasFine(Object? fine) => norm(fine).contains('과태료');
  static bool hasWarning(Object? fine) {
    final text = norm(fine);
    return text.contains('경고') || text.contains('범칙금');
  }

  static bool isFineUnknown(Object? fine) => norm(fine) == fineUnknownText;

  static bool penaltyEligible(Object? category, Object? entryValue) {
    final entry = norm(entryValue);
    return _eligibleCategories.contains(norm(category)) ||
        _eligibleMenus.any(entry.contains);
  }

  static bool partialUnknownMenu(Object? category, Object? entryValue) {
    final entry = norm(entryValue);
    return _partialUnknownCategories.contains(norm(category)) ||
        _partialUnknownMenus.any(entry.contains);
  }

  static Map<String, bool> tableDisposition(Map<String, dynamic> row) {
    final status = norm(row['처리상태']);
    final fine = norm(row['범칙금_과태료']);
    final fines = fine.contains('과태료');
    final warnings = fine.contains('경고') || fine.contains('범칙금');
    final rejects = rejectStatuses.contains(status);
    final decided = fines || warnings || rejects;
    final completed = completedStatuses.contains(status);
    final inProgress = !decided && !completed && status != withdrawnStatus;
    final unconfirmed = !decided && !inProgress;
    final unknown =
        unconfirmed &&
        (fine == fineUnknownText ||
            (status == '일부수용' &&
                fine.isEmpty &&
                partialUnknownMenu(row['category'], row['entry_value'])));
    final noPenalty =
        unconfirmed &&
        !unknown &&
        !penaltyEligible(row['category'], row['entry_value']) &&
        completed;
    return {
      'fines': fines,
      'warnings': warnings,
      'rejects': rejects,
      'unconfirmed': unconfirmed,
      'in_progress': inProgress,
      'disposition_unknown': unknown,
      'no_penalty': noPenalty,
      'unclassified': unconfirmed && !unknown && !noPenalty,
    };
  }

  static Map<String, bool> dashboardDisposition(Map<String, dynamic> row) {
    final fines = hasFine(row['범칙금_과태료']);
    final warnings = hasWarning(row['범칙금_과태료']);
    final rejects = isReject(row['처리상태']);
    return {
      'fines': fines,
      'warnings': warnings,
      'rejects': rejects,
      'unconfirmed': !(fines || warnings || rejects),
    };
  }

  static Map<String, bool> trafficDashboard(Map<String, dynamic> row) {
    final traffic = norm(row['category']) == 'traffic';
    final reject = isReject(row['처리상태']);
    return {
      'fine': traffic && hasFine(row['범칙금_과태료']),
      'penalty': traffic && hasWarning(row['범칙금_과태료']),
      'reject': traffic && reject,
      'unconfirmed': traffic && isFineUnknown(row['범칙금_과태료']) && !reject,
    };
  }

  static bool listStatusFilter(String name, Object? status) {
    final text = norm(status);
    if (name == processingLabel) return processingStatuses.contains(text);
    if (name == '완료') return completedStatuses.contains(text);
    if (name == '불수용') return rejectStatuses.contains(text);
    return text == norm(name);
  }

  static bool listFineFilter(String name, Object? fine, Object? status) {
    if (name == '과태료') return hasFine(fine);
    if (name == '경고') return hasWarning(fine);
    if (name == fineUnknownText) {
      return isFineUnknown(fine) && !isReject(status);
    }
    return true;
  }

  // ── SQL 조각(SQLite) ───────────────────────────────────────────────────

  static final String _sqlTrimChars = 'char(${trimCodes.join(',')})';

  /// `trim(IFNULL(expr,''), <같은 문자 집합>)`. SQLite trim 은 기본으로 U+0020 만 뗀다.
  static String sqlNorm(String expr) => "trim(IFNULL($expr,''),$_sqlTrimChars)";

  static String sqlIn(String expr, Iterable<String> values) =>
      '$expr IN (${values.map((v) => "'$v'").join(',')})';

  static String sqlNotIn(String expr, Iterable<String> values) =>
      '$expr NOT IN (${values.map((v) => "'$v'").join(',')})';

  static String sqlStatusIs(String column, String value) =>
      "${sqlNorm(column)} = '$value'";

  static String sqlStatusIn(String column, Iterable<String> values) =>
      sqlIn(sqlNorm(column), values);

  static String sqlContains(String column, String text) =>
      "instr(IFNULL($column,''),'$text') > 0";

  static String sqlHasFine(String column) => sqlContains(column, '과태료');

  static String sqlHasWarning(String column) =>
      '(${sqlContains(column, '경고')} OR ${sqlContains(column, '범칙금')})';

  static String sqlFineUnknown(String fineColumn, String statusColumn) =>
      "${sqlNorm(fineColumn)} = '$fineUnknownText' AND ${sqlNorm(statusColumn)} NOT IN ('불수용','기타')";

  static String sqlNotWithdrawn(String column) =>
      "${sqlNorm(column)} != '$withdrawnStatus'";

  static String sqlListStatusFilter(String column, String name) {
    if (name == processingLabel) return sqlStatusIn(column, processingOrder);
    if (name == '완료') return sqlStatusIn(column, completedOrder);
    if (name == '불수용') return sqlStatusIn(column, rejectOrder);
    return sqlStatusIs(column, norm(name));
  }

  static String? sqlListFineFilter(
    String fineColumn,
    String statusColumn,
    String name,
  ) {
    if (name == '과태료') return sqlHasFine(fineColumn);
    if (name == '경고') return sqlHasWarning(fineColumn);
    if (name == fineUnknownText) {
      return sqlFineUnknown(fineColumn, statusColumn);
    }
    return null;
  }
}
