import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/report.dart';
import '../models/report_filter.dart';
import '../utils/report_display_text.dart';
import 'performance_trace.dart';
import 'report_filter_spec.dart';

/// 화면에서 복사한 인용부호·꺾쇠·개행 검색에 한해 원문 또는 표시문구를
/// 허용한다. 기존 ',' OR / '&' AND 해석과 DB·서버 전송 값은 바꾸지 않는다.
class ReportDisplaySearch {
  ReportDisplaySearch(ReportFilter filter)
    : queries = {
        if (needsDisplayMatch(filter.name)) '신고명': filter.name,
        if (needsDisplayMatch(filter.reportContent))
          '신고내용': filter.reportContent,
        if (needsDisplayMatch(filter.processContent))
          '처리내용': filter.processContent,
        if (needsDisplayMatch(filter.ratingCause)) '별점사유': filter.ratingCause,
      },
      rawFilter = filter.copyWith(
        name: needsDisplayMatch(filter.name) ? '' : filter.name,
        reportContent: needsDisplayMatch(filter.reportContent)
            ? ''
            : filter.reportContent,
        processContent: needsDisplayMatch(filter.processContent)
            ? ''
            : filter.processContent,
        ratingCause: needsDisplayMatch(filter.ratingCause)
            ? ''
            : filter.ratingCause,
      ) {
    _groups = {
      for (final entry in queries.entries)
        entry.key: ReportFilterSpec.parseGroups(entry.value),
    };
  }

  final Map<String, String> queries;
  final ReportFilter rawFilter;
  late final Map<String, List<List<String>>> _groups;
  bool get isActive => queries.isNotEmpty;
  String get cacheKey => jsonEncode(queries);

  static bool needsDisplayMatch(String query) {
    final value = query.trim();
    return value.contains('"') ||
        value.contains("'") ||
        value.contains('<') ||
        value.contains('>') ||
        value.contains('\r') ||
        value.contains('\n') ||
        value.contains('\u00a0');
  }

  bool _matches(String field, String value) {
    final groups = _groups[field]!;
    if (ReportFilterSpec.matchesGroups(value, groups)) return true;
    final shown = field == '신고명'
        ? reportTitlePreview(value)
        : reportDisplayText(value);
    if (shown != value && ReportFilterSpec.matchesGroups(shown, groups)) {
      return true;
    }
    // 목록 제목은 빈 줄을 접지만 상세 제목에서는 원래 빈 줄을 보여 준다.
    // 어느 화면에서 복사했든 그 화면에 보인 문구를 그대로 찾을 수 있다.
    return field == '신고명' &&
        ReportFilterSpec.matchesGroups(reportDisplayText(value), groups);
  }

  bool matchesValues(Map<String, Object?> row) => queries.keys.every(
    (field) => _matches(field, row[field]?.toString() ?? ''),
  );

  bool matchesReport(Report report) => queries.keys.every(
    (field) => _matches(field, switch (field) {
      '신고명' => report.name,
      '신고내용' => report.reportContent,
      '처리내용' => report.processContent,
      '별점사유' => report.ratingCause,
      _ => throw StateError('unsupported display search field'),
    }),
  );
}

/// 본문은 영속/임시 테이블 어디에도 복제하지 않고 페이지 단위로 읽는다.
/// 일치 ID만 TEMP에 남겨 기존 SQL의 COUNT·정렬·LIMIT 전에 결합한다.
/// 호출자가 소유한 읽기 트랜잭션 안에서 실행하며 캐시 게시도 완료 뒤에만 한다.
Future<int> rebuildDisplaySearchMatches(
  DatabaseExecutor db,
  ReportDisplaySearch search, {
  required bool Function() isCancelled,
  String sourceTable = 'reports_effective',
  void Function(int rows)? onPage,
}) async {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(sourceTable)) {
    throw ArgumentError('invalid source table');
  }
  void check() {
    if (isCancelled()) throw const QueryCancelled();
  }

  check();
  await db.execute(
    'CREATE TEMP TABLE IF NOT EXISTS sr_display_search_match (id TEXT PRIMARY KEY)',
  );
  await db.execute('DELETE FROM temp.sr_display_search_match');
  final columns = [
    'ID',
    ...search.queries.keys,
  ].map((field) => '"$field"').join(',');
  String? after;
  var matched = 0;
  while (true) {
    check();
    final rows = await db.rawQuery(
      'SELECT $columns FROM "$sourceTable" ${after == null ? '' : 'WHERE ID>?'} ORDER BY ID LIMIT 200',
      [?after],
    );
    check();
    if (rows.isEmpty) break;
    onPage?.call(rows.length);
    final batch = db.batch();
    for (final row in rows) {
      check();
      if (!search.matchesValues(row)) continue;
      batch.rawInsert(
        'INSERT INTO temp.sr_display_search_match (id) VALUES (?)',
        [row['ID']],
      );
      matched++;
    }
    await batch.commit(noResult: true);
    after = rows.last['ID'].toString();
    // 긴 본문이 많아도 취소/필터 변경 이벤트를 페이지 사이에 처리한다.
    await Future<void>.delayed(Duration.zero);
  }
  check();
  return matched;
}
