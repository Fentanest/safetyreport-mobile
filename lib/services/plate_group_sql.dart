import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart' as sqlite3_lib;

import 'plate_normalize.dart';
import 'sqlite_connection.dart' show sqliteBusyTimeoutMs;

/// 중복차량 그룹핑 전용 사용자 정의 SQL 함수 `normalize_plate(text)`.
///
/// **왜 보조 연결이 따로 필요한가** — 이 앱은 BL-1(번들 SQLite, FFI)을 쓰려고 sqflite 의
/// `databaseFactory` 를 `sqflite_common_ffi` 로 바꿔 끼운다([BundledSqlite]). 그 뒤에서 실제
/// SQLite 작업을 하는 `package:sqlite3` 의 `CommonDatabase`(FFI 버전은 종종 별도 isolate 안에서
/// 돈다)는 sqflite/`sqflite_common_ffi` 가 앱 코드에 공개하는 API가 아니다 — `Database.createFunction`
/// 은 오직 `package:sqlite3` 의 `Database`/`CommonDatabase` 객체에만 있고, sqflite 의 `Database`/
/// `Transaction`(`DatabaseExecutor`)에는 그런 메서드 자체가 없다. 그래서 **같은 DB 파일을
/// `package:sqlite3` 로 따로 한 번 더 연 뒤** 그 연결에만 `normalize_plate` 를 등록한다.
///
/// 번호판 정규화가 필요한 조회는 전부 이 보조 연결([select])에서 돈다. 일반 sqflite 연결
/// (`openAppDatabase`)에는 이 함수가 없고 등록할 공개 API도 없다 — 거기서 실수로
/// `normalize_plate(...)` 를 SQL에 쓰면 sqlite 자체가 `SqliteException: no such function:
/// normalize_plate` 로 바로, 조용한 오동작 없이 실패한다.
///
/// [selectAsync]는 별도 isolate에서 연결을 열고 결과 변환까지 마친 뒤 finally에서 닫는다.
/// 연결 캐시는 isolate-local이라 UI isolate에 SQLite 핸들을 남기지 않는다.
/// 호출자는 파일 교체가 조회 완료까지 기다리도록 DB 수명을 보호한다.
///
/// 반환값(둘 다 PC `services/report_query_service.py` `_plate_group_key`/`get_duplicate_records`
/// 와 같은 의미): 정규화 성공 시 정규화된 번호판, 실패 시 원문(트림) — 서로 다른 미인식 값이 하나의
/// 그룹으로 뭉치지 않게 정규화 실패 시 입력을 그대로 키로 쓴다. 자세한 Dart 쪽 규칙은
/// [normalizePlateGroupKey] 참고.
class PlateGroupSql {
  PlateGroupSql._();

  static const functionName = 'normalize_plate';

  static final Map<String, sqlite3_lib.Database> _connections = {};

  static sqlite3_lib.Database _forPath(String path) {
    return _connections.putIfAbsent(path, () {
      final conn = sqlite3_lib.sqlite3.open(
        path,
        mode: sqlite3_lib.OpenMode.readOnly,
      );
      conn.execute('PRAGMA busy_timeout=$sqliteBusyTimeoutMs');
      conn.createFunction(
        functionName: functionName,
        argumentCount: const sqlite3_lib.AllowedArgumentCount(1),
        // 입력이 같으면 결과도 같다(순수 함수) — 쿼리 플래너가 전제할 수 있다.
        deterministic: true,
        function: (args) {
          final value = args[0];
          if (value == null) return null;
          return normalizePlateGroupKey(value);
        },
      );
      return conn;
    });
  }

  /// [path] 에 연 보조 연결에서 읽기 전용 SELECT 를 돈다. 이 연결은 readOnly 로 열려 쓰기는
  /// 지원하지 않는다 — 번호판 정규화가 필요한 **조회**만 여기로 온다.
  static List<Map<String, dynamic>> select(
    String path,
    String sql, [
    List<Object?> params = const [],
  ]) {
    final rows = _forPath(path).select(sql, params);
    return rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  /// Open, normalize, select and materialize rows entirely in a worker isolate.
  /// Only the path, SQL and parameters cross the isolate boundary. Always close,
  /// including SQL failures, before the caller's DB lifetime guard is released.
  static Future<List<Map<String, dynamic>>> selectAsync(
    String path,
    String sql, [
    List<Object?> params = const [],
  ]) => Isolate.run(() {
    try {
      return select(path, sql, params);
    } finally {
      closeAll();
    }
  });

  /// DB 파일이 교체되기 전(백업 복원·서버 DB 가져오기·데모 전환 — [LocalDbService.closeDb])
  /// 반드시 모든 연결을 닫는다. 안 그러면 옛 파일을 가리키는 핸들이 새 파일과 뒤섞인다(DB
  /// 교환·변환 무결성 규칙). 경로별로 다시 닫을 필요 없이 한 번에 전부 닫는다 — 데모/실제 계정
  /// 전환처럼 경로가 바뀌는 경우까지 안전하게 아우른다.
  static void closeAll() {
    for (final conn in _connections.values) {
      conn.close();
    }
    _connections.clear();
  }

  @visibleForTesting
  static int get openConnectionCountForTest => _connections.length;
}
