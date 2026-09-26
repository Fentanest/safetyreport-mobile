// 자정 업로드 스케줄 (contracts/community-ingest/schedule.md).
//
// 기준 Asia/Seoul 00:00. 한국은 DST 가 없어 KST = UTC+9 고정으로 계산한다.
// dueKey(t) = "midnight:" + kst_date(t) — t 시점에 이미 지난 가장 최근 KST 자정.
// nextDueAt(t) = t 보다 엄격히 늦은 다음 KST 자정.
// shouldRun: runs[dueKey] 가 succeeded 면 false, running+lease 유효면 false, 그 밖 true.
// 이전 날짜 누락은 따로 실행하지 않는다(최신 키 하나만 — 미ACK 전체를 보내므로).
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import '../community_store.dart';
import '../community_store.dart' as community_store;
import '../../services/community_auth_config.dart';
import 'community_uploader.dart';

const String communityPeriodicUniqueName = 'community-upload-periodic';
const String communityPeriodicTaskName = 'community-upload-periodic';
const String communityMidnightUniqueName = 'community-midnight';
const String communityMidnightTaskName = 'community-midnight';

/// (t + 9h) 의 UTC 날짜 → due key.
String dueKey(DateTime nowUtc) {
  final kst = nowUtc.toUtc().add(const Duration(hours: 9));
  final date =
      '${kst.year.toString().padLeft(4, '0')}-${kst.month.toString().padLeft(2, '0')}-${kst.day.toString().padLeft(2, '0')}';
  return 'midnight:$date';
}

