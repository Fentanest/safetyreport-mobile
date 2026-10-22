import 'dart:convert';
import 'dart:math';

import 'backfill_errors.dart';

class BackfillPaused implements Exception {
  BackfillPaused(this.reason, {this.retrySeconds = 300});
  final String reason;
  final int retrySeconds;
}

class BackfillCancelled implements Exception {}

class BackfillBlocked implements Exception {
  BackfillBlocked(this.reason);
  final String reason;
}

abstract class RawBackfillBackend {
  Future<Map<String, dynamic>?> scope();
  Future<bool> current(Map<String, dynamic> scope);
  Future<bool> optimizationReady();
  Future<Map<String, dynamic>> inventory();
  Future<List<String>> localIds();
  Future<List<String>> eligibleIds();
  Future<Map<String, dynamic>> prepare(String id);
  Future<String?> enqueue(String id, String run);
  Future<String> receipt(String id, String event);
  Future<void> wakeUpload();
}

/// 업로드 단계의 영수증 조회를 한 번에 묶을 수 있는 backend(선택). 없으면 항목마다 [RawBackfillBackend.receipt].
abstract class BatchedReceipts {
  Future<void> prefetchReceipts(Iterable<String> events);
}

abstract class BackfillItems {
  Future<void> reset(String run, Map<String, Map<String, dynamic>> items);
  Future<void> loadLegacy(String run, Map<String, dynamic> items);

  /// '다시 시도' 버튼: 시각과 관계없이 모든 보류를 pending·attempts 0·hold_count 0·stale false 로.
  Future<void> retry(String run);

  /// 자동 재시도: `next_attempt_at <= now` 인 보류를 pending·attempts 2 로(한 번 더 실패하면 다시 보류).
  /// 아직 때가 아닌 보류는 30일 표시(stale)만 갱신한다. 되돌린 수를 돌려준다.
  Future<int> releaseDueHolds(String run, int now);
  Future<List<(int, String, Map<String, dynamic>)>> page(
    String run,
    int cursor,
    int limit,
  );
  Future<List<(String, Map<String, dynamic>)>> queued(String run, int limit);
  Future<void> put(String run, String id, Map<String, dynamic> item);
  Future<int> size(String run);
  Future<Map<String, int>> summary(String run);
}

