import 'app_prefs_keys.dart';
import '../models/editor_schema.dart';
import '../models/rating_lookup.dart';
import '../storage/schema_utils.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine_estimate;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../community/community_store.dart';
import '../models/report.dart';
import 'duplicate_projection_service.dart';
import 'geocode_utils.dart';
import 'attachment_policy.dart';
import 'photo_capture_time.dart';
import 'standalone_parser.dart';

/// 서버 _normalize_police_agency 동일: '경찰서' 이후 문자열 제거
String normalizePoliceAgency(String agency) {
  final idx = agency.indexOf('경찰서');
  return idx != -1 ? agency.substring(0, idx + 3) : agency;
}

/// 서버 DB 컬럼명(한국어)과 동일한 스키마 사용.
/// mobile-only 추가 컬럼: category, entry_value, synced_at
/// raw payload 는 report_raw 사이드카 테이블에 저장한다.
/// 동기화·지도 좌표 변환 중이라 백업·복원을 거절할 때. 메시지는 그대로 화면에 보인다.
class DbBusyException implements Exception {
  DbBusyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 가져올 DB 의 모르는 열에 값이 있어 교체하지 않았을 때(감사 SOL-02). 메시지는 그대로 화면에 보인다.
class UnknownColumnsException implements Exception {
  UnknownColumnsException(this.columns);
  final List<String> columns;

  @override
  String toString() =>
      '이 앱이 모르는 열에 값이 있어 가져오지 않았습니다(그대로 바꾸면 값이 사라집니다): '
      '${columns.join(', ')}. 앱을 최신 버전으로 업데이트한 뒤 다시 시도하세요.';
}

/// 이전(또는 모르는 새) 버전 DB — 2026-09-26 초기화 크롤링 릴리스는 이전 DB 를 새 구조로 옮기지 않는다.
/// 가져오기·복원은 이 오류로 멈추고(무엇이든 바꾸기 전에), 앱의 기존 DB 는 [LocalDbService.resetLegacyDatabase] 가 백업 뒤 비운다.
/// 서버 core/storage/exchange.py 의 LegacyDatabaseRefused 와 같은 규칙·문구.
class LegacyDatabaseException implements Exception {
  LegacyDatabaseException(this.message);
  final String message;

