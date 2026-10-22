// 1회 전송 진행 보고(CLIENT-RULES 4-1): POST {SUPABASE_URL}/functions/v1/community-ingest/progress.
//
// 개수와 상태 코드만 보낸다(신고 ID·본문·URL·공식 사이트 ID·기기 식별자는 넣을 칸이 없다).
// 마지막 시도·전송 내용 요약은 community.db meta 에 둔다 — 앱과 WorkManager isolate 가 같은 파일을 열어 공유한다.
// 실패는 조용히 넘기고 재시도하지 않는다. 503 maintenance 는 결과 기록(`progress_report.maintenance`)만 남기고
// 중지 처리는 호출자(B)가 [ProgressReporter.lastMaintenance] 로 읽어 한다.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../capture/community_capture.dart' show mobileParserVersion;
import '../community_store.dart';
import 'report_env.dart';

class ProgressReporter {
  ProgressReporter._();

  static const metaLast = 'progress_report.last';
  static const metaMaintenance = 'progress_report.maintenance';
  static const metaResult = 'progress_report.result';

  /// 같은 연결에 두 번 보내지 않는 간격(서버가 429).
  static const minGap = Duration(seconds: 60);
  static const periodicGap = Duration(minutes: 10);
  static const maxBodyBytes = 4096;
  static const timeout = Duration(seconds: 15);

  static const _activeStates = {
    'listing',
    'filling',
    'uploading',
    'paused',
    'waiting_optimize',
    'holds',
  };
  static const _allStates = {..._activeStates, 'done', 'none'};
  static const triggers = {'start', 'state_change', 'periodic', 'daily'};

  /// 보낼 때가 되면 보낸다. 아무것도 던지지 않는다.
  ///
  /// [trigger]: `start`(앱 시작·게이트 통과 뒤 1회) / `state_change`(상태 키가 바뀐 때만) /
  /// `periodic`(진행 중이면 마지막 시도 뒤 10분) / `daily`(done·none 이면 하루 1번).
  /// [backfill]·[optimize]·[pace] 는 progress.schema.json 의 같은 이름 객체.
  static Future<void> maybeSend({
    required CommunityStore store,
    required String trigger,
    required Map<String, Object?> backfill,
    required Map<String, Object?> optimize,
    required String officialLogin,
    Map<String, Object?>? pace,
  }) async {
    try {
      await _run(store, trigger, backfill, optimize, officialLogin, pace);
    } catch (_) {
      // 진행 보고는 다른 기능에 영향을 주지 않는다.
    }
  }

