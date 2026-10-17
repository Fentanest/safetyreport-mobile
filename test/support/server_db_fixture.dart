// 서버 스키마 6 .db 파일(core/database/models.py 와 같은 열, 2026-10-11 재설계)을 만든다.
// 옛 mysafety + mysafetymerge_* 구조는 더 받지 않는다 — 가져오기는 정확히 같은 버전만 받는다
// (test/storage/server_import_test.dart 의 "server DB of schema N is refused" 가 그 거절을 본다).
// 이 파일은 "지금 서버가 주는 .db" 를 만들어 가져오기 변환 규칙을 시험한다.
import 'package:safetyreport/services/local_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 서버 신고 표(mysafety_report) 전체 열 — 모바일 reports 와 같다(raw_content 는 _body 사이드카).
const serverReportCreateSql = '''
  CREATE TABLE mysafety_report (
    ID              TEXT PRIMARY KEY,
    상태             TEXT,
    신고번호          TEXT,
    신고명            TEXT,
    신고일            TEXT,
    만족도조사여부     TEXT,
    별점             INTEGER,
    별점사유          TEXT,
    감시목록          TEXT,
    처리상태          TEXT,
    차량번호          TEXT,
    위반법규          TEXT,
    범칙금_과태료      TEXT,
    벌점             TEXT,
    처리기관          TEXT,
    처리기관코드        TEXT,
    담당자            TEXT,
    답변일            TEXT,
    발생일자          TEXT,
    발생시각          TEXT,
    위반장소          TEXT,
    주소정규화        TEXT,
    행정구역          TEXT,
    위도             REAL,
    경도             REAL,
    지오코딩상태      TEXT,
    종결여부          TEXT,
    신고내용          TEXT,
    처리내용          TEXT,
    지도             TEXT,
    첨부사진          TEXT,
    첨부파일          TEXT,
    synced_at       INTEGER,
    보완횟수         INTEGER,
    보완_미응답      TEXT,
    보완_요청자      TEXT,
    보완_요청일시    TEXT,
    보완_완료일시    TEXT,
    보완_요청_내용   TEXT,
    보완_신고자_의견 TEXT,
    사진_첫촬영       TEXT,
    사진_끝촬영       TEXT,
    사진_촬영수       INTEGER,
    category        TEXT,
    entry_value     TEXT,
    ssnpc_cd        TEXT,
    ssnpc_type      TEXT
  )
''';

/// [path] 에 스키마 6~7 서버 DB(신고 + 본문 + 사용자 표)를 새로 만들어 연다. 호출한 쪽이 닫아야 한다.
/// `mysafety_report` 는 category 가 NULL 이면 목록에서만 본 신고다(가져오기가 세지 않는다).
/// 스키마 6에는 상세 원본 표가 없다(7에서 추가) — [withDetailRaw] 로 옛 구조를 흉내 낸다(명세 2절 예전 DB 가져오기 시험용).
Future<Database> openServerSchemaDb(
  String path, {
  int? version,
  bool withDetailRaw = true,
}) async {
  final db = await openDatabase(path);
  await db.setVersion(version ?? LocalDbService.serverSchemaVersion);
  await db.execute(serverReportCreateSql);
  await db.execute('''
    CREATE TABLE mysafety_report_body (
      ID          TEXT PRIMARY KEY,
      raw_content TEXT NOT NULL DEFAULT '',
      raw_type    TEXT NOT NULL DEFAULT '',
      saved_at    INTEGER
    )
  ''');
  await db.execute('CREATE TABLE mysafety_watchlist (신고번호 TEXT PRIMARY KEY)');
  await db.execute(
    'CREATE TABLE mysafety_sync_meta (key TEXT PRIMARY KEY, value TEXT)',
  );
  await db.execute('''
    CREATE TABLE mysafety_geocode_cache (
      주소정규화 TEXT PRIMARY KEY,
      원본주소   TEXT,
      행정구역   TEXT,
      위도      REAL,
      경도      REAL,
      상태      TEXT NOT NULL DEFAULT 'ok',
      source    TEXT NOT NULL DEFAULT 'kakao',
      error_message TEXT,
      updated_at INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE mysafety_duplicate_group (
      group_id TEXT PRIMARY KEY,
      fingerprint TEXT NOT NULL,
      match_type TEXT NOT NULL,
      status TEXT NOT NULL,
      representative_mode TEXT NOT NULL DEFAULT 'auto',
      representative_id TEXT,
      member_count INTEGER NOT NULL DEFAULT 0,
      apply_globally INTEGER NOT NULL DEFAULT 1,
      note TEXT,
      created_at INTEGER,
      updated_at INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE mysafety_duplicate_member (
      group_id TEXT NOT NULL,
      report_id TEXT NOT NULL,
      report_number TEXT NOT NULL,
      category TEXT NOT NULL,
      is_representative INTEGER NOT NULL DEFAULT 0,
      priority_score INTEGER NOT NULL DEFAULT 0,
      raw_match INTEGER NOT NULL DEFAULT 0,
      field_match INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER,
      updated_at INTEGER,
      PRIMARY KEY (group_id, report_id)
    )
  ''');
  await db.execute('''
    CREATE TABLE mysafety_report_override (
      ID          TEXT NOT NULL,
      column_name TEXT NOT NULL,
      value       TEXT,
      updated_at  INTEGER NOT NULL,
      PRIMARY KEY (ID, column_name)
    )
  ''');
  await db.execute('''
    CREATE TABLE mysafety_duplicate_decision (
      group_id            TEXT PRIMARY KEY,
      status              TEXT NOT NULL,
      representative_mode TEXT NOT NULL,
      representative_id   TEXT,
      apply_globally      INTEGER NOT NULL,
      note                TEXT,
      updated_at          INTEGER NOT NULL
    )
  ''');
  if (withDetailRaw) {
    // 스키마 7(2026-10-17): 상세 원본 표. 서버 core/database/models.py 와 같은 열.
    await db.execute('''
      CREATE TABLE mysafety_report_detail_raw (
        ID         TEXT PRIMARY KEY,
        raw_zlib   BLOB NOT NULL,
        raw_sha256 TEXT NOT NULL,
        raw_size   INTEGER NOT NULL,
        fetched_at TEXT NOT NULL,
        source     TEXT NOT NULL
      )
    ''');
  }
  return db;
}

/// mysafety_report 에 한 행 넣는다. 지정하지 않은 열은 NULL(서버가 "모름/아직 안 해봄"으로 두는 값).
Future<void> insertServerReport(Database db, Map<String, Object?> row) =>
    db.insert('mysafety_report', row);
