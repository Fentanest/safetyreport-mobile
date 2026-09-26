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

/// Workmanager 등록: 1시간 주기 periodic + 다음 KST 자정 one-off. 이미 있으면 교체.
Future<void> registerBackgroundJobs() async {
  try {
    await Workmanager().registerPeriodicTask(
      communityPeriodicUniqueName,
      communityPeriodicTaskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
    final delay = nextDueAt(DateTime.now().toUtc())
        .difference(DateTime.now().toUtc());
    await Workmanager().registerOneOffTask(
      communityMidnightUniqueName,
      communityMidnightTaskName,
      initialDelay: delay.isNegative ? Duration.zero : delay,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  } catch (_) {
    // 플러그인이 없는 환경(테스트 등)에서는 조용히 넘어간다.
  }
}

/// Client 전환·로그아웃 시 해제.
Future<void> cancelBackgroundJobs() async {
  try {
    await Workmanager().cancelByUniqueName(communityPeriodicUniqueName);
    await Workmanager().cancelByUniqueName(communityMidnightUniqueName);
  } catch (_) {}
}

typedef UploadRunner = Future<UploadRunResult> Function(String trigger);

/// OS·resume 경로 보충 실행. lease 로 단일화하고 schedule_runs 에 기록한다.
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
  final rows = await store.db.rawQuery(
    'SELECT state, lease_until FROM schedule_runs WHERE project_namespace=? '
    'AND contributor_fingerprint=? AND local_dataset_id=? AND writer_epoch=? '
    'AND schedule_key=?',
    [projectNamespace, fingerprint, localDatasetId, epoch, key],
  );
  final runs = <String, Map<String, Object?>>{};
  if (rows.isNotEmpty) {
    runs[key] = {
      'state': rows.first['state'],
      'lease_until': rows.first['lease_until'],
    };
  }
  if (!shouldRun(t, runs)) return 'succeeded';
  const owner = 'scheduler';
  if (!await store.acquireLease(
      'scheduler', '$owner:$reason', const Duration(minutes: 10))) {
    return 'deferred';
  }
  try {
    await store.db.insert('schedule_runs', {
      'project_namespace': projectNamespace,
      'contributor_fingerprint': fingerprint,
      'local_dataset_id': localDatasetId,
      'writer_epoch': epoch,
      'schedule_key': key,
      'scheduled_date_kst': key.substring('midnight:'.length),
      'due_at_utc': isoUtc(dueAtUtc(key)),
      'state': 'running',
      'attempts': (rows.isEmpty
              ? 0
              : int.tryParse('${rows.first['state'] == 'running' ? 1 : 0}') ??
                  0) +
          1,
      'last_attempt_at': isoUtc(t),
      'lease_owner': '$owner:$reason',
      'lease_until': isoUtc(t.add(const Duration(minutes: 10))),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final result = await runUpload('midnight');
    final state = result.result == 'success' || result.result == 'no_change'
        ? 'succeeded'
        : (result.result == 'deferred' || result.result == 'offline'
            ? 'deferred'
            : 'failed');
    await store.db.rawUpdate(
      'UPDATE schedule_runs SET state=?, finished_at=?, deferred_reason=? '
      'WHERE project_namespace=? AND contributor_fingerprint=? '
      'AND local_dataset_id=? AND writer_epoch=? AND schedule_key=?',
      [
        state,
        state == 'running' ? null : isoUtc(DateTime.now().toUtc()),
        result.errorCode,
        projectNamespace,
        fingerprint,
        localDatasetId,
        epoch,
        key,
      ],
    );
    return state;
  } finally {
    await store.releaseLease('scheduler', '$owner:$reason');
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
      return isGateCacheFresh(prefs, DateTime.now());
    } catch (_) {
      return false;
    }
  }

  @override
  void invalidate(String reason) {}
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