  @override
  String toString() => message;
}

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
    if (_fileOp != null) await _waitForFileOp();
    if (_db != null) return _db!;
    _initFuture ??= _open();
    _db = await _initFuture;
    return _db!;
  }

  /// 데모 계정(심사용)은 별도 파일을 쓴다(결정 D-7, M-24). 원천은 설정 키 standaloneDemoMode.
  /// 모드를 바꾸는 쪽은 [closeDb] 를 불러 다음 접근 때 맞는 파일이 열리게 한다.
  /// 다른 서비스가 reports 를 직접 고친 뒤 부른다(화면 캐시 비우기 — M-5).
  static void invalidateCaches() => _invalidateProjectRowsCache();

  /// 데모 계정(심사용) DB 파일 이름.
  static const demoDbFileName = 'standalone_reports_demo.db';

  static Future<String> getDbPath() async {
    final dbPath = await getDatabasesPath();
    final prefs = await SharedPreferences.getInstance();
    final demo = prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false;
    return join(
      dbPath,
      demo ? demoDbFileName : 'standalone_reports.db',
    );
  }

  // ── 공유 연결과 백그라운드 작업 (M-25) ──────────────────────────────────
  // 동기화·자동 동기화·지오코딩 백필은 공유 연결로 오래 쓴다. 예전엔 백업·복원·데모 전환·로그아웃이
  // 그 사이 연결을 닫아 진행 중인 쓰기가 "database is closed" 로 깨졌다.
  static int _backgroundWork = 0;
  static Completer<void>? _backgroundIdle;
  static bool _closeRequested = false;
  static const _backgroundZoneKey = #srLocalDbBackgroundWork;

  /// 공유 연결을 오래 쓰는 작업을 감싼다. [closeDb] 는 이 작업들이 끝날 때까지 기다린다.
  static Future<T> runBackgroundWork<T>(Future<T> Function() body) async {
    // 파일 교체 중에는 시작하지 않는다. 잠금이 없으면 기다리지 않고 바로 센다 —
    // 여기서 한 번이라도 넘기면 그 틈에 closeDb 가 "작업 없음"으로 보고 닫는다.
    if (_fileOp != null) await _waitForFileOp();
    _backgroundWork++;
    try {
      return await runZoned(body, zoneValues: {_backgroundZoneKey: true});
    } finally {
      _backgroundWork--;
      if (_backgroundWork == 0) {
        _backgroundIdle?.complete();
        _backgroundIdle = null;
      }
    }
  }

  static bool get hasBackgroundWork => _backgroundWork > 0;

  /// 연결을 닫으려고 기다리는 중. 백그라운드 작업은 다음 확인 지점에서 멈춘다(지오코딩은 대기 상태로 넘김).
  static bool get closeRequested => _closeRequested;

  /// 사용자가 누른 파일 교체(백업·복원·서버 DB 가져오기)는 작업 중이면 거절한다 — 서버 복원의 409 와 같음.
  static void _refuseDuringBackgroundWork(String action) {
    if (_backgroundWork > 0) {
      throw DbBusyException(
        '동기화 또는 지도 좌표 변환이 진행 중이라 $action 할 수 없습니다. 끝난 뒤 다시 시도하세요.',
      );
    }
  }

  // ── DB 파일 복사·교체 중 잠금 (G11-4) ─────────────────────────────────
  // 백업·복원이 파일을 복사·교체하는 동안 화면·스케줄러가 [db] 로 연결을 다시 열면 교체되는 파일 위에 연결이 생긴다.
  // 그 사이 [db]·[runBackgroundWork] 는 끝날 때까지 기다린다. 파일 작업 자신(zone)은 통과.
  static Completer<void>? _fileOp;
  static const _fileOpZoneKey = #srLocalDbFileOp;

  static Future<void> _waitForFileOp() async {
    while (_fileOp != null && Zone.current[_fileOpZoneKey] != true) {
      await _fileOp!.future;
    }
  }

  static Future<T> _withFileExclusive<T>(Future<T> Function() body) async {
    while (_fileOp != null) {
      await _fileOp!.future;
    }
    final op = Completer<void>();
    try {
      await _closeDb(hold: op);
      return await runZoned(body, zoneValues: {_fileOpZoneKey: true});
    } finally {
      if (identical(_fileOp, op)) _fileOp = null;
      op.complete();
    }
  }

  @visibleForTesting
  static Future<T> withFileExclusiveForTest<T>(Future<T> Function() body) =>
      _withFileExclusive(body);

  static Future<void> closeDb() => _closeDb();

  /// [hold] 가 있으면 백그라운드 작업이 모두 빠진 직후(같은 동기 구간) 파일 잠금을 건다 — 그 틈에 다시 열리지 않게.
  static Future<void> _closeDb({Completer<void>? hold}) async {
    if (Zone.current[_backgroundZoneKey] == true) {
      throw StateError('백그라운드 작업 안에서는 DB 연결을 닫을 수 없습니다.');
    }
    _closeRequested = true;
    try {
      while (_backgroundWork > 0) {
        await (_backgroundIdle ??= Completer<void>()).future;
      }
      if (hold != null) _fileOp = hold;
      final pending = _initFuture;
      final open = _db ?? (pending == null ? null : await pending);
      _db = null;
      _initFuture = null;
      await open?.close();
    } finally {
      _closeRequested = false;
    }
  }

  /// 앱 DB 스키마 버전. contracts/storage-contract.json 의 schema_version.mobile 과 같아야 한다(테스트가 확인).
  static const dbVersion = 15;

  /// 서버 DB 스키마 버전(PRAGMA user_version). contracts/storage-contract.json 의 schema_version.server 와 같아야 한다(테스트가 확인).
  /// 서버 DB 가져오기는 정확히 이 버전만 받는다(이전 버전 서버 DB 는 거절).
  static const serverSchemaVersion = 4;

  static Future<Database> _open() async {
    final path = await getDbPath();
    // [이전 DB 업데이트 비활성 — 2026-09-26 초기화 크롤링 릴리스] 이전 버전 DB 는 옮기지 않고 백업 뒤 비운다.
    // await backupBeforeUpgrade(path);
    // 데모 DB(심사용 합성 데이터)는 실제 계정의 커뮤니티 데이터셋과 무관하다 — 선회전하지 않는다(Sol 재검증 2).
    await resetLegacyDatabase(
      path,
      beforeReset: basename(path) == demoDbFileName ? () async {} : null,
    );
    final database = await openDatabase(
      path,
      version: dbVersion,
      onCreate: _create,
      // [이전 DB 업데이트 비활성 — 2026-09-26 초기화 크롤링 릴리스]
      // onUpgrade: _migrateLocalDatabase,
      onUpgrade: _refuseLegacyUpgrade,
    );
    await _ensureEffectiveView(database);
    return database;
  }

  /// 업데이트 로직 대신: 이전 버전 파일이 여기까지 오면(비우기를 거치지 않은 경로) 옮기지 않고 멈춘다.
  /// sqflite 는 onUpgrade 가 없으면 옛 구조에 새 버전 번호만 적으므로 비워 두지 않는다.
  static Future<void> _refuseLegacyUpgrade(Database db, int oldV, int newV) async {
    throw LegacyDatabaseException(
      '이전 버전 앱 DB(스키마 $oldV)는 이번 업데이트에서 옮기지 않습니다(지금 $newV). '
      '초기화 크롤링으로 안전신문고에서 다시 수집하세요.',
    );
  }

  /// 가져올 DB 의 스키마 버전이 이 앱과 정확히 같아야 한다(서버 exchange.refuse_other_version 과 같은 규칙).
  static void _refuseOtherVersion(int version, int expected, String label) {
    if (version < expected) {
      throw LegacyDatabaseException(
        '이전 버전 $label DB(스키마 $version)는 가져올 수 없습니다(지금 $expected). '
        '이번 업데이트는 이전 DB 를 옮기지 않습니다 — 초기화 크롤링으로 안전신문고에서 다시 수집하세요.',
      );
    }
    if (version > expected) {
      throw LegacyDatabaseException(
        '더 새 버전 $label DB(스키마 $version)는 가져올 수 없습니다(지금 $expected). 앱을 먼저 업데이트하세요.',
      );
    }
  }

  static const legacyResetMetaKey = 'legacy_reset';

  /// 이전 버전 DB 를 비울 때 옮기는 코드 없이 남기는 자료: 감시목록(sync_meta 의 watchlist 값)과 지오코딩 캐시(구조가 같을 때만).
  /// 서버 LEGACY_KEEP_TABLES 의 감시목록·지오코딩 캐시와 같다(관리자·API 키는 서버 전용).
  static const legacyKept = ['watchlist', 'geocode_cache'];

  /// 이전 버전 DB(저장된 버전 1 이상, [dbVersion] 미만)면: 통째로 백업(`VACUUM INTO <db>.legacy_v<옛 버전>.<epoch ms>.bak`, 무결성 검사)
  /// → [beforeReset](기본: 커뮤니티 dataset 선회전, 실패하면 비우지 않음) → 새 스키마의 빈 DB 를 옆에 만들어
  /// 감시목록·지오코딩 캐시만 옮기고 sync_meta[legacy_reset] 에 기록 → 원래 이름으로 바꾼다.
  /// 반환: {from_version, backup, kept, dropped, at} (이전 버전 DB 가 아니면 null). 서버 database.reset_legacy_database 와 같은 규칙.
  @visibleForTesting
  static Future<Map<String, Object?>?> resetLegacyDatabase(
    String path, {
    Future<void> Function()? beforeReset,
  }) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    // 백업부터 파일 교체까지 옛 DB 의 쓰기 잠금을 잡는다(Sol 재검증 1): 앱의 개인 DB 접근은 모두 [db] → [_open] 을 거쳐
    // 이 함수가 끝나기 전에는 연결이 없지만, 그 밖의 연결이 쓰려 하면 조용히 사라지지 않고 잠김 오류로 실패한다.
    final lock = await openDatabase(path, singleInstance: false);
    try {
      await lock.rawQuery('PRAGMA busy_timeout=30000');
      await lock.execute('BEGIN IMMEDIATE');
      return await _resetLegacyLocked(path, file, beforeReset);
    } finally {
      try {
        await lock.execute('ROLLBACK');
      } catch (_) {}
      await lock.close();
    }
  }

  static Future<Map<String, Object?>?> _resetLegacyLocked(
    String path,
    File file,
    Future<void> Function()? beforeReset,
  ) async {
    final probe = await openDatabase(path, singleInstance: false);
    int version;
    List<String> oldTables;
    String backup;
    Object? watchlist;
    List<Map<String, Object?>> geoInfo = const [];
    List<Map<String, Object?>> geoRows = const [];
    try {
      version = await probe.getVersion();
      if (version < 1 || version >= dbVersion) return null;
      oldTables = [
        for (final r in await probe.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        ))
          r['name'] as String,
      ];
      // 남길 자료는 잠금 안에서 백업과 같은 시점에 읽어 둔다(새 DB 에 옛 DB 를 ATTACH 하면 그 쓰기 트랜잭션이 잠긴 옛 DB 까지 잠그려 한다).
      if (oldTables.contains('sync_meta')) {
        final rows = await probe.rawQuery(
          "SELECT value FROM sync_meta WHERE key = 'watchlist' AND value IS NOT NULL",
        );
        if (rows.isNotEmpty) watchlist = rows.first['value'];
      }
      if (oldTables.contains('geocode_cache')) {
        geoInfo = await probe.rawQuery('PRAGMA table_info("geocode_cache")');
        geoRows = await probe.query('geocode_cache');
      }
      // 파일 복사가 아니라 VACUUM INTO: WAL 에만 있던 최근 쓰기까지 담은 일관된 사본이다(다른 연결 때문에
      // 체크포인트가 끝나지 못해도 빠지지 않는다 — Sol 검토 2). 서버는 sqlite backup API.
      backup = '$path.legacy_v$version.${DateTime.now().millisecondsSinceEpoch}.bak';
      final target = File(backup);
      if (target.existsSync()) await target.delete();
      await probe.execute("VACUUM INTO '${backup.replaceAll("'", "''")}'");
    } finally {
      await probe.close();
    }
    final check = await openDatabase(backup, readOnly: true, singleInstance: false);
    try {
      final result = (await check.rawQuery('PRAGMA integrity_check')).first.values.first;
      if (result != 'ok') {
        await check.close();
        try {
          await File(backup).delete();
        } catch (_) {}
        throw LegacyDatabaseException('이전 DB 백업 무결성 검사 실패: $result');
      }
    } finally {
      if (check.isOpen) await check.close();
    }
    await (beforeReset ?? () => _rotateCommunityDataset('legacy_reset'))();

    final staged = '$path.legacy_reset_staging';
    for (final f in [staged, '$staged-wal', '$staged-shm', '$staged-journal']) {
      final side = File(f);
      if (side.existsSync()) await side.delete();
    }
    final kept = <String>[];
    final at = DateTime.now().toIso8601String();
    final fresh = await openDatabase(
      staged,
      version: dbVersion,
      onCreate: _create,
      singleInstance: false,
    );
    try {
      final sameGeo = geoInfo.isNotEmpty &&
          _columnSignature(geoInfo) ==
              _columnSignature(await fresh.rawQuery('PRAGMA table_info("geocode_cache")'));
      await fresh.transaction((txn) async {
        if (watchlist != null) {
          await txn.insert('sync_meta', {'key': 'watchlist', 'value': watchlist},
              conflictAlgorithm: ConflictAlgorithm.replace);
          kept.add('watchlist');
        }
        if (sameGeo) {
          final batch = txn.batch();
          for (final row in geoRows) {
            batch.insert('geocode_cache', row);
          }
          await batch.commit(noResult: true);
          kept.add('geocode_cache');
        }
        await txn.insert(
          'sync_meta',
          {
            'key': legacyResetMetaKey,
            'value': jsonEncode({
              'from_version': version,
              'backup': backup,
              'kept': kept,
              'dropped': oldTables,
              'at': at,
            }),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    } finally {
      await fresh.close();
    }
    for (final ext in ['-wal', '-shm', '-journal']) {
      final side = File('$path$ext');
      if (side.existsSync()) await side.delete();
    }
    await File(staged).rename(path);
    return {
      'from_version': version,
      'backup': backup,
      'kept': kept,
      'dropped': oldTables,
      'at': at,
    };
  }

  /// 열 구성 비교용(PRAGMA table_info): 이름·타입·NOT NULL·기본값·기본키.
  static String _columnSignature(List<Map<String, Object?>> rows) => [
        for (final r in rows)
          '${r['name']}|${(r['type'] ?? '').toString().toUpperCase()}|${r['notnull']}|${r['dflt_value']}|${r['pk']}',
      ].join(',');

  /// 초기화 크롤링 판정용: (개인 DB 신고 수, 이전 DB 를 비운 기록). 열지 못하면 신고 수 null(새 설치로 보지 않음).
  /// DB 를 여는 김에 이전 버전 DB 비우기가 먼저 일어난다.
  static Future<({int? reports, Map<String, Object?>? legacyReset})> personalDbFacts() async {
    try {
      final d = await db;
      final count = Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM reports')) ?? 0;
      final meta = await d.query('sync_meta',
          columns: ['value'], where: 'key = ?', whereArgs: [legacyResetMetaKey], limit: 1);
      Map<String, Object?>? legacy;
      if (meta.isNotEmpty && meta.first['value'] != null) {
        try {
          final decoded = jsonDecode(meta.first['value'] as String);
          if (decoded is Map) legacy = Map<String, Object?>.from(decoded);
        } catch (_) {
          legacy = {'raw': meta.first['value']};
        }
      }
      return (reports: count, legacyReset: legacy);
    } catch (_) {
      return (reports: null, legacyReset: null);
    }
  }

  /// 목록 API 로 받은 값으로 이미 저장된 신고의 목록 값을 갱신한다(서버 database.title_to_sql 과 같은 규칙).
  /// 종결돼 상세를 다시 받지 않는 신고도 사이트에서 바뀐 상태·만족도(나중에 매긴 별점)가 반영된다.
  /// 새 값이 비면 기존 값 유지, '참여 완료' 는 되돌리지 않는다(결정 D-3). 반환: 갱신한 신고 수.
  static Future<int> updateTitlesFromList(
    List<Map<String, dynamic>> items,
  ) async {
    final d = await db;
    var updated = 0;
    await d.transaction((txn) async {
      final batch = txn.batch();
      for (final item in items) {
        final id = item['C_NO']?.toString() ?? '';
        if (id.isEmpty) continue;
        final t = titleFieldsFromListItem(item);
        batch.rawUpdate(
          '''
          UPDATE reports SET
            상태 = CASE WHEN ? = '' THEN 상태 ELSE ? END,
            신고번호 = CASE WHEN ? = '' THEN 신고번호 ELSE ? END,
            신고명 = CASE WHEN ? = '' THEN 신고명 ELSE ? END,
            신고일 = CASE WHEN ? = '' THEN 신고일 ELSE ? END,
            만족도조사여부 = CASE
              WHEN ? = '' THEN 만족도조사여부
              WHEN 만족도조사여부 = '참여 완료' THEN 만족도조사여부
              ELSE ? END
          WHERE ID = ?
          ''',
          [
            for (final k in ['상태', '신고번호', '신고명', '신고일', '만족도조사여부']) ...[
              t[k],
              t[k],
            ],
            id,
          ],
        );
      }
      final results = await batch.commit();
      updated = results.whereType<int>().fold(0, (a, b) => a + b);
    });
    if (updated > 0) invalidateCaches();
    return updated;
  }

  /// 촬영 시각을 아직 못 읽은 주정차 신고 (ID, 첨부사진, 신고번호). 신고일 6개월 이내(첨부 URL 만료 전)만, 최신 ID 부터.
  /// 서버 photo_capture_time.pending_photo_rows 와 같은 조건.
  static Future<List<({String id, String photos, String reportNumber})>>
  pendingPhotoRows({int? limit}) async {
    final d = await db;
    final cutoffText = attachmentCutoff(DateTime.now());
    final rows = await d.rawQuery(
      '''
      SELECT ID, 첨부사진, 신고번호 FROM reports
      WHERE (category = 'parking' OR COALESCE(entry_value, '') LIKE '%불법주정차신고%')
        AND 사진_촬영수 IS NULL
        AND COALESCE(첨부사진, '') LIKE 'http%'
        AND COALESCE(신고일, '') >= ?
      ORDER BY ID DESC
      ${limit == null ? '' : 'LIMIT $limit'}
      ''',
      [cutoffText],
    );
    return [
      for (final r in rows)
        (
          id: r['ID'].toString(),
          photos: (r['첨부사진'] ?? '').toString(),
          reportNumber: (r['신고번호'] ?? '').toString(),
        ),
    ];
  }

  /// 상세 저장 전에 촬영 시각을 읽어야 하는지: 아직 없는 신고이거나 `사진_촬영수` 가 NULL(서버 `_prefetch_derived` 와 같음).
  static Future<bool> needsPhotoCapture(String id) async {
    final d = await db;
    final rows = await d.query(
      'reports',
      columns: ['사진_촬영수'],
      where: 'ID = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty || rows.first['사진_촬영수'] == null;
  }

  /// 촬영 시각을 저장한다(아직 비어 있을 때만). 사이트 원본이 아니라 계산값이라 변경 알림·synced_at 과 무관.
  static Future<void> setPhotoCapture(String id, PhotoCapture capture) async {
    final d = await db;
    final n = await d.update(
      'reports',
      {
        '사진_첫촬영': capture.first,
        '사진_끝촬영': capture.last,
        '사진_촬영수': capture.count,
      },
      where: 'ID = ? AND 사진_촬영수 IS NULL',
      whereArgs: [id],
    );
    if (n > 0) invalidateCaches();
  }

  static const preUpgradeBackupKeep = 3;

  /// 앱 업데이트 뒤 처음 DB 를 열 때, 스키마를 올리기 전에 DB 파일을 복사해 둔다.
  /// 저장된 버전이 1 이상이고 [dbVersion] 보다 낮을 때만(새 설치·이미 최신은 건너뜀).
  /// 파일: `<db>.pre_v<옛 버전>.<epoch ms>.bak`, 최근 [preUpgradeBackupKeep] 개만 남긴다.
  /// 버전 없이 열어(마이그레이션 없음) WAL 을 본 파일에 합친 뒤 복사하므로 최근 쓰기도 들어간다.
  /// 되돌리기: 이 파일을 원래 이름으로 바꾸고 **그 버전의 앱**으로 연다(새 앱으로 열면 다시 올린다).
  @visibleForTesting
  static Future<String?> backupBeforeUpgrade(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final probe = await openDatabase(path, singleInstance: false);
    int version;
    try {
      version = await probe.getVersion();
      if (version >= 1 && version < dbVersion) {
        await probe.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      }
    } finally {
      await probe.close();
    }
    if (version < 1 || version >= dbVersion) return null;
    final target =
        '$path.pre_v$version.${DateTime.now().millisecondsSinceEpoch}.bak';
    await file.copy(target);
    final dir = file.parent;
    final name = file.uri.pathSegments.last;
    final olds = dir.listSync().whereType<File>().where((f) {
      final n = f.uri.pathSegments.last;
      return n.startsWith('$name.pre_v') && n.endsWith('.bak');
    }).toList()..sort((a, b) => _backupStamp(a).compareTo(_backupStamp(b)));
    for (final f in olds.take(
      olds.length > preUpgradeBackupKeep
          ? olds.length - preUpgradeBackupKeep
          : 0,
    )) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    return target;
  }

  /// `<db>.pre_v<버전>.<epoch ms>.bak` 의 시각 부분(정렬용).
  static int _backupStamp(File f) {
    final parts = f.uri.pathSegments.last.split('.');
    return parts.length >= 2 ? int.tryParse(parts[parts.length - 2]) ?? 0 : 0;
  }

  /// 보완요청 마지막 round 1개 + 누적 횟수 + 요청자/일시 메타를 reports row 에 보존.
  /// 이전 빌드에서 잠시 존재했던 report_supplement_history 테이블은 정리한다.
  static Future<void> _addSupplementColumns(DatabaseExecutor db) async {
    for (final (col, type) in const [
      ('보완횟수', 'INTEGER DEFAULT 0'),
      ('보완_미응답', "TEXT DEFAULT 'N'"),
      ('보완_요청자', "TEXT DEFAULT ''"),
      ('보완_요청일시', "TEXT DEFAULT ''"),
      ('보완_완료일시', "TEXT DEFAULT ''"),
      ('보완_요청_내용', "TEXT DEFAULT ''"),
      ('보완_신고자_의견', "TEXT DEFAULT ''"),
    ]) {
      await addColumnIfMissing(db, 'reports', col, type);
    }
    await db.execute('DROP TABLE IF EXISTS report_supplement_history');
  }

  static Future<void> _addGeoColumns(DatabaseExecutor db) async {
    for (final (col, type) in const [
      ('주소정규화', "TEXT DEFAULT ''"),
      ('행정구역', "TEXT DEFAULT ''"),
      ('위도', 'REAL'),
      ('경도', 'REAL'),
      ('지오코딩상태', "TEXT DEFAULT ''"),
    ]) {
      await addColumnIfMissing(db, 'reports', col, type);
    }
  }

  /// 화면용 보기: 사이트 원본(reports) 위에 사용자 수정값(report_override)을 덮는다(결정 D-1, 저장 계층 재설계 R3).
  /// reports 는 원본을 담아 서버와 교환하고, 화면·통계는 이 보기를 읽는다(서버 merge 와 같은 뜻).
  /// 열이 추가될 수 있어 DB 를 열 때마다 다시 만든다. 주의: 이 보기가 참조하는 열은 DROP/RENAME 이 막히므로,
  /// 그런 마이그레이션은 먼저 `DROP VIEW IF EXISTS reports_effective` 를 해야 한다.
  static const effectiveReportsView = 'reports_effective';

  static Future<void> _ensureEffectiveView(DatabaseExecutor db) async {
    final columns = (await db.rawQuery(
      'PRAGMA table_info("reports")',
    )).map((r) => r['name'] as String).toList();
    final editable = EditorSchema.defaultDetailFields.toSet();
    // 위반장소를 고쳤으면 좌표 열은 고친 주소의 지오코딩 캐시에서(없으면 대기) — 서버 merge 와 같은 규칙(S-4).
    // 주소 정규화(geocode_utils.normalizeGeocodeAddress: 앞뒤 공백 제거 + 연속 공백 하나로)를 SQL 로.
    const addressOverride =
        "(SELECT o.value FROM report_override o WHERE o.ID = r.ID AND o.column_name = '위반장소')";
    var normalized =
        "REPLACE(REPLACE(REPLACE($addressOverride, char(9), ' '), char(10), ' '), char(13), ' ')";
    for (var i = 0; i < 4; i++) {
      normalized = "REPLACE($normalized, '  ', ' ')"; // 공백 16칸까지
    }
    normalized = 'TRIM($normalized)';
    String fromCache(String column) =>
        '(SELECT c."$column" FROM geocode_cache c WHERE c.주소정규화 = $normalized)';
    final overriddenGeo = <String, String>{
      '주소정규화': normalized,
      '행정구역': fromCache('행정구역'),
      '위도': fromCache('위도'),
      '경도': fromCache('경도'),
      '지오코딩상태':
          "CASE WHEN $normalized = '' THEN '' ELSE COALESCE(${fromCache('상태')}, 'pending') END",
    };
    final select = columns
        .map((c) {
          if (editable.contains(c)) {
            return 'COALESCE((SELECT o.value FROM report_override o WHERE o.ID = r.ID AND o.column_name = \'$c\'), r."$c") AS "$c"';
          }
          final geo = overriddenGeo[c];
          if (geo != null) {
            return 'CASE WHEN $addressOverride IS NULL THEN r."$c" ELSE $geo END AS "$c"';
          }
          return 'r."$c" AS "$c"';
        })
        .join(', ');
    await db.execute('DROP VIEW IF EXISTS $effectiveReportsView');
    await db.execute(
      'CREATE VIEW $effectiveReportsView AS SELECT $select FROM reports r',
    );
  }

  /// v12(저장 계층 재설계 R1): 사용자 수정값·중복 판단 표. 서버 mysafety_report_override / mysafety_duplicate_decision 과 같은 구조.
  static Future<void> _createStorageTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS report_override (
        ID          TEXT NOT NULL,
        column_name TEXT NOT NULL,
        value       TEXT,
        updated_at  INTEGER NOT NULL,
        PRIMARY KEY (ID, column_name)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS duplicate_decision (
        group_id            TEXT PRIMARY KEY,
        status              TEXT NOT NULL,
        representative_mode TEXT NOT NULL,
        representative_id   TEXT,
        apply_globally      INTEGER NOT NULL,
        note                TEXT,
        updated_at          INTEGER NOT NULL
      )
    ''');
  }

  /// v13(저장 계층 재설계 R3, M-14): 옛 DB 의 처리상태·종결여부·보완_미응답 정규화를 한 번만 한다.
  /// 예전엔 DB 를 열 때마다 전 행에 돌고 오류를 삼켰다.
  /// 서버 database._normalize_processing_layers 와 같은 네 단계(NULL 은 '' 로 보고 비교 — 2026-09-25 동등성 검수로 맞춤).
  @visibleForTesting
  static Future<void> normalizeLegacyProcessingStatesForTest(
    DatabaseExecutor database,
  ) => _normalizeLegacyProcessingStates(database);

  static Future<void> _normalizeLegacyProcessingStates(
    DatabaseExecutor database,
  ) async {
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
          AND IFNULL(상태, '') NOT IN ('수용', '일부수용', '불수용', '기타', '답변완료', '취하', '이송')
          AND IFNULL(처리상태, '') != '보완요청'
      """);
    await database.execute("""
        UPDATE reports
        SET 처리상태 = '처리중',
            종결여부 = 'N'
        WHERE IFNULL(상태, '') NOT IN ('수용', '일부수용', '불수용', '기타', '답변완료', '취하', '이송')
          AND IFNULL(보완_미응답, '') != 'Y'
          AND (처리상태 IS NULL OR 처리상태 IN ('', '진행', '진행중', '처리중', '검토중'))
      """);
  }

  // [이전 DB 업데이트 비활성 — 2026-09-26 초기화 크롤링 릴리스] 호출하는 곳(onUpgrade)을 주석 처리했다. 다음 스키마 변경 때 다시 켠다.
  // ignore: unused_element
  static Future<void> _migrateLocalDatabase(
    Database db,
    int oldV,
    int newV,
  ) async {
    if (oldV < 4) {
      await addColumnIfMissing(db, 'reports', '별점', 'INTEGER');
      await addColumnIfMissing(db, 'reports', '별점사유', "TEXT DEFAULT ''");
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
    if (oldV < 11) {
      await _addPhotoCaptureColumns(db);
    }
    if (oldV < 12) {
      await _createStorageTables(db);
    }
    if (oldV < 13) {
      await _normalizeLegacyProcessingStates(db);
    }
    if (oldV < 14) {
      await _restoreReportContentFromRaw(db);
    }
    if (oldV < 15) {
      // 2026-09-25 서버↔모바일 동등성 검수: NULL 상태 보정을 서버와 같게 다시 적용하고,
      // 서버에서 가져온 예전 데이터의 차량번호(다음 줄이 붙은 값)를 서버 repair_car_numbers 와 같게 고친다.
      await _normalizeLegacyProcessingStates(db);
      await _repairCarNumbersFromRaw(db);
    }
  }

  /// 서버 maintenance_service.repair_car_numbers 와 같은 규칙: 차량번호에 `*` 가 들어간 신고를 저장된 본문 원문으로 다시 뽑는다.
  /// 예전 서버 파서는 칸이 비면 다음 줄(`* 발생일자 …`)을 번호로 가져갔다. 앱 파서는 그런 값을 만들지 않았지만
  /// 그 서버 DB 를 가져오면 들어온다. 네트워크 없음. 반환: 고친 건수.
  @visibleForTesting
  static Future<int> repairCarNumbersForTest(DatabaseExecutor db) =>
      _repairCarNumbersFromRaw(db);

  static Future<int> _repairCarNumbersFromRaw(DatabaseExecutor db) async {
    final hasRaw = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='report_raw'",
    )).isNotEmpty;
    if (!hasRaw) return 0;
    final rows = await db.rawQuery(
      'SELECT r.ID, r.차량번호, w.raw_content FROM reports r '
      'JOIN report_raw w ON w.ID = r.ID '
      "WHERE r.차량번호 LIKE '%*%'",
    );
    var fixed = 0;
    for (final row in rows) {
      final old = row['차량번호']?.toString() ?? '';
      final repaired = extractCarNumber(row['raw_content']?.toString() ?? '');
      if (repaired != old) {
        await db.update(
          'reports',
          {'차량번호': repaired},
          where: 'ID = ?',
          whereArgs: [row['ID']],
        );
        fixed++;
      }
    }
    return fixed;
  }

  /// v14(2026-09-25 파서 통일): 예전 앱은 신고내용에서 "본 신고는 안전신문고 … 신고입니다" 안내 문장을 지웠다.
  /// 서버와 같은 규칙(본문에서 `* 차량번호` 앞까지, 안내 문장 유지)으로 저장된 원문(report_raw)에서 다시 만든다. 네트워크 없음.
  /// 원문이 없는 신고는 그대로 둔다. 반환: 고친 건수.
  @visibleForTesting
  static Future<int> restoreReportContentFromRawForTest(DatabaseExecutor db) =>
      _restoreReportContentFromRaw(db);

  static Future<int> _restoreReportContentFromRaw(DatabaseExecutor db) async {
    final hasRaw = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='report_raw'",
    )).isNotEmpty;
    if (!hasRaw) return 0;
    final rows = await db.rawQuery('''
      SELECT r.ID, r.신고내용, w.raw_content FROM reports r
      JOIN report_raw w ON w.ID = r.ID
      WHERE COALESCE(w.raw_content, '') != ''
    ''');
    var fixed = 0;
    for (final row in rows) {
      final restored = reportContentOf(
        normalizeRawPayloadText(row['raw_content'] as String?),
      );
      final current = (row['신고내용'] ?? '').toString();
      // 예전 앱이 안내 문장만 지운 행만 고친다(서버에서 가져온 다른 경로의 값은 건드리지 않음).
      final withoutIntro = restored
          .replaceAll(
            RegExp(r'본 신고는 안전신문고 (?:앱의|포털의) .+? 메뉴로 접수된 신고입니다\.?\s*'),
            '',
          )
          .trim();
      if (restored == current || withoutIntro != current.trim()) continue;
      await db.update(
        'reports',
        {'신고내용': restored},
        where: 'ID = ?',
        whereArgs: [row['ID']],
      );
      fixed++;
    }
    return fixed;
  }

  /// 주정차 사진 EXIF 촬영 시각(서버 `services/photo_capture_time.py` 가 채움). 서버 detail/merge 와 같은 이름·형식.
  /// NULL = 아직 시도 안 함, 사진_촬영수 0 = 촬영 정보 없음. 서버↔모바일 교환 대상(PROJECT_RULES §3-1).
  static const photoCaptureColumns = ['사진_첫촬영', '사진_끝촬영', '사진_촬영수'];

  static Future<void> _addPhotoCaptureColumns(DatabaseExecutor db) async {
    await addColumnIfMissing(db, 'reports', '사진_첫촬영', 'TEXT');
    await addColumnIfMissing(db, 'reports', '사진_끝촬영', 'TEXT');
    await addColumnIfMissing(db, 'reports', '사진_촬영수', 'INTEGER');
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
        보완_신고자_의견 TEXT DEFAULT '',
        사진_첫촬영       TEXT,
        사진_끝촬영       TEXT,
        사진_촬영수       INTEGER
      )
    ''');
    await _createRawTable(db);
    await _createGeocodeCacheTable(db);
    await DuplicateProjectionService.createSchema(db);
    await _createStorageTables(db);
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

  /// 계약 `change_tracked.columns` + category·entry_value(따로 비교) — 서버 CHANGE_TRACKED_COLUMNS 와 같아야 한다(테스트).
  @visibleForTesting
  static List<String> get syncedAtTrackedKeysForTest => _syncedAtTrackedKeys;

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

  /// 크롤링한 신고 1건을 저장한다(저장 계층 재설계 R3, 서버 core/storage/reports_repo.py 와 같은 규칙).
  /// - 기존 행은 사이트 열·계산 열만 UPDATE 한다. REPLACE 를 쓰지 않아 모델에 없는 열(사진 촬영 시각 등)이 지워지지 않는다.
  /// - 신고번호·신고명 같은 식별 정보는 빈 값으로 덮지 않는다.
  /// - 별점·사유·만족도조사여부는 [ratingLookup] 에 따라(결정 D-2·D-3): 사이트 값이 있으면 사이트, 조회 실패·미시도면 기존 유지,
  ///   '참여 완료' 는 되돌리지 않는다.
  /// - 변경 판정(synced_at): [_syncedAtTrackedKeys] + 본문, NULL 과 '' 는 같게. 본문·entry_value 는 이전 값이 있을 때만 비교.
  /// 반환: 새 신고인지, 저장으로 바뀌었는지(synced_at 을 갱신했는지 — 서버 reports_repo 의 "신규"/"변경" 판정과 같음), 저장된 synced_at.
  static Future<({bool isNew, bool changed, int syncedAt})> upsertReport(
    Report r,
    String category,
    String entryValue, {
    String rawContent = '',
    // 서버 parser 와 같게 상세 JSON 에서 뽑은 본문 원문의 종류는 'report_body'
    String rawType = 'report_body',
    RatingLookup ratingLookup = RatingLookup.notTried,
    PhotoCapture? photoCapture,
  }) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    var isNew = false;
    var changedResult = false;
    var syncedAtResult = now;
    await d.transaction((txn) async {
      final existingRows = await txn.query(
        'reports',
        where: 'ID = ?',
        whereArgs: [r.id],
        limit: 1,
      );
      final existing = existingRows.isEmpty
          ? null
          : Map<String, Object?>.from(existingRows.first);
      final watchlist = await _readWatchlist(txn);
      final geoPayload = prepareGeoPayloadForAddress(
        r.location,
        existingRecord: existing,
      );

      String keepIfEmpty(String column, String value) =>
          value.isNotEmpty ? value : (existing?[column]?.toString() ?? value);

      final existingPoll = existing?['만족도조사여부']?.toString();
      final Object? rating;
      final Object? ratingCause;
      switch (ratingLookup) {
        case RatingLookup.found:
          rating = r.rating;
          ratingCause = r.ratingCause;
        case RatingLookup.failed:
          rating = r.rating ?? existing?['별점'];
          ratingCause = existing?['별점사유'] ?? r.ratingCause;
        case RatingLookup.notTried:
          rating = r.rating ?? existing?['별점'];
          ratingCause = existing == null ? r.ratingCause : existing['별점사유'];
        case RatingLookup.confirmedNone:
          rating = null;
          ratingCause = '';
      }
      // '참여 완료' 는 되돌리지 않는다 — 조회가 미참여를 확정했을 때만 예외(결정 D-3).
      final poll = ratingLookup == RatingLookup.confirmedNone
          ? '참여 가능'
          : existingPoll == '참여 완료' && r.pollStatus != '참여 완료'
          ? existingPoll
          : r.pollStatus;

      final siteRow = <String, Object?>{
        '상태': keepIfEmpty('상태', r.result),
        '신고번호': keepIfEmpty('신고번호', r.reportNumber),
        '신고명': keepIfEmpty('신고명', r.name),
        '신고일': keepIfEmpty('신고일', r.date),
        '만족도조사여부': poll,
        '별점': rating,
        '별점사유': ratingCause,
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
        '보완횟수': r.supplementCount,
        '보완_미응답': r.supplementOpen ? 'Y' : 'N',
        '보완_요청자': r.supplementRequester,
        '보완_요청일시': r.supplementRequestedAt,
        '보완_완료일시': r.supplementCompletedAt,
        '보완_요청_내용': r.supplementRequest,
        '보완_신고자_의견': r.supplementOpinion,
        for (final e in geoPayload.entries) e.key: e.value,
        '감시목록': watchlist.contains(r.reportNumber) ? 'Y' : 'N',
        // 사진 촬영 시각: 트랜잭션 밖에서 읽어 온 값. 이미 있는 값은 이어받는다(변경 판정 대상 아님).
        if (photoCapture != null && existing?['사진_촬영수'] == null) ...{
          '사진_첫촬영': photoCapture.first,
          '사진_끝촬영': photoCapture.last,
          '사진_촬영수': photoCapture.count,
        },
      };

      int syncedAt = now;
      // 본문 원문: 서버 reports_repo._save_raw 와 같은 규칙 — 새 원문이 비면 기존 것을 그대로 두고(변경 아님),
      // 있으면 이전 원문과 내용·종류 중 하나라도 다를 때 변경.
      final existingRaw = await _getRawPayload(txn, r.id);
      final rawChanged =
          rawContent.trim().isNotEmpty &&
          existingRaw != null &&
          (_stringify(existingRaw['raw_content']) != rawContent ||
              _stringify(existingRaw['raw_type']) != rawType);
      if (existing != null) {
        final tracked = _syncedAtTrackedKeys.where(
          (k) => k != 'entry_value' && k != 'category',
        );
        final changed =
            tracked.any(
              (k) => _stringify(existing[k]) != _stringify(siteRow[k]),
            ) ||
            existing['category'] != category ||
            (_stringify(existing['entry_value']).isNotEmpty &&
                existing['entry_value'] != entryValue) ||
            rawChanged;
        syncedAt = changed
            ? now
            : (_toEpochMillis(existing['synced_at']) ?? now);
        changedResult = changed;
        await txn.update(
          'reports',
          {...siteRow, 'synced_at': syncedAt},
          where: 'ID = ?',
          whereArgs: [r.id],
        );
      } else {
        isNew = true;
        changedResult = true;
        await txn.insert('reports', {
          'ID': r.id,
          ...siteRow,
          'raw_content': '',
          'synced_at': syncedAt,
        });
      }
      syncedAtResult = syncedAt;
      if (rawContent.trim().isNotEmpty) {
        final previousSavedAt = _toEpochMillis(existingRaw?['saved_at']);
        await _replaceRawPayload(
          txn,
          r.id,
          rawContent: rawContent,
          rawType: rawType,
          savedAt: existingRaw == null || rawChanged || previousSavedAt == null
              ? now
              : previousSavedAt,
        );
      }
    });
    _invalidateProjectRowsCache();
    return (isNew: isNew, changed: changedResult, syncedAt: syncedAtResult);
  }

  static Future<Set<String>> _readWatchlist(DatabaseExecutor db) async {
    final rows = await db.query(
      'sync_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['watchlist'],
    );
    final raw = rows.isEmpty ? '' : (rows.first['value']?.toString() ?? '');
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  // ── 신고 조회 ─────────────────────────────────────────────────────────────

  /// 리스트 로드용 청크 조회.
  ///
  /// sqflite 는 쿼리 결과 전체를 하나의 연속 DirectByteBuffer 로 직렬화해
  /// MethodChannel 로 넘긴다. 신고가 수천~수만 건 쌓이면 이 단일 버퍼가 커져
  /// `OutOfMemoryError`(ByteBuffer.allocateDirect) 로 죽는다.
  /// ID(PRIMARY KEY) 기준 keyset 페이지네이션으로 나눠 읽어 Dart 리스트에 누적하면
  /// per-query 버퍼가 작게 유지된다. 최종 정렬/집계는 호출부에서 다시 하므로
  /// 여기서는 조회 순서(ID)만 유지해도 결과가 동일하다.
  static const int _kListChunkSize = 1000;

  static Future<List<Map<String, dynamic>>> _queryReportsChunked(
    DatabaseExecutor d, {
    String? where,
    List<dynamic>? whereArgs,
  }) async {
    final all = <Map<String, dynamic>>[];
    String? lastId;
    while (true) {
      final clauses = <String>[];
      final args = <dynamic>[];
      if (where != null && where.trim().isNotEmpty) {
        clauses.add('($where)');
        if (whereArgs != null) args.addAll(whereArgs);
      }
      if (lastId != null) {
        clauses.add('ID > ?');
        args.add(lastId);
      }
      final rows = await d.query(
        effectiveReportsView,
        where: clauses.isEmpty ? null : clauses.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'ID',
        limit: _kListChunkSize,
      );
      all.addAll(rows);
      if (rows.length < _kListChunkSize) break;
      final next = rows.last['ID'];
      if (next is! String || next.isEmpty) break;
      lastId = next;
    }
    return all;
  }

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
      where += " AND IFNULL(처리상태, '') != '취하'";
    }
    final rows = await _queryReportsChunked(d, where: where, whereArgs: args);
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
    final rows = await _queryReportsChunked(
      d,
      where: excludeWithdraw ? "IFNULL(처리상태, '') != '취하'" : null,
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

  /// 동기화 엔진이 다시 받을 신고를 고를 때 쓰는 사이트 원본 상태(수정값 제외, 필요한 열만 — M-17).
  static Future<
    Map<String, ({String status, String finished, String supplementOpen})>
  >
  getSyncStates() async {
    final d = await db;
    final rows = await d.query(
      'reports',
      columns: ['ID', '처리상태', '종결여부', '보완_미응답'],
    );
    return {
      for (final r in rows)
        r['ID'] as String: (
          status: _stringify(r['처리상태']),
          finished: _stringify(r['종결여부']),
          supplementOpen: _stringify(r['보완_미응답']),
        ),
    };
  }

  static Future<Report?> getReport(String cNo) async {
    final d = await db;
    final rows = await d.query(
      effectiveReportsView,
      where: 'ID = ?',
      whereArgs: [cNo],
    );
    return rows.isEmpty ? null : _rowToReport(rows.first);
  }

  /// 신고번호(STTEMNT_NO, SPP-...)로 DB 조회. 단건 자동 sync 용.
  static Future<Report?> getReportByNumber(String reportNumber) async {
    final d = await db;
    final rows = await d.query(
      effectiveReportsView,
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
    _invalidateProjectRowsCache(); // 별점은 대표건 선정에 쓰인다(M-4)
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
      await _queryReportsChunked(d),
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
    final rows = await _queryStatsRows(
      d,
      year: year,
      law: law,
      excludeWithdraw: excludeWithdraw,
      useRepresentativeRecords: useRepresentativeRecords,
    );

    // available_years 는 필터와 무관하게 전체에서(서버 _load_stats_frames 와 같음).
    var allRows = await d.query(
      effectiveReportsView,
      columns: ['답변일', '위반법규', 'category'],
    );
    // available_laws 는 서버 get_agency_stats 처럼 연도·취하 제외·대표건을 적용한 뒤, 법규 필터는 빼고 만든다
    // (2026-09-25 서버↔모바일 계산 동등성 검사에서 발견 — 예전엔 전체 행에서 만들어 필터와 어긋났다).
    final lawScopeRows = law == null
        ? rows
        : await _queryStatsRows(
            d,
            year: year,
            excludeWithdraw: excludeWithdraw,
            useRepresentativeRecords: useRepresentativeRecords,
          );
    return _aggregateStats(rows, allRows, lawScopeRows, normalizePolice);
  }

  /// 통계 요약 카드 + 월별 추이 (서버 `get_stats_overview` 와 같은 정의).
  /// [computeStats] 와 같은 행(연도·법규·취하 제외·대표건)을 사용한다.
  static Future<Map<String, dynamic>> computeStatsOverview({
    String? year,
    String? law,
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    final rows = await _queryStatsRows(
      d,
      year: year,
      law: law,
      excludeWithdraw: excludeWithdraw,
      useRepresentativeRecords: useRepresentativeRecords,
    );
    List<Map<String, dynamic>> byCategory(String category) =>
        rows.where((r) => r['category'] == category).toList(growable: false);
    return {
      'all': summarizeOverviewRows(rows),
      'traffic': summarizeOverviewRows(byCategory('traffic')),
      'parking': summarizeOverviewRows(byCategory('parking')),
      'other': summarizeOverviewRows(byCategory('other')),
      'year_basis': '답변일',
      'exclude_withdraw': excludeWithdraw,
    };
  }

  static Future<List<Map<String, dynamic>>> _queryStatsRows(
    Database d, {
    String? year,
    String? law,
    required bool excludeWithdraw,
    required bool useRepresentativeRecords,
  }) async {
    String where = '1=1';
    final args = <dynamic>[];

    if (year != null) {
      // S-08: 연도는 답변일 기준(서버 /stats 와 동일).
      where += ' AND 답변일 LIKE ?';
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
      where += " AND IFNULL(처리상태, '') != '취하'";
    }

    final rows = await d.query(
      effectiveReportsView,
      where: where,
      whereArgs: args.isEmpty ? null : args,
    );
    return _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );
  }

  static const _overviewCompletedStatuses = {'수용', '불수용', '일부수용', '기타', '답변완료'};
  static const _overviewProcessingStatuses = {'처리중', '진행', '진행중', '검토중'};

  static DateTime? _parseOverviewDate(Object? value) {
    final text = (value?.toString() ?? '').trim();
    if (text.length < 10) return null;
    final m = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})$',
    ).firstMatch(text.substring(0, 10));
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final da = int.parse(m.group(3)!);
    final date = DateTime.utc(y, mo, da);
    // 2026-02-30 같은 값은 DateTime 이 넘겨 버리므로 거꾸로 확인한다.
    if (date.year != y || date.month != mo || date.day != da) return null;
    return date;
  }

  static String _monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// 서버 `_summarize_overview_frame` 과 같은 정의. 평균 처리일은 기관 평균을 합치지 않고
  /// 완료 상태이면서 두 날짜가 모두 유효하고 차이 >= 0 인 신고만으로 직접 계산하며 표본 수를 함께 돌려준다.
  @visibleForTesting
  static Map<String, dynamic> summarizeOverviewRows(
    List<Map<String, dynamic>> rows,
  ) {
    var completed = 0, accept = 0, partial = 0, reject = 0;
    var supplement = 0, processing = 0, withdraw = 0;
    var reversed = 0, undated = 0, daySum = 0, dayCount = 0;
    final reportedByMonth = <String, int>{};
    final answeredByMonth = <String, int>{};

    for (final r in rows) {
      final status = (r['처리상태']?.toString() ?? '').trim();
      if (_overviewCompletedStatuses.contains(status)) completed++;
      if (status == '수용') accept++;
      if (status == '일부수용') partial++;
      if (status == '불수용' || status == '기타') reject++;
      if (status == '보완요청') supplement++;
      if (_overviewProcessingStatuses.contains(status)) processing++;
      if (status == '취하') withdraw++;

      final reported = _parseOverviewDate(r['신고일']);
      final answered = _parseOverviewDate(r['답변일']);
      if (reported == null) {
        undated++;
      } else {
        final key = _monthKey(reported);
        reportedByMonth[key] = (reportedByMonth[key] ?? 0) + 1;
      }
      if (answered != null) {
        final key = _monthKey(answered);
        answeredByMonth[key] = (answeredByMonth[key] ?? 0) + 1;
      }
      // S-10: 평균 처리기간은 완료 신고만(기관표와 같은 기준).
      if (_overviewCompletedStatuses.contains(status) &&
          reported != null &&
          answered != null) {
        final days = answered.difference(reported).inDays;
        if (days < 0) {
          reversed++;
        } else {
          daySum += days;
          dayCount++;
        }
      }
    }

    List<Map<String, dynamic>> series(Map<String, int> source) {
      final keys = source.keys.toList()..sort();
      return [
        for (final k in keys) {'month': k, 'count': source[k]},
      ];
    }

    return {
      'total': rows.length,
      'completed': completed,
      'accept': accept,
      'partial': partial,
      'reject': reject,
      'supplement': supplement,
      'processing': processing,
      'withdraw': withdraw,
      'avg_days': dayCount == 0
          ? null
          : double.parse((daySum / dayCount).toStringAsFixed(1)),
      'avg_days_count': dayCount,
      'reversed_date_count': reversed,
      'undated_report_count': undated,
      'monthly_reported': series(reportedByMonth),
      'monthly_answered': series(answeredByMonth),
    };
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
      // S-08: 서버 지도 통계와 같은 답변일 기준.
      where += ' AND 답변일 LIKE ?';
      args.add('$year%');
    }
    if (excludeWithdraw) {
      where += " AND IFNULL(처리상태, '') != '취하'";
    }

    var rows = await d.query(
      effectiveReportsView,
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

    final agencyCount = rows
        .map((row) {
          final raw = _stringify(row['처리기관']).trim();
          if (raw.isEmpty) return '';
          return normalizePolice ? normalizePoliceAgency(raw) : raw;
        })
        .where((name) => name.isNotEmpty)
        .toSet()
        .length;

    var allYearRows = await d.query(effectiveReportsView, columns: ['답변일']);
    final availableYears =
        allYearRows
            .map((row) => _stringify(row['답변일']))
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
          'agency_count': 0,
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
        'agency_count': agencyCount,
      },
    };
  }

  static Future<Map<String, dynamic>> computeReportMapMissingGroups({
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
      // S-08: 서버 지도 통계와 같은 답변일 기준.
      where += ' AND 답변일 LIKE ?';
      args.add('$year%');
    }
    if (excludeWithdraw) {
      where += " AND IFNULL(처리상태, '') != '취하'";
    }

    var rows = await d.query(
      effectiveReportsView,
      columns: [
        'ID',
        '신고번호',
        '신고명',
        '신고일',
        '답변일',
        '처리기관',
        '담당자',
        '처리상태',
        '상태',
        '범칙금_과태료',
        '벌점',
        '차량번호',
        '위반법규',
        '위반장소',
        '발생일자',
        '발생시각',
        '신고내용',
        '처리내용',
        '첨부사진',
        '첨부파일',
        '지도',
        '만족도조사여부',
        '종결여부',
        '별점',
        '별점사유',
        'synced_at',
        '보완횟수',
        '보완_미응답',
        '보완_요청자',
        '보완_요청일시',
        '보완_완료일시',
        '보완_요청_내용',
        '보완_신고자_의견',
        '주소정규화',
        '행정구역',
        '위도',
        '경도',
        'category',
      ],
      where: where,
      whereArgs: args.isEmpty ? null : args,
    );
    rows = await _projectRows(
      d,
      rows,
      useRepresentativeRecords: useRepresentativeRecords,
    );

    final groupsByKey = <String, List<Map<String, dynamic>>>{};
    for (final rawRow in rows) {
      final row = Map<String, dynamic>.from(rawRow);
      final lat = parseGeoDouble(row['위도']);
      final lng = parseGeoDouble(row['경도']);
      final normalizedAddress =
          normalizeGeocodeAddress(row['주소정규화']?.toString()) == ''
          ? normalizeGeocodeAddress(row['위반장소']?.toString())
          : normalizeGeocodeAddress(row['주소정규화']?.toString());
      final address = _stringify(row['위반장소']).trim();
      final addressKey = normalizedAddress.isNotEmpty
          ? normalizedAddress
          : address;
      final hasValidCoordinates = lat != null && lng != null;

      if (addressKey.isEmpty || hasValidCoordinates) {
        continue;
      }
      row['위도'] = lat;
      row['경도'] = lng;
      row['주소정규화'] = normalizedAddress;
      groupsByKey
          .putIfAbsent(addressKey, () => <Map<String, dynamic>>[])
          .add(row);
    }

    final groups = <Map<String, dynamic>>[];
    for (final entry in groupsByKey.entries) {
      final groupRows = entry.value;
      groupRows.sort((left, right) {
        final leftDate = _stringify(left['신고일']);
        final rightDate = _stringify(right['신고일']);
        final dateCompare = rightDate.compareTo(leftDate);
        if (dateCompare != 0) return dateCompare;
        return _stringify(left['신고번호']).compareTo(_stringify(right['신고번호']));
      });

      final first = groupRows.first;
      final reports = groupRows
          .map((row) => _rowToReport(row, normalizePolice: normalizePolice))
          .toList();
      groups.add({
        'address': _stringify(first['위반장소']).trim().isNotEmpty
            ? _stringify(first['위반장소']).trim()
            : entry.key,
        'normalized_address': entry.key,
        'region': _stringify(first['행정구역']).trim(),
        'report_count': reports.length,
        'reports': reports
            .map(
              (report) => {
                'ID': report.id,
                '신고번호': report.reportNumber,
                '신고명': report.name,
                '신고일': report.date,
                '답변일': report.responseDate,
                '처리기관': report.agency,
                '담당자': report.manager,
                '처리상태': report.status,
                '상태': report.result,
                '범칙금_과태료': report.fineInfo,
                '벌점': report.penaltyPoints,
                '차량번호': report.carNumber,
                '위반법규': report.law,
                '위반장소': report.location,
                '발생일자': report.occurrenceDate,
                '발생시각': report.occurrenceTime,
                '신고내용': report.reportContent,
                '처리내용': report.processContent,
                '첨부사진': report.attachedPhotos,
                '첨부파일': report.attachedFiles,
                '지도': report.mapImage,
                '만족도조사여부': report.pollStatus,
                '종결여부': report.processingFinish,
                '별점': report.rating,
                '별점사유': report.ratingCause,
                'category': report.category,
                'synced_at': report.syncedAt,
                '보완횟수': report.supplementCount,
                '보완_미응답': report.supplementOpen ? 'Y' : 'N',
                '보완_요청자': report.supplementRequester,
                '보완_요청일시': report.supplementRequestedAt,
                '보완_완료일시': report.supplementCompletedAt,
                '보완_요청_내용': report.supplementRequest,
                '보완_신고자_의견': report.supplementOpinion,
              },
            )
            .toList(),
      });
    }

    groups.sort((left, right) {
      final countCompare = (right['report_count'] as int).compareTo(
        left['report_count'] as int,
      );
      if (countCompare != 0) return countCompare;
      return _stringify(
        left['address'],
      ).compareTo(_stringify(right['address']));
    });

    return {
      'groups': groups,
      'meta': {
        'group_count': groups.length,
        'report_count': groups.fold<int>(
          0,
          (sum, group) => sum + ((group['report_count'] as int?) ?? 0),
        ),
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
      _buildMapRatioItem('미확인', pendingCount, total),
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
    List<Map<String, dynamic>> lawScopeRows,
    bool normalizePolice,
  ) {
    final traffic = rows.where((r) => r['category'] == 'traffic').toList();
    final parking = rows.where((r) => r['category'] == 'parking').toList();
    final other = rows.where((r) => r['category'] == 'other').toList();

    // 연도 목록은 항상 전체에서 추출 (필터 변경 시 다른 연도 선택지 유지). S-08: 답변일 기준.
    final years =
        allRows
            .map(
              (r) => (r['답변일'] as String? ?? '').length >= 4
                  ? (r['답변일'] as String).substring(0, 4)
                  : '',
            )
            .where((y) => RegExp(r'^\d{4}$').hasMatch(y))
            .where((y) => y.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));

    return {
      'traffic': buildStatsCategory(
        traffic,
        lawScopeRows.where((r) => r['category'] == 'traffic').toList(),
        normalizePolice,
      ),
      'parking': buildStatsCategory(
        parking,
        lawScopeRows.where((r) => r['category'] == 'parking').toList(),
        normalizePolice,
      ),
      'other': buildStatsCategory(
        other,
        lawScopeRows.where((r) => r['category'] == 'other').toList(),
        normalizePolice,
      ),
      'available_years': years,
    };
  }

  static const _unassignedPersonValues = {'', '미지정'};

  /// 한 카테고리의 기관별/담당자별 표. 서버 `_build_stats_tables` 와 같은 규칙(S-10).
  @visibleForTesting
  static Map<String, dynamic> buildStatsCategory(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> lawScopeCatRows,
    bool normalizePolice,
  ) {
    // 경찰기관 정규화: 집계 키 단계에서 처리해 같은 경찰서로 통합
    String agencyKey(String raw) {
      final t = raw.trim();
      if (!normalizePolice) return t;
      return normalizePoliceAgency(t);
    }

    // S-10: 표 포함 여부는 처리상태가 아니라 기관·담당자 값으로 정한다(서버 `_build_stats_tables` 와 동일).
    // 배정된 처리중 신고도 들어가고 `in_progress` 로 따로 센다. 기관이 비면 어느 표에도 넣지 않는다.
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
      if (agency.isEmpty || _unassignedPersonValues.contains(manager)) continue;
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
        lawScopeCatRows
            .map((r) => r['위반법규'] as String? ?? '')
            .where((l) => l.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final hasEmptyLaw = lawScopeCatRows.any(
      (r) => (r['위반법규'] as String? ?? '').isEmpty,
    );

    int categoryTotalFine = 0;
    int categoryEstimatedFineAmount = 0;
    int categoryEstimatedFineCount = 0;
    for (final r in rows) {
      final fine = r['범칙금_과태료'] as String? ?? '';
      final fineAmount = extractFineAmount(fine);
      categoryTotalFine += fineAmount;
      if (fine.contains('과태료') && fineAmount == 0) {
        final est = fine_estimate.estimate(r);
        if (est != null) {
          categoryEstimatedFineAmount += est['amount'] as int;
          categoryEstimatedFineCount++;
        }
      }
    }

    return {
      'by_agency': allAgency,
      'by_person': allPerson,
      'police_by_agency': policeAgency,
      'police_by_person': policePerson,
      'other_by_agency': nonPoliceAgency,
      'other_by_person': nonPolicePerson,
      'available_laws': allLaws,
      'has_empty_law': hasEmptyLaw,
      'total_fine_amount': categoryTotalFine,
      'estimated_fine_amount': categoryEstimatedFineAmount,
      'estimated_fine_count': categoryEstimatedFineCount,
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
    final withdrawFilter = excludeWithdraw
        ? "AND IFNULL(처리상태, '') != '취하'"
        : '';
    // 신고번호 DESC 가 유니크 tiebreaker 라 LIMIT/OFFSET 페이지 경계에서
    // 누락/중복 없이 전체 정렬 순서를 그대로 유지한다.
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final page = await d.rawQuery(
        '''
        WITH dup_vehicles AS (
          SELECT 차량번호,
                 COUNT(*)                                                 AS total_count,
                 SUM(CASE WHEN IFNULL(처리상태, '') != '취하' THEN 1 ELSE 0 END)        AS valid_count,
                 MAX(신고번호)                                              AS max_report_no
          FROM $effectiveReportsView
          WHERE 차량번호 != '' $withdrawFilter
          GROUP BY 차량번호
          HAVING COUNT(*) >= 2
        )
        SELECT r.*,
               dv.total_count,
               dv.valid_count
        FROM $effectiveReportsView r
        INNER JOIN dup_vehicles dv ON r.차량번호 = dv.차량번호
        WHERE r.차량번호 != '' $withdrawFilter
        ORDER BY dv.max_report_no DESC, r.차량번호 ASC, r.신고번호 DESC
        LIMIT ? OFFSET ?
      ''',
        [_kListChunkSize, offset],
      );
      rows.addAll(page);
      if (page.length < _kListChunkSize) break;
      offset += _kListChunkSize;
    }
    return rows
        .map((r) => _rowToReportWithCounts(r, normalizePolice: normalizePolice))
        .toList();
  }

  static Report _rowToReportWithCounts(
    Map<String, dynamic> r, {
    bool normalizePolice = false,
  }) {
    // 같은 변환 두 벌을 하나로(M-30): 기본 변환 + 중복 건수만 덧붙인다.
    return _rowToReport(r, normalizePolice: normalizePolice).copyWith(
      totalCount: (r['total_count'] as num?)?.toInt() ?? 0,
      validCount: (r['valid_count'] as num?)?.toInt() ?? 0,
    );
  }

  // ── 감시목록 ──────────────────────────────────────────────────────────────

  static Future<Set<String>> getWatchlistNumbers() async {
    final raw = await getMeta('watchlist') ?? '';
    if (raw.isEmpty) return {};
    return raw.split(',').where((s) => s.isNotEmpty).toSet();
  }

  static Future<void> setWatchlistNumbers(Set<String> numbers) async {
    final d = await db;
    await d.transaction((txn) => _writeWatchlist(txn, numbers));
    _invalidateProjectRowsCache();
  }

  /// DB 에 있는 현재 목록을 읽어 더하거나 뺀다(화면 메모리의 옛 목록으로 덮지 않음 — M-7). 결과 목록을 돌려준다.
  static Future<Set<String>> changeWatchlist({
    Iterable<String> add = const [],
    Iterable<String> remove = const [],
  }) async {
    final d = await db;
    late Set<String> next;
    await d.transaction((txn) async {
      next = {...await _readWatchlist(txn), ...add}..removeAll(remove);
      await _writeWatchlist(txn, next);
    });
    _invalidateProjectRowsCache();
    return next;
  }

  /// 감시목록의 원천은 sync_meta 'watchlist'. reports.감시목록 은 거기서 계산한 표시값이다. 한 트랜잭션으로 쓴다(M-6).
  static Future<void> _writeWatchlist(
    Transaction txn,
    Set<String> numbers,
  ) async {
    await txn.insert('sync_meta', {
      'key': 'watchlist',
      'value': numbers.join(','),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await txn.rawUpdate(
      "UPDATE reports SET 감시목록 = 'N' WHERE 감시목록 != 'N' OR 감시목록 IS NULL",
    );
    final list = numbers.toList();
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, (i + 500).clamp(0, list.length));
      final marks = List.filled(chunk.length, '?').join(',');
      await txn.rawUpdate(
        "UPDATE reports SET 감시목록 = 'Y' WHERE 신고번호 IN ($marks)",
        chunk,
      );
    }
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
    final withdrawFilter = excludeWithdraw
        ? " AND IFNULL(처리상태, '') != '취하'"
        : '';
    final rows = await d.rawQuery(
      'SELECT * FROM $effectiveReportsView WHERE 신고번호 IN ($placeholders)$withdrawFilter ORDER BY 신고일 DESC',
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
      where += " AND IFNULL(처리상태, '') != '취하'";
    }
    final rows = await d.query(
      effectiveReportsView,
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

  /// 전체 재동기화에서 사이트 목록에 없는 신고를 정리한다. 수정값도 함께 지운다(신고가 사라졌으므로).
  static Future<int> removeReportsNotIn(Set<String> keepIds) async {
    if (keepIds.isEmpty) return 0;
    final d = await db;
    final existing = (await d.query(
      'reports',
      columns: ['ID'],
    )).map((r) => r['ID'] as String).toList();
    final stale = existing.where((id) => !keepIds.contains(id)).toList();
    if (stale.isEmpty) return 0;
    await d.transaction((txn) async {
      for (var i = 0; i < stale.length; i += 500) {
        final chunk = stale.sublist(i, (i + 500).clamp(0, stale.length));
        final marks = List.filled(chunk.length, '?').join(',');
        for (final table in ['reports', 'report_raw', 'report_override']) {
          await txn.delete(table, where: 'ID IN ($marks)', whereArgs: chunk);
        }
      }
    });
    _invalidateProjectRowsCache();
    return stale.length;
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
    // 실제 데이터 DB 는 건드리지 않고 데모 전용 파일로 바꿔서 채운다(M-24).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppPrefsKeys.standaloneDemoMode, true);
    await closeDb();
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
    _refuseDuringBackgroundWork('백업');
    await _withFileExclusive(() => _exportBackupLocked(targetPath));
  }

  static Future<void> _exportBackupLocked(String targetPath) async {
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

  static Future<void> _commitImportedDatabase(String importedDbPath) =>
      _withFileExclusive(() => _commitImportedDatabaseLocked(importedDbPath));

  static Future<void> _commitImportedDatabaseLocked(
    String importedDbPath,
  ) async {
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
      // 성공해도 남긴다 — 잘못 가져온 뒤 직전 DB 로 되돌릴 사본(감사 SOL-05). 최근 [importBackupKeep] 개만.
      backupPath =
          '$dbPath.before_import.${DateTime.now().millisecondsSinceEpoch}.bak';
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
      if (backupPath != null && !replacementSucceeded && restoreSucceeded) {
        // 교체 실패 → 원래 DB 를 되돌렸으니 같은 내용의 사본은 필요 없다.
        try {
          await File(backupPath).delete();
        } catch (_) {}
      }
    }
    if (replacementSucceeded) _pruneImportBackups(dbPath);
  }

  static const importBackupKeep = 3;

  /// 가져오기·복원 직전 사본 `<db>.before_import.<epoch ms>.bak` 은 최근 [importBackupKeep] 개만 남긴다.
  static void _pruneImportBackups(String dbPath) {
    final file = File(dbPath);
    final name = file.uri.pathSegments.last;
    try {
      final olds = file.parent.listSync().whereType<File>().where((f) {
        final n = f.uri.pathSegments.last;
        return n.startsWith('$name.before_import.') && n.endsWith('.bak');
      }).toList()..sort((a, b) => _backupStamp(a).compareTo(_backupStamp(b)));
      for (final f in olds.take(
        olds.length > importBackupKeep ? olds.length - importBackupKeep : 0,
      )) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 가장 최근 가져오기·복원 직전 사본으로 되돌린다(감사 SOL-05). 되돌리기도 복원이라 지금 DB 가 새 사본으로 남는다.
  /// 사본이 없으면 false.
  static Future<bool> revertToPreviousImport() async {
    final latest = await latestImportBackup();
    if (latest == null) return false;
    await replaceFromBackup(latest);
    return true;
  }

  /// 가장 최근 가져오기·복원 직전 사본(없으면 null) — 설정 화면의 되돌리기 버튼이 쓴다.
  static Future<String?> latestImportBackup() async {
    final dbPath = await getDbPath();
    final file = File(dbPath);
    final name = file.uri.pathSegments.last;
    if (!file.parent.existsSync()) return null;
    final list = file.parent.listSync().whereType<File>().where((f) {
      final n = f.uri.pathSegments.last;
      return n.startsWith('$name.before_import.') && n.endsWith('.bak');
    }).toList()..sort((a, b) => _backupStamp(a).compareTo(_backupStamp(b)));
    return list.isEmpty ? null : list.last.path;
  }

  static Future<Database> _createImportTargetDb(String path) async {
    final database = await openDatabase(
      path,
      version: dbVersion,
      onCreate: _create,
      // [이전 DB 업데이트 비활성 — 2026-09-26 초기화 크롤링 릴리스]
      // onUpgrade: _migrateLocalDatabase,
      onUpgrade: _refuseLegacyUpgrade,
    );
    await _ensureEffectiveView(database);
    return database;
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

  /// 서버 DB 의 표를 원시 값 그대로 읽는다. 표가 없으면(구서버) 빈 목록, 그 밖의 읽기 오류는 그대로 올린다
  /// (예전처럼 삼키면 조용히 빈 값이 들어갔다 — M-28). 가져오기는 임시 DB 에서 하므로 실패해도 기존 데이터는 그대로다.
  static Future<List<Map<String, Object?>>> _readServerTable(
    Database serverDb,
    Set<String> serverTables,
    String table,
  ) async {
    if (!serverTables.contains(table)) return const [];
    return serverDb.query(table);
  }

  /// 서버 신고 행을 **원본**(목록 mysafety + 상세 mysafetydetail_*)에서 읽는다.
  /// 서버 화면용 표(merge)에는 사용자 수정값과 "6개월 초과" 첨부 가림이 덮여 있어서, 그걸 앱 원본으로 저장하면
  /// 다시 서버로 복원할 때 사이트 원본이 사라진다(저장 계층 재설계 R2). 수정값은 report_override 로 따로 온다.
  /// 원본 표가 없는 옛 서버 DB 만 merge 를 읽는다.
  static Future<List<Map<String, Object?>>> _readServerReportRows(
    Database serverDb,
    Set<String> serverTables, {
    required String mergeTable,
    required String category,
  }) async {
    final detailTable = 'mysafetydetail_$category';
    if (!serverTables.contains('mysafety') ||
        !serverTables.contains(detailTable)) {
      return _readServerTable(serverDb, serverTables, mergeTable);
    }
    final titleColumns =
        (await serverDb.rawQuery('PRAGMA table_info("mysafety")'))
            .map((r) => r['name'] as String)
            .where((name) => name != 'ID')
            .map((name) => 't."$name" AS "$name"')
            .join(', ');
    return serverDb.rawQuery(
      'SELECT d.*, $titleColumns FROM "$detailTable" d '
      'JOIN "mysafety" t ON t.ID = d.ID',
    );
  }

  /// 계약 타입(integer/real)에 맞춘다. 숫자 문자열은 숫자로, 빈 문자열은 NULL 로(숫자 열에 '' 는 잘못된 값).
  static Object? _coerceForColumn(Object? value, String? declaredType) {
    if (value is! String) return value;
    final type = (declaredType ?? '').toUpperCase();
    if (type.contains('INT')) {
      if (value.trim().isEmpty) return null;
      return int.tryParse(value.trim()) ??
          double.tryParse(value.trim())?.toInt() ??
          value;
    }
    if (type.contains('REAL')) {
      if (value.trim().isEmpty) return null;
      return double.tryParse(value.trim()) ?? value;
    }
    return value;
  }

  static Future<Map<String, String>> _columnTypes(
    DatabaseExecutor db,
    String table,
  ) async => {
    for (final r in await db.rawQuery('PRAGMA table_info("$table")'))
      r['name'] as String: (r['type'] as String?) ?? '',
  };

  /// 서버 DB 에서 읽는 표에 이 앱이 모르는 열이 있고 그 열에 NULL 아닌 값('' 포함)이 있으면 교체 전에 멈춘다.
  /// 그대로 가져오면 그 값이 조용히 사라진다(PROJECT_RULES 3-1, 감사 SOL-02 — PC exchange.UnknownColumns 와 같은 규칙).
  /// 아는 열 = 이 앱의 대상 표 열(계약 storage-contract.json 과 같음 — test/storage/storage_contract_test.dart).
  static Future<void> _refuseUnknownServerColumns(
    Database serverDb,
    Set<String> serverTables,
    DatabaseExecutor localDb,
  ) async {
    final reportColumns = (await _columnTypes(localDb, 'reports')).keys.toSet();
    // 분류마다 실제로 읽는 표와 같게 고른다(_readServerReportRows 와 같은 조건 — Sol 재검증 SOL-02):
    // mysafety + 그 분류의 상세 표가 있으면 둘, 없으면 그 분류의 merge 표.
    final known = <String, Set<String>>{
      for (final c in const ['traffic', 'parking', 'other'])
        if (serverTables.contains('mysafety') &&
            serverTables.contains('mysafetydetail_$c')) ...{
          'mysafety': reportColumns,
          'mysafetydetail_$c': reportColumns,
        } else
          'mysafetymerge_$c': reportColumns,
      'mysafety_raw_content': (await _columnTypes(localDb, 'report_raw')).keys.toSet(),
      'mysafety_sync_meta': const {'key', 'value'},
      'mysafety_watchlist': const {'신고번호'},
      'mysafety_entry_value': const {'ID', 'entry_value'},
      'mysafety_geocode_cache': (await _columnTypes(localDb, 'geocode_cache')).keys.toSet(),
      'mysafety_duplicate_group':
          (await _columnTypes(localDb, DuplicateProjectionService.groupTable)).keys.toSet(),
      'mysafety_duplicate_member':
          (await _columnTypes(localDb, DuplicateProjectionService.memberTable)).keys.toSet(),
      'mysafety_report_override': (await _columnTypes(localDb, 'report_override')).keys.toSet(),
      'mysafety_duplicate_decision':
          (await _columnTypes(localDb, 'duplicate_decision')).keys.toSet(),
    };
    final problems = <String>[];
    for (final entry in known.entries) {
      if (!serverTables.contains(entry.key)) continue;
      for (final col in (await _columnTypes(serverDb, entry.key)).keys) {
        if (entry.value.contains(col)) continue;
        final n = Sqflite.firstIntValue(await serverDb.rawQuery(
              'SELECT COUNT(*) FROM "${entry.key}" WHERE "$col" IS NOT NULL',
            )) ??
            0;
        if (n > 0) problems.add('${entry.key}.$col($n행)');
      }
    }
    if (problems.isNotEmpty) {
      throw UnknownColumnsException(problems);
    }
  }

  // ── 서버 DB → 모바일 DB 변환 ────────────────────────────────────────────────

  /// 서버 DB (mysafetymerge_traffic / parking / other 3개 테이블 + mysafety_watchlist)
  /// 를 읽어 모바일 DB (단일 reports 테이블 + category 컬럼) 로 마이그레이션.
  ///
  /// [serverDbPath] 서버에서 받은 .db 파일의 절대 경로.
  /// 반환: 임포트한 신고 건수.
  static Future<int> importFromServerDb(String serverDbPath) async {
    _refuseDuringBackgroundWork('서버 DB 가져오기를');
    final preparedDbPath = await _prepareExternalDbSnapshot(serverDbPath);
    final serverDb = await openDatabase(preparedDbPath, readOnly: true);
    Directory? stagingDir;
    Database? localDb;

    try {
      // 이전(또는 더 새) 버전 서버 DB 는 가져오지 않는다(2026-09-26 초기화 크롤링 릴리스).
      _refuseOtherVersion(await serverDb.getVersion(), serverSchemaVersion, '서버');
      await _validateServerDbSchema(serverDb);

      stagingDir = await Directory.systemTemp.createTemp(
        'mysafetyreport_import_staged_',
      );
      final stagedDbPath = join(
        stagingDir.path,
        'standalone_reports_import.db',
      );
      localDb = await _createImportTargetDb(stagedDbPath);

      final serverTables = (await serverDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name'] as String).toSet();
      final reportTypes = await _columnTypes(localDb, 'reports');

      final entryValueById = <String, Object?>{
        for (final r in await _readServerTable(
          serverDb,
          serverTables,
          'mysafety_entry_value',
        ))
          r['ID'] as String: r['entry_value'],
      };
      final rawPayloadById = <String, Map<String, Object?>>{
        for (final r in await _readServerTable(
          serverDb,
          serverTables,
          'mysafety_raw_content',
        ))
          r['ID'] as String: r,
      };
      // 서버 sync_meta 의 'watchlist' 는 구서버의 낡은 사본일 수 있어 쓰지 않는다(S-15). 원천은 mysafety_watchlist.
      final syncMetaRows =
          (await _readServerTable(serverDb, serverTables, 'mysafety_sync_meta'))
              .where(
                (r) =>
                    r['key'] != 'map_backfill_state' && r['key'] != 'watchlist',
              )
              .toList();
      final watchNumbers =
          (await _readServerTable(serverDb, serverTables, 'mysafety_watchlist'))
              .map((r) => r['신고번호']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList();

      const sourceTableMap = {
        'mysafetymerge_traffic': 'traffic',
        'mysafetymerge_parking': 'parking',
        'mysafetymerge_other': 'other',
      };
      await _refuseUnknownServerColumns(serverDb, serverTables, localDb);
      const geoColumns = ['주소정규화', '행정구역', '위도', '경도', '지오코딩상태'];
      int imported = 0;

      await localDb.transaction((txn) async {
        // 행마다 insert 를 기다리면 Android 에서 행마다 플랫폼 채널 왕복이 생긴다 → 500개씩 묶어 보낸다(M-27).
        var batch = txn.batch();
        var queued = 0;
        Future<void> flush() async {
          if (queued == 0) return;
          await batch.commit(noResult: true);
          batch = txn.batch();
          queued = 0;
        }

        Future<void> put(String table, Map<String, Object?> row) async {
          batch.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          if (++queued >= 500) await flush();
        }

        for (final entry in sourceTableMap.entries) {
          final rows = await _readServerReportRows(
            serverDb,
            serverTables,
            mergeTable: entry.key,
            category: entry.value,
          );
          for (final row in rows) {
            final reportId = row['ID']?.toString() ?? '';
            if (reportId.isEmpty) continue;
            // 값은 바꾸지 않는다(NULL 은 NULL). 모바일에 있는 열만, 계약 타입에 맞춰.
            final importedRow = <String, Object?>{
              for (final e in row.entries)
                if (reportTypes.containsKey(e.key))
                  e.key: _coerceForColumn(e.value, reportTypes[e.key]),
              'category': entry.value,
              // 서버 행 없음 = 모름(NULL), 행의 값(빈 문자열 포함)은 그대로 — PC exchange 와 같은 규칙(감사 SOL-03).
              'entry_value': entryValueById[reportId],
              'raw_content': '',
            };
            // 구서버에 지오코딩 열이 없을 때만 주소에서 계산한다(계산값, owner=derived).
            if (!geoColumns.any(row.containsKey)) {
              importedRow.addAll(
                prepareGeoPayloadForAddress(importedRow['위반장소']?.toString()),
              );
            }
            importedRow['감시목록'] = watchNumbers.contains(importedRow['신고번호'])
                ? 'Y'
                : 'N';
            await put('reports', importedRow);
            final raw = rawPayloadById[reportId];
            if (raw != null) {
              await put('report_raw', {
                'ID': reportId,
                'raw_content': raw['raw_content'],
                'raw_type': raw['raw_type'],
                'saved_at': raw['saved_at'],
              });
            }
            imported++;
          }
        }

        for (final row in syncMetaRows) {
          await put('sync_meta', row);
        }
        // 감시목록은 비어 있어도 기록한다(키가 없으면 앱이 예전 값을 남길 수 있음 — M-8).
        await put('sync_meta', {
          'key': 'watchlist',
          'value': watchNumbers.join(','),
        });

        const copied = {
          'mysafety_geocode_cache': 'geocode_cache',
          'mysafety_duplicate_group': DuplicateProjectionService.groupTable,
          'mysafety_duplicate_member': DuplicateProjectionService.memberTable,
          'mysafety_report_override': 'report_override',
          'mysafety_duplicate_decision': 'duplicate_decision',
        };
        for (final pair in copied.entries) {
          final types = await _columnTypes(txn, pair.value);
          for (final row in await _readServerTable(
            serverDb,
            serverTables,
            pair.key,
          )) {
            await put(pair.value, {
              for (final e in row.entries)
                if (types.containsKey(e.key))
                  e.key: _coerceForColumn(e.value, types[e.key]),
            });
          }
        }
        await flush();
      });

      if (imported <= 0) {
        throw Exception('임포트할 신고 데이터가 없습니다.');
      }
      final duplicateGroupCount =
          Sqflite.firstIntValue(
            await localDb.rawQuery(
              'SELECT COUNT(*) FROM ${DuplicateProjectionService.groupTable}',
            ),
          ) ??
          0;

      final hasLastSync = syncMetaRows.any(
        (row) => (row['key']?.toString() ?? '') == 'last_sync',
      );
      if (!hasLastSync) {
        await localDb.insert('sync_meta', {
          'key': 'last_sync',
          'value': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (duplicateGroupCount == 0) {
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
      // 개인 DB 교체 직전 커뮤니티 dataset 선회전 — 실패하면 교체하지 않는다(H-02).
      await _rotateCommunityDataset('server_import');
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

  /// 커뮤니티 dataset 선회전 (보수적): 개인 DB 파일을 교체하기 직전에 호출한다.
  /// 교체가 실패해도 되돌리지 않는다(초기화 1회 추가 비용). 저장소를 열 수 없으면
  /// 조용히 넘어간다 — 복원·가져오기를 막지 않는다.
  /// 모드 전환 DB 이관은 ReportProvider 쪽이므로 T5 가 같은 함수를 호출한다(REQUESTS.md).
  /// 개인 DB 를 다른 데이터셋으로 바꾸기 직전: 커뮤니티 dataset 을 선회전한다(S-20, PC exchange.restore 와 같은 규칙).
  /// 실패하면 교체하지 않는다 — 옛 journal 과 새 개인 DB 신고가 섞이는 것을 막는다(Sol 통합 검토 H-02).
  static Future<void> _rotateCommunityDataset(String reason) async {
    try {
      final store = await CommunityStore.open();
      await store.rotateDataset(reason);
    } catch (e) {
      throw Exception('커뮤니티 공유 저장소를 준비하지 못해 DB 를 바꾸지 않았습니다($reason). 다시 시도해 주세요. [$e]');
    }
  }

  /// 모바일 백업 .db 로 현재 DB 를 바꾼다(저장 계층 재설계 R1d, M-11).
  /// 임시 사본에서 종류·버전 확인 → 마이그레이션 → 무결성 검사를 마친 뒤 `_commitImportedDatabase` 로 교체한다
  /// (기존 DB 는 `<db>.before_import.<시각>.bak` 으로 남기고(최근 3개) 실패하면 되돌린다). 서버 DB 는 importFromServerDb 를 쓴다.
  static Future<void> replaceFromBackup(String backupDbPath) async {
    _refuseDuringBackgroundWork('백업 복원을');
    _invalidateProjectRowsCache();
    if (!File(backupDbPath).existsSync()) {
      throw Exception('백업 파일이 존재하지 않습니다: $backupDbPath');
    }
    final kind = await detectDbKind(backupDbPath);
    if (kind != 'mobile') {
      throw Exception('앱 백업 형식이 아닙니다($kind). 서버 DB 는 서버 DB 가져오기를 사용하세요.');
    }
    final preparedDbPath = await _prepareExternalDbSnapshot(backupDbPath);
    Directory? stagingDir;
    Database? staged;
    try {
      stagingDir = await Directory.systemTemp.createTemp(
        'mysafetyreport_restore_staged_',
      );
      final stagedPath = join(stagingDir.path, 'standalone_reports_restore.db');
      await File(preparedDbPath).copy(stagedPath);
      for (final ext in ['-wal', '-shm']) {
        final side = File('$preparedDbPath$ext');
        if (side.existsSync()) await side.copy('$stagedPath$ext');
      }

      final probe = await openDatabase(
        stagedPath,
        readOnly: true,
        singleInstance: false,
      );
      final version = await probe.getVersion();
      await probe.close();
      if (version <= 0) {
        throw Exception('백업 파일의 DB 버전을 알 수 없습니다.');
      }
      if (version > dbVersion) {
        throw Exception('더 새 버전 앱에서 만든 백업입니다(v$version). 앱을 업데이트한 뒤 복원하세요.');
      }
      // 이전 버전 앱 DB 는 옮기지 않는다(2026-09-26 초기화 크롤링 릴리스) — 예전엔 여기서 마이그레이션했다.
      _refuseOtherVersion(version, dbVersion, '모바일 앱');

      staged = await _createImportTargetDb(stagedPath);
      await staged.delete(
        'sync_meta',
        where: 'key = ?',
        whereArgs: ['map_backfill_state'],
      );
      await DuplicateProjectionService.refreshDuplicateGroups(staged);
      final integrity = (await staged.rawQuery(
        'PRAGMA integrity_check',
      )).first.values.first;
      if (integrity != 'ok') {
        throw Exception('백업 파일 무결성 검사 실패: $integrity');
      }
      await staged.close();
      staged = null;
      // 개인 DB 교체 직전 커뮤니티 dataset 선회전 — 실패하면 교체하지 않는다(H-02).
      await _rotateCommunityDataset('restore');
      await _commitImportedDatabase(stagedPath);
      _invalidateProjectRowsCache();
    } finally {
      if (staged != null) {
        try {
          await staged.close();
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

  static Future<Map<String, dynamic>?> getEditableRecord(
    String reportId,
  ) async {
    final d = await db;
    final rows = await d.query(
      effectiveReportsView,
      where: 'ID = ?',
      whereArgs: [reportId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  /// 사용자가 고친 필드 → 안전신문고 원본 값(편집 화면의 "수정됨"·원본 보기·되돌리기용, R4).
  static Future<Map<String, String?>> getSiteValuesOfEditedFields(
    String reportId,
  ) async {
    final d = await db;
    final edited = await d.query(
      'report_override',
      columns: ['column_name'],
      where: 'ID = ?',
      whereArgs: [reportId],
    );
    if (edited.isEmpty) return const {};
    final site = await d.query(
      'reports',
      where: 'ID = ?',
      whereArgs: [reportId],
      limit: 1,
    );
    if (site.isEmpty) return const {};
    return {
      for (final row in edited)
        row['column_name'] as String: site.first[row['column_name']]
            ?.toString(),
    };
  }

  static Future<bool> updateEditableRecord(
    String reportId,
    Map<String, dynamic> values,
  ) async {
    // 편집값은 사용자 수정값 표에 저장한다(결정 D-1, M-12). 사이트 원본(reports)은 그대로라 재조회가 편집을 되돌리지 않는다.
    // 보낸 필드만 다루고, 원본과 같아지면(앞뒤 공백 무시) 수정값을 지워 원본으로 되돌린다(M-13).
    final d = await db;
    final siteRows = await d.query(
      'reports',
      where: 'ID = ?',
      whereArgs: [reportId],
      limit: 1,
    );
    if (siteRows.isEmpty) return false;
    final site = siteRows.first;
    final editable = EditorSchema.defaultDetailFields.toSet();
    final now = DateTime.now().millisecondsSinceEpoch;
    await d.transaction((txn) async {
      for (final entry in values.entries) {
        if (!editable.contains(entry.key)) continue;
        final value = entry.value?.toString();
        if (value == '6개월 초과') continue; // 화면용 가림 글자는 수정값이 아니다
        await txn.delete(
          'report_override',
          where: 'ID = ? AND column_name = ?',
          whereArgs: [reportId, entry.key],
        );
        final siteValue = _stringify(site[entry.key]);
        if ((value ?? '') != siteValue &&
            (value ?? '').trim() != siteValue.trim()) {
          await txn.insert('report_override', {
            'ID': reportId,
            'column_name': entry.key,
            'value': value,
            'updated_at': now,
          });
        }
      }
    });
    _invalidateProjectRowsCache();
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
  int total = 0, fines = 0, warn = 0, reject = 0, unconfirmed = 0;

  /// S-10: 완료도 취하도 아닌 상태(처리중·진행·검토중·보완요청·이송·빈 값 등). 미분류와 따로 센다.
  int inProgress = 0;

  int dispositionUnknown = 0;
  int noPenalty = 0;
  int unclassified = 0;

  int totalFine = 0;
  int fineAmountUnknown = 0; // S-05: 과태료인데 금액을 읽지 못한 건(0원과 구분)
  int estimatedFineAmount = 0;
  int estimatedFineCount = 0;

  final List<int> responseDays = [];
  final List<int> ratings = []; // 1~5 별점 표본

  _AgencyAgg(this.name, this.person);

  void add(Map<String, dynamic> r) {
    total++;
    final status = (r['처리상태'] as String? ?? '').trim();
    final fine = (r['범칙금_과태료'] as String? ?? '');
    if (fine.contains('과태료')) fines++;
    if (fine.contains('경고') || fine.contains('범칙금')) warn++;
    if (status == '불수용' || status == '기타') reject++;
    final completed = LocalDbService._overviewCompletedStatuses.contains(
      status,
    );
    if (!fine.contains('과태료') &&
        !fine.contains('경고') &&
        !fine.contains('범칙금') &&
        status != '불수용' &&
        status != '기타') {
      if (!completed && status != '취하') {
        inProgress++;
      } else {
        unconfirmed++;
        final category = (r['category'] as String? ?? '').trim();
        final entry = (r['entry_value'] as String? ?? '').trim();
        final eligible =
            category == 'traffic' ||
            category == 'parking' ||
            entry.contains('자동차·교통위반') ||
            entry.contains('불법주정차신고') ||
            entry.contains('쓰레기, 폐기물');

        final isUnknown = fine.trim() == '미확인';
        if (isUnknown) {
          dispositionUnknown++;
        } else if (!eligible && completed) {
          noPenalty++;
        } else {
          unclassified++;
        }
      }
    }
    final fineAmount = extractFineAmount(fine);
    totalFine += fineAmount;
    if (fine.contains('과태료') && fineAmount == 0) {
      fineAmountUnknown++;
      final est = fine_estimate.estimate(r);
      if (est != null) {
        estimatedFineAmount += est['amount'] as int;
        estimatedFineCount++;
      }
    }

    final date = r['신고일'] as String? ?? '';
    final resp = r['답변일'] as String? ?? '';
    // S-10: 처리기간은 완료 신고만(이송 답변일이 붙은 처리중·취하 제외).
    if (completed && date.length >= 10 && resp.length >= 10) {
      try {
        final d = DateTime.parse(date.substring(0, 10));
        final rd = DateTime.parse(resp.substring(0, 10));
        final days = rd.difference(d).inDays;
        // S-01: 서버와 같이 날짜가 뒤바뀐(음수) 건은 평균에서 제외.
        if (days >= 0) responseDays.add(days);
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
      'unconfirmed': unconfirmed,
      'unconfirmed_pct': double.parse(
        (unconfirmed / t * 100).toStringAsFixed(1),
      ),
      'disposition_unknown': dispositionUnknown,
      'disposition_unknown_pct': double.parse(
        (dispositionUnknown / t * 100).toStringAsFixed(1),
      ),
      'no_penalty': noPenalty,
      'no_penalty_pct': double.parse((noPenalty / t * 100).toStringAsFixed(1)),
      'unclassified': unclassified,
      'unclassified_pct': double.parse(
        (unclassified / t * 100).toStringAsFixed(1),
      ),
      'in_progress': inProgress,
      'in_progress_pct': double.parse(
        (inProgress / t * 100).toStringAsFixed(1),
      ),
      'total_fine_amount': totalFine,
      'fine_amount_unknown': fineAmountUnknown,
      'estimated_fine_amount': estimatedFineAmount,
      'estimated_fine_count': estimatedFineCount,
      'avg_rating': avgRating,
      'rating_count': ratings.length,
      // S-01: 서버 _calc_avg_days 와 같이 소수 1자리.
      'avg_days': responseDays.isEmpty
          ? null
          : double.parse(
              (responseDays.reduce((a, b) => a + b) / responseDays.length)
                  .toStringAsFixed(1),
            ),
    };
  }
}