  /// 마지막 503 maintenance 기록 `{at, resume_at, retry_after_s}`. 없거나 지났으면 null 이 아니라 호출자가 판단한다.
  static Future<Map<String, Object?>?> lastMaintenance(
    CommunityStore store,
  ) async {
    final raw = await store.meta(metaMaintenance);
    if (raw == null) return null;
    try {
      final d = jsonDecode(raw);
      return d is Map ? Map<String, Object?>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearMaintenance(CommunityStore store) async {
    await store.db.delete('meta', where: 'key=?', whereArgs: [metaMaintenance]);
  }

  /// 상태 키: 이 중 하나가 바뀌면 state_change(개수만 바뀐 것은 아님).
  static String stateKey(
    Map<String, Object?> backfill,
    Map<String, Object?> optimize,
    String officialLogin,
  ) => [
    backfill['state'],
    backfill['phase'],
    backfill['reason'],
    officialLogin,
    optimize['required'],
    optimize['running'],
    optimize['holds_only'],
  ].join('|');

  static Future<void> _run(
    CommunityStore store,
    String trigger,
    Map<String, Object?> backfill,
    Map<String, Object?> optimize,
    String officialLogin,
    Map<String, Object?>? pace,
  ) async {
    if (!triggers.contains(trigger)) return;
    final state = backfill['state'];
    if (state is! String || !_allStates.contains(state)) return;

    final ctx = await store.activeContext();
    final connectionId = ctx?['connection_id'];
    if (connectionId is! String || connectionId.isEmpty) {
      return await _result(store, 'skipped', 'no_connection');
    }
    final now = ReportEnv.now();
    final last = await _readLast(store);
    final attemptAt = last['attempt_at'] is int
        ? DateTime.fromMillisecondsSinceEpoch(last['attempt_at'] as int)
        : null;
    // 같은 연결 60초 안 두 번째 금지(모든 trigger 공통).
    if (attemptAt != null) {
      final gap = now.difference(attemptAt);
      if (!gap.isNegative && gap < minGap) {
        return await _result(store, 'skipped', 'rate_60s');
      }
    }
    final key = stateKey(backfill, optimize, officialLogin);
    switch (trigger) {
      case 'start':
        break;
      case 'state_change':
        if (last['key'] == key) {
          return await _result(store, 'skipped', 'same_state');
        }
      case 'periodic':
        if (!_activeStates.contains(state)) {
          return await _result(store, 'skipped', 'not_active');
        }
        if (attemptAt != null && now.difference(attemptAt) < periodicGap) {
          return await _result(store, 'skipped', 'periodic_10m');
        }
      case 'daily':
        if (_activeStates.contains(state)) {
          return await _result(store, 'skipped', 'active_uses_periodic');
        }
        if (last['day'] == ReportEnv.kstDate(now)) {
          return await _result(store, 'skipped', 'daily_done');
        }
    }

    final cfg = ReportEnv.config;
    if (!cfg.isConfigured) {
      return await _result(store, 'skipped', 'unconfigured');
    }
    final version = await ReportEnv.appVersion();
    if (version == null) return await _result(store, 'skipped', 'no_version');
    final body = buildBody(
      connectionId: connectionId,
      platform: ReportEnv.platform(),
      clientVersion: version,
      backfill: backfill,
      optimize: optimize,
      officialLogin: officialLogin,
      pace: pace,
    );
    if (body == null) return await _result(store, 'skipped', 'schema_invalid');
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > maxBodyBytes) {
      return await _result(store, 'skipped', 'too_large');
    }
    final token = await ReportEnv.accessToken();
    if (token == null || token.isEmpty) {
      return await _result(store, 'skipped', 'no_token');
    }

    // 시도 시각을 먼저 남긴다 — 실패해도 60초·10분 간격은 지킨다(재시도 없음).
    await _writeLast(store, {
      ...last,
      'attempt_at': now.millisecondsSinceEpoch,
    });
    final client = ReportEnv.newClient();
    try {
      final res = await client
          .post(
            Uri.parse(
              '${cfg.supabaseUrl}/functions/v1/community-ingest/progress',
            ),
            headers: {
              'apikey': cfg.publishableKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: bytes, // gzip 금지
          )
          .timeout(timeout);
      if (res.statusCode == 200) {
        await _writeLast(store, {
          'attempt_at': now.millisecondsSinceEpoch,
          'sent_at': now.millisecondsSinceEpoch,
          'key': key,
          'day': ReportEnv.kstDate(now),
          'state': state,
        });
        return await _result(store, 'sent', '200');
      }
      if (res.statusCode == 503 && _isMaintenance(res)) {
        await _recordMaintenance(store, res, now);
        return await _result(store, 'maintenance', '503');
      }
      return await _result(store, 'failed', '${res.statusCode}');
    } on TimeoutException {
      return await _result(store, 'failed', 'timeout');
    } catch (_) {
      return await _result(store, 'failed', 'network');
    } finally {
      client.close();
    }
  }

  static bool _isMaintenance(http.Response res) {
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      return d is Map &&
          d['error'] is Map &&
          (d['error'] as Map)['code'] == 'maintenance';
    } catch (_) {
      return false;
    }
  }

  static Future<void> _recordMaintenance(
    CommunityStore store,
    http.Response res,
    DateTime now,
  ) async {
    String? resumeAt;
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      final v = (d as Map)['error'] is Map
          ? ((d['error'] as Map)['resume_at'])
          : null;
      if (v is String &&
          RegExp(r'^\d{4}-\d{2}-\d{2}T[0-9:.]+Z$').hasMatch(v) &&
          v.length <= 40) {
        resumeAt = v;
      }
    } catch (_) {}
    final retry = int.tryParse(res.headers['retry-after'] ?? '');
    await store.setMeta(
      metaMaintenance,
      jsonEncode({
        'at': isoUtc(now),
        'resume_at': resumeAt,
        'retry_after_s': (retry != null && retry >= 0 && retry <= 86400)
            ? retry
            : null,
      }),
    );
  }

