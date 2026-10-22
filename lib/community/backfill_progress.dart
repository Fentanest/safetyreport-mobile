// 1회 전송 진행 보고·사용자 조치 알림을 "언제" 부를지 정하고 값을 만든다 — CLIENT-RULES 4-1·8절.
//
// 전송·60초 간격·마지막 전송 기록은 D 의 [ProgressReporter]·[UserActionNotifier] 가 맡는다. 여기는:
// - 보내는 때: ① 앱 시작·게이트 통과 뒤 1회(start) ② (state, phase, reason, official_login, optimize.*) 가 바뀜(state_change)
//   ③ 진행 중이면 마지막 호출 뒤 10분(periodic) ④ done·none 이면 하루 1번(daily, KST 날짜). 개수만 바뀐 것은 보내지 않는다.
// - 중지(5절)·필수 버전 잠금(6절) 중에는 진행 보고를 부르지 않는다(알림 판단은 잠금도 알려야 하므로 부른다).
// - 값: 개수와 상태 코드만(신고 ID·본문·URL 없음). `pace` 는 오늘(KST) 포그라운드 slice 수·백그라운드 실행 수.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_mode.dart';
import '../services/app_prefs_keys.dart';
import '../services/db_optimize.dart';
import 'backfill_store.dart';
import 'community_store.dart';
import 'notify/user_action_notifier.dart';
import 'raw_backfill_unstick.dart' show rawLoginManualKey;
import 'report/progress_reporter.dart';
import 'update_requirement.dart';
import 'upload_pause.dart';

class BackfillProgress {
  BackfillProgress._();

  static const paceKey = 'raw_backfill_pace';
  static const lastCallKey = 'raw_backfill_progress_call';
  static const periodicGap = Duration(minutes: 10);
  static const activeStates = {
    'listing',
    'filling',
    'uploading',
    'paused',
    'waiting_optimize',
    'holds',
  };

  /// 이 프로세스에서 start 를 이미 불렀는가(앱 시작·게이트 통과 뒤 1회).
  static bool _startCalled = false;

  /// 시험용 시계.
  static DateTime Function() clock = DateTime.now;

  static String kstDay(DateTime t) {
    final k = t.toUtc().add(const Duration(hours: 9));
    return '${k.year.toString().padLeft(4, '0')}-${k.month.toString().padLeft(2, '0')}-${k.day.toString().padLeft(2, '0')}';
  }