/// due key → 그 KST 날짜 00:00 = UTC 전날 15:00.
DateTime dueAtUtc(String key) {
  final date = key.substring('midnight:'.length);
  final parts = date.split('-');
  final day = DateTime.utc(
      int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  return day.subtract(const Duration(hours: 9));
}

/// t 보다 엄격히 늦은 다음 KST 자정 (UTC).
DateTime nextDueAt(DateTime nowUtc) {
  final t = nowUtc.toUtc();
  var candidate = dueAtUtc(dueKey(t));
  if (!candidate.isAfter(t)) {
    candidate = candidate.add(const Duration(days: 1));
  }
  // 자정 정확히는 다음 날 키의 due 이다.
  final nextDayKey = dueKey(candidate.add(const Duration(seconds: 1)));
  return dueAtUtc(nextDayKey);
}

/// [runs] = schedule_key → {state, lease_until?}.
bool shouldRun(DateTime nowUtc, Map<String, Map<String, Object?>>? runs) {
  final key = dueKey(nowUtc);
  final run = (runs ?? {})[key];
  if (run == null) return true;
  if (run['state'] == 'succeeded') return false;
  if (run['state'] == 'running') {
    final until = run['lease_until']?.toString();
    if (until != null && until.compareTo(isoUtc(nowUtc)) > 0) return false;
    return true;
  }
  return true;
}

/// Workmanager 등록: 1시간 주기 periodic(복구·누락 자정 보충) + 다음 KST 자정 one-off. 이미 있으면 교체.
Future<void> registerBackgroundJobs() async {
  try {
    await Workmanager().registerPeriodicTask(
      communityPeriodicUniqueName,
      communityPeriodicTaskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  } catch (_) {
    // 플러그인이 없는 환경(테스트 등)에서는 조용히 넘어간다.
  }
  await registerMidnightTask();
}

/// 다음 KST 자정 one-off 를 (다시) 예약한다. 자정 작업이 끝날 때마다 백그라운드에서도 불러 다음 날이 끊기지 않게 한다.
Future<void> registerMidnightTask({DateTime? now}) async {
  try {
    final t = (now ?? DateTime.now()).toUtc();
    final delay = nextDueAt(t).difference(t);
    await Workmanager().registerOneOffTask(
      communityMidnightUniqueName,
      communityMidnightTaskName,
      initialDelay: delay.isNegative ? Duration.zero : delay,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  } catch (_) {}
}

/// Client 전환·로그아웃 시 해제.
Future<void> cancelBackgroundJobs() async {
  try {
    await Workmanager().cancelByUniqueName(communityPeriodicUniqueName);
    await Workmanager().cancelByUniqueName(communityMidnightUniqueName);
  } catch (_) {}
}

typedef UploadRunner = Future<UploadRunResult> Function(String trigger);

/// OS·resume 경로 보충 실행(PC `community_schedule.run_midnight` 와 같은 순서). 그날 key 를 한 트랜잭션에서 확인·선점하고
/// (실행별 고유 owner, 10분 lease), 업로드 뒤 **그 owner 일 때만** 결과를 적는다 — 다른 isolate 의 같은 이유 실행이
/// 동시에 돌거나 늦게 끝난 쪽이 앞선 결과를 덮지 않는다. 반환: succeeded(이미 끝남 포함) | deferred | failed.
Future<String> catchUp(
  String reason, {
  required CommunityStore store,
  required UploadRunner runUpload,
  DateTime? now,
  String? namespace,
}) async {
  final t = (now ?? DateTime.now()).toUtc();
  final key = dueKey(t);
  final context = await store.activeContext();
  if (context == null) return 'deferred';
  // context 표에는 namespace 열이 없다 — capture·uploader 와 같은 규칙(공개 설정 URL)으로 계산한다.
  final projectNamespace = namespace ?? community_store.projectNamespace(CommunityAuthConfig.fromEnvironment.supabaseUrl);
  final fingerprint = context['contributor_fingerprint']?.toString() ?? '';
  final localDatasetId = await store.localDatasetId();
  final epoch = int.tryParse('${context['writer_epoch']}') ?? 0;
  final keyArgs = [projectNamespace, fingerprint, localDatasetId, epoch, key];
  const keyWhere = 'project_namespace=? AND contributor_fingerprint=? AND local_dataset_id=? AND writer_epoch=? AND schedule_key=?';
  final owner = 'scheduler:$reason:${newUuidV4()}';
  final claimed = await store.transaction((tx) async {
    final rows = await tx.rawQuery('SELECT state, lease_until, attempts FROM schedule_runs WHERE $keyWhere', keyArgs);
    final runs = rows.isEmpty
        ? null
        : {key: <String, Object?>{'state': rows.first['state'], 'lease_until': rows.first['lease_until']}};
    if (!shouldRun(t, runs)) return rows.first['state'] == 'succeeded' ? 'succeeded' : 'deferred';
    await tx.insert(
        'schedule_runs',
        {
          'project_namespace': projectNamespace,
          'contributor_fingerprint': fingerprint,
          'local_dataset_id': localDatasetId,
          'writer_epoch': epoch,
          'schedule_key': key,
          'scheduled_date_kst': key.substring('midnight:'.length),
          'due_at_utc': isoUtc(dueAtUtc(key)),
          'state': 'running',
          'attempts': (rows.isEmpty ? 0 : int.tryParse('${rows.first['attempts']}') ?? 0) + 1,
          'last_attempt_at': isoUtc(t),
          'lease_owner': owner,
          'lease_until': isoUtc(t.add(const Duration(minutes: 10))),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    return null;
  });
  if (claimed != null) return claimed;
  UploadRunResult result;
  try {
    result = await runUpload('midnight');
  } catch (e) {
    // 예외여도 key 를 lease 만료까지 running 으로 두지 않는다(내 owner 일 때만 failed 기록 — PC run_midnight 와 같음)
    result = UploadRunResult(runId: '', result: 'failed', errorCode: e.runtimeType.toString());
  }
  final state = midnightState(result.result);
  // PC run_midnight 와 같다: 보류·실패 사유는 오류 코드, 없으면 결과 코드. 다른 실행이 이어받았으면(lease 만료 뒤) 덮지 않는다.
  await store.db.rawUpdate(
    'UPDATE schedule_runs SET state=?, finished_at=?, deferred_reason=?, lease_owner=NULL, lease_until=NULL, run_id=? '
    'WHERE $keyWhere AND lease_owner=?',
    [
      state,
      isoUtc(DateTime.now().toUtc()),
      state == 'succeeded' ? null : (result.errorCode ?? result.result),
      result.runId.isEmpty ? null : result.runId,
      ...keyArgs,
      owner,
    ],
  );
  return state;
}

/// 자정 실행 결과 → schedule_runs 상태(PC `community_schedule.run_midnight` 와 같음). 그날 key 는 sent/no_pending 일 때만
/// succeeded — 대기 전(not_due)·cooldown·다른 실행·인증/동의·게이트·예산 초과(more_pending)는 deferred(다음 기회에 다시).
String midnightState(String result) {
  switch (result) {
    case 'sent':
    case 'no_pending':
      return 'succeeded';
    case 'not_due':
    case 'cooldown':
    case 'busy_other_run':
    case 'needs_auth':
    case 'needs_consent':
    case 'blocked_gate':
    case 'more_pending':
      return 'deferred';
    default:
      return 'failed';
  }
}

/// 게이트 캐시(600초 이내 성공) 기반 판정. T5 의 CommunityGate 가 닿지 않는
/// 경로(지도 패널·백그라운드)에서 uploader 의 requireFresh 를 만족한다.
class CacheGateCheck implements CommunityGateCheck {
  @override
  Future<bool> requireFresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final fresh = await isGateCacheFresh(prefs, DateTime.now());
      _blocked = fresh ? null : _cachedState(prefs) ?? 'gate_not_fresh';
      return fresh;
    } catch (_) {
      _blocked = 'gate_not_fresh';
      return false;
    }
  }

  String? _blocked;
  Future<void>? _pendingWrite;

  @override
  String? get blockedState => _blocked;

  /// 무효화 기록이 끝날 때까지 기다린다 — 백그라운드 작업은 isolate 가 끝나기 전에 부른다(기록이 사라지지 않게).
  Future<void> flush() => _pendingWrite ?? Future<void>.value();

  /// 403·철회 수신: 캐시를 무효로 기록해 다른 isolate(앱·다음 백그라운드 작업)도 보게 한다.
  /// 앱 게이트는 다음 확인(60초 poll·requireFresh)에서 중앙 상태로 다시 쓴다.
  @override
  void invalidate(String reason) {
    _blocked = reason;
    _pendingWrite = SharedPreferences.getInstance()
        .then((prefs) => prefs.setString('community_gate_cache_v1',
            jsonEncode({'state': 'invalidated:$reason', 'verified_at': DateTime.now().millisecondsSinceEpoch})))
        .then<void>((_) {}, onError: (_) {});
  }
}

String? _cachedState(SharedPreferences prefs) {
  try {
    final decoded = jsonDecode(prefs.getString('community_gate_cache_v1') ?? '');
    final state = decoded is Map ? decoded['state'] : null;
    return state is String && state != 'ok' ? state : null;
  } catch (_) {
    return null;
  }
}

/// 게이트 캐시 읽기 (T5 가 쓰는 키 — REQUESTS.md 참조).
///
/// `community_gate_cache_v1` = {state, verified_at(ms epoch)}. state=ok 이고
/// 600초 이내일 때만 true.
Future<bool> isGateCacheFresh(SharedPreferences prefs, DateTime now) async {
  try {
    final raw = prefs.getString('community_gate_cache_v1');
    if (raw == null) return false;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return false;
    if (decoded['state'] != 'ok') return false;
    final verifiedAt = int.tryParse('${decoded['verified_at']}');
    if (verifiedAt == null) return false;
    return now.millisecondsSinceEpoch - verifiedAt <= 600 * 1000;
  } catch (_) {
    return false;
  }
}
