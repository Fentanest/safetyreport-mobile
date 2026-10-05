import '../models/report_filter.dart';
import 'report_query.dart';
import 'performance_trace.dart';
import 'app_prefs_keys.dart';
import 'database_snapshot.dart';
import 'community_auth_service.dart';
import '../models/editor_schema.dart';
import '../models/rating_lookup.dart';
import '../storage/schema_utils.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting, listEquals;
import 'package:path/path.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine_estimate;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../community/community_store.dart';
import '../models/report.dart';
import 'agency_registry.dart';
import 'duplicate_projection_service.dart';
import 'geocode_utils.dart';
import 'local_database_exchange.dart';
import 'attachment_policy.dart';
import 'photo_capture_time.dart';

import 'standalone_parser.dart';
import 'report_policy.dart';

part 'local_statistics.dart';

/// registry 현행 기관 표시(확인된 1:1 승계만). 스냅샷 미로드·미확정이면
/// 원문으로 폴백한다 — PC `_apply_registry_agency_display` 와 같은 규칙.
/// [code] 는 원문 기관코드(TEXT·nullable), [raw] 는 원문 기관명이다.
String registryDisplayAgency(Object? code, String raw) {
  final trimmed = raw.trim();
  final resolved = AgencyRegistry.displayCurrentAgencyOrNull(
    code?.toString(),
    trimmed,
  );
  if (resolved != null && resolved.trim().isNotEmpty) return resolved;
  return trimmed;
}