  static Future<Map<String, dynamic>?> _marker(CommunityStore store) async {
    try {
      final text = await store.meta('raw_backfill');
      final value = text == null ? null : jsonDecode(text);
      return value is Map ? value.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 오늘(KST) 포그라운드 채우기 slice 수·백그라운드 실행 수를 1 올린다(0시에 0부터).
  static Future<void> countRun(
    CommunityStore store, {
    required bool background,
  }) async {
    try {
      final today = kstDay(clock());
      final now = await _pace(store, today);
      final key = background ? 'bg' : 'fg';
      now[key] = (now[key] as int) + 1;
      await store.setMeta(paceKey, jsonEncode(now));
    } catch (_) {}
  }

  static Future<Map<String, Object?>> _pace(
    CommunityStore store,
    String today,
  ) async {
    try {
      final text = await store.meta(paceKey);
      final value = text == null ? null : jsonDecode(text);
      if (value is Map && value['day'] == today) {
        return {
          'day': today,
          'fg': (value['fg'] as num?)?.toInt() ?? 0,
          'bg': (value['bg'] as num?)?.toInt() ?? 0,
        };
      }
    } catch (_) {}
    return {'day': today, 'fg': 0, 'bg': 0};
  }

  static String? _iso(Object? epochSeconds) {
    if (epochSeconds is! num || epochSeconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (epochSeconds * 1000).round(),
      isUtc: true,
    ).toIso8601String();
  }

  /// 예전 marker 에는 run_started_at 이 없다 — run_id 앞부분(마이크로초)에서 읽는다.
  static Object? _runStarted(Map<String, dynamic> marker) {
    final started = marker['run_started_at'];
    if (started is num) return started;
    final id = marker['run_id'];
    if (id is! String) return null;
    final micros = int.tryParse(id.split('-').first);
    return micros == null ? null : micros / 1e6;
  }

  static String? _code(Object? value) =>
      value is String && RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(value)
      ? value
      : null;

  /// 진행 보고 `backfill` 객체(progress.schema.json).
  static Future<Map<String, Object?>> backfillSection(
    CommunityStore store,
    Map<String, dynamic>? marker,
  ) async {
    const countKeys = [
      'total',
      'stored',
      'queued',
      'pending',
      'holds',
      'stale_holds',
      'raw_unavailable',
      'not_eligible',
    ];
    if (marker == null || marker['run_id'] is! String) {
      return {
        'state': 'none',
        'phase': null,
        'reason': null,
        'next_attempt_at': null,
        for (final k in countKeys) k: null,
        'run_started_at': null,
        'updated_at': null,
      };
    }
    Map<String, int>? counts;
    try {
      counts = await SqliteBackfillItems(
        store,
        () async {},
      ).stateCounts(marker['run_id'] as String);
    } catch (_) {
      counts = null;
    }
    final state = marker['state'];
    return {
      'state': ProgressStates.all.contains(state) ? state : 'none',
      'phase': _code(marker['phase']),
      'reason': state == 'paused' ? _code(marker['reason']) : null,
      'next_attempt_at': _iso(marker['next_attempt_at']),
      for (final k in countKeys) k: counts?[k],
      'run_started_at': _iso(_runStarted(marker)),
      'updated_at': _iso(marker['updated_at']),
    };
  }

  static Future<Map<String, Object?>> optimizeSection() async {
    var required = false, holdsOnly = false;
    try {
      final meta = await DbOptimize.readMeta();
      holdsOnly = DbOptimize.holdsOnly(meta);
      required = !holdsOnly && await DbOptimize.needsRun();
    } catch (_) {}
    return {
      'required': required,
      'running': DbOptimize.isRunning,
      'holds_only': holdsOnly,
    };
  }

  /// `ok` / `retry`(일시 실패로 기다림) / `manual_required`(사용자가 로그인해야 함).
  static Future<String> officialLogin(
    CommunityStore store,
    Map<String, dynamic>? marker,
  ) async {
    if (marker?['state'] != 'paused') return 'ok';
    final reason = marker?['reason'];
    if (reason == 'official_login_required') {
      return await store.meta(rawLoginManualKey) != null
          ? 'manual_required'
          : 'retry';
    }
    if (reason == 'official_login_retry') return 'retry';
    return 'ok';
  }

  /// 지금 상태를 보고·알림 판단에 넘긴다. [start] 는 앱 시작·게이트 통과 뒤, [background] 는 WorkManager 실행 끝.
  static Future<void> report(
    CommunityStore store, {
    bool start = false,
    bool background = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (AppModeX.fromString(prefs.getString(AppPrefsKeys.appMode)) !=
              AppMode.standalone ||
          (prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false)) {
        return;
      }
      final lock = await UpdateRequirement.load(prefs);
      final marker = await _marker(store);
      final backfill = await backfillSection(store, marker);
      final optimize = await optimizeSection();
      final login = await officialLogin(store, marker);
      final stateKey = jsonEncode([
        backfill['state'],
        backfill['phase'],
        backfill['reason'],
        login,
        optimize['required'],
        optimize['running'],
        optimize['holds_only'],
      ]);
      final trigger = await _trigger(
        store,
        stateKey,
        backfill['state'] as String,
        start: start,
      );
      if (trigger == null && !background && !start) return;
      final staleHolds = (backfill['stale_holds'] as int?) ?? 0;
      await UserActionNotifier.evaluate(
        backfillReason: backfill['reason'] as String?,
        officialLoginManual: login == 'manual_required',
        optimizeBlockedInBackground:
            background &&
            backfill['state'] == 'waiting_optimize' &&
            optimize['required'] == true,
        staleHolds: staleHolds,
        updateRequired: lock.locked,
      );
      // 중지(5절)·필수 버전 잠금(6절) 중에는 진행 보고를 부르지 않는다. 연결 전은 설정 단계 보고(4-2)가 맡는다.
      if (trigger == null || lock.locked) return;
      if (await UploadPause.isPaused(store)) return;
      if (await store.activeContext() == null) return;
      final today = kstDay(clock());
      final pace = await _pace(store, today);
      final sent = await ProgressReporter.maybeSend(
        store: store,
        trigger: trigger,
        backfill: backfill,
        optimize: optimize,
        officialLogin: login,
        pace: {
          'foreground_slices_today': pace['fg'],
          'background_runs_today': pace['bg'],
        },
      );
      // D5: 보낸 경우에만 "마지막 보낸 상태 키"를 바꾼다. 60초 간격 등으로 건너뛴 상태 변화는 다음 tick 에 나간다.
      if (sent) {
        if (trigger == 'start') _startCalled = true;
        await store.setMeta(
          lastCallKey,
          jsonEncode({
            'key': stateKey,
            'at': clock().toUtc().millisecondsSinceEpoch ~/ 1000,
            'day': today,
          }),
        );
      }
      // 진행 보고가 503 maintenance 를 받았으면 5절 중지 처리로 넘긴다(D 가 meta 에 남긴 기록).
      final maintenance = await ProgressReporter.lastMaintenance(store);
      if (maintenance != null) {
        await UploadPause.applyMaintenance(store, {
          'resume_at': maintenance['resume_at'],
          // 503 쪽 문구가 없으면 applyMaintenance 가 저장된 문구를 그대로 둔다(R1-10).
          'pause_message': maintenance['pause_message'],
        });
        await ProgressReporter.clearMaintenance(store);
      }
    } catch (_) {
      // 보고·알림은 다른 기능에 영향을 주지 않는다.
    }
  }

  static Future<String?> _trigger(
    CommunityStore store,
    String stateKey,
    String state, {
    required bool start,
  }) async {
    // start 표시는 실제로 보낼 때(연결 있음·중지/잠금 아님) 세운다 — 게이트 통과 전 호출이 1회를 써 버리지 않게.
    if (start && !_startCalled) return 'start';
    Map<String, Object?> last = const {};
    try {
      final text = await store.meta(lastCallKey);
      final value = text == null ? null : jsonDecode(text);
      if (value is Map) last = value.cast<String, Object?>();
    } catch (_) {}
    if (last['key'] != stateKey) return 'state_change';
    final now = clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (activeStates.contains(state)) {
      final at = (last['at'] as num?)?.toInt() ?? 0;
      return now - at >= periodicGap.inSeconds ? 'periodic' : null;
    }
    return last['day'] == kstDay(clock()) ? null : 'daily';
  }

  /// 시험 전용: start 1회 표시를 되돌린다.
  static void resetForTest() => _startCalled = false;
}

class ProgressStates {
  static const all = {
    'waiting_optimize',
    'listing',
    'filling',
    'uploading',
    'paused',
    'holds',
    'done',
    'none',
  };
}