  static Future<Map<String, Object?>> _readLast(CommunityStore store) async {
    try {
      final raw = await store.meta(metaLast);
      if (raw == null) return {};
      final d = jsonDecode(raw);
      return d is Map ? Map<String, Object?>.from(d) : {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeLast(
    CommunityStore store,
    Map<String, Object?> v,
  ) => store.setMeta(metaLast, jsonEncode(v));

  /// 마지막 결과 요약(진단용, 값 없음). `{at, status, detail}`.
  static Future<void> _result(
    CommunityStore store,
    String status,
    String detail,
  ) async {
    try {
      await store.setMeta(
        metaResult,
        jsonEncode({
          'at': ReportEnv.now().millisecondsSinceEpoch,
          'status': status,
          'detail': detail,
        }),
      );
    } catch (_) {}
  }

  // ── 본문 조립·스키마 검사 (progress.schema.json) ─────────────

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final _code = RegExp(r'^[a-z0-9_]{1,40}$');
  static final _instant = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$',
  );
  static final _version = RegExp(r'^[0-9][0-9A-Za-z.+_-]{0,39}$');
  static const _countKeys = [
    'total',
    'stored',
    'queued',
    'pending',
    'holds',
    'stale_holds',
    'raw_unavailable',
    'not_eligible',
  ];

  /// 스키마에 맞는 본문을 만든다. 모르는 키는 버리고, 형식이 틀리면 null(보내지 않는다).
  static Map<String, Object?>? buildBody({
    required String connectionId,
    required String platform,
    required String clientVersion,
    required Map<String, Object?> backfill,
    required Map<String, Object?> optimize,
    required String officialLogin,
    Map<String, Object?>? pace,
  }) {
    if (!_uuid.hasMatch(connectionId)) return null;
    if (!const {'android', 'ios', 'other'}.contains(platform)) return null;
    if (!_version.hasMatch(clientVersion)) return null;
    if (!const {'ok', 'retry', 'manual_required'}.contains(officialLogin)) {
      return null;
    }
    final state = backfill['state'];
    if (state is! String || !_allStates.contains(state)) return null;

    bool codeOk(Object? v) => v == null || (v is String && _code.hasMatch(v));
    bool instantOk(Object? v) =>
        v == null || (v is String && _instant.hasMatch(v));
    bool countOk(Object? v) =>
        v == null || (v is int && v >= 0 && v <= 10000000);

    final bf = <String, Object?>{'state': state};
    for (final k in const ['phase', 'reason']) {
      if (!codeOk(backfill[k])) return null;
      bf[k] = backfill[k];
    }
    for (final k in const ['next_attempt_at', 'run_started_at', 'updated_at']) {
      if (!instantOk(backfill[k])) return null;
      bf[k] = backfill[k];
    }
    for (final k in _countKeys) {
      if (!countOk(backfill[k])) return null;
      bf[k] = backfill[k];
    }
    // 객체 키 순서는 스키마와 무관하지만 읽기 좋게 계약 순서로 정리한다.
    const order = [
      'state',
      'phase',
      'reason',
      'next_attempt_at',
      'total',
      'stored',
      'queued',
      'pending',
      'holds',
      'stale_holds',
      'raw_unavailable',
      'not_eligible',
      'run_started_at',
      'updated_at',
    ];
    final bfOrdered = {for (final k in order) k: bf[k]};

    final opt = <String, Object?>{};
    for (final k in const ['required', 'running', 'holds_only']) {
      final v = optimize[k];
      if (v is! bool) return null;
      opt[k] = v;
    }

    Map<String, Object?>? paceOut;
    if (pace != null) {
      int? slot(Object? v) {
        if (v == null) return null;
        if (v is int && v >= 0 && v <= 100000) return v;
        throw const FormatException('pace');
      }

      try {
        paceOut = {
          'foreground_slices_today': slot(pace['foreground_slices_today']),
          'background_runs_today': slot(pace['background_runs_today']),
        };
      } on FormatException {
        return null;
      }
    }
    return {
      'protocol': 1,
      'contract': 'community-progress-v1',
      'connection_id': connectionId,
      'source_app': 'safetyreport-mobile',
      'platform': platform,
      'client_version': clientVersion,
      'parser_version': mobileParserVersion,
      'backfill': bfOrdered,
      'optimize': opt,
      'official_login': officialLogin,
      'pace': paceOut,
    };
  }
}
