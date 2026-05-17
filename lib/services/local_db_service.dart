import 'dart:io';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/duplicate_group.dart';
import '../models/report.dart';
import 'duplicate_projection_service.dart';
import 'geocode_utils.dart';
import 'standalone_parser.dart';

/// 서버 _normalize_police_agency 동일: '경찰서' 이후 문자열 제거
String normalizePoliceAgency(String agency) {
  final idx = agency.indexOf('경찰서');
  return idx != -1 ? agency.substring(0, idx + 3) : agency;
}

/// 서버 DB 컬럼명(한국어)과 동일한 스키마 사용.
/// mobile-only 추가 컬럼: category, entry_value, synced_at
/// raw payload 는 report_raw 사이드카 테이블에 저장한다.
class LocalDbService {
  static Database? _db;
  static Future<Database>? _initFuture;
  static const playReviewDemoUsername = 'demo';
  static const playReviewDemoPassword = 'demo';
  static const playReviewDemoPhone = 'demo';

  static bool isPlayReviewDemoLogin({
    required String username,
    required String password,
    required String rawPhone,
  }) {
    return username == playReviewDemoUsername &&
        password == playReviewDemoPassword &&
        (rawPhone.isEmpty || rawPhone == playReviewDemoPhone);
  }

  static Future<Database> get db async {
    if (_db != null) return _db!;
    _initFuture ??= _open();
    _db = await _initFuture;
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
      _initFuture = null;
    }
  }

  static Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final database = await openDatabase(
      join(dbPath, 'standalone_reports.db'),
      version: 10,
      onCreate: _create,
      onUpgrade: _migrateLocalDatabase,
    );
    try {
      await database.execute("""
        UPDATE reports
        SET 처리상태 = 상태,
            종결여부 = 'Y',
            보완_미응답 = 'N'
        WHERE 상태 IN ('수용', '일부수용', '불수용', '기타', '답변완료', '취하', '이송')
          AND (처리상태 IS NULL OR 처리상태 IN ('', '진행', '진행중', '처리중', '검토중') OR 보완_미응답 = 'Y')
      """);
      await database.execute("""
        UPDATE reports
        SET 처리상태 = '보완요청',
            종결여부 = 'N',
            보완_미응답 = 'Y'
        WHERE 상태 = '보완요청'
          AND (처리상태 IS NULL OR 처리상태 IN ('', '진행', '진행중', '처리중', '검토중', '보완요청'))
      """);
      await database.execute("""
        UPDATE reports
        SET 처리상태 = '보완요청',
            종결여부 = 'N'
        WHERE 보완_미응답 = 'Y'
          AND 상태 NOT IN ('수용', '일부수용', '불수용', '기타', '답변완료', '취하', '이송')
          AND 처리상태 != '보완요청'
      """);
      await database.execute("""
        UPDATE reports
        SET 처리상태 = '처리중',
            종결여부 = 'N'
        WHERE 상태 NOT IN ('수용', '일부수용', '불수용', '기타', '답변완료', '취하', '이송', '보완요청')
          AND 보완_미응답 != 'Y'
          AND (처리상태 IS NULL OR 처리상태 IN ('', '진행', '진행중', '처리중', '검토중'))
      """);
    } catch (_) {
      // best-effort normalization for legacy standalone DBs
    }
    return database;
  }

  /// 보완요청 마지막 round 1개 + 누적 횟수 + 요청자/일시 메타를 reports row 에 보존.
  /// 이전 빌드에서 잠시 존재했던 report_supplement_history 테이블은 정리한다.
  static Future<void> _addSupplementColumns(DatabaseExecutor db) async {
    for (final col in const [
      "ALTER TABLE reports ADD COLUMN 보완횟수 INTEGER DEFAULT 0",
      "ALTER TABLE reports ADD COLUMN 보완_미응답 TEXT DEFAULT 'N'",
      "ALTER TABLE reports ADD COLUMN 보완_요청자 TEXT DEFAULT ''",
      "ALTER TABLE reports ADD COLUMN 보완_요청일시 TEXT DEFAULT ''",
      "ALTER TABLE reports ADD COLUMN 보완_완료일시 TEXT DEFAULT ''",
      "ALTER TABLE reports ADD COLUMN 보완_요청_내용 TEXT DEFAULT ''",
      "ALTER TABLE reports ADD COLUMN 보완_신고자_의견 TEXT DEFAULT ''",
    ]) {
      try {
        await db.execute(col);
      } catch (_) {
        // 이미 추가된 경우 무시
      }
    }
    try {
      await db.execute('DROP TABLE IF EXISTS report_supplement_history');
    } catch (_) {}
  }

  static Future<void> _addGeoColumns(DatabaseExecutor db) async {
    for (final col in const [
      "ALTER TABLE reports ADD COLUMN 주소정규화 TEXT DEFAULT ''",
      "ALTER TABLE reports ADD COLUMN 행정구역 TEXT DEFAULT ''",
      "ALTER TABLE reports ADD COLUMN 위도 REAL",
      "ALTER TABLE reports ADD COLUMN 경도 REAL",
      "ALTER TABLE reports ADD COLUMN 지오코딩상태 TEXT DEFAULT ''",
    ]) {
      try {
        await db.execute(col);
      } catch (_) {
        // 이미 추가된 경우 무시
      }
    }
  }

  static Future<void> _migrateLocalDatabase(
    Database db,
    int oldV,
    int newV,
  ) async {
    if (oldV < 4) {
      try {
        await db.execute("ALTER TABLE reports ADD COLUMN 별점 INTEGER");
        await db.execute("ALTER TABLE reports ADD COLUMN 별점사유 TEXT DEFAULT ''");
      } catch (_) {
        // 이미 컬럼이 있는 경우 무시
      }
    }
    if (oldV < 5) {
      await _createRawTable(db);
      await _migrateRawContentToSidecar(db);
    }
    if (oldV < 6) {
      await DuplicateProjectionService.createSchema(db);
    }
    if (oldV < 7) {
      await DuplicateProjectionService.createSchema(db);
    }
    if (oldV < 9) {
      await _addSupplementColumns(db);
    }
    if (oldV < 10) {
      await _addGeoColumns(db);
      await _createGeocodeCacheTable(db);
    }
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
        별점             INTEGER,
        별점사유          TEXT DEFAULT '',
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
        주소정규화        TEXT DEFAULT '',
        행정구역          TEXT DEFAULT '',
        위도             REAL,
        경도             REAL,
        지오코딩상태      TEXT DEFAULT '',
        종결여부          TEXT DEFAULT 'N',
        신고내용          TEXT,
        처리내용          TEXT,
        지도             TEXT,
        첨부사진          TEXT,
        첨부파일          TEXT,
        category        TEXT,
        entry_value     TEXT DEFAULT '',
        raw_content     TEXT DEFAULT '',
        synced_at       INTEGER,
        보완횟수         INTEGER DEFAULT 0,
        보완_미응답      TEXT DEFAULT 'N',
        보완_요청자      TEXT DEFAULT '',
        보완_요청일시    TEXT DEFAULT '',
        보완_완료일시    TEXT DEFAULT '',
        보완_요청_내용   TEXT DEFAULT '',
        보완_신고자_의견 TEXT DEFAULT ''
      )
    ''');
    await _createRawTable(db);
    await _createGeocodeCacheTable(db);
    await DuplicateProjectionService.createSchema(db);
    await db.execute('''
      CREATE TABLE sync_meta (
        key   TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  static Future<void> _createRawTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS report_raw (
        ID          TEXT PRIMARY KEY,
        raw_content TEXT NOT NULL DEFAULT '',
        raw_type    TEXT NOT NULL DEFAULT '',
        saved_at    INTEGER
      )
    ''');
  }

  static Future<void> _createGeocodeCacheTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS geocode_cache (
        주소정규화 TEXT PRIMARY KEY,
        원본주소   TEXT,
        행정구역   TEXT,
        위도      REAL,
        경도      REAL,
        상태      TEXT NOT NULL DEFAULT '',
        source    TEXT NOT NULL DEFAULT 'kakao',
        error_message TEXT DEFAULT '',
        updated_at INTEGER
      )
    ''');
  }

  static Future<void> _migrateRawContentToSidecar(Database db) async {
    try {
      await db.execute('''
        INSERT OR REPLACE INTO report_raw (ID, raw_content, raw_type, saved_at)
        SELECT ID, raw_content, '', synced_at
        FROM reports
        WHERE raw_content IS NOT NULL AND raw_content != ''
      ''');
      await db.execute(
        "UPDATE reports SET raw_content = '' WHERE raw_content IS NOT NULL AND raw_content != ''",
      );
    } catch (_) {
      // report_raw migration best-effort
    }
  }

  static int? _toEpochMillis(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    if (value is String) {
      if (value.trim().isEmpty) return null;
      return int.tryParse(value) ?? double.tryParse(value)?.toInt();
    }
    return null;
  }

  static String _stringify(dynamic value) => value?.toString() ?? '';

  static Future<Map<String, dynamic>?> _getRawPayload(
    DatabaseExecutor db,
    String reportId,
  ) async {
    final rows = await db.query(
      'report_raw',
      where: 'ID = ?',
      whereArgs: [reportId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> _replaceRawPayload(
    DatabaseExecutor db,
    String reportId, {
    required String rawContent,
    String rawType = '',
    int? savedAt,
  }) async {
    if (reportId.isEmpty) return;
    if (rawContent.isEmpty) {
      await db.delete('report_raw', where: 'ID = ?', whereArgs: [reportId]);
      return;
    }
    await db.insert('report_raw', {
      'ID': reportId,
      'raw_content': rawContent,
      'raw_type': rawType,
      'saved_at': savedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static bool _rowsEqual(
    Map<String, Object?> left,
    Map<String, Object?> right,
  ) {
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (_stringify(left[key]) != _stringify(right[key])) {
        return false;
      }
    }
    return true;
  }

  static const _kProjectRowsCacheLimit = 16;
  static final Map<String, List<Map<String, dynamic>>> _projectRowsCache = {};
  static void _invalidateProjectRowsCache() => _projectRowsCache.clear();

  static String _buildProjectRowsCacheKey(
    List<Map<String, dynamic>> rows,
    bool useRepresentativeRecords,
    int projectionVersion,
  ) {
    var signature = rows.length;
    for (final row in rows) {
      signature = Object.hash(
        signature,
        row['ID']?.toString() ?? '',
        row['synced_at'],
        row['신고일']?.toString() ?? '',
        row['신고번호']?.toString() ?? '',
        row['감시목록']?.toString() ?? '',
        row['위반장소']?.toString() ?? '',
        row['차량번호']?.toString() ?? '',
        row['처리기관']?.toString() ?? '',
        row['담당자']?.toString() ?? '',
        row['위반법규']?.toString() ?? '',
        row['category']?.toString() ?? '',
        row['entry_value']?.toString() ?? '',
        row['범칙금_과태료']?.toString() ?? '',
      );
    }
    return '${useRepresentativeRecords ? 1 : 0}|$projectionVersion|$signature';
  }

  static Future<int> _currentDuplicateProjectionVersion(
    DatabaseExecutor db,
  ) async {
    var version = 0;
    try {
      final rows = await db.rawQuery(
        'SELECT MAX(IFNULL(updated_at, 0)) AS v FROM ${DuplicateProjectionService.groupTable}',
      );
      version = int.tryParse(rows.first['v']?.toString() ?? '') ?? 0;
    } catch (_) {}
    try {
      final rows = await db.rawQuery(
        'SELECT MAX(IFNULL(updated_at, 0)) AS v FROM ${DuplicateProjectionService.memberTable}',
      );
      final memberVersion =
          int.tryParse(rows.first['v']?.toString() ?? '') ?? 0;
      if (memberVersion > version) version = memberVersion;
    } catch (_) {}
    return version;
  }

  static Future<List<Map<String, dynamic>>> _projectRows(
    DatabaseExecutor db,
    List<Map<String, dynamic>> rows, {
    required bool useRepresentativeRecords,
  }) async {
    final normalized = rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    if (normalized.isEmpty) return normalized;
    if (!useRepresentativeRecords) {
      return normalized;
    }

    final projectionVersion = await _currentDuplicateProjectionVersion(db);
    final cacheKey = _buildProjectRowsCacheKey(
      normalized,
      useRepresentativeRecords,
      projectionVersion,
    );
    final cached = _projectRowsCache[cacheKey];
    if (cached != null) {
      return cached.map((row) => Map<String, dynamic>.from(row)).toList();
    }

    if (_projectRowsCache.length >= _kProjectRowsCacheLimit) {
      _projectRowsCache.clear();
    }

    final projected = await DuplicateProjectionService.projectReportRows(
      db,
      normalized,
      useRepresentativeRecords: useRepresentativeRecords,
    );
    _projectRowsCache[cacheKey] = projected
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    return projected.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  static const _syncedAtTrackedKeys = <String>[
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
    'category',
    'entry_value',
    '보완횟수',
    '보완_미응답',
    '보완_요청자',
    '보완_요청일시',
    '보완_완료일시',
    '보완_요청_내용',
    '보완_신고자_의견',
  ];

  // ── 신고 저장/업데이트 ─────────────────────────────────────────────────────

  static Future<void> upsertReport(
    Report r,
    String category,
    String entryValue, {
    String rawContent = '',
  }) async {
    final watchlistNums = await getWatchlistNumbers();
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic>? existingRecord;
    try {
      final existingRows = await d.query(
        'reports',
        where: 'ID = ?',
        whereArgs: [r.id],
        limit: 1,
      );
      if (existingRows.isNotEmpty) {
        existingRecord = Map<String, dynamic>.from(existingRows.first);
      }
    } catch (_) {}
    final geoPayload = prepareGeoPayloadForAddress(
      r.location,
      existingRecord: existingRecord,
    );
    final reportRow = <String, Object?>{
      'ID': r.id,
      '상태': r.result,
      '신고번호': r.reportNumber,
      '신고명': r.name,
      '신고일': r.date,
      '만족도조사여부': r.pollStatus,
      '별점': r.rating,
      '별점사유': r.ratingCause,
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
      '주소정규화': geoPayload['주소정규화'],
      '행정구역': geoPayload['행정구역'],
      '위도': geoPayload['위도'],
      '경도': geoPayload['경도'],
      '지오코딩상태': geoPayload['지오코딩상태'],
      '종결여부': r.processingFinish,
      '신고내용': r.reportContent,
      '처리내용': r.processContent,
      '지도': r.mapImage,
      '첨부사진': r.attachedPhotos,
      '첨부파일': r.attachedFiles,
      'category': category,
      'entry_value': entryValue,
      'raw_content': '',
      '보완횟수': r.supplementCount,
      '보완_미응답': r.supplementOpen ? 'Y' : 'N',
      '보완_요청자': r.supplementRequester,
      '보완_요청일시': r.supplementRequestedAt,
      '보완_완료일시': r.supplementCompletedAt,
      '보완_요청_내용': r.supplementRequest,
      '보완_신고자_의견': r.supplementOpinion,
    };

    await d.transaction((txn) async {
      final existingRows = await txn.query(
        'reports',
        where: 'ID = ?',
        whereArgs: [r.id],
        limit: 1,
      );
      final existingRaw = await _getRawPayload(txn, r.id);

      int syncedAt = now;
      if (existingRows.isNotEmpty) {
        final existing = Map<String, Object?>.from(existingRows.first);
        final existingComparable = <String, Object?>{};
        final reportComparable = <String, Object?>{};
        for (final key in _syncedAtTrackedKeys) {
          existingComparable[key] = existing[key];
          reportComparable[key] = reportRow[key];
        }
        final reportChanged = !_rowsEqual(existingComparable, reportComparable);
        final rawChanged =
            _stringify(existingRaw?['raw_content']) != _stringify(rawContent);
        syncedAt = (!reportChanged && !rawChanged)
            ? (_toEpochMillis(existing['synced_at']) ?? now)
            : now;
      }

      await txn.insert('reports', {
        ...reportRow,
        'synced_at': syncedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _replaceRawPayload(
        txn,
        r.id,
        rawContent: rawContent,
        savedAt: syncedAt,
      );
    });
    _invalidateProjectRowsCache();
  }

  // ── 신고 조회 ─────────────────────────────────────────────────────────────

  static Future<List<Report>> getReportsByCategory(
    String category, {
    bool excludeWithdraw = false,
    bool normalizePolice = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    var where = 'category = ?';
    final args = <dynamic>[category];
    if (excludeWithdraw) {
      where += " AND 처리상태 != '취하'";
    }
    final rows = await d.query(
      'reports',
      where: where,
      whereArgs: args,
      orderBy: '신고일 DESC',
    );
    final projected = await _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );
    projected.sort(
      (left, right) =>
          _stringify(right['신고번호']).compareTo(_stringify(left['신고번호'])),
    );
    return projected
        .map((r) => _rowToReport(r, normalizePolice: normalizePolice))
        .toList();
  }

  static Future<List<Report>> getAllReports({
    bool excludeWithdraw = false,
    bool normalizePolice = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    final rows = await d.query(
      'reports',
      where: excludeWithdraw ? "처리상태 != '취하'" : null,
      orderBy: '신고일 DESC',
    );
    final projected = await _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );
    projected.sort(
      (left, right) =>
          _stringify(right['신고번호']).compareTo(_stringify(left['신고번호'])),
    );
    return projected
        .map((r) => _rowToReport(r, normalizePolice: normalizePolice))
        .toList();
  }

  static Future<Report?> getReport(String cNo) async {
    final d = await db;
    final rows = await d.query('reports', where: 'ID = ?', whereArgs: [cNo]);
    return rows.isEmpty ? null : _rowToReport(rows.first);
  }

  /// 신고번호(STTEMNT_NO, SPP-...)로 DB 조회. 단건 자동 sync 용.
  static Future<Report?> getReportByNumber(String reportNumber) async {
    final d = await db;
    final rows = await d.query(
      'reports',
      where: '신고번호 = ?',
      whereArgs: [reportNumber],
      limit: 1,
    );
    return rows.isEmpty ? null : _rowToReport(rows.first);
  }

  static Future<void> updateReportRatingByNumber(
    String reportNumber, {
    required String pollStatus,
    int? rating,
    String? ratingCause,
  }) async {
    final d = await db;
    final values = <String, Object?>{'만족도조사여부': pollStatus};
    if (rating != null) values['별점'] = rating;
    if (ratingCause != null) values['별점사유'] = ratingCause;
    await d.update(
      'reports',
      values,
      where: '신고번호 = ?',
      whereArgs: [reportNumber],
    );
  }

  static Future<int> getTotalCount() async {
    final d = await db;
    final r = await d.rawQuery('SELECT COUNT(*) as cnt FROM reports');
    return (r.first['cnt'] as int?) ?? 0;
  }

  // ── 동기화 메타 ───────────────────────────────────────────────────────────

  static Future<void> setMeta(String key, String value) async {
    final d = await db;
    await d.insert('sync_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String?> getMeta(String key) async {
    final d = await db;
    final rows = await d.query('sync_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  // ── 대시보드 요약 ─────────────────────────────────────────────────────────

  static Future<DashboardStats> computeSummary({
    bool excludeWithdraw = false,
    bool normalizePolice = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    final rows = await _projectRows(
      d,
      await d.query('reports'),
      useRepresentativeRecords: useRepresentativeRecords,
    );

    int accept = 0,
        partial = 0,
        reject = 0,
        supplement = 0,
        processing = 0,
        completed = 0,
        withdraw = 0;
    int tFine = 0, tPenalty = 0, tReject = 0, tUnconfirmed = 0;

    // 서버 get_dashboard_stats 로직과 정확히 동일
    for (final r in rows) {
      final status = r['처리상태'] as String? ?? '';
      final cat = r['category'] as String? ?? '';
      final fine = r['범칙금_과태료'] as String? ?? '';

      if (status == '수용') accept++;
      if (status == '일부수용') partial++;
      if (status == '불수용' || status == '기타') reject++;
      if (status == '보완요청') supplement++;
      if (status == '처리중' ||
          status == '진행' ||
          status == '진행중' ||
          status == '검토중') {
        processing++;
      }
      if (['수용', '불수용', '일부수용', '기타', '답변완료'].contains(status)) completed++;
      if (status == '취하') withdraw++;

      if (cat == 'traffic') {
        if (fine.contains('과태료')) tFine++;
        if (fine.contains('경고') || fine.contains('범칙금')) tPenalty++;
        if (status == '불수용' || status == '기타') tReject++;
        if (fine == '미확인' && status != '불수용' && status != '기타') tUnconfirmed++;
      }
    }

    // 최근 답변: 서버 get_dashboard_stats 와 동일하게 답변일이 최근 3일 이내인
    // 항목만 골라온다 (취하 제외 옵션도 함께 반영). 한도는 서버와 같이 200건.
    final today = DateTime.now();
    final threeDaysAgo = today.subtract(const Duration(days: 3));
    String two(int v) => v.toString().padLeft(2, '0');
    String fmtDate(DateTime t) => '${t.year}-${two(t.month)}-${two(t.day)}';
    final lowerBound = fmtDate(threeDaysAgo);
    final upperBound = '${fmtDate(today)} 99';
    final recentRows =
        rows.where((row) {
          final status = _stringify(row['처리상태']);
          if (!const {'수용', '일부수용', '불수용', '기타', '답변완료'}.contains(status)) {
            return false;
          }
          if (excludeWithdraw && status == '취하') return false;
          final responseDate = _stringify(row['답변일']);
          if (responseDate.isEmpty) return false;
          return responseDate.compareTo(lowerBound) >= 0 &&
              responseDate.compareTo(upperBound) <= 0;
        }).toList()..sort((left, right) {
          final leftSynced = _toEpochMillis(left['synced_at']) ?? -1;
          final rightSynced = _toEpochMillis(right['synced_at']) ?? -1;
          if (leftSynced != rightSynced) {
            return rightSynced.compareTo(leftSynced);
          }
          final leftAnswer = _stringify(left['답변일']);
          final rightAnswer = _stringify(right['답변일']);
          final answerComp = rightAnswer.compareTo(leftAnswer);
          if (answerComp != 0) return answerComp;
          return _stringify(right['신고번호']).compareTo(_stringify(left['신고번호']));
        });

    final watchlistRows =
        rows.where((row) {
          if (_stringify(row['감시목록']) != 'Y') return false;
          if (excludeWithdraw && _stringify(row['처리상태']) == '취하') {
            return false;
          }
          return true;
        }).toList()..sort(
          (left, right) =>
              _stringify(right['신고번호']).compareTo(_stringify(left['신고번호'])),
        );

    final lastSync = await getMeta('last_sync') ?? '';

    final effectiveWithdraw = excludeWithdraw ? 0 : withdraw;

    return DashboardStats(
      lastCrawlTime: lastSync,
      total: rows.length,
      acceptCount: accept,
      partialCount: partial,
      rejectCount: reject,
      supplementCount: supplement,
      processingCount: processing,
      completedCount: completed,
      withdrawCount: withdraw,
      withdrawRawCount: withdraw,
      withdrawGraphCount: effectiveWithdraw,
      tFineCount: tFine,
      tPenaltyCount: tPenalty,
      tRejectCount: tReject,
      tUnconfirmedCount: tUnconfirmed,
      recentAnswers: recentRows
          .take(200)
          .map((r) => _rowToReport(r, normalizePolice: normalizePolice))
          .toList(),
      watchlist: watchlistRows
          .map((r) => _rowToReport(r, normalizePolice: normalizePolice))
          .toList(),
      excludeWithdraw: excludeWithdraw,
    );
  }

  // ── 통계 집계 ─────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> computeStats({
    String? year,
    String? law,
    bool excludeWithdraw = false,
    bool normalizePolice = false,
    bool useRepresentativeRecords = false,
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
    if (excludeWithdraw) {
      where += " AND 처리상태 != '취하'";
    }

    var rows = await d.query(
      'reports',
      where: where,
      whereArgs: args.isEmpty ? null : args,
    );
    rows = await _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );

    // 필터와 무관하게 전체에서 available_years/laws 추출
    // (취하 제외는 available_years/laws에는 영향 안 줌 — 서버도 동일)
    var allRows = await d.query(
      'reports',
      columns: ['신고일', '위반법규', 'category'],
    );
    return _aggregateStats(rows, allRows, normalizePolice);
  }

  static Future<Map<String, dynamic>> computeReportMapStats({
    String? year,
    String category = 'all',
    bool excludeWithdraw = false,
    bool normalizePolice = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    final normalizedCategory = _normalizeMapCategory(category);

    String where = '1=1';
    final args = <dynamic>[];
    if (normalizedCategory != 'all') {
      where += ' AND category = ?';
      args.add(normalizedCategory);
    }
    if (year != null && year != 'all' && year.isNotEmpty) {
      where += ' AND 신고일 LIKE ?';
      args.add('$year%');
    }
    if (excludeWithdraw) {
      where += " AND 처리상태 != '취하'";
    }

    var rows = await d.query(
      'reports',
      columns: [
        'ID',
        '위반장소',
        '주소정규화',
        '행정구역',
        '위도',
        '경도',
        '지오코딩상태',
        '처리상태',
        '범칙금_과태료',
        '처리기관',
        'category',
        '신고일',
      ],
      where: where,
      whereArgs: args.isEmpty ? null : args,
    );
    rows = await _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );

    var allYearRows = await d.query('reports', columns: ['신고일']);
    final availableYears =
        allYearRows
            .map((row) => _stringify(row['신고일']))
            .where((value) => value.length >= 4)
            .map((value) => value.substring(0, 4))
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));

    if (rows.isEmpty) {
      return {
        'points': const <Map<String, dynamic>>[],
        'meta': {
          'available_years': availableYears,
          'current_year': year ?? 'all',
          'selected_category': normalizedCategory,
          'dedupe_mode': useRepresentativeRecords ? 'canonical' : 'raw',
          'total_reports': 0,
          'geocoded_reports': 0,
          'missing_reports': 0,
          'address_groups': 0,
        },
      };
    }

    final pointsByKey = <String, List<Map<String, dynamic>>>{};
    var geocodedReports = 0;
    var missingReports = 0;

    for (final rawRow in rows) {
      final row = Map<String, dynamic>.from(rawRow);
      final lat = parseGeoDouble(row['위도']);
      final lng = parseGeoDouble(row['경도']);
      final normalizedAddress =
          normalizeGeocodeAddress(row['주소정규화']?.toString()) == ''
          ? normalizeGeocodeAddress(row['위반장소']?.toString())
          : normalizeGeocodeAddress(row['주소정규화']?.toString());
      final address = _stringify(row['위반장소']).trim();
      if (lat == null || lng == null || normalizedAddress.isEmpty) {
        if (address.isNotEmpty) {
          missingReports++;
        }
        continue;
      }
      geocodedReports++;
      if (normalizePolice) {
        row['처리기관'] = normalizePoliceAgency(_stringify(row['처리기관']));
      }
      row['위도'] = lat;
      row['경도'] = lng;
      row['주소정규화'] = normalizedAddress;
      final key = '$lat|$lng|$normalizedAddress';
      pointsByKey.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(row);
    }

    final points = <Map<String, dynamic>>[];
    for (final group in pointsByKey.values) {
      final first = group.first;
      final total = group.length;
      final categoryCounts = <String, int>{};
      for (final item in group) {
        final itemCategory = _stringify(item['category']).trim();
        if (itemCategory.isEmpty) continue;
        categoryCounts[itemCategory] = (categoryCounts[itemCategory] ?? 0) + 1;
      }

      points.add({
        'lat': first['위도'],
        'lng': first['경도'],
        'address':
            _firstNonEmptyMapValue(group, '위반장소') ??
            _firstNonEmptyMapValue(group, '주소정규화') ??
            '',
        'region':
            _firstNonEmptyMapValue(group, '행정구역') ??
            _firstNonEmptyMapValue(group, '위반장소') ??
            '',
        'total': total,
        'status_breakdown': _buildMapStatusBreakdown(group),
        'disposition_breakdown': _buildMapDispositionBreakdown(group),
        'agency_breakdown': _buildMapAgencyBreakdown(group),
        'category_breakdown': [
          _buildMapRatioItem('교통위반', categoryCounts['traffic'] ?? 0, total),
          _buildMapRatioItem('주정차위반', categoryCounts['parking'] ?? 0, total),
          _buildMapRatioItem('기타위반', categoryCounts['other'] ?? 0, total),
        ].where((item) => (item['count'] as int) > 0).toList(),
      });
    }

    points.sort(
      (left, right) => (right['total'] as int).compareTo(left['total'] as int),
    );

    return {
      'points': points,
      'meta': {
        'available_years': availableYears,
        'current_year': year ?? 'all',
        'selected_category': normalizedCategory,
        'dedupe_mode': useRepresentativeRecords ? 'canonical' : 'raw',
        'total_reports': rows.length,
        'geocoded_reports': geocodedReports,
        'missing_reports': missingReports,
        'address_groups': points.length,
      },
    };
  }

  static String _normalizeMapCategory(String value) {
    final normalized = value.trim().toLowerCase();
    return {'all', 'traffic', 'parking', 'other'}.contains(normalized)
        ? normalized
        : 'all';
  }

  static Map<String, dynamic> _buildMapRatioItem(
    String label,
    int count,
    int total,
  ) {
    final safeCount = count < 0 ? 0 : count;
    final safeTotal = total < 0 ? 0 : total;
    return {
      'label': label,
      'count': safeCount,
      'pct': safeTotal > 0
          ? double.parse(((safeCount / safeTotal) * 100).toStringAsFixed(1))
          : 0.0,
    };
  }

  static List<Map<String, dynamic>> _buildMapStatusBreakdown(
    List<Map<String, dynamic>> group,
  ) {
    final statuses = group
        .map((row) => _stringify(row['처리상태']).trim())
        .toList();
    final total = group.length;
    final processingCount = statuses
        .where((value) => {'', '진행', '진행중', '검토중', '처리중'}.contains(value))
        .length;
    final ordered = [
      _buildMapRatioItem(
        '수용',
        statuses.where((value) => value == '수용').length,
        total,
      ),
      _buildMapRatioItem(
        '일부수용',
        statuses.where((value) => value == '일부수용').length,
        total,
      ),
      _buildMapRatioItem(
        '불수용',
        statuses.where((value) => value == '불수용').length,
        total,
      ),
      _buildMapRatioItem(
        '기타',
        statuses.where((value) => value == '기타').length,
        total,
      ),
      _buildMapRatioItem(
        '답변완료',
        statuses.where((value) => value == '답변완료').length,
        total,
      ),
      _buildMapRatioItem(
        '보완요청',
        statuses.where((value) => value == '보완요청').length,
        total,
      ),
      _buildMapRatioItem('처리중', processingCount, total),
      _buildMapRatioItem(
        '취하',
        statuses.where((value) => value == '취하').length,
        total,
      ),
      _buildMapRatioItem(
        '이송',
        statuses.where((value) => value == '이송').length,
        total,
      ),
    ];
    return ordered.where((item) => (item['count'] as int) > 0).toList();
  }

  static List<Map<String, dynamic>> _buildMapDispositionBreakdown(
    List<Map<String, dynamic>> group,
  ) {
    final total = group.length;
    final fineCount = group
        .where((row) => _stringify(row['범칙금_과태료']).contains('과태료'))
        .length;
    final warningCount = group.where((row) {
      final text = _stringify(row['범칙금_과태료']);
      return text.contains('경고') || text.contains('범칙금');
    }).length;
    final rejectCount = group.where((row) {
      final status = _stringify(row['처리상태']);
      return status == '불수용' || status == '기타';
    }).length;
    final pendingCount = total - fineCount - warningCount - rejectCount;
    final ordered = [
      _buildMapRatioItem('과태료', fineCount, total),
      _buildMapRatioItem('경고/범칙금', warningCount, total),
      _buildMapRatioItem('불수용/기타', rejectCount, total),
      _buildMapRatioItem('기타/미확인', pendingCount, total),
    ];
    return ordered.where((item) => (item['count'] as int) > 0).toList();
  }

  static List<Map<String, dynamic>> _buildMapAgencyBreakdown(
    List<Map<String, dynamic>> group,
  ) {
    final counts = <String, int>{};
    for (final row in group) {
      final name = _stringify(row['처리기관']).trim();
      if (name.isEmpty) continue;
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final total = group.length;
    final items =
        counts.entries
            .map(
              (entry) => {
                'name': entry.key,
                'count': entry.value,
                'pct': total > 0
                    ? double.parse(
                        ((entry.value / total) * 100).toStringAsFixed(1),
                      )
                    : 0.0,
              },
            )
            .toList()
          ..sort(
            (left, right) =>
                (right['count'] as int).compareTo(left['count'] as int),
          );
    return items;
  }

  static String? _firstNonEmptyMapValue(
    List<Map<String, dynamic>> group,
    String column,
  ) {
    for (final row in group) {
      final value = _stringify(row[column]).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static Map<String, dynamic> _aggregateStats(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> allRows,
    bool normalizePolice,
  ) {
    final traffic = rows.where((r) => r['category'] == 'traffic').toList();
    final parking = rows.where((r) => r['category'] == 'parking').toList();
    final other = rows.where((r) => r['category'] == 'other').toList();

    // 연도 목록은 항상 전체에서 추출 (필터 변경 시 다른 연도 선택지 유지)
    final years =
        allRows
            .map(
              (r) => (r['신고일'] as String? ?? '').length >= 4
                  ? (r['신고일'] as String).substring(0, 4)
                  : '',
            )
            .where((y) => y.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));

    return {
      'traffic': _buildCategory(
        traffic,
        allRows.where((r) => r['category'] == 'traffic').toList(),
        normalizePolice,
      ),
      'parking': _buildCategory(
        parking,
        allRows.where((r) => r['category'] == 'parking').toList(),
        normalizePolice,
      ),
      'other': _buildCategory(
        other,
        allRows.where((r) => r['category'] == 'other').toList(),
        normalizePolice,
      ),
      'available_years': years,
    };
  }

  static Map<String, dynamic> _buildCategory(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> allCatRows,
    bool normalizePolice,
  ) {
    // 경찰기관 정규화: 집계 키 단계에서 처리해 같은 경찰서로 통합
    String agencyKey(String raw) {
      final t = raw.trim();
      if (!normalizePolice) return t;
      return normalizePoliceAgency(t);
    }

    final agencyAgg = <String, _AgencyAgg>{};
    for (final r in rows) {
      final key = agencyKey((r['처리기관'] as String? ?? ''));
      if (key.isEmpty) continue;
      agencyAgg.putIfAbsent(key, () => _AgencyAgg(key, ''));
      agencyAgg[key]!.add(r);
    }

    final allAgency = agencyAgg.values.map((a) => a.toJson()).toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

    final personAgg = <String, _AgencyAgg>{};
    for (final r in rows) {
      final agency = agencyKey((r['처리기관'] as String? ?? ''));
      final manager = (r['담당자'] as String? ?? '').trim();
      final status = (r['처리상태'] as String? ?? '');
      if ((manager.isEmpty) &&
          (status == '처리중' ||
              status == '진행' ||
              status == '진행중' ||
              status == '검토중' ||
              status == '취하')) {
        continue;
      }
      if (agency.isEmpty) continue;
      final key = '$agency\t$manager';
      personAgg.putIfAbsent(key, () => _AgencyAgg(agency, manager));
      personAgg[key]!.add(r);
    }

    final allPerson = personAgg.values.map((a) => a.toJson()).toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

    final policeAgency = allAgency
        .where((r) => (r['agency'] as String).contains('경찰'))
        .toList();
    final nonPoliceAgency = allAgency
        .where((r) => !(r['agency'] as String).contains('경찰'))
        .toList();
    final policePerson = allPerson
        .where((r) => (r['agency'] as String).contains('경찰'))
        .toList();
    final nonPolicePerson = allPerson
        .where((r) => !(r['agency'] as String).contains('경찰'))
        .toList();

    // 법규 목록은 카테고리 전체에서 추출 (필터 변경 시 다른 법규 선택지 유지)
    final allLaws =
        allCatRows
            .map((r) => r['위반법규'] as String? ?? '')
            .where((l) => l.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final hasEmptyLaw = allCatRows.any(
      (r) => (r['위반법규'] as String? ?? '').isEmpty,
    );

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

  /// 중복차량 — 서버 get_duplicate_records 와 동일 로직.
  ///
  /// 차량별 그룹의 모든 신고를 보여주되, 최근 신고가 있는 그룹부터 위로 오도록 정렬.
  /// 같은 차량끼리 붙어 보이도록 그룹 내에서는 신고번호 역순.
  ///
  /// 정렬 키 (서버 동일):
  ///   1. 그룹의 최근신고번호 DESC  → 최근 신고가 있는 차량 그룹이 위
  ///   2. 차량번호 ASC              → 같은 차량 행끼리 묶임
  ///   3. 개별 신고번호 DESC        → 그룹 내에서 최신 신고 우선
  ///
  /// excludeWithdraw 적용 후 단 1건만 남는 차량은 '중복' 의미가 없어 제외.
  static Future<List<Report>> getDuplicateVehicleReports({
    bool excludeWithdraw = false,
    bool normalizePolice = false,
  }) async {
    final d = await db;
    final withdrawFilter = excludeWithdraw ? "AND 처리상태 != '취하'" : '';
    final rows = await d.rawQuery('''
      WITH dup_vehicles AS (
        SELECT 차량번호,
               COUNT(*)                                                 AS total_count,
               SUM(CASE WHEN 처리상태 != '취하' THEN 1 ELSE 0 END)        AS valid_count,
               MAX(신고번호)                                              AS max_report_no
        FROM reports
        WHERE 차량번호 != '' $withdrawFilter
        GROUP BY 차량번호
        HAVING COUNT(*) >= 2
      )
      SELECT r.*,
             dv.total_count,
             dv.valid_count
      FROM reports r
      INNER JOIN dup_vehicles dv ON r.차량번호 = dv.차량번호
      WHERE r.차량번호 != '' $withdrawFilter
      ORDER BY dv.max_report_no DESC, r.차량번호 ASC, r.신고번호 DESC
    ''');
    return rows
        .map((r) => _rowToReportWithCounts(r, normalizePolice: normalizePolice))
        .toList();
  }

  static Report _rowToReportWithCounts(
    Map<String, dynamic> r, {
    bool normalizePolice = false,
  }) {
    var agency = r['처리기관'] as String? ?? '';
    if (normalizePolice) agency = normalizePoliceAgency(agency);
    return Report(
      id: r['ID'] as String? ?? '',
      reportNumber: r['신고번호'] as String? ?? '',
      name: r['신고명'] as String? ?? '',
      date: r['신고일'] as String? ?? '',
      responseDate: r['답변일'] as String? ?? '',
      agency: agency,
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
      rating: (r['별점'] as num?)?.toInt(),
      ratingCause: r['별점사유'] as String? ?? '',
      totalCount: (r['total_count'] as num?)?.toInt() ?? 0,
      validCount: (r['valid_count'] as num?)?.toInt() ?? 0,
      category: r['category'] as String? ?? '',
      syncedAt: _toEpochMillis(r['synced_at']),
      supplementCount: (r['보완횟수'] as num?)?.toInt() ?? 0,
      supplementOpen: (r['보완_미응답'] as String? ?? 'N') == 'Y',
      supplementRequester: r['보완_요청자'] as String? ?? '',
      supplementRequestedAt: r['보완_요청일시'] as String? ?? '',
      supplementCompletedAt: r['보완_완료일시'] as String? ?? '',
      supplementRequest: r['보완_요청_내용'] as String? ?? '',
      supplementOpinion: r['보완_신고자_의견'] as String? ?? '',
    );
  }

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
    _invalidateProjectRowsCache();
  }

  static Future<List<Report>> getWatchlistReports({
    bool excludeWithdraw = false,
    bool normalizePolice = false,
    bool useRepresentativeRecords = false,
  }) async {
    final numbers = await getWatchlistNumbers();
    if (numbers.isEmpty) return [];
    final d = await db;
    final placeholders = numbers.map((_) => '?').join(',');
    final withdrawFilter = excludeWithdraw ? " AND 처리상태 != '취하'" : '';
    final rows = await d.rawQuery(
      'SELECT * FROM reports WHERE 신고번호 IN ($placeholders)$withdrawFilter ORDER BY 신고일 DESC',
      numbers.toList(),
    );
    final projected = await _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );
    projected.sort(
      (left, right) =>
          _stringify(right['신고번호']).compareTo(_stringify(left['신고번호'])),
    );
    return projected
        .map((r) => _rowToReport(r, normalizePolice: normalizePolice))
        .toList();
  }

  // ── 검색 ─────────────────────────────────────────────────────────────────

  static Future<List<Report>> searchReports(
    String query, {
    bool excludeWithdraw = false,
    bool normalizePolice = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    final q = '%$query%';
    var where =
        '(신고명 LIKE ? OR 신고번호 LIKE ? OR 차량번호 LIKE ? OR 처리기관 LIKE ? OR 위반법규 LIKE ?)';
    final args = <dynamic>[q, q, q, q, q];
    if (excludeWithdraw) {
      where += " AND 처리상태 != '취하'";
    }
    final rows = await d.query(
      'reports',
      where: where,
      whereArgs: args,
      orderBy: '신고일 DESC',
    );
    final projected = await _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );
    projected.sort(
      (left, right) =>
          _stringify(right['신고번호']).compareTo(_stringify(left['신고번호'])),
    );
    return projected
        .map((r) => _rowToReport(r, normalizePolice: normalizePolice))
        .toList();
  }

  // ── 전체 삭제 ─────────────────────────────────────────────────────────────

  static Future<void> clearAll() async {
    final d = await db;
    _invalidateProjectRowsCache();
    await d.delete('report_raw');
    try {
      await d.delete('geocode_cache');
    } catch (_) {}
    try {
      await d.delete(DuplicateProjectionService.memberTable);
      await d.delete(DuplicateProjectionService.groupTable);
    } catch (_) {}
    await d.delete('reports');
    await d.delete('sync_meta');
  }

  /// Play Console 심사용 데모 데이터 3건을 로컬 DB에 시드한다.
  /// standalone demo/demo 또는 demo/demo/demo 계정에서 사용.
  static Future<void> seedPlayReviewDemo() async {
    _invalidateProjectRowsCache();
    await clearAll();
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    const watchlistNumber = 'SPP-2604-2344496';
    final seededAt = DateTime.now().toIso8601String();

    final rows = <Map<String, Object?>>[
      {
        'ID': '59578643',
        '상태': '답변완료',
        '신고번호': 'SPP-2604-2344496',
        '신고명': '중앙선 침범',
        '신고일': '2026-04-23',
        '만족도조사여부': '참여 완료',
        '별점': 5,
        '별점사유': '수고하십니다',
        '감시목록': 'Y',
        '처리상태': '수용',
        '차량번호': '경기부천라6830',
        '위반법규': '도로교통법 제13조3항',
        '범칙금_과태료': '과태료: 70,000원',
        '벌점': '',
        '처리기관': '경찰청 경기도남부경찰청 부천원미경찰서',
        '담당자': '장은형',
        '답변일': '2026-04-24',
        '발생일자': '2026-04-23',
        '발생시각': '17:45',
        '위반장소': '경기도 부천시 원미구 역곡동 257-2',
        '종결여부': 'Y',
        '신고내용': '전방 오토바이 한 대가 중앙선 침범유턴하여 신고합니다.',
        '처리내용':
            '안녕하십니까?\n교통법규위반 신고를 하여 주셔서 감사드리며\n귀하께서 제보해주신 영상자료를 확인한 결과,\n도로교통법 제13조3항 (통행구분 위반(중앙선 침범에 한함))를 위반한 사실이 확인되어,\n차량 소유주에게 위반행위에 따른 과태료 70,000원을 부과하고자\n‘과태료 부과 사전통지서’를 발송하였음을 알려드립니다.\n\n답변내용 중 궁금한 사항이나 이해가 가지 않는 내용이 있으실 경우\n부천원미경찰서 교통과 (☎ 032-680-7147)로\n문의하시면 자세하게 답변해 드리겠습니다.\n\n귀하의 가정에 건강과 안녕을 기원합니다.\n\n※ 다른 차량의 개인정보 보호를 위해, 신청번호 1건당 차량 1대만 단속 처리 할 수 있\n음을 양지 바랍니다.',
        '지도':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_cb69c49b3fca4cdc9cbd9fecd42ed5d8_MAPIMG.png',
        '첨부사진':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_1_08573e9674f1408f835666d249452340.png',
        '첨부파일':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_2_2056180c13204993a4d0f4338b8c20fc.mp4\nhttps://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_3_b67c8c3310fa4fdfada7b58950b203a9.mp4\nhttps://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_4_f4898241e7f546b48fd490b4e032dd6a.mp4',
        'category': 'traffic',
        'entry_value': '',
        'raw_content': '',
        'synced_at': now,
      },
      {
        'ID': '58700792',
        '상태': '답변완료',
        '신고번호': 'SPP-2604-0419411',
        '신고명': '친환경차 충전구역 불법주차 신고입니다.\n\n* 차량번호',
        '신고일': '2026-04-04',
        '만족도조사여부': '참여 완료',
        '별점': 5,
        '별점사유': '',
        '감시목록': 'N',
        '처리상태': '수용',
        '차량번호': '341소7346',
        '위반법규': '',
        '범칙금_과태료': '과태료',
        '벌점': '',
        '처리기관': '경기도 고양시 기후환경국 기후에너지과',
        '담당자': '장윤석',
        '답변일': '2026-04-10',
        '발생일자': '',
        '발생시각': '',
        '위반장소': '경기도 고양시 일산동구 호수로 595',
        '종결여부': 'Y',
        '신고내용': '친환경차 충전구역 불법주차 신고입니다.',
        '처리내용':
            '1. 선생님의 가정에 건강과 행운이 늘 함께 하시기를 기원합니다. \n2. 선생님께서 제기하신 &quot;친환경자동차 충전시설의 충전구역과 전용주차구역의 주차위반 및 충전방해 행위&quot; 민원에 대해 답변드리겠습니다.\n\n가. 선생님께서 신고해주신 자료를 확인한 결과 「환경친화적 자동차의 개발 및 보급 촉진에 관한 법률」 제11조의2 규정을 위반한 행위로 판단됩니다.\n나. 따라서 우리 시에서는 차적조회 후 해당 차량 소유자에게 과태료 처분 사전통지 및 의견청취 절차를 거칠 예정이며, 의견제출 기한 후 위반행위가 명백한 경우에는 과태료 부과를 진행할 예정임을 알려드립니다.\n\n3. 선생님의 질문에 만족스러운 답변이 되었기를 바라며, 국민신문고 민원처리 결과에 대한 만족도 조사를 실시하고 있사오니, 선생님의 소중한 시간을 내어 참여해 주시면 앞으로 시정 발전에 많은 도움이 될 것입니다. 만족도 조사 참여방법은 나의신문고-민원 신청결과 답변내용 아래 「만족도 평가하기」 버튼을 눌러 참여해 주시기 바랍니다.\n4. 기타 궁금하신 사항은 고양시청 기후에너지과 장윤석 주무관(☎031-8075-2813)에게 연락주시면 친절히 답변 드리겠습니다. 감사합니다.',
        '지도':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/04/20260404_d111734d51c849028200dbbc435ef1b2_MAPIMG.png',
        '첨부사진':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/04/20260404_1_026f028208514fe2915d428ee7ca5d9a.jpg\nhttps://www.safetyreport.go.kr/fileDown/singo/202604/04/20260404_2_cff99e2c881e4a1088a236bdfeba6257.jpg',
        '첨부파일': '',
        'category': 'parking',
        'entry_value': '',
        'raw_content': '',
        'synced_at': now,
      },
      {
        'ID': '59578555',
        '상태': '답변완료',
        '신고번호': 'SPP-2604-2344422',
        '신고명': '담배꽁초 투기',
        '신고일': '2026-04-23',
        '만족도조사여부': '참여 가능',
        '별점': null,
        '별점사유': '',
        '감시목록': 'N',
        '처리상태': '수용',
        '차량번호': '86보7665',
        '위반법규': '',
        '범칙금_과태료': '과태료',
        '벌점': '',
        '처리기관': '경기도 부천시 원미구 도시미관과',
        '담당자': '한대화',
        '답변일': '2026-04-24',
        '발생일자': '2026-04-23',
        '발생시각': '17:46',
        '위반장소': '경기도 부천시 원미구 역곡동 257-2',
        '종결여부': 'Y',
        '신고내용': '후면 영상 15초, 담배꽁초 버리는 다마스 신고합니다.',
        '처리내용':
            '1. 평소 시정에 많은 관심을 가져 주심에 진심으로 감사드립니다.\n2. 귀하께서 신청하신 민원(1AA-2604-1035550) ‘담배꽁초 무단투기 신고’ 영상자료를 검토한 결과, 「폐기물관리법」 제8조(폐기물의 투기 금지 등) 규정 위반행위가 확인됨에 따라 해당 차량 소유주에 과태료 부과 절차를 이행할 예정임을 알려드립니다. \n3. 신고포상금(6,000원)은 「부천시 폐기물 관리에 관한 조례」에 따라 위반행위 적발일로부터 14일 이내 신청할 수 있으며, 무단투기 신고포상금 지급 기준에 따라 예산 범위 내에서 지급됩니다. \n4. 또한, 포상금 신청을 원하실 경우 신청서 및 통장 사본을 이메일(story00323@korea.kr)로 제출하여 주시기 바라며, 포상금은 과태료 부과절차 이후 지급될 예정으로 30일 이상 소요됨을 참고하시기 바랍니다.\n5. 귀하의 질문에 만족스러운 답변이 되었기를 바라며, 답변 내용에 대한 추가 설명이 필요한 경우 원미구 도시미관과 주무관 한대화(☏032-625-5496)에게 연락주시면 친절히 안내해 드리도록 하겠습니다.  끝.',
        '지도':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_13caf3f3c245403c9a55323ef504d4d1_MAPIMG.png',
        '첨부사진':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_2_2daaa28ed220402daf792872c7fd5b54.png',
        '첨부파일':
            'https://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_1_75bf3964915043988c57318ebf9abd81.mp4\nhttps://www.safetyreport.go.kr/fileDown/singo/202604/23/20260423_3_1d5dcfd61cbd4445ae974a0fed3f5560.mp4',
        'category': 'other',
        'entry_value': '',
        'raw_content': '',
        'synced_at': now,
      },
    ];

    await d.transaction((txn) async {
      for (final row in rows) {
        await txn.insert(
          'reports',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.insert('sync_meta', {
        'key': 'last_sync',
        'value': seededAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('sync_meta', {
        'key': 'watchlist',
        'value': watchlistNumber,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await DuplicateProjectionService.refreshDuplicateGroups(d);
  }

  /// 업로드/선택된 .db 파일의 종류 판별.
  /// - server: mysafetymerge_* 계열 서버 DB
  /// - mobile: reports + category 컬럼을 가진 모바일 standalone DB
  /// - unknown: 알 수 없음
  static Future<String> detectDbKind(String dbPath) async {
    final src = File(dbPath);
    if (!src.existsSync()) return 'unknown';

    final preparedDbPath = await _prepareExternalDbSnapshot(dbPath);
    final extDb = await openDatabase(preparedDbPath, readOnly: true);
    try {
      final tables = await extDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final tableNames = tables
          .map((r) => r['name']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();

      if (tableNames.contains('reports') && !tableNames.contains('mysafety')) {
        try {
          final cols = await extDb.rawQuery("PRAGMA table_info(reports)");
          final colNames = cols
              .map((r) => r['name']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toSet();
          if (colNames.contains('category')) {
            return 'mobile';
          }
        } catch (_) {}
      }

      if (tableNames.contains('mysafety') &&
          (tableNames.contains('mysafetymerge_traffic') ||
              tableNames.contains('mysafetymerge_parking') ||
              tableNames.contains('mysafetymerge_other'))) {
        return 'server';
      }

      return 'unknown';
    } finally {
      await extDb.close();
      await _cleanupPreparedSnapshot(preparedDbPath);
    }
  }

  /// 현재 standalone DB를 백업 파일로 내보낸다.
  /// sqflite가 WAL을 사용할 수 있어 main .db만 그대로 복사하면 최신 변경이 누락될 수 있으므로
  /// 먼저 DB를 닫아 체크포인트/flush를 유도한 뒤 복사한다.
  static Future<void> exportBackup(String targetPath) async {
    await closeDb();
    final dbPath = await getDbPath();
    final src = File(dbPath);
    if (!src.existsSync()) {
      throw Exception('로컬 DB 파일이 존재하지 않습니다: $dbPath');
    }
    await src.copy(targetPath);
  }

  static Future<String> _prepareExternalDbSnapshot(String sourceDbPath) async {
    final src = File(sourceDbPath);
    if (!src.existsSync()) {
      throw Exception('DB 파일이 존재하지 않습니다: $sourceDbPath');
    }

    final tmpDir = await Directory.systemTemp.createTemp(
      'mysafetyreport_import_',
    );
    final preparedDbPath = join(tmpDir.path, basename(sourceDbPath));
    await src.copy(preparedDbPath);

    for (final ext in ['-wal', '-shm']) {
      final sidecar = File('$sourceDbPath$ext');
      if (!sidecar.existsSync()) continue;
      try {
        await sidecar.copy('$preparedDbPath$ext');
      } catch (_) {
        // content URI/권한 제한 등으로 sidecar 접근이 안 되면 복사 가능한 파일만 사용
      }
    }

    Database? preparedDb;
    try {
      preparedDb = await openDatabase(preparedDbPath);
      await preparedDb.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {
      // 이미 단일 스냅샷이면 그대로 사용
    } finally {
      await preparedDb?.close();
    }

    for (final ext in ['-wal', '-shm']) {
      final sidecar = File('$preparedDbPath$ext');
      if (!sidecar.existsSync()) continue;
      try {
        await sidecar.delete();
      } catch (_) {}
    }

    return preparedDbPath;
  }

  static Future<void> _cleanupPreparedSnapshot(String preparedDbPath) async {
    final dir = Directory(dirname(preparedDbPath));
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> _deleteDbSidecars(String dbPath) async {
    for (final ext in ['-wal', '-shm']) {
      final sidecar = File('$dbPath$ext');
      if (!sidecar.existsSync()) continue;
      try {
        await sidecar.delete();
      } catch (_) {}
    }
  }

  static Future<void> _commitImportedDatabase(String importedDbPath) async {
    final dbPath = await getDbPath();
    final target = File(dbPath);
    final imported = File(importedDbPath);
    final stagedCopyPath =
        '$dbPath.pending.${DateTime.now().millisecondsSinceEpoch}';
    final stagedCopy = File(stagedCopyPath);
    if (!imported.existsSync()) {
      throw Exception('임시 임포트 DB가 존재하지 않습니다.');
    }

    await closeDb();
    _invalidateProjectRowsCache();
    await _deleteDbSidecars(dbPath);

    final hadCurrentDb = await target.exists();
    String? backupPath;
    var replacementSucceeded = false;
    var restoreSucceeded = !hadCurrentDb;

    if (hadCurrentDb) {
      backupPath = '$dbPath.bak.${DateTime.now().millisecondsSinceEpoch}';
      await target.copy(backupPath);
    }

    try {
      await imported.copy(stagedCopyPath);
      if (hadCurrentDb && await target.exists()) {
        await target.delete();
      }
      await stagedCopy.rename(dbPath);
      replacementSucceeded = true;
    } catch (exc) {
      Object? restoreError;
      if (hadCurrentDb) {
        try {
          if (await target.exists()) {
            await target.delete();
          }
          if (backupPath != null) {
            await File(backupPath).copy(dbPath);
            restoreSucceeded = true;
          }
        } catch (restoreExc) {
          restoreError = restoreExc;
        }
      }
      if (restoreError != null) {
        throw Exception(
          '임포트 DB 교체에 실패했고 기존 DB 복구도 실패했습니다. '
          '백업 파일을 보존했습니다: ${backupPath ?? '없음'}. '
          '교체 오류: $exc / 복구 오류: $restoreError',
        );
      }
      throw Exception('임포트 DB 교체에 실패했습니다: $exc');
    } finally {
      try {
        await stagedCopy.delete();
      } catch (_) {}
      if (backupPath != null && (replacementSucceeded || restoreSucceeded)) {
        try {
          await File(backupPath).delete();
        } catch (_) {}
      }
    }
  }

  static Future<Database> _createImportTargetDb(String path) async {
    return openDatabase(
      path,
      version: 10,
      onCreate: _create,
      onUpgrade: _migrateLocalDatabase,
    );
  }

  static Future<void> _validateServerDbSchema(Database serverDb) async {
    final tableRows = await serverDb.rawQuery(
      'SELECT name FROM sqlite_master WHERE type = \'table\'',
    );
    final tableNames = tableRows
        .map((r) => r['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();

    if (!tableNames.contains('mysafety') ||
        !tableNames.contains('mysafetymerge_traffic')) {
      throw Exception('유효하지 않은 서버 DB 형식입니다: mysafety 계열 테이블이 없습니다.');
    }

    const requiredColumns = {'ID', '신고번호', '위반장소'};
    const sourceTables = {
      'mysafetymerge_traffic',
      'mysafetymerge_parking',
      'mysafetymerge_other',
    };

    var hasAnyReport = false;
    for (final tableName in sourceTables) {
      if (!tableNames.contains(tableName)) continue;
      final countRows = await serverDb.rawQuery(
        'SELECT COUNT(*) AS cnt FROM $tableName',
      );
      final count = int.tryParse(countRows.first['cnt']?.toString() ?? '') ?? 0;
      if (count > 0) hasAnyReport = true;

      final columns = await serverDb.rawQuery('PRAGMA table_info($tableName)');
      final columnNames = columns
          .map((c) => c['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toSet();
      if (!columnNames.containsAll(requiredColumns)) {
        throw Exception('서버 DB 병합 테이블 형식이 올바르지 않습니다: $tableName');
      }
    }

    if (!hasAnyReport) {
      throw Exception('서버 DB에 이식 가능한 신고 데이터가 없습니다.');
    }
  }

  static Future<Map<String, String>> _loadServerEntryValues(
    Database serverDb,
  ) async {
    final entryValueById = <String, String>{};
    try {
      final rows = await serverDb.query('mysafety_entry_value');
      for (final row in rows) {
        final id = row['ID']?.toString() ?? '';
        if (id.isEmpty) continue;
        entryValueById[id] = row['entry_value']?.toString() ?? '';
      }
    } catch (_) {}
    return entryValueById;
  }

  static Future<Map<String, Map<String, Object?>>> _loadServerRawPayload(
    Database serverDb,
  ) async {
    final rawPayloadById = <String, Map<String, Object?>>{};
    try {
      final rows = await serverDb.query('mysafety_raw_content');
      for (final row in rows) {
        final id = row['ID']?.toString() ?? '';
        if (id.isEmpty) continue;
        rawPayloadById[id] = {
          'raw_content': row['raw_content']?.toString() ?? '',
          'raw_type': row['raw_type']?.toString() ?? '',
          'saved_at': _toEpochMillis(row['saved_at']),
        };
      }
    } catch (_) {}
    return rawPayloadById;
  }

  static Future<List<Map<String, Object?>>> _loadServerSyncMeta(
    Database serverDb,
  ) async {
    final rows = <Map<String, Object?>>[];
    try {
      final sourceRows = await serverDb.query('mysafety_sync_meta');
      for (final row in sourceRows) {
        final key = row['key']?.toString() ?? '';
        if (key.isEmpty) continue;
        rows.add({'key': key, 'value': row['value']?.toString() ?? ''});
      }
    } catch (_) {}
    return rows;
  }

  static Future<List<Map<String, Object?>>> _loadServerDuplicateGroups(
    Database serverDb,
  ) async {
    final duplicateGroups = <Map<String, Object?>>[];
    try {
      final sourceRows = await serverDb.query('mysafety_duplicate_group');
      for (final row in sourceRows) {
        final groupId = row['group_id']?.toString() ?? '';
        if (groupId.isEmpty) continue;
        duplicateGroups.add({
          'group_id': groupId,
          'fingerprint': row['fingerprint']?.toString() ?? groupId,
          'match_type': row['match_type']?.toString() ?? 'payload_exact',
          'status':
              row['status']?.toString() ?? DuplicateStatuses.confirmedDuplicate,
          'representative_mode':
              row['representative_mode']?.toString() ??
              RepresentativeModes.auto,
          'representative_id': row['representative_id']?.toString() ?? '',
          'member_count':
              int.tryParse(row['member_count']?.toString() ?? '') ?? 0,
          'apply_globally':
              int.tryParse(row['apply_globally']?.toString() ?? '') ??
              ((row['status']?.toString() ?? '') ==
                      DuplicateStatuses.confirmedDuplicate
                  ? 1
                  : 0),
          'note': row['note']?.toString() ?? '',
          'created_at': _toEpochMillis(row['created_at']),
          'updated_at': _toEpochMillis(row['updated_at']),
        });
      }
    } catch (_) {}
    return duplicateGroups;
  }

  static Future<List<Map<String, Object?>>> _loadServerDuplicateMembers(
    Database serverDb,
  ) async {
    final duplicateMembers = <Map<String, Object?>>[];
    try {
      final sourceRows = await serverDb.query('mysafety_duplicate_member');
      for (final row in sourceRows) {
        final groupId = row['group_id']?.toString() ?? '';
        final reportId = row['report_id']?.toString() ?? '';
        if (groupId.isEmpty || reportId.isEmpty) continue;
        duplicateMembers.add({
          'group_id': groupId,
          'report_id': reportId,
          'report_number': row['report_number']?.toString() ?? '',
          'category': row['category']?.toString() ?? 'other',
          'is_representative':
              int.tryParse(row['is_representative']?.toString() ?? '') ?? 0,
          'priority_score':
              int.tryParse(row['priority_score']?.toString() ?? '') ?? 0,
          'raw_match': int.tryParse(row['raw_match']?.toString() ?? '') ?? 0,
          'field_match':
              int.tryParse(row['field_match']?.toString() ?? '') ?? 0,
          'created_at': _toEpochMillis(row['created_at']),
          'updated_at': _toEpochMillis(row['updated_at']),
        });
      }
    } catch (_) {}
    return duplicateMembers;
  }

  static Future<List<Map<String, Object?>>> _loadServerGeocodeCacheRows(
    Database serverDb,
    Set<String> localCacheCols,
    int now,
  ) async {
    final rows = <Map<String, Object?>>[];
    try {
      final sourceRows = await serverDb.query('mysafety_geocode_cache');
      for (final row in sourceRows) {
        final normalized = normalizeGeocodeAddress(row['주소정규화']?.toString());
        if (normalized.isEmpty) continue;

        final cachedRow = <String, Object?>{};
        for (final entry in row.entries) {
          if (localCacheCols.contains(entry.key)) {
            cachedRow[entry.key] = entry.value;
          }
        }
        cachedRow['주소정규화'] = normalized;
        cachedRow['원본주소'] = row['원본주소']?.toString() ?? normalized;
        cachedRow['행정구역'] = row['행정구역']?.toString() ?? '';
        cachedRow['위도'] = parseGeoDouble(row['위도']);
        cachedRow['경도'] = parseGeoDouble(row['경도']);
        cachedRow['상태'] = row['상태']?.toString() ?? '';
        cachedRow['source'] = row['source']?.toString() ?? 'kakao';
        cachedRow['error_message'] = row['error_message']?.toString() ?? '';
        cachedRow['updated_at'] = _toEpochMillis(row['updated_at']) ?? now;
        rows.add(cachedRow);
      }
    } catch (_) {}
    return rows;
  }

  // ── 서버 DB → 모바일 DB 변환 ────────────────────────────────────────────────

  /// 서버 DB (mysafetymerge_traffic / parking / other 3개 테이블 + mysafety_watchlist)
  /// 를 읽어 모바일 DB (단일 reports 테이블 + category 컬럼) 로 마이그레이션.
  ///
  /// [serverDbPath] 서버에서 받은 .db 파일의 절대 경로.
  /// 반환: 임포트한 신고 건수.
  static Future<int> importFromServerDb(String serverDbPath) async {
    final preparedDbPath = await _prepareExternalDbSnapshot(serverDbPath);
    final serverDb = await openDatabase(preparedDbPath, readOnly: true);
    Directory? stagingDir;
    Database? localDb;

    try {
      await _validateServerDbSchema(serverDb);

      stagingDir = await Directory.systemTemp.createTemp(
        'mysafetyreport_import_staged_',
      );
      final stagedDbPath = join(
        stagingDir.path,
        'standalone_reports_import.db',
      );
      localDb = await _createImportTargetDb(stagedDbPath);

      final now = DateTime.now().millisecondsSinceEpoch;
      final localReportCols =
          (await localDb.rawQuery('PRAGMA table_info(reports)'))
              .map((row) => row['name']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toSet();
      final localCacheCols =
          (await localDb.rawQuery('PRAGMA table_info(geocode_cache)'))
              .map((row) => row['name']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toSet();

      final entryValueById = await _loadServerEntryValues(serverDb);
      final rawPayloadById = await _loadServerRawPayload(serverDb);
      final syncMetaRows = await _loadServerSyncMeta(serverDb);
      final duplicateGroups = await _loadServerDuplicateGroups(serverDb);
      final duplicateMembers = await _loadServerDuplicateMembers(serverDb);
      final geocodeCacheRows = await _loadServerGeocodeCacheRows(
        serverDb,
        localCacheCols,
        now,
      );

      const sourceTableMap = {
        'mysafetymerge_traffic': 'traffic',
        'mysafetymerge_parking': 'parking',
        'mysafetymerge_other': 'other',
      };
      int imported = 0;

      await localDb.transaction((txn) async {
        for (final entry in sourceTableMap.entries) {
          final tableName = entry.key;
          final category = entry.value;
          final rows = await serverDb.query(tableName);
          if (rows.isEmpty) continue;

          for (final row in rows) {
            final reportId = row['ID']?.toString() ?? '';
            if (reportId.isEmpty) continue;
            final rawPayload = rawPayloadById[reportId];
            final syncedAt = _toEpochMillis(row['synced_at']) ?? now;
            final filteredRow = <String, Object?>{};
            for (final sourceEntry in row.entries) {
              if (localReportCols.contains(sourceEntry.key)) {
                filteredRow[sourceEntry.key] = sourceEntry.value;
              }
            }
            if (filteredRow.isEmpty) {
              continue;
            }

            final importedRow = <String, Object?>{
              ...filteredRow,
              'category': category,
              'entry_value': entryValueById[reportId] ?? '',
              'raw_content': '',
              'synced_at': syncedAt,
            };
            final geoPayload =
                filteredRow.containsKey('위도') ||
                    filteredRow.containsKey('경도') ||
                    filteredRow.containsKey('주소정규화') ||
                    filteredRow.containsKey('행정구역') ||
                    filteredRow.containsKey('지오코딩상태')
                ? extractGeoPayload(
                    importedRow,
                    fallbackAddress: importedRow['위반장소']?.toString() ?? '',
                  )
                : prepareGeoPayloadForAddress(importedRow['위반장소']?.toString());
            importedRow.addAll(geoPayload);
            await txn.insert(
              'reports',
              importedRow,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            await _replaceRawPayload(
              txn,
              reportId,
              rawContent: rawPayload?['raw_content']?.toString() ?? '',
              rawType: rawPayload?['raw_type']?.toString() ?? '',
              savedAt: _toEpochMillis(rawPayload?['saved_at']) ?? syncedAt,
            );
            imported++;
          }
        }
      });

      if (imported <= 0) {
        throw Exception('임포트할 신고 데이터가 없습니다.');
      }

      await localDb.transaction((txn) async {
        for (final row in syncMetaRows) {
          await txn.insert(
            'sync_meta',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final row in geocodeCacheRows) {
          await txn.insert(
            'geocode_cache',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final row in duplicateGroups) {
          await txn.insert(
            DuplicateProjectionService.groupTable,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final row in duplicateMembers) {
          await txn.insert(
            DuplicateProjectionService.memberTable,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });

      try {
        final watchRows = await serverDb.query(
          'mysafety_watchlist',
          columns: ['신고번호'],
        );
        final watchNumbers = watchRows
            .map((r) => r['신고번호']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
        if (watchNumbers.isNotEmpty) {
          await localDb.insert('sync_meta', {
            'key': 'watchlist',
            'value': watchNumbers.join(','),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          final placeholders = watchNumbers.map((_) => '?').join(',');
          await localDb.rawUpdate(
            "UPDATE reports SET 감시목록 = 'Y' WHERE 신고번호 IN ($placeholders)",
            watchNumbers,
          );
        }
      } catch (_) {}

      final hasLastSync = syncMetaRows.any(
        (row) => (row['key']?.toString() ?? '') == 'last_sync',
      );
      if (!hasLastSync) {
        await localDb.insert('sync_meta', {
          'key': 'last_sync',
          'value': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (duplicateGroups.isEmpty || duplicateMembers.isEmpty) {
        await DuplicateProjectionService.refreshDuplicateGroups(localDb);
      }

      final reportCountRows = await localDb.rawQuery(
        'SELECT COUNT(*) AS cnt FROM reports',
      );
      if ((int.tryParse(reportCountRows.first['cnt']?.toString() ?? '') ?? 0) <=
          0) {
        throw Exception('임포트 결과 reports 데이터가 비어 있습니다.');
      }

      await localDb.close();
      localDb = null;
      await _commitImportedDatabase(stagedDbPath);
      _invalidateProjectRowsCache();
      return imported;
    } finally {
      await serverDb.close();
      if (localDb != null) {
        try {
          await localDb.close();
        } catch (_) {}
      }
      if (stagingDir != null) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
      }
      await _cleanupPreparedSnapshot(preparedDbPath);
    }
  }

  /// 백업 .db 파일을 통째로 현재 DB 자리로 복사 (덮어쓰기).
  /// Standalone 백업 → 같은 모바일 스키마 DB 를 그대로 사용.
  /// (서버 DB 는 스키마가 달라서 이 메서드 사용 불가 → importFromServerDb 사용)
  static Future<void> replaceFromBackup(String backupDbPath) async {
    _invalidateProjectRowsCache();
    final preparedDbPath = await _prepareExternalDbSnapshot(backupDbPath);
    await closeDb();
    final dbPath = await getDbPath();
    final src = File(preparedDbPath);
    if (!src.existsSync()) {
      await _cleanupPreparedSnapshot(preparedDbPath);
      throw Exception('백업 파일이 존재하지 않습니다: $backupDbPath');
    }
    await _deleteDbSidecars(dbPath);
    await src.copy(dbPath);
    await _cleanupPreparedSnapshot(preparedDbPath);
    final reopened = await db;
    await DuplicateProjectionService.refreshDuplicateGroups(reopened);
    _invalidateProjectRowsCache();
    // 다음 db getter 호출 시 새로 open.
  }

  static Future<Map<String, dynamic>?> getEditableRecord(
    String reportId,
  ) async {
    final d = await db;
    final rows = await d.query(
      'reports',
      where: 'ID = ?',
      whereArgs: [reportId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  static Future<bool> updateEditableRecord(
    String reportId,
    Map<String, dynamic> values,
  ) async {
    final d = await db;
    final existingRows = await d.query(
      'reports',
      where: 'ID = ?',
      whereArgs: [reportId],
      limit: 1,
    );
    if (existingRows.isEmpty) return false;

    final existing = Map<String, dynamic>.from(existingRows.first);
    final next = Map<String, dynamic>.from(existing);
    for (final entry in values.entries) {
      next[entry.key] = entry.value;
    }

    if (values.containsKey('위반장소')) {
      final previousAddress = normalizeGeocodeAddress(
        existing['위반장소']?.toString(),
      );
      final nextAddress = normalizeGeocodeAddress(next['위반장소']?.toString());
      if (previousAddress != nextAddress) {
        next.addAll(
          prepareGeoPayloadForAddress(
            next['위반장소']?.toString(),
            existingRecord: existing,
          ),
        );
      }
    }

    final existingComparable = <String, Object?>{};
    final nextComparable = <String, Object?>{};
    for (final key in _syncedAtTrackedKeys) {
      existingComparable[key] = existing[key];
      nextComparable[key] = next[key];
    }
    final reportChanged = !_rowsEqual(existingComparable, nextComparable);
    final syncedAt = reportChanged
        ? DateTime.now().millisecondsSinceEpoch
        : (_toEpochMillis(existing['synced_at']) ??
              DateTime.now().millisecondsSinceEpoch);
    next['synced_at'] = syncedAt;

    await d.update(
      'reports',
      next,
      where: 'ID = ?',
      whereArgs: [reportId],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _invalidateProjectRowsCache();
    await DuplicateProjectionService.refreshDuplicateGroups(d);
    return true;
  }

  // ── 내부 변환 ─────────────────────────────────────────────────────────────

  static Report _rowToReport(
    Map<String, dynamic> r, {
    bool normalizePolice = false,
  }) {
    var agency = r['처리기관'] as String? ?? '';
    if (normalizePolice) agency = normalizePoliceAgency(agency);
    return Report(
      id: r['ID'] as String? ?? '',
      reportNumber: r['신고번호'] as String? ?? '',
      name: r['신고명'] as String? ?? '',
      date: r['신고일'] as String? ?? '',
      responseDate: r['답변일'] as String? ?? '',
      agency: agency,
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
      rating: (r['별점'] as num?)?.toInt(),
      ratingCause: r['별점사유'] as String? ?? '',
      category: r['category'] as String? ?? '',
      syncedAt: _toEpochMillis(r['synced_at']),
      supplementCount: (r['보완횟수'] as num?)?.toInt() ?? 0,
      supplementOpen: (r['보완_미응답'] as String? ?? 'N') == 'Y',
      supplementRequester: r['보완_요청자'] as String? ?? '',
      supplementRequestedAt: r['보완_요청일시'] as String? ?? '',
      supplementCompletedAt: r['보완_완료일시'] as String? ?? '',
      supplementRequest: r['보완_요청_내용'] as String? ?? '',
      supplementOpinion: r['보완_신고자_의견'] as String? ?? '',
    );
  }
}

// ── 집계 헬퍼 ────────────────────────────────────────────────────────────────

class _AgencyAgg {
  final String name;
  final String person;
  int total = 0, fines = 0, warn = 0, reject = 0;
  int totalFine = 0;
  final List<int> responseDays = [];
  final List<int> ratings = []; // 1~5 별점 표본

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

    final rating = (r['별점'] as num?)?.toInt();
    if (rating != null && rating >= 1 && rating <= 5) {
      ratings.add(rating);
    }
  }

  Map<String, dynamic> toJson() {
    final t = total > 0 ? total.toDouble() : 1.0;
    final avgRating = ratings.isEmpty
        ? null
        : double.parse(
            (ratings.reduce((a, b) => a + b) / ratings.length).toStringAsFixed(
              2,
            ),
          );
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
      'avg_rating': avgRating,
      'rating_count': ratings.length,
      'avg_days': responseDays.isEmpty
          ? null
          : responseDays.reduce((a, b) => a + b) / responseDays.length,
    };
  }
}
