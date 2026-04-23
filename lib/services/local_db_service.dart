import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/report.dart';
import 'standalone_parser.dart';

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

  /// DB 인스턴스를 닫고 리셋합니다. (파일 교체 후 재오픈 용도)
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
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE reports (
            c_no          TEXT PRIMARY KEY,
            report_number TEXT,
            name          TEXT,
            date          TEXT,
            response_date TEXT,
            agency        TEXT,
            manager       TEXT,
            status        TEXT,
            result        TEXT,
            fine_info     TEXT,
            penalty_points TEXT,
            car_number    TEXT,
            law           TEXT,
            location      TEXT,
            occurrence_date TEXT,
            occurrence_time TEXT,
            report_content  TEXT,
            process_content TEXT,
            attached_photos TEXT,
            attached_files  TEXT,
            map_image       TEXT,
            category        TEXT,
            synced_at       INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_meta (
            key   TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
      },
    );
  }

  // ── 신고 저장/업데이트 ─────────────────────────────────────────────────────

  static Future<void> upsertReport(Report r, String category) async {
    final d = await db;
    await d.insert(
      'reports',
      {
        'c_no': r.id,
        'report_number': r.reportNumber,
        'name': r.name,
        'date': r.date,
        'response_date': r.responseDate,
        'agency': r.agency,
        'manager': r.manager,
        'status': r.status,
        'result': r.result,
        'fine_info': r.fineInfo,
        'penalty_points': r.penaltyPoints,
        'car_number': r.carNumber,
        'law': r.law,
        'location': r.location,
        'occurrence_date': r.occurrenceDate,
        'occurrence_time': r.occurrenceTime,
        'report_content': r.reportContent,
        'process_content': r.processContent,
        'attached_photos': r.attachedPhotos,
        'attached_files': r.attachedFiles,
        'map_image': r.mapImage,
        'category': category,
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
      orderBy: 'date DESC',
    );
    return rows.map(_rowToReport).toList();
  }

  static Future<List<Report>> getAllReports() async {
    final d = await db;
    final rows = await d.query('reports', orderBy: 'date DESC');
    return rows.map(_rowToReport).toList();
  }

  static Future<Report?> getReport(String cNo) async {
    final d = await db;
    final rows = await d.query('reports', where: 'c_no = ?', whereArgs: [cNo]);
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
    final rows =
        await d.query('sync_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  // ── 대시보드 요약 ─────────────────────────────────────────────────────────

  static Future<DashboardStats> computeSummary() async {
    final d = await db;
    final rows = await d.query('reports');

    int accept = 0, partial = 0, reject = 0, processing = 0, withdraw = 0;
    int tFine = 0, tPenalty = 0, tReject = 0, tUnconfirmed = 0;

    for (final r in rows) {
      final status = r['status'] as String? ?? '';
      final cat = r['category'] as String? ?? '';
      final fine = r['fine_info'] as String? ?? '';

      switch (status) {
        case '수용':
          accept++;
        case '일부수용':
          partial++;
        case '불수용':
          reject++;
        case '취하':
          withdraw++;
        default:
          processing++;
      }

      if (cat == 'traffic') {
        if (fine.contains('과태료') || fine.contains('범칙금'))
          tFine++;
        else if (fine == '경고')
          tPenalty++;
        else if (status == '불수용')
          tReject++;
        else if (fine == '미확인')
          tUnconfirmed++;
      }
    }

    final recentRows = await d.query(
      'reports',
      where: "status IN ('수용', '일부수용', '불수용', '취하')",
      orderBy: 'response_date DESC',
      limit: 10,
    );

    final watchlistNums = await getWatchlistNumbers();
    List<Map<String, dynamic>> watchlistRows = [];
    if (watchlistNums.isNotEmpty) {
      final placeholders = watchlistNums.map((_) => '?').join(',');
      watchlistRows = await d.rawQuery(
        'SELECT * FROM reports WHERE report_number IN ($placeholders) ORDER BY date DESC',
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
      completedCount: accept + partial + reject + withdraw,
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
      where += " AND date LIKE ?";
      args.add('$year%');
    }
    if (law != null) {
      if (law == '__없음__') {
        where += " AND (law IS NULL OR law = '')";
      } else {
        where += " AND law = ?";
        args.add(law);
      }
    }

    final rows = await d.query(
      'reports',
      where: where,
      whereArgs: args.isEmpty ? null : args,
    );

    return _aggregateStats(rows);
  }

  static Map<String, dynamic> _aggregateStats(List<Map<String, dynamic>> rows) {
    final traffic = rows.where((r) => r['category'] == 'traffic').toList();
    final parking = rows.where((r) => r['category'] == 'parking').toList();
    final other = rows.where((r) => r['category'] == 'other').toList();

    final years = rows
        .map((r) => (r['date'] as String? ?? '').length >= 4
            ? (r['date'] as String).substring(0, 4)
            : '')
        .where((y) => y.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    return {
      'traffic': _buildCategory(traffic),
      'parking': _buildCategory(parking),
      'other': _buildCategory(other),
      'available_years': years,
    };
  }

  static Map<String, dynamic> _buildCategory(List<Map<String, dynamic>> rows) {
    // ── 기관별 집계 ──
    final agencyAgg = <String, _AgencyAgg>{};
    for (final r in rows) {
      final key = (r['agency'] as String? ?? '').trim();
      if (key.isEmpty) continue;
      agencyAgg.putIfAbsent(key, () => _AgencyAgg(key, ''));
      agencyAgg[key]!.add(r);
    }

    final allAgency = agencyAgg.values.map((a) => a.toJson()).toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

    // ── 담당자별 집계 (agency + manager 쌍) ──
    // Python과 동일: 미배정 담당자 + 처리중/취하 건 제외
    final personAgg = <String, _AgencyAgg>{};
    for (final r in rows) {
      final agency = (r['agency'] as String? ?? '').trim();
      final manager = (r['manager'] as String? ?? '').trim();
      final status = (r['status'] as String? ?? '');
      // 미배정 담당자 + 처리중/취하 건은 제외
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

    // ── 경찰/비경찰 분리 ──
    final policeAgency = allAgency.where((r) => (r['agency'] as String).contains('경찰')).toList();
    final nonPoliceAgency = allAgency.where((r) => !(r['agency'] as String).contains('경찰')).toList();
    final policePerson = allPerson.where((r) => (r['agency'] as String).contains('경찰')).toList();
    final nonPolicePerson = allPerson.where((r) => !(r['agency'] as String).contains('경찰')).toList();

    final allLaws = rows
        .map((r) => r['law'] as String? ?? '')
        .where((l) => l.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final hasEmptyLaw = rows.any((r) => (r['law'] as String? ?? '').isEmpty);

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
    // 차량번호별 최신 신고 1건 + 총/유효 건수
    final rows = await d.rawQuery('''
      SELECT r.*,
             cc.total_count,
             cc.valid_count
      FROM reports r
      INNER JOIN (
        SELECT car_number,
               COUNT(*)  AS total_count,
               SUM(CASE WHEN result != '취하' THEN 1 ELSE 0 END) AS valid_count
        FROM reports
        WHERE car_number != ''
        GROUP BY car_number
        HAVING COUNT(*) >= 2
      ) cc ON r.car_number = cc.car_number
      WHERE r.date = (
        SELECT MAX(date) FROM reports r2
        WHERE r2.car_number = r.car_number
      )
      ORDER BY cc.total_count DESC, r.date DESC
    ''');
    return rows.map(_rowToReportWithCounts).toList();
  }

  static Report _rowToReportWithCounts(Map<String, dynamic> r) => Report(
        id: r['c_no'] as String? ?? '',
        reportNumber: r['report_number'] as String? ?? '',
        name: r['name'] as String? ?? '',
        date: r['date'] as String? ?? '',
        responseDate: r['response_date'] as String? ?? '',
        agency: r['agency'] as String? ?? '',
        manager: r['manager'] as String? ?? '',
        status: r['status'] as String? ?? '',
        result: r['result'] as String? ?? '',
        fineInfo: r['fine_info'] as String? ?? '',
        penaltyPoints: r['penalty_points'] as String? ?? '',
        carNumber: r['car_number'] as String? ?? '',
        law: r['law'] as String? ?? '',
        location: r['location'] as String? ?? '',
        occurrenceDate: r['occurrence_date'] as String? ?? '',
        occurrenceTime: r['occurrence_time'] as String? ?? '',
        reportContent: r['report_content'] as String? ?? '',
        processContent: r['process_content'] as String? ?? '',
        attachedPhotos: r['attached_photos'] as String? ?? '',
        attachedFiles: r['attached_files'] as String? ?? '',
        mapImage: r['map_image'] as String? ?? '',
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
  }

  static Future<List<Report>> getWatchlistReports() async {
    final numbers = await getWatchlistNumbers();
    if (numbers.isEmpty) return [];
    final d = await db;
    final placeholders = numbers.map((_) => '?').join(',');
    final rows = await d.rawQuery(
      'SELECT * FROM reports WHERE report_number IN ($placeholders) ORDER BY date DESC',
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
      where: 'name LIKE ? OR report_number LIKE ? OR car_number LIKE ? OR agency LIKE ? OR law LIKE ?',
      whereArgs: [q, q, q, q, q],
      orderBy: 'date DESC',
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
        id: r['c_no'] as String? ?? '',
        reportNumber: r['report_number'] as String? ?? '',
        name: r['name'] as String? ?? '',
        date: r['date'] as String? ?? '',
        responseDate: r['response_date'] as String? ?? '',
        agency: r['agency'] as String? ?? '',
        manager: r['manager'] as String? ?? '',
        status: r['status'] as String? ?? '',
        result: r['result'] as String? ?? '',
        fineInfo: r['fine_info'] as String? ?? '',
        penaltyPoints: r['penalty_points'] as String? ?? '',
        carNumber: r['car_number'] as String? ?? '',
        law: r['law'] as String? ?? '',
        location: r['location'] as String? ?? '',
        occurrenceDate: r['occurrence_date'] as String? ?? '',
        occurrenceTime: r['occurrence_time'] as String? ?? '',
        reportContent: r['report_content'] as String? ?? '',
        processContent: r['process_content'] as String? ?? '',
        attachedPhotos: r['attached_photos'] as String? ?? '',
        attachedFiles: r['attached_files'] as String? ?? '',
        mapImage: r['map_image'] as String? ?? '',
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
    final status = (r['status'] as String? ?? '');
    final fine = (r['fine_info'] as String? ?? '');
    if (fine.contains('과태료')) fines++;
    if (fine.contains('경고') || fine.contains('범칙금')) warn++;
    if (status == '불수용' || status == '기타') reject++;
    totalFine += extractFineAmount(fine);

    final date = r['date'] as String? ?? '';
    final resp = r['response_date'] as String? ?? '';
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

