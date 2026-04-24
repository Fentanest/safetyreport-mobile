import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/report.dart';
import 'standalone_parser.dart';

/// 서버 DB 컬럼명(한국어)과 동일한 스키마 사용.
/// mobile-only 추가 컬럼: category, entry_value, synced_at
class LocalDbService {
  static Database? _db;

  static Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  static Future<String> getDbPath() async {
    final dbPath = await getDatabasesPath();
    return join(dbPath, 'standalone_reports.db');
  }

  static Future<void> closeDb() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  static Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      join(dbPath, 'standalone_reports.db'),
      version: 2,
      onCreate: _create,
      onUpgrade: (db, oldV, newV) async {
        // 구버전(v1 영문 컬럼명) → v2 한국어 컬럼명으로 재생성 (데이터 초기화, 재동기화 필요)
        await db.execute('DROP TABLE IF EXISTS reports');
        await db.execute('DROP TABLE IF EXISTS sync_meta');
        await _create(db, newV);
      },
    );
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE reports (
        ID              TEXT PRIMARY KEY,
        상태             TEXT,
        신고번호          TEXT,
        신고명            TEXT,
        신고일            TEXT,
        만족도조사여부     TEXT,
        감시목록          TEXT DEFAULT 'N',
        처리상태          TEXT,
        차량번호          TEXT,
        위반법규          TEXT,
        범칙금_과태료      TEXT,
        벌점             TEXT,
        처리기관          TEXT,
        담당자            TEXT,
        답변일            TEXT,
        발생일자          TEXT,
        발생시각          TEXT,
        위반장소          TEXT,
        종결여부          TEXT DEFAULT 'N',
        신고내용          TEXT,
        처리내용          TEXT,
        지도             TEXT,
        첨부사진          TEXT,
        첨부파일          TEXT,
        category        TEXT,
        entry_value     TEXT DEFAULT '',
        synced_at       INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_meta (
        key   TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  // ── 신고 저장/업데이트 ─────────────────────────────────────────────────────

  static Future<void> upsertReport(Report r, String category, String entryValue) async {
    final watchlistNums = await getWatchlistNumbers();
    final d = await db;
    await d.insert(
      'reports',
      {
        'ID': r.id,
        '상태': r.result,
        '신고번호': r.reportNumber,
        '신고명': r.name,
        '신고일': r.date,
        '만족도조사여부': r.pollStatus,
        '감시목록': watchlistNums.contains(r.reportNumber) ? 'Y' : 'N',
        '처리상태': r.status,
        '차량번호': r.carNumber,
        '위반법규': r.law,
        '범칙금_과태료': r.fineInfo,
        '벌점': r.penaltyPoints,
        '처리기관': r.agency,
        '담당자': r.manager,
        '답변일': r.responseDate,
        '발생일자': r.occurrenceDate,
        '발생시각': r.occurrenceTime,
        '위반장소': r.location,
        '종결여부': r.processingFinish,
        '신고내용': r.reportContent,
        '처리내용': r.processContent,
        '지도': r.mapImage,
        '첨부사진': r.attachedPhotos,
        '첨부파일': r.attachedFiles,
        'category': category,
        'entry_value': entryValue,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── 신고 조회 ─────────────────────────────────────────────────────────────

  static Future<List<Report>> getReportsByCategory(String category) async {
    final d = await db;
    final rows = await d.query(
      'reports',
      where: 'category = ?',
      whereArgs: [category],
      orderBy: '신고일 DESC',
    );
    return rows.map(_rowToReport).toList();
  }

  static Future<List<Report>> getAllReports() async {
    final d = await db;
    final rows = await d.query('reports', orderBy: '신고일 DESC');
    return rows.map(_rowToReport).toList();
  }

  static Future<Report?> getReport(String cNo) async {
    final d = await db;
    final rows = await d.query('reports', where: 'ID = ?', whereArgs: [cNo]);
    return rows.isEmpty ? null : _rowToReport(rows.first);
  }

  static Future<int> getTotalCount() async {
    final d = await db;
    final r = await d.rawQuery('SELECT COUNT(*) as cnt FROM reports');
    return (r.first['cnt'] as int?) ?? 0;
  }

  // ── 동기화 메타 ───────────────────────────────────────────────────────────

  static Future<void> setMeta(String key, String value) async {
    final d = await db;
    await d.insert(
      'sync_meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String?> getMeta(String key) async {
    final d = await db;
    final rows = await d.query('sync_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  // ── 대시보드 요약 ─────────────────────────────────────────────────────────

  static Future<DashboardStats> computeSummary() async {
    final d = await db;
    final rows = await d.query('reports');

    int accept = 0, partial = 0, reject = 0, processing = 0, completed = 0, withdraw = 0;
    int tFine = 0, tPenalty = 0, tReject = 0, tUnconfirmed = 0;

    // 서버 get_dashboard_stats 로직과 정확히 동일
    for (final r in rows) {
      final status = r['처리상태'] as String? ?? '';
      final cat = r['category'] as String? ?? '';
      final fine = r['범칙금_과태료'] as String? ?? '';

      if (status == '수용') accept++;
      if (status == '일부수용') partial++;
      if (status == '불수용' || status == '기타') reject++;
      if (status == '처리중' || status == '진행' || status == '진행중') processing++;
      if (['수용', '불수용', '일부수용', '기타', '답변완료'].contains(status)) completed++;
      if (status == '취하') withdraw++;

      if (cat == 'traffic') {
        if (fine.contains('과태료')) tFine++;
        if (fine.contains('경고') || fine.contains('범칙금')) tPenalty++;
        if (status == '불수용' || status == '기타') tReject++;
        if (fine == '미확인' && status != '불수용' && status != '기타') tUnconfirmed++;
      }
    }

    final recentRows = await d.query(
      'reports',
      where: "처리상태 IN ('수용', '일부수용', '불수용', '기타', '답변완료')",
      orderBy: '답변일 DESC',
      limit: 10,
    );

    final watchlistNums = await getWatchlistNumbers();
    List<Map<String, dynamic>> watchlistRows = [];
    if (watchlistNums.isNotEmpty) {
      final placeholders = watchlistNums.map((_) => '?').join(',');
      watchlistRows = await d.rawQuery(
        'SELECT * FROM reports WHERE 신고번호 IN ($placeholders) ORDER BY 신고일 DESC',
        watchlistNums.toList(),
      );
    }

    final lastSync = await getMeta('last_sync') ?? '';

    return DashboardStats(
      lastCrawlTime: lastSync,
      total: rows.length,
      acceptCount: accept,
      partialCount: partial,
      rejectCount: reject,
      processingCount: processing,
      completedCount: completed,
      withdrawCount: withdraw,
      tFineCount: tFine,
      tPenaltyCount: tPenalty,
      tRejectCount: tReject,
      tUnconfirmedCount: tUnconfirmed,
      recentAnswers: recentRows.map(_rowToReport).toList(),
      watchlist: watchlistRows.map(_rowToReport).toList(),
    );
  }

  // ── 통계 집계 ─────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> computeStats({
    String? year,
    String? law,
  }) async {
    final d = await db;

    String where = '1=1';
    final args = <dynamic>[];

    if (year != null) {
      where += ' AND 신고일 LIKE ?';
      args.add('$year%');
    }
    if (law != null) {
      if (law == '__없음__') {
        where += ' AND (위반법규 IS NULL OR 위반법규 = \'\')';
      } else {
        where += ' AND 위반법규 = ?';
        args.add(law);
      }
    }

    final rows = await d.query(
      'reports',
      where: where,
      whereArgs: args.isEmpty ? null : args,
    );

    // 필터와 무관하게 전체에서 available_years/laws 추출
    final allRows = await d.query('reports', columns: ['신고일', '위반법규', 'category']);
    return _aggregateStats(rows, allRows);
  }

  static Map<String, dynamic> _aggregateStats(
      List<Map<String, dynamic>> rows, List<Map<String, dynamic>> allRows) {
    final traffic = rows.where((r) => r['category'] == 'traffic').toList();
    final parking = rows.where((r) => r['category'] == 'parking').toList();
    final other = rows.where((r) => r['category'] == 'other').toList();

    // 연도 목록은 항상 전체에서 추출 (필터 변경 시 다른 연도 선택지 유지)
    final years = allRows
        .map((r) => (r['신고일'] as String? ?? '').length >= 4
            ? (r['신고일'] as String).substring(0, 4)
            : '')
        .where((y) => y.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    return {
      'traffic': _buildCategory(traffic, allRows.where((r) => r['category'] == 'traffic').toList()),
      'parking': _buildCategory(parking, allRows.where((r) => r['category'] == 'parking').toList()),
      'other': _buildCategory(other, allRows.where((r) => r['category'] == 'other').toList()),
      'available_years': years,
    };
  }

  static Map<String, dynamic> _buildCategory(
      List<Map<String, dynamic>> rows, List<Map<String, dynamic>> allCatRows) {
    final agencyAgg = <String, _AgencyAgg>{};
    for (final r in rows) {
      final key = (r['처리기관'] as String? ?? '').trim();
      if (key.isEmpty) continue;
      agencyAgg.putIfAbsent(key, () => _AgencyAgg(key, ''));
      agencyAgg[key]!.add(r);
    }

    final allAgency = agencyAgg.values.map((a) => a.toJson()).toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

    final personAgg = <String, _AgencyAgg>{};
    for (final r in rows) {
      final agency = (r['처리기관'] as String? ?? '').trim();
      final manager = (r['담당자'] as String? ?? '').trim();
      final status = (r['처리상태'] as String? ?? '');
      if ((manager.isEmpty) &&
          (status == '처리중' || status == '진행' || status == '진행중' || status == '취하')) {
        continue;
      }
      if (agency.isEmpty) continue;
      final key = '$agency\t$manager';
      personAgg.putIfAbsent(key, () => _AgencyAgg(agency, manager));
      personAgg[key]!.add(r);
    }

    final allPerson = personAgg.values.map((a) => a.toJson()).toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

    final policeAgency = allAgency.where((r) => (r['agency'] as String).contains('경찰')).toList();
    final nonPoliceAgency = allAgency.where((r) => !(r['agency'] as String).contains('경찰')).toList();
    final policePerson = allPerson.where((r) => (r['agency'] as String).contains('경찰')).toList();
    final nonPolicePerson = allPerson.where((r) => !(r['agency'] as String).contains('경찰')).toList();

    // 법규 목록은 카테고리 전체에서 추출 (필터 변경 시 다른 법규 선택지 유지)
    final allLaws = allCatRows
        .map((r) => r['위반법규'] as String? ?? '')
        .where((l) => l.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final hasEmptyLaw = allCatRows.any((r) => (r['위반법규'] as String? ?? '').isEmpty);

    return {
      'by_agency': allAgency,
      'by_person': allPerson,
      'police_by_agency': policeAgency,
      'police_by_person': policePerson,
      'other_by_agency': nonPoliceAgency,
      'other_by_person': nonPolicePerson,
      'available_laws': allLaws,
      'has_empty_law': hasEmptyLaw,
    };
  }

  // ── 중복차량 ─────────────────────────────────────────────────────────────

  static Future<List<Report>> getDuplicateVehicleReports() async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT r.*,
             cc.total_count,
             cc.valid_count
      FROM reports r
      INNER JOIN (
        SELECT 차량번호,
               COUNT(*)  AS total_count,
               SUM(CASE WHEN 상태 != '취하' THEN 1 ELSE 0 END) AS valid_count
        FROM reports
        WHERE 차량번호 != ''
        GROUP BY 차량번호
        HAVING COUNT(*) >= 2
      ) cc ON r.차량번호 = cc.차량번호
      WHERE r.신고일 = (
        SELECT MAX(신고일) FROM reports r2
        WHERE r2.차량번호 = r.차량번호
      )
      ORDER BY cc.total_count DESC, r.신고일 DESC
    ''');
    return rows.map(_rowToReportWithCounts).toList();
  }

  static Report _rowToReportWithCounts(Map<String, dynamic> r) => Report(
        id: r['ID'] as String? ?? '',
        reportNumber: r['신고번호'] as String? ?? '',
        name: r['신고명'] as String? ?? '',
        date: r['신고일'] as String? ?? '',
        responseDate: r['답변일'] as String? ?? '',
        agency: r['처리기관'] as String? ?? '',
        manager: r['담당자'] as String? ?? '',
        status: r['처리상태'] as String? ?? '',
        result: r['상태'] as String? ?? '',
        fineInfo: r['범칙금_과태료'] as String? ?? '',
        penaltyPoints: r['벌점'] as String? ?? '',
        carNumber: r['차량번호'] as String? ?? '',
        law: r['위반법규'] as String? ?? '',
        location: r['위반장소'] as String? ?? '',
        occurrenceDate: r['발생일자'] as String? ?? '',
        occurrenceTime: r['발생시각'] as String? ?? '',
        reportContent: r['신고내용'] as String? ?? '',
        processContent: r['처리내용'] as String? ?? '',
        attachedPhotos: r['첨부사진'] as String? ?? '',
        attachedFiles: r['첨부파일'] as String? ?? '',
        mapImage: r['지도'] as String? ?? '',
        pollStatus: r['만족도조사여부'] as String? ?? '답변 대기',
        processingFinish: r['종결여부'] as String? ?? 'N',
        totalCount: (r['total_count'] as num?)?.toInt() ?? 0,
        validCount: (r['valid_count'] as num?)?.toInt() ?? 0,
      );

  // ── 감시목록 ──────────────────────────────────────────────────────────────

  static Future<Set<String>> getWatchlistNumbers() async {
    final raw = await getMeta('watchlist') ?? '';
    if (raw.isEmpty) return {};
    return raw.split(',').where((s) => s.isNotEmpty).toSet();
  }

  static Future<void> setWatchlistNumbers(Set<String> numbers) async {
    await setMeta('watchlist', numbers.join(','));
    // 감시목록 컬럼 동기화
    final d = await db;
    await d.rawUpdate("UPDATE reports SET 감시목록 = 'N'");
    if (numbers.isNotEmpty) {
      final placeholders = numbers.map((_) => '?').join(',');
      await d.rawUpdate(
        "UPDATE reports SET 감시목록 = 'Y' WHERE 신고번호 IN ($placeholders)",
        numbers.toList(),
      );
    }
  }

  static Future<List<Report>> getWatchlistReports() async {
    final numbers = await getWatchlistNumbers();
    if (numbers.isEmpty) return [];
    final d = await db;
    final placeholders = numbers.map((_) => '?').join(',');
    final rows = await d.rawQuery(
      'SELECT * FROM reports WHERE 신고번호 IN ($placeholders) ORDER BY 신고일 DESC',
      numbers.toList(),
    );
    return rows.map(_rowToReport).toList();
  }

  // ── 검색 ─────────────────────────────────────────────────────────────────

  static Future<List<Report>> searchReports(String query) async {
    final d = await db;
    final q = '%$query%';
    final rows = await d.query(
      'reports',
      where: '신고명 LIKE ? OR 신고번호 LIKE ? OR 차량번호 LIKE ? OR 처리기관 LIKE ? OR 위반법규 LIKE ?',
      whereArgs: [q, q, q, q, q],
      orderBy: '신고일 DESC',
    );
    return rows.map(_rowToReport).toList();
  }

  // ── 전체 삭제 ─────────────────────────────────────────────────────────────

  static Future<void> clearAll() async {
    final d = await db;
    await d.delete('reports');
    await d.delete('sync_meta');
  }

  // ── 내부 변환 ─────────────────────────────────────────────────────────────

  static Report _rowToReport(Map<String, dynamic> r) => Report(
        id: r['ID'] as String? ?? '',
        reportNumber: r['신고번호'] as String? ?? '',
        name: r['신고명'] as String? ?? '',
        date: r['신고일'] as String? ?? '',
        responseDate: r['답변일'] as String? ?? '',
        agency: r['처리기관'] as String? ?? '',
        manager: r['담당자'] as String? ?? '',
        status: r['처리상태'] as String? ?? '',
        result: r['상태'] as String? ?? '',
        fineInfo: r['범칙금_과태료'] as String? ?? '',
        penaltyPoints: r['벌점'] as String? ?? '',
        carNumber: r['차량번호'] as String? ?? '',
        law: r['위반법규'] as String? ?? '',
        location: r['위반장소'] as String? ?? '',
        occurrenceDate: r['발생일자'] as String? ?? '',
        occurrenceTime: r['발생시각'] as String? ?? '',
        reportContent: r['신고내용'] as String? ?? '',
        processContent: r['처리내용'] as String? ?? '',
        attachedPhotos: r['첨부사진'] as String? ?? '',
        attachedFiles: r['첨부파일'] as String? ?? '',
        mapImage: r['지도'] as String? ?? '',
        pollStatus: r['만족도조사여부'] as String? ?? '답변 대기',
        processingFinish: r['종결여부'] as String? ?? 'N',
      );
}

// ── 집계 헬퍼 ────────────────────────────────────────────────────────────────

class _AgencyAgg {
  final String name;
  final String person;
  int total = 0, fines = 0, warn = 0, reject = 0;
  int totalFine = 0;
  final List<int> responseDays = [];

  _AgencyAgg(this.name, this.person);

  void add(Map<String, dynamic> r) {
    total++;
    final status = (r['처리상태'] as String? ?? '');
    final fine = (r['범칙금_과태료'] as String? ?? '');
    if (fine.contains('과태료')) fines++;
    if (fine.contains('경고') || fine.contains('범칙금')) warn++;
    if (status == '불수용' || status == '기타') reject++;
    totalFine += extractFineAmount(fine);

    final date = r['신고일'] as String? ?? '';
    final resp = r['답변일'] as String? ?? '';
    if (date.length >= 10 && resp.length >= 10) {
      try {
        final d = DateTime.parse(date.substring(0, 10));
        final rd = DateTime.parse(resp.substring(0, 10));
        responseDays.add(rd.difference(d).inDays);
      } catch (_) {}
    }
  }

  Map<String, dynamic> toJson() {
    final t = total > 0 ? total.toDouble() : 1.0;
    return {
      'agency': name,
      'person': person,
      'total': total,
      'fines': fines,
      'fines_pct': double.parse((fines / t * 100).toStringAsFixed(1)),
      'warnings': warn,
      'warnings_pct': double.parse((warn / t * 100).toStringAsFixed(1)),
      'rejects': reject,
      'rejects_pct': double.parse((reject / t * 100).toStringAsFixed(1)),
      'total_fine_amount': totalFine,
      'avg_days': responseDays.isEmpty
          ? null
          : responseDays.reduce((a, b) => a + b) / responseDays.length,
    };
  }
}