Map<String, dynamic> _copy(Map value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

class MemoryBackfillItems implements BackfillItems {
  Map<String, Map<String, dynamic>> items = {};
  @override
  Future<void> reset(
    String run,
    Map<String, Map<String, dynamic>> items,
  ) async {
    this.items = items;
  }

  @override
  Future<void> loadLegacy(String run, Map<String, dynamic> items) async {
    this.items = {for (final e in items.entries) e.key: _copy(e.value as Map)};
  }

  @override
  Future<void> retry(String run) async {
    for (final item in items.values) {
      if (item['state'] == 'hold') resetHold(item);
    }
  }

  @override
  Future<int> releaseDueHolds(String run, int now) async {
    var released = 0;
    for (final item in items.values) {
      if (item['state'] != 'hold') continue;
      if (releaseHold(item, now)) released++;
    }
    return released;
  }

  @override
  Future<List<(int, String, Map<String, dynamic>)>> page(
    String run,
    int cursor,
    int limit,
  ) async {
    final rows = items.entries.toList();
    return [
      for (var p = cursor; p < rows.length && p < cursor + limit; p++)
        (p, rows[p].key, _copy(rows[p].value)),
    ];
  }

  @override
  Future<List<(String, Map<String, dynamic>)>> queued(
    String run,
    int limit,
  ) async => items.entries
      .where((e) => e.value['state'] == 'queued')
      .take(limit)
      .map((e) => (e.key, _copy(e.value)))
      .toList();
  @override
  Future<void> put(String run, String id, Map<String, dynamic> item) async {
    items[id] = _copy(item);
  }

  @override
  Future<int> size(String run) async => items.length;
  @override
  Future<Map<String, int>> summary(String run) async =>
      summarizeBackfill(items.values);
  Map<String, dynamic> get holds => {
    for (final e in items.entries)
      if (e.value['state'] == 'hold')
        e.key: {
          'reason': e.value['error'] ?? 'upload_rejected',
          'attempts': e.value['attempts'],
        },
  };
}

Map<String, int> summarizeBackfill(Iterable<Map<String, dynamic>> items) {
  final s = <String, int>{
    for (final k in [
      'total',
      'raw_unavailable',
      'available',
      'sent',
      'filled',
      'unfilled',
      'missing_reports',
      'holds',
      'unfinished',
      'pending',
      'queued',
    ])
      k: 0,
  };
  for (final i in items) {
    final eligible = i['eligible'] == true && i['state'] != 'not_eligible';
    if (eligible) {
      s['total'] = s['total']! + 1;
    }
    if (eligible && i['state'] == 'raw_unavailable') {
      s['raw_unavailable'] = s['raw_unavailable']! + 1;
    }
    if (eligible && i['state'] == 'stored') {
      s['sent'] = s['sent']! + 1;
    }
    for (final key in ['filled', 'unfilled']) {
      s[key] = s[key]! + (i[key] as num? ?? 0).toInt();
    }
    if (i['was_missing'] == true) {
      s['missing_reports'] = s['missing_reports']! + 1;
    }
    if (i['state'] == 'hold') {
      s['holds'] = s['holds']! + 1;
    }
    if (i['state'] == 'pending') s['pending'] = s['pending']! + 1;
    if (i['state'] == 'queued') s['queued'] = s['queued']! + 1;
    if (!['stored', 'raw_unavailable', 'not_eligible'].contains(i['state'])) {
      s['unfinished'] = s['unfinished']! + 1;
    }
  }
  s['available'] = s['total']! - s['raw_unavailable']!;
  return s;
}

/// 고정적 오류 3회(또는 업로드 확인 3회 retry) → 보류. 보류 횟수에 따라 다음 자동 재시도 시각을 둔다(CLIENT-RULES 1절).
void holdItem(Map<String, dynamic> item, int now) {
  final count = ((item['hold_count'] as num?)?.toInt() ?? 0) + 1;
  final first = (item['first_held_at'] as num?)?.toInt() ?? now;
  item.addAll({
    'state': 'hold',
    'hold_count': count,
    'next_attempt_at': now + holdBackoffSeconds(count),
    'first_held_at': first,
    'stale': now - first > holdStaleSeconds,
  });
}

/// '다시 시도' 버튼과 2-3 초기화의 되돌림: 처음부터 다시(보류 이력도 지운다).
void resetHold(Map<String, dynamic> item) {
  item.addAll({
    'state': 'pending',
    'attempts': 0,
    'event_id': null,
    'hold_count': 0,
    'stale': false,
  });
  item.remove('next_attempt_at');
  item.remove('first_held_at');
  item.remove(transientAttemptsKey);
}

/// 신고 하나의 연속 일시적 오류 횟수(D1). 성공·보류 때 0(키를 지운다).
const transientAttemptsKey = 'transient_attempts';

/// 같은 신고가 연속 이만큼 일시적 오류를 내면 그 신고만 보류하고 커서를 넘긴다(D1).
const transientHoldThreshold = 5;

/// 신고 탓이 아닌 일시적 사유 — 신고별 횟수에 넣지 않는다(D1).
const notReportTransientReasons = {
  'sync_busy',
  'db_locked',
  'maintenance',
  'official_login_required',
  'official_login_retry',
};

/// 그 신고가 서버에 저장됐다(stored): 보류 이력(hold_count·first_held_at 등)을 이때만 지운다(D2).
void clearHoldHistory(Map<String, dynamic> item) {
  for (final k in [
    'hold_count',
    'first_held_at',
    'next_attempt_at',
    'stale',
    transientAttemptsKey,
  ]) {
    item.remove(k);
  }
}

/// 때가 된 보류를 pending·attempts 2 로. 때가 아니면 30일 표시만 갱신한다. 되돌렸으면 true.
/// `next_attempt_at` 이 없는 예전 보류는 바로 되돌린다.
bool releaseHold(Map<String, dynamic> item, int now) {
  final first = (item['first_held_at'] as num?)?.toInt();
  if (first != null) item['stale'] = now - first > holdStaleSeconds;
  final due = (item['next_attempt_at'] as num?)?.toInt() ?? 0;
  if (due > now) return false;
  item.addAll({'state': 'pending', 'attempts': 2, 'event_id': null});
  return true;
}

/// The same bounded phases, completion and retry rules as PC RawBackfill.
///
/// Error rules (CLIENT-RULES 1, 2026-10-22): a transient error (network, timeout, official 5xx/429, no
/// `result`, another job's lock, a locked local DB, community maintenance) pauses the run with a growing
/// interval (60 → 300 → 900 → 3600 s) and never counts against the report. A fixed error counts; three of
/// them hold the report, and a hold retries by itself (15 min → 1 h → 6 h → 24 h).
class RawBackfill {
  RawBackfill({
    required this.load,
    required this.save,
    required this.backend,
    this.items,
    this.shouldYield,
    this.maintenance,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final Future<Map<String, dynamic>?> Function() load;
  final Future<void> Function(Map<String, dynamic>, Map<String, dynamic>) save;
  final RawBackfillBackend backend;
  final BackfillItems? items;
  final bool Function()? shouldYield;

  /// Upload pause (server maintenance, CLIENT-RULES 5). null = not paused; otherwise `{'wake_at': epoch
  /// seconds or null}` — the run waits as `paused`/`maintenance` and does no work at all.
  final Future<Map<String, Object?>?> Function()? maintenance;
  final DateTime Function() now;
  double get seconds => now().millisecondsSinceEpoch / 1000;
  int get _whole => seconds.floor();
  Future<Map<String, dynamic>?> run({
    int budget = 1000,
    bool retryHolds = false,
  }) async {
    final b = backend, scope = await backend.scope();
    if (scope == null || !await b.current(scope)) {
      return null;
    }
    var m = await load();
    final repo = items ?? MemoryBackfillItems();
    if (m == null || ['local_dataset_id'].any((k) => m![k] != scope[k])) {
      m = <String, dynamic>{
        'contract': 'v2',
        ...scope,
        'run_id':
            '${now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x100000000)}',
        'run_started_at': _whole,
        'state': 'waiting_optimize',
        'phase': 'listing',
        'listing_complete': false,
        'cursor': 0,
        'stats': <String, dynamic>{},
        'holds': <String, dynamic>{},
        'failures': 0,
        'transient_failures': 0,
        'next_attempt_at': 0,
      };
      await repo.reset(m['run_id'] as String, {});
    } else if (m['items'] is Map) {
      await repo.loadLegacy(
        m['run_id'] as String,
        (m['items'] as Map).cast<String, dynamic>(),
      );
      m['listing_complete'] = m['listing_complete'] ?? m['phase'] != 'listing';
    }
    final marker = m, run = marker['run_id'] as String;
    marker.addAll(scope);
    if (retryHolds) {
      await repo.retry(run);
      marker.addAll({
        'failures': 0,
        'transient_failures': 0,
        'next_attempt_at': 0,
      });
      if (marker['phase'] != 'listing' && marker['listing_complete'] == true) {
        marker.addAll({'phase': 'filling', 'cursor': 0});
      }
    }
    Future<void> publish() async {
      if (!await b.current(scope)) {
        throw BackfillCancelled();
      }
      final stats = await repo.summary(run);
      marker['stats'] = {
        for (final e in stats.entries)
          if (e.key != 'unfinished') e.key: e.value,
      };
      if (repo is MemoryBackfillItems) {
        marker['holds'] = repo.holds;
        marker['items'] = _copy(repo.items);
      } else {
        marker['holds'] = stats['holds'];
        marker.remove('items');
      }
      marker['updated_at'] = _whole;
      await save(_copy(marker), scope);
    }

    if (marker['state'] == 'done' && !retryHolds) {
      return marker;
    }
    // Reports newly queued by this slice: the uploader is woken once when the filling slice ends.
    var newQueued = 0;
    try {
      final pause = await maintenance?.call();
      if (pause != null) {
        final wake = (pause['wake_at'] as num?)?.toInt() ?? 0;
        if (marker['state'] != 'paused' ||
            marker['reason'] != 'maintenance' ||
            marker['next_attempt_at'] != wake) {
          marker.addAll({
            'state': 'paused',
            'reason': 'maintenance',
            // No resume time: no timer — the next status that says "resumed" wakes the run.
            'next_attempt_at': wake,
          });
          await publish();
        }
        return marker;
      }
      if (marker['reason'] == 'maintenance') {
        // Resumed (possibly earlier than announced): the maintenance time no longer applies.
        marker['next_attempt_at'] = 0;
      }
      if (seconds < (marker['next_attempt_at'] as num? ?? 0)) {
        return marker;
      }
      marker.remove('reason');
      marker['next_attempt_at'] = 0;
      if (!await b.optimizationReady()) {
        marker['state'] = 'waiting_optimize';
        await publish();
        return marker;
      }
      if (marker['phase'] == 'listing' || marker['listing_complete'] != true) {
        marker.addAll({'phase': 'listing', 'state': 'listing'});
        await publish();
        final inventory = await b.inventory();
        if (inventory['list_ok'] != true) {
          throw BackfillPaused('list_incomplete');
        }
        final existing = (await b.localIds()).toSet(),
            eligible = (await b.eligibleIds()).toSet();
        final missing = (inventory['ids'] as List)
            .cast<String>()
            .toSet()
            .difference(existing);
        final remoteEligible = (inventory['eligible_ids'] as List? ?? [])
            .cast<String>()
            .toSet();
        final ids = eligible.union(missing).toList()..sort();
        await repo.reset(run, {
          for (final id in ids)
            id: <String, dynamic>{
              'state': 'pending',
              'attempts': 0,
              'eligible': eligible.contains(id) || remoteEligible.contains(id),
              'was_missing': missing.contains(id),
            },
        });
        marker.addAll({
          'phase': 'filling',
          'state': 'filling',
          'cursor': 0,
          'listing_complete': true,
        });
        await publish();
      } else if (await repo.releaseDueHolds(run, _whole) > 0) {
        // Holds whose time has come go back to work at the start of this slice.
        marker.addAll({'phase': 'filling', 'cursor': 0});
      }
      if (marker['phase'] == 'filling') {
        marker['state'] = 'filling';
        for (final (index, id, item) in await repo.page(
          run,
          (marker['cursor'] as num).toInt(),
          budget,
        )) {
          if (shouldYield?.call() == true) {
            break;
          }
          if ([
            'stored',
            'raw_unavailable',
            'not_eligible',
            'hold',
            'queued',
          ].contains(item['state'])) {
            marker['cursor'] = index + 1;
            continue;
          }
          if (!await b.current(scope)) {
            throw BackfillCancelled();
          }
          try {
            item.addAll(await b.prepare(id));
            if (!await b.current(scope)) {
              throw BackfillCancelled();
            }
            if (item['eligible'] != true) {
              item['state'] = 'not_eligible';
            } else if (item['raw_unavailable'] == true) {
              item['state'] = 'raw_unavailable';
            } else {
              item['event_id'] = await b.enqueue(id, run);
              if (item['event_id'] == null) {
                throw StateError('raw_event_not_created');
              }
              item['state'] = 'queued';
              newQueued++;
            }
            // 진행했다: run 의 연속 횟수와 이 신고의 연속 일시적 횟수를 0 으로(보류 이력은 stored 때만 지운다, D2).
            item.remove(transientAttemptsKey);
            marker['failures'] = 0;
            marker['transient_failures'] = 0;
            marker['cursor'] = index + 1;
          } on BackfillBlocked catch (e) {
            item.addAll({
              'state': 'not_eligible',
              'eligible': false,
              'error': e.reason,
            });
            marker['cursor'] = index + 1;
          } on BackfillPaused {
            marker['cursor'] = index;
            rethrow;
          } on BackfillCancelled {
            rethrow;
          } catch (e) {
            final transient = transientBackfillReason(e);
            if (transient != null) {
              if (notReportTransientReasons.contains(transient)) {
                // 신고 탓이 아님(다른 작업의 잠금·DB 잠김·점검·로그인): 신고별 횟수에 넣지 않는다.
                marker['cursor'] = index;
                throw BackfillPaused(transient);
              }
              // D1: 같은 신고가 연속 5번 일시적 오류면 그 신고만 고정적 오류처럼 보류하고 커서를 넘긴다
              // (한 신고가 run 전체를 막지 않게). 그 전에는 attempts 를 올리지 않고 커서도 그대로, run 은 쉰다.
              final count =
                  ((item[transientAttemptsKey] as num?)?.toInt() ?? 0) + 1;
              if (count >= transientHoldThreshold) {
                item.remove(transientAttemptsKey);
                item['error'] = 'transient_$transient';
                holdItem(item, _whole);
                marker['cursor'] = index + 1;
                await repo.put(run, id, item);
                continue;
              }
              item[transientAttemptsKey] = count;
              await repo.put(run, id, item);
              marker['cursor'] = index;
              throw BackfillPaused(transient);
            }
            item['attempts'] = (item['attempts'] as int) + 1;
            marker['failures'] = (marker['failures'] as int) + 1;
            item['error'] = e.runtimeType.toString();
            if (item['attempts'] >= 3) {
              item.remove(transientAttemptsKey);
              holdItem(item, _whole);
              marker['cursor'] = index + 1;
            } else {
              marker['cursor'] = index;
            }
            await repo.put(run, id, item);
            if (marker['failures'] >= 5) {
              throw BackfillPaused('consecutive_failures');
            }
            if (item['attempts'] < 3) {
              break;
            }
          }
          await repo.put(run, id, item);
        }
        if (marker['cursor'] >= await repo.size(run)) {
          marker.addAll({'phase': 'uploading', 'state': 'uploading'});
        } else if (newQueued > 0) {
          // The filling slice ends with new queued reports: wake the uploader once (CLIENT-RULES 3).
          // When the slice moves on to the receipt stage, that stage's wake below covers it.
          await b.wakeUpload();
          newQueued = 0;
        }
      }
      if (marker['phase'] == 'uploading') {
        final queued = await repo.queued(run, budget);
        if (b is BatchedReceipts) {
          await (b as BatchedReceipts).prefetchReceipts([
            for (final (_, item) in queued)
              if (item['event_id'] is String) item['event_id'] as String,
          ]);
        }
        for (final (id, item) in queued) {
          if (shouldYield?.call() == true) {
            break;
          }
          final result = await b.receipt(id, item['event_id'] as String);
          if (result == 'stored') {
            item['state'] = 'stored';
            clearHoldHistory(item);
          } else if (result == 'blocked') {
            item.addAll({
              'state': 'not_eligible',
              'eligible': false,
              'error': 'upload_rejected',
            });
          } else if (result == 'rebind') {
            item.addAll({'state': 'pending', 'attempts': 0});
            marker.addAll({'phase': 'filling', 'cursor': 0});
          } else if (result == 'retry') {
            item['attempts'] = (item['attempts'] as int) + 1;
            if (item['attempts'] >= 3) {
              // Three upload retries are a hold (automatic retry), not a permanent exclusion.
              item['error'] = 'upload_retry';
              holdItem(item, _whole);
            } else {
              item['state'] = 'pending';
              marker.addAll({'phase': 'filling', 'cursor': 0});
            }
          }
          await repo.put(run, id, item);
        }
        final stats = await repo.summary(run),
            complete =
                marker['listing_complete'] == true && stats['unfinished'] == 0;
        if (!complete &&
            marker['listing_complete'] == true &&
            (stats['pending'] ?? 0) > 0) {
          // Pending reports (rebind, retry, a hold released, the one-time unstick) are only picked up by
          // the filling phase — never leave them behind an "uploading" run.
          marker.addAll({'phase': 'filling', 'cursor': 0});
        }
        marker['state'] = complete
            ? 'done'
            : marker['phase'] == 'filling'
            ? 'filling'
            : stats['holds']! > 0
            ? 'holds'
            : marker['phase'];
        if (!complete) {
          await b.wakeUpload();
        }
      }
      await publish();
      return marker;
    } on BackfillPaused catch (e) {
      int retry;
      if (officialLoginReasons.contains(e.reason)) {
        retry = e.retrySeconds;
      } else {
        final count =
            ((marker['transient_failures'] as num?)?.toInt() ?? 0) + 1;
        marker['transient_failures'] = count;
        retry = transientBackoffSeconds(count);
      }
      marker.addAll({
        'state': 'paused',
        'reason': e.reason,
        'next_attempt_at': seconds + retry,
      });
      if (newQueued > 0) await b.wakeUpload();
      await publish();
      return marker;
    } on BackfillCancelled {
      return null;
    }
  }
}