/// registry 현행 표시 + 통계 키. 스냅샷 미로드면 (원문 표시, src 키)로
/// 폴백한다 — PC `_apply_registry_agency_display` 와 같은 규칙(키 포함).
/// 미확정도 항상 값을 낸다(호출자가 비어 제외 판단).
({String display, String key}) registryKeyedAgency(Object? code, String raw) {
  final trimmed = raw.trim();
  final codeText = code?.toString().trim();
  final c = (codeText == null || codeText.isEmpty) ? null : codeText;
  final keyed = AgencyRegistry.resolveKeyedAgencyOrNull(c, trimmed);
  if (keyed != null && keyed.key.isNotEmpty) return keyed;
  return (display: trimmed, key: 'src:${c ?? '-'}:$trimmed');
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
/// 다른 카카오 계정의 DB(또는 주인을 모르는 DB) — 가져오지 않는다(PC account_data.ForeignDatabaseRefused 와 같은 규칙).
class ForeignDatabaseException implements Exception {
  ForeignDatabaseException(this.message);
  final String message;

  @override
  String toString() => message;
}

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
    final pending = _initFuture ??= _open();
    try {
      final opened = await pending;
      if (identical(_initFuture, pending)) _db = opened;
      return opened;
    } catch (_) {
      if (identical(_initFuture, pending)) _initFuture = null;
      rethrow;
    }
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
    return join(dbPath, demo ? demoDbFileName : 'standalone_reports.db');
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
    if (Zone.current[_fileOpZoneKey] == true) return body();
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
      Database? open = _db;
      try {
        open ??= pending == null ? null : await pending;
      } catch (_) {
        // A failed open owns no connection. Close still clears its admission.
      }
      _db = null;
      _initFuture = null;
      await open?.close();
      _statsCache.clear();
      _summaryCache.clear();
      _mapCache.clear();
      _mapMetaCache.clear();
      _agencyLookupKey = null;
      _missingLookupKey = null;
    } finally {
      _closeRequested = false;
    }
  }

  /// 앱 DB 스키마 버전. contracts/storage-contract.json 의 schema_version.mobile 과 같아야 한다(테스트가 확인).
  static const dbVersion = 16;

  /// 서버 DB 스키마 버전(PRAGMA user_version). contracts/storage-contract.json 의 schema_version.server 와 같아야 한다(테스트가 확인).
  /// 서버 DB 가져오기는 정확히 이 버전만 받는다(이전 버전 서버 DB 는 거절).
  static const serverSchemaVersion = 5;

  static Future<Database> _open() async {
    final path = await getDbPath();
    await LocalDatabaseExchange.recover(path);
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
  static Future<void> _refuseLegacyUpgrade(
    Database db,
    int oldV,
    int newV,
  ) async {
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

  // ── 신고 자료의 주인 = 로그인한 카카오 계정 (2026-09-27 사용자 결정, PC services/account_data.py 와 같은 규칙) ──
  /// 이 DB 의 주인 카카오 회원번호(카카오가 준 숫자 ID 원문). 서버 DB `mysafety_sync_meta` 와 같은 키 — 교환 때 그대로 옮겨진다.
  static const kakaoMemberMetaKey = 'kakao_member_id';

  /// 지금 로그인한 카카오 회원번호(가져오기 검사용). 시험은 바꿔 끼운다. 확인할 수 없으면 null(→ 거절).
  @visibleForTesting
  static Future<String?> Function() currentKakaoId = _defaultCurrentKakaoId;

  static Future<String?> _defaultCurrentKakaoId() async {
    try {
      return await CommunityAuthService.instance.currentKakaoId();
    } catch (_) {
      return null;
    }
  }

  /// 가져올 DB 파일의 주인 카카오 회원번호. 서버 DB 는 mysafety_sync_meta, 모바일 DB 는 sync_meta.
  static Future<String?> _fileOwner(Database source, String table) async {
    try {
      final rows = await source.rawQuery(
        'SELECT value FROM $table WHERE key = ?',
        [kakaoMemberMetaKey],
      );
      final value = rows.isEmpty ? null : rows.first['value'];
      return value is String && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// 가져오기·복원 전: 파일의 주인이 지금 로그인한 카카오 계정과 같아야 한다. 무엇이든 바꾸기 전에 부른다.
  static Future<void> _refuseForeignOwner(Database source, String table) async {
    final current = await currentKakaoId();
    if (current == null) {
      throw ForeignDatabaseException(
        '카카오 로그인을 확인하지 못해 DB 를 가져올 수 없습니다. 다시 로그인한 뒤 시도하세요.',
      );
    }
    final owner = await _fileOwner(source, table);
    if (owner == null) {
      throw ForeignDatabaseException(
        '누구의 자료인지 알 수 없는 DB(카카오 계정 정보가 없는 이전 DB)는 가져올 수 없습니다. '
        '초기화 크롤링으로 안전신문고에서 다시 받으세요.',
      );
    }
    if (owner != current) {
      throw ForeignDatabaseException(
        '다른 카카오 계정의 DB 는 가져올 수 없습니다. 지금 로그인한 계정으로 만든 DB 만 가져올 수 있습니다.',
      );
    }
  }

  static Future<String?> dbOwner() => getMeta(kakaoMemberMetaKey);

  /// 게이트 통과 뒤(Standalone): 'ok'(같음·처음이라 적음) | 'mismatch'(다른 계정의 자료) | 'unknown'(로그인 계정 번호를 모름).
  static Future<String> checkOwner(String? kakaoId) async {
    if (kakaoId == null || kakaoId.isEmpty) return 'unknown';
    final owner = await dbOwner();
    if (owner == null || owner.isEmpty) {
      await setMeta(kakaoMemberMetaKey, kakaoId);
      return 'ok';
    }
    return owner == kakaoId ? 'ok' : 'mismatch';
  }

  /// 카카오 로그아웃(또는 다른 계정으로 시작)할 때: 신고 자료만 비운다. 남기는 것은 이전 DB 초기화와 같다
  /// (감시목록 `sync_meta['watchlist']`·지오코딩 캐시 — [legacyKept]). 데이터 주인 표시도 지워져 다음 로그인 계정이 새 주인이 된다
  /// ([thenOwner] 를 주면 비운 뒤 그 번호를 적는다). 백업은 만들지 않는다(사용자에게 지운다고 알린 자료).
  /// 동기화·지도 변환 중이면 거절(아무것도 지우지 않음). 커뮤니티 dataset 을 먼저 선회전해 지운 자료의 공유 대기 사본이 다음 계정으로 가지 않게 한다.
  static Future<Map<String, Object?>> wipeReportData(
    String reason, {
    String? thenOwner,
  }) async {
    _refuseDuringBackgroundWork('신고 내역을 지울');
    // 백업·복원과 같은 파일 배타 구간: 막 시작한 작업은 끝날 때까지 기다리고, 그동안 새 동기화·화면은 [db] 에서 기다린다
    // (지우는 도중이나 지운 뒤에 옛 작업이 신고를 다시 쓰지 않게 — Codex 검수 P1).
    return _withFileExclusive(() => _wipeReportDataLocked(reason, thenOwner));
  }

  static Future<Map<String, Object?>> _wipeReportDataLocked(
    String reason,
    String? thenOwner,
  ) async {
    await _rotateCommunityDataset(reason);
    final d = await db;
    final cleared = <String>[];
    await d.transaction((txn) async {
      final virtualTables = [
        for (final r in await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE 'CREATE VIRTUAL TABLE%'",
        ))
          r['name'] as String,
      ];
      final tables = [
        for (final r in await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        ))
          r['name'] as String,
      ];
      for (final name in tables) {
        if (name == 'geocode_cache' ||
            name == 'android_metadata' ||
            name == 'sync_meta') {
          continue;
        }
        // 가상 표(FTS)의 보조 표는 가상 표를 비우면 함께 비워진다 — 직접 건드리지 않는다
        if (virtualTables.any((v) => name != v && name.startsWith('${v}_'))) {
          continue;
        }
        await txn.delete(name);
        cleared.add(name);
      }
      await txn.delete(
        'sync_meta',
        where: 'key != ?',
        whereArgs: ['watchlist'],
      );
      if (thenOwner != null && thenOwner.isNotEmpty) {
        await txn.insert('sync_meta', {
          'key': kakaoMemberMetaKey,
          'value': thenOwner,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    _invalidateProjectRowsCache();
    return {'cleared': cleared, 'kept': legacyKept};
  }

  /// 이전 버전 DB 를 비울 때 옮기는 코드 없이 남기는 자료: 감시목록(sync_meta 의 watchlist 값)과 지오코딩 캐시(구조가 같을 때만).
  /// 서버 LEGACY_KEEP_TABLES 의 감시목록·지오코딩 캐시와 같다(관리자·API 키는 서버 전용).
  static const legacyKept = ['watchlist', 'geocode_cache'];

  /// 이전 버전 DB(저장된 버전 1 이상, [dbVersion] 미만)면 **파일을 바꾸지 않고 그 자리에서** 한 쓰기 트랜잭션(`BEGIN IMMEDIATE`)으로:
  /// 버전 재확인 → 남길 자료(감시목록 `sync_meta['watchlist']`, 열 구성이 같은 지오코딩 캐시) 읽기 → 별도 읽기 연결의
  /// 일관된 사본 `<db>.legacy_v<옛 버전>.<epoch ms>.bak`([copyDatabaseConsistent], WAL 에만 있던 쓰기 포함, 구형 Android 가능) + 무결성 검사 → [beforeReset](기본: 커뮤니티 dataset 선회전,
  /// 실패하면 아무것도 바꾸지 않음) → 표·보기 전부 DROP → 지금 스키마 CREATE → 남길 자료·`sync_meta[legacy_reset]` 기록 → 버전 → COMMIT.
  /// 반환: {from_version, backup, kept, dropped, at} (이전 버전 DB 가 아니거나 다른 연결이 먼저 끝냈으면 null).
  /// 열린 DB 의 WAL 삭제·파일 이름 교체는 SQLite 가 손상 경로로 꼽으므로 하지 않는다(Sol 재검증 3). 트랜잭션 동안 다른 연결의 쓰기는 잠김 오류로 실패한다.
  /// 서버 database.reset_legacy_database 와 같은 규칙(잠금 안 재확인·한 트랜잭션).
  @visibleForTesting
  static Future<Map<String, Object?>?> resetLegacyDatabase(
    String path, {
    Future<void> Function()? beforeReset,
  }) async {
    if (!File(path).existsSync()) return null;
    final db = await openDatabase(path, singleInstance: false);
    try {
      final first = await db.getVersion();
      if (first < 1 || first >= dbVersion) return null;
      await db.rawQuery('PRAGMA busy_timeout=30000');
      Map<String, Object?>? info;
      await db.transaction((txn) async {
        final version =
            Sqflite.firstIntValue(await txn.rawQuery('PRAGMA user_version')) ??
            0;
        if (version < 1 || version >= dbVersion) return; // 다른 연결이 먼저 끝냈다
        final oldTables = [
          for (final r in await txn.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
          ))
            r['name'] as String,
        ];
        Object? watchlist;
        if (oldTables.contains('sync_meta')) {
          final rows = await txn.rawQuery(
            "SELECT value FROM sync_meta WHERE key = 'watchlist' AND value IS NOT NULL",
          );
          if (rows.isNotEmpty) watchlist = rows.first['value'];
        }
        var geoInfo = const <Map<String, Object?>>[];
        var geoRows = const <Map<String, Object?>>[];
        if (oldTables.contains('geocode_cache')) {
          geoInfo = await txn.rawQuery('PRAGMA table_info("geocode_cache")');
          geoRows = await txn.query('geocode_cache');
        }

        final backup =
            '$path.legacy_v$version.${DateTime.now().millisecondsSinceEpoch}.bak';
        await _backupChecked(path, backup);
        await (beforeReset ?? () => _rotateCommunityDataset('legacy_reset'))();

        for (final r in await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='view'",
        )) {
          await txn.execute('DROP VIEW "${r['name']}"');
        }
        // 가상 표(FTS 등)를 먼저 지운다 — 그 보조 표를 함께 지우므로 나머지는 IF EXISTS(Sol 재검증 5).
        final virtualTables = [
          for (final r in await txn.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE 'CREATE VIRTUAL TABLE%'",
          ))
            r['name'] as String,
        ];
        for (final name in virtualTables) {
          await txn.execute('DROP TABLE "$name"');
        }
        for (final name in oldTables) {
          await txn.execute('DROP TABLE IF EXISTS "$name"');
        }
        await _createSchema(txn);
        final kept = <String>[];
        if (watchlist != null) {
          await txn.insert('sync_meta', {
            'key': 'watchlist',
            'value': watchlist,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          kept.add('watchlist');
        }
        if (geoInfo.isNotEmpty &&
            _columnSignature(geoInfo) ==
                _columnSignature(
                  await txn.rawQuery('PRAGMA table_info("geocode_cache")'),
                )) {
          final batch = txn.batch();
          for (final row in geoRows) {
            batch.insert('geocode_cache', row);
          }
          await batch.commit(noResult: true);
          kept.add('geocode_cache');
        }
        final result = <String, Object?>{
          'from_version': version,
          'backup': backup,
          'kept': kept,
          'dropped': oldTables,
          'at': DateTime.now().toIso8601String(),
        };
        await txn.insert('sync_meta', {
          'key': legacyResetMetaKey,
          'value': jsonEncode(result),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.execute('PRAGMA user_version = $dbVersion');
        info = result;
      });
      return info;
    } finally {
      await db.close();
    }
  }

  /// 별도 연결로 일관된 사본([copyDatabaseConsistent])을 만든다. 실패하면 사본을 지우고 예외(개인 DB 무변경).
  static Future<void> _backupChecked(String path, String target) =>
      copyDatabaseConsistent(path, target);

  /// [sourcePath] 의 일관된 사본을 [target] 에 만든다 — `VACUUM INTO` 를 쓰지 않는다: 그 명령은 SQLite 3.27 부터라
  /// Android 7~10(API 24~29, 기본 SQLite 3.9~3.22)에서 실패한다(Sol 재검증 4). 대신 새 파일에 원본을 ATTACH 하고
  /// 한 읽기 트랜잭션(DEFERRED — 원본에는 읽기 잠금만)에서 원본 스키마(`sqlite_master.sql`)를 그대로 다시 만들고 표마다 `INSERT … SELECT *`,
  /// `sqlite_sequence`·`user_version` 도 옮긴다. 같은 트랜잭션이라 표 사이에도 같은 시점이고 WAL 에만 있던 쓰기도 들어간다.
  /// 끝나면 표별 행 수 비교와 `integrity_check`. 어긋나면 사본을 지우고 예외. 초기화 크롤링 사전 백업도 쓴다.
  static Future<void> copyDatabaseConsistent(
    String sourcePath,
    String target,
  ) async {
    Future<void> removeTarget() async {
      for (final f in [
        target,
        '$target-wal',
        '$target-shm',
        '$target-journal',
      ]) {
        final file = File(f);
        if (file.existsSync()) await file.delete();
      }
    }

    await removeTarget();
    final copy = await openDatabase(target, singleInstance: false);
    var ok = false;
    try {
      await copy.execute('ATTACH DATABASE ? AS src', [sourcePath]);
      try {
        await copy.execute('BEGIN');
        try {
          final objects = await copy.rawQuery(
            "SELECT type, name, sql FROM src.sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid",
          );
          bool isVirtual(Map<String, Object?> o) => RegExp(
            r'^\s*CREATE\s+VIRTUAL\s+TABLE',
            caseSensitive: false,
          ).hasMatch(o['sql'] as String);
          Future<bool> existsInCopy(String name) async => (await copy.rawQuery(
            'SELECT 1 FROM main.sqlite_master WHERE name = ?',
            [name],
          )).isNotEmpty;
          final tableObjects = objects
              .where((o) => o['type'] == 'table')
              .toList();
          // 가상 표(FTS 등)를 먼저 만든다 — 그 보조(shadow) 표가 함께 생기므로 아래에서 다시 만들지 않는다(Sol 재검증 5).
          for (final o in tableObjects.where(isVirtual)) {
            await copy.execute(o['sql'] as String);
          }
          final copied = <String>[];
          for (final o in tableObjects.where((o) => !isVirtual(o))) {
            final name = o['name'] as String;
            if (await existsInCopy(name)) {
              await copy.execute(
                'DELETE FROM main."$name"',
              ); // 가상 표가 만든 보조 표: 원본 행으로 바꾼다
            } else {
              await copy.execute(o['sql'] as String);
            }
            copied.add(name);
          }
          // 가상 표 자체에는 넣지 않는다 — 내용은 방금 옮길 보조 표에 있다.
          for (final t in copied) {
            await copy.execute('INSERT INTO main."$t" SELECT * FROM src."$t"');
          }
          final hasSequence = (await copy.rawQuery(
            "SELECT 1 FROM src.sqlite_master WHERE name = 'sqlite_sequence'",
          )).isNotEmpty;
          if (hasSequence) {
            await copy.execute('DELETE FROM main.sqlite_sequence');
            await copy.execute(
              'INSERT INTO main.sqlite_sequence SELECT * FROM src.sqlite_sequence',
            );
          }
          // 인덱스 → 보기 → 트리거(보기에 다는 INSTEAD OF 트리거는 보기가 있어야 한다, Sol 재검증 5). 데이터를 다 넣은 뒤라 트리거가 복사 중에 발동하지 않는다.
          for (final type in const ['index', 'view', 'trigger']) {
            for (final o in objects.where((o) => o['type'] == type)) {
              if (await existsInCopy(o['name'] as String)) {
                continue; // 가상 표가 이미 만든 것
              }
              await copy.execute(o['sql'] as String);
            }
          }
          final tables = copied;
          final version =
              Sqflite.firstIntValue(
                await copy.rawQuery('PRAGMA src.user_version'),
              ) ??
              0;
          await copy.execute('PRAGMA main.user_version = $version');
          for (final t in tables) {
            final a = Sqflite.firstIntValue(
              await copy.rawQuery('SELECT count(*) FROM src."$t"'),
            );
            final b = Sqflite.firstIntValue(
              await copy.rawQuery('SELECT count(*) FROM main."$t"'),
            );
            if (a != b) {
              throw LegacyDatabaseException('DB 사본의 $t 행 수가 다릅니다($a → $b).');
            }
          }
          for (final table in copied) {
            final columns = await copy.rawQuery(
              'PRAGMA src.table_info("$table")',
            );
            final expressions = <String>[];
            for (final column in columns) {
              final name = (column['name'] as String).replaceAll('"', '""');
              expressions.add('"$name"');
              expressions.add('typeof("$name")');
            }
            final fields = expressions.join(',');
            for (final direction in ['src', 'main']) {
              final other = direction == 'src' ? 'main' : 'src';
              final differences = await copy.rawQuery(
                'SELECT $fields,COUNT(*) FROM $direction."$table" GROUP BY $fields EXCEPT SELECT $fields,COUNT(*) FROM $other."$table" GROUP BY $fields LIMIT 1',
              );
              if (differences.isNotEmpty) {
                throw LegacyDatabaseException('DB 사본의 $table 값 또는 타입이 다릅니다.');
              }
            }
          }
          await copy.execute('COMMIT');
        } catch (_) {
          try {
            await copy.execute('ROLLBACK');
          } catch (_) {}
          rethrow;
        }
      } finally {
        await copy.execute('DETACH DATABASE src');
      }
      final result = (await copy.rawQuery(
        'PRAGMA integrity_check',
      )).first.values.first.toString();
      if (result != 'ok') {
        throw LegacyDatabaseException('DB 사본 무결성 검사 실패: $result');
      }
      ok = true;
    } finally {
      await copy.close();
      if (!ok) {
        try {
          await removeTarget();
        } catch (_) {}
      }
    }
  }

  /// 열 구성 비교용(PRAGMA table_info): 이름·타입·NOT NULL·기본값·기본키.
  static String _columnSignature(List<Map<String, Object?>> rows) => [
    for (final r in rows)
      '${r['name']}|${(r['type'] ?? '').toString().toUpperCase()}|${r['notnull']}|${r['dflt_value']}|${r['pk']}',
  ].join(',');

  /// 초기화 크롤링 판정용: (개인 DB 신고 수, 이전 DB 를 비운 기록). 열지 못하면 신고 수 null(새 설치로 보지 않음).
  /// DB 를 여는 김에 이전 버전 DB 비우기가 먼저 일어난다.
  static Future<({int? reports, Map<String, Object?>? legacyReset})>
  personalDbFacts() async {
    try {
      final d = await db;
      final count =
          Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM reports'),
          ) ??
          0;
      final meta = await d.query(
        'sync_meta',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [legacyResetMetaKey],
        limit: 1,
      );
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

  static const _pendingPhotoWhere =
      "(category = 'parking' OR COALESCE(entry_value, '') LIKE '%불법주정차신고%') AND 사진_촬영수 IS NULL AND COALESCE(첨부사진, '') LIKE 'http%' AND COALESCE(신고일, '') >= ?";

  static Future<int> pendingPhotoCount({String? cutoff}) async =>
      Sqflite.firstIntValue(
        await (await db).rawQuery(
          'SELECT COUNT(*) FROM reports WHERE $_pendingPhotoWhere',
          [cutoff ?? attachmentCutoff(DateTime.now())],
        ),
      )!;

  /// 같은 날짜 조건/내림차순을 사용하며 백그라운드 작업은 ID keyset으로
  /// 128건씩 읽는다. 한 번의 동기화 종료 재시도는 기존 30건 제한을 유지한다.
  static Future<List<({String id, String photos, String reportNumber})>>
  pendingPhotoRows({int? limit, String? beforeId, String? cutoff}) async {
    final d = await db;
    final rows = await PerformanceTrace.sql(
      'maintenance.photo_page',
      () => d.rawQuery(
        'SELECT ID,첨부사진,신고번호 FROM reports WHERE $_pendingPhotoWhere '
        '${beforeId == null ? '' : 'AND ID<?'} ORDER BY ID DESC ${limit == null ? '' : 'LIMIT ?'}',
        [cutoff ?? attachmentCutoff(DateTime.now()), ?beforeId, ?limit],
      ),
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
    // 사용자 수정 주소는 표시용이다. 좌표는 공식 신고 원본에서 읽은 값을 유지한다.
    final select = columns
        .map((c) {
          if (editable.contains(c)) {
            return 'COALESCE((SELECT o.value FROM report_override o WHERE o.ID = r.ID AND o.column_name = \'$c\'), r."$c") AS "$c"';
          }
          return 'r."$c" AS "$c"';
        })
        .join(', ');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sr_report_category_number ON reports(category, 신고번호 DESC, ID DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sr_report_answer ON reports(답변일)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sr_duplicate_report ON duplicate_member(report_id, group_id, is_representative)',
    );
    final indexTimer = Stopwatch()..start();
    final summaryIndex = await db.rawQuery(
      'PRAGMA index_info(sr_summary_cover)',
    );
    if (summaryIndex.isNotEmpty &&
        !summaryIndex.any((r) => r['name'] == '신고번호')) {
      await db.execute('DROP INDEX sr_summary_cover');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sr_summary_cover ON reports(ID,category,처리상태,범칙금_과태료,감시목록,신고번호)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sr_report_watch ON reports(감시목록,ID)',
    );
    PerformanceTrace.record('db.read_index_prepare', indexTimer);
    await db.execute(
      'CREATE TEMP TABLE IF NOT EXISTS sr_read_revision(value INTEGER NOT NULL)',
    );
    await db.execute(
      'INSERT INTO temp.sr_read_revision SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM temp.sr_read_revision)',
    );
    for (final table in [
      'reports',
      'report_override',
      'duplicate_group',
      'duplicate_member',
      'sync_meta',
    ]) {
      for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
        await db.execute(
          'CREATE TEMP TRIGGER IF NOT EXISTS sr_revision_${table}_$operation AFTER $operation ON main.$table BEGIN UPDATE sr_read_revision SET value = value + 1; END',
        );
      }
    }
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

  static Future<void> _create(Database db, int version) => _createSchema(db);

  /// 지금 스키마의 표 전부(새 DB·이전 버전 DB 비우기가 같이 쓴다).
  static Future<void> _createSchema(DatabaseExecutor db) async {
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
        처리기관코드        TEXT,
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

  static void _invalidateProjectRowsCache() {
    _statsCache.clear();
    _summaryCache.clear();
    _mapCache.clear();
    _mapMetaCache.clear();
  }

  // Legacy export/detail callers still project originals. Retaining copies of
  // their full rows in a cache duplicated memory and missed status-only changes.
  static Future<List<Map<String, dynamic>>> _projectRows(
    DatabaseExecutor db,
    List<Map<String, dynamic>> rows, {
    required bool useRepresentativeRecords,
  }) => DuplicateProjectionService.projectReportRows(
    db,
    rows,
    useRepresentativeRecords: useRepresentativeRecords,
  );

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
    '처리기관코드',
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
      final geoPayload = officialGeoPayload(
        r.location,
        r.latitude,
        r.longitude,
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
        '처리기관코드': r.agencyCode,
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

  static String? _agencyLookupKey;
  static Future<void> _ensureAgencyLookup(
    Database connection, {
    DatabaseExecutor? executor,
  }) async {
    Future<void> prepare(DatabaseExecutor d) async {
      final key =
          '${identityHashCode(connection)}:${await _readRevision(d)}:${identityHashCode(AgencyRegistry.cacheVersion)}';
      if (_agencyLookupKey == key) return;
      await d.execute(
        'CREATE TEMP TABLE IF NOT EXISTS sr_agencies(code TEXT, raw TEXT, display TEXT, PRIMARY KEY(code,raw))',
      );
      await d.delete('sr_agencies');
      final rows = await d.rawQuery(
        "SELECT DISTINCT IFNULL(처리기관코드,'') AS code, IFNULL(처리기관,'') AS raw FROM $effectiveReportsView",
      );
      final batch = d.batch();
      for (final row in rows) {
        batch.insert('sr_agencies', {
          'code': row['code'],
          'raw': row['raw'],
          'display': registryDisplayAgency(row['code'], row['raw'] as String),
        });
      }
      await batch.commit(noResult: true);
      _agencyLookupKey = key;
    }

    try {
      if (executor != null) {
        await prepare(executor);
      } else {
        await connection.transaction(prepare);
      }
    } catch (_) {
      _agencyLookupKey = null;
      rethrow;
    }
  }

  /// Only distinct short metadata; raw_content and report bodies are not read.
  static Future<({List<String> statuses, List<String> laws})>
  getFilterOptions() => runBackgroundWork(() async {
    final d = await db;
    final statuses = await d.rawQuery(
      "SELECT DISTINCT trim(IFNULL(처리상태,'')) AS value FROM $effectiveReportsView",
    );
    final laws = await d.rawQuery(
      "SELECT DISTINCT trim(IFNULL(위반법규,'')) AS value FROM $effectiveReportsView",
    );
    return (
      statuses: statuses.map((r) => r['value'] as String).toList(),
      laws: laws.map((r) => r['value'] as String).toList(),
    );
  });

  static Future<({List<Report> reports, int total})> getReportPage({
    String category = 'all',
    String scope = '',
    String? metric,
    String? missingAddress,
    String? answerYear,
    ReportFilter filter = const ReportFilter(),
    int page = 0,
    int pageSize = 200,
    bool Function()? isCancelled,
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
    bool compact = false,
  }) => runBackgroundWork(() async {
    if (page < 0 || pageSize < 1 || pageSize > 200) {
      throw ArgumentError('잘못된 페이지');
    }
    if (isCancelled?.call() == true) throw const QueryCancelled();
    final connection = await db;
    return connection.transaction((d) async {
      if (isCancelled?.call() == true) throw const QueryCancelled();
      var agencyExpression = "trim(IFNULL(처리기관,''))";
      if (filter.agency.isNotEmpty ||
          filter.onlyPolice ||
          filter.excludePolice) {
        await _ensureAgencyLookup(connection, executor: d);
        agencyExpression =
            "(SELECT display FROM temp.sr_agencies a WHERE a.code = IFNULL(r.처리기관코드,'') AND a.raw = IFNULL(r.처리기관,''))";
      }
      final q = ReportQuery(filter, agencyExpression: agencyExpression);
      if (answerYear != null && answerYear != 'all') {
        q.clauses.add('r.답변일 LIKE ?');
        q.args.add('$answerYear%');
      }
      if (scope == 'duplicates') {
        return _getDuplicatePage(
          d,
          page,
          pageSize,
          excludeWithdraw,
          q,
          compact: compact,
        );
      }
      if (metric != null) {
        final condition = switch (metric) {
          '전체' => '1=1',
          // 대시보드 막대·타일과 같은 규칙(ReportPolicy, 서버 대시보드와 같음)
          '보완 요청' => ReportPolicy.sqlStatusIs(
            '처리상태',
            ReportPolicy.supplementStatus,
          ),
          '처리 중' => ReportPolicy.sqlListStatusFilter(
            '처리상태',
            ReportPolicy.processingLabel,
          ),
          '수용' => ReportPolicy.sqlStatusIs('처리상태', '수용'),
          '일부수용' => ReportPolicy.sqlStatusIs('처리상태', '일부수용'),
          '불수용/기타' => ReportPolicy.sqlListStatusFilter('처리상태', '불수용'),
          '취하' => ReportPolicy.sqlStatusIs(
            '처리상태',
            ReportPolicy.withdrawnStatus,
          ),
          'traffic:과태료' => ReportPolicy.sqlHasFine('범칙금_과태료'),
          'traffic:경고/범칙금' => ReportPolicy.sqlHasWarning('범칙금_과태료'),
          'traffic:불수용' => ReportPolicy.sqlListStatusFilter('처리상태', '불수용'),
          'traffic:과태료 미확인' => ReportPolicy.sqlFineUnknown('범칙금_과태료', '처리상태'),
          _ => throw ArgumentError('알 수 없는 요약 항목'),
        };
        q.clauses.add(condition);
      }
      q.clauses.add(_representativeWhere(useRepresentativeRecords));
      if (scope == 'watchlist') {
        q.clauses.add(_watchWhere(useRepresentativeRecords));
      }
      if (scope == 'missing') {
        await _ensureMissingLookup(connection, executor: d);
        q.clauses.add(
          'EXISTS (SELECT 1 FROM temp.sr_missing_addresses m WHERE m.ID=r.ID${missingAddress == null ? "" : " AND m.address_key = ?"})',
        );
        if (missingAddress != null) q.args.add(missingAddress);
      }
      if (scope == 'recent') {
        final today = DateTime.now();
        String date(DateTime t) =>
            '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
        q.clauses.add(
          "${ReportPolicy.sqlListStatusFilter('처리상태', '완료')} AND 답변일>=? AND 답변일<=?",
        );
        q.args.addAll([
          date(today.subtract(const Duration(days: 3))),
          '${date(today)} 99',
        ]);
      }
      if (scope == 'rating') {
        q.clauses.add("trim(IFNULL(만족도조사여부,'')) NOT IN ('참여 완료','참여 불가')");
        q.clauses.add(
          ReportPolicy.sqlNotIn(ReportPolicy.sqlNorm('처리상태'), const [
            '취하',
            '답변 대기',
            ...ReportPolicy.processingOrder,
          ]),
        );
      }
      if (category != 'all') {
        q.clauses.add('category = ?');
        q.args.add(category);
      }
      if (excludeWithdraw) q.clauses.add(ReportPolicy.sqlNotWithdrawn('처리상태'));
      final count = await PerformanceTrace.sql(
        'list.sql_count',
        () => d.rawQuery(
          'SELECT COUNT(*) AS n FROM $effectiveReportsView r WHERE ${q.where}',
          q.args,
        ),
      );
      final rows = await PerformanceTrace.sql(
        'list.sql_page',
        () => d.rawQuery(
          'SELECT ${compact ? _listCardSelect : 'r.*'} FROM $effectiveReportsView r WHERE ${q.where} ORDER BY ${scope == 'recent' ? 'CAST(synced_at AS INTEGER) DESC, 답변일 DESC, 신고번호 DESC, ID DESC' : '신고번호 DESC, ID DESC'} LIMIT ? OFFSET ?',
          [...q.args, pageSize, page * pageSize],
        ),
      );
      return (
        reports: PerformanceTrace.sync(
          'list.report_objects',
          () =>
              rows.map((r) => _rowToReport(r, detailLoaded: !compact)).toList(),
        ),
        total: count.first['n'] as int,
      );
    }, exclusive: false);
  });

  /// 목록 카드·선택 동작·별점 판정이 쓰는 열(SQ-P06). 긴 본문(신고내용·처리내용·보완 내용)과
  /// 첨부·지도 URL, 매핑하지 않는 원문 열은 읽지 않는다. 상세 시트는 열 때 한 건을 다시 읽는다
  /// ([Report.detailLoaded] false → `showReportDetailSheet` 가 [getReport] 로 채운다).
  static const listCardColumns = <String>[
    'ID',
    '신고번호',
    '신고명',
    '신고일',
    '답변일',
    '처리기관',
    '처리기관코드',
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
    '만족도조사여부',
    '종결여부',
    '별점',
    '별점사유',
    'category',
    'synced_at',
    '보완횟수',
    '보완_미응답',
    '보완_요청자',
    '보완_요청일시',
    '보완_완료일시',
  ];
  static final String _listCardSelect = listCardColumns
      .map((c) => 'r."$c"')
      .join(', ');

  static Future<({List<Report> reports, int total})> _getDuplicatePage(
    DatabaseExecutor d,
    int page,
    int pageSize,
    bool excludeWithdraw,
    ReportQuery q, {
    bool compact = false,
  }) async {
    final withdraw = excludeWithdraw
        ? "AND ${ReportPolicy.sqlNotWithdrawn('처리상태')}"
        : '';
    final cte =
        """
      WITH dv AS (SELECT 차량번호, COUNT(*) AS total_count,
        SUM(CASE WHEN ${ReportPolicy.sqlNotWithdrawn('처리상태')} THEN 1 ELSE 0 END) AS valid_count,
        MAX(신고번호) AS max_report_no FROM $effectiveReportsView
        WHERE 차량번호 != '' $withdraw GROUP BY 차량번호 HAVING COUNT(*) >= 2)
    """;
    final count = await d.rawQuery(
      '$cte SELECT COUNT(*) AS n FROM $effectiveReportsView r JOIN dv ON r.차량번호=dv.차량번호 WHERE ${q.where} $withdraw',
      q.args,
    );
    final rows = await d.rawQuery(
      '$cte SELECT ${compact ? _listCardSelect : 'r.*'}, dv.total_count, dv.valid_count FROM $effectiveReportsView r '
      'JOIN dv ON r.차량번호 = dv.차량번호 WHERE ${q.where} $withdraw '
      'ORDER BY dv.max_report_no DESC, r.차량번호 ASC, r.신고번호 DESC, r.ID DESC LIMIT ? OFFSET ?',
      [...q.args, pageSize, page * pageSize],
    );
    return (
      reports: rows
          .map((r) => _rowToReportWithCounts(r, detailLoaded: !compact))
          .toList(),
      total: (count.first['n'] as int?) ?? 0,
    );
  }

  static Future<List<Report>> getReportsByCategory(
    String category, {
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    var where = 'category = ?';
    final args = <dynamic>[category];
    if (excludeWithdraw) {
      where += ' AND ${ReportPolicy.sqlNotWithdrawn('처리상태')}';
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
    return projected.map((r) => _rowToReport(r)).toList();
  }

  static Future<List<Report>> getAllReports({
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    final rows = await _queryReportsChunked(
      d,
      where: excludeWithdraw ? ReportPolicy.sqlNotWithdrawn('처리상태') : null,
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
    return projected.map((r) => _rowToReport(r)).toList();
  }

  /// 엑셀 내보내기가 시트에 쓰는 값을 만드는 데 필요한 열(SQ-P03). 처리기관코드는 기관 표시명 해석에 쓴다.
  @visibleForTesting
  static const exportReportColumns = <String>[
    'ID',
    '상태',
    '신고번호',
    '신고명',
    '신고일',
    '처리상태',
    '차량번호',
    '위반법규',
    '범칙금_과태료',
    '벌점',
    '처리기관',
    '처리기관코드',
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
    '만족도조사여부',
    '별점',
    '별점사유',
  ];

  static String _exportWhere(bool excludeWithdraw) => excludeWithdraw
      ? 'category = ? AND ${ReportPolicy.sqlNotWithdrawn('처리상태')}'
      : 'category = ?';

  /// 엑셀 내보내기 진행률의 분모. [readReportsForExport] 와 같은 조건이다.
  static Future<int> countReportsForExport(
    String category, {
    bool excludeWithdraw = false,
  }) => runBackgroundWork(() async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT COUNT(*) AS n FROM $effectiveReportsView WHERE ${_exportWhere(excludeWithdraw)}',
      [category],
    );
    return (rows.first['n'] as int?) ?? 0;
  });

  /// 엑셀 내보내기 전용 페이지 읽기(SQ-P03).
  ///
  /// [getReportsByCategory] 와 같은 조건·같은 순서(ID 오름차순 keyset, [_kListChunkSize] 행)로 읽되,
  /// [exportReportColumns] 만 읽고 페이지마다 같은 변환([_rowToReport])을 거친 [Report] 를 [onPage] 로 넘긴다.
  /// 전체 목록을 만들지 않는다. 신고번호 정렬은 호출자가 모든 페이지를 받은 뒤 같은 비교로 한다.
  /// 내보내기는 대표건 투영을 쓰지 않는다(useRepresentativeRecords=false 이면 [_projectRows] 는 행을 그대로 돌려준다).
  /// 페이지 경계에서 [isCancelled] 또는 연결 닫기 요청이면 [QueryCancelled] 로 멈춘다.
  static Future<void> readReportsForExport(
    String category, {
    bool excludeWithdraw = false,
    required FutureOr<void> Function(List<Report> page) onPage,
    bool Function()? isCancelled,
  }) => runBackgroundWork(() async {
    final d = await db;
    final available = (await d.rawQuery(
      'PRAGMA table_info("$effectiveReportsView")',
    )).map((r) => r['name'] as String).toSet();
    // 예전 DB 에 없는 열은 SELECT * 에서처럼 NULL(→ 같은 기본값)로 둔다.
    final columns = [
      for (final c in exportReportColumns)
        if (available.contains(c)) '"$c"',
    ].join(', ');
    String? lastId;
    while (true) {
      if (isCancelled?.call() == true || closeRequested) {
        throw const QueryCancelled();
      }
      final rows = await d.rawQuery(
        'SELECT $columns FROM $effectiveReportsView '
        'WHERE (${_exportWhere(excludeWithdraw)})${lastId == null ? '' : ' AND ID > ?'} '
        'ORDER BY ID LIMIT ?',
        [category, ?lastId, _kListChunkSize],
      );
      if (isCancelled?.call() == true || closeRequested) {
        throw const QueryCancelled();
      }
      await onPage(rows.map(_rowToReport).toList(growable: false));
      if (rows.length < _kListChunkSize) break;
      final next = rows.last['ID'];
      if (next is! String || next.isEmpty) break;
      lastId = next;
    }
  });

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

  static final _summaryCache = <String, DashboardStats>{};

  static Future<DashboardStats> computeSummary({
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
    bool Function()? isCancelled,
  }) => runBackgroundWork(() async {
    if (isCancelled?.call() == true) throw const QueryCancelled();
    final connection = await db;
    if (isCancelled?.call() == true) throw const QueryCancelled();
    final revision = await _readRevision(connection);
    final now = DateTime.now();
    final key =
        '${identityHashCode(connection)}:$revision:${identityHashCode(AgencyRegistry.cacheVersion)}:$excludeWithdraw:$useRepresentativeRecords:${now.year}-${now.month}-${now.day}';
    if (_summaryCache[key] != null) return _summaryCache[key]!;
    final result = await connection.transaction((d) async {
      if (isCancelled?.call() == true) throw const QueryCancelled();
      final representative = _representativeWhere(useRepresentativeRecords);
      final timer = Stopwatch()..start();
      // 하위 질의가 처리상태·범칙금_과태료·category 를 ReportPolicy.sqlNorm 으로 한 번 정규화한다
      // (서버 대시보드와 같은 규칙, contracts/report-policy-vectors.json).
      const traffic = "category = 'traffic'";
      final fields = <String, String>{
        'accept': "처리상태 = '수용'",
        'partial': "처리상태 = '일부수용'",
        'reject': ReportPolicy.sqlIn('처리상태', ReportPolicy.rejectOrder),
        'supplement': "처리상태 = '${ReportPolicy.supplementStatus}'",
        'processing': ReportPolicy.sqlIn('처리상태', ReportPolicy.processingOrder),
        'completed': ReportPolicy.sqlIn('처리상태', ReportPolicy.completedOrder),
        'withdraw': "처리상태 = '${ReportPolicy.withdrawnStatus}'",
        'fine': '$traffic AND ${ReportPolicy.sqlHasFine('범칙금_과태료')}',
        'penalty': '$traffic AND ${ReportPolicy.sqlHasWarning('범칙금_과태료')}',
        'traffic_reject':
            '$traffic AND ${ReportPolicy.sqlIn('처리상태', ReportPolicy.rejectOrder)}',
        'unconfirmed':
            "$traffic AND 범칙금_과태료 = '${ReportPolicy.fineUnknownText}' AND ${ReportPolicy.sqlNotIn('처리상태', ReportPolicy.rejectOrder)}",
      };
      final sums = fields.entries
          .map((e) => 'COUNT(CASE WHEN ${e.value} THEN 1 END) AS ${e.key}')
          .join(',');
      final counts = await PerformanceTrace.sql(
        'summary.sql_counts',
        () => d.rawQuery(
          'SELECT COUNT(*) AS total, $sums FROM ('
          'SELECT r.ID, ${ReportPolicy.sqlNorm('r.category')} AS category, '
          '${ReportPolicy.sqlNorm('COALESCE(s.value,r.처리상태)')} AS 처리상태, '
          '${ReportPolicy.sqlNorm('COALESCE(f.value,r.범칙금_과태료)')} AS 범칙금_과태료 FROM reports r '
          "LEFT JOIN report_override s ON s.ID=r.ID AND s.column_name='처리상태' "
          "LEFT JOIN report_override f ON f.ID=r.ID AND f.column_name='범칙금_과태료') r "
          'WHERE $representative',
        ),
      );
      int n(String field) => counts.first[field] as int;
      final today = DateTime.now();
      String date(DateTime t) =>
          '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      final lower = date(today.subtract(const Duration(days: 3))),
          upper = '${date(today)} 99';
      final recent = await PerformanceTrace.sql(
        'summary.sql_recent',
        () => d.rawQuery(
          "SELECT r.* FROM $effectiveReportsView r WHERE $representative AND "
          "r.ID IN (SELECT ID FROM reports WHERE 답변일 >= ? AND 답변일 <= ? UNION SELECT ID FROM report_override WHERE column_name='답변일' AND value >= ? AND value <= ?) AND "
          "${ReportPolicy.sqlListStatusFilter('처리상태', '완료')} AND 답변일 >= ? AND 답변일 <= ? "
          'ORDER BY CAST(synced_at AS INTEGER) DESC, 답변일 DESC, 신고번호 DESC LIMIT 200',
          [lower, upper, lower, upper, lower, upper],
        ),
      );
      // The watch flag of ANY confirmed member applies to its representative.
      final watch = _watchWhere(useRepresentativeRecords);
      final watchWhere =
          '$representative AND $watch${excludeWithdraw ? " AND ${ReportPolicy.sqlNotWithdrawn('COALESCE(s.value,r.처리상태)')}" : ''}';
      final watchCount = await PerformanceTrace.sql(
        'summary.sql_watch_count',
        () => d.rawQuery(
          'SELECT COUNT(*) AS n FROM reports r INDEXED BY sr_summary_cover '
          "LEFT JOIN report_override s ON s.ID=r.ID AND s.column_name='처리상태' "
          'WHERE $representative AND $watch'
          '${excludeWithdraw ? " AND ${ReportPolicy.sqlNotWithdrawn('COALESCE(s.value,r.처리상태)')}" : ""}',
        ),
      );
      final watched = await PerformanceTrace.sql(
        'summary.sql_watchlist',
        () => d.rawQuery(
          'SELECT r.* FROM $effectiveReportsView r WHERE r.ID IN '
          '(SELECT r.ID FROM reports r INDEXED BY sr_summary_cover '
          "LEFT JOIN report_override s ON s.ID=r.ID AND s.column_name='처리상태' "
          'WHERE $watchWhere ORDER BY 신고번호 DESC LIMIT 200) '
          'ORDER BY 신고번호 DESC',
        ),
      );
      final recentReports = PerformanceTrace.sync(
        'summary.report_objects',
        () => recent.map(_rowToReport).toList(),
      );
      final watchReports = PerformanceTrace.sync(
        'summary.watch_objects',
        () => watched.map(_rowToReport).toList(),
      );
      PerformanceTrace.record('summary.total', timer);
      return DashboardStats(
        lastCrawlTime:
            (await d.query(
                  'sync_meta',
                  columns: ['value'],
                  where: 'key=?',
                  whereArgs: ['last_sync'],
                )).firstOrNull?['value']
                as String? ??
            '',
        total: n('total'),
        acceptCount: n('accept'),
        partialCount: n('partial'),
        rejectCount: n('reject'),
        supplementCount: n('supplement'),
        processingCount: n('processing'),
        completedCount: n('completed'),
        withdrawCount: n('withdraw'),
        withdrawRawCount: n('withdraw'),
        withdrawGraphCount: excludeWithdraw ? 0 : n('withdraw'),
        tFineCount: n('fine'),
        tPenaltyCount: n('penalty'),
        tRejectCount: n('traffic_reject'),
        tUnconfirmedCount: n('unconfirmed'),
        recentAnswers: recentReports,
        watchlist: watchReports,
        watchlistTotal: watchCount.first['n'] as int,
        excludeWithdraw: excludeWithdraw,
      );
    }, exclusive: false);
    if (await _readRevision(connection) == revision) {
      if (_summaryCache.length >= 4) _summaryCache.clear();
      _summaryCache[key] = result;
    }
    return result;
  });

  // ── 통계 집계 ─────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> computeStats({
    String? year,
    String? law,
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
  }) async =>
      (await computeStatsBundle(
            year: year,
            law: law,
            excludeWithdraw: excludeWithdraw,
            useRepresentativeRecords: useRepresentativeRecords,
          ))['stats']
          as Map<String, dynamic>;

  static Future<Map<String, dynamic>> computeStatsOverview({
    String? year,
    String? law,
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
  }) async =>
      (await computeStatsBundle(
            year: year,
            law: law,
            excludeWithdraw: excludeWithdraw,
            useRepresentativeRecords: useRepresentativeRecords,
          ))['overview']
          as Map<String, dynamic>;

  // sqflite cannot interrupt a running CTAS. Serialize acquisition in Dart so
  // rapidly abandoned screens never enqueue another large native query each.
  static Future<void> _statsReadTail = Future<void>.value();

  static Future<T> _serializeStatsRead<T>(
    Future<T> Function() work,
    bool Function()? isCancelled,
  ) async {
    final predecessor = _statsReadTail;
    final released = Completer<void>();
    _statsReadTail = released.future;
    try {
      await predecessor;
      if (isCancelled?.call() == true || closeRequested) {
        throw const QueryCancelled();
      }
      return await work();
    } finally {
      released.complete();
    }
  }

  static int _statsQuerySerial = 0;
  static final _statsCache = <String, Map<String, dynamic>>{};

  /// Projection is evaluated in SQL, before grouping, with the same confirmed
  /// member selection as projectReportRows. No raw-content fingerprinting here.
  static String _representativeWhere(bool useRepresentativeRecords) =>
      !useRepresentativeRecords
      ? '1=1'
      : """
        r.ID NOT IN (
          SELECT m.report_id FROM duplicate_member m JOIN duplicate_group g USING (group_id)
          WHERE m.report_id IS NOT NULL AND g.status = 'confirmed_duplicate'
            AND IFNULL(m.is_representative, 0) != 1
        )
      """;

  static String _watchWhere(bool representative) => !representative
      ? "r.감시목록 = 'Y'"
      : """
    r.ID IN (
      SELECT ID FROM reports WHERE 감시목록 = 'Y'
      UNION
      SELECT me.report_id FROM duplicate_member me JOIN duplicate_group g USING(group_id)
      JOIN duplicate_member other USING(group_id) JOIN reports watched ON watched.ID = other.report_id
      WHERE g.status = 'confirmed_duplicate' AND watched.감시목록 = 'Y'
    )
  """;

  static const _statsColumns = [
    'category',
    '처리상태',
    '범칙금_과태료',
    '처리기관',
    '처리기관코드',
    '담당자',
    '별점',
    '신고일',
    '답변일',
    '신고명',
    '위반법규',
    'entry_value',
    '차량번호',
    '발생시각',
    '사진_첫촬영',
    '사진_끝촬영',
  ];

  /// 화면 "자료 변경" 판정용 쓰기 표시(SQ-P02): 연결 identity + TEMP 쓰기 revision + `PRAGMA data_version`.
  /// 읽기 캐시 키와 같은 재료다. 같으면 마지막으로 본 뒤 이 DB 에 쓰기가 없었다는 뜻이다.
  static Future<String> readDataStamp() async {
    final d = await db;
    return '${identityHashCode(d)}:${await _readRevision(d)}';
  }

  static Future<String> _readRevision(DatabaseExecutor d) async {
    final v = await d.rawQuery('PRAGMA data_version');
    final c = await d.rawQuery('SELECT value AS n FROM temp.sr_read_revision');
    return '${v.first.values.first}:${c.first['n']}';
  }

  /// One native GROUP BY, one bounded stream, one result for both statistics views.
  /// TEMP data never changes the exchange schema and is dropped even on cancel.
  static Future<Map<String, dynamic>> computeStatsBundle({
    String? year,
    String? law,
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
    bool Function()? isCancelled,
  }) => _serializeStatsRead(
    () => runBackgroundWork(() async {
      final d = await db;
      final revision = await _readRevision(d);
      final key =
          '${identityHashCode(d)}:$revision:${identityHashCode(AgencyRegistry.cacheVersion)}:$year:$law:$excludeWithdraw:$useRepresentativeRecords';
      if (isCancelled?.call() == true) throw const QueryCancelled();
      final cached = _statsCache[key];
      if (cached != null) return cached;
      void checkCancel() {
        if (isCancelled?.call() == true) throw const QueryCancelled();
      }

      checkCancel();
      final table = 'sr_stats_${++_statsQuerySerial}';
      final args = <Object?>[];
      final clauses = [_representativeWhere(useRepresentativeRecords)];
      if (year != null) {
        clauses.add('답변일 LIKE ?');
        args.add('$year%');
      }
      if (excludeWithdraw) clauses.add(ReportPolicy.sqlNotWithdrawn('처리상태'));
      final columns = _statsColumns.map((c) => '"$c"').join(',');
      final cats = {
        for (final c in ['traffic', 'parking', 'other'])
          c: _StatsCategoryAccumulator(),
      };
      final overview = {
        for (final c in ['all', 'traffic', 'parking', 'other'])
          c: _OverviewAccumulator(),
      };
      final timer = Stopwatch()..start();
      try {
        // CTAS captures a consistent snapshot on the native SQLite worker. CPU and
        // the full result remain outside the UI isolate; only <=1000 groups cross.
        await d.execute(
          'CREATE TEMP TABLE $table AS SELECT $columns, COUNT(*) AS _weight '
          'FROM $effectiveReportsView r WHERE ${clauses.join(' AND ')} GROUP BY $columns',
          args,
        );
        PerformanceTrace.record('stats.sql_group', timer);
        var last = 0;
        while (true) {
          checkCancel();
          final rows = await PerformanceTrace.sql(
            'stats.sql_page',
            () => d.rawQuery(
              'SELECT rowid AS _cursor, * FROM $table WHERE rowid > ? ORDER BY rowid LIMIT 1000',
              [last],
            ),
          );
          if (rows.isEmpty) break;
          PerformanceTrace.sync('stats.registry_and_tables', () {
            for (final row in rows) {
              final cat = cats[row['category']];
              if (cat == null) continue;
              cat.addLaw(row);
              final rowLaw = row['위반법규']?.toString() ?? '';
              if (law != null &&
                  (law == '__없음__' ? rowLaw.isNotEmpty : rowLaw != law)) {
                continue;
              }
              cat.add(row);
            }
          });
          PerformanceTrace.sync('stats.chart_data', () {
            final selected = rows
                .where((r) {
                  final value = r['위반법규']?.toString() ?? '';
                  return law == null ||
                      (law == '__없음__' ? value.isEmpty : value == law);
                })
                .toList(growable: false);
            overview['all']!.add(selected);
            for (final c in cats.keys) {
              overview[c]!.add(
                selected
                    .where((r) => r['category'] == c)
                    .toList(growable: false),
              );
            }
          });
          last = rows.last['_cursor'] as int;
          await Future<void>.delayed(Duration.zero);
        }
        checkCancel();
        final years = await d.rawQuery(
          'SELECT DISTINCT substr(답변일,1,4) AS y FROM $effectiveReportsView ORDER BY y DESC',
        );
        final result = <String, dynamic>{
          'stats': {
            for (final c in cats.keys) c: cats[c]!.toJson(),
            'available_years': years
                .map((r) => r['y'])
                .whereType<String>()
                .where((y) => RegExp(r'^\d{4}$').hasMatch(y))
                .toList(),
          },
          'overview': {
            for (final c in overview.keys) c: overview[c]!.toJson(),
            'year_basis': '답변일',
            'exclude_withdraw': excludeWithdraw,
          },
        };
        if (await _readRevision(d) == revision) {
          if (_statsCache.length >= 4) _statsCache.clear();
          _statsCache[key] = result;
        }
        return result;
      } finally {
        await d.execute('DROP TABLE IF EXISTS temp.$table');
        PerformanceTrace.record('stats.total', timer);
        // TEMP writes contribute to total_changes. Cache only a completed result
        // below, never a row list, and never while a dataset has changed.
      }
    }),
    isCancelled,
  );

  static const _overviewCompletedStatuses = ReportPolicy.completedStatuses;
  static const _overviewProcessingStatuses = ReportPolicy.processingStatuses;

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
    List<Map<String, dynamic>> rows, {
    bool includeInternal = false,
  }) {
    var completed = 0, accept = 0, partial = 0, reject = 0;
    var supplement = 0, processing = 0, withdraw = 0;
    var reversed = 0, undated = 0, daySum = 0, dayCount = 0;
    final reportedByMonth = <String, int>{};
    final answeredByMonth = <String, int>{};

    for (final r in rows) {
      final weight = (r['_weight'] as int?) ?? 1;
      final status = ReportPolicy.norm(r['처리상태']);
      if (_overviewCompletedStatuses.contains(status)) completed += weight;
      if (status == '수용') accept += weight;
      if (status == '일부수용') partial += weight;
      if (ReportPolicy.rejectStatuses.contains(status)) reject += weight;
      if (status == ReportPolicy.supplementStatus) supplement += weight;
      if (_overviewProcessingStatuses.contains(status)) processing += weight;
      if (status == ReportPolicy.withdrawnStatus) withdraw += weight;

      final reported = _parseOverviewDate(r['신고일']);
      final answered = _parseOverviewDate(r['답변일']);
      if (reported == null) {
        undated += weight;
      } else {
        final key = _monthKey(reported);
        reportedByMonth[key] = (reportedByMonth[key] ?? 0) + weight;
      }
      if (answered != null) {
        final key = _monthKey(answered);
        answeredByMonth[key] = (answeredByMonth[key] ?? 0) + weight;
      }
      // S-10: 평균 처리기간은 완료 신고만(기관표와 같은 기준).
      if (_overviewCompletedStatuses.contains(status) &&
          reported != null &&
          answered != null) {
        final days = answered.difference(reported).inDays;
        if (days < 0) {
          reversed += weight;
        } else {
          daySum += days * weight;
          dayCount += weight;
        }
      }
    }

    List<Map<String, dynamic>> series(Map<String, int> source) {
      final keys = source.keys.toList()..sort();
      return [
        for (final k in keys) {'month': k, 'count': source[k]},
      ];
    }

    // 2026-09-28 통계 개편 추가 필드(서버 `_summarize_overview_frame` 과 같은 정의 — contracts/stats-overview-vectors.json).
    // 답변월 기준 과태료 건수: 월별 처리 추이 보조 계열(같은 답변일 기준).
    final answeredFineByMonth = <String, int>{};
    for (final r in rows) {
      final weight = (r['_weight'] as int?) ?? 1;
      final answered = _parseOverviewDate(r['답변일']);
      final fine = r['범칙금_과태료']?.toString() ?? '';
      if (answered != null && fine.contains('과태료')) {
        final key = _monthKey(answered);
        answeredFineByMonth[key] = (answeredFineByMonth[key] ?? 0) + weight;
      }
    }

    return {
      'total': rows.fold<int>(
        0,
        (sum, r) => sum + ((r['_weight'] as int?) ?? 1),
      ),
      if (includeInternal) '_day_sum': daySum,
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
      'monthly_answered_fine': series(answeredFineByMonth),
      ..._overviewExtras(rows),
    };
  }

  /// 카테고리 전체(기관 유무와 무관) 처분 분류·확정/추정 과태료·위반 유형. 서버 `_overview_disposition`·
  /// `_overview_fine_amount`·`_overview_report_types` 와 같은 규칙. 처분·금액은 기관표 행([_AgencyAgg])과 같은 계산을 쓴다.
  static Map<String, dynamic> _overviewExtras(List<Map<String, dynamic>> rows) {
    final agg = _AgencyAgg('', '');
    var decided = 0;
    var confirmedCount = 0;
    final typeCounts = <String, int>{};
    final lawCounts = <String, int>{};
    var resultUnknown = 0;
    for (final r in rows) {
      final weight = (r['_weight'] as int?) ?? 1;
      agg.add(r);
      final fine = r['범칙금_과태료']?.toString() ?? '';
      final status = ReportPolicy.norm(r['처리상태']);
      final disposition = ReportPolicy.dashboardDisposition(r);
      if (!disposition['unconfirmed']!) decided += weight;
      if (fine.contains('과태료') && extractFineAmount(fine) > 0) {
        confirmedCount += weight;
      }
      final name = (r['신고명']?.toString() ?? '').trim();
      typeCounts[name] = (typeCounts[name] ?? 0) + weight;
      final law = (r['위반법규']?.toString() ?? '').trim();
      lawCounts[law] = (lawCounts[law] ?? 0) + weight;
      if (status == ReportPolicy.answeredUnknownStatus) resultUnknown += weight;
    }
    final types = typeCounts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return {
      'result_distribution': {
        'accept': rows
            .where((r) => ReportPolicy.norm(r['처리상태']) == '수용')
            .fold<int>(0, (n, r) => n + ((r['_weight'] as int?) ?? 1)),
        'partial': rows
            .where((r) => ReportPolicy.norm(r['처리상태']) == '일부수용')
            .fold<int>(0, (n, r) => n + ((r['_weight'] as int?) ?? 1)),
        'reject': rows
            .where((r) => ReportPolicy.isReject(r['처리상태']))
            .fold<int>(0, (n, r) => n + ((r['_weight'] as int?) ?? 1)),
        'unknown': resultUnknown,
      },
      'violation_laws': [
        for (final e
            in lawCounts.entries.toList()..sort((a, b) {
              final c = b.value.compareTo(a.value);
              return c != 0 ? c : a.key.compareTo(b.key);
            }))
          {
            'name': e.key,
            'filter': e.key.isEmpty ? '__없음__' : e.key,
            'count': e.value,
          },
      ],
      // overlap = 과태료+경고/범칙금+불수용 합 − 셋 중 하나 이상인 신고 수(한 신고에 겹친 수)
      'disposition': {
        'fines': agg.fines,
        'warnings': agg.warn,
        'rejects': agg.reject,
        'unconfirmed': agg.unconfirmed,
        'in_progress': agg.inProgress,
        'disposition_unknown': agg.dispositionUnknown,
        'no_penalty': agg.noPenalty,
        'unclassified': agg.unclassified,
        'overlap': agg.fines + agg.warn + agg.reject - decided,
      },
      // 확정·추정은 합치지 않는다(PROJECT_RULES §3-2)
      'fine_amount': {
        'confirmed_amount': agg.totalFine,
        'confirmed_count': confirmedCount,
        'unknown_count': agg.fineAmountUnknown,
        'estimated_amount': agg.estimatedFineAmount,
        'estimated_count': agg.estimatedFineCount,
      },
      'report_types': [
        for (final e in types) {'name': e.key, 'count': e.value},
      ],
    };
  }

  /// 신고 지도 핀 기준(2026-10-05, 서버 apply_pin_basis 와 같은 규칙).
  /// 'address' 외 모두 'coords' 로 정규화한다.
  static String normalizeMapPinBasis(String? value) =>
      value == 'address' ? 'address' : 'coords';

  /// 핀 기준 주소키 = trim(주소정규화), 비면 trim(위반장소).
  static String mapPinBasisKey(Object? normalized, Object? location) {
    final primary = (normalized?.toString() ?? '').trim();
    if (primary.isNotEmpty) return primary;
    return (location?.toString() ?? '').trim();
  }

  /// 지도 묶음 원(cluster) 이름(2026-10-05 후속 B, 벡터 description 이 정본).
  /// contracts/map-cluster-label-vectors.json 과 같은 규칙.
  /// rows: {'주소정규화','위반장소'} (값 null 허용).
  /// address_count = 비지 않은 주소키 종류 수.
  /// 대표 주소키 = 신고 수가 가장 많은 주소키(동률이면 문자열 비교로 작은 것).
  /// address = 대표 주소키 신고들의 비지 않은 trim(위반장소) 중 가장 작은 값,
  /// 없으면 대표 주소키, 주소키가 하나도 없으면 빈 문자열.
  /// region = 0곳 '주소 정보 없음' / 1곳 address / 2곳 이상 '{address} 외 {N-1}곳'.
  @visibleForTesting
  static ({String address, int addressCount, String region})
  resolveMapClusterLabel(List<Map<String, Object?>> rows) {
    final counts = <String, int>{};
    final minDisplay = <String, String>{};
    for (final row in rows) {
      final key = mapPinBasisKey(row['주소정규화'], row['위반장소']);
      if (key.isEmpty) continue;
      counts[key] = (counts[key] ?? 0) + 1;
      final display = (row['위반장소']?.toString() ?? '').trim();
      if (display.isEmpty) continue;
      final prev = minDisplay[key];
      if (prev == null || display.compareTo(prev) < 0) {
        minDisplay[key] = display;
      }
    }
    return clusterLabelFromKeyStats(counts, minDisplay);
  }

  /// 칸 집계(SQL 그룹 행)에서 모은 주소키별 건수·최소 표시문구로 같은 라벨을 낸다.
  /// counts: 비지 않은 주소키 → 그 키 신고 수. minDisplay: 키 → 그 키 신고들의
  /// 비지 않은 trim(위반장소) 중 가장 작은 값(없으면 항목 없음).
  @visibleForTesting
  static ({String address, int addressCount, String region})
  clusterLabelFromKeyStats(
    Map<String, int> counts,
    Map<String, String> minDisplay,
  ) {
    final nonEmpty = Map<String, int>.from(counts)
      ..removeWhere((key, _) => key.isEmpty);
    final addressCount = nonEmpty.length;
    if (addressCount == 0) {
      return (address: '', addressCount: 0, region: '주소 정보 없음');
    }
    var topKey = nonEmpty.entries.first.key;
    var topCount = nonEmpty.entries.first.value;
    for (final entry in nonEmpty.entries.skip(1)) {
      if (entry.value > topCount ||
          (entry.value == topCount && entry.key.compareTo(topKey) < 0)) {
        topKey = entry.key;
        topCount = entry.value;
      }
    }
    final display = minDisplay[topKey];
    final address = (display != null && display.isNotEmpty)
        ? display
        : topKey;
    final region = addressCount == 1
        ? address
        : '$address 외 ${addressCount - 1}곳';
    return (address: address, addressCount: addressCount, region: region);
  }

  /// 핀 기준 SQL 조각(address 모드 effective 좌표). FROM 에
  /// `$effectiveReportsView r` 과 `temp.<rep> rep` 조인이 있어야 한다.
  static const _pinKeyExpr =
      "COALESCE(NULLIF(trim(r.주소정규화),''),trim(r.위반장소))";
  static const _pinKeyEmpty = "(IFNULL(($_pinKeyExpr),'') = '')";
  static const _pinOwnValid =
      "typeof(r.위도) IN ('integer','real') AND typeof(r.경도) IN ('integer','real') AND CAST(r.위도 AS REAL) BETWEEN -90 AND 90 AND CAST(r.경도 AS REAL) BETWEEN -180 AND 180";
  static const _pinEffValid =
      "(CASE WHEN $_pinKeyEmpty THEN ($_pinOwnValid) ELSE (rep.lat IS NOT NULL AND rep.lng IS NOT NULL) END)";
  static const _pinEffLat =
      "(CASE WHEN $_pinKeyEmpty THEN r.위도 ELSE rep.lat END)";
  static const _pinEffLng =
      "(CASE WHEN $_pinKeyEmpty THEN r.경도 ELSE rep.lng END)";

  /// 표시용 effective 좌표 계산. DB 의 위도·경도·지오코딩상태는 바꾸지 않는다.
  /// rows: {'ID','주소정규화','위반장소','위도','경도'}.
  /// effective: ID → [위도, 경도] (없으면 null).
  /// representatives: 주소키 → 그 주소 신고들의 유효 공식 좌표 중 가장 많이 나온
  /// 쌍(동률이면 위도 작은 것→경도 작은 것). 유효 좌표 판정은 기존 지도 것과 같다.
  @visibleForTesting
  static ({
    Map<String, List<double>?> effective,
    Map<String, List<double>> representatives,
  }) resolveMapPinBasis(List<Map<String, Object?>> rows, String pinBasis) {
    final basis = normalizeMapPinBasis(pinBasis);
    final keys = <String, String>{};
    final ownValid = <String, List<double>>{};
    final counts = <String, Map<(double, double), int>>{};
    for (final row in rows) {
      final id = row['ID']?.toString() ?? '';
      if (id.isEmpty) continue;
      final key = mapPinBasisKey(row['주소정규화'], row['위반장소']);
      keys[id] = key;
      final latRaw = row['위도'];
      final lngRaw = row['경도'];
      if (!_validMapCoordinate(latRaw, lngRaw)) continue;
      final lat = (latRaw as num).toDouble();
      final lng = (lngRaw as num).toDouble();
      ownValid[id] = [lat, lng];
      if (basis == 'address' && key.isNotEmpty) {
        final perKey = counts.putIfAbsent(key, () => {});
        final pair = (lat, lng);
        perKey[pair] = (perKey[pair] ?? 0) + 1;
      }
    }
    final representatives = <String, List<double>>{};
    if (basis == 'address') {
      for (final entry in counts.entries) {
        final ranked = entry.value.entries.toList()
          ..sort((a, b) {
            var c = b.value.compareTo(a.value);
            if (c != 0) return c;
            c = a.key.$1.compareTo(b.key.$1);
            if (c != 0) return c;
            return a.key.$2.compareTo(b.key.$2);
          });
        representatives[entry.key] = [
          ranked.first.key.$1,
          ranked.first.key.$2,
        ];
      }
    }
    final effective = <String, List<double>?>{};
    for (final id in keys.keys) {
      if (basis != 'address') {
        effective[id] = ownValid[id];
      } else {
        final key = keys[id]!;
        effective[id] = key.isEmpty ? ownValid[id] : representatives[key];
      }
    }
    return (effective: effective, representatives: representatives);
  }

  /// 핀 기준 계산용 모집단 행(ID·주소·좌표) 읽기. 호출자 트랜잭션 안에서 읽는다.
  static Future<List<Map<String, Object?>>> _fetchPinBasisRows(
    DatabaseExecutor d,
    String scope,
    List<Object?> args,
    bool Function()? isCancelled,
  ) async {
    const pageSize = 2000;
    final rows = <Map<String, Object?>>[];
    var offset = 0;
    while (true) {
      if (isCancelled?.call() == true || closeRequested) {
        throw const QueryCancelled();
      }
      final page = await PerformanceTrace.sql(
        'map.sql_pin_basis',
        () => d.rawQuery(
          'SELECT ID, 주소정규화, 위반장소, 위도, 경도 FROM $effectiveReportsView r WHERE $scope LIMIT ? OFFSET ?',
          [...args, pageSize, offset],
        ),
      );
      if (page.isEmpty) break;
      for (final row in page) {
        rows.add(Map<String, Object?>.from(row));
      }
      offset += page.length;
      if (page.length < pageSize) break;
      await Future<void>.delayed(Duration.zero);
    }
    return rows;
  }

  /// 주소키 → 대표 좌표를 TEMP 표로 올린다. 호출자가 finally 에서 지운다.
  static Future<String> _createPinRepTable(
    DatabaseExecutor d,
    Map<String, List<double>> representatives,
  ) async {
    final table = 'sr_pin_rep_${++_statsQuerySerial}';
    await d.execute(
      'CREATE TEMP TABLE $table(address_key TEXT PRIMARY KEY, lat REAL, lng REAL)',
    );
    if (representatives.isNotEmpty) {
      final batch = d.batch();
      for (final entry in representatives.entries) {
        batch.insert(table, {
          'address_key': entry.key,
          'lat': entry.value[0],
          'lng': entry.value[1],
        });
      }
      await batch.commit(noResult: true);
    }
    return table;
  }

  static final _mapCache = <String, Map<String, dynamic>>{};
  static final _mapMetaCache = <String, Map<String, dynamic>>{};
  static Future<Map<String, dynamic>> computeReportMapStats({
    String? year,
    String category = 'all',
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
    List<double>? bounds,
    double zoom = 7,
    String pinBasis = 'coords',
    bool Function()? isCancelled,
  }) => runBackgroundWork(() async {
    final d = await db;
    if (isCancelled?.call() == true || closeRequested) {
      throw const QueryCancelled();
    }
    final basis = normalizeMapPinBasis(pinBasis);
    final revision = await _readRevision(d);
    final metaKey =
        '${identityHashCode(d)}:$revision:${identityHashCode(AgencyRegistry.cacheVersion)}:$year:$category:$excludeWithdraw:$useRepresentativeRecords:$basis';
    final cacheKey = '$metaKey:${bounds?.join(',')}:$zoom';
    final cached = _mapCache[cacheKey];
    if (cached != null) return cached;
    // Metadata and cell weights share a read snapshot, including while a sync
    // writer is queued. Pages still yield to navigation on the Dart isolate.
    return d.transaction((d) async {
      // The transaction may have waited behind a native statistics snapshot.
      if (isCancelled?.call() == true || closeRequested) {
        throw const QueryCancelled();
      }
      final normalizedCategory = _normalizeMapCategory(category);
      final args = <Object?>[];
      final clauses = [_representativeWhere(useRepresentativeRecords)];
      if (normalizedCategory != 'all') {
        clauses.add('category = ?');
        args.add(normalizedCategory);
      }
      if (year != null && year != 'all' && year.isNotEmpty) {
        clauses.add('답변일 LIKE ?');
        args.add('$year%');
      }
      if (excludeWithdraw) clauses.add(ReportPolicy.sqlNotWithdrawn('처리상태'));
      final scope = clauses.join(' AND ');
      const valid =
          "typeof(위도) IN ('integer','real') AND typeof(경도) IN ('integer','real') AND CAST(위도 AS REAL) BETWEEN -90 AND 90 AND CAST(경도 AS REAL) BETWEEN -180 AND 180";
      // 핀 기준이 address 면 같은 주소 대표 좌표(effective)로 읽는다.
      // coords 면 아래 SQL 은 기존과 같다(위도·경도 원값).
      String? pinRepTable;
      var mapFrom = '$effectiveReportsView r';
      var mapValid = valid;
      var mapLat = '위도';
      var mapLng = '경도';
      var mapGroupKey =
          "COALESCE(NULLIF(trim(주소정규화),''),trim(위반장소))";
      if (basis == 'address') {
        final pinRows = await _fetchPinBasisRows(d, scope, args, isCancelled);
        final resolved = resolveMapPinBasis(pinRows, 'address');
        pinRepTable = await _createPinRepTable(d, resolved.representatives);
        mapFrom =
            '$effectiveReportsView r LEFT JOIN temp.$pinRepTable rep ON rep.address_key = ($_pinKeyExpr)';
        mapValid = _pinEffValid;
        mapLat = _pinEffLat;
        mapLng = _pinEffLng;
        mapGroupKey = _pinKeyExpr;
      }
      // Full population metadata is independent of the viewport. Retain this
      // small result even if a later viewport read is abandoned.
      final meta =
          _mapMetaCache[metaKey] ??
          await (() async {
            final metaRows = await PerformanceTrace.sql(
              'map.sql_meta',
              () => d.rawQuery(
                "SELECT COUNT(*) AS total, COUNT(CASE WHEN $mapValid THEN 1 END) AS geo, "
                // 2026-10-05 후속 A(서버 정의가 정본): effective 좌표가 있는 신고의
                // 서로 다른 (위도, 경도, 주소키) 조합 수. 주소키 빈 신고도 (lat,lng,'') 로 센다.
                "COUNT(DISTINCT CASE WHEN $mapValid THEN (CAST($mapLat AS REAL) || CHAR(31) || CAST($mapLng AS REAL) || CHAR(31) || IFNULL(($mapGroupKey),'')) END) AS address_groups, "
                "COUNT(CASE WHEN NOT ($mapValid) AND trim(IFNULL(위반장소,'')) != '' THEN 1 END) AS missing "
                'FROM $mapFrom WHERE $scope',
                args,
              ),
            );
            final agencyRows = await d.rawQuery(
              'SELECT DISTINCT 처리기관코드, 처리기관 FROM $effectiveReportsView r WHERE $scope',
              args,
            );
            final agencyCount = agencyRows
                .map(
                  (r) => registryKeyedAgency(
                    r['처리기관코드'],
                    r['처리기관']?.toString() ?? '',
                  ),
                )
                .where((a) => a.display.isNotEmpty)
                .map((a) => a.key)
                .toSet()
                .length;
            final years = await d.rawQuery(
              'SELECT DISTINCT substr(답변일,1,4) AS y FROM $effectiveReportsView ORDER BY y DESC',
            );
            final meta = <String, dynamic>{
              'available_years': years
                  .map((r) => r['y'])
                  .whereType<String>()
                  .where((y) => y.isNotEmpty)
                  .toList(),
              'current_year': year ?? 'all',
              'selected_category': normalizedCategory,
              'dedupe_mode': useRepresentativeRecords ? 'canonical' : 'raw',
              'pin_basis': basis,
              'total_reports': metaRows.first['total'],
              'geocoded_reports': metaRows.first['geo'],
              'missing_reports': metaRows.first['missing'],
              'address_groups': metaRows.first['address_groups'],
              'agency_count': agencyCount,
            };
            if (await _readRevision(d) == revision) {
              if (_mapMetaCache.length >= 4) _mapMetaCache.clear();
              _mapMetaCache[metaKey] = meta;
            }
            return meta;
          })();
      if (isCancelled?.call() == true || closeRequested) {
        throw const QueryCancelled();
      }
      // All coordinates remain unmodified. Cell centroids are presentation only.
      final box = bounds ?? const [-90.0, -180.0, 90.0, 180.0];
      if (box.length != 4 ||
          box.any((n) => !n.isFinite) ||
          box[0] >= box[2] ||
          box[1] >= box[3]) {
        throw ArgumentError('잘못된 지도 범위');
      }
      final latStep = (box[2] - box[0]) / 32;
      final lngStep = (box[3] - box[1]) / 32;
      final table = 'sr_map_${++_statsQuerySerial}';
      final cells = <String, _MapCellAccumulator>{};
      final timer = Stopwatch()..start();
      try {
        await d.execute(
          'CREATE TEMP TABLE $table AS SELECT '
          'CAST((CAST($mapLat AS REAL)-?)/? AS INTEGER) AS cy, CAST((CAST($mapLng AS REAL)-?)/? AS INTEGER) AS cx, '
          'AVG(CAST($mapLat AS REAL)) AS lat, AVG(CAST($mapLng AS REAL)) AS lng, COUNT(*) AS _weight, '
          '처리상태, 범칙금_과태료, 처리기관, 처리기관코드, category, MIN(위반장소) AS address, '
          'COUNT(DISTINCT 위반장소) AS addresses, MIN(CAST($mapLat AS REAL)) AS min_lat, MAX(CAST($mapLat AS REAL)) AS max_lat, MIN(CAST($mapLng AS REAL)) AS min_lng, MAX(CAST($mapLng AS REAL)) AS max_lng, '
          // 2026-10-05 후속 B: 칸 묶음 이름용 주소키별 집계. 표시문구는 그룹 내 최소값이며
          // _MapCellAccumulator 가 그룹 행들의 최소값 중 최소값을 대표 표시로 쓴다.
          "IFNULL(($mapGroupKey),'') AS addr_key, "
          "MIN(CASE WHEN trim(IFNULL(위반장소,'')) != '' THEN trim(위반장소) END) AS addr_display "
          'FROM $mapFrom WHERE $scope AND $mapValid AND '
          'CAST($mapLat AS REAL) >= ? AND CAST($mapLat AS REAL) < ? AND CAST($mapLng AS REAL) >= ? AND CAST($mapLng AS REAL) < ? '
          'GROUP BY cy, cx, 처리상태, 범칙금_과태료, 처리기관, 처리기관코드, category, addr_key',
          [
            box[0],
            latStep,
            box[1],
            lngStep,
            ...args,
            box[0],
            box[2],
            box[1],
            box[3],
          ],
        );
        var last = 0;
        while (true) {
          if (isCancelled?.call() == true || closeRequested) {
            throw const QueryCancelled();
          }
          final rows = await PerformanceTrace.sql(
            'map.sql_page',
            () => d.rawQuery(
              'SELECT rowid AS cursor, * FROM $table WHERE rowid > ? ORDER BY rowid LIMIT 1000',
              [last],
            ),
          );
          if (rows.isEmpty) break;
          PerformanceTrace.sync('map.cell_data', () {
            for (final row in rows) {
              cells
                  .putIfAbsent(
                    '${row['cy']}:${row['cx']}',
                    _MapCellAccumulator.new,
                  )
                  .add(row);
            }
          });
          last = rows.last['cursor'] as int;
          await Future<void>.delayed(Duration.zero);
        }
        final points = cells.values.map((c) => c.toJson()).toList()
          ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));
        final result = <String, dynamic>{
          'points': points,
          'meta': {
            ...meta,
            'rendered_cells': cells.length,
            'point_mode': 'spatial_cells',
            'viewport_reports': cells.values.fold<int>(
              0,
              (n, c) => n + c.total,
            ),
          },
        };
        if (isCancelled?.call() == true || closeRequested) {
          throw const QueryCancelled();
        }
        if (await _readRevision(d) == revision) {
          if (_mapCache.length >= 8) _mapCache.clear();
          _mapCache[cacheKey] = result;
        }
        return result;
      } finally {
        await d.execute('DROP TABLE IF EXISTS temp.$table');
        if (pinRepTable != null) {
          await d.execute('DROP TABLE IF EXISTS temp.$pinRepTable');
        }
        PerformanceTrace.record('map.total', timer, rows: cells.length);
      }
    }, exclusive: false);
  });

  static bool _validMapCoordinate(Object? lat, Object? lng) =>
      lat is num &&
      lng is num &&
      lat.isFinite &&
      lng.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lng >= -180 &&
      lng <= 180;

  static String? _missingLookupKey;
  static Future<void> _ensureMissingLookup(
    Database connection, {
    DatabaseExecutor? executor,
  }) async {
    Future<void> prepare(DatabaseExecutor d) async {
      final key = '${identityHashCode(connection)}:${await _readRevision(d)}';
      if (key == _missingLookupKey) return;
      await _buildMissingLookup(d, key, connection);
    }

    try {
      if (executor != null) {
        await prepare(executor);
      } else {
        await connection.transaction(prepare);
      }
    } catch (_) {
      _missingLookupKey = null;
      rethrow;
    }
  }

  static Future<void> _buildMissingLookup(
    DatabaseExecutor d,
    String key,
    Database connection,
  ) async {
    final snapshot = 'sr_missing_${++_statsQuerySerial}';
    await d.execute(
      'CREATE TEMP TABLE IF NOT EXISTS sr_missing_addresses(ID TEXT PRIMARY KEY, address_key TEXT NOT NULL)',
    );
    await d.execute(
      'CREATE INDEX IF NOT EXISTS temp.sr_missing_address_key ON sr_missing_addresses(address_key)',
    );
    await d.execute('DELETE FROM temp.sr_missing_addresses');
    try {
      await d.execute(
        'CREATE TEMP TABLE $snapshot AS SELECT ID, 주소정규화, 위반장소, 위도, 경도 FROM $effectiveReportsView',
      );
      var last = 0;
      while (true) {
        if (closeRequested) throw const QueryCancelled();
        final rows = await d.rawQuery(
          'SELECT rowid AS cursor,* FROM $snapshot WHERE rowid > ? ORDER BY rowid LIMIT 1000',
          [last],
        );
        if (rows.isEmpty) break;
        final batch = d.batch();
        for (final row in rows) {
          if (_validMapCoordinate(row['위도'], row['경도'])) {
            continue;
          }
          final normalized = normalizeGeocodeAddress(row['주소정규화']?.toString());
          final address = normalized.isEmpty
              ? normalizeGeocodeAddress(row['위반장소']?.toString())
              : normalized;
          if (address.isNotEmpty) {
            batch.insert('sr_missing_addresses', {
              'ID': row['ID'],
              'address_key': address,
            });
          }
        }
        await batch.commit(noResult: true);
        last = rows.last['cursor'] as int;
        await Future<void>.delayed(Duration.zero);
      }
      if (key == '${identityHashCode(connection)}:${await _readRevision(d)}') {
        _missingLookupKey = key;
      }
    } finally {
      await d.execute('DROP TABLE IF EXISTS temp.$snapshot');
    }
  }

  static Future<Map<String, dynamic>> computeReportMapMissingGroups({
    String? year,
    String category = 'all',
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
    int page = 0,
    String pinBasis = 'coords',
  }) => runBackgroundWork(() async {
    if (page < 0) throw ArgumentError('잘못된 페이지');
    final basis = normalizeMapPinBasis(pinBasis);
    final connection = await db;
    return connection.transaction((d) async {
      await _ensureMissingLookup(connection, executor: d);
      final q = ReportQuery(const ReportFilter(), agencyExpression: '처리기관');
      q.clauses.add(_representativeWhere(useRepresentativeRecords));
      if (category != 'all') {
        q.clauses.add('r.category = ?');
        q.args.add(category);
      }
      if (year != null && year != 'all') {
        q.clauses.add('r.답변일 LIKE ?');
        q.args.add('$year%');
      }
      if (excludeWithdraw) {
        q.clauses.add(ReportPolicy.sqlNotWithdrawn('r.처리상태'));
      }
      // 핀 기준이 address 면 같은 주소에 유효 좌표가 있는 신고는
      // effective 좌표가 생겨 목록에서 빠진다.
      String? pinRepTable;
      var source =
          '$effectiveReportsView r JOIN temp.sr_missing_addresses m ON m.ID=r.ID WHERE ${q.where}';
      try {
        if (basis == 'address') {
          final pinRows = await _fetchPinBasisRows(d, q.where, q.args, null);
          final resolved = resolveMapPinBasis(pinRows, 'address');
          pinRepTable = await _createPinRepTable(d, resolved.representatives);
          source =
              '$effectiveReportsView r JOIN temp.sr_missing_addresses m ON m.ID=r.ID '
              'LEFT JOIN temp.$pinRepTable rep ON rep.address_key = ($_pinKeyExpr) '
              'WHERE ${q.where} AND ($_pinKeyEmpty OR rep.lat IS NULL)';
        }
        final totals = await d.rawQuery(
          'SELECT COUNT(*) AS n, COUNT(DISTINCT m.address_key) AS groups FROM $source',
          q.args,
        );
        final groupRows = await d.rawQuery(
          'SELECT m.address_key,COUNT(*) AS n FROM $source GROUP BY m.address_key ORDER BY n DESC,m.address_key LIMIT 100 OFFSET ?',
          [...q.args, page * 100],
        );
        final groups = <Map<String, dynamic>>[];
        for (final group in groupRows) {
          final rows = await d.rawQuery(
            'SELECT r.* FROM $source AND m.address_key = ? ORDER BY r.신고일 DESC,r.신고번호 LIMIT 10',
            [...q.args, group['address_key']],
          );
          if (rows.isEmpty) throw StateError('missing_group_snapshot_changed');
          final first = rows.first;
          groups.add({
            'address': _stringify(first['위반장소']).trim().isEmpty
                ? group['address_key']
                : _stringify(first['위반장소']).trim(),
            'normalized_address': group['address_key'],
            'region': _stringify(first['행정구역']).trim(),
            'report_count': group['n'],
            'reports': rows,
          });
        }
        return {
          'groups': groups,
          'meta': {
            'group_count': totals.first['groups'],
            'report_count': totals.first['n'],
            'page': page,
            'page_size': 100,
            'pin_basis': basis,
          },
        };
      } finally {
        if (pinRepTable != null) {
          await d.execute('DROP TABLE IF EXISTS temp.$pinRepTable');
        }
      }
    }, exclusive: false);
  });

  static String _normalizeMapCategory(String value) {
    final normalized = value.trim().toLowerCase();
    return {'all', 'traffic', 'parking', 'other'}.contains(normalized)
        ? normalized
        : 'all';
  }

  static const _unassignedPersonValues = {'', '미지정'};

  /// 한 카테고리의 기관별/담당자별 표. 서버 `_build_stats_tables` 와 같은 규칙(S-10).
  @visibleForTesting
  static Map<String, dynamic> buildStatsCategory(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> lawScopeCatRows,
  ) {
    // 기관코드 registry 키로 같은 기관을 통합.
    // registry 가 로드됐으면 확인된 코드의 현행명·통계 키로 묶는다
    // (서버 `_build_stats_tables` 와 같음 — 묶음 기준은 이름이 아니라 agency_stat_key).
    ({String display, String key}) agencyKeyed(Object? code, String raw) {
      final t = raw.trim();
      return registryKeyedAgency(code, t);
    }

    // S-10: 표 포함 여부는 처리상태가 아니라 기관·담당자 값으로 정한다(서버 `_build_stats_tables` 와 동일).
    // 배정된 처리중 신고도 들어가고 `in_progress` 로 따로 센다. 기관이 비면 어느 표에도 넣지 않는다.
    // 2026-09-28 사용자 결정(S-10 대체): 표는 답변 완료 신고만(처리중·보완요청·이송·취하 제외). 서버 `_build_stats_tables` 와 같음.
    final answered = rows
        .where(
          (r) => _overviewCompletedStatuses.contains(
            (r['처리상태'] as String? ?? '').trim(),
          ),
        )
        .toList(growable: false);
    final agencyAgg = <String, _AgencyAgg>{};
    for (final r in answered) {
      final keyed = agencyKeyed(r['처리기관코드'], (r['처리기관'] as String? ?? ''));
      if (keyed.display.isEmpty) continue;
      agencyAgg.putIfAbsent(
        keyed.key,
        () => _AgencyAgg(keyed.display, '', keyed.key),
      );
      agencyAgg[keyed.key]!.add(r);
    }

    final allAgency = agencyAgg.values.map((a) => a.toJson()).toList()
      ..sort((a, b) {
        var c = (b['total'] as int).compareTo(a['total'] as int);
        if (c != 0) return c;
        c = (a['agency'] as String).compareTo(b['agency'] as String);
        if (c != 0) return c;
        return (a['agency_key'] as String).compareTo(b['agency_key'] as String);
      });

    final personAgg = <String, _AgencyAgg>{};
    for (final r in answered) {
      final keyed = agencyKeyed(r['처리기관코드'], (r['처리기관'] as String? ?? ''));
      final manager = (r['담당자'] as String? ?? '').trim();
      if (keyed.display.isEmpty || _unassignedPersonValues.contains(manager)) {
        continue;
      }
      final key = '${keyed.key}\t$manager';
      personAgg.putIfAbsent(
        key,
        () => _AgencyAgg(keyed.display, manager, keyed.key),
      );
      personAgg[key]!.add(r);
    }

    final allPerson = personAgg.values.map((a) => a.toJson()).toList()
      ..sort((a, b) {
        var c = (b['total'] as int).compareTo(a['total'] as int);
        if (c != 0) return c;
        c = (a['agency'] as String).compareTo(b['agency'] as String);
        if (c != 0) return c;
        c = (a['person'] as String).compareTo(b['person'] as String);
        if (c != 0) return c;
        return (a['agency_key'] as String).compareTo(b['agency_key'] as String);
      });

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
  }) async {
    final d = await db;
    final withdrawFilter = excludeWithdraw
        ? 'AND ${ReportPolicy.sqlNotWithdrawn('처리상태')}'
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
                 SUM(CASE WHEN ${ReportPolicy.sqlNotWithdrawn('처리상태')} THEN 1 ELSE 0 END)        AS valid_count,
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
    return rows.map((r) => _rowToReportWithCounts(r)).toList();
  }

  static Report _rowToReportWithCounts(
    Map<String, dynamic> r, {
    bool detailLoaded = true,
  }) {
    // 같은 변환 두 벌을 하나로(M-30): 기본 변환 + 중복 건수만 덧붙인다.
    return _rowToReport(r, detailLoaded: detailLoaded).copyWith(
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

  /// Existing "clear all" action needs identities, never full Report bodies.
  static Future<List<String>> getDisplayedWatchlistNumbers({
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
  }) => runBackgroundWork(() async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT r.신고번호 FROM $effectiveReportsView r WHERE ${_representativeWhere(useRepresentativeRecords)} AND ${_watchWhere(useRepresentativeRecords)}${excludeWithdraw ? " AND ${ReportPolicy.sqlNotWithdrawn('r.처리상태')}" : ""}',
    );
    return rows.map((r) => _stringify(r['신고번호'])).toList(growable: false);
  });

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
    bool useRepresentativeRecords = false,
  }) async {
    final numbers = await getWatchlistNumbers();
    if (numbers.isEmpty) return [];
    final d = await db;
    final placeholders = numbers.map((_) => '?').join(',');
    final withdrawFilter = excludeWithdraw
        ? ' AND ${ReportPolicy.sqlNotWithdrawn('처리상태')}'
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
    return projected.map((r) => _rowToReport(r)).toList();
  }

  // ── 검색 ─────────────────────────────────────────────────────────────────

  static Future<List<Report>> searchReports(
    String query, {
    bool excludeWithdraw = false,
    bool useRepresentativeRecords = false,
  }) async {
    final d = await db;
    final q = '%$query%';
    var where =
        '(신고명 LIKE ? OR 신고번호 LIKE ? OR 차량번호 LIKE ? OR 처리기관 LIKE ? OR 위반법규 LIKE ?)';
    final args = <dynamic>[q, q, q, q, q];
    if (excludeWithdraw) {
      where += ' AND ${ReportPolicy.sqlNotWithdrawn('처리상태')}';
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
    return projected.map((r) => _rowToReport(r)).toList();
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

  /// 모든 사용자가 볼 수 있는 합성 예시 신고 100건. 별도 DB만 비우고 다시 채운다.
  static Future<void> seedPlayReviewDemo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppPrefsKeys.standaloneDemoMode, true);
    await closeDb();
    _invalidateProjectRowsCache();
    await clearAll();
    final d = await db;
    final now = DateTime.now();
    final syncedAt = now.millisecondsSinceEpoch;
    final seededAt = now.toIso8601String();
    const categories = ['traffic', 'parking', 'other'];
    const titles = [
      '신호 위반',
      '횡단보도 주정차',
      '보도 위 적치물',
      '중앙선 침범',
      '소화전 주변 주정차',
      '쓰레기 무단투기',
      '안전모 미착용',
      '버스 정류장 주정차',
      '시설물 파손',
      '차로 변경 위반',
    ];
    const agencies = ['예시 교통 담당 기관', '예시 주차 담당 기관', '예시 생활안전 담당 기관'];
    const places = [
      ('서울특별시', 37.5665, 126.9780),
      ('부산광역시', 35.1796, 129.0756),
      ('대구광역시', 35.8714, 128.6014),
      ('광주광역시', 35.1595, 126.8526),
      ('대전광역시', 36.3504, 127.3845),
      ('울산광역시', 35.5384, 129.3114),
      ('인천광역시', 37.4563, 126.7052),
      ('제주특별자치도', 33.4996, 126.5312),
    ];
    String date(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';

    await d.transaction((txn) async {
      for (var index = 0; index < 100; index++) {
        final number = index + 1;
        final day = now.subtract(Duration(days: index * 3 + 2));
        final answered = index % 5 != 0;
        final categoryIndex = index % categories.length;
        final place = places[index % places.length];
        final reportNumber = 'DEMO-${number.toString().padLeft(4, '0')}';
        final address =
            '${place.$1} 예시 위치 ${number.toString().padLeft(3, '0')}';
        await txn.insert('reports', {
          'ID': 'demo-$reportNumber',
          '상태': answered ? '답변완료' : '처리중',
          '신고번호': reportNumber,
          '신고명': '${titles[index % titles.length]} (예시)',
          '신고일': date(day),
          '만족도조사여부': answered ? (index % 4 == 0 ? '참여 완료' : '참여 가능') : '답변 대기',
          '별점': answered && index % 4 == 0 ? (index % 5) + 1 : null,
          '별점사유': '',
          '감시목록': index % 20 == 0 ? 'Y' : 'N',
          '처리상태': answered ? (index % 7 == 0 ? '불수용' : '수용') : '처리중',
          '차량번호': categoryIndex == 2 ? '' : '12가${1000 + index % 18}',
          '위반법규': '',
          '범칙금_과태료': answered && index % 3 == 0 ? '과태료: 40,000원' : '',
          '벌점': '',
          // 실제 자료처럼 처리중(답변 전) 신고에는 처리기관·담당자가 아직 없다.
          '처리기관': answered ? agencies[categoryIndex] : '',
          '담당자': answered ? '예시 담당자' : '',
          '답변일': answered ? date(day.add(const Duration(days: 2))) : '',
          '발생일자': date(day),
          '발생시각': '${(8 + index % 12).toString().padLeft(2, '0')}:30',
          '위반장소': address,
          '주소정규화': address,
          '행정구역': place.$1,
          '위도': place.$2 + (index % 5) * 0.0001,
          '경도': place.$3 + (index % 5) * 0.0001,
          '지오코딩상태': 'ok',
          '종결여부': answered ? 'Y' : 'N',
          '신고내용': '기능을 살펴보기 위한 가상 신고 내용입니다. 실제 신고가 아닙니다.',
          '처리내용': answered ? '예시 처리 결과입니다. 실제 기관의 답변이 아닙니다.' : '',
          '지도': '',
          '첨부사진': '',
          '첨부파일': '',
          'category': categories[categoryIndex],
          'entry_value': '',
          'raw_content': '',
          'synced_at': syncedAt,
        });
      }
      await txn.insert('sync_meta', {
        'key': 'last_sync',
        'value': seededAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('sync_meta', {
        'key': 'watchlist',
        'value': 'DEMO-0001,DEMO-0021,DEMO-0041,DEMO-0061,DEMO-0081',
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
    try {
      // Read all tables from one SQLite snapshot, including committed WAL rows.
      // Never drop a required sidecar or turn an open/checkpoint failure into success.
      await copyReadOnlyDatabaseSnapshot(sourceDbPath, preparedDbPath);
    } catch (_) {
      await _cleanupPreparedSnapshot(preparedDbPath);
      rethrow;
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

  static Future<void> _commitImportedDatabaseLocked(
    String importedDbPath, {
    String? destination,
  }) async {
    final dbPath = destination ?? await getDbPath();
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
      // A closed WAL database has all values in the main file, but its WAL
      // header makes read-only backup consumers create sidecars. Finalize the
      // copied snapshot as a portable standalone SQLite file.
      final portable = await openDatabase(backupPath, singleInstance: false);
      try {
        await portable.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
        await portable.rawQuery('PRAGMA journal_mode=DELETE');
      } finally {
        await portable.close();
      }
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

    for (final tableName in sourceTables) {
      if (!tableNames.contains(tableName)) continue;

      final columns = await serverDb.rawQuery('PRAGMA table_info($tableName)');
      final columnNames = columns
          .map((c) => c['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toSet();
      if (!columnNames.containsAll(requiredColumns)) {
        throw Exception('서버 DB 병합 테이블 형식이 올바르지 않습니다: $tableName');
      }
    }

    // A supported, authenticated zero-row snapshot is valid.
  }

  /// Reject rows the JOIN/converter could silently omit or replace.
  static Future<void> _preflightServerPopulation(
    Database serverDb,
    Set<String> tables,
  ) async {
    final sources = <String>[];
    final details = <String>[];
    for (final category in ['traffic', 'parking', 'other']) {
      final detail = 'mysafetydetail_$category';
      final originals = tables.contains('mysafety') && tables.contains(detail);
      final source = originals ? detail : 'mysafetymerge_$category';
      if (!tables.contains(source)) continue;
      sources.add('SELECT ID FROM "$source"');
      if (originals) {
        details.add('SELECT ID FROM "$detail"');
        final orphan = await serverDb.rawQuery(
          'SELECT 1 FROM "$detail" d LEFT JOIN mysafety t ON t.ID=d.ID WHERE t.ID IS NULL LIMIT 1',
        );
        if (orphan.isNotEmpty) {
          throw const FormatException('상세에 대응하는 목록 행이 없습니다.');
        }
      }
    }
    if (sources.isEmpty) throw const FormatException('변환 대상 표가 없습니다.');
    final union = sources.join(' UNION ALL ');
    final invalid = await serverDb.rawQuery(
      "SELECT 1 FROM ($union) WHERE ID IS NULL OR typeof(ID)!='text' OR trim(ID)='' OR trim(ID)!=ID LIMIT 1",
    );
    final duplicate = await serverDb.rawQuery(
      'SELECT ID FROM ($union) GROUP BY ID HAVING COUNT(*)>1 LIMIT 1',
    );
    if (invalid.isNotEmpty || duplicate.isNotEmpty) {
      throw const FormatException('신고 ID가 없거나 분류 사이에서 중복됩니다.');
    }
    if (details.isNotEmpty) {
      // A mixed layout can keep another category in a merge table.
      final missing = await serverDb.rawQuery(
        'SELECT 1 FROM mysafety t WHERE NOT EXISTS (SELECT 1 FROM ($union) d WHERE d.ID=t.ID) LIMIT 1',
      );
      if (missing.isNotEmpty) {
        throw const FormatException('목록에 대응하는 상세 또는 병합 행이 없습니다.');
      }
    }
    for (final table in ['mysafety_raw_content', 'mysafety_entry_value']) {
      if (!tables.contains(table)) continue;
      final orphan = await serverDb.rawQuery(
        'SELECT 1 FROM "$table" r WHERE NOT EXISTS (SELECT 1 FROM ($union) d WHERE d.ID=r.ID) LIMIT 1',
      );
      if (orphan.isNotEmpty) {
        throw FormatException('$table 원문 행을 보존할 신고가 없습니다.');
      }
      final duplicate = await serverDb.rawQuery(
        'SELECT ID FROM "$table" GROUP BY ID HAVING COUNT(*)>1 LIMIT 1',
      );
      if (duplicate.isNotEmpty) throw FormatException('$table ID가 중복됩니다.');
    }
  }

  static Future<void> _verifyImportedTable(
    Database source,
    Set<String> sourceTables,
    Database target,
    String sourceTable,
    String targetTable,
  ) async {
    if (!sourceTables.contains(sourceTable)) return;
    final info = await target.rawQuery('PRAGMA table_info("$targetTable")');
    final keys = info
        .where((r) => (r['pk'] as int) > 0)
        .map((r) => r['name'] as String)
        .toList();
    final types = await _columnTypes(target, targetTable);
    if (keys.isEmpty) throw FormatException('$targetTable 검증 키가 없습니다.');
    await for (final rows in _readServerTablePages(
      source,
      sourceTables,
      sourceTable,
    )) {
      final expectedRows = [
        for (final row in rows)
          {
            for (final entry in row.entries)
              if (types.containsKey(entry.key))
                entry.key: _coerceForColumn(entry.value, types[entry.key]),
          },
      ];
      final args = <Object?>[];
      for (final row in expectedRows) {
        args.addAll(keys.map((k) => row[k]));
      }
      final actualRows = await target.query(
        targetTable,
        where: List.filled(
          rows.length,
          '(${keys.map((k) => '"$k" IS ?').join(' AND ')})',
        ).join(' OR '),
        whereArgs: args,
      );
      String key(Map<String, Object?> row) =>
          jsonEncode(keys.map((k) => row[k]).toList());
      final actual = {for (final row in actualRows) key(row): row};
      if (actual.length != expectedRows.length) {
        throw FormatException('$targetTable 원본 키 보존 실패');
      }
      for (final expected in expectedRows) {
        final row = actual[key(expected)];
        if (row == null) throw FormatException('$targetTable 원본 키 보존 실패');
        _verifyCells(targetTable, expected, row);
      }
    }
  }

  static void _verifyCells(
    String table,
    Map<String, Object?> expected,
    Map<String, Object?> actual,
  ) {
    for (final entry in expected.entries) {
      final value = actual[entry.key];
      final expectedValue = entry.value;
      final equal = expectedValue is List<int> && value is List<int>
          ? listEquals(expectedValue, value)
          : value == expectedValue;
      final sameType =
          (expectedValue == null && value == null) ||
          (expectedValue is int && value is int) ||
          (expectedValue is double && value is double) ||
          (expectedValue is String && value is String) ||
          (expectedValue is List<int> && value is List<int>);
      if (!equal || !sameType) {
        throw FormatException('$table.${entry.key} 값 또는 타입 보존 실패');
      }
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
  static Stream<List<Map<String, Object?>>> _readServerTablePages(
    Database serverDb,
    Set<String> serverTables,
    String table,
  ) async* {
    if (!serverTables.contains(table)) return;
    int? cursor;
    while (true) {
      final rows = await PerformanceTrace.sql(
        'exchange.table_page',
        () => serverDb.rawQuery(
          'SELECT rowid AS _sr_cursor, * FROM "$table" ${cursor == null ? "" : "WHERE rowid>?"} ORDER BY rowid LIMIT 128',
          cursor == null ? [] : [cursor],
        ),
      );
      if (rows.isEmpty) return;
      cursor = rows.last['_sr_cursor'] as int;
      yield rows
          .map((r) => Map<String, Object?>.from(r)..remove('_sr_cursor'))
          .toList();
    }
  }

  static Stream<List<Map<String, Object?>>> _readServerReportRows(
    Database serverDb,
    Set<String> serverTables, {
    required String mergeTable,
    required String category,
  }) async* {
    final detailTable = 'mysafetydetail_$category';
    final originals =
        serverTables.contains('mysafety') && serverTables.contains(detailTable);
    final source = originals ? detailTable : mergeTable;
    if (!serverTables.contains(source)) return;
    final titleColumns = originals
        ? (await serverDb.rawQuery('PRAGMA table_info("mysafety")'))
              .map((r) => r['name'] as String)
              .where((name) => name != 'ID')
              .map((name) => 't."$name" AS "$name"')
              .join(', ')
        : '';
    final hasEntry = serverTables.contains('mysafety_entry_value');
    final hasRaw = serverTables.contains('mysafety_raw_content');
    int? cursor;
    while (true) {
      final rows = await PerformanceTrace.sql(
        'exchange.report_page',
        () => serverDb.rawQuery(
          'SELECT d.rowid AS _sr_cursor,d.* ${originals ? ', $titleColumns' : ''}, '
          '${hasEntry ? 'e.entry_value' : 'NULL'} AS _sr_entry_value, '
          '${hasRaw ? 'rr.ID' : 'NULL'} AS _sr_raw_present, '
          '${hasRaw ? 'rr.raw_content' : 'NULL'} AS _sr_raw_content, '
          '${hasRaw ? 'rr.raw_type' : 'NULL'} AS _sr_raw_type, '
          '${hasRaw ? 'rr.saved_at' : 'NULL'} AS _sr_saved_at '
          'FROM "$source" d '
          '${originals ? 'JOIN mysafety t ON t.ID=d.ID ' : ''}'
          '${hasEntry ? 'LEFT JOIN mysafety_entry_value e ON e.ID=d.ID ' : ''}'
          '${hasRaw ? 'LEFT JOIN mysafety_raw_content rr ON rr.ID=d.ID ' : ''}'
          '${cursor == null ? "" : "WHERE d.rowid>?"} ORDER BY d.rowid LIMIT 128',
          cursor == null ? [] : [cursor],
        ),
      );
      if (rows.isEmpty) return;
      cursor = rows.last['_sr_cursor'] as int;
      yield rows;
    }
  }

  /// 계약 타입(integer/real)에 맞춘다. 숫자 문자열은 숫자로, 빈 문자열은 NULL 로(숫자 열에 '' 는 잘못된 값).
  static Object? _coerceForColumn(Object? value, String? declaredType) {
    final type = (declaredType ?? '').toUpperCase();
    if (value is num) {
      if (!value.isFinite || (type.contains('INT') && value != value.toInt())) {
        throw const FormatException('숫자 열에 보존할 수 없는 값이 있습니다.');
      }
      return value;
    }
    if (value is! String) return value;
    if (type.contains('INT')) {
      if (value.trim().isEmpty) return null;
      final integer = int.tryParse(value.trim());
      if (integer != null) return integer;
      final number = double.tryParse(value.trim());
      if (number != null && number.isFinite && number == number.toInt()) {
        return number.toInt();
      }
      throw const FormatException('정수 열에 보존할 수 없는 값이 있습니다.');
    }
    if (type.contains('REAL')) {
      if (value.trim().isEmpty) return null;
      final number = double.tryParse(value.trim());
      if (number == null || !number.isFinite) {
        throw const FormatException('실수 열에 보존할 수 없는 값이 있습니다.');
      }
      return number;
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
      'mysafety_raw_content': (await _columnTypes(
        localDb,
        'report_raw',
      )).keys.toSet(),
      'mysafety_sync_meta': const {'key', 'value'},
      'mysafety_watchlist': const {'신고번호'},
      'mysafety_entry_value': const {'ID', 'entry_value'},
      'mysafety_geocode_cache': (await _columnTypes(
        localDb,
        'geocode_cache',
      )).keys.toSet(),
      'mysafety_duplicate_group': (await _columnTypes(
        localDb,
        DuplicateProjectionService.groupTable,
      )).keys.toSet(),
      'mysafety_duplicate_member': (await _columnTypes(
        localDb,
        DuplicateProjectionService.memberTable,
      )).keys.toSet(),
      'mysafety_report_override': (await _columnTypes(
        localDb,
        'report_override',
      )).keys.toSet(),
      'mysafety_duplicate_decision': (await _columnTypes(
        localDb,
        'duplicate_decision',
      )).keys.toSet(),
    };
    final problems = <String>[];
    for (final entry in known.entries) {
      if (!serverTables.contains(entry.key)) continue;
      for (final col in (await _columnTypes(serverDb, entry.key)).keys) {
        if (entry.value.contains(col)) continue;
        final n =
            Sqflite.firstIntValue(
              await serverDb.rawQuery(
                'SELECT COUNT(*) FROM "${entry.key}" WHERE "$col" IS NOT NULL',
              ),
            ) ??
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
    return _withFileExclusive(() => _importFromServerDbLocked(serverDbPath));
  }

  static Future<int> _importFromServerDbLocked(String serverDbPath) async {
    final destination = await getDbPath();
    final owner = await currentKakaoId();
    final preferences = await SharedPreferences.getInstance();
    final generation = preferences.getInt('native_config_generation') ?? 0;
    final preparedDbPath = await _prepareExternalDbSnapshot(serverDbPath);
    final serverDb = await openDatabase(preparedDbPath, readOnly: true);
    Directory? stagingDir;
    Database? localDb;

    try {
      // 이전(또는 더 새) 버전 서버 DB 는 가져오지 않는다(2026-09-26 초기화 크롤링 릴리스).
      _refuseOtherVersion(
        await serverDb.getVersion(),
        serverSchemaVersion,
        '서버',
      );
      // 다른 카카오 계정(또는 주인을 모르는) 서버 DB 는 가져오지 않는다 — 무엇이든 바꾸기 전에
      await _refuseForeignOwner(serverDb, 'mysafety_sync_meta');
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

      await _preflightServerPopulation(serverDb, serverTables);

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
              .toSet();

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
          batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.abort);
          if (++queued >= 500) await flush();
        }

        for (final entry in sourceTableMap.entries) {
          await for (final rows in _readServerReportRows(
            serverDb,
            serverTables,
            mergeTable: entry.key,
            category: entry.value,
          )) {
            for (final row in rows) {
              final reportId = row['ID']?.toString() ?? '';
              if (reportId.isEmpty) throw const FormatException('빈 신고 ID');
              // 값은 바꾸지 않는다(NULL 은 NULL). 모바일에 있는 열만, 계약 타입에 맞춰.
              final importedRow = <String, Object?>{
                for (final e in row.entries)
                  if (reportTypes.containsKey(e.key))
                    e.key: _coerceForColumn(e.value, reportTypes[e.key]),
                'category': entry.value,
                // 서버 행 없음 = 모름(NULL), 행의 값(빈 문자열 포함)은 그대로 — PC exchange 와 같은 규칙(감사 SOL-03).
                'entry_value': row['_sr_entry_value'],
                'raw_content': '',
              };
              // 구서버에 지오코딩 열이 없을 때만 주소에서 계산한다(계산값, owner=derived).
              if (!geoColumns.any(row.containsKey)) {
                importedRow.addAll(
                  officialGeoPayload(
                    importedRow['위반장소']?.toString(),
                    null,
                    null,
                  ),
                );
              }
              importedRow['감시목록'] = watchNumbers.contains(importedRow['신고번호'])
                  ? 'Y'
                  : 'N';
              await put('reports', importedRow);
              if (row['_sr_raw_present'] != null) {
                await put('report_raw', {
                  'ID': reportId,
                  'raw_content': row['_sr_raw_content'],
                  'raw_type': row['_sr_raw_type'],
                  'saved_at': row['_sr_saved_at'],
                });
              }
              imported++;
            }
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
          await for (final rows in _readServerTablePages(
            serverDb,
            serverTables,
            pair.key,
          )) {
            for (final row in rows) {
              await put(pair.value, {
                for (final e in row.entries)
                  if (types.containsKey(e.key))
                    e.key: _coerceForColumn(e.value, types[e.key]),
              });
            }
          }
        }
        await flush();
      });

      for (final entry in sourceTableMap.entries) {
        await for (final rows in _readServerReportRows(
          serverDb,
          serverTables,
          mergeTable: entry.key,
          category: entry.value,
        )) {
          final ids = rows.map((r) => r['ID']).toList();
          final marks = List.filled(ids.length, '?').join(',');
          final actualReports = {
            for (final r in await localDb.query(
              'reports',
              where: 'ID IN ($marks)',
              whereArgs: ids,
            ))
              r['ID']: r,
          };
          final actualRaw = {
            for (final r in await localDb.query(
              'report_raw',
              where: 'ID IN ($marks)',
              whereArgs: ids,
            ))
              r['ID']: r,
          };
          for (final row in rows) {
            final expected = <String, Object?>{
              for (final e in row.entries)
                if (reportTypes.containsKey(e.key))
                  e.key: _coerceForColumn(e.value, reportTypes[e.key]),
              'category': entry.value,
              'entry_value': row['_sr_entry_value'],
              'raw_content': '',
              '감시목록': watchNumbers.contains(row['신고번호']) ? 'Y' : 'N',
            };
            final actual = actualReports[row['ID']];
            if (actual == null) throw const FormatException('신고 원본 키 보존 실패');
            _verifyCells('reports', expected, actual);
            if (row['_sr_raw_present'] != null) {
              final raw = actualRaw[row['ID']];
              if (raw == null) throw const FormatException('원문 원본 키 보존 실패');
              _verifyCells('report_raw', {
                'ID': row['ID'],
                'raw_content': row['_sr_raw_content'],
                'raw_type': row['_sr_raw_type'],
                'saved_at': row['_sr_saved_at'],
              }, raw);
            }
          }
        }
      }
      for (final pair in const {
        'mysafety_geocode_cache': 'geocode_cache',
        'mysafety_duplicate_group': DuplicateProjectionService.groupTable,
        'mysafety_duplicate_member': DuplicateProjectionService.memberTable,
        'mysafety_report_override': 'report_override',
        'mysafety_duplicate_decision': 'duplicate_decision',
      }.entries) {
        await _verifyImportedTable(
          serverDb,
          serverTables,
          localDb,
          pair.key,
          pair.value,
        );
      }
      for (final row in syncMetaRows) {
        final actual = await localDb.query(
          'sync_meta',
          where: 'key=?',
          whereArgs: [row['key']],
        );
        if (actual.length != 1) throw const FormatException('메타데이터 키 보존 실패');
        _verifyCells('sync_meta', row, actual.single);
      }
      await _refuseForeignOwner(serverDb, 'mysafety_sync_meta');
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
      if (reportCountRows.single['cnt'] != imported) {
        throw const FormatException('임포트 원본과 결과의 신고 수가 다릅니다.');
      }

      await localDb.close();
      localDb = null;
      // 개인 DB 교체 직전 커뮤니티 dataset 선회전 — 실패하면 교체하지 않는다(H-02).
      await _publishDatabaseExchange(
        stagedDbPath,
        'server_import',
        destination: destination,
        owner: owner,
        generation: generation,
      );
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

  static Future<void> _publishDatabaseExchange(
    String prepared,
    String reason, {
    required String destination,
    required String? owner,
    required int generation,
  }) async {
    Future<void> checkScope() async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      if ((preferences.getInt('native_config_generation') ?? 0) != generation ||
          owner == null ||
          await currentKakaoId() != owner ||
          await getDbPath() != destination) {
        throw ForeignDatabaseException(
          'DB 준비 중 계정 또는 데이터 경로가 변경되었습니다. 자료를 바꾸지 않았습니다.',
        );
      }
    }

    await checkScope();
    final store = await CommunityStore.open();
    await LocalDatabaseExchange.publish(
      destination: destination,
      prepared: prepared,
      reason: reason,
      store: store,
      copy: copyDatabaseConsistent,
      commit: () async {
        await checkScope();
        await _commitImportedDatabaseLocked(prepared, destination: destination);
      },
    );
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
      throw Exception(
        '커뮤니티 공유 저장소를 준비하지 못해 DB 를 바꾸지 않았습니다($reason). 다시 시도해 주세요. [$e]',
      );
    }
  }

  /// 모바일 백업 .db 로 현재 DB 를 바꾼다(저장 계층 재설계 R1d, M-11).
  /// 임시 사본에서 종류·버전 확인 → 마이그레이션 → 무결성 검사를 마친 뒤 `_commitImportedDatabase` 로 교체한다
  /// (기존 DB 는 `<db>.before_import.<시각>.bak` 으로 남기고(최근 3개) 실패하면 되돌린다). 서버 DB 는 importFromServerDb 를 쓴다.
  static Future<void> replaceFromBackup(String backupDbPath) async {
    _refuseDuringBackgroundWork('백업 복원을');
    return _withFileExclusive(() => _replaceFromBackupLocked(backupDbPath));
  }

  static Future<void> _replaceFromBackupLocked(String backupDbPath) async {
    final destination = await getDbPath();
    final owner = await currentKakaoId();
    final preferences = await SharedPreferences.getInstance();
    final generation = preferences.getInt('native_config_generation') ?? 0;
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
      String? probeError;
      if (version == dbVersion) {
        // 다른 카카오 계정(또는 주인을 모르는) 백업은 복원하지 않는다(직전 DB 되돌리기도 이 경로) — 무엇이든 바꾸기 전에
        try {
          await _refuseForeignOwner(probe, 'sync_meta');
        } on ForeignDatabaseException catch (e) {
          probeError = e.message;
        }
      }
      await probe.close();
      if (probeError != null) throw ForeignDatabaseException(probeError);
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
      await _publishDatabaseExchange(
        stagedPath,
        'restore',
        destination: destination,
        owner: owner,
        generation: generation,
      );
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
    bool detailLoaded = true,
  }) {
    final agency = registryDisplayAgency(
      r['처리기관코드'],
      r['처리기관'] as String? ?? '',
    );
    return Report(
      id: r['ID'] as String? ?? '',
      reportNumber: r['신고번호'] as String? ?? '',
      name: r['신고명'] as String? ?? '',
      date: r['신고일'] as String? ?? '',
      responseDate: r['답변일'] as String? ?? '',
      agency: agency,
      // NULL 보존: DB NULL 을 '' 로 바꾸면 다시 저장할 때 '' 가 된다(REVIEW2 중간-3).
      agencyCode: r['처리기관코드'] as String?,
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
      detailLoaded: detailLoaded,
    );
  }
}

// ── 집계 헬퍼 ────────────────────────────────────────────────────────────────
